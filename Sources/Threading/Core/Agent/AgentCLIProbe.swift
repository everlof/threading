import Foundation

/// Answers whether the agent CLIs are actually reachable from the shell that will launch them.
///
/// Nothing else checks this: `AgentLauncher` trusts the login shell's PATH, so a machine
/// without `claude` on it launches a session whose first output is `command not found` inside
/// a terminal pane — a shell error where a sentence belongs. This probe asks the same login
/// shell the launcher uses (`AgentLauncher.loginShellPath`, the same `command -v` shape as
/// `ExternalAppLauncher.locate`), so its answer and the launch cannot disagree about PATH.
enum AgentCLIProbe {

    struct Result: Equatable, Sendable {
        let executable: String
        /// The absolute path the login shell resolves, or nil when the command is not found.
        let resolvedPath: String?

        var isInstalled: Bool { resolvedPath != nil }
    }

    /// Resolves each executable off the main thread; one shell per executable, because each
    /// needs its own answer. Results arrive in the order asked.
    @MainActor
    static func resolve(
        executables: [String],
        completion: @escaping @MainActor @Sendable ([Result]) -> Void
    ) {
        let shell = AgentLauncher.loginShellPath
        DispatchQueue.global(qos: .userInitiated).async {
            let results = executables.map { executable in
                Result(executable: executable, resolvedPath: locate(executable, shell: shell))
            }
            Task { @MainActor in
                completion(results)
            }
        }
    }

    /// Shared by external-editor discovery so every login-shell lookup has the same quoting,
    /// deadline, size bound, and executable validation.
    nonisolated static func locate(_ executable: String, shell: String) -> String? {
        var command = ShellCommand(word: "command")
        command.append(word: "-v")
        command.append(word: executable)
        guard let result = try? BoundedChildProcess.run(
            executable: shell,
            arguments: ["-l", "-c", command.source],
            timeout: AgentCLIProbeDefaults.timeout,
            maximumOutputBytes: AgentCLIProbeDefaults.maximumOutputBytes,
            output: .standardOutput
        ), result.termination == .exited(0), !result.outputWasTruncated else { return nil }

        return path(
            fromShellOutput: String(decoding: result.output, as: UTF8.self),
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// The pure half: turns raw `command -v` output into a validated absolute path. A shell
    /// that prints an alias definition, an error, or nothing at all answers nil.
    nonisolated static func path(
        fromShellOutput output: String,
        isExecutable: (String) -> Bool
    ) -> String? {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\n"), isExecutable(path) else { return nil }
        return path
    }
}

private enum AgentCLIProbeDefaults {
    static let timeout: TimeInterval = 5
    static let maximumOutputBytes = 64 * 1024
}
