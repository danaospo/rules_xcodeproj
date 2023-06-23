"""Implementation of the `xcodeproj` rule."""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//lib:shell.bzl", "shell")
load(
    "//xcodeproj/internal/bazel_integration_files:actions.bzl",
    "write_bazel_build_script",
    "write_create_xcode_overlay_script",
)
load("//xcodeproj/internal:configuration.bzl", "calculate_configuration")
load("//xcodeproj/internal:execution_root.bzl", "write_execution_root_file")
load(":input_files.bzl", "input_files")
load("//xcodeproj/internal:memory_efficiency.bzl", "memory_efficient_depset")
load(":output_files.bzl", "output_files")
load(":pbxproj_partials.bzl", "pbxproj_partials")
load(":providers.bzl", "XcodeProjInfo")
load("//xcodeproj/internal:selected_model_versions.bzl", "write_selected_model_versions_file")
load("//xcodeproj/internal:target_id.bzl", "write_target_ids_list")
load(":xcode_targets.bzl", xctargets = "xcode_targets")

# Utility

def _get_minimum_xcode_version(*, xcode_config):
    version = str(xcode_config.xcode_version())
    if not version:
        fail("""\
`xcode_config.xcode_version` was not set. This is a bazel bug. Try again.
""")
    return ".".join(version.split(".")[0:3])

def _process_dep(dep):
    info = dep[XcodeProjInfo]

    if info.non_top_level_rule_kind:
        fail("""
'{label}' is not a top-level target, but was listed in `top_level_targets`. \
Only list top-level targets (e.g. binaries, apps, tests, or distributable \
frameworks) in `top_level_targets`. Schemes and \
`focused_targets`/`unfocused_targets` can refer to dependencies of targets \
listed in `top_level_targets`, and don't need to be listed in \
`top_level_targets` themselves.

If you feel this is an error, and `{kind}` targets should be recognized as \
top-level targets, file a bug report here: \
https://github.com/MobileNativeFoundation/rules_xcodeproj/issues/new?template=bug.md
""".format(label = dep.label, kind = info.non_top_level_rule_kind))

    return info

# Actions

def _write_installer(
        *,
        actions,
        bazel_integration_files,
        config,
        contents_xcworkspacedata,
        install_path,
        is_fixture,
        name,
        project_pbxproj,
        template,
        xcfilelists):
    installer = actions.declare_file(
        "{}-installer.sh".format(name),
    )

    actions.expand_template(
        template = template,
        output = installer,
        is_executable = True,
        substitutions = {
            "%bazel_integration_files%": shell.array_literal(
                [f.short_path for f in bazel_integration_files],
            ),
            "%config%": config,
            "%contents_xcworkspacedata%": contents_xcworkspacedata.short_path,
            "%is_fixture%": "1" if is_fixture else "0",
            "%output_path%": install_path,
            "%project_pbxproj%": project_pbxproj.short_path,
            "%xcfilelists%": shell.array_literal(
                [f.short_path for f in xcfilelists],
            ),
        },
    )

    return installer

# Rule

