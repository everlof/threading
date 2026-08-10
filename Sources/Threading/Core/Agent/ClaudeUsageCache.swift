import CryptoKit
import Foundation

// MARK: - Wire Types

/// `<profileID>.json` as the bridge writes it.
private struct ClaudeStatusSnapshot: Decodable {
    let schemaVersion: Int?
    let observedAt: String?
    let rateLimits: RateLimits?

    struct RateLimits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
    }

    struct Window: Decodable {
        /// Percent 0–100.
        let usedPercentage: Double?
        /// Epoch **seconds**, unlike the OAuth API's ISO-8601 strings.
        let resetsAt: Double?
    }
}

// MARK: - Claude Usage Cache

/// Reads the per-account usage cache maintained by Claudex's status-line bridge.
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
        )
        else { return nil }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard let snapshot = try? decoder.decode(ClaudeStatusSnapshot.self, from: data),
              snapshot.schemaVersion == ClaudeUsageCacheDefaults.supportedSchemaVersion,
              let observedAt = snapshot.observedAt.flatMap(UsageHTTP.parseISO8601),
              observedAt <= Date().addingTimeInterval(ClaudeUsageCacheDefaults.futureTolerance)
        else { return nil }

        var windows: [AccountUsage.Window] = []
        if let window = normalize(
            snapshot.rateLimits?.fiveHour,
            id: UsageDefaults.fiveHourWindowID,
            label: UsageDefaults.fiveHourLabel
        ) {
            windows.append(window)
        }
        if let window = normalize(
            snapshot.rateLimits?.sevenDay,
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

    // MARK: - Private Methods

    private static func normalize(
        _ window: ClaudeStatusSnapshot.Window?,
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

    /// Claudex's profile id recipe, reproduced exactly.
    private static func profileID(forConfigPath configPath: String) -> String {
        let canonical = URL(fileURLWithPath: configPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Claude Usage Cache Defaults

enum ClaudeUsageCacheDefaults {
    /// Relative to `~/Library/Application Support`.
    static let cacheSubdirectory = "Claudex/ClaudeStatus"

    static let supportedSchemaVersion = 1

    /// A snapshot is a few hundred bytes; anything huge is not one.
    static let maxSnapshotBytes = 64 * 1024

    /// Clock slack before an `observed_at` in the future marks a snapshot unusable.
    static let futureTolerance: TimeInterval = 5 * 60
}
