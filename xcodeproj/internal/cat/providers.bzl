"""Providers that are used throughout the rules."""

XcodeProjAutomaticTargetProcessingInfo = provider(
    """\
Provides needed information about a target to allow rules_xcodeproj to
automatically process it.

If you need more control over how a target or its dependencies are processed,
return an `XcodeProjInfo` provider instance instead.

**Warning:** This provider currently has an unstable API and may change in the
future. If you are using this provider, please let us know so we can prioritize
stabilizing it.
""",
    fields = {
        "alternate_icons": """\
An attribute name (or `None`) to collect the application alternate icons.
""",
        "app_icons": """\
An attribute name (or `None`) to collect the application icons.
""",
        "args": """\
A `List` (or `None`) representing the command line arguments that this target
should execute or test with.
""",
        "bundle_id": """\
An attribute name (or `None`) to collect the bundle id string from.
""",
        "codesignopts": """\
An attribute name (or `None`) to collect the `codesignopts` `list` from.
""",
        "collect_uncategorized_files": """\
Whether to collect files from uncategorized attributes.
""",
        "deps": """\
A sequence of attribute names to collect `Target`s from for `deps`-like
attributes.
""",
        "entitlements": """\
An attribute name (or `None`) to collect `File`s from for the
`entitlements`-like attribute.
""",
        "env": """\
A `dict` representing the environment variables that this target should execute
or test with.
""",
        "exported_symbols_lists": """\
A sequence of attribute names to collect `File`s from for the
`exported_symbols_lists`-like attributes.
""",
        "hdrs": """\
A sequence of attribute names to collect `File`s from for `hdrs`-like
attributes.
""",
        "implementation_deps": """\
A sequence of attribute names to collect `Target`s from for
`implementation_deps`-like attributes.
""",
        "infoplists": """\
A sequence of attribute names to collect `File`s from for the `infoplists`-like
attributes.
""",
        "launchdplists": """\
A sequence of attribute names to collect `File`s from for the
`launchdplists`-like attributes.
""",
        "link_mnemonics": """\
A sequence of mnemonic (action) names to gather link parameters. The first
action that matches any of the mnemonics is used.
""",
        "non_arc_srcs": """\
A sequence of attribute names to collect `File`s from for `non_arc_srcs`-like
attributes.
""",
        "pch": """\
An attribute name (or `None`) to collect `File`s from for the `pch`-like
attribute.
""",
        "provisioning_profile": """\
An attribute name (or `None`) to collect `File`s from for the
`provisioning_profile`-like attribute.
""",
        "should_generate_target": """\
Whether or an Xcode target should be generated for this target. Even if this
value is `False`, setting values for the other attributes can cause inputs to be
collected and shown in the Xcode project.
""",
        "srcs": """\
A sequence of attribute names to collect `File`s from for `srcs`-like
attributes.
""",
        "target_type": "See `XcodeProjInfo.target_type`.",
        "xcode_targets": """\
A `dict` mapping attribute names to target type strings (i.e. "resource" or
"compile"). Only Xcode targets from the specified attributes with the specified
target type are allowed to propagate.
""",
    },
)

target_type = struct(
    compile = "compile",
)

XcodeProjInfo = provider(
    """\
Provides information needed to generate an Xcode project.

**Warning:** This provider currently has an unstable API and may change in the
future. If you are using this provider, please let us know so we can prioritize
stabilizing it.
""",
    fields = {
        "dependencies": """\
A `depset` of target IDs (see `xcode_target.id`) that this target directly
depends on.
""",
        "hosted_targets": """\
A `depset` of `struct`s with 'host' and 'hosted' fields. The `host` field is the
target ID (see `xcode_target.id`) of the hosting target. The `hosted` field is
the target ID of the hosted target.
""",
        "inputs": """\
A value returned from `input_files.collect`/`inputs_files.merge`, that contains
information related to all of the input `File`s for the project collected so
far. It also includes information related to "extra files" that should be added
to the Xcode project, but are not associated with any targets.
""",
        "replacement_labels": """\
A `depset` of `struct`s with `id` and `label` fields. The `id` field is the
target ID (see `xcode_target.id`) of the target that have its label (and name)
be replaced with the label in the `label` field.
""",
        "non_top_level_rule_kind": """
If this target is not a top-level target, this is the value from
`ctx.rule.kind`, otherwise it is `None`. Top-level targets are targets that
are valid to be listed in the `top_level_targets` attribute of `xcodeproj`.
In particular, this means that they aren't library targets, which when
specified in `top_level_targets` cause duplicate mis-configured targets to be
added to the project.
""",
        "outputs": """\
A value returned from `output_files.collect`/`output_files.merge`, that contains
information about the output files for this target and its transitive
dependencies.
""",
        "platforms": """\
A `depset` of `apple_platform`s that this target and its transitive dependencies
are built for.
""",
        "target_type": """\
A string that categorizes the type of the current target. This will be one of
"compile", "resources", or `None`. Even if this target doesn't produce an Xcode
target, it can still have a non-`None` value for this field.
""",
        "transitive_dependencies": """\
A `depset` of target IDs (see `xcode_target.id`) that this target transitively
depends on.
""",
        "xcode_target": """\
A value returned from `xcode_targets.make` if this target can produce an Xcode
target.
""",
        "xcode_targets": """\
A `depset` of values returned from `xcode_targets.make`, which potentially will
become targets in the Xcode project.
""",
    },
)

XcodeProjProvisioningProfileInfo = provider(
    "Provides information about a provisioning profile.",
    fields = {
        "profile_name": """\
The profile name (e.g. "iOS Team Provisioning Profile: com.example.app").
""",
        "team_id": """\
The Team ID the profile is associated with (e.g. "V82V4GQZXM").
""",
        "is_xcode_managed": "Whether the profile is managed by Xcode.",
    },
)
