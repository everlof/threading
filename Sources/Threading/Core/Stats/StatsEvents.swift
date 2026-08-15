import Foundation

/// A project's glanceable metrics finished, or one of its cached readings changed.
struct ProjectStatsDidChange: AppEvent {
    static let name = Notification.Name("projectStatsDidChange")
    let projectID: ProjectID
}

/// The transcript usage report was rebuilt.
struct TranscriptUsageDidChange: AppEvent {
    static let name = Notification.Name("transcriptUsageDidChange")
}

/// A usage scan moved. Separate from `TranscriptUsageDidChange` because this arrives many times
/// for one report and only the dashboard's own placeholder is interested: a listener that rebuilt
/// a page from it would rebuild that page for every tick of a progress bar.
struct TranscriptUsageScanProgressDidChange: AppEvent {
    static let name = Notification.Name("transcriptUsageScanProgressDidChange")
}

struct AccountUsageDidChange: AppEvent {
    static let name = Notification.Name("ThreadingAccountUsageDidChange")
    let accountID: AccountID
}

struct UsageLimitHistoryDidChange: AppEvent {
    static let name = Notification.Name.usageLimitHistoryDidChange
}

/// A user-authored limit was added, edited or removed, app-wide or on one account — the signal
/// the settings page and the alert center re-evaluate on, since a rule created now must be able
/// to speak before the next reading arrives.
struct CustomLimitsDidChange: AppEvent {
    static let name = Notification.Name("ThreadingCustomLimitsDidChange")
}

/// The usage-window poke's schedule was edited.
struct UsageWindowScheduleDidChange: AppEvent {
    static let name = Notification.Name("ThreadingUsageWindowScheduleDidChange")
}

/// A poke fired, failed, or the standing reason it is holding changed — the signal the settings
/// page redraws its ledger on.
struct UsageWindowPokeDidChange: AppEvent {
    static let name = Notification.Name("ThreadingUsageWindowPokeDidChange")
}
