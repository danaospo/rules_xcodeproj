import ArgumentParser
import Foundation
import GeneratorCommon
import PBXProj

@main
struct CompilerBuildSettings {
    private static let separator = Data([0x0a]) // Newline
    private static let subSeparator = Data([0x09]) // Tab

    static func main() async {
        let logger = DefaultLogger(
            standardError: StderrOutputStream(),
            standardOutput: StdoutOutputStream(),
            // FIXME: Take a colorize parameter
            colorize: false
        )

        do {
            let (output, buildSettings) = try await parseArgs()

            var data = Data()

            for (key, value) in buildSettings.sorted(by: { $0.key < $1.key }) {
                data.append(Data(key.utf8))
                data.append(Self.subSeparator)
                data.append(Data(value.utf8))
                data.append(Self.separator)
            }

            try data.write(to: output)
        } catch {
            logger.logError(error.localizedDescription)
            Darwin.exit(1)
        }
    }

    private static func parseArgs() async throws -> (
        output: URL,
        buildSettings: [String: String]
    ) {
        guard CommandLine.arguments.count > 1 else {
            throw PreconditionError(message: "Missing <output-path>")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])

        guard CommandLine.arguments.count > 2 else {
            throw PreconditionError(message: "Missing <build-mode>")
        }
        guard let buildMode = BuildMode(argument: CommandLine.arguments[2])
        else {
            throw PreconditionError(
                message: "Unknown build mode: \(CommandLine.arguments[2])"
            )
        }

        guard CommandLine.arguments.count > 3 else {
            throw PreconditionError(message: "Missing <package-bin-dir>")
        }
        let packageBinDir = CommandLine.arguments[3]

        let buildSettings = try await processSwiftArgs(
            rawArguments: CommandLine.arguments.dropFirst(4),
            buildMode: buildMode,
            packageBinDir: packageBinDir
        )

