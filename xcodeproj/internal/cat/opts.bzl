"""Functions for processing compiler and linker options."""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("//xcodeproj/internal:memory_efficiency.bzl", "EMPTY_LIST")

# Compiler option processing

_CC_COMPILE_ACTIONS = {
    "CppCompile": None,
    "ObjcCompile": None,
}

# Defensive list of features that can appear in the CC toolchain, but that we
# definitely don't want to enable (meaning we don't want them to contribute
# command line flags).
_UNSUPPORTED_CC_FEATURES = [
    "debug_prefix_map_pwd_is_dot",
    # TODO: See if we need to exclude or handle it properly
    "thin_lto",
    "module_maps",
    "use_header_modules",
    "fdo_instrument",
    "fdo_optimize",
]

def _legacy_get_unprocessed_cc_compiler_opts(
        *,
        ctx,
        c_sources,
        cxx_sources,
        has_swift_opts,
        target,
        implementation_compilation_context):
    if (has_swift_opts or
        not implementation_compilation_context or
        not (c_sources or cxx_sources)):
        return (EMPTY_LIST, EMPTY_LIST, EMPTY_LIST, EMPTY_LIST)

    cc_toolchain = find_cpp_toolchain(ctx)

    user_copts = getattr(ctx.rule.attr, "copts", [])
    user_copts = _expand_locations(
        ctx = ctx,
        values = user_copts,
        targets = getattr(ctx.rule.attr, "data", []),
    )
    user_copts = _expand_make_variables(
        ctx = ctx,
        values = user_copts,
        attribute_name = "copts",
    )

    is_objc = apple_common.Objc in target
    if is_objc:
        objc = ctx.fragments.objc
        user_copts = (
            objc.copts +
            user_copts +
            objc.copts_for_current_compilation_mode
        )

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = (
            # `CcCommon.ALL_COMPILE_ACTIONS` doesn't include objc...
            ctx.features + ["objc-compile", "objc++-compile"]
        ),
        unsupported_features = (
            ctx.disabled_features + _UNSUPPORTED_CC_FEATURES
        ),
    )
    variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_compile_flags = user_copts,
        include_directories = implementation_compilation_context.includes,
        quote_include_directories = implementation_compilation_context.quote_includes,
        system_include_directories = implementation_compilation_context.system_includes,
        framework_include_directories = (
            implementation_compilation_context.framework_includes
        ),
        preprocessor_defines = depset(
            transitive = [
                implementation_compilation_context.local_defines,
                implementation_compilation_context.defines,
            ],
        ),
    )

    cpp = ctx.fragments.cpp

    if c_sources:
        base_copts = cc_common.get_memory_inefficient_command_line(
            feature_configuration = feature_configuration,
            action_name = "objc-compile" if is_objc else "c-compile",
            variables = variables,
        )
        conlyopts = base_copts + cpp.copts + cpp.conlyopts
        args = ctx.actions.args()
        args.add("wrapped_clang")
        args.add_all(conlyopts)
        conly_args = [args]
    else:
        conlyopts = []
        conly_args = []

    if cxx_sources:
        base_cxxopts = cc_common.get_memory_inefficient_command_line(
            feature_configuration = feature_configuration,
            action_name = "objc++-compile" if is_objc else "c++-compile",
            variables = variables,
        )
        cxxopts = base_cxxopts + cpp.copts + cpp.cxxopts
        args = ctx.actions.args()
        args.add("wrapped_clang_pp")
        args.add_all(cxxopts)
        cxx_args = [args]
    else:
        cxxopts = []
        cxx_args = []

    return conlyopts, conly_args, cxxopts, cxx_args

def _modern_get_unprocessed_cc_compiler_opts(
        *,
        # buildifier: disable=unused-variable
        ctx,
        c_sources,
        cxx_sources,
        # buildifier: disable=unused-variable
        has_swift_opts,
        target,
        # buildifier: disable=unused-variable
        implementation_compilation_context):
    conlyopts = EMPTY_LIST
    conly_args = EMPTY_LIST
    cxxopts = EMPTY_LIST
    cxx_args = EMPTY_LIST

    if not c_sources and not cxx_sources:
        return (conlyopts, conly_args, cxxopts, cxx_args)

    for action in target.actions:
        if action.mnemonic not in _CC_COMPILE_ACTIONS:
            continue

        previous_arg = None
        for arg in action.argv:
            if previous_arg == "-c":
                if not conly_args and arg in c_sources:
                    # First argument is "wrapped_clang"
                    conlyopts = action.argv[1:]
                    conly_args = action.args
                elif not cxx_args and arg in cxx_sources:
                    # First argument is "wrapped_clang_pp"
                    cxxopts = action.argv[1:]
                    cxx_args = action.args
                break
            previous_arg = arg

        if ((not c_sources or conly_args) and
            (not cxx_sources or cxx_args)):
            # We've found all the args we are looking for
            break

    return conlyopts, conly_args, cxxopts, cxx_args

