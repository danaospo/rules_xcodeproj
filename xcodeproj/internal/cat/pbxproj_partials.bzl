"""Actions for creating `PBXProj` partials."""

load("//xcodeproj/internal:memory_efficiency.bzl", "EMPTY_STRING")
load(":platforms.bzl", "PLATFORM_NAME")
load(
    "//xcodeproj/internal:pbxproj_partials.bzl",
    _pbxproj_partials = "pbxproj_partials",
)

# Utility

def _apple_platform_to_platform_name(platform):
    return PLATFORM_NAME[platform]

def _filter_external_file(file):
    if not file.owner.workspace_name:
        return None

    # Removing "external" prefix
    return "$(BAZEL_EXTERNAL){}".format(file.path[8:])

def _filter_external_file_path(file_path):
    if not file_path.startswith("external/"):
        return None

    # Removing "external" prefix
    return "$(BAZEL_EXTERNAL){}".format(file_path[8:])

def _filter_generated_file(file):
    if file.is_source:
        return None

    # Removing "bazel-out" prefix
    return "$(BAZEL_OUT){}".format(file.path[9:])

def _filter_generated_file_path(file_path):
    if not file_path.startswith("bazel-out/"):
        return None

    # Removing "bazel-out" prefix
    return "$(BAZEL_OUT){}".format(file_path[9:])

def _depset_len(d):
    return str(len(d.to_list()))

def _depset_to_list(d):
    return d.to_list()

def _identity(seq):
    return seq

# Partials

# enum of flags, mainly to ensure the strings are frozen and reused
_flags = struct(
    archs = "--archs",
    c_params = "--c-params",
    colorize = "--colorize",
    compiler_build_settings_files = "--compiler-build-settings-files",
    consolidation_map_output_paths = "--consolidation-map-output-paths",
    cxx_params = "--cxx-params",
    default_xcode_configuration = "--default-xcode-configuration",
    dependencies = "--dependencies",
    dependency_counts = "--dependency-counts",
    dsym_paths = "--dsym-paths",
    files_paths = "--file-paths",
    folder_paths = "--folder-paths",
    folder_resources = "--folder-resources",
    folder_resources_counts = "--folder-resources-counts",
    hdrs = "--hdrs",
    hdrs_counts = "--hdrs-counts",
    labels = "--labels",
    label_counts = "--label-counts",
    module_names = "--module-names",
    non_arc_srcs = "--non-arc-srcs",
    non_arc_srcs_counts = "--non-arc-srcs-counts",
    organization_name = "--organization-name",
    os_versions = "--os-versions",
    package_bin_dirs = "--package-bin-dirs",
    platforms = "--platforms",
    post_build_script = "--post-build-script",
    pre_build_script = "--pre-build-script",
    product_basenames = "--product-basenames",
    product_names = "--product-names",
    product_paths = "--product-paths",
    product_types = "--product-types",
    resources = "--resources",
    resources_counts = "--resources-counts",
    srcs = "--srcs",
    srcs_counts = "--srcs-counts",
    target_counts = "--target-counts",
    targets = "--targets",
    unit_test_hosts = "--unit-test-hosts",
    top_level_targets = "--top-level-targets",
    use_base_internationalization = "--use-base-internationalization",
    xcode_configuration_counts = "--xcode-configuration-counts",
    xcode_configurations = "--xcode-configurations",
)

def _write_compiler_build_settings(
        *,
        actions,
        build_mode,
        name,
        package_bin_dir,
        swift_args,
        tool):
    """Creates the `OTHER_SWIFT_FLAGS` build setting string file for a target.

    Args:
        actions: `ctx.actions`.
        build_mode: See `xcodeproj.build_mode`.
        name: The name of the target.
        package_bin_dir: The package directory for the target within
            `ctx.bin_dir`.
        swift_args: A `list` of `Args` for the `SwiftCompile` action for this
            target.
        tool: The executable that will generate the output files.

    Returns:
        A `file` containing the `OTHER_SWIFT_FLAGS` build setting string for
        the target, or `None` if `swift_args` is empty.
    """
    if not swift_args:
        return None

    output = actions.declare_file(
        "{}.rules_xcodeproj.compiler_build_settings".format(name),
    )

    args = actions.args()
    args.add(output)
    args.add(build_mode)
    args.add(package_bin_dir)

    actions.run(
        arguments = [args] + swift_args,
        executable = tool,
        outputs = [output],
        progress_message = "Generating %{output}",
        mnemonic = "WriteOtherSwiftFlags",
    )

    return output

