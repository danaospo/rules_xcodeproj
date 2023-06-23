"""Functions for processing library targets."""

load("@build_bazel_rules_swift//swift:swift.bzl", "SwiftInfo")
load("//xcodeproj/internal:build_settings.bzl", "get_product_module_name")
load("//xcodeproj/internal:configuration.bzl", "calculate_configuration")
load(":compilation_providers.bzl", comp_providers = "compilation_providers")
load(
    ":files.bzl",
    "join_paths_ignoring_empty",
)
load(":input_files.bzl", "input_files")
load(":linker_input_files.bzl", "linker_input_files")
load(":opts.bzl", "opts")
load(":output_files.bzl", "output_files")
load(":pbxproj_partials.bzl", "pbxproj_partials")
load(":platforms.bzl", "platforms")
load(":processed_target.bzl", "processed_target")
load(":product.bzl", "process_product")
load(":providers.bzl", "XcodeProjInfo")
load("//xcodeproj/internal:target_id.bzl", "get_id")
load(
    ":target_properties.bzl",
    "process_dependencies",
    "process_modulemaps",
)
load(":xcode_targets.bzl", "xcode_targets")

def process_library_target(
        *,
        ctx,
        build_mode,
        target,
        attrs,
        automatic_target_info,
        transitive_infos):
    """Gathers information about a library target.

    Args:
        ctx: The aspect context.
        build_mode: See `xcodeproj.build_mode`.
        target: The `Target` to process.
        attrs: `dir(ctx.rule.attr)` (as a performance optimization).
        automatic_target_info: The `XcodeProjAutomaticTargetProcessingInfo` for
            `target`.
        transitive_infos: A `list` of `depset`s of `XcodeProjInfo`s from the
            transitive dependencies of `target`.

    Returns:
        The value returned from `processed_target`.
    """
    configuration = calculate_configuration(bin_dir_path = ctx.bin_dir.path)
    label = target.label
    id = get_id(label = label, configuration = configuration)

    product_name = ctx.rule.attr.name
    # set_if_true(
    #     build_settings,
    #     "PRODUCT_MODULE_NAME",
    #     get_product_module_name(ctx = ctx, target = target),
    # )

    dependencies, transitive_dependencies = process_dependencies(
        build_mode = build_mode,
        transitive_infos = transitive_infos,
    )

    deps_infos = [
        dep[XcodeProjInfo]
        for attr in automatic_target_info.implementation_deps
        for dep in getattr(ctx.rule.attr, attr, [])
        if XcodeProjInfo in dep
    ]

    objc = target[apple_common.Objc] if apple_common.Objc in target else None
    swift_info = target[SwiftInfo] if SwiftInfo in target else None

    (
        compilation_providers,
        implementation_compilation_context,
        framework_includes,
    ) = comp_providers.collect(
        cc_info = target[CcInfo],
        objc = objc,
        is_xcode_target = True,
        transitive_implementation_providers = [
            info.compilation_providers
            for info in deps_infos
        ],
    )
    linker_inputs = linker_input_files.collect(
        target = target,
        automatic_target_info = automatic_target_info,
        compilation_providers = compilation_providers,
    )

    platform = platforms.collect(ctx = ctx)
    module_name_attribute, module_name = get_product_module_name(
        ctx = ctx,
        target = target,
    )

    product = process_product(
        ctx = ctx,
        target = target,
        product_name = product_name,
        # Value taken from `PRODUCT_TYPE_ENCODED` in `product.bzl`, for
        # `com.apple.product-type.library.static`
        product_type = "L",
        module_name = module_name,
        module_name_attribute = module_name_attribute,
        linker_inputs = linker_inputs,
    )

    modulemaps = process_modulemaps(swift_info = swift_info)
    (target_inputs, provider_inputs) = input_files.collect(
        ctx = ctx,
        target = target,
        attrs = attrs,
        id = id,
        platform = platform,
        is_bundle = False,
        product = product,
        linker_inputs = linker_inputs,
        automatic_target_info = automatic_target_info,
        modulemaps = modulemaps,
        transitive_infos = transitive_infos,
    )

    debug_outputs = target[apple_common.AppleDebugOutputs] if apple_common.AppleDebugOutputs in target else None
    output_group_info = target[OutputGroupInfo] if OutputGroupInfo in target else None
    (target_outputs, provider_outputs) = output_files.collect(
        ctx = ctx,
        debug_outputs = debug_outputs,
        id = id,
        inputs = target_inputs,
        output_group_info = output_group_info,
        swift_info = swift_info,
        transitive_infos = transitive_infos,
    )

    package_bin_dir = join_paths_ignoring_empty(
        ctx.bin_dir.path,
        label.workspace_root,
        label.package,
    )
    params = opts.collect_params(
        ctx = ctx,
        build_mode = build_mode,
        c_sources = target_inputs.c_sources,
        cxx_sources = target_inputs.cxx_sources,
        target = target,
        implementation_compilation_context = implementation_compilation_context,
        package_bin_dir = package_bin_dir,
    )

    compiler_build_settings = pbxproj_partials.write_compiler_build_settings(
        actions = ctx.actions,
        build_mode = build_mode,
        name = label.name,
        package_bin_dir = package_bin_dir,
        swift_args = params.swift_args,
        tool = ctx.executable._compiler_build_settings_generator,
    )

    return processed_target(
        dependencies = dependencies,
        inputs = provider_inputs,
        outputs = provider_outputs,
        platform = platform.platform,
        transitive_dependencies = transitive_dependencies,
        xcode_target = xcode_targets.make(
            configuration = configuration,
            dependencies = dependencies,
            id = id,
            inputs = target_inputs,
            label = label,
            outputs = target_outputs,
            compiler_build_settings_file = compiler_build_settings,
            package_bin_dir = package_bin_dir,
            params = params,
            platform = platform,
            product = product,
            transitive_dependencies = transitive_dependencies,
        ),
    )
