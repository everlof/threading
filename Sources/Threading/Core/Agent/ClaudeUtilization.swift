import Foundation

// MARK: - Claude Utilization

/// The utilization document Claude serves from its usage endpoint — and, verbatim, what the
/// CLI caches under `cachedUsageUtilization.utilization` in `.claude.json`.
///
/// One type for both readers on purpose. The live fetch used to decode only the fixed
/// `five_hour`/`seven_day` pair and drop the rest of the payload, leaving the **model-scoped**
/// windows to be recovered from the CLI's cached copy of the very same document — a file that
/// simply does not exist for an account whose CLI has not cached usage yet. The symptom was an
/// account showing fresh 5-hour and weekly bars with its Fable window nowhere, not because the
/// endpoint withheld it but because the response carrying it was thrown away.
///
/// A scoped window is findable only in `limits[]`, as an entry whose `scope.model` names a
/// model. The sibling `seven_day_opus`-style keys are the fixed slots of an older shape and are
/// null on accounts metered this way.
struct ClaudeUtilization: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?

    /// The provider's own flattened list of every limit that applies. Entries with no model in
    /// their scope restate `five_hour`/`seven_day` and are skipped rather than drawn twice.
    let limits: [Limit]?

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

    // MARK: - Normalization

    /// The account's own windows, in the order every reading prints them.
    func accountWindows() -> [AccountUsage.Window] {
        [
            Self.normalize(
                fiveHour,
                id: UsageDefaults.fiveHourWindowID,
                label: UsageDefaults.fiveHourLabel
            ),
            Self.normalize(
                sevenDay,
                id: UsageDefaults.weeklyWindowID,
                label: UsageDefaults.weeklyLabel
            )
        ].compactMap { $0 }
    }

    /// The limits that belong to one model rather than to the plan.
    ///
    /// Deduplicated by name because the list is the provider's own projection and nothing
    /// promises it is a set.
    func modelWindows() -> [AccountUsage.Window] {
        var seen: Set<String> = []

        return (limits ?? []).compactMap { limit in
            guard let name = limit.scope?.model?.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty,
                let percent = limit.percent,
                seen.insert(name.lowercased()).inserted
            else { return nil }

            let base = Self.baseWindow(forGroup: limit.group)

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

    // MARK: - Private Methods

    /// Which of the account's windows a scoped limit is measured in. The feed names the group
    /// rather than the length, and a scoped weekly limit resets with the weekly window.
    private static func baseWindow(
        forGroup group: String?
    ) -> (label: String, duration: TimeInterval?) {
        switch group {
        case ClaudeUtilizationDefaults.sessionGroup:
            return (UsageDefaults.fiveHourLabel, UsageDefaults.fiveHourSeconds)
        case ClaudeUtilizationDefaults.weeklyGroup:
            return (UsageDefaults.weeklyLabel, UsageDefaults.sevenDaySeconds)
        default:
            return (UsageDefaults.weeklyLabel, nil)
        }
    }

    /// A slot that is present keeps its identity even with its value missing — `fraction` is
    /// allowed to be unknown, and a written-out reading renders it as `—` rather than dropping
    /// the window from the list.
    private static func normalize(
        _ window: Window?,
        id: String,
        label: String
    ) -> AccountUsage.Window? {
        guard let window else { return nil }

        return AccountUsage.Window(
            id: id,
            label: label,
            fraction: window.utilization.map { min(max($0 / 100, 0), 1) },
            resetsAt: window.resetsAt.flatMap(UsageHTTP.parseISO8601),
            windowDuration: UsageDefaults.duration(forWindowID: id)
        )
    }
}

// MARK: - Claude Utilization Defaults

enum ClaudeUtilizationDefaults {
    /// The groups a scoped limit names itself by.
    static let sessionGroup = "session"
    static let weeklyGroup = "weekly"
}
