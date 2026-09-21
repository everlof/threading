import Foundation

// Resolves this host's process environment and user settings. The portable policy receives
// values; it never reads preferences or assumes where another host installs its tools.
extension AgentEnvironment {
    static func launchEnvironment() -> [String: String] {
        applyingCommandLineTools(to: removingInheritedIdentity(from: ProcessInfo.processInfo.environment))
    }

    static func applyingCommandLineTools(
        to environment: [String: String],
        directory: String = ThreadingCommandLineTools.directory.path,
        isEnabled: Bool = AppSettings.prependsCommandLineToolsToPATH
    ) -> [String: String] {
        prependingCommandLineTools(to: environment, directory: directory, isEnabled: isEnabled)
    }
}
