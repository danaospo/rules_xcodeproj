"""Module containing functions dealing with the `xcode_target` data \
structure."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load(
    "//xcodeproj/internal:memory_efficiency.bzl",
    "EMPTY_DEPSET",
    "EMPTY_LIST",
)

# `xcode_target`

def _make_xcode_target(
        *,
        configuration,
        dependencies,
        id,
        inputs,
        label,
        linker_inputs = None,
        outputs,
        package_bin_dir,
        params,
        platform,
        product,
        compiler_build_settings_file = None,
        test_host = None,
        transitive_dependencies):
    """Creates the internal data structure of the `xcode_targets` module.

    Args:
        configuration: The configuration of the `Target`.
        dependencies: A `depset` of `id`s of targets that this target depends
            on.
        id: A unique identifier. No two Xcode targets will have the same `id`.
            This won't be user facing, the generator will use other fields to
            generate a unique name for a target.
        label: The `Label` of the `Target`.
        package_bin_dir: The package directory for the `Target` within
            `ctx.bin_dir`.
        compiler_build_settings_file: A `file` containing the `OTHER_SWIFT_FLAGS`
            build setting string for the target, or `None` if the target doesn't
            compile Swift code.
        transitive_dependencies: A `depset` of `id`s of all transitive targets
            that this target depends on.
    """

    return struct(
        configuration = configuration,
        dependencies = dependencies,
        id = id,
        inputs = _to_xcode_target_inputs(inputs),
        label = label,
        linker_inputs = _to_xcode_target_linker_inputs(linker_inputs),
        outputs = _to_xcode_target_outputs(outputs),
        compiler_build_settings_file = compiler_build_settings_file,
        package_bin_dir = package_bin_dir,
        # params = params,
        platform = platform,
        product = product,
        test_host = test_host,
        transitive_dependencies = transitive_dependencies,
    )

def _to_xcode_target_inputs(inputs):
    return struct(
        entitlements = inputs.entitlements,
        folder_resources = inputs.folder_resources,
        hdrs = tuple(inputs.hdrs),
        non_arc_srcs = tuple(inputs.non_arc_srcs),
        resources = inputs.resources,
        # TODO: Get these as non-flattened lists, to prevent processing/list creation?
        srcs = tuple(inputs.srcs),
    )

def _to_xcode_target_linker_inputs(linker_inputs):
    if not linker_inputs:
        return None

    top_level_values = linker_inputs._top_level_values
    if not top_level_values:
        return None

    return struct(
        link_args = top_level_values.link_args,
        link_args_inputs = top_level_values.link_args_inputs,
    )

def _to_xcode_target_outputs(outputs):
    direct_outputs = outputs.direct_outputs

    swift_generated_header = None
    if direct_outputs:
        swift = direct_outputs.swift
        if swift:
            if swift.generated_header:
                swift_generated_header = swift.generated_header

    return struct(
        dsym_files = (
            (direct_outputs.dsym_files if direct_outputs else None) or EMPTY_DEPSET
        ),
        product_path = (
            direct_outputs.product_path if direct_outputs else None
        ),
        swift_generated_header = swift_generated_header,
    )

# Other

def _create_single_link_params(
        *,
        actions,
        generator_name,
        link_params_processor,
        params_index,
        xcode_target):
    linker_inputs = xcode_target.linker_inputs

    if not linker_inputs:
        return None

    link_args = linker_inputs.link_args

    if not link_args:
        return None

    name = xcode_target.label.name

    link_params = actions.declare_file(
        "{}-params/{}.{}.link.params".format(
            generator_name,
            name,
            params_index,
        ),
    )

    # FIXME: collect compile_targets
    compile_targets = None

    if compile_targets:
        self_product_paths = [
            compile_target.product.file.path
            for compile_target in compile_targets
            if compile_target.product.file
        ]
    else:
        # Handle `{cc,swift}_{binary,test}` with `srcs` case
        self_product_paths = [
            paths.join(
                xcode_target.product.package_dir,
                "lib{}.lo".format(name),
            ),
        ]

    generated_product_paths_file = actions.declare_file(
        "{}-params/{}.{}.generated_product_paths_file.json".format(
            generator_name,
            name,
            params_index,
        ),
    )
    actions.write(
        output = generated_product_paths_file,
        content = json.encode(self_product_paths),
    )

    is_framework = (
        xcode_target.product.type == "com.apple.product-type.framework"
    )

    args = actions.args()
    args.add(link_params)
    args.add(generated_product_paths_file)
    args.add("1" if is_framework else "0")

    actions.run(
        executable = link_params_processor,
        arguments = [args] + link_args,
        mnemonic = "ProcessLinkParams",
        progress_message = "Generating %{output}",
        inputs = (
            [generated_product_paths_file] +
            list(linker_inputs.link_args_inputs)
        ),
        outputs = [link_params],
    )

    return link_params

def _create_link_params(
        *,
        actions,
        generator_name,
        link_params_processor,
        xcode_targets):
    """Creates the `link_params` for each `xcode_target`.

    Args:
        actions: `ctx.actions`.
        generator_name: The name of the `xcodeproj` generator target.
        link_params_processor: Executable to process the link params.
        xcode_targets: A `dict` mapping `xcode_target.id` to `xcode_target`s.

    Returns:
        A `dict` mapping `xcode_target.id` to a `link.params` file for that
        target, if one is needed.
    """
    link_params = {}
    for idx, xcode_target in enumerate(xcode_targets.values()):
        a_link_params = _create_single_link_params(
            actions = actions,
            generator_name = generator_name,
            link_params_processor = link_params_processor,
            params_index = idx,
            xcode_target = xcode_target,
        )
        if a_link_params:
            link_params[xcode_target.id] = a_link_params

    return link_params

def _dicts_from_xcode_configurations(*, infos_per_xcode_configuration):
    """Creates `xcode_target`s `dicts` from multiple Xcode configurations.

    Args:
        infos_per_xcode_configuration: A `dict` mapping Xcode configuration
            names to a `list` of `XcodeProjInfo`s.

    Returns:
        A `tuple` with three elements:

        *   A `dict` mapping `xcode_target.id` to `xcode_target`s.
        *   A `dict` mapping `xcode_target.label` to a `dict` mapping
            `xcode_target.id` to `xcode_target`s.
        *   A `dict` mapping `xcode_target.id` to a `list` of Xcode
            configuration names that the target is present in.
    """
    xcode_targets = {}
    xcode_targets_by_label = {}
    xcode_target_configurations = {}
    for xcode_configuration, infos in infos_per_xcode_configuration.items():
        configuration_xcode_targets = {
            xcode_target.id: xcode_target
            for xcode_target in depset(
                transitive = [info.xcode_targets for info in infos],
            ).to_list()
        }
        xcode_targets.update(configuration_xcode_targets)
        for xcode_target in configuration_xcode_targets.values():
            id = xcode_target.id
            xcode_targets_by_label.setdefault(xcode_target.label, {})[id] = (
                xcode_target
            )
            xcode_target_configurations.setdefault(id, []).append(
                xcode_configuration,
            )

    return (xcode_targets, xcode_targets_by_label, xcode_target_configurations)

xcode_targets = struct(
    create_link_params = _create_link_params,
    dicts_from_xcode_configurations = _dicts_from_xcode_configurations,
    make = _make_xcode_target,
)