def _xcodeproj_impl(ctx):
    xcode_configuration_map = ctx.attr.xcode_configuration_map
    infos = []
    infos_per_xcode_configuration = {}
    for transition_key in (
        ctx.split_attr.top_level_simulator_targets.keys() +
        ctx.split_attr.top_level_device_targets.keys()
    ):
        targets = []
        if ctx.split_attr.top_level_simulator_targets:
            targets.extend(
                ctx.split_attr.top_level_simulator_targets[transition_key],
            )
        if ctx.split_attr.top_level_device_targets:
            targets.extend(
                ctx.split_attr.top_level_device_targets[transition_key],
            )

        i = [_process_dep(dep) for dep in targets]
        infos.extend(i)
        for xcode_configuration in xcode_configuration_map[transition_key]:
            infos_per_xcode_configuration[xcode_configuration] = i

    xcode_configurations = sorted(infos_per_xcode_configuration.keys())
    default_xcode_configuration = (ctx.attr.default_xcode_configuration or
                                   xcode_configurations[0])

    actions = ctx.actions
    bin_dir_path = ctx.bin_dir.path
    build_mode = ctx.attr.build_mode
    colorize = ctx.attr.colorize
    config = ctx.attr.config
    configuration = calculate_configuration(bin_dir_path = bin_dir_path)
    install_path = ctx.attr.install_path
    is_fixture = ctx.attr._is_fixture
    minimum_xcode_version = (
        ctx.attr.minimum_xcode_version or
        _get_minimum_xcode_version(
            xcode_config = (
                ctx.attr._xcode_config[apple_common.XcodeVersionConfig]
            ),
        )
    )
    name = ctx.attr.name
    project_options = ctx.attr.project_options
    workspace_directory = ctx.attr.workspace_directory

    (_, provider_outputs) = output_files.merge(
        transitive_infos = infos,
    )

    inputs = input_files.merge(
        transitive_infos = infos,
    )

    focused_labels = {label: None for label in ctx.attr.focused_targets}
    unfocused_labels = {label: None for label in ctx.attr.unfocused_targets}
    replacement_labels = {
        r.id: r.label
        for r in depset(
            transitive = [info.replacement_labels for info in infos],
        ).to_list()
    }

    (
        xcode_targets,
        xcode_targets_by_label,
        xcode_target_configurations,
    ) = xctargets.dicts_from_xcode_configurations(
        infos_per_xcode_configuration = infos_per_xcode_configuration,
    )

    target_ids_list = write_target_ids_list(
        actions = actions,
        name = name,
        target_ids = xcode_targets.keys(),
    )

    execution_root_file = write_execution_root_file(
        actions = actions,
        bin_dir_path = bin_dir_path,
        name = name,
    )

    bazel_integration_files = (
        list(ctx.files._base_integration_files)
    ) + [
        write_bazel_build_script(
            actions = actions,
            bazel_env = ctx.attr.bazel_env,
            bazel_path = ctx.attr.bazel_path,
            generator_label = ctx.label,
            target_ids_list = target_ids_list,
            template = ctx.file._bazel_build_script_template,
        ),
    ]
    if build_mode == "xcode":
        bazel_integration_files.append(
            write_create_xcode_overlay_script(
                actions = actions,
                generator_name = name,
                targets = xcode_targets,
                template = ctx.file._create_xcode_overlay_script_template,
            ),
        )
    else:
        bazel_integration_files.extend(ctx.files._bazel_integration_files)

    (
        pbxtargetdependencies,
        pbxproject_targets,
        pbxproject_target_attributes,
        consolidation_maps,
    ) = pbxproj_partials.write_pbxtargetdependencies(
        actions = actions,
        colorize = colorize,
        generator_name = name,
        install_path = install_path,
        minimum_xcode_version = minimum_xcode_version,
        xcode_target_configurations = xcode_target_configurations,
        xcode_targets_by_label = xcode_targets_by_label,
        tool = ctx.executable._pbxtargetdependencies_generator,
    )

    # Can probably move this into `xcode_targets.merge` (or `finalize` or whatever)
    link_params = xctargets.create_link_params(
        actions = actions,
        generator_name = name,
        link_params_processor = ctx.executable._link_params_processor,
        xcode_targets = xcode_targets,
    )

    (
        target_partials,
        buildfile_subidentifiers_files,
        automatic_xcschemes,
    ) = pbxproj_partials.write_targets(
        actions = actions,
        build_mode = build_mode,
        consolidation_maps = consolidation_maps,
        default_xcode_configuration = default_xcode_configuration,
        generator_name = name,
        hosted_targets = memory_efficient_depset(
            transitive = [info.hosted_targets for info in infos],
        ),
        install_path = install_path,
        link_params = link_params,
        tool = ctx.executable._pbxnativetargets_generator,
        xcode_target_configurations = xcode_target_configurations,
        xcode_targets = xcode_targets,
        xcode_targets_by_label = xcode_targets_by_label,
    )

    selected_model_versions_file = write_selected_model_versions_file(
        actions = actions,
        name = name,
        tool = ctx.executable._selected_model_versions_generator,
        # FIXME: Handle unfocused targets?
        xccurrentversions_files = [
            file
            for _, files in inputs.xccurrentversions.to_list()
            for file in files
        ],
    )

    # FIXME: Extract
    transitive_files = []
    transitive_file_paths = []
    transitive_folders = []
    for xcode_target in xcode_targets.values():
        transitive_files.append(
            memory_efficient_depset(xcode_target.inputs.hdrs),
        )
        transitive_files.append(
            memory_efficient_depset(xcode_target.inputs.non_arc_srcs),
        )
        transitive_files.append(
            memory_efficient_depset(xcode_target.inputs.srcs),
        )
        transitive_file_paths.append(xcode_target.inputs.resources)
        transitive_folders.append(xcode_target.inputs.folder_resources)
    files = memory_efficient_depset(transitive = transitive_files)
    file_paths = memory_efficient_depset(
        # FIXME: Include extra files
        [],
        transitive = transitive_file_paths,
    )
    folders = depset(
        # FIXME: Include extra folders
        [],
        transitive = transitive_folders,
    )
    # END FIXME

    (
        pbxproject_known_regions,
        files_and_groups,
        resolved_repositories_file,
    ) = pbxproj_partials.write_files_and_groups(
        actions = actions,
        buildfile_subidentifiers_files = buildfile_subidentifiers_files,
        colorize = colorize,
        # FIXME: Calculate `compile_stub_needed`
        compile_stub_needed = True,
        execution_root_file = execution_root_file,
        files = files,
        file_paths = file_paths,
        folders = folders,
        generator_name = name,
        install_path = install_path,
        project_options = project_options,
        selected_model_versions_file = selected_model_versions_file,
        tool = ctx.executable._files_and_groups_generator,
        workspace_directory = workspace_directory,
    )

    pbxproj_prefix = pbxproj_partials.write_pbxproj_prefix(
        actions = actions,
        build_mode = build_mode,
        colorize = colorize,
        default_xcode_configuration = default_xcode_configuration,
        execution_root_file = execution_root_file,
        generator_name = name,
        index_import = ctx.executable._index_import,
        install_path = install_path,
        minimum_xcode_version = minimum_xcode_version,
        platforms = depset(transitive = [info.platforms for info in infos]),
        post_build_script = ctx.attr.post_build,
        pre_build_script = ctx.attr.pre_build,
        project_options = project_options,
        resolved_repositories_file = resolved_repositories_file,
        target_ids_list = target_ids_list,
        tool = ctx.executable._pbxproj_prefix_generator,
        xcode_configurations = xcode_configurations,
        workspace_directory = workspace_directory,
    )

    project_pbxproj = pbxproj_partials.write_project_pbxproj(
        actions = actions,
        files_and_groups = files_and_groups,
        generator_name = name,
        pbxproj_prefix = pbxproj_prefix,
        pbxproject_known_regions = pbxproject_known_regions,
        pbxproject_target_attributes = pbxproject_target_attributes,
        pbxproject_targets = pbxproject_targets,
        pbxtargetdependencies = pbxtargetdependencies,
        targets = target_partials,
    )

    xcfilelists = pbxproj_partials.write_xcfilelists(
        actions = actions,
        files = files,
        file_paths = file_paths,
        generator_name = name,
    )

    contents_xcworkspacedata = ctx.file._contents_xcworkspacedata

    installer = _write_installer(
        actions = actions,
        bazel_integration_files = bazel_integration_files,
        config = config,
        contents_xcworkspacedata = contents_xcworkspacedata,
        install_path = install_path,
        is_fixture = is_fixture,
        name = name,
        project_pbxproj = project_pbxproj,
        template = ctx.file._installer_template,
        xcfilelists = xcfilelists,
    )

    if build_mode == "xcode":
        input_files_output_groups = input_files.to_output_groups_fields(
            inputs = inputs,
            index_import = ctx.executable._index_import,
        )
        output_files_output_groups = {}
        all_targets_files = [
            input_files_output_groups["all_xc"],
            input_files_output_groups["all_xi"],
            input_files_output_groups["all_xl"],
        ]
    else:
        input_files_output_groups = {}
        output_files_output_groups = output_files.to_output_groups_fields(
            outputs = provider_outputs,
            # FIXME: `additional_bwb_outputs`
            additional_bwb_outputs = {},
            index_import = ctx.executable._index_import,
        )
        all_targets_files = [output_files_output_groups["all_b"]]

    return [
        DefaultInfo(
            executable = installer,
            runfiles = ctx.runfiles(
                files = [
                    contents_xcworkspacedata,
                    project_pbxproj,
                ] + bazel_integration_files + xcfilelists,
            ),
        ),
        OutputGroupInfo(
            all_targets = depset(
                transitive = all_targets_files,
            ),
            target_ids_list = depset([target_ids_list]),
            **dicts.add(
                input_files_output_groups,
                output_files_output_groups,
            )
        ),
    ]

