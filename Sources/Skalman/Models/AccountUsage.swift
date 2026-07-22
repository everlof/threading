import Foundation

// MARK: - Account Usage

/// A rate-limit snapshot for one agent account, normalized across providers.
///
/// Claude and Codex both meter subscriptions by rolling windows but report them in different
/// shapes; everything downstream (the toolbar pill, its popover) reads this one model.
struct AccountUsage: Equatable {

    // MARK: - Window

    /// One rolling rate-limit window, e.g. the 5-hour session limit.
    struct Window: Equatable, Identifiable {
        let id: String
        let label: String

        /// Fraction of the window consumed, 0…1. Nil when the value is unknown — a window
        /// whose reset has passed keeps its identity but not its stale percentage.
        let fraction: Double?

        let resetsAt: Date?

        /// The window's full length, when known. Lets the popover mark how far through the
        /// window's *time* we are — the pace line the spent fraction is read against.
        let windowDuration: TimeInterval?

        /// Percent for display, or nil when the fraction is unknown.
        var percent: Int? {
            fraction.map { Int(($0 * 100).rounded()) }
        }

        /// Whether the reset moment has passed, making `fraction` a leftover from the
        /// previous window rather than a current reading.
        func isExpired(at now: Date = Date()) -> Bool {
            guard let resetsAt else { return false }
            return resetsAt <= now
        }

        /// How far through the window's time we are, 0…1 — the linear mark the bar draws so the
        /// spent fraction reads against the clock. Fill left of the mark is under pace; fill past
        /// it is burning faster than time. Nil when the window's length is unknown.
        func elapsedFraction(at now: Date = Date()) -> Double? {
            guard let resetsAt, let windowDuration, windowDuration > 0 else { return nil }
            let remaining = resetsAt.timeIntervalSince(now)
            let elapsed = windowDuration - remaining
            return min(max(elapsed / windowDuration, 0), 1)
        }
    }

    // MARK: - Source

    /// Where a reading came from, which sets how often re-reading is worthwhile: a local
    /// cache costs a file read, an API call costs a network round trip.
    enum Source: Equatable {
        case api
        case localCache
    }

    // MARK: - Properties

    let windows: [Window]

    /// Subscription tier, e.g. `Max`, when the provider reports one.
    let planLabel: String?

    /// Limits belonging to one model rather than the account as a whole — Codex reports these
    /// separately, each with its own window and reset.
    ///
    /// Kept apart from `windows` on purpose: the toolbar's peak must stay the *account's*
    /// pressure. A model-specific limit at 100% says one model is spent, not that the plan is,
    /// and folding it into the peak would put the pill in the red over a model the session is
    /// not even using.
    var modelWindows: [Window] = []

    /// Rate-limit resets the account has banked — Codex grants a few, each clearing a spent
    /// window early. Worth surfacing precisely when a window is spent, which is the moment the
    /// user is deciding whether to stop for the day.
    var resetCredits: Int?

    /// Purchased credits that carry on past the plan's included usage, when the provider
    /// reports a balance.
    var creditBalance: String?

    /// When the values were true: the fetch time for a live API read, or the provider's own
    /// observation stamp when the data came from a local cache.
    let observedAt: Date

    let source: Source

    /// The window closest to its limit, which is the one worth a glance in the toolbar.
    ///
    /// Expired windows are skipped: their percentage describes the previous window, and
    /// surfacing it would show pressure that no longer exists.
    func peakWindow(at now: Date = Date()) -> Window? {
        windows
            .filter { !$0.isExpired(at: now) && $0.fraction != nil }
            .max { ($0.fraction ?? 0) < ($1.fraction ?? 0) }
    }

    /// `5h 43% · 7d 73%` as plain text, for the places that cannot tint per window — a menu
    /// item, a tooltip. The toolbar pill builds its own attributed version, where each value
    /// carries its window's severity colour.
    ///
    /// Nil when there is nothing to say, so a caller shows no line rather than an empty one.
    /// An expired window keeps its name and loses its number, for the same reason
    /// `peakWindow` skips it: the percentage describes the window before it.
    func compactSummary(at now: Date = Date()) -> String? {
        guard !windows.isEmpty else { return nil }

        return windows
            .map { window in
                let value = window.isExpired(at: now)
                    ? UsageDefaults.unknownValue
                    : window.percent.map { "\($0)%" } ?? UsageDefaults.unknownValue

                return "\(window.id) \(value)"
            }
            .joined(separator: UsageDefaults.segmentSeparator)
    }
}

// MARK: - Usage Severity

/// How close a window is to its limit, driving the pill and bar tint.
enum UsageSeverity {
    case normal
    case warning
    case critical

    /// Thresholds shared with the sidebar's sensibilities: quiet until three quarters,
    /// alarming only when the window is nearly spent.
    static func from(fraction: Double?) -> UsageSeverity {
        switch fraction ?? 0 {
        case ..<UsageDefaults.warningFraction: return .normal
        case ..<UsageDefaults.criticalFraction: return .warning
        default: return .critical
        }
    }
}

// MARK: - Usage Defaults

enum UsageDefaults {
    static let warningFraction = 0.75
    static let criticalFraction = 0.92

    /// Between one window and the next in a written-out reading.
    static let segmentSeparator = " · "

    /// Stands in for a window whose number would be a leftover from the previous one.
    static let unknownValue = "—"

    /// A fetched value is served from cache this long before another fetch is worthwhile.
    static let refreshInterval: TimeInterval = 300

    /// Re-read interval when the reading came from a local file rather than the network.
    static let localCacheRefreshInterval: TimeInterval = 30

    /// Floor between fetches for one account, however eagerly the UI asks.
    static let minimumRefreshSpacing: TimeInterval = 60

    /// Cadence of the timer that keeps the visible account's pill current. Each tick only
    /// refetches once `refreshInterval` has elapsed, so this stays cheap.
    static let refreshTimerInterval: TimeInterval = 60

    static let requestTimeout: TimeInterval = 20

    /// Window identifiers shared by both providers' normalizers.
    static let fiveHourWindowID = "5h"
    static let weeklyWindowID = "7d"
    static let fiveHourLabel = "5-hour"
    static let weeklyLabel = "Weekly"

    static let fiveHourSeconds: TimeInterval = 5 * 60 * 60
    static let sevenDaySeconds: TimeInterval = 7 * 24 * 60 * 60

    /// The length of a window from its identifier, for the providers whose feed does not name it
    /// outright: the shared 5h/7d ids, and the `12h`/`3d`-style ids derived for other windows.
    static func duration(forWindowID id: String) -> TimeInterval? {
        switch id {
        case fiveHourWindowID: return fiveHourSeconds
        case weeklyWindowID: return sevenDaySeconds
        default:
            if id.hasSuffix("h"), let hours = Int(id.dropLast()) { return TimeInterval(hours) * 3600 }
            if id.hasSuffix("d"), let days = Int(id.dropLast()) { return TimeInterval(days) * 86400 }
            return nil
        }
    }
}