        return (output, buildSettings)
    }

    private static func processSwiftArgs(
        rawArguments: Array<String>.SubSequence,
        buildMode: BuildMode,
        packageBinDir: String
    ) async throws -> [String: String] {
        let isBwX = buildMode == .xcode

        var previousArg: Substring? = nil
        var previousClangArg: Substring? = nil
        var previousFrontendArg: Substring? = nil
        var skipNext = 0

        var args: [Substring]
        if isBwX {
            args = [
                "-Xcc",
                "-ivfsoverlay",
                "-Xcc",
                "$(DERIVED_FILE_DIR)/xcode-overlay.yaml",
                "-Xcc",
                "-ivfsoverlay",
                "-Xcc",
                "$(OBJROOT)/bazel-out-overlay.yaml",
                "-vfsoverlay",
                "$(OBJROOT)/bazel-out-overlay.yaml",
            ]
        } else {
            args = [
                "-Xcc",
                "-ivfsoverlay",
                "-Xcc",
                "$(OBJROOT)/bazel-out-overlay.yaml",
                "-vfsoverlay",
                "$(OBJROOT)/bazel-out-overlay.yaml",
            ]
        }

        var buildSettings: [String: String] = [:]
        for try await arg in parseArgs(rawArguments: rawArguments) {
            if skipNext != 0 {
                skipNext -= 1
                continue
            }

            let isClangArg = previousArg == "-Xcc"
            let isFrontendArg = previousArg == "-Xfrontend"
            let isFrontend = arg == "-Xfrontend"
            let isXcc = arg == "-Xcc"

            // Track previous argument
            defer {
                if isClangArg {
                    previousClangArg = arg
                } else if !isXcc {
                    previousClangArg = nil
                }

                if isFrontendArg {
                    previousFrontendArg = arg
                } else if !isFrontend {
                    previousFrontendArg = nil
                }

                previousArg = arg
            }

            // Handle Clang (-Xcc) args
            if isXcc {
                args.append(arg)
                continue
            }

            if isClangArg {
                try processClangArg(
                    arg,
                    previousClangArg: previousClangArg,
                    args: &args,
                    isBwX: isBwX
                )
                continue
            }

            // Skip based on flag
            let rootArg = arg.split(separator: "=", maxSplits: 1).first!

            if let thisSkipNext = skipArgs[rootArg] {
                skipNext = thisSkipNext - 1
                continue
            }

            if isFrontendArg {
                if let thisSkipNext = skipFrontendArgs[rootArg] {
                    skipNext = thisSkipNext - 1
                    continue
                }

                // We filter out `-Xfrontend`, so we need to add it back if the
                // current arg wasn't filtered out
                args.append("-Xfrontend")

                try processFrontendArg(
                    arg,
                    previousFrontendArg: previousFrontendArg,
                    args: &args,
                    isBwX: isBwX
                )
                continue
            }

            if !arg.hasPrefix("-") && arg.hasSuffix(".swift") {
                // These are the files to compile, not options. They are seen
                // here because of the way we collect Swift compiler options.
                // Ideally in the future we could collect Swift compiler options
                // similar to how we collect C and C++ compiler options.
                continue
            }

            try processArg(
                arg,
                previousArg: previousArg,
                previousFrontendArg: previousFrontendArg,
                args: &args,
                buildSettings: &buildSettings,
                isBwX: isBwX,
                packageBinDir: packageBinDir
            )
        }

        buildSettings["OTHER_SWIFT_FLAGS"] =
            args.joined(separator: " ").pbxProjEscaped

        return buildSettings
    }

    private static func processArg(
        _ arg: Substring,
        previousArg: Substring?,
        previousFrontendArg: Substring?,
        args: inout [Substring],
        buildSettings: inout [String: String],
        isBwX: Bool,
        packageBinDir: String
    ) throws {
        if let compilationMode = compilationModeArgs[arg] {
            buildSettings["SWIFT_COMPILATION_MODE"] = compilationMode
            return
        }

        if previousArg == "-swift-version" {
            if arg != "5.0" {
                buildSettings["SWIFT_VERSION"] = String(arg)
            }
            return
        }

        if previousArg == "-emit-objc-header-path" {
            guard arg.hasPrefix(packageBinDir) else {
                throw UsageError(message: """
-emit-objc-header-path must be in bin dir of the target. \(arg) is not under \
\(packageBinDir)
""")
            }
            buildSettings["SWIFT_OBJC_INTERFACE_HEADER_NAME"] = String(
                arg.dropFirst(packageBinDir.count + 1).pbxProjEscaped
            )
            return
        }

        if arg.hasPrefix("-I") {
            let path = arg.dropFirst(2)
            if !isBwX ||
                path.starts(with: "__BAZEL_XCODE_DEVELOPER_DIR__")
            {
                guard !path.isEmpty else {
                    args.append(arg)
                    return
                }

                // We include these paths in BwX mode to account for
                // `/Applications/Xcode.app/Contents/Developer/Platforms/PLATFORM/Developer/usr/lib`.
                // Otherwise we exclude them because we set
                // `SWIFT_INCLUDE_PATHS`.
                let absoluteArg: Substring = "-I" + path.buildSettingPath()
                args.append(absoluteArg.quoteIfNeeded())
            }
            return
        }

        if previousArg == "-I" {
            if !isBwX ||
                arg.starts(with: "__BAZEL_XCODE_DEVELOPER_DIR__")
            {
                // We include these paths in BwX mode to account for
                // `/Applications/Xcode.app/Contents/Developer/Platforms/PLATFORM/Developer/usr/lib`.
                // Otherwise we exclude them because we set
                // `SWIFT_INCLUDE_PATHS`.
                if isBwX {
                    // We need to append `-I` for BwX because we don't in the
                    // `arg.hasPrefix("-I")` case
                    args.append("-I")
                }
                args.append(arg.buildSettingPath().quoteIfNeeded())
            }
            return
        }

        if previousArg == "-F" {
            args.append(arg.buildSettingPath().quoteIfNeeded())
            return
        }

        if arg.hasPrefix("-F") {
            let path = arg.dropFirst(2)

            guard !path.isEmpty else {
                args.append(arg)
                return
            }

            let absoluteArg: Substring = "-F" + path.buildSettingPath()
            args.append(absoluteArg.quoteIfNeeded())
            return
        }

        if arg.hasPrefix("-vfsoverlay") {
            guard !isBwX else {
                throw UsageError(message: """
Using VFS overlays with `build_mode = "xcode"` is unsupported.
""")
            }

            var path = arg.dropFirst(11)

            guard !path.isEmpty else {
                args.append(arg)
                return
            }

            if path.hasPrefix("=") {
                path = path.dropFirst()
            }

            let absoluteArg: Substring = "-vfsoverlay" + path.buildSettingPath()
            args.append(absoluteArg.quoteIfNeeded())
            return
        }

        if previousArg == "-vfsoverlay" {
            guard !isBwX else {
                throw UsageError(message: """
Using VFS overlays with `build_mode = "xcode"` is unsupported.
""")
            }
            args.append(arg.buildSettingPath().quoteIfNeeded())
            return
        }

        args.append(arg.substituteBazelPlaceholders().quoteIfNeeded())
    }

    private static func processClangArg(
        _ arg: Substring,
        previousClangArg: Substring?,
        args: inout [Substring],
        isBwX: Bool
    ) throws {
        if arg.hasPrefix("-fmodule-map-file=") {
            let path = arg.dropFirst(18)
            let absoluteArg: Substring =
                "-fmodule-map-file=" + path.buildSettingPath()
            args.append(absoluteArg.quoteIfNeeded())
            return
        }

        for searchArg in clangSearchPathArgs {
            if arg.hasPrefix(searchArg) {
                let path = arg.dropFirst(searchArg.count)

                guard !path.isEmpty else {
                    args.append(arg)
                    return
                }

                args.append(searchArg)
                args.append("-Xcc")
                args.append(path.buildSettingPath().quoteIfNeeded())
                return
            }
        }

        if let previousClangArg,
           clangSearchPathArgs.contains(previousClangArg)
        {
            args.append(arg.buildSettingPath().quoteIfNeeded())
        }

        // `-ivfsoverlay` doesn't apply `-working_directory=`, so we need to
        // prefix it ourselves
        if previousClangArg == "-ivfsoverlay" {
            guard !isBwX else {
                throw UsageError(message: """
Using VFS overlays with `build_mode = "xcode"` is unsupported.
""")
            }
            args.append(
                arg.buildSettingPath().quoteIfNeeded()
            )
            return
        }

        if arg.hasPrefix("-ivfsoverlay") {
            guard !isBwX else {
                throw UsageError(message: """
Using VFS overlays with `build_mode = "xcode"` is unsupported.
""")
            }

            var path = arg.dropFirst(12)

            if path.hasPrefix("=") {
                path = path.dropFirst()
            }

            guard !path.isEmpty else {
                args.append(arg)
                return
            }

            let absoluteArg: Substring =
                "-ivfsoverlay" + path.buildSettingPath()
            args.append(absoluteArg.quoteIfNeeded())
            return
        }

        args.append(arg.substituteBazelPlaceholders().quoteIfNeeded())
    }

    private static func processFrontendArg(
        _ arg: Substring,
        previousFrontendArg: Substring?,
        args: inout [Substring],
        isBwX: Bool
    ) throws {
        if let previousFrontendArg {
            if overlayArgs.contains(previousFrontendArg) {
                guard !isBwX else {
                    throw UsageError(message: """
Using '\(previousFrontendArg)' with `build_mode = "xcode"` is unsupported.
""")
                }
                args.append(arg.buildSettingPath().quoteIfNeeded())
                return
            }

            if loadPluginsArgs.contains(previousFrontendArg) {
                args.append(
                    arg.buildSettingPath(useXcodeBuildDir: isBwX)
                        .quoteIfNeeded()
                )
                return
            }
        }

        args.append(arg.substituteBazelPlaceholders().quoteIfNeeded())
    }

    private static func parseArgs(
        rawArguments: Array<String>.SubSequence
    ) -> AsyncThrowingStream<Substring, Error> {
        return AsyncThrowingStream { continuation in
            let argsTask = Task {
                for arg in rawArguments {
                    guard !arg.starts(with: "@") else {
                        let path = String(arg.dropFirst())
                        for try await line in URL(fileURLWithPath: path).lines {
                            // Change params files from `shell` to `multiline`
                            // format
                            // https://bazel.build/versions/6.1.0/rules/lib/Args#set_param_file_format.format
                            if line.hasPrefix("'") && line.hasSuffix("'") {
                                let startIndex = line
                                    .index(line.startIndex, offsetBy: 1)
                                let endIndex = line.index(before: line.endIndex)
                                continuation
                                    .yield(line[startIndex ..< endIndex])
                            } else {
                                continuation.yield(Substring(line))
                            }
                        }
                        continue
                    }
                    continuation.yield(Substring(arg))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                argsTask.cancel()
            }
        }
    }
}

