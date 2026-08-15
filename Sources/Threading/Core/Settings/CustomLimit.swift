import Foundation

// MARK: - Custom Limit Metric

/// What a rule measures.
///
/// Raw values are persisted and **named at birth, never renamed** — a rule that stops decoding is
/// a limit the user drew and Threading silently forgot, which is the worst failure this feature
/// has. Two shapes are declared and one is implemented: `paceShare` and `syntheticWindow` are the
/// draft's later slices, and they are listed here so the stored record does not have to change
/// shape when they arrive. `CustomLimit.isSupported` is what keeps an undeclared shape from being
/// evaluated as though it were a fixed cap.
enum CustomLimitMetric: String, Codable, Equatable, CaseIterable {

    /// A provider window's own `fraction`, against a constant. Reads the live reading and
    /// nothing else.
    case fixedCap

    /// A provider window's `fraction` against its `elapsedFraction` — the shared-login shape.
    /// The bound is `share × elapsedFraction(now)`, so it **rises with the clock**.
    case paceShare

    /// Consumption inside a trailing window the provider does not meter — a five-hour discipline
    /// recreated on a plan that meters only a week. Funded by fraction delta over the history the
    /// app already keeps, so the unit stays the provider's own.
    case syntheticWindow

    /// Whether the evaluator can answer this shape today.
    var isImplemented: Bool { true }
}

// MARK: - Custom Limit Tier

/// How far up the consequence ladder a rule is armed.
///
/// A higher tier implies the ones above it, so the raw values are ordered and comparison is by
/// that order rather than by a separate list of opted-in tiers: "notify" always shows, "hold"
/// always notifies. Nothing here ever answers a chooser, types into a session, interrupts a turn
/// in flight, or spends money.
enum CustomLimitTier: String, Codable, Equatable, CaseIterable, Comparable {

    /// The bound is drawn where the reading is; nothing acts.
    case show

    /// Plus a notification at each threshold, once per window instance.
    case notify

    /// Plus: Threading-initiated spend stands down at the bound — scheduled sends, the
    /// usage-window poke, the escape ranking's eligibility and the control plane's admission.
    /// It does not stop the keyboard, and the settings copy says so.
    case hold

    /// Plus: sessions on the account are held at their next turn boundary — the visible queue
    /// stops draining, the row carries a conduct mark, and the composer offers Continue Anyway.
    /// It still does not stop the keyboard: a turn typed and sent by hand goes.
    case park

    /// Rank on the ladder, low to high.
    private var rank: Int {
        switch self {
        case .show: return 0
        case .notify: return 1
        case .hold: return 2
        case .park: return 3
        }
    }

    static func < (lhs: CustomLimitTier, rhs: CustomLimitTier) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Whether the evaluator honours this tier today. A rule stored at a higher tier by a later
    /// build still evaluates — it is clamped to what this build can actually do rather than
    /// dropped, because a limit that decodes and then does nothing is the same silent forgetting
    /// the raw values guard against.
    var isImplemented: Bool { self <= CustomLimitDefaults.highestImplementedTier }
}

// MARK: - Custom Limit

/// One user-authored bound on one account: a *metric* (what is measured), a *bound* (where the
/// line is), and *consequences* (what happens on approach and at the line).
///
/// The provider's limit is the only limit the readings carry, so every consumer of pressure reads
/// a provider window against 100% of itself. This is the object that lets the user draw their own
/// line and have the same consumers read *that*.
///
/// **Thresholds are fractions of the bound, not of the window.** "Tell me at 50% of the weekly" is
/// a bound at `0.5` with one threshold at `1.0` — the line is at half, tell me when I reach it.
/// "Keep this account under 80%, warn me on the way" is a bound at `0.8` with thresholds
/// `[0.75, 1.0]`. Stating it once, in one direction, is what keeps a template's arithmetic and the
/// evaluator's from disagreeing about which number the percentage in the notification refers to.
struct CustomLimit: Codable, Equatable, Identifiable {

    // MARK: - Properties

    let id: UUID

    /// The provider window this rule measures, by `AccountUsage.Window.id` — `5h`, `7d`, or a
    /// model-scoped window's own identifier.
    ///
    /// Named rather than derived from the account's peak: a rule about the weekly must keep
    /// meaning the weekly on a morning when the five-hour window is the fuller one, or the line
    /// the user drew would wander between windows without them touching it.
    var windowID: String

    var metric: CustomLimitMetric

    /// Where the line is, as a fraction of the window: `0.8` is "treat 80% of this window as
    /// spent". Held in `0…1` by `normalized`.
    var bound: Double

    var tier: CustomLimitTier

    /// Where along the way to the bound the rule speaks, as fractions **of the bound**, ascending
    /// and deduplicated. `1.0` is the bound itself and is not implied — a rule that wants to be
    /// told when it arrives says so.
    var thresholds: [Double]

