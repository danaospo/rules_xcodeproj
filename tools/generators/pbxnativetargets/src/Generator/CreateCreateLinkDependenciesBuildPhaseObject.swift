import GeneratorCommon
import PBXProj

extension Generator {
    struct CreateCreateLinkDependenciesBuildPhaseObject {
        private let callable: Callable

        /// - Parameters:
        ///   - callable: The function that will be called in
        ///     `callAsFunction()`.
        init(callable: @escaping Callable = Self.defaultCallable) {
            self.callable = callable
        }

        /// Creates the "Create Link Dependencies" build phase object for a
        /// target.
        func callAsFunction(
            buildMode: BuildMode,
            subIdentifier: Identifiers.Targets.SubIdentifier,
            hasCompileStub: Bool
        ) -> Object {
            return callable(
                /*buildMode:*/ buildMode,
                /*subIdentifier:*/ subIdentifier,
                /*hasCompileStub:*/ hasCompileStub
            )
        }
    }
}

// MARK: - CreateCreateLinkDependenciesBuildPhaseObject.Callable

extension Generator.CreateCreateLinkDependenciesBuildPhaseObject {
    typealias Callable = (
        _ buildMode: BuildMode,
        _ subIdentifier: Identifiers.Targets.SubIdentifier,
        _ hasCompileStub: Bool
    ) -> Object

    static func defaultCallable(
        buildMode: BuildMode,
        subIdentifier: Identifiers.Targets.SubIdentifier,
        hasCompileStub: Bool
    ) -> Object {
        let action = #"""
perl -pe 's/\$(\()?([a-zA-Z_]\w*)(?(1)\))/$ENV{$2}/g' \
  "$SCRIPT_INPUT_FILE_0" > "$SCRIPT_OUTPUT_FILE_0"
"""#
        var shellScriptComponents: [String]
        if buildMode == .xcode {
            shellScriptComponents = [
                #"""
set -euo pipefail

if [[ "$ACTION" == "indexbuild" ]]; then
  touch "$SCRIPT_OUTPUT_FILE_0"
else
\#(action)
fi

"""#,
            ]
        } else {
            shellScriptComponents = [
                #"""
set -euo pipefail

if [[ "${ENABLE_PREVIEWS:-}" == "YES" ]]; then
\#(action)
else
  touch "$SCRIPT_OUTPUT_FILE_0"
fi

"""#,
            ]
        }

        var outputPaths = [#"""
				"$(DERIVED_FILE_DIR)/link.params",
"""#]
        if hasCompileStub {
            outputPaths.append(#"""
				"$(DERIVED_FILE_DIR)/_CompileStub_.m",
"""#)
            shellScriptComponents.append(#"""
touch "$SCRIPT_OUTPUT_FILE_1"

"""#)
        }

        // The tabs for indenting are intentional
        let content = #"""
{
			isa = PBXShellScriptBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			inputPaths = (
				"$(LINK_PARAMS_FILE)",
			);
			name = "Create Link Dependencies";
			outputPaths = (
\#(outputPaths.joined(separator: "\n"))
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = \#(
    shellScriptComponents.joined(separator: "\n").pbxProjEscaped
);
			showEnvVarsInLog = 0;
		}
"""#

        return Object(
            identifier: Identifiers.Targets.buildPhase(
                .createLinkDependencies,
                subIdentifier: subIdentifier
            ),
            content: content
        )
    }
}