# Bazel 6 check
_get_unprocessed_cc_compiler_opts = (
    _modern_get_unprocessed_cc_compiler_opts if hasattr(apple_common, "link_multi_arch_static_library") else _legacy_get_unprocessed_cc_compiler_opts
)

def _get_unprocessed_compiler_opts(
        *,
        ctx,
        build_mode,
        c_sources,
        cxx_sources,
        target,
        implementation_compilation_context):
    """Returns the unprocessed compiler options for the given target.

    Args:
        ctx: The aspect context.
        build_mode: See `xcodeproj.build_mode`.
        c_sources: A `dict` of C source paths.
        cxx_sources: A `dict` of C++ source paths.
        target: The `Target` that the compiler options will be retrieved from.
        implementation_compilation_context: The implementation deps aware
            `CcCompilationContext` for `target`.

    Returns:
        A `tuple` containing three elements:

        *   A `list` of C compiler options.
        *   A `list` of C++ compiler options.
        *   A `list` of Swift compiler options.
    """
    swiftcopts = []
    for action in target.actions:
        if action.mnemonic == "SwiftCompile":
            # First two arguments are "worker" and "swiftc"
            swiftcopts = action.argv[2:]
            break

    conlyopts, conly_args, cxxopts, cxxargs = _get_unprocessed_cc_compiler_opts(
        ctx = ctx,
        c_sources = c_sources,
        cxx_sources = cxx_sources,
        has_swift_opts = bool(swiftcopts),
        target = target,
        implementation_compilation_context = implementation_compilation_context,
    )

    if build_mode == "xcode":
        for opt in conlyopts + cxxopts:
            if opt.startswith("-ivfsoverlay`"):
                fail("""\
Using VFS overlays with `build_mode = "xcode"` is unsupported.
""")

    return (
        conlyopts,
        conly_args,
        cxxopts,
        cxxargs,
        swiftcopts,
    )

def _create_cc_compile_params(
        *,
        actions,
        name,
        generator_name,
        args,
        opt_type,
        cc_compiler_params_processor):
    if not args or not actions:
        return (EMPTY_LIST, None)

    def _create_compiler_raw_params(idx, raw_args):
        raw_output = actions.declare_file(
            "{}.rules_xcodeproj.{}.{}.compile.raw-{}.params".format(
                name,
                generator_name,
                opt_type,
                idx,
            ),
        )
        actions.write(
            output = raw_output,
            content = raw_args,
        )
        return raw_output

    raw_params = tuple([
        _create_compiler_raw_params(idx, raw_args)
        for idx, raw_args in enumerate(args)
    ])

    xcode_params = actions.declare_file(
        "{}.rules_xcodeproj.{}.{}.compile.params".format(
            name,
            generator_name,
            opt_type,
        ),
    )

    xcode_params_args = actions.args()
    xcode_params_args.add(xcode_params)
    xcode_params_args.add_all(raw_params)

    actions.run(
        executable = cc_compiler_params_processor,
        arguments = [xcode_params_args],
        mnemonic = "ProcessCCCompileParams",
        progress_message = "Generating %{output}",
        inputs = raw_params,
        outputs = [xcode_params],
    )

    return raw_params, xcode_params

def _process_compiler_opts(
        *,
        actions,
        build_mode,
        cc_compiler_params_processor,
        conly_args,
        conlyopts,
        cpp_fragment,
        cxx_args,
        cxxopts,
        generator_name,
        name,
        package_bin_dir,
        swift_args):
    """Processes compiler options.

    Args:
        actions: `ctx.actions`.
        build_mode: See `xcodeproj.build_mode`.
        cc_compiler_params_processor: The `cc_compiler_params_processor`
            executable.
        conly_args: An `Args` object for C compiler options.
        conlyopts: A `list` of C compiler options.
        cpp_fragment: The `cpp` configuration fragment.
        cxx_args: An `Args` object for C compiler options.
        cxxopts: A `list` of C++ compiler options.
        generator_name: The name of the xcodeproj target.
        name: The name of the target.
        package_bin_dir: The package directory for the target within
            `ctx.bin_dir`.
        swift_args: A `list` of `Args` for the `SwiftCompile` action for this
            target.

    Returns:
        A `tuple` containing six elements:

        *   A C compiler params `File`.
        *   A C++ compiler params `File`.
        *   A `list` of `Args` for the `SwiftCompile` action for this target.
        *   A `bool` that is `True` if C compiler options contain
            "-D_FORTIFY_SOURCE=1".
        *   A `bool` that is `True` if C++ compiler options contain
            "-D_FORTIFY_SOURCE=1".
        *   A `list` of Swift PCM (clang) compiler options.
    """
    c_raw_params, c_xcode_params = _create_cc_compile_params(
        actions = actions,
        name = name,
        generator_name = generator_name,
        args = conly_args,
        opt_type = "c",
        cc_compiler_params_processor = cc_compiler_params_processor,
    )
    cxx_raw_params, cxx_xcode_params = _create_cc_compile_params(
        actions = actions,
        name = name,
        generator_name = generator_name,
        args = cxx_args,
        opt_type = "cxx",
        cc_compiler_params_processor = cc_compiler_params_processor,
    )

    return struct(
        c_raw_params = c_raw_params,
        c_xcode_params = c_xcode_params,
        cxx_raw_params = cxx_raw_params,
        cxx_xcode_params = cxx_xcode_params,
        swift_args = swift_args,
    )

