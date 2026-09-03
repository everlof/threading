import Foundation
import os

enum CodexTranscriptDefaults {
    /// How long one walk of an account's sessions tree answers misses before the next lookup
    /// that misses walks again.
    ///
    /// The bound folds a burst — the search projection asking for every conversation in the
    /// catalogue, a row reconfigured on every tick of a working agent — into one read, and it
    /// is short: Codex writes a rollout within a second of starting, and the lifecycle hook
    /// that reports the file's exact path arrives sooner still and is admitted without any walk.
    static let rolloutIndexMaximumAge: TimeInterval = 1

    /// The conversation id a rollout's name ends with is a UUID.
    static let sessionIDLength = 36
}

/// Locates the rollout JSONL file Codex keeps for a conversation.
enum CodexTranscript {

    private struct CacheKey: Hashable {
        let accountPath: String
        let sessionID: TranscriptID
    }

    /// Every rollout beneath one account's `sessions` directory, as one walk found them.
    ///
    /// A miss used to cost a walk of the whole tree — nested by year, month and day, holding
    /// every conversation the account ever had — and a miss is the *common* case for a retained
    /// catalogue: an archived conversation's rollout is pruned long before its session row is.
    /// The search projection asked for 311 such sessions in one pass, on the main actor, and each
    /// walked the same 672 entries; see `performance.md`. Reading the tree once and answering
    /// every lookup from the result makes a pass cost one walk, and lets that walk run off the
    /// main actor while the projection reads only what is already known.
    struct RolloutIndex: Sendable {
        let accountPath: String
        let walkedAt: Date
        /// Keyed by the conversation id each rollout's name ends with.
        fileprivate var urlsBySessionID: [String: URL]
        /// Every rollout, for an id that is not a UUID and so cannot be keyed above.
        fileprivate var rollouts: [(stem: String, url: URL)]

        var count: Int { rollouts.count }

        func url(for sessionID: TranscriptID) -> URL? {
            let raw = sessionID.rawValue
            guard raw.count != CodexTranscriptDefaults.sessionIDLength else {
                return urlsBySessionID[raw]
            }
            return rollouts.first { $0.stem.hasSuffix(raw) }?.url
        }

        /// Records one rollout. A walk hands every entry exactly once, so the only caller that
        /// has to ask first is the reported-path route, which checks `url(for:)` before it admits.
        fileprivate mutating func admit(_ url: URL) {
            let stem = url.deletingPathExtension().lastPathComponent
            rollouts.append((stem, url))
            if stem.count >= CodexTranscriptDefaults.sessionIDLength {
                urlsBySessionID[String(stem.suffix(CodexTranscriptDefaults.sessionIDLength))] = url
            }
        }
    }

    private struct State {
        /// Paths already found. Immutable for the lifetime of a conversation, so never aged.
        var urls: [CacheKey: URL] = [:]
        /// The last walk of each account's tree, keyed by the account's standardized path.
        var indexes: [String: RolloutIndex] = [:]
        var walkCount = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

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
    ///
    /// A miss is answered by the account's rollout index, which is read at most once per
    /// `rolloutIndexMaximumAge` however many conversations ask. A caller with a whole catalogue
    /// to resolve on the main actor should not be here at all: it asks `knownURL` and has
    /// `rolloutIndex` read the tree off the main actor first.
    static func url(
        sessionID: TranscriptID,
        account: AgentAccount,
        now: Date = Date()
    ) -> URL? {
        let key = cacheKey(sessionID: sessionID, account: account)
        if let cached = state.withLock({ $0.urls[key] }) {
            return cached
        }

        guard let url = rolloutIndex(account: account, now: now).url(for: sessionID) else {
            return nil
        }
        state.withLock { $0.urls[key] = url }
        return url
    }

    /// The path already known for a conversation, without reading the filesystem.
    ///
    /// Nil says only that nothing has looked yet — or that the last walk did not see the
    /// rollout, which for a pruned conversation is the durable answer. This is the lookup for
    /// work on the main actor that covers many conversations: a projection of the whole session
    /// catalogue reads dictionaries here and lets `rolloutIndex` do the one walk elsewhere.
    static func knownURL(sessionID: TranscriptID, account: AgentAccount) -> URL? {
        let key = cacheKey(sessionID: sessionID, account: account)
        return state.withLock { state in
            if let url = state.urls[key] { return url }
            guard let url = state.indexes[key.accountPath]?.url(for: sessionID) else { return nil }
            state.urls[key] = url
            return url
        }
    }

    /// One account's rollouts: the last walk while it is younger than `maximumAge`, else a fresh
    /// one. The walk enumerates the whole sessions tree, so a caller that has many conversations
    /// to place calls this once, off the main actor, and then answers each from `knownURL`.
    @discardableResult
    static func rolloutIndex(
        account: AgentAccount,
        maximumAge: TimeInterval = CodexTranscriptDefaults.rolloutIndexMaximumAge,
        now: Date = Date()
    ) -> RolloutIndex {
        let accountPath = standardizedPath(of: account)
        if let index = state.withLock({ $0.indexes[accountPath] }),
           index.walkedAt <= now,
           now.timeIntervalSince(index.walkedAt) < maximumAge {
            return index
        }

        let index = walk(accountPath: accountPath, at: now)
        state.withLock {
            $0.indexes[accountPath] = index
            $0.walkCount += 1
        }
        return index
    }

