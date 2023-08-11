import Foundation
import GeneratorCommon
import PBXProj

extension Generator {
    struct CalculatePlatformVariantBuildSettings {
        private let callable: Callable

        /// - Parameters:
        ///   - callable: The function that will be called in
        ///     `callAsFunction()`.
        init(callable: @escaping Callable = Self.defaultCallable) {
            self.callable = callable
        }

        /// Calculates the build settings for one of the target's platform
        /// variants.
        func callAsFunction(
            buildMode: BuildMode,
            productType: PBXProductType,
            platformVariant: Target.PlatformVariant
        ) async throws -> [PlatformVariantBuildSetting] {
            return try await callable(
                /*buildMode:*/ buildMode,
                /*productType:*/ productType,
                /*platformVariant:*/ platformVariant
            )
        }
    }
}

// MARK: - CalculatePlatformVariantBuildSettings.Callable

extension Generator.CalculatePlatformVariantBuildSettings {
    typealias Callable = (
        _ buildMode: BuildMode,
        _ productType: PBXProductType,
        _ platformVariant: Target.PlatformVariant
    ) async throws -> [PlatformVariantBuildSetting]

    static func defaultCallable(
        buildMode: BuildMode,
        productType: PBXProductType,
        platformVariant: Target.PlatformVariant
    ) async throws -> [PlatformVariantBuildSetting] {
        var buildSettings: [PlatformVariantBuildSetting] = []

        buildSettings.append(
            .init(key: "ARCHS", value: platformVariant.arch.pbxProjEscaped)
        )
        buildSettings.append(
            .init(
                key: "BAZEL_PACKAGE_BIN_DIR",
                value: platformVariant.packageBinDir.pbxProjEscaped
            )
        )
        buildSettings.append(
            .init(
                key: "BAZEL_TARGET_ID",
                value: platformVariant.id.rawValue.pbxProjEscaped
            )
        )
        buildSettings.append(
            .init(
                key:
                    platformVariant.platform.os.deploymentTargetBuildSettingKey,
                value: platformVariant.osVersion.pretty.pbxProjEscaped
            )
        )

        if !platformVariant.moduleName.isEmpty {
            buildSettings.append(
                .init(
                    key: "PRODUCT_MODULE_NAME",
                    value: platformVariant.moduleName.pbxProjEscaped
                )
            )
        }

        if let outputsProductPath = platformVariant.outputsProductPath {
            buildSettings.append(
                .init(
                    key: "BAZEL_OUTPUTS_PRODUCT",
                    value: outputsProductPath.pbxProjEscaped
                )
            )
            buildSettings.append(
                .init(
                    key: "BAZEL_OUTPUTS_PRODUCT_BASENAME",
                    value: platformVariant.productBasename.pbxProjEscaped
                )
            )
        }

        if let dSYMPathsBuildSetting = platformVariant.dSYMPathsBuildSetting {
            buildSettings.append(
                .init(
                    key: "BAZEL_OUTPUTS_DSYM",
                    value: dSYMPathsBuildSetting.pbxProjEscaped
                )
            )
        }

        if let executableName = platformVariant.executableName,
           executableName != platformVariant.productName
        {
            buildSettings.append(
                .init(
                    key: "EXECUTABLE_NAME",
                    value: executableName.pbxProjEscaped
                )
            )
        }

        let productExtension =
            (platformVariant.productPath as NSString).pathExtension
        if productExtension != productType.fileExtension {
            buildSettings.append(
                .init(
                    key: productType.isBundle ?
                        "WRAPPER_EXTENSION" : "EXECUTABLE_EXTENSION",
                    value: productExtension.pbxProjEscaped
                )
            )
        }

        if let compileTargetIDs = platformVariant.compileTargetIDs {
            buildSettings.append(
                .init(
                    key: "BAZEL_COMPILE_TARGET_IDS",
                    value: compileTargetIDs.pbxProjEscaped
                )
            )
        }

        if let entitlements = platformVariant.entitlements {
            buildSettings.append(
                .init(
                    key: "CODE_SIGN_ENTITLEMENTS",
                    value: entitlements.buildSetting.pbxProjEscaped
                )
            )

            if buildMode == .bazel {
                // This is required because otherwise Xcode can fails the build
                // due to a generated entitlements file being modified by the
                // Bazel build script. We only set this for BwB mode though,
                // because when this is set, Xcode uses the entitlements as
                // provided instead of modifying them, which is needed in BwX
                // mode.
                buildSettings.append(
                    .init(
                        key: "CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION",
                        value: "YES"
                    )
                )
            }
        }

        if let testHost = platformVariant.unitTestHost {
            buildSettings.append(
                .init(
                    key: "TARGET_BUILD_DIR",
                    value: #"""
"$(BUILD_DIR)/\#(testHost.packageBinDir)$(TARGET_BUILD_SUBPATH)"
"""#
                )
            )
            buildSettings.append(
                .init(
                    key: "TEST_HOST",
                    value: #"""
"$(BUILD_DIR)/\#(testHost.packageBinDir)/\#(testHost.productPath)/\#(testHost.executableName)"
"""#
                )
            )
        }

        let cFlags: [String]
        if let cParams = platformVariant.cParams {
            // Drop the `bazel-out` prefix since we use the env var for this
            // portion of the path
            buildSettings.append(
                .init(
                    key: "C_PARAMS_FILE",
                    value: #"""
"$(BAZEL_OUT)\#(cParams.dropFirst(9))"
"""#
                )
            )
            cFlags = ["@$(DERIVED_FILE_DIR)/c.compile.params"]
        } else {
            cFlags = []
        }

        let cxxFlags: [String]
        if let cxxParams = platformVariant.cxxParams {
            // Drop the `bazel-out` prefix since we use the env var for this
            // portion of the path
            buildSettings.append(
                .init(
                    key: "CXX_PARAMS_FILE",
                    value: #"""
"$(BAZEL_OUT)\#(cxxParams.dropFirst(9))"
"""#
                )
            )
            cxxFlags = ["@$(DERIVED_FILE_DIR)/cxx.compile.params"]
        } else {
            cxxFlags = []
        }

        if let linkParams = platformVariant.linkParams {
            // Drop the `bazel-out` prefix since we use the env var for this
            // portion of the path
            buildSettings.append(
                .init(
                    key: "LINK_PARAMS_FILE",
                    value: #"""
"$(BAZEL_OUT)\#(linkParams.dropFirst(9))"
"""#
                )
            )
            buildSettings.append(
                .init(
                    key: "OTHER_LDFLAGS",
                    value: #""@$(DERIVED_FILE_DIR)/link.params""#
                )
            )
        }

        // Set VFS overlays

        var cFlagsPrefix: [String] = []
        var cxxFlagsPrefix: [String] = []
        var swiftFlagsPrefix: [String] = []

        // Work around stubbed swiftc messing with Indexing setting of
        // `-working-directory` incorrectly
        if buildMode == .bazel {
            if false /* FIXME */ {
                swiftFlagsPrefix.append(contentsOf: [
                    "-Xcc",
                    "-working-directory",
                    "-Xcc",
                    "$(PROJECT_DIR)",
                    "-working-directory",
                    "$(PROJECT_DIR)",
                ])
            }
        }
        if !cFlags.isEmpty {
            cFlagsPrefix.append(
                contentsOf: ["-working-directory", "$(PROJECT_DIR)"]
            )
        }
        if !cxxFlags.isEmpty {
            cxxFlagsPrefix.append(
                contentsOf: ["-working-directory", "$(PROJECT_DIR)"]
            )
        }

        if buildMode == .xcode {
            // FIXME: Fix
            if /*target.inputs.containsSourceFiles*/ true {
                if !cFlags.isEmpty {
                    cFlagsPrefix.append(contentsOf: [
                        "-ivfsoverlay",
                        "$(DERIVED_FILE_DIR)/xcode-overlay.yaml",
                    ])
                }
                if !cxxFlags.isEmpty {
                    cxxFlagsPrefix.append(contentsOf: [
                        "-ivfsoverlay",
                        "$(DERIVED_FILE_DIR)/xcode-overlay.yaml",
                    ])
                }
            }
        }

        if !cFlags.isEmpty {
            cFlagsPrefix.append(contentsOf: [
                "-ivfsoverlay",
                "$(OBJROOT)/bazel-out-overlay.yaml",
            ])
        }
        if !cxxFlags.isEmpty {
            cxxFlagsPrefix.append(contentsOf: [
                "-ivfsoverlay",
                "$(OBJROOT)/bazel-out-overlay.yaml",
            ])
        }

        // FIXME: Fix
        if /*buildSettings.keys.contains("PREVIEWS_SWIFT_INCLUDE__YES")*/ false {
            swiftFlagsPrefix.append(
                "$(PREVIEWS_SWIFT_INCLUDE__$(ENABLE_PREVIEWS))"
            )
        }

        var cFlagsString = (cFlagsPrefix + cFlags).joined(separator: " ")
        var cxxFlagsString = (cxxFlagsPrefix + cxxFlags).joined(separator: " ")
        let swiftFlagsString = (swiftFlagsPrefix)
            .joined(separator: " ")

        // Append settings when using ASAN
        // FIXME: Fix
        if /*cHasFortifySource*/ false {
            buildSettings.append(
                .init(
                    key: "ASAN_OTHER_CFLAGS__",
                    value: #""$(ASAN_OTHER_CFLAGS__NO)""#
                )
            )
            buildSettings.append(
                .init(
                    key: "ASAN_OTHER_CFLAGS__NO",
                    value: cFlagsString
                )
            )
            buildSettings.append(
                .init(
                    key: "ASAN_OTHER_CFLAGS__YES",
                    value: #"""
"$(ASAN_OTHER_CFLAGS__NO) -Wno-macro-redefined -D_FORTIFY_SOURCE=0"
"""#
                )
            )
            cFlagsString = #"""
"$(ASAN_OTHER_CFLAGS__$(CLANG_ADDRESS_SANITIZER))"
"""#
        } else if !cFlagsString.isEmpty {
            cFlagsString = cFlagsString.pbxProjEscaped
        }
        // FIXME: Fix
        if /*cxxHasFortifySource*/ false {
            buildSettings.append(
                .init(
                    key: "ASAN_OTHER_CPLUSPLUSFLAGS__",
                    value: #""$(ASAN_OTHER_CPLUSPLUSFLAGS__NO)""#
                )
            )
            buildSettings.append(
                .init(
                    key: "ASAN_OTHER_CPLUSPLUSFLAGS__NO",
                    value: cxxFlagsString
                )
            )
            buildSettings.append(
                .init(
                    key: "ASAN_OTHER_CPLUSPLUSFLAGS__YES",
                    value: #"""
"$(ASAN_OTHER_CPLUSPLUSFLAGS__NO) -Wno-macro-redefined -D_FORTIFY_SOURCE=0"
"""#
                )
            )
            cxxFlagsString = """
"$(ASAN_OTHER_CPLUSPLUSFLAGS__$(CLANG_ADDRESS_SANITIZER))"
"""
        } else if !cxxFlagsString.isEmpty {
            cxxFlagsString = cxxFlagsString.pbxProjEscaped
        }

        if !cFlagsString.isEmpty {
            buildSettings.append(
                .init(key: "OTHER_CFLAGS", value: cFlagsString)
            )
        }
        if !cxxFlagsString.isEmpty {
            buildSettings.append(
                .init(
                    key: "OTHER_CPLUSPLUSFLAGS",
                    value: cxxFlagsString
                )
            )
        }

        // FIXME: Extract
        if let compilerBuildSettingsFile =
            platformVariant.compilerBuildSettingsFile
        {
            // FIXME: Wrap in better precondition error that mentions url
            for try await line in compilerBuildSettingsFile.lines {
                let components = line.split(separator: "\t", maxSplits: 1)
                guard components.count == 2 else {
                    throw PreconditionError(message: """
"\(compilerBuildSettingsFile.path)": Invalid format, missing tab separator.
""")
                }
                buildSettings.append(
                    .init(
                        key: String(components[0]),
                        value: String(components[1])
                    )
                )
            }
        }

        return buildSettings
    }
}

struct PlatformVariantBuildSetting: Equatable {
    let key: String
    let value: String
}

private extension Platform.OS {
    var deploymentTargetBuildSettingKey: String {
        switch self {
        case .macOS: return "MACOSX_DEPLOYMENT_TARGET"
        case .iOS: return "IPHONEOS_DEPLOYMENT_TARGET"
        case .tvOS: return "TVOS_DEPLOYMENT_TARGET"
        case .watchOS: return "WATCHOS_DEPLOYMENT_TARGET"
        }
    }

    var sdkRoot: String {
        switch self {
        case .macOS: return "macosx"
        case .iOS: return "iphoneos"
        case .tvOS: return "appletvos"
        case .watchOS: return "watchos"
        }
    }
}

private extension BazelPath {
    var buildSetting: String {
        if path.starts(with: "bazel-out/") {
            return "$(BAZEL_OUT)\(path.dropFirst(9))"
        }
        if path.starts(with: "external/") {
            return "$(BAZEL_EXTERNAL)\(path.dropFirst(8))"
        }
        if path.starts(with: "../") {
            return "$(BAZEL_EXTERNAL)\(path.dropFirst(2))"
        }
        return path
    }
}

private extension PBXProductType {
    var fileExtension: String? {
        switch self {
        case .application,
                .messagesApplication,
                .onDemandInstallCapableApplication,
                .watchApp,
                .watch2App,
                .watch2AppContainer:
            return "app"
        case .appExtension,
                .intentsServiceExtension,
                .messagesExtension,
                .stickerPack,
                .tvExtension,
                .extensionKitExtension,
                .watchExtension,
                .watch2Extension,
                .xcodeExtension:
            return "appex"
        case .resourceBundle, .bundle:
            return "bundle"
        case .ocUnitTestBundle:
            return "octest"
        case .unitTestBundle, .uiTestBundle:
            return "xctest"
        case .framework, .staticFramework:
            return "framework"
        case .xcFramework:
            return "xcframework"
        case .dynamicLibrary:
            return "dylib"
        case .staticLibrary:
            return "a"
        case .driverExtension:
            return "dext"
        case .instrumentsPackage:
            return "instrpkg"
        case .metalLibrary:
            return "metallib"
        case .systemExtension:
            return "systemextension"
        case .commandLineTool:
            return nil
        case .xpcService:
            return "xpc"
        }
    }
}