def _write_targets(
        *,
        actions,
        build_mode,
        consolidation_maps,
        default_xcode_configuration,
        generator_name,
        hosted_targets,
        install_path,
        link_params,
        tool,
        xcode_target_configurations,
        xcode_targets,
        xcode_targets_by_label):
    """Creates `File`s representing targets in a `PBXProj` element.

    Args:
        actions: `ctx.actions`.
        build_mode: See `xcodeproj.build_mode`.
        consolidation_maps: A `dict` mapping `File`s containing target
            consolidation maps to a `list` of `Label`s of the targets included
            in the map.
        default_xcode_configuration: The name of the the Xcode configuration to
            use when building, if not overridden by custom schemes.
        generator_name: The name of the `xcodeproj` generator target.
        hosted_targets: A `depset` of `struct`s with `host` and `hosted` fields.
            The `host` field is the target ID of the hosting target. The
            `hosted` field is the target ID of the hosted target.
        install_path: The workspace relative path to where the final
            `.xcodeproj` will be written.
        link_params: A `dict` mapping `xcode_target.id` to a `link.params` file
            for that target, if one is needed.
        tool: The executable that will generate the output files.
        xcode_target_configurations: A `dict` mapping `xcode_target.id` to a
            `list` of Xcode configuration names that the target is present in.
        xcode_targets: A `dict` mapping `xcode_target.id` to `xcode_target`s.
        xcode_targets_by_label: A `dict` mapping `xcode_target.label` to a
            `dict` mapping `xcode_target.id` to `xcode_target`s.

    Returns:
        A tuple with three elements:

        *   `pbxnativetargets`: A `list` of `File`s for the `PBNativeTarget`
            `PBXProj` partials.
        *   `buildfile_subidentifiers_files`: A `list` of `File`s that contain
            serialized `[Identifiers.BuildFile.SubIdentifier]`s.
        *   `automatic_xcschemes`: A `list` of `File`s for automatically
            generated `.xcscheme`s.
    """
    pbxnativetargets = []
    buildfile_subidentifiers_files = []
    automatic_xcschemes = []
    for consolidation_map, labels in consolidation_maps.items():
        (
            label_pbxnativetargets,
            label_buildfile_subidentifiers,
            label_automatic_xcschemes,
        ) = _write_consolidation_map_targets(
            actions = actions,
            build_mode = build_mode,
            consolidation_map = consolidation_map,
            default_xcode_configuration = default_xcode_configuration,
            generator_name = generator_name,
            hosted_targets = hosted_targets,
            idx = consolidation_map.basename,
            install_path = install_path,
            labels = labels,
            link_params = link_params,
            map_unit_test_hosts = _create_map_unit_test_hosts(xcode_targets),
            tool = tool,
            xcode_target_configurations = xcode_target_configurations,
            xcode_targets_by_label = xcode_targets_by_label,
        )

        pbxnativetargets.append(label_pbxnativetargets)
        buildfile_subidentifiers_files.append(label_buildfile_subidentifiers)
        automatic_xcschemes.append(label_automatic_xcschemes)

    return (
        pbxnativetargets,
        buildfile_subidentifiers_files,
        automatic_xcschemes,
    )

# # TODO: Verify we want to do this, versus popping the depset and creating the
# # list at analysis. This retains the created `target_ids` in memory, which might
# # not be the tradeoff we want to do.
# def _create_map_hosted_targets(labels, xcode_targets_by_label):
#     target_ids = {
#         id: None
#         for label in labels
#         for id in xcode_targets_by_label[label]
#     }

#     def _map_hosted_targets(hosted_target):
#         if hosted_target.hosted in target_ids:
#             return [hosted_target.hosted, hosted_target.host]
#         return None

