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
        Self.fullest(of: windows, at: now)
    }

    // MARK: - Scoped Windows

    /// Which model-scoped windows a written-out reading names.
    ///
    /// The difference is whether the model is *settled*. A session already running one is
    /// measured against the windows metering it and nothing else — naming another model's limit
    /// there would read as pressure on work that is not subject to it. A menu where the login is
    /// picked *before* the model is not yet in that position, and narrowing to the account's
    /// configured default withholds the number that binds the choice made two clicks later: an
    /// account whose Fable window is at 89% looks identical to one at 12% until it is too late
    /// to pick the other login.
    enum ScopedWindows {
        /// Only the windows metering the named model.
        case metering
        /// Every scoped window on the account, whatever it will run.
        case all
    }

    /// The model-scoped windows that meter `model` — the ones that will actually stop a session
    /// running it.
    ///
    /// Matching by name is what makes `modelWindows` usable without lying: the same list holds
    /// every model the plan meters separately, and only the entry naming this one applies here.
    /// No model named (an account that has chosen nothing, a menu built before the choice) means
    /// none of them apply, which is the conservative answer rather than the loud one.
    func scopedWindows(metering model: String?) -> [Window] {
        guard let model, !model.isEmpty else { return [] }
        return modelWindows.filter { ModelName.scope($0.id, meters: model) }
    }

    /// Every window a session on `model` is measured against: the account's own, plus the
    /// scoped ones naming that model.
    func windows(metering model: String?) -> [Window] {
        windows + scopedWindows(metering: model)
    }

    /// The window such a session runs out of *first* — what the toolbar's ring gauges.
    ///
    /// `peakWindow` answers a different question and both are needed: the account's pressure is
    /// what compares two logins, while the binding window is what stops the work in front of
    /// you. A weekly window at 56% beside a Fable window at 89% is comfortable as an account
    /// and nearly spent as a session, and the ring belongs to the session.
    func bindingWindow(at now: Date = Date(), metering model: String?) -> Window? {
        Self.fullest(of: windows(metering: model), at: now)
    }

    /// The fullest window metering `model`, with the account's own left out — what a row that
    /// *is* that model states about itself.
    ///
    /// `bindingWindow` is the wrong reading there: a model list compares its own rows, and the
    /// account weekly they all share would print the same number on every one of them.
    func tightestScopedWindow(at now: Date = Date(), metering model: String?) -> Window? {
        Self.fullest(of: scopedWindows(metering: model), at: now)
    }

    private static func fullest(of windows: [Window], at now: Date) -> Window? {
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
    ///
    /// Naming a model adds the windows that meter it — `5h 7% · 7d 56% · Fable 89%` — so a
    /// surface that knows what the session will run on says the number that binds it. A surface
    /// where the model is not decided yet asks for `.all` instead, and gets the same line with
    /// every scoped window on it.
    func compactSummary(
        at now: Date = Date(),
        metering model: String? = nil,
        scoped: ScopedWindows = .metering
    ) -> String? {
        let windows = scoped == .all ? self.windows + modelWindows : self.windows(metering: model)
        guard !windows.isEmpty else { return nil }

        return windows
            .map { "\($0.id) \(Self.value(of: $0, at: now))" }
            .joined(separator: UsageDefaults.segmentSeparator)
    }

    /// A window's percentage as text, or `—` when the number would be a leftover from the
    /// window before it. Shared so every written-out reading forgets a stale value the same way.
    static func value(of window: Window, at now: Date) -> String {
        guard !window.isExpired(at: now), let percent = window.percent else {
            return UsageDefaults.unknownValue
        }
        return "\(percent)%"
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

    /// The identifier for a window of this length — the inverse of `duration(forWindowID:)`.
    ///
    /// A model-scoped window is named after its *model*, which is the right label beside the
    /// account's own windows and the wrong one under a row that is already that model. Its
    /// length is the only thing left that says which window it is, so `7d` is recovered from it.
    static func windowID(forDuration duration: TimeInterval?) -> String? {
        guard let duration, duration > 0 else { return nil }

        switch duration {
        case fiveHourSeconds: return fiveHourWindowID
        case sevenDaySeconds: return weeklyWindowID
        default:
            let hours = Int((duration / 3600).rounded())
            guard hours > 0 else { return nil }
            return hours.isMultiple(of: 24) ? "\(hours / 24)d" : "\(hours)h"
        }
    }
}
