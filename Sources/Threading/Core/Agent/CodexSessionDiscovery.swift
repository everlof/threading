import Foundation

/// Recovers the session identifier Codex assigned to a freshly launched session.
///
/// Codex has no equivalent of Claude's `--session-id`, so the identifier can only be
/// read back after launch. Codex records each session as
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`, whose first line is a
/// `session_meta` record carrying the authoritative identifier and the launch directory.
/// A match uses both creation time and directory; ambiguous concurrent matches remain pending.
enum CodexSessionDiscovery {

    /// Polls for the rollout file belonging to a session launched in `projectPath`.
    ///
    /// Codex writes the file shortly after startup, so this retries on an interval before
    /// giving up. Rollouts live under the launching account's own home, so `codexHome` must
    /// be the account's config directory. The completion is always delivered on the main queue.
    static func discoverSessionID(
        projectPath: String,
        codexHome: String,
        launchedAt: Date,
        completion: @escaping @MainActor @Sendable (TranscriptID?) -> Void
    ) {
        let sessionsDirectory = URL(fileURLWithPath: codexHome)
            .appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory)

        DispatchQueue.global(qos: .utility).async {
            var attemptsRemaining = CodexDiscoveryDefaults.maxAttempts

            while attemptsRemaining > 0 {
                if let sessionID = CodexRolloutIdentity.find(
                    projectPath: projectPath,
                    sessionsDirectory: sessionsDirectory,
                    launchedAt: launchedAt
                ) {
                    DispatchQueue.main.async { completion(sessionID) }
                    return
                }

                attemptsRemaining -= 1
                Thread.sleep(forTimeInterval: CodexDiscoveryDefaults.pollInterval)
            }

            ThreadingLogger.agent.warning(
                "Codex session discovery timed out for \(projectPath, privacy: .private(mask: .hash)) in \(codexHome, privacy: .private(mask: .hash))"
            )
            DispatchQueue.main.async { completion(nil) }
        }
    }

}
