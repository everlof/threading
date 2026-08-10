import Foundation

// MARK: - Wire Types

/// `.claude.json` → `cachedUsageUtilization`: the CLI's own copy of the last usage reading it
/// took from the API, kept beside the rest of its per-account state. Which `.claude.json` is
/// `profileURLs(for:home:)`, and it is not always the one under the config directory.
private struct ClaudeProfileFile: Decodable {
    let cachedUsageUtilization: CachedUsage?

    struct CachedUsage: Decodable {
        /// Epoch **milliseconds**, like the credentials file's expiry and unlike Codex.
        let fetchedAtMs: Double?
        let utilization: Utilization?
    }

    struct Utilization: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?

        /// The CLI's own flattened list of every limit that applies, and the only place a
        /// *model-scoped* window is named. The sibling `seven_day_opus`-style keys are the
        /// fixed slots of an older shape and are null on accounts metered this way.
        let limits: [Limit]?
    }

    struct Window: Decodable {
        /// Percent 0–100.
        let utilization: Double?
        let resetsAt: String?
    }

    struct Limit: Decodable {
        /// `session`, `weekly_all`, `weekly_scoped` — read through `group` instead, since the
        /// scope is what distinguishes an entry and the kind only restates it.
        let kind: String?
        /// `session` or `weekly`: which of the account's windows this limit is measured in.
        let group: String?
        /// Percent 0–100.
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?

        struct Scope: Decodable {
            let model: Model?

            struct Model: Decodable {
                let id: String?
                let displayName: String?
            }
        }
    }
}

// MARK: - Claude Usage Profile Cache

/// Reads the usage snapshot Claude Code stores in its own per-account `.claude.json`.
///
/// This is the only local source that names a **model-scoped** limit. Neither the status-line
/// feed nor the fixed `five_hour`/`seven_day` pair carries one: a plan meters some models
/// separately (a weekly window for Fable alongside the weekly window for everything), and on a
/// session running that model the scoped window is routinely the binding one — 89% against a
/// 56% account weekly is not a detail the panel can leave out, because it is the number that
/// stops the work.
///
/// The CLI refreshes this cache on its own schedule rather than per turn, so it is *staler*
/// than the status-line feed for the windows both carry. That is why it is a fallback for
/// `five_hour`/`seven_day` and the sole source for the scoped ones: a slightly old scoped
/// reading is a floor on a number that only rises within its window, and an expired window
/// still loses its value the same way every other reading does.
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

        let utilization = cached.utilization
        var windows: [AccountUsage.Window] = []
        if let window = normalize(
            utilization?.fiveHour,
            id: UsageDefaults.fiveHourWindowID,
            label: UsageDefaults.fiveHourLabel
        ) {
            windows.append(window)
        }
        if let window = normalize(
            utilization?.sevenDay,
            id: UsageDefaults.weeklyWindowID,
            label: UsageDefaults.weeklyLabel
        ) {
            windows.append(window)
        }

        let modelWindows = self.modelWindows(from: utilization?.limits ?? [])
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

    /// The limits that belong to one model rather than to the plan.
    ///
    /// An entry with no model in its scope is the account's own window, which arrives through
    /// `five_hour`/`seven_day` already; taking it twice would draw the same bar under two names.
    /// Deduplicated by name because the list is the CLI's own projection and nothing promises it
    /// is a set.
    private static func modelWindows(from limits: [ClaudeProfileFile.Limit]) -> [AccountUsage.Window] {
        var seen: Set<String> = []

        return limits.compactMap { limit in
            guard let name = limit.scope?.model?.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty,
                let percent = limit.percent,
                seen.insert(name.lowercased()).inserted
            else { return nil }

            let base = baseWindow(forGroup: limit.group)

            // The id is the model's own name — it is what identifies the limit, what a session
            // is matched against, and what its history is filed under. What it is *called* on
            // screen comes from `label` and `compactName`, both of which lead with the length.
            return AccountUsage.Window(
                id: name,
                label: "\(base.label)\(UsageDefaults.segmentSeparator)\(name)",
                fraction: min(max(percent / 100, 0), 1),
                resetsAt: limit.resetsAt.flatMap(UsageHTTP.parseISO8601),
                windowDuration: base.duration,
                scopeName: name
            )
        }
    }

    /// Which of the account's windows a scoped limit is measured in. The feed names the group
    /// rather than the length, and a scoped weekly limit resets with the weekly window.
    private static func baseWindow(forGroup group: String?) -> (label: String, duration: TimeInterval?) {
        switch group {
        case ClaudeUsageProfileDefaults.sessionGroup:
            return (UsageDefaults.fiveHourLabel, UsageDefaults.fiveHourSeconds)
        case ClaudeUsageProfileDefaults.weeklyGroup:
            return (UsageDefaults.weeklyLabel, UsageDefaults.sevenDaySeconds)
        default:
            return (UsageDefaults.weeklyLabel, nil)
        }
    }

    private static func normalize(
        _ window: ClaudeProfileFile.Window?,
        id: String,
        label: String
    ) -> AccountUsage.Window? {
        guard let window, let percent = window.utilization else { return nil }

        return AccountUsage.Window(
            id: id,
            label: label,
            fraction: min(max(percent / 100, 0), 1),
            resetsAt: window.resetsAt.flatMap(UsageHTTP.parseISO8601),
            windowDuration: UsageDefaults.duration(forWindowID: id)
        )
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

    /// The groups a scoped limit names itself by.
    static let sessionGroup = "session"
    static let weeklyGroup = "weekly"
}
