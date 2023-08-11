import ArgumentParser
import Foundation
import GeneratorCommon
import PBXProj

extension Generator {
    struct Arguments: ParsableArguments {
        @Argument(
            help: """
Path to where the 'pbxnativetargets' 'PBXProj' partial should be written.
""",
            transform: { URL(fileURLWithPath: $0, isDirectory: false) }
        )
        var targetsOutputPath: URL

        @Argument(
            help: """
Path to where the serialized '[Identifiers.BuildFile.SubIdentifiers]' should \
be written.
""",
            transform: { URL(fileURLWithPath: $0, isDirectory: false) }
        )
        var buildFileSubIdentifiersOutputPath: URL

        @Argument(
            help: """
Path to the directory where automatic `.xcscheme` files should be written.
""",
            transform: { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        var xcshemesOutputDirectory: URL

        @Argument(
            help: "Path to the consolidation map.",
            transform: { URL(fileURLWithPath: $0, isDirectory: false) }
        )
        var consolidationMap: URL

        @Argument(help: "`xcodeproj.build_mode`.")
        var buildMode: BuildMode

        @Argument(help: "Name of the default Xcode configuration.")
        var defaultXcodeConfiguration: String

        // FIXME: Consider splitting out like how we do the other attributes (but for a `TopLevelTargetAttributes` instead of `TargetAttributes`). It adds 7 flags, but increases readability of the command-line, and allows the types to be correct
        @Option(
            parsing: .upToNextOption,
            help: """
Tuples of <target> target ID, <outputs-product-path>, <link-params>, \
<entitlements>, <executable-name>, <compile-target-name>, \
<compile-target-ids>, and <test-host>.
"""
        )
        private var topLevelTargets: [String] = []

        @Option(
            name: .customLong("unit-test-hosts"),
            parsing: .upToNextOption,
            help: """
Tuples of <target> target ID, <package-bin-dir>, <product-path>, and \
<executable-name>.
"""
        )
        private var _unitTestHosts: [String] = []

        @OptionGroup var targetsArguments: TargetsArguments

        mutating func validate() throws {
            guard topLevelTargets.count.isMultiple(of: 8) else {
                throw ValidationError("""
<top-level-targets> (\(topLevelTargets.count) objects) must be tuples of \
<target> target ID, <output-product-basename>, <link-params>, <entitlements>, \
<executable-name>, <compile-target-name>, <compile-target-ids>, and <test-host>.
""")
            }

            guard _unitTestHosts.count.isMultiple(of: 4) else {
                throw ValidationError("""
<unit-test-hosts> (\(_unitTestHosts.count) objects) must be tuples of \
<target> target ID, <package-bin-dir>, <product-path>, and <executable-name>.
""")
            }
        }
    }
}

extension Generator.Arguments {
    struct TopLevelTargetAttributes {
        /// e.g. "bazel-out/App.zip" or "bazel-out/App.app"
        let outputsProductPath: String?

        let linkParams: String?
        let entitlements: BazelPath?
        let executableName: String?
        let compileTargetName: String?
        let compileTargetIDs: String?
        let unitTestHost: TargetID?
    }

    struct UnitTestHostAttributes {
        let packageBinDir: String
        let productPath: String
        let executableName: String
    }

    var topLevelTargetAttributes: [TargetID: TopLevelTargetAttributes] {
        return Dictionary(
            uniqueKeysWithValues:
                stride(from: 0, to: topLevelTargets.count - 1, by: 8)
                .lazy
                .map { idx -> (TargetID, TopLevelTargetAttributes) in
                    let outputsProductPath = topLevelTargets[idx+1]
                    let linkParams = topLevelTargets[idx+2]
                    let entitlements = topLevelTargets[idx+3]
                    let executableName = topLevelTargets[idx+4]
                    let compileTargetName = topLevelTargets[idx+5]
                    let compileTargetIDs = topLevelTargets[idx+6]
                    let unitTestHost = topLevelTargets[idx+7]
                    return (
                        TargetID(topLevelTargets[idx]),
                        TopLevelTargetAttributes(
                            outputsProductPath: outputsProductPath.isEmpty ?
                                nil : outputsProductPath,
                            linkParams: linkParams.isEmpty ?
                                nil : linkParams,
                            entitlements: entitlements.isEmpty ?
                                nil : BazelPath(entitlements),
                            executableName: executableName.isEmpty ?
                                nil : executableName,
                            compileTargetName: compileTargetName.isEmpty ?
                                nil : compileTargetName,
                            compileTargetIDs: compileTargetIDs.isEmpty ?
                                nil : compileTargetIDs,
                            unitTestHost: unitTestHost.isEmpty ?
                                nil : TargetID(unitTestHost)
                        )
                    )
                }
        )
    }

    var unitTestHosts: [TargetID: Target.UnitTestHost] {
        return Dictionary(
            uniqueKeysWithValues:
                stride(from: 0, to: _unitTestHosts.count - 1, by: 4)
                .lazy
                .map { idx -> (TargetID, Target.UnitTestHost) in
                    return (
                        TargetID(_unitTestHosts[idx]),
                        Target.UnitTestHost(
                            packageBinDir: _unitTestHosts[idx+1],
                            productPath: _unitTestHosts[idx+2],
                            executableName: _unitTestHosts[idx+3]
                        )
                    )
                }
        )
    }
}
