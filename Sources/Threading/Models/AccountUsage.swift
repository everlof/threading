import Foundation

// MARK: - Account Usage

/// A rate-limit snapshot for one agent account, normalized across providers.
///
/// Claude and Codex both meter subscriptions by rolling windows but report them in different
/// shapes; everything downstream (the toolbar pill, its popover) reads this one model.
struct AccountUsage: Equatable {

    struct ResetCredit: Equatable, Identifiable {
        let id: String
        let title: String
        let grantedAt: Date?
        let expiresAt: Date?
        let status: String

        var isAvailable: Bool { status.lowercased() == "available" }
    }

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

        /// The model this window meters, when it meters one rather than the account as a whole.
        ///
        /// Carried beside `id` rather than deduced from it, because `id` cannot be spared: a
        /// scoped window is identified by its model's name, which is what `ModelName.scope`
        /// matches a session against and what `UsageHistoryStore` files its samples under. So
        /// the identity stays the model, and this says what the identity means.
        let scopeName: String?

        init(
            id: String,
            label: String,
            fraction: Double?,
            resetsAt: Date?,
            windowDuration: TimeInterval?,
            scopeName: String? = nil
        ) {
            self.id = id
            self.label = label
            self.fraction = fraction
            self.resetsAt = resetsAt
            self.windowDuration = windowDuration
            self.scopeName = scopeName
        }

        /// Percent for display, or nil when the fraction is unknown.
        var percent: Int? {
            fraction.map { Int(($0 * 100).rounded()) }
        }

