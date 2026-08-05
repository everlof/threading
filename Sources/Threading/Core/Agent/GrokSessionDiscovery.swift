import Foundation
import os

/// Confirms that the caller-minted Grok UUID has become a persisted conversation.
///
/// Grok accepts `--session-id`, but it does not create the session while its first-launch
/// browser authentication screen is still open. Persisting the UUID before this check would
/// make a quit from that screen relaunch with `--resume` for a conversation that never existed.
enum GrokSessionDiscovery {

    /// Polls Grok's supported session-list command off the main actor. The expected UUID is
    /// unique, so unlike provider-assigned discovery there is no timestamp or checkout race to
    /// resolve; the project directory merely scopes Grok's list to the launching workspace.
    @MainActor
    static func discoverSessionID(
        _ expectedID: TranscriptID,
        projectPath: String,
        completion: @escaping @MainActor @Sendable (TranscriptID?) -> Void
    ) {
        let shell = AgentLauncher.loginShellPath
        DispatchQueue.global(qos: .utility).async {
            var attemptsRemaining = GrokDiscoveryDefaults.maxAttempts
            while attemptsRemaining > 0 {
                if let output = listSessions(projectPath: projectPath, shell: shell),
                   contains(expectedID, in: output) {
                    Task { @MainActor in completion(expectedID) }
                    return
                }

                attemptsRemaining -= 1
                if attemptsRemaining > 0 {
                    Thread.sleep(forTimeInterval: GrokDiscoveryDefaults.pollInterval)
                }
            }

            ThreadingLogger.session.debug(
                "Grok session \(expectedID.rawValue, privacy: .public) is not persisted yet"
            )
            Task { @MainActor in completion(nil) }
        }
    }

    /// Pure output matching for fixtures. UUID characters on either side mean the value is
    /// embedded in another token rather than a session row.
    static func contains(_ expectedID: TranscriptID, in output: String) -> Bool {
        let expected = expectedID.rawValue.lowercased()
        let uuidCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return output.components(separatedBy: uuidCharacters.inverted).contains {
            $0.lowercased() == expected
        }
    }

    private nonisolated static func listSessions(
        projectPath: String,
        shell: String
    ) -> String? {
        var command = ShellCommand(word: AgentDefaults.grokExecutable)
        command.append(word: "sessions")
        command.append(word: "list")
        command.append(flag: "--limit", value: String(GrokDiscoveryDefaults.sessionListLimit))
        let source = ShellCommand.executing(command, in: projectPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", source.source]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
