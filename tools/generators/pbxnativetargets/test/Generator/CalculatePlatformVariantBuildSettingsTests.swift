import CustomDump
import GeneratorCommon
import PBXProj
import XCTest

@testable import pbxnativetargets

class CalculatePlatformVariantBuildSettingsTests: XCTestCase {

    // MARK: - buildMode

    func test_bwb() {
        // Arrange

        let buildMode = BuildMode.bazel
        let platformVariant = Target.PlatformVariant.mock()

        let expectedBuildSettings = baseBuildSettings

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            buildMode: buildMode,
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_bwx() {
        // Arrange

        let buildMode = BuildMode.xcode
        let platformVariant = Target.PlatformVariant.mock()

        let expectedBuildSettings = baseBuildSettings
            .updating([
                "OTHER_SWIFT_FLAGS": #"""
-Xcc -ivfsoverlay \#
-Xcc $(DERIVED_FILE_DIR)/xcode-overlay.yaml \#
-Xcc -ivfsoverlay \#
-Xcc $(OBJROOT)/bazel-out-overlay.yaml
"""#.pbxProjEscaped,
            ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            buildMode: buildMode,
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    // MARK: platformVariant

    func test_arch() {
        // Arrange

        let platformVariant = Target.PlatformVariant.mock(
            arch: "x86_64"
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "ARCHS": "x86_64",
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_arch_escaped() {
        // Arrange

        let platformVariant = Target.PlatformVariant.mock(
            arch: "something-odd"
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "ARCHS": #""something-odd""#,
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_compileTargets() {
        // Arrange

        let platformVariant = Target.PlatformVariant.mock(
            compileTargetIDs: "B config A config"
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "BAZEL_COMPILE_TARGET_IDS": #""B config A config""#,
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_compileParams() {
        // Arrange

        let platformVariant = Target.PlatformVariant.mock(
            cParams: "bazel-out/some/c.params",
            cxxParams: "bazel-out/some/cxx.params",
            swiftParams: "bazel-out/some/swift.params"
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "C_PARAMS_FILE": "$(BAZEL_OUT)/some/c.params".pbxProjEscaped,
            "OTHER_CFLAGS": #"""
-working-directory $(PROJECT_DIR) \#
@$(DERIVED_FILE_DIR)/c.compile.params
"""#.pbxProjEscaped,
            "CXX_PARAMS_FILE":
                "$(BAZEL_OUT)/some/cxx.params".pbxProjEscaped,
            "OTHER_CPLUSPLUSFLAGS": #"""
-working-directory $(PROJECT_DIR) \#
@$(DERIVED_FILE_DIR)/cxx.compile.params
"""#.pbxProjEscaped,
            "SWIFT_PARAMS_FILE":
                "$(BAZEL_OUT)/some/swift.params".pbxProjEscaped,
            "OTHER_SWIFT_FLAGS": #"""
-Xcc -working-directory \#
-Xcc $(PROJECT_DIR) \#
-working-directory $(PROJECT_DIR) \#
-vfsoverlay $(OBJROOT)/bazel-out-overlay.yaml
"""#.pbxProjEscaped
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_entitlements_bwb() {
        // Arrange

        let buildMode = BuildMode.bazel
        let platformVariant = Target.PlatformVariant.mock(
            entitlements: "bazel-out/some/app.entitlements"
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION": "YES",
            "CODE_SIGN_ENTITLEMENTS": #""$(BAZEL_OUT)/some/app.entitlements""#,
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            buildMode: buildMode,
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_entitlements_bwx() {
        // Arrange

        let buildMode = BuildMode.xcode
        let platformVariant = Target.PlatformVariant.mock(
            entitlements: "some/app.entitlements"
        )

        let expectedBuildSettings = bwxBuildSettings.updating([
            "CODE_SIGN_ENTITLEMENTS": "some/app.entitlements",
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            buildMode: buildMode,
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_executableExtension() {
        // Arrange

        let productType = PBXProductType.dynamicLibrary
        let platformVariant = Target.PlatformVariant.mock(
            productPath: "some/tool.so"
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "EXECUTABLE_EXTENSION": "so",
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            productType: productType,
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_executableExtension_empty() {
        // Arrange

        let productType = PBXProductType.dynamicLibrary
        let platformVariant = Target.PlatformVariant.mock(
            productPath: "some/tool"
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "EXECUTABLE_EXTENSION": #""""#,
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            productType: productType,
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_executableName_same() {
        // Arrange

        let platformVariant = Target.PlatformVariant.mock(
            productName: "tool",
            executableName: "tool"
        )

        let expectedBuildSettings = baseBuildSettings

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_executableName_different() {
        // Arrange

        let platformVariant = Target.PlatformVariant.mock(
            productName: "tool",
            executableName: "other name"
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "EXECUTABLE_NAME": "other name".pbxProjEscaped,
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_id() {
        // Arrange

        let platformVariant = Target.PlatformVariant.mock(
            id: "ID config"
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "BAZEL_TARGET_ID": "ID config".pbxProjEscaped,
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_linkParams() {
        // Arrange

        let platformVariant = Target.PlatformVariant.mock(
            linkParams: "bazel-out/some/link.params"
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "LINK_PARAMS_FILE":
                "$(BAZEL_OUT)/some/link.params".pbxProjEscaped,
            "OTHER_LDFLAGS":
                "@$(DERIVED_FILE_DIR)/link.params".pbxProjEscaped,
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_packageBinDir() {
        // Arrange

        let platformVariant = Target.PlatformVariant.mock(
            packageBinDir: "bazel-out/package/dir"
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "BAZEL_PACKAGE_BIN_DIR": "bazel-out/package/dir".pbxProjEscaped,
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_platform() {
        // Arrange

        let platformVariant = Target.PlatformVariant.mock(
            platform: .tvOSSimulator,
            osVersion: "8"
        )

        let expectedBuildSettings = noPlatformBuildSettings.updating([
            "TVOS_DEPLOYMENT_TARGET": "8.0",
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_unitTest_noTestHost() {
        // Arrange

        let productType = PBXProductType.unitTestBundle
        let platformVariant = Target.PlatformVariant.mock(
            productPath: "a/test.xctest"
        )

        let expectedBuildSettings = baseBuildSettings

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            productType: productType,
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_unitTest_withTestHost() {
        // Arrange

        let productType = PBXProductType.unitTestBundle
        let platformVariant = Target.PlatformVariant.mock(
            productPath: "a/test.xctest",
            testHost: .init(
                packageBinDir: "some/packageBin/dir",
                productPath: "a/path/Host.app",
                executableName: "Executable_Name"
            )
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "TARGET_BUILD_DIR": #"""
$(BUILD_DIR)/some/packageBin/dir$(TARGET_BUILD_SUBPATH)
"""#.pbxProjEscaped,
            "TEST_HOST": #"""
$(BUILD_DIR)/some/packageBin/dir/a/path/Host.app/Executable_Name
"""#.pbxProjEscaped,
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            productType: productType,
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }

    func test_wrappedExtension() {
        // Arrange

        let productType = PBXProductType.bundle
        let platformVariant = Target.PlatformVariant.mock(
            productPath: "another/bundle.odd"
        )

        let expectedBuildSettings = baseBuildSettings.updating([
            "WRAPPER_EXTENSION": "odd",
        ])

        // Act

        let buildSettings = calculatePlatformVariantBuildSettingsWithDefaults(
            productType: productType,
            platformVariant: platformVariant
        )

        // Assert

        XCTAssertNoDifference(
            buildSettings.asDictionary,
            expectedBuildSettings
        )
    }
}

private func calculatePlatformVariantBuildSettingsWithDefaults(
    buildMode: BuildMode = .bazel,
    productType: PBXProductType = .staticLibrary,
    platformVariant: Target.PlatformVariant
) -> [PlatformVariantBuildSetting] {
    return Generator.CalculatePlatformVariantBuildSettings.defaultCallable(
        buildMode: buildMode,
        productType: productType,
        platformVariant: platformVariant
    )
}

private let noPlatformBuildSettings: [String: String] = [
    "ARCHS": "arm64",
    "BAZEL_PACKAGE_BIN_DIR": "some/path",
    "BAZEL_TARGET_ID": "A",
]

private let baseBuildSettings = noPlatformBuildSettings.updating([
    "ARCHS": "arm64",
    "BAZEL_PACKAGE_BIN_DIR": "some/path",
    "BAZEL_TARGET_ID": "A",
    "MACOSX_DEPLOYMENT_TARGET": "9.4.1",
])

private let bwxBuildSettings = baseBuildSettings.updating([
    "OTHER_SWIFT_FLAGS": #"""
-Xcc -ivfsoverlay \#
-Xcc $(DERIVED_FILE_DIR)/xcode-overlay.yaml \#
-Xcc -ivfsoverlay \#
-Xcc $(OBJROOT)/bazel-out-overlay.yaml
"""#.pbxProjEscaped,
])

private extension Target.PlatformVariant {
    static func mock(
        xcodeConfigurations: [String] = ["CONFIG"],
        id: TargetID = "A",
        compileTargetIDs: String? = nil,
        packageBinDir: String = "some/path",
        productPath: String = "bazel-out/some/path/libA.a",
        outputsProductPath: String? = nil,
        platform: Platform = .macOS,
        osVersion: SemanticVersion = "9.4.1",
        arch: String = "arm64",
        productName: String = "productName",
        productBasename: String = "libA.a",
        moduleName: String = "",
        executableName: String? = nil,
        entitlements: BazelPath? = nil,
        conditionalFiles: Set<BazelPath> = [],
        cParams: String? = nil,
        cxxParams: String? = nil,
        swiftParams: String? = nil,
        linkParams: String? = nil,
        hosts: [Target.Host] = [],
        testHost: Target.TestHost? = nil
    ) -> Self {
        return Self(
            xcodeConfigurations: xcodeConfigurations,
            id: id,
            compileTargetIDs: compileTargetIDs,
            packageBinDir: packageBinDir,
            productPath: productPath,
            outputsProductPath: outputsProductPath,
            productName: productName,
            productBasename: productBasename,
            moduleName: moduleName,
            platform: platform,
            osVersion: osVersion,
            arch: arch,
            executableName: executableName,
            entitlements: entitlements,
            conditionalFiles: conditionalFiles,
            cParams: cParams,
            cxxParams: cxxParams,
            swiftParams: swiftParams,
            linkParams: linkParams,
            hosts: hosts,
            testHost: testHost
        )
    }
}

private extension Array where Element == PlatformVariantBuildSetting {
    var asDictionary: [String: String] {
        return Dictionary(uniqueKeysWithValues: map { ($0.key, $0.value) })
    }
}