def _process_target_compiler_opts(
        *,
        ctx,
        build_mode,
        c_sources,
        cxx_sources,
        target,
        implementation_compilation_context,
        package_bin_dir):
    """Processes the compiler options for a target.

    Args:
        ctx: The aspect context.
        build_mode: See `xcodeproj.build_mode`.
        c_sources: A `dict` of C source paths.
        cxx_sources: A `dict` of C++ source paths.
        target: The `Target` that the compiler options will be retrieved from.
        implementation_compilation_context: The implementation deps aware
            `CcCompilationContext` for `target`.
        package_bin_dir: The package directory for `target` within
            `ctx.bin_dir`.

    Returns:
        A `tuple` containing six elements:

        *   A C compiler params `File`.
        *   A C++ compiler params `File`.
        *   A `list` of `Args` for the `SwiftCompile` action for this target.
        *   A `bool` that is `True` if C compiler options contain
            "-D_FORTIFY_SOURCE=1".
        *   A `bool` that is `True` if C++ compiler options contain
            "-D_FORTIFY_SOURCE=1".
        *   A `list` of Swift PCM (clang) compiler options.
    """
    (
        conlyopts,
        conly_args,
        cxxopts,
        cxx_args,
        swift_args,
    ) = _get_unprocessed_compiler_opts(
        ctx = ctx,
        build_mode = build_mode,
        c_sources = c_sources,
        cxx_sources = cxx_sources,
        target = target,
        implementation_compilation_context = implementation_compilation_context,
    )
    return _process_compiler_opts(
        actions = ctx.actions,
        name = ctx.rule.attr.name,
        generator_name = ctx.attr._generator_name,
        conlyopts = conlyopts,
        conly_args = conly_args,
        cxxopts = cxxopts,
        cxx_args = cxx_args,
        swift_args = swift_args,
        build_mode = build_mode,
        cpp_fragment = ctx.fragments.cpp,
        package_bin_dir = package_bin_dir,
        cc_compiler_params_processor = (
            ctx.executable._cc_compiler_params_processor
        ),
    )

# Utility

def _expand_locations(*, ctx, values, targets = []):
    """Expands the `$(location)` placeholders in each of the given values.

    Args:
        ctx: The aspect context.
        values: A `list` of strings, which may contain `$(location)`
            placeholders.
        targets: A `list` of additional targets (other than the calling rule's
            `deps`) that should be searched for substitutable labels.

    Returns:
        A `list` of strings with any `$(location)` placeholders filled in.
    """
    return [ctx.expand_location(value, targets) for value in values]

def _expand_make_variables(*, ctx, values, attribute_name):
    """Expands all references to Make variables in each of the given values.

    Args:
        ctx: The aspect context.
        values: A `list` of strings, which may contain Make variable
            placeholders.
        attribute_name: The attribute name string that will be presented in the
            console when an error occurs.

    Returns:
        A `list` of strings with Make variables placeholders filled in.
    """
    return [
        ctx.expand_make_variables(attribute_name, token, {})
        for value in values
        # TODO: Handle `no_copts_tokenization`
        for token in ctx.tokenize(value)
    ]

# API

def _collect_params(
        *,
        ctx,
        build_mode,
        c_sources,
        cxx_sources,
        target,
        implementation_compilation_context,
        package_bin_dir):
    """Processes the compiler options for a target.

    Args:
        ctx: The aspect context.
        build_mode: See `xcodeproj.build_mode`.
        c_sources: A `dict` of C source paths.
        cxx_sources: A `dict` of C++ source paths.
        target: The `Target` that the compiler and linker options will be
            retrieved from.
        implementation_compilation_context: The implementation deps aware
            `CcCompilationContext` for `target`.
        package_bin_dir: The package directory for `target` within
            `ctx.bin_dir`.

    Returns:
        A `tuple` containing six elements:

        *   A C compiler params `File`.
        *   A C++ compiler params `File`.
        *   A `list` of `Args` for the `SwiftCompile` action for this target.
        *   A `bool` that is `True` if C compiler options contain
            "-D_FORTIFY_SOURCE=1".
        *   A `bool` that is `True` if C++ compiler options contain
            "-D_FORTIFY_SOURCE=1".
        *   A `list` of Swift PCM (clang) compiler options.
    """
    return _process_target_compiler_opts(
        ctx = ctx,
        build_mode = build_mode,
        c_sources = c_sources,
        cxx_sources = cxx_sources,
        target = target,
        implementation_compilation_context = implementation_compilation_context,
        package_bin_dir = package_bin_dir,
    )

# These functions are exposed only for access in unit tests.
testable = struct(
    process_compiler_opts = _process_compiler_opts,
)

opts = struct(
    collect_params = _collect_params,
)