    /// Whether the always-visible pill may take a state from this rule.
    ///
    /// Opt-in per rule, and off by default: the one surface that cannot be dismissed must not
    /// acquire a new red state because a rule was created to fire one quiet 50% alert.
    var showsInToolbar: Bool

    /// How far back a **synthetic window** looks, in seconds. Nil for every other metric.
    ///
    /// Added as an optional rather than folded into `bound`, so a record written before synthetic
    /// windows existed decodes unchanged — the metric enum was declared from the start, but the
    /// span it measures over could not be. A synthetic rule with no span cannot be evaluated and
    /// says so, which is the same "cannot see" a missing reading produces.
    var trailingSpan: TimeInterval?

    /// The user's own words for this rule, when they gave it any. Nil falls back to the sentence
    /// derived from the metric and bound, so a rule always has something to be called in a
    /// receipt.
    var name: String?

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        windowID: String,
        metric: CustomLimitMetric = .fixedCap,
        bound: Double,
        tier: CustomLimitTier = .notify,
        thresholds: [Double] = [CustomLimitDefaults.boundThreshold],
        showsInToolbar: Bool = false,
        trailingSpan: TimeInterval? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.windowID = windowID
        self.metric = metric
        self.bound = Self.normalized(bound)
        self.tier = tier
        self.thresholds = Self.normalized(thresholds: thresholds)
        self.showsInToolbar = showsInToolbar
        self.trailingSpan = trailingSpan.flatMap { $0 > 0 ? $0 : nil }
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
    }

    // MARK: - Public Methods

    /// Whether this build can evaluate the rule as stored.
    ///
    /// A rule written by a later build — a pace share, a synthetic window — decodes, is listed,
    /// and is *not* evaluated. Failing to evaluate loudly beats evaluating a shape whose bound
    /// means something else: a pace share's `bound` is a share of elapsed time, and reading it as
    /// a fixed cap would fire alerts at a line the user never drew.
    var isSupported: Bool {
        guard metric.isImplemented else { return false }
        // A synthetic window with no span is a rule whose question has no length. It decodes and
        // is listed; it is not evaluated, because there is nothing to evaluate it over.
        if metric == .syntheticWindow { return trailingSpan != nil }
        return true
    }

    /// What the evaluator actually arms, which is never more than this build implements.
    var effectiveTier: CustomLimitTier { min(tier, CustomLimitDefaults.highestImplementedTier) }

    /// The thresholds as fractions of the *window*, which is what a bar or a chart draws.
    var windowThresholds: [Double] { thresholds.map { $0 * bound } }

    // MARK: - Normalization

    /// Clamps a bound into the range a fraction can occupy, and off zero: a bound of zero is
    /// permanently crossed, which is a rule that can only ever be noise.
    static func normalized(_ bound: Double) -> Double {
        guard bound.isFinite else { return CustomLimitDefaults.boundThreshold }
        return min(max(bound, CustomLimitDefaults.minimumBound), CustomLimitDefaults.boundThreshold)
    }

    /// Ascending, deduplicated, inside `(0, 1]`. A rule with no usable threshold keeps the bound
    /// itself, so it still has one thing to say.
    static func normalized(thresholds: [Double]) -> [Double] {
        let usable = thresholds
            .filter { $0.isFinite && $0 > 0 && $0 <= CustomLimitDefaults.boundThreshold }
            .map { ($0 * CustomLimitDefaults.thresholdRoundingScale).rounded()
                / CustomLimitDefaults.thresholdRoundingScale }
        let unique = Array(Set(usable)).sorted()
        return unique.isEmpty ? [CustomLimitDefaults.boundThreshold] : unique
    }

    // MARK: - Templates

    /// "Tell me when this window reaches *percent*." The line is the percentage itself, and the
    /// only thing armed is the notification.
    static func alert(windowID: String, at fraction: Double) -> CustomLimit {
        CustomLimit(
            windowID: windowID,
            bound: fraction,
            tier: .notify,
            thresholds: [CustomLimitDefaults.boundThreshold]
        )
    }

    /// "Tell me at every *step* of this window." The line is the provider's own, and the rule
    /// speaks on the way up.
    static func everyStep(windowID: String, step: Double) -> CustomLimit {
        CustomLimit(
            windowID: windowID,
            bound: CustomLimitDefaults.boundThreshold,
            tier: .notify,
            thresholds: Self.steps(of: step)
        )
    }

    /// "No more than *budget* of this window in any *span*" — the window a provider stopped
    /// metering, recreated.
    ///
    /// Armed at `hold`: the instruction is about pacing, and being told after the fact that a
    /// morning spent the week is the outcome the rule exists to prevent.
    static func syntheticWindow(
        windowID: String,
        budget: Double,
        span: TimeInterval
    ) -> CustomLimit {
        CustomLimit(
            windowID: windowID,
            metric: .syntheticWindow,
            bound: budget,
            tier: .hold,
            thresholds: [CustomLimitDefaults.holdWarningThreshold, CustomLimitDefaults.boundThreshold],
            trailingSpan: span
        )
    }

    /// "Keep this account under *fraction*" — a line that stands Threading's own spend down.
    ///
    /// Its thresholds warn on the way rather than only at the line: a hold that arrives with no
    /// notice is a scheduled send that silently did not go.
    static func cap(windowID: String, at fraction: Double) -> CustomLimit {
        CustomLimit(
            windowID: windowID,
            bound: fraction,
            tier: .hold,
            thresholds: [CustomLimitDefaults.holdWarningThreshold, CustomLimitDefaults.boundThreshold]
        )
    }

    /// "Never use more than *share* of what the clock has released" — the shared-login shape.
    ///
    /// The guarantee reads better the other way round: at any instant, at least `(1 − share)` of
    /// what linear time has released is unspent and waiting for whoever else uses this login.
    /// Armed at `hold` rather than `notify`, because the instruction is about conduct — somebody
    /// saying "this is a friend's account" wants Threading to stand down, not to be told.
    static func paceShare(windowID: String, share: Double) -> CustomLimit {
        CustomLimit(
            windowID: windowID,
            metric: .paceShare,
            bound: share,
            tier: .hold,
            thresholds: [CustomLimitDefaults.boundThreshold]
        )
    }

    /// The ladder `step, 2·step, … 1.0`, which is what "every 10%" means as a threshold list.
    static func steps(of step: Double) -> [Double] {
        guard step.isFinite, step > 0, step <= CustomLimitDefaults.boundThreshold else {
            return [CustomLimitDefaults.boundThreshold]
        }
        let count = Int((CustomLimitDefaults.boundThreshold / step).rounded(.down))
        guard count > 0 else { return [CustomLimitDefaults.boundThreshold] }
        return (1...count).map { Double($0) * step }
    }
}