#     return _map_hosted_targets

def _create_map_unit_test_hosts(xcode_targets):
    def _map_unit_test_hosts(id):
        test_host = xcode_targets[id]
        if not test_host:
            fail("""\
Target ID for unit test host '{}' not found in xcode_targets""".format(id))
        return [
            id,
            # packageBinDir
            test_host.package_bin_dir,
            # productPath
            test_host.product.file_path,
            # executableName
            test_host.product.executable_name or test_host.product.name,
        ]

    return _map_unit_test_hosts

def _dsym_files_to_string(dsym_files):
    dsym_paths = []
    for file in dsym_files.to_list():
        file_path = file.path

        # dSYM files contain plist and DWARF.
        if not file_path.endswith("Info.plist"):
            # ../Product.dSYM/Contents/Resources/DWARF/Product
            dsym_path = "/".join(file_path.split("/")[:-4])
            dsym_paths.append("\"{}\"".format(dsym_path))
    return " ".join(dsym_paths)

def _paths(files):
    return [file.path for file in files]

_UNIT_TEST_PRODUCT_TYPE = "com.apple.product-type.bundle.unit-test"

def _write_consolidation_map_targets(
        *,
        actions,
        build_mode,
        consolidation_map,
        default_xcode_configuration,
        generator_name,
        hosted_targets,
        idx,
        install_path,
        labels,
        link_params,
        map_unit_test_hosts,
        tool,
        xcode_target_configurations,
        xcode_targets_by_label):
    """Creates `File`s representing targets in a `PBXProj` element, for a \
    given consolidation map

    Args:
        actions: `ctx.actions`.
        build_mode: See `xcodeproj.build_mode`.
        consolidation_map: A `File` containing a target consolidation maps.
        default_xcode_configuration: The name of the the Xcode configuration to
            use when building, if not overridden by custom schemes.
        generator_name: The name of the `xcodeproj` generator target.
        hosted_targets: A `depset` of `struct`s with `host` and `hosted` fields.
            The `host` field is the target ID of the hosting target. The
            `hosted` field is the target ID of the hosted target.
        idx: The index of the consolidation map.
        install_path: The workspace relative path to where the final
            `.xcodeproj` will be written.
        link_params: A `dict` mapping `xcode_target.id` to a `link.params` file
            for that target, if one is needed.
        labels: A `list` of `Label`s of the targets included in
            `consolidation_map`.
        map_unit_test_hosts: A function that maps a unit test host target ID to
            a `list` of `str`s containing the unit test host target ID, package
            bin dir, product path, and executable name.
        tool: The executable that will generate the output files.
        xcode_target_configurations: A `dict` mapping `xcode_target.id` to a
            `list` of Xcode configuration names that the target is present in.
        xcode_targets_by_label: A `dict` mapping `xcode_target.label` to a
            `dict` mapping `xcode_target.id` to `xcode_target`s.

    Returns:
        A tuple with three elements:

        *   `pbxnativetargets`: A `File` for the `PBNativeTarget` `PBXProj`
            partial.
        *   `buildfile_subidentifiers`: A `File` that contain serialized
            `[Identifiers.BuildFile.SubIdentifier]`.
        *   `automatic_xcschemes`: A `File` for the directory containing
            automatically generated `.xcscheme`s.
    """
    pbxnativetargets = actions.declare_file(
        "{}_pbxproj_partials/pbxnativetargets/{}".format(
            generator_name,
            idx,
        ),
    )
    buildfile_subidentifiers = actions.declare_file(
        "{}_pbxproj_partials/buildfile_subidentifiers/{}".format(
            generator_name,
            idx,
        ),
    )
    automatic_xcschemes = actions.declare_directory(
        "{}_pbxproj_partials/automatic_xcschemes/{}".format(
            generator_name,
            idx,
        ),
    )

    is_bwb = build_mode == "bazel"

    args = actions.args()
    args.use_param_file("@%s")
    args.set_param_file_format("multiline")

    # targetsOutputPath
    args.add(pbxnativetargets)

    # buildFileSubIdentifiersOutputPath
    args.add(buildfile_subidentifiers)

    # xcshemesOutputDirectory
    args.add(automatic_xcschemes.path)

    # consolidationMap
    args.add(consolidation_map)

    # buildMode
    args.add(build_mode)

    # defaultXcodeConfiguration
    args.add(default_xcode_configuration)

    # Will need for xcschemes
    # # hostedTargets
    # args.add_all(
    #     _flags.target_and_hosts,
    #     hosted_targets,
    #     allow_closure = True,
    #     map_each = _create_map_hosted_targets(
    #         labels = labels,
    #         xcode_targets_by_label = xcode_targets_by_label,
    #     ),
    # )

    archs = []
    dsym_files = []
    folder_resources = []
    folder_resources_counts = []
    hdrs = []
    hdrs_counts = []
    module_names = []
    non_arc_srcs = []
    non_arc_srcs_counts = []
    os_versions = []
    compiler_build_settings_paths = []
    compiler_build_settings_files = []
    package_bin_dirs = []
    platforms = []
    product_basenames = []
    product_names = []
    product_paths = []
    product_types = []
    resources = []
    resources_counts = []
    srcs = []
    srcs_counts = []
    target_ids = []
    top_level_target_attributes = []
    unit_test_host_ids = []
    xcode_configuration_counts = []
    xcode_configurations = []
    for label in labels:
        for xcode_target in xcode_targets_by_label[label].values():
            target_ids.append(xcode_target.id)
            product_types.append(xcode_target.product.type)
            package_bin_dirs.append(xcode_target.package_bin_dir)
            product_names.append(xcode_target.product.name)
            product_paths.append(xcode_target.product.file_path)
            product_basenames.append(xcode_target.product.basename)
            module_names.append(xcode_target.product.module_name or "")
            platforms.append(xcode_target.platform.platform)
            os_versions.append(xcode_target.platform.os_version)
            archs.append(xcode_target.platform.arch)
            srcs_counts.append(len(xcode_target.inputs.srcs))
            srcs.append(xcode_target.inputs.srcs)
            non_arc_srcs_counts.append(len(xcode_target.inputs.non_arc_srcs))
            non_arc_srcs.append(xcode_target.inputs.non_arc_srcs)
            hdrs_counts.append(len(xcode_target.inputs.hdrs))
            hdrs.append(xcode_target.inputs.hdrs)
            resources_counts.append(xcode_target.inputs.resources)
            resources.append(xcode_target.inputs.resources)
            folder_resources_counts.append(xcode_target.inputs.folder_resources)
            folder_resources.append(xcode_target.inputs.folder_resources)
            dsym_files.append(xcode_target.outputs.dsym_files)

            if (xcode_target.test_host and
                xcode_target.product.type == _UNIT_TEST_PRODUCT_TYPE):
                unit_test_host = xcode_target.test_host
                unit_test_host_ids.append(unit_test_host)
            else:
                unit_test_host = EMPTY_STRING

            target_link_params = link_params.get(xcode_target.id, EMPTY_STRING)

            # FIXME: Extract to a single type, for easier checking/setting?
            if (is_bwb or target_link_params or unit_test_host or
                # xcode_target._compile_targets or
                xcode_target.inputs.entitlements or
                xcode_target.product.executable_name):
                top_level_target_attributes.extend([
                    xcode_target.id,
                    xcode_target.outputs.product_path or EMPTY_STRING,
                    target_link_params,
                    xcode_target.inputs.entitlements or EMPTY_STRING,
                    xcode_target.product.executable_name or EMPTY_STRING,
                    # FIXME: compileTargetName
                    EMPTY_STRING,
                    # FIXME: compileTargetIDs
                    EMPTY_STRING,
                    unit_test_host,
                ])

            compiler_build_settings_file = (
                xcode_target.compiler_build_settings_file
            )
            compiler_build_settings_paths.append(
                compiler_build_settings_file or EMPTY_STRING
            )
            if compiler_build_settings_file:
                compiler_build_settings_files.append(
                    compiler_build_settings_file
                )

            # args.add_all(
            #     _flags.swift_params,
            #     xcode_target.params.swift_raw_params,
            # )
            # inputs.extend(xcode_target.params.swift_raw_params)

            # args.add_all(_flags.c_params, xcode_target.params.c_raw_params)
            # inputs.extend(xcode_target.params.c_raw_params)

            # args.add_all(_flags.cxx_params, xcode_target.params.cxx_raw_params)
            # inputs.extend(xcode_target.params.cxx_raw_params)

            configurations = xcode_target_configurations[xcode_target.id]
            xcode_configuration_counts.append(len(configurations))
            xcode_configurations.append(configurations)

    # topLevelTargets
    args.add_all(_flags.top_level_targets, top_level_target_attributes)

    # unitTestHosts
    args.add_all(
        _flags.unit_test_hosts,
        unit_test_host_ids,
        allow_closure = True,
        map_each = map_unit_test_hosts,
    )

    # targets
    args.add_all(_flags.targets, target_ids)

    # xcodeConfigurationCounts
    args.add_all(
        _flags.xcode_configuration_counts,
        xcode_configuration_counts,
    )

    # xcodeConfigurations
    args.add_all(
        _flags.xcode_configurations,
        xcode_configurations,
        map_each = _identity,
    )

    # productTypes
    args.add_all(_flags.product_types, product_types)

    # packageBinDirs
    args.add_all(_flags.package_bin_dirs, package_bin_dirs)

    # productNames
    args.add_all(_flags.product_names, product_names)

    # productPaths
    args.add_all(_flags.product_paths, product_paths)

    # productBasenames
    args.add_all(_flags.product_basenames, product_basenames)

    # moduleNames
    args.add_all(_flags.module_names, module_names)

    # platforms
    args.add_all(
        _flags.platforms,
        platforms,
        map_each = _apple_platform_to_platform_name,
    )

    # osVersions
    args.add_all(_flags.os_versions, os_versions)

    # archs
    args.add_all(_flags.archs, archs)

    # compilerBuildSettingsFiles
    args.add_all(
        _flags.compiler_build_settings_files,
        compiler_build_settings_paths,
    )

    has_srcs = False
    for srcs_count in srcs_counts:
        if srcs_count > 0:
            has_srcs = True
            break
    if has_srcs:
        # srcsCounts
        args.add_all(_flags.srcs_counts, srcs_counts)

        # srcs
        args.add_all(_flags.srcs, srcs, map_each = _paths)

    has_non_arc_srcs = False
    for non_arc_srcs_count in non_arc_srcs_counts:
        if non_arc_srcs_count > 0:
            has_non_arc_srcs = True
            break
    if has_non_arc_srcs:
        # nonArcSrcsCounts
        args.add_all(_flags.non_arc_srcs_counts, non_arc_srcs_counts)

        # nonArcSrcs
        args.add_all(_flags.non_arc_srcs, non_arc_srcs, map_each = _paths)

    has_hdrs = False
    for hdrs_count in hdrs_counts:
        if hdrs_count > 0:
            has_hdrs = True
            break
    if has_hdrs:
        # hdrsCounts
        args.add_all(_flags.hdrs_counts, hdrs_counts)

        # hdrs
        args.add_all(_flags.hdrs, hdrs, map_each = _paths)

    # resourcesCounts
    args.add_all(
        _flags.resources_counts,
        resources_counts,
        map_each = _depset_len,
    )

    # resources
    args.add_all(
        _flags.resources,
        resources,
        map_each = _depset_to_list,
    )

    # folderResourcesCounts
    args.add_all(
        _flags.folder_resources_counts,
        folder_resources_counts,
        map_each = _depset_len,
    )

    # folderResources
    args.add_all(
        _flags.folder_resources,
        folder_resources,
        map_each = _depset_to_list,
    )

    # dsymPaths
    args.add_all(
        _flags.dsym_paths,
        dsym_files,
        map_each = _dsym_files_to_string,
    )

    message = "Generating {} PBXNativeTargets partials (shard {})".format(
        install_path,
        idx,
    )

    actions.run(
        arguments = [args],
        executable = tool,
        inputs = [consolidation_map] + compiler_build_settings_files,
        outputs = [
            pbxnativetargets,
            buildfile_subidentifiers,
            automatic_xcschemes,
        ],
        progress_message = message,
        mnemonic = "WritePBXNativeTargets",
        execution_requirements = {
            # Lots of files to read, so lets have some speed
            "no-sandbox": "1",
        },
    )

    return (
        pbxnativetargets,
        buildfile_subidentifiers,
        automatic_xcschemes,
    )

