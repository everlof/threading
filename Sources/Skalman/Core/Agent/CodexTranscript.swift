import Foundation

/// Locates the rollout JSONL file Codex keeps for a conversation.
enum CodexTranscript {

    static func url(sessionID: String, for session: AgentSession) -> URL? {
        guard let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) else { return nil }

        let root = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory)

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.pathExtension == CodexDiscoveryDefaults.rolloutExtension,
                  url.lastPathComponent.hasPrefix(CodexDiscoveryDefaults.rolloutPrefix),
                  url.deletingPathExtension().lastPathComponent.hasSuffix(sessionID)
            else { continue }
            return url
        }

        return nil
    }
}