// MARK: - Custom Limit Defaults

enum CustomLimitDefaults {

    /// The bound expressed as a fraction of itself — `1.0`, and the one threshold every rule has
    /// unless it names others. Written rather than typed as a bare literal because it appears in
    /// three different roles (a full window, a full bound, a clamp ceiling).
    static let boundThreshold = 1.0

    /// A bound below this is indistinguishable from "already over", so it is where a bound stops.
    static let minimumBound = 0.01

    /// Thresholds are rounded to whole percentage points before deduplication, so a generator and
    /// a hand-typed list produce the same set rather than two lines a hundredth apart.
    static let thresholdRoundingScale = 100.0

    /// The highest tier this build evaluates. Raised as the ladder is implemented.
    static let highestImplementedTier: CustomLimitTier = .park

    /// What "every 10%" means.
    static let tenPercentStep = 0.1

    /// Where a hold warns on the way to its line. Three quarters of the way, matching
    /// `warningFraction`'s own sense of "close" — a hold that arrives with no notice is a
    /// scheduled send that silently did not go.
    static let holdWarningThreshold = 0.75

    /// The percentages the alert template offers, and the order the menu lists them in.
    static let offeredAlertFractions: [Double] = [0.5, 0.75, 0.9]

    /// The shares the "reserve a share for its owner" template offers. A half is the instruction
    /// people actually give about a shared login; the other two are the same idea for someone who
    /// is the heavier or the lighter user of the two.
    static let offeredPaceShares: [Double] = [0.25, 0.5, 0.75]

    /// The percentages the "keep this account under" template offers — a hold, not an alert.
    static let offeredCapFractions: [Double] = [0.5, 0.8, 0.9]

    /// The spans a recreated window is offered over, and the budget each carries.
    ///
    /// A fifth of the week in any five hours is the shape of the window Claude used to meter, and
    /// the two neighbours are the same discipline held tighter or looser. Stated as a pair because
    /// a span with no budget is not a rule anybody could act on.
    static let offeredSyntheticWindows: [(span: TimeInterval, budget: Double)] = [
        (UsageDefaults.fiveHourSeconds, 0.10),
        (UsageDefaults.fiveHourSeconds, 0.15),
        (24 * 3_600, 0.30)
    ]

    /// How many rules one account may hold.
    ///
    /// A backstop rather than a product limit: rule count is user-fixed and small, and every
    /// evaluation is linear in it. Ten is more lines than anyone has drawn on one login, and it
    /// keeps a stuck "Add" from manufacturing a preference blob that the next launch refuses.
    static let maximumRulesPerAccount = 10
}

// MARK: - Optional String

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
