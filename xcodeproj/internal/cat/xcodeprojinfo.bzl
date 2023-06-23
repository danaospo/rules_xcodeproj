"""Functions for creating `XcodeProjInfo` providers."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(
    "@build_bazel_rules_apple//apple:providers.bzl",
    "AppleBinaryInfo",
    "AppleBundleInfo",
)
load(":automatic_target_info.bzl", "calculate_automatic_target_info")
load("//xcodeproj/internal:bazel_labels.bzl", "bazel_labels")
load(":input_files.bzl", "input_files")
load(":library_targets.bzl", "process_library_target")
load(
    "//xcodeproj/internal:memory_efficiency.bzl",
    "NONE_LIST",
    "memory_efficient_depset",
)
load(":non_xcode_targets.bzl", "process_non_xcode_target")
load(":output_files.bzl", "output_files")
load(
    ":providers.bzl",
    "XcodeProjInfo",
    "target_type",
)
load(":processed_target.bzl", "processed_target")
load(":targets.bzl", "targets")
load(
    ":target_properties.bzl",
    "process_dependencies",
)
load(":top_level_targets.bzl", "process_top_level_target")

# Creating `XcodeProjInfo`

_INTERNAL_RULE_KINDS = {
    "apple_cc_toolchain": None,
    "apple_mac_tools_toolchain": None,
    "apple_xplat_tools_toolchain": None,
    "armeabi_cc_toolchain_config": None,
    "filegroup": None,
    "cc_toolchain": None,
    "cc_toolchain_alias": None,
    "cc_toolchain_suite": None,
    "macos_test_runner": None,
    "xcode_swift_toolchain": None,
}

_TOOLS_REPOS = {
    "build_bazel_rules_apple": None,
    "build_bazel_rules_swift": None,
    "bazel_tools": None,
    "xctestrunner": None,
}

# Just a slight optimization to not process things we know don't need to have
# out provider.
def _should_create_provider(*, ctx, target):
    if BuildSettingInfo in target:
        return False
    if target.label.workspace_name in _TOOLS_REPOS:
        return False
    if ctx.rule.kind in _INTERNAL_RULE_KINDS:
        return False
    return True

_BUILD_TEST_RULES = {
    "ios_build_test": None,
    "macos_build_test": None,
    "tvos_build_test": None,
    "watchos_build_test": None,
}

_TEST_SUITE_RULES = {
    "test_suite": None,
}

skip_type = struct(
    apple_build_test = "apple_build_test",
    apple_binary_no_deps = "apple_binary_no_deps",
    apple_test_bundle = "apple_test_bundle",
    test_suite = "test_suite",
)

def _get_skip_type(*, ctx, target):
    """Determines if the given target should be skipped for target generation.

    There are some rules, like the test runners for iOS tests, that we want to
    ignore. Nothing from those rules are considered.

    Args:
        ctx: The aspect context.
        target: The `Target` to check.

    Returns:
        A `skip_type` if `target` should be skipped, otherwise `None`.
    """
    if ctx.rule.kind in _BUILD_TEST_RULES:
        return skip_type.apple_build_test

    if ctx.rule.kind in _TEST_SUITE_RULES:
        return skip_type.test_suite

    if AppleBinaryInfo in target and not hasattr(ctx.rule.attr, "deps"):
        return skip_type.apple_binary_no_deps

    if targets.is_test_bundle(
        target = target,
        deps = getattr(ctx.rule.attr, "deps", None),
    ):
        return skip_type.apple_test_bundle

    return None

def _target_info_fields(
        *,
        dependencies,
        hosted_targets,
        inputs,
        non_top_level_rule_kind,
        outputs,
        platforms,
        replacement_labels,
        target_type,
        transitive_dependencies,
        xcode_target,
        xcode_targets):
    """Generates target specific fields for the `XcodeProjInfo`.

    This should be merged with other fields to fully create an `XcodeProjInfo`.

    Args:
        dependencies: Maps to the `XcodeProjInfo.dependencies` field.
        hosted_targets: Maps to the `XcodeProjInfo.hosted_targets` field.
        inputs: Maps to the `XcodeProjInfo.inputs` field.
        non_top_level_rule_kind: Maps to the
            `XcodeProjInfo.non_top_level_rule_kind` field.
        outputs: Maps to the `XcodeProjInfo.outputs` field.
        platforms: Maps to the `XcodeProjInfo.platforms` field.
        replacement_labels: Maps to the `XcodeProjInfo.replacement_labels`
            field.
        target_type: Maps to the `XcodeProjInfo.target_type` field.
        transitive_dependencies: Maps to the
            `XcodeProjInfo.transitive_dependencies` field.
        xcode_target: Maps to the `XcodeProjInfo.xcode_target` field.
        xcode_targets: Maps to the `XcodeProjInfo.xcode_targets` field.

    Returns:
        A `dict` containing the following fields:

        *   `dependencies`
        *   `hosted_targets`
        *   `inputs`
        *   `non_top_level_rule_kind`
        *   `outputs`
        *   `platforms`
        *   `replacement_labels`
        *   `target_type`
        *   `transitive_dependencies`
        *   `xcode_target`
        *   `xcode_targets`
    """
    return {
        "dependencies": dependencies,
        "hosted_targets": hosted_targets,
        "inputs": inputs,
        "non_top_level_rule_kind": non_top_level_rule_kind,
        "outputs": outputs,
        "platforms": platforms,
        "replacement_labels": replacement_labels,
        "target_type": target_type,
        "transitive_dependencies": transitive_dependencies,
        "xcode_target": xcode_target,
        "xcode_targets": xcode_targets,
    }

def _skip_target(
        *,
        ctx,
        build_mode,
        target,
        target_skip_type,
        deps,
        deps_attrs,
        transitive_infos,
        automatic_target_info):
    """Passes through existing target info fields, not collecting new ones.

    Merges `XcodeProjInfo`s for the dependencies of the current target, and
    forwards them on, not collecting any information for the current target.

    Args:
        ctx: The aspect context.
        build_mode: See `xcodeproj.build_mode`.
        target: The `Target` to skip.
        deps: `Target`s collected from `ctx.attr.deps`.
        deps_attrs: A sequence of attribute names to collect `Target`s from for
            `deps`-like attributes.
        transitive_infos: A `list` of `depset`s of `XcodeProjInfo`s from the
            transitive dependencies of the target.
        automatic_target_info: The `XcodeProjAutomaticTargetProcessingInfo` for
            `target`.

    Returns:
        The return value of `_target_info_fields`, with values merged from
        `transitive_infos`.
    """
    valid_transitive_infos = [
        info
        for _, info in transitive_infos
    ]

    dependencies, transitive_dependencies = process_dependencies(
        build_mode = build_mode,
        transitive_infos = valid_transitive_infos,
    )

    (_, provider_outputs) = output_files.merge(
        transitive_infos = valid_transitive_infos,
    )

    deps_transitive_infos = [
        info
        for attr, info in transitive_infos
        if attr in deps_attrs and info.xcode_target
    ]

    def _target_replacement_label(info):
        if not info.xcode_target:
            return target.label
        if target_skip_type != skip_type.apple_test_bundle:
            return target.label

        # Normalizes label to ensure this works with and without bzlmod
        # and then drop the target name because that will be replaced below
        label_str = bazel_labels.normalize_label(info.xcode_target.label)
        package_label_str = label_str.split(":")[0]

        # Important notes:
        #
        # 1. This relies on implementation details of
        # https://github.com/bazelbuild/rules_apple/blob/master/apple/internal/testing/apple_test_assembler.bzl#L100-L125
        # 2. Since `target_skip_type` is `skip_type.apple_test_bundle`
        # we can assume that `runner` is present as it's a required attribute
        # 3. The `.replace` below is safe even if `runner` is the
        # default runner `ios_default_runner` since it's a no-op in that case.
        #
        # Removes `runner` from `target.label.name` to create a replacement
        # label that works in all scenarios. For context, this is why
        # other approaches won't work:
        #
        # 1. Simply use `target.label.name`
        #
        # As of https://github.com/bazelbuild/rules_apple/pull/1948
        # `bundle_name` can be used to name the bundle instead of the
        # target name and `bundle_name` is not accesible in this context.
        #
        # 2. Use `ctx.rule.attr.generator_name`
        #
        # In many scenarios `generator_name` would be enough since it holds the
        # name of the test rule generating it but if the test
        # targets are wrapped in macros then `generator_name` can be anything
        #
        # Example:
        #
        # `iOSAppObjCUnitTestSuite_iPhone-13-Pro__16.2` => `iOSAppObjCUnitTestSuite`
        #
        runner_label_name = ctx.rule.attr.runner.label.name
        label_name = target.label.name.replace("_{}".format(runner_label_name), "")

        return Label(
            "{}:{}".format(package_label_str, label_name),
        )

    return _target_info_fields(
        dependencies = dependencies,
        hosted_targets = memory_efficient_depset(
            transitive = [
                info.hosted_targets
                for info in valid_transitive_infos
            ],
        ),
        inputs = input_files.merge(
            transitive_infos = valid_transitive_infos,
        ),
        non_top_level_rule_kind = None,
        outputs = provider_outputs,
        platforms = memory_efficient_depset(
            transitive = [info.platforms for info in valid_transitive_infos],
        ),
        replacement_labels = memory_efficient_depset(
            [
                struct(
                    id = info.xcode_target.id,
                    label = _target_replacement_label(info),
                )
                for info in deps_transitive_infos
            ],
            transitive = [
                info.replacement_labels
                for info in valid_transitive_infos
            ],
        ),
        target_type = target_type.compile,
        transitive_dependencies = transitive_dependencies,
        xcode_target = None,
        xcode_targets = memory_efficient_depset(
            transitive = [
                info.xcode_targets
                for info in valid_transitive_infos
            ],
        ),
    )

def _create_xcodeprojinfo(
        *,
        ctx,
        build_mode,
        target,
        attrs,
        transitive_infos,
        automatic_target_info):
    """Creates the target portion of an `XcodeProjInfo` for a `Target`.

    Args:
        ctx: The aspect context.
        build_mode: See `xcodeproj.build_mode`.
        target: The `Target` to process.
        attrs: `dir(ctx.rule.attr)` (as a performance optimization).
        automatic_target_info: The `XcodeProjAutomaticTargetProcessingInfo` for
            `target`.
        transitive_infos: A `list` of `XcodeProjInfo`s from the transitive
            dependencies of `target`.

    Returns:
        A `dict` of fields to be merged into the `XcodeProjInfo`. See
        `_target_info_fields`.
    """
    if not _should_create_provider(ctx = ctx, target = target):
        return None

    valid_transitive_infos = [
        info
        for attr, info in transitive_infos
        if (info.target_type in automatic_target_info.xcode_targets.get(
            attr,
            NONE_LIST,
        ))
    ]

    if not automatic_target_info.should_generate_target:
        processed_target = process_non_xcode_target(
            ctx = ctx,
            target = target,
            attrs = attrs,
            automatic_target_info = automatic_target_info,
            transitive_infos = valid_transitive_infos,
        )
    elif AppleBundleInfo in target:
        processed_target = process_top_level_target(
            ctx = ctx,
            build_mode = build_mode,
            target = target,
            attrs = attrs,
            automatic_target_info = automatic_target_info,
            bundle_info = target[AppleBundleInfo],
            transitive_infos = valid_transitive_infos,
        )
    elif target[DefaultInfo].files_to_run.executable:
        processed_target = process_top_level_target(
            ctx = ctx,
            build_mode = build_mode,
            target = target,
            attrs = attrs,
            automatic_target_info = automatic_target_info,
            bundle_info = None,
            transitive_infos = valid_transitive_infos,
        )
    else:
        processed_target = process_library_target(
            ctx = ctx,
            build_mode = build_mode,
            target = target,
            attrs = attrs,
            automatic_target_info = automatic_target_info,
            transitive_infos = valid_transitive_infos,
        )

    return _target_info_fields(
        dependencies = processed_target.dependencies,
        hosted_targets = memory_efficient_depset(
            processed_target.hosted_targets,
            transitive = [
                info.hosted_targets
                for info in valid_transitive_infos
            ],
        ),
        inputs = processed_target.inputs,
        non_top_level_rule_kind = (
            None if processed_target.is_top_level_target else ctx.rule.kind
        ),
        outputs = processed_target.outputs,
        platforms = memory_efficient_depset(
            [processed_target.platform] if processed_target.platform else None,
            transitive = [info.platforms for info in valid_transitive_infos],
        ),
        replacement_labels = memory_efficient_depset(
            transitive = [
                info.replacement_labels
                for _, info in transitive_infos
            ],
        ),
        target_type = automatic_target_info.target_type,
        transitive_dependencies = processed_target.transitive_dependencies,
        xcode_target = processed_target.xcode_target,
        xcode_targets = memory_efficient_depset(
            processed_target.xcode_targets,
            transitive = [
                info.xcode_targets
                for info in valid_transitive_infos
            ],
        ),
    )

# API

def create_xcodeprojinfo(*, ctx, build_mode, target, attrs, transitive_infos):
    """Creates an `XcodeProjInfo` for the given target.

    Args:
        ctx: The aspect context.
        build_mode: See `xcodeproj.build_mode`.
        attrs: `dir(ctx.rule.attr)` (as a performance optimization).
        target: The `Target` to process.
        transitive_infos: A `list` of `XcodeProjInfo`s from the transitive
            dependencies of `target`.

    Returns:
        An `XcodeProjInfo` populated with information from `target` and
        `transitive_infos`.
    """
    automatic_target_info = calculate_automatic_target_info(
        ctx = ctx,
        build_mode = build_mode,
        target = target,
    )

    target_skip_type = _get_skip_type(ctx = ctx, target = target)
    if target_skip_type:
        info_fields = _skip_target(
            ctx = ctx,
            build_mode = build_mode,
            target = target,
            target_skip_type = target_skip_type,
            deps = [
                dep
                for attr in automatic_target_info.deps
                for dep in getattr(ctx.rule.attr, attr, [])
            ],
            deps_attrs = automatic_target_info.deps,
            transitive_infos = transitive_infos,
            automatic_target_info = automatic_target_info,
        )
    else:
        info_fields = _create_xcodeprojinfo(
            ctx = ctx,
            build_mode = build_mode,
            target = target,
            attrs = attrs,
            automatic_target_info = automatic_target_info,
            transitive_infos = transitive_infos,
        )

    if not info_fields:
        return None

    return XcodeProjInfo(
        # label = target.label,
        # labels = depset(
        #     [target.label],
        #     transitive = [
        #         info.labels
        #         for _, info in transitive_infos
        #     ],
        # ),
        **info_fields
    )
