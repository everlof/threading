import Foundation

/// Answers whether the agent CLIs are actually reachable from the shell that will launch them.
///
/// Nothing else checks this: `AgentLauncher` trusts the login shell's PATH, so a machine
/// without `claude` on it launches a session whose first output is `command not found` inside
/// a terminal pane — a shell error where a sentence belongs. This probe asks the same login
/// shell the launcher uses (`AgentLauncher.loginShellPath`, the same `command -v` shape as
/// `ExternalAppLauncher.locate`), so its answer and the launch cannot disagree about PATH.
enum AgentCLIProbe {

    struct Result: Equatable {
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
        completion: @escaping @MainActor ([Result]) -> Void
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

    private nonisolated static func locate(_ executable: String, shell: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v \(executable) 2>/dev/null | head -1"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return path(
            fromShellOutput: String(decoding: data, as: UTF8.self),
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
