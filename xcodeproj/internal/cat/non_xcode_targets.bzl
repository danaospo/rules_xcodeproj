"""Functions for processing non-Xcode targets."""

load("@build_bazel_rules_swift//swift:swift.bzl", "SwiftInfo")
load(":compilation_providers.bzl", comp_providers = "compilation_providers")
load(":linker_input_files.bzl", "linker_input_files")
load(":input_files.bzl", "input_files")
load(":output_files.bzl", "output_files")
load(":processed_target.bzl", "processed_target")
load(
    ":target_properties.bzl",
    "process_dependencies",
)

def process_non_xcode_target(
        *,
        ctx,
        target,
        attrs,
        automatic_target_info,
        transitive_infos):
    """Gathers information about a non-Xcode target.

    Args:
        ctx: The aspect context.
        target: The `Target` to process.
        attrs: `dir(ctx.rule.attr)` (as a performance optimization).
        automatic_target_info: The `XcodeProjAutomaticTargetProcessingInfo` for
            `target`.
        transitive_infos: A `list` of `depset`s of `XcodeProjInfo`s from the
            transitive dependencies of `target`.

    Returns:
        The value returned from `processed_target`.
    """
    dependencies, transitive_dependencies = process_dependencies(
        build_mode = ctx.attr._build_mode,
        transitive_infos = transitive_infos,
    )

    cc_info = target[CcInfo] if CcInfo in target else None
    objc = target[apple_common.Objc] if apple_common.Objc in target else None
    swift_info = target[SwiftInfo] if SwiftInfo in target else None

    (
        compilation_providers,
        _,
        _,
    ) = comp_providers.collect(
        cc_info = cc_info,
        objc = objc,
        is_xcode_target = False,
        # Since we don't use the returned `implementation_compilation_context`,
        # we can pass `[]` here
        transitive_implementation_providers = [],
    )
    linker_inputs = linker_input_files.collect(
        target = target,
        automatic_target_info = automatic_target_info,
        compilation_providers = compilation_providers,
    )

    (_, provider_inputs) = input_files.collect(
        ctx = ctx,
        target = target,
        attrs = attrs,
        unfocused = None,
        id = None,
        platform = None,
        is_bundle = False,
        product = None,
        linker_inputs = linker_inputs,
        automatic_target_info = automatic_target_info,
        transitive_infos = transitive_infos,
    )

    (_, provider_outputs) = output_files.merge(
        transitive_infos = transitive_infos,
    )

    return processed_target(
        dependencies = dependencies,
        inputs = provider_inputs,
        outputs = provider_outputs,
        transitive_dependencies = transitive_dependencies,
        xcode_target = None,
    )
