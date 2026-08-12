import Foundation

// MARK: - Wire Types

/// `.claude.json` → `cachedUsageUtilization`: the CLI's own copy of the last usage reading it
/// took from the API, kept beside the rest of its per-account state. Which `.claude.json` is
/// `profileURLs(for:home:)`, and it is not always the one under the config directory. The
/// cached document is the endpoint's response verbatim, so it decodes as `ClaudeUtilization` —
/// the same type the live fetch reads off the wire.
private struct ClaudeProfileFile: Decodable {
    let cachedUsageUtilization: CachedUsage?

    struct CachedUsage: Decodable {
        /// Epoch **milliseconds**, like the credentials file's expiry and unlike Codex.
        let fetchedAtMs: Double?
        let utilization: ClaudeUtilization?
    }
}

// MARK: - Claude Usage Profile Cache

/// Reads the usage snapshot Claude Code stores in its own per-account `.claude.json`.
///
/// This is the only **local** source that names a model-scoped limit — the status-line feed
/// does not carry one — which matters for the account whose reading comes from that feed: a
/// plan meters some models separately (a weekly window for Fable alongside the weekly window
/// for everything), and on a session running that model the scoped window is routinely the
/// binding one. A live API read carries its own scoped windows now (`ClaudeUtilization`), so
/// this file backfills them only where the fresher source cannot.
///
/// The CLI refreshes this cache on its own schedule rather than per turn, so it is *staler*
/// than the status-line feed for the windows both carry. That is why it is a fallback rather
/// than a peer: a slightly old scoped reading is a floor on a number that only rises within
/// its window, and an expired window still loses its value the same way every other reading
/// does.
///
/// Nil rather than throwing, for the same reason as `ClaudeUsageCache`: absent file, an account
/// whose CLI has not run since the key existed, and a moved schema all mean one thing here.
enum ClaudeUsageProfileCache {

    // MARK: - Public Methods

    static func read(
        account: AgentAccount,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AccountUsage? {
        profileURLs(for: account, home: home)
            .compactMap(read(fileAt:))
            .max { $0.observedAt < $1.observedAt }
    }

    // MARK: - Private Methods

    /// Where this account's profile file can be, newest reading winning.
    ///
    /// An alternate login is launched with `CLAUDE_CONFIG_DIR` pointed at its directory and
    /// keeps its `.claude.json` inside it. The **default** login does not: its config directory
    /// is `~/.claude`, but the file the CLI actually writes is `~/.claude.json`, one level up in
    /// the home directory — so reading only under `configPath` finds either nothing or a
    /// leftover stub, and the account loses exactly the windows this file alone carries. The
    /// symptom is a default account showing its 5-hour and weekly bars, from the fresher
    /// sources, and no scoped one beside them.
    ///
    /// Both places are read rather than one chosen, because the CLI has been moving this file:
    /// whichever it is writing now is the one with the later stamp, and that is the one taken.
    private static func profileURLs(for account: AgentAccount, home: URL) -> [URL] {
        var urls = [URL(fileURLWithPath: account.configPath)]
        if account.isDefault { urls.append(home) }

        return urls.map { $0.appendingPathComponent(ClaudeUsageProfileDefaults.fileName) }
    }

    private static func read(fileAt url: URL) -> AccountUsage? {
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: ClaudeUsageProfileDefaults.maxProfileBytes
        )
        else { return nil }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard let file = try? decoder.decode(ClaudeProfileFile.self, from: data),
              let cached = file.cachedUsageUtilization,
              let fetchedAtMs = cached.fetchedAtMs
        else { return nil }

        let observedAt = Date(timeIntervalSince1970: fetchedAtMs / 1000)
        guard observedAt <= Date().addingTimeInterval(ClaudeUsageProfileDefaults.futureTolerance)
        else { return nil }

        let windows = cached.utilization?.accountWindows() ?? []
        let modelWindows = cached.utilization?.modelWindows() ?? []
        guard !windows.isEmpty || !modelWindows.isEmpty else { return nil }

        var usage = AccountUsage(
            windows: windows,
            planLabel: nil,
            observedAt: observedAt,
            source: .localCache
        )
        usage.modelWindows = modelWindows
        return usage
    }

}

// MARK: - Claude Usage Profile Defaults

enum ClaudeUsageProfileDefaults {
    static let fileName = ".claude.json"

    /// The file also holds per-project state and assorted caches, so it is far larger than a
    /// usage snapshot — but it is the CLI's own working file, and one that has grown past this
    /// is not one to parse on a refresh timer.
    static let maxProfileBytes = 8 * 1024 * 1024

    /// Clock slack before a `fetched_at` in the future marks the snapshot unusable.
    static let futureTolerance: TimeInterval = 5 * 60
}