# buildifier: disable=function-docstring
def make_xcodeproj_rule(
        *,
        xcodeproj_aspect,
        is_fixture = False,
        target_transitions = None,
        xcodeproj_transition = None):
    attrs = {
        "adjust_schemes_for_swiftui_previews": attr.bool(
            mandatory = True,
        ),
        "bazel_path": attr.string(
            mandatory = True,
        ),
        "bazel_env": attr.string_dict(
            mandatory = True,
        ),
        "build_mode": attr.string(
            mandatory = True,
        ),
        "colorize": attr.bool(mandatory = True),
        "config": attr.string(
            mandatory = True,
        ),
        "default_xcode_configuration": attr.string(),
        "fail_for_invalid_extra_files_targets": attr.bool(
            mandatory = True,
        ),
        "focused_targets": attr.string_list(
            mandatory = True,
        ),
        "install_path": attr.string(
            mandatory = True,
        ),
        "minimum_xcode_version": attr.string(
            mandatory = True,
        ),
        "owned_extra_files": attr.label_keyed_string_dict(
            allow_files = True,
            mandatory = True,
        ),
        "post_build": attr.string(
            mandatory = True,
        ),
        "pre_build": attr.string(
            mandatory = True,
        ),
        # TODO: Remove
        "project_name": attr.string(
            mandatory = True,
        ),
        "project_options": attr.string_dict(
            mandatory = True,
        ),
        "runner_build_file": attr.string(
            mandatory = True,
        ),
        "runner_label": attr.string(
            mandatory = True,
        ),
        "scheme_autogeneration_mode": attr.string(
            mandatory = True,
        ),
        "schemes_json": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "top_level_device_targets": attr.label_list(
            cfg = target_transitions.device,
            aspects = [xcodeproj_aspect],
            providers = [XcodeProjInfo],
            mandatory = True,
        ),
        "top_level_simulator_targets": attr.label_list(
            cfg = target_transitions.simulator,
            aspects = [xcodeproj_aspect],
            providers = [XcodeProjInfo],
            mandatory = True,
        ),
        "unfocused_targets": attr.string_list(
            mandatory = True,
        ),
        "unowned_extra_files": attr.label_list(
            allow_files = True,
            mandatory = True,
        ),
        "workspace_directory": attr.string(
            mandatory = True,
        ),
        "xcode_configuration_map": attr.string_list_dict(
            mandatory = True,
        ),
        "ios_device_cpus": attr.string(
            mandatory = True,
        ),
        "ios_simulator_cpus": attr.string(
            mandatory = True,
        ),
        "tvos_device_cpus": attr.string(
            mandatory = True,
        ),
        "tvos_simulator_cpus": attr.string(
            mandatory = True,
        ),
        "watchos_device_cpus": attr.string(
            mandatory = True,
        ),
        "watchos_simulator_cpus": attr.string(
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = Label(
                "@bazel_tools//tools/allowlists/function_transition_allowlist",
            ),
        ),
        "_base_integration_files": attr.label(
            cfg = "exec",
            allow_files = True,
            default = Label(
                "//xcodeproj/internal/bazel_integration_files:base_integration_files",
            ),
        ),
        "_bazel_build_script_template": attr.label(
            allow_single_file = True,
            default = Label(
                "//xcodeproj/internal/templates:bazel_build.sh",
            ),
        ),
        "_bazel_integration_files": attr.label(
            cfg = "exec",
            allow_files = True,
            default = Label("//xcodeproj/internal/bazel_integration_files"),
        ),
        "_contents_xcworkspacedata": attr.label(
            allow_single_file = True,
            default = Label(
                "//xcodeproj/internal/templates:contents.xcworkspacedata",
            ),
        ),
        "_create_xcode_overlay_script_template": attr.label(
            allow_single_file = True,
            default = Label(
                "//xcodeproj/internal/templates:create_xcode_overlay.sh",
            ),
        ),
        "_files_and_groups_generator": attr.label(
            cfg = "exec",
            default = Label(
                "//tools/generators/files_and_groups:universal_files_and_groups",
            ),
            executable = True,
        ),
        "_index_import": attr.label(
            cfg = "exec",
            default = Label("@rules_xcodeproj_index_import//:index_import"),
            executable = True,
        ),
        "_installer_template": attr.label(
            allow_single_file = True,
            default = Label("//xcodeproj/internal/templates:cat.installer.sh"),
        ),
        "_is_fixture": attr.bool(default = is_fixture),
        "_link_params_processor": attr.label(
            cfg = "exec",
            default = Label("//tools/params_processors:cat_link_params_processor"),
            executable = True,
        ),
        "_pbxnativetargets_generator": attr.label(
            cfg = "exec",
            default = Label(
                "//tools/generators/pbxnativetargets:universal_pbxnativetargets",
            ),
            executable = True,
        ),
        "_pbxproj_prefix_generator": attr.label(
            cfg = "exec",
            default = Label(
                "//tools/generators/pbxproj_prefix:universal_pbxproj_prefix",
            ),
            executable = True,
        ),
        "_pbxtargetdependencies_generator": attr.label(
            cfg = "exec",
            default = Label(
                "//tools/generators/pbxtargetdependencies:universal_pbxtargetdependencies",
            ),
            executable = True,
        ),
        "_selected_model_versions_generator": attr.label(
            cfg = "exec",
            default = Label(
                "//tools/generators/selected_model_versions",
            ),
            executable = True,
        ),
        "_xcode_config": attr.label(
            default = configuration_field(
                name = "xcode_config_label",
                fragment = "apple",
            ),
        ),
    }

    return rule(
        doc = "Creates an `.xcodeproj` file in the workspace when run.",
        cfg = xcodeproj_transition,
        implementation = _xcodeproj_impl,
        attrs = attrs,
        executable = True,
    )