# `project.pbxproj`

def _write_project_pbxproj(
        *,
        actions,
        files_and_groups,
        generator_name,
        pbxproj_prefix,
        pbxproject_targets,
        pbxproject_known_regions,
        pbxproject_target_attributes,
        pbxtargetdependencies,
        targets):
    """Creates a `project.pbxproj` `File`.

    Args:
        actions: `ctx.actions`.
        files_and_groups: The `files_and_groups` `File` returned from
            `pbxproj_partials.write_files_and_groups`.
        generator_name: The name of the `xcodeproj` generator target.
        pbxproj_prefix: The `File` returned from
            `pbxproj_partials.write_pbxproj_prefix`.
        pbxproject_known_regions: The `known_regions` `File` returned from
            `pbxproj_partials.write_known_regions`.
        pbxproject_target_attributes: The `pbxproject_target_attributes` `File` returned from
            `pbxproj_partials.write_pbxproject_targets`.
        pbxproject_targets: The `pbxproject_targets` `File` returned from
            `pbxproj_partials.write_pbxproject_targets`.
        pbxtargetdependencies: The `pbxtargetdependencies` `Files` returned from
            `pbxproj_partials.write_pbxproject_targets`.
        targets: The `targets` `list` of `Files` returned from
            `pbxproj_partials.write_targets`.

    Returns:
        A `project.pbxproj` `File`.
    """
    output = actions.declare_file("{}.project.pbxproj".format(generator_name))

    inputs = [
        pbxproj_prefix,
        pbxproject_target_attributes,
        pbxproject_known_regions,
        pbxproject_targets,
    ] + targets + [
        pbxtargetdependencies,
        files_and_groups,
    ]

    args = actions.args()
    args.use_param_file("%s")
    args.set_param_file_format("multiline")
    args.add_all(inputs)

    actions.run_shell(
        arguments = [args],
        inputs = inputs,
        outputs = [output],
        command = """\
cat "$@" > {output}
""".format(output = output.path),
        mnemonic = "WriteXcodeProjPBXProj",
        progress_message = "Generating %{output}",
        execution_requirements = {
            # Absolute paths
            "no-remote": "1",
            # Each file is directly referenced, so lets have some speed
            "no-sandbox": "1",
        },
    )

    return output

