import Foundation
import os

/// Locates the rollout JSONL file Codex keeps for a conversation.
enum CodexTranscript {

    private struct CacheKey: Hashable {
        let accountPath: String
        let sessionID: TranscriptID
    }

    private static let cachedURLs = OSAllocatedUnfairLock(initialState: [CacheKey: URL]())

    @MainActor
    static func url(sessionID: TranscriptID, for session: AgentSession) -> URL? {
        guard let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) else { return nil }

        return url(sessionID: sessionID, account: account)
    }

    /// Account-taking seam keeps lookup and memoization independently testable from machine
    /// account discovery. Rollout paths are immutable for the lifetime of a conversation.
    static func url(sessionID: TranscriptID, account: AgentAccount) -> URL? {
        let key = CacheKey(
            accountPath: URL(fileURLWithPath: account.configPath).standardizedFileURL.path,
            sessionID: sessionID
        )
        if let cached = cachedURLs.withLock({ $0[key] }) {
            return cached
        }

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
                  url.deletingPathExtension().lastPathComponent.hasSuffix(sessionID.rawValue)
            else { continue }

            cachedURLs.withLock { $0[key] = url }
            return url
        }

        return nil
    }

    static func invalidateCache() {
        cachedURLs.withLock { $0.removeAll() }
    }
}