    /// How many sessions trees have been read since launch.
    ///
    /// The one-walk-per-pass rule is a performance contract, and a contract nothing asserts is
    /// one refactor from gone: a test drives a burst of lookups through the production path and
    /// reads this instead of timing anything.
    static var rolloutWalkCount: Int {
        state.withLock { $0.walkCount }
    }

    /// Validates and remembers the exact rollout path Codex reported through a lifecycle hook.
    ///
    /// The hook already knows the file, so enumerating the account's complete session tree to
    /// rediscover it would put externally growing filesystem work on a turn callback. The path
    /// is still treated as input: it must resolve below this account's `sessions` directory and
    /// carry the reported conversation id before it is admitted to the same immutable-path cache
    /// as a discovered rollout — and to the account's index, so a lookup arriving between the
    /// report and the next walk does not read the conversation as having no transcript.
    static func url(
        reportedPath: String,
        sessionID: TranscriptID,
        account: AgentAccount
    ) -> URL? {
        let sessionsRoot = URL(fileURLWithPath: account.configPath, isDirectory: true)
            .appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: reportedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard candidate.path.hasPrefix(sessionsRoot.path + "/"),
              isRollout(candidate, for: sessionID) else {
            return nil
        }

        let key = cacheKey(sessionID: sessionID, account: account)
        state.withLock { state in
            state.urls[key] = candidate
            if state.indexes[key.accountPath]?.url(for: sessionID) == nil {
                state.indexes[key.accountPath]?.admit(candidate)
            }
        }
        return candidate
    }

    /// Reads Codex's current user-facing name for a conversation.
    ///
    /// The rollout itself carries no title. Current Codex releases keep the canonical name in
    /// `<CODEX_HOME>/session_index.jsonl`, one bounded record per thread, and rewrite that index
    /// when `/rename` or `thread/name/set` succeeds. Read the whole small index rather than
    /// guessing from terminal output; the latter is presentation copy and may be localized.
    static func title(sessionID: TranscriptID, account: AgentAccount) -> String? {
        titles(account: account)[sessionID]
    }

    /// Reads the account index once, used at launch to refresh every retained Codex session
    /// without paying one full scan per sidebar row.
    static func titles(account: AgentAccount) -> [TranscriptID: String] {
        let index = URL(fileURLWithPath: account.configPath)
            .appendingPathComponent(CodexDiscoveryDefaults.sessionIndexFile)
        var titles: [TranscriptID: String] = [:]

        JSONLReader.forEachRecord(
            at: index,
            limit: CodexDiscoveryDefaults.sessionIndexScanLimit
        ) { record in
            guard let rawID = record["id"] as? String else { return true }
            let candidate = (record["thread_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let candidate, !candidate.isEmpty {
                titles[TranscriptID(rawID)] = candidate
            }
            return true
        }

        return titles
    }

    /// Forgets every path and every walk. The walk count stays, so a test measures a difference.
    static func invalidateCache() {
        state.withLock {
            $0.urls.removeAll()
            $0.indexes.removeAll()
        }
    }

    // MARK: - Private Methods

    private static func walk(accountPath: String, at date: Date) -> RolloutIndex {
        let root = URL(fileURLWithPath: accountPath)
            .appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory)
        let span = PerformanceRecorder.shared.begin(
            "codex.rollouts.walk",
            category: "transcripts"
        )
        var index = RolloutIndex(
            accountPath: accountPath,
            walkedAt: date,
            urlsBySessionID: [:],
            rollouts: []
        )
        defer { span.end(metadata: ["rollouts": String(index.count)]) }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return index }

        for case let url as URL in enumerator where isRollout(url) {
            index.admit(url)
        }
        return index
    }

    private static func cacheKey(
        sessionID: TranscriptID,
        account: AgentAccount
    ) -> CacheKey {
        CacheKey(
            accountPath: standardizedPath(of: account),
            sessionID: sessionID
        )
    }

    private static func standardizedPath(of account: AgentAccount) -> String {
        URL(fileURLWithPath: account.configPath).standardizedFileURL.path
    }

    private static func isRollout(_ url: URL) -> Bool {
        url.pathExtension == CodexDiscoveryDefaults.rolloutExtension
            && url.lastPathComponent.hasPrefix(CodexDiscoveryDefaults.rolloutPrefix)
    }

    private static func isRollout(_ url: URL, for sessionID: TranscriptID) -> Bool {
        isRollout(url)
            && url.deletingPathExtension().lastPathComponent.hasSuffix(sessionID.rawValue)
    }
}
