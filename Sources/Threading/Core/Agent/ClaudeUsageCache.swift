import CryptoKit
import Foundation

// MARK: - Wire Types

/// `<profileID>.json` as the bridge writes it.
private struct ClaudeStatusSnapshot: Decodable {
    let schemaVersion: Int?
    let observedAt: String?
    let rateLimits: ClaudeStatusRateLimits?

}

/// The status line's `rate_limits` block — the same shape in Claude Code's own status-line input
/// and in the snapshot Claudex's bridge copies it into.
private struct ClaudeStatusRateLimits: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?

    struct Window: Decodable {
        /// Percent 0–100.
        let usedPercentage: Double?
        /// Epoch **seconds**, unlike the OAuth API's ISO-8601 strings.
        let resetsAt: Double?
    }
}

/// Claude Code's raw status-line input as Threading's own feed saves it: only the block that
/// matters is decoded. It carries no timestamp, so the file's modification date stands in.
private struct ClaudeStatusLineInput: Decodable {
    let rateLimits: ClaudeStatusRateLimits?
}

// MARK: - Claude Usage Cache

/// Reads the per-account usage caches fed by Claude Code's status line: Threading's own feed
/// (`readFeed`) and the cache maintained by Claudex's status-line bridge (`read`).
///
/// On macOS Claude Code keeps its OAuth token in the Keychain, not in a credentials file, so
/// there is usually nothing on disk to call the usage API with. The Keychain is no answer
/// here: its items do not say which config directory they belong to, and reading them from an
/// unbundled binary prompts on every rebuild. But Claude Code *pushes* its rate limits into
/// whatever `statusLine` command the account configures, and the user's Claudex install
/// (`~/repo/claudex`) catches that feed and caches it per account. Reading that cache gets
/// live usage with no credential, no network and no prompt.
///
/// The cache is keyed by profile id: the lowercase-hex SHA-256 of the account's canonical
/// config-directory path — standardized, symlink-resolved, no trailing slash. That recipe is
/// Claudex's (`ClaudeStatusLineInstaller.profileID`); it must match byte-for-byte or the
/// file simply is not found, which is also the graceful degradation when Claudex is not
/// installed at all.
enum ClaudeUsageCache {

    // MARK: - Public Methods

    /// The cached usage for an account, or nil when no usable snapshot exists.
    ///
    /// Nil rather than throwing: this is a fallback source, and every failure mode —
    /// Claudex absent, bridge not installed for this account, schema moved on — means the
    /// same thing to the caller.
    static func read(account: AgentAccount) -> AccountUsage? {
        guard let data = try? BoundedFileReader.read(
            cacheFileURL(forConfigPath: account.configPath),
            maximumBytes: ClaudeUsageCacheDefaults.maxSnapshotBytes
        ),
              let snapshot = try? decoder().decode(ClaudeStatusSnapshot.self, from: data),
              snapshot.schemaVersion == ClaudeUsageCacheDefaults.supportedSchemaVersion,
              let observedAt = snapshot.observedAt.flatMap(UsageHTTP.parseISO8601)
        else { return nil }

        return usage(from: snapshot.rateLimits, observedAt: observedAt)
    }

    /// The reading Threading's own status-line feed last saved for an account, or nil.
    ///
    /// Every local Claude terminal Threading launches runs `ClaudeStatusLineSettings.feedCommand`,
    /// which saves the status line's input whenever it carries `rate_limits` — so this needs
    /// neither Claudex nor a credential, which is what keeps a login whose Keychain item this
    /// build may not read (every Debug rebuild, for one) reporting after each turn.
    static func readFeed(account: AgentAccount, now: Date = Date()) -> AccountUsage? {
        let url = feedFileURL(forConfigPath: account.configPath)
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: ClaudeUsageCacheDefaults.maxSnapshotBytes
        ),
              let input = try? decoder().decode(ClaudeStatusLineInput.self, from: data),
              let observedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                  .contentModificationDate
        else { return nil }

        return usage(from: input.rateLimits, observedAt: observedAt, now: now)
    }

    /// Where the feed saves an account's reading: one file per login, named by the same profile
    /// id as Claudex's cache, under Threading's own support root so a hosted test writes into its
    /// scratch directory rather than the user's.
    static func feedFileURL(forConfigPath configPath: String) -> URL {
        MCPBridgeLocation.supportRoot
            .appendingPathComponent(ClaudeUsageCacheDefaults.feedSubdirectory, isDirectory: true)
            .appendingPathComponent("\(profileID(forConfigPath: configPath)).json")
    }

    /// Claudex's profile id recipe, reproduced exactly.
    static func profileID(forConfigPath configPath: String) -> String {
        let canonical = URL(fileURLWithPath: configPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Private Methods

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// The account's own two windows from a `rate_limits` block, or nil when it names neither or
    /// claims to come from the future.
    private static func usage(
        from rateLimits: ClaudeStatusRateLimits?,
        observedAt: Date,
        now: Date = Date()
    ) -> AccountUsage? {
        guard observedAt <= now.addingTimeInterval(ClaudeUsageCacheDefaults.futureTolerance)
        else { return nil }

        var windows: [AccountUsage.Window] = []
        if let window = normalize(
            rateLimits?.fiveHour,
            id: UsageDefaults.fiveHourWindowID,
            label: UsageDefaults.fiveHourLabel
        ) {
            windows.append(window)
        }
        if let window = normalize(
            rateLimits?.sevenDay,
            id: UsageDefaults.weeklyWindowID,
            label: UsageDefaults.weeklyLabel
        ) {
            windows.append(window)
        }

        guard !windows.isEmpty else { return nil }

        return AccountUsage(
            windows: windows,
            planLabel: nil,
            observedAt: observedAt,
            source: .localCache
        )
    }

    private static func normalize(
        _ window: ClaudeStatusRateLimits.Window?,
        id: String,
        label: String
    ) -> AccountUsage.Window? {
        guard let window, let percentage = window.usedPercentage else { return nil }

        return AccountUsage.Window(
            id: id,
            label: label,
            fraction: min(max(percentage / 100, 0), 1),
            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) },
            windowDuration: UsageDefaults.duration(forWindowID: id)
        )
    }

    private static func cacheFileURL(forConfigPath configPath: String) -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        return applicationSupport
            .appendingPathComponent(ClaudeUsageCacheDefaults.cacheSubdirectory)
            .appendingPathComponent("\(profileID(forConfigPath: configPath)).json")
    }
}

// MARK: - Claude Usage Cache Defaults

enum ClaudeUsageCacheDefaults {
    /// Relative to `~/Library/Application Support`.
    static let cacheSubdirectory = "Claudex/ClaudeStatus"

    /// Threading's own feed, relative to its support root.
    static let feedSubdirectory = "ClaudeStatus"

    static let supportedSchemaVersion = 1

    /// A snapshot is a few hundred bytes; anything huge is not one.
    static let maxSnapshotBytes = 64 * 1024

    /// Clock slack before an `observed_at` in the future marks a snapshot unusable.
    static let futureTolerance: TimeInterval = 5 * 60
}