private let skipArgs: [Substring: Int] = [
    // Xcode sets output paths
    "-emit-module-path": 2,
    "-emit-object": 1,
    "-output-file-map": 2,

    // Xcode sets these, and no way to unset them
    "-enable-bare-slash-regex": 1,
    "-module-name": 2,
    "-num-threads": 2,
    "-parse-as-library": 1,
    "-sdk": 2,
    "-target": 2,

    // We want to use Xcode's normal PCM handling
    "-module-cache-path": 2,

    // We want Xcode's normal debug handling
    "-debug-prefix-map": 2,
    "-file-prefix-map": 2,
    "-gline-tables-only": 1,

    // We want to use Xcode's normal indexing handling
    "-index-ignore-system-modules": 1,
    "-index-store-path": 2,

    // We set Xcode build settings to control these
    "-enable-batch-mode": 1,

    // We don't want to translate this for BwX
    "-emit-symbol-graph-dir": 2,

    // These are handled in `opts.bzl`
    "-g": 1,

    // These are fully handled in a `previousArg` check
    "-emit-objc-header-path": 1,
    "-swift-version": 1,

    // We filter out `-Xfrontend`, then add it back only if the current arg
    // wasn't filtered out
    "-Xfrontend": 1,

    // This is rules_swift specific, and we don't want to translate it for BwX
    "-Xwrapped-swift": 1,
]

