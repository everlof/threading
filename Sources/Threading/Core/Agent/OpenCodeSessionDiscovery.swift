import Foundation

/// Recovers the session identifier OpenCode assigned to a freshly launched TUI.
///
/// OpenCode has no flag for choosing a new session id. Its supported `session list --format
/// json` command reports each id, creation time, and directory, which is enough to distinguish a
/// new launch from older conversations in the same checkout without depending on OpenCode's
/// private database layout.
enum OpenCodeSessionDiscovery {

    // MARK: - Types

    private struct ListedSession: Decodable {
        let id: String
        let created: TimeInterval
        let directory: String
    }

    // MARK: - Public Methods

    /// Polls OpenCode's session listing for the conversation created by this launch.
    /// Completion is always delivered on the main actor.
    @MainActor
    static func discoverSessionID(
        projectPath: String,
        launchedAt: Date,
        completion: @escaping @MainActor @Sendable (TranscriptID?) -> Void
    ) {
        let shell = AgentLauncher.loginShellPath

        DispatchQueue.global(qos: .utility).async {
            var attemptsRemaining = OpenCodeDiscoveryDefaults.maxAttempts

            while attemptsRemaining > 0 {
                if let output = sessionList(projectPath: projectPath, shell: shell),
                   let sessionID = sessionID(
                       in: output,
                       projectPath: projectPath,
                       launchedAt: launchedAt
                   ) {
                    Task { @MainActor in completion(sessionID) }
                    return
                }

                attemptsRemaining -= 1
                if attemptsRemaining > 0 {
                    Thread.sleep(forTimeInterval: OpenCodeDiscoveryDefaults.pollInterval)
                }
            }

            ThreadingLogger.agent.warning(
                "OpenCode session discovery timed out for \(projectPath, privacy: .public)"
            )
            Task { @MainActor in completion(nil) }
        }
    }

    /// The pure selection half, internal so fixtures can pin OpenCode's public JSON contract.
    static func sessionID(
        in data: Data,
        projectPath: String,
        launchedAt: Date
    ) -> TranscriptID? {
        guard let sessions = try? JSONDecoder().decode([ListedSession].self, from: data) else {
            return nil
        }

        let cutoff = launchedAt.addingTimeInterval(-OpenCodeDiscoveryDefaults.clockSlack)
        let project = normalized(projectPath)

        return sessions
            .filter { $0.id.hasPrefix(OpenCodeDiscoveryDefaults.sessionIDPrefix) }
            .filter { normalized($0.directory) == project }
            .filter { Date(timeIntervalSince1970: $0.created / 1_000) >= cutoff }
            .max { $0.created < $1.created }
            .map { TranscriptID($0.id) }
    }

    // MARK: - Private Methods

    private static func sessionList(projectPath: String, shell: String) -> Data? {
        var command = ShellCommand(word: AgentDefaults.openCodeExecutable)
        command.append(word: "session")
        command.append(word: "list")
        command.append(flag: "--max-count", value: String(OpenCodeDiscoveryDefaults.sessionListLimit))
        command.append(flag: "--format", value: "json")

        guard let result = try? BoundedChildProcess.run(
            executable: shell,
            arguments: [
                "-l",
                "-c",
                ShellCommand.executing(command, in: projectPath).source
            ],
            environment: AgentEnvironment.launchEnvironment(),
            timeout: OpenCodeDiscoveryDefaults.commandTimeout,
            maximumOutputBytes: OpenCodeDiscoveryDefaults.maximumSessionListBytes,
            output: .standardOutput
        ), result.termination == .exited(0), !result.outputWasTruncated else { return nil }
        return result.output
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