def _write_xcfilelists(*, actions, files, file_paths, generator_name):
    external_args = actions.args()
    external_args.set_param_file_format("multiline")
    external_args.add_all(
        files,
        map_each = _filter_external_file,
    )
    external_args.add_all(
        file_paths,
        map_each = _filter_external_file_path,
    )

    external = actions.declare_file(
        "{}-xcfilelists/external.xcfilelist".format(generator_name),
    )
    actions.write(external, external_args)

    generated_args = actions.args()
    generated_args.set_param_file_format("multiline")
    generated_args.add_all(
        files,
        map_each = _filter_generated_file,
    )
    generated_args.add_all(
        file_paths,
        map_each = _filter_generated_file_path,
    )

    generated = actions.declare_file(
        "{}-xcfilelists/generated.xcfilelist".format(generator_name),
    )
    actions.write(generated, generated_args)

    return [external, generated]

pbxproj_partials = struct(
    write_files_and_groups = _pbxproj_partials.write_files_and_groups,
    write_compiler_build_settings = _write_compiler_build_settings,
    write_project_pbxproj = _write_project_pbxproj,
    write_pbxproj_prefix = _pbxproj_partials.write_pbxproj_prefix,
    write_pbxtargetdependencies = _pbxproj_partials.write_pbxtargetdependencies,
    write_targets = _write_targets,
    write_xcfilelists = _write_xcfilelists,
)
