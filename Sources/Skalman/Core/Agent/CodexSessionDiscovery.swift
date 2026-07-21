import Foundation

/// Recovers the session identifier Codex assigned to a freshly launched session.
///
/// Codex has no equivalent of Claude's `--session-id`, so the identifier can only be
/// read back after launch. Codex records each session as
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`, whose first line is a
/// `session_meta` record carrying the authoritative identifier and the launch directory.
/// Matching on both creation time and directory keeps concurrent launches distinct.
enum CodexSessionDiscovery {

    // MARK: - Types

    /// The `session_meta` record written as the first line of every rollout file.
    private struct RolloutHeader: Decodable {
        let type: String
        let payload: Payload

        struct Payload: Decodable {
            let id: String
            let cwd: String
        }
    }

    // MARK: - Public Methods

    /// Polls for the rollout file belonging to a session launched in `projectPath`.
    ///
    /// Codex writes the file shortly after startup, so this retries on an interval before
    /// giving up. Rollouts live under the launching account's own home, so `codexHome` must
    /// be the account's config directory. The completion is always delivered on the main queue.
    static func discoverSessionID(
        projectPath: String,
        codexHome: String,
        launchedAt: Date,
        completion: @escaping (String?) -> Void
    ) {
        let sessionsDirectory = URL(fileURLWithPath: codexHome)
            .appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory)

        DispatchQueue.global(qos: .utility).async {
            var attemptsRemaining = CodexDiscoveryDefaults.maxAttempts

            while attemptsRemaining > 0 {
                if let sessionID = findSessionID(
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

            SkalmanLogger.agent.warning(
                "Codex session discovery timed out for \(projectPath, privacy: .public) in \(codexHome, privacy: .public)"
            )
            DispatchQueue.main.async { completion(nil) }
        }
    }

    // MARK: - Private Methods

    /// Scans for the newest rollout file created after `launchedAt` whose recorded
    /// working directory matches the project.
    private static func findSessionID(
        projectPath: String,
        sessionsDirectory: URL,
        launchedAt: Date
    ) -> String? {
        let cutoff = launchedAt.addingTimeInterval(-CodexDiscoveryDefaults.clockSlack)
        let normalizedProjectPath = normalized(projectPath)

        let candidates = rolloutFiles(in: sessionsDirectory)
            .compactMap { url -> (URL, Date)? in
                guard let created = creationDate(of: url), created >= cutoff else { return nil }
                return (url, created)
            }
            .sorted { $0.1 > $1.1 }

        for (url, _) in candidates {
            guard let header = readHeader(at: url),
                  header.type == CodexDiscoveryDefaults.sessionMetaType,
                  normalized(header.payload.cwd) == normalizedProjectPath else { continue }

            return header.payload.id
        }

        return nil
    }

    /// Enumerates every rollout file beneath a Codex sessions directory, which is
    /// nested by year, month, and day.
    private static func rolloutFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  url.pathExtension == CodexDiscoveryDefaults.rolloutExtension,
                  url.lastPathComponent.hasPrefix(CodexDiscoveryDefaults.rolloutPrefix) else { return nil }
            return url
        }
    }

    /// Reads and decodes the first line of a rollout file.
    ///
    /// Only a bounded prefix is read: a rollout file grows with the conversation, but the
    /// `session_meta` record is always first.
    private static func readHeader(at url: URL) -> RolloutHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let prefix = try? handle.read(upToCount: CodexDiscoveryDefaults.headerReadLimit),
              let text = String(data: prefix, encoding: .utf8),
              let firstLine = text.split(separator: "\n", maxSplits: 1).first,
              let lineData = firstLine.data(using: .utf8) else { return nil }

        return try? JSONDecoder().decode(RolloutHeader.self, from: lineData)
    }

    private static func creationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    /// Normalizes a path so symlinked and trailing-slash variants compare equal.
    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
