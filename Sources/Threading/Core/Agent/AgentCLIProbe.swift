import Foundation

/// Answers whether the agent CLIs are actually reachable from the shell that will launch them.
///
/// Nothing else checks this: `AgentLauncher` trusts the login shell's PATH, so a machine
/// without `claude` on it launches a session whose first output is `command not found` inside
/// a terminal pane — a shell error where a sentence belongs. This probe asks the same login
/// shell the launcher uses (`AgentLauncher.loginShellPath`, the same `command -v` shape as
/// `ExternalAppLauncher.locate`), so its answer and the launch cannot disagree about PATH.
enum AgentCLIProbe {

    /// Marks the beginning of the environment emitted by the login-shell probe. Shell profiles
    /// are allowed to print banners before the requested command, so parsing an unframed
    /// `/usr/bin/env` dump can mistake profile prose for the environment that follows it.
    static let environmentMarker = "__threading_agent_login_environment_v1__"

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

    /// Reads the PATH exported by the same login shell that launches agents.
    ///
    /// The marker is printed after the shell has sourced its profile. This makes the answer
    /// immune to a profile banner containing a PATH-looking line, while the bounded child keeps
    /// a noisy or blocked profile from turning discovery into unbounded work.
    nonisolated static func loginShellPATH(
        shell: String,
        environment: [String: String] = AgentEnvironment.launchEnvironment(),
        timeout: TimeInterval = AgentCLIProbeDefaults.timeout,
        maximumOutputBytes: Int = AgentCLIProbeDefaults.maximumOutputBytes
    ) -> String? {
        var marker = ShellCommand(word: "printf")
        marker.append(word: "%s\\n")
        marker.append(word: environmentMarker)
        let dump = ShellCommand(word: AgentCLIProbeDefaults.environmentCommand)
        let source = "\(marker.source); \(dump.source)"

        guard let result = try? BoundedChildProcess.run(
            executable: shell,
            arguments: ["-l", "-c", source],
            environment: environment,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            output: .standardOutput
        ), result.termination == .exited(0), !result.outputWasTruncated else { return nil }

        return path(
            fromLoginEnvironmentOutput: String(decoding: result.output, as: UTF8.self)
        )
    }

    /// Resolves one authored executable name against an already captured PATH.
    ///
    /// The returned path deliberately preserves a stable symlink such as
    /// `~/.local/bin/cursor-agent`; resolving it to a versioned target would leave a successful
    /// self-update pointing at the version it just replaced.
    nonisolated static func locate(
        _ executable: String,
        on pathVariable: String,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String? {
        guard !executable.isEmpty, !executable.contains("/") else { return nil }
        for entry in pathVariable.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = String(entry)
            guard directory.hasPrefix("/") else { continue }
            let candidate = (directory as NSString).appendingPathComponent(executable)
            guard isExecutable(candidate) else { continue }
            return candidate
        }
        return nil
    }

    /// The pure half of `loginShellPATH`. Only lines after the last exact marker belong to the
    /// environment command; everything before it is shell-profile output.
    nonisolated static func path(fromLoginEnvironmentOutput output: String) -> String? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let markerIndex = lines.lastIndex(where: { $0 == environmentMarker[...] }) else {
            return nil
        }
        let prefix = "\(EnvironmentKeys.path)="
        for line in lines[lines.index(after: markerIndex)...] where line.hasPrefix(prefix) {
            let value = String(line.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
        return nil
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
    static let environmentCommand = "/usr/bin/env"
}
