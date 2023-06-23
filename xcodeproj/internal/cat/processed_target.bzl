"""Functions for creating data structures related to processed bazel targets."""

load(":providers.bzl", "target_type")

def processed_target(
        *,
        dependencies,
        hosted_targets = None,
        inputs,
        is_top_level_target = False,
        outputs,
        platform = None,
        transitive_dependencies,
        xcode_target):
    """Generates the return value for target processing functions.

    Args:
        dependencies: A `depset` of target ids of direct dependencies of this
            target.
        hosted_targets: An optional `list` of `struct`s as used in
            `XcodeProjInfo.hosted_targets`.
        inputs: A value as returned from
            `input_files.collect`/`input_files.merge` that will provide values
            for the `XcodeProjInfo.inputs` field.
        is_top_level_target: If `True`, the target is a top-level target.
        outputs: A value as returned from `output_files.collect` that will
            provide values for the `XcodeProjInfo.outputs` field.
        platform: An `apple_platform`, or `None`, that will be included in the
            `XcodeProjInfo.platforms` field.
        transitive_dependencies: A `depset` of target ids of transitive
            dependencies of this target.
        xcode_target: An optional value returned from `xcode_targets.make` that
            will be in the `XcodeProjInfo.xcode_targets` `depset`.

    Returns:
        A `struct` containing fields for each argument.
    """
    return struct(
        dependencies = dependencies,
        hosted_targets = hosted_targets,
        inputs = inputs,
        is_top_level_target = is_top_level_target,
        outputs = outputs,
        platform = platform,
        target_type = target_type,
        transitive_dependencies = transitive_dependencies,
        xcode_target = xcode_target,
        xcode_targets = [xcode_target] if xcode_target else None,
    )