private let skipFrontendArgs: [Substring: Int] = [
    // We want Xcode to control coloring
    "-color-diagnostics": 1,

    // We want Xcode's normal debug handling
    "-no-clang-module-breadcrumbs": 1,
    "-no-serialize-debugging-options": 1,
    "-serialize-debugging-options": 1,

    // We don't want to translate this for BwX
    "-emit-symbol-graph": 1,
]

private let compilationModeArgs: [Substring: String] = [
    "-incremental": "singlefile",
    "-no-whole-module-optimization": "singlefile",
    "-whole-module-optimization": "wholemodule",
    "-wmo": "wholemodule",
]

private let clangSearchPathArgs: Set<Substring> = [
    "-F",
    "-I",
    "-iquote",
    "-isystem",
]

private let loadPluginsArgs: Set<Substring> = [
    "-load-plugin-executable",
    "-load-plugin-library",
]

private let overlayArgs: Set<Substring> = [
    "-explicit-swift-module-map-file",
    "-vfsoverlay",
]

extension Substring {
    func buildSettingPath(
        useXcodeBuildDir: Bool = false
    ) -> Self {
        if self == "bazel-out" || starts(with: "bazel-out/") {
            // Dropping "bazel-out" prefix
            if useXcodeBuildDir {
                return "$(BUILD_DIR)\(dropFirst(9))"
            } else {
                return "$(BAZEL_OUT)\(dropFirst(9))"
            }
        }

        if self == "external" || starts(with: "external/") {
            // Dropping "external" prefix
            return "$(BAZEL_EXTERNAL)\(dropFirst(8))"
        }

        if self == ".." || starts(with: "../") {
            // Dropping ".." prefix
            return "$(BAZEL_EXTERNAL)\(dropFirst(2))"
        }

        if self == "." {
            // We need to use Bazel's execution root for ".", since includes can
            // reference things like "external/" and "bazel-out"
            return "$(PROJECT_DIR)"
        }

        let substituted = substituteBazelPlaceholders()

        if substituted.hasPrefix("/") {
            return substituted
        }

        return "$(SRCROOT)/\(substituted)"
    }

    func substituteBazelPlaceholders() -> Self {
        return
            // Use Xcode set `DEVELOPER_DIR`
            replacing(
                "__BAZEL_XCODE_DEVELOPER_DIR__",
                with: "$(DEVELOPER_DIR)"
            )
            // Use Xcode set `SDKROOT`
            .replacing("__BAZEL_XCODE_SDKROOT__", with: "$(SDKROOT)")
    }

    func quoteIfNeeded() -> Self {
        // Quote the arg if it contains spaces
        guard !contains(" ") else {
            return "'\(self)'"
        }
        return self
    }
}