        /// What a compact reading calls this window: its length, plus the model it meters when
        /// it meters one — `5h`, `7d`, `7d Fable`.
        ///
        /// One vocabulary, so the same window reads as the same window everywhere it is named.
        /// A scoped window used to print as its model alone, which put `5h 7% · 7d 56% · Fable
        /// 89%` on screen — a model's name in a list of window lengths, leaving no way to tell
        /// what period that last number covered, and no way to connect it to the `Weekly ·
        /// Fable` bar stating the same figure two inches below.
        ///
        /// The spacious form (`label`) says the same thing in longer words — `Weekly · Fable` —
        /// so a bar and a menu line name one window two lengths of the same way, rather than two
        /// different ways.
        var compactName: String {
            guard let scopeName, !scopeName.isEmpty else { return id }
            guard let length = UsageDefaults.windowID(forDuration: windowDuration) else {
                return scopeName
            }
            return "\(length)\(UsageDefaults.scopeSeparator)\(scopeName)"
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

    /// Detailed reset-credit metadata, when the provider exposes the companion endpoint.
    /// History retains only the available count and soonest expiry—never provider IDs/titles.
    var resetCreditDetails: [ResetCredit] = []

    var nextExpiringResetCredit: ResetCredit? {
        resetCreditDetails
            .filter { $0.isAvailable && $0.expiresAt != nil }
            .min { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// Purchased credits that carry on past the plan's included usage, when the provider
    /// reports a balance.
    var creditBalance: String?

    /// When the values were true: the fetch time for a live API read, or the provider's own
    /// observation stamp when the data came from a local cache.
    let observedAt: Date

    let source: Source

    /// Every window this account has, account-wide and model-scoped alike.
    ///
    /// For callers that need to *find a named window* rather than rank pressure — a scheduled
    /// send re-reading the reset it was aimed at. The two lists stay separate everywhere the
    /// distinction matters (see `modelWindows`); this is only for lookup by id.
    var allWindows: [Window] { windows + modelWindows }

    /// The window closest to its limit, which is the one worth a glance in the toolbar.
    ///
    /// Expired windows are skipped: their percentage describes the previous window, and
    /// surfacing it would show pressure that no longer exists.
    func peakWindow(at now: Date = Date()) -> Window? {
        Self.fullest(of: windows, at: now)
    }

    // MARK: - Named Windows

    /// The account's shortest window: the one whose phase is worth owning.
    ///
    /// Chosen by length rather than by identifier, which is what keeps `UsageWindowPoke`
    /// provider-agnostic. A runtime that meters on four hours instead of five, or renames `5h`,
    /// needs no change here — and neither does the day Codex's window turns out to be anchored,
    /// which is the whole point of picking the window by what it *is*.
    ///
    /// Expired windows are kept, unlike everywhere else in this file: a window whose reset has
    /// passed is precisely the state the poke exists to notice.
    var anchoredWindow: Window? {
        windows
            .filter { $0.windowDuration != nil }
            .min { ($0.windowDuration ?? 0) < ($1.windowDuration ?? 0) }
    }

    /// The account's longest window — the cap a short window is pulled forward *out of*, and so
    /// the one the poke's pace guard reads.
    var longestWindow: Window? {
        windows
            .filter { $0.windowDuration != nil }
            .max { ($0.windowDuration ?? 0) < ($1.windowDuration ?? 0) }
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

    private static func fullest(of windows: [Window], at now: Date) -> Window? {
        windows
            .filter { !$0.isExpired(at: now) && $0.fraction != nil }
            .max { ($0.fraction ?? 0) < ($1.fraction ?? 0) }
    }

    /// One window of a written-out reading: its short name, its value as text, and how close it
    /// is to its limit.
    ///
    /// Structured rather than pre-joined so a surface that can tint per window — the pill, a
    /// menu row — and one that cannot — a tooltip — derive from the same list, with the
    /// stale-value and severity rules decided once. An expired window keeps its name, loses its
    /// number, and reports `.normal`: the percentage describes the window before it, and so
    /// would any pressure tinted from it.
    struct Reading {
        let name: String
        let value: String
        let severity: UsageSeverity
        /// The same reading as a proportion, for a surface that draws it as a length rather than
        /// writing it — the menu rows' metric columns. Nil under exactly the rule `value`
        /// answers with `—`, so a bar and the number beside it cannot disagree about whether
        /// there is anything to report.
        let fraction: Double?
    }

    /// Every window a written-out reading names, in the order the line prints them.
    ///
    /// Naming a model adds the windows that meter it, so a surface that knows what the session
    /// will run on says the number that binds it. A surface where the model is not decided yet
    /// asks for `.all` instead, and gets every scoped window on the account.
    func readings(
        at now: Date = Date(),
        metering model: String? = nil,
        scoped: ScopedWindows = .metering
    ) -> [Reading] {
        readings(
            of: scoped == .all ? windows + modelWindows : windows(metering: model),
            at: now
        )
    }

    /// The same readings for a window list the caller has already chosen — the model rows'
    /// scoped-only line. One mapping, so the stale-value and severity rules cannot drift
    /// between the lists.
    func readings(of windows: [Window], at now: Date) -> [Reading] {
        windows.map { window in
            let live = window.isExpired(at: now) ? nil : window.fraction
            return Reading(
                name: window.compactName,
                value: Self.value(of: window, at: now),
                severity: UsageSeverity.from(fraction: live),
                fraction: live
            )
        }
    }

    /// `5h 43% · 7d 73%` as plain text, for the places that cannot tint per window — a menu
    /// item's tooltip, a settings line. Surfaces that can tint read `readings` instead.
    ///
    /// Nil when there is nothing to say, so a caller shows no line rather than an empty one.
    ///
    /// Each window is named by `compactName`, so a scoped one states its length beside its model
    /// rather than standing in the list as a bare model name.
    func compactSummary(
        at now: Date = Date(),
        metering model: String? = nil,
        scoped: ScopedWindows = .metering
    ) -> String? {
        let readings = readings(at: now, metering: model, scoped: scoped)
        guard !readings.isEmpty else { return nil }

        return readings
            .map { "\($0.name) \($0.value)" }
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

    /// The mark that stands between one window and the next, without the spaces the written
    /// form pads it with. A drawn reading sets those gaps from `Design.Spacing` instead, so the
    /// two forms stay one decision — see `UsageReadingLabel.summary`.
    static let segmentMark = "·"

    /// Between one window and the next in a written-out reading.
    static let segmentSeparator = " \(segmentMark) "

    /// Between a scoped window's length and the model it meters — `7d Fable`. A space rather
    /// than `segmentSeparator`, which would make one window look like two in a joined list.
    static let scopeSeparator = " "

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

    /// The longest a 429 backoff grows however many refusals arrive in a row — an hour is
    /// enough contrition, and past it a stuck flag would silence the pill for the whole run.
    static let rateLimitBackoffCap: TimeInterval = 3600

    /// How much jitter may *stretch* a rate-limit wait (it never shortens one), so refusals
    /// dealt to several accounts together do not send them back together.
    static let rateLimitJitterFraction = 0.1

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

    /// The spacious name for a window identifier, for a surface naming a window **no reading has
    /// arrived for yet**.
    ///
    /// A user-authored limit can be drawn before its account has ever been read, and until the
    /// reading lands there is no `Window` to take a `label` from. Printing the raw identifier
    /// there put `Watch 7d` and `No 7d reading yet.` on a settings page whose every other line
    /// says `Weekly` — the identifier is a key, and a key on screen reads as a leak. Anything
    /// this table does not know keeps its identifier, which is then genuinely all that is known.
    static func label(forWindowID id: String) -> String {
        switch id {
        case fiveHourWindowID: return fiveHourLabel
        case weeklyWindowID: return weeklyLabel
        default: return id
        }
    }

    /// The identifier for a window of this length — the inverse of `duration(forWindowID:)`.
    ///
    /// A model-scoped window is identified by its *model* rather than by its length, so
    /// `compactName` recovers the length from here to name it the way every other window is
    /// named.
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
