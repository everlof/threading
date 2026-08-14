import Foundation

// MARK: - Custom Limit Window Instance

/// One *turn* of a window: the window's identity plus the moment it resets.
///
/// A rule re-arms when its window does, and "when its window does" cannot be read from the
/// identifier alone — `7d` is the same window all year. The reset moment is what tells this
/// week's weekly from last week's, so it is half the identity: a reset re-arms every threshold
/// and withdraws what was delivered, and a fired record whose reset has passed is pruned rather
/// than kept as a reason to stay silent.
struct CustomLimitWindowInstance: Hashable, Codable {

    let windowID: String

    /// Nil for a window the provider reports without a reset. Such an instance never turns over,
    /// so a threshold announced on it stays announced — which is the honest behaviour: nothing
    /// observed says the window started again.
    let resetsAt: Date?

    /// A stable string form, for the fired-state map's keys. Seconds resolution, because a reset
    /// moment that survived JSON at sub-second precision would key two records to the same
    /// instance.
    var key: String {
        guard let resetsAt else { return "\(windowID)\(CustomLimitEvaluatorDefaults.instanceSeparator)\(CustomLimitEvaluatorDefaults.noResetKey)" }
        let seconds = Int(resetsAt.timeIntervalSince1970.rounded())
        return "\(windowID)\(CustomLimitEvaluatorDefaults.instanceSeparator)\(seconds)"
    }

    init(windowID: String, resetsAt: Date?) {
        self.windowID = windowID
        self.resetsAt = resetsAt
    }

    init(window: AccountUsage.Window) {
        self.init(windowID: window.id, resetsAt: window.resetsAt)
    }
}

// MARK: - Custom Limit State

/// Where one rule stands against its own line.
///
/// The ladder's two upper states are declared and not yet produced: `holding` and `parked` arrive
/// with tiers 3 and 4, and naming them here keeps a later slice from renaming a state a receipt
/// or a test already names. `CustomLimitTier.isImplemented` is what stops this build claiming
/// either.
enum CustomLimitState: String, Equatable {

    /// The reading this rule needs is not there. Notify goes silent; a hold would engage.
    case unknown

    /// Stored by a build that understands a metric this one does not. Listed, never evaluated.
    case unsupported

    /// Under every threshold.
    case clear

    /// Past a threshold, still under the bound.
    case near

    /// At or over the bound, with nothing above notify armed.
    case reached

    /// At or over the bound on a tier-3 rule. Not produced yet.
    case holding

    /// At or over the bound on a tier-4 rule. Not produced yet.
    case parked

    /// Whether the line itself has been reached, whatever the tier does about it.
    var isAtBound: Bool {
        switch self {
        case .reached, .holding, .parked: return true
        case .unknown, .unsupported, .clear, .near: return false
        }
    }
}

// MARK: - Custom Limit Reason

/// Why a rule is where it is, structured rather than written out.
///
/// The sentence a receipt prints is `CustomLimitReceipt`'s job. Keeping the judgement free of
/// `L10n` is what lets the table tests assert on the answer instead of on this month's wording —
/// and it is what keeps "over your line" and "cannot see" distinguishable, which matters because
/// the two have opposite remedies.
enum CustomLimitReason: Equatable {

    /// No window, or a window whose percentage belongs to the turn before this one.
    case noReading

    /// A metric this build does not evaluate.
    case notEvaluated(CustomLimitMetric)

    case underBound(consumedOfBound: Double)
    case atBound(consumedOfBound: Double)
}

// MARK: - Custom Limit Evaluation

/// One rule's answer at one moment.
struct CustomLimitEvaluation: Equatable, Identifiable {

    /// The rule's own id, so an evaluation can be matched back to the row that made it.
    var id: UUID { rule.id }

    let rule: CustomLimit
    let instance: CustomLimitWindowInstance

    /// How much of the *bound* is spent — `0.75` on a rule at 80% means the window reads 60%.
    /// Nil exactly when the reading is unknown.
    let consumedOfBound: Double?

    /// The raw provider fraction, carried alongside because the number a surface *prints* is
    /// always this one. A bar drawing full at 40% would lie about the figure beside it: what a
    /// rule moves is the tint, never the length or the printed percentage.
    let windowFraction: Double?

    let state: CustomLimitState
    let reason: CustomLimitReason

    /// Thresholds newly crossed at this evaluation, ascending.
    ///
    /// All of them are marked fired; only the highest is announced. A sparse reading that jumps
    /// 48% → 61% past lines at 50% and 60% fires **once**, naming 60% — a backlog of every line
    /// in between is the alert fatigue this feature would otherwise be.
    let crossedThresholds: [Double]

    /// The line worth naming in the notification.
    var announcedThreshold: Double? { crossedThresholds.last }

    /// Whether this evaluation should post. An unknown reading never does: an alert derived from
    /// a guess is noise, and a missing fraction never reads as consumption.
    var wantsNotification: Bool {
        guard rule.effectiveTier >= .notify, announcedThreshold != nil else { return false }
        return state != .unknown && state != .unsupported
    }

    /// The severity a surface tints with — computed against the *effective* bound rather than the
    /// provider's 100%, reusing the shipped `warningFraction`/`criticalFraction` rather than
    /// inventing a second severity vocabulary. An account at 47% raw under a 50% line tints
    /// critical while printing 47%: the number is the fact, the tint is the pressure.
    var severity: UsageSeverity {
        UsageSeverity.from(fraction: consumedOfBound)
    }
}

// MARK: - Custom Limit Evaluator

/// The arithmetic behind a user-authored limit. Pure, in `UsageWindowPlan`'s shape and for its
/// reason: a rule that stands between the user and their own quota must be table-testable with no
/// network, no home directory and no clock of its own.
///
/// Evaluation is **edge-driven, never polled** — a new reading, the turn-settle refresh, or a rule
/// being edited. Nothing here scans a transcript or reads a file; the input is gathered by the
/// caller and the judgement happens here.
enum CustomLimitEvaluator {

    // MARK: - Input

    struct Input {
        /// The rules in force on this account, already resolved across the two scopes.
        var rules: [CustomLimit]

        /// The account's last reading, or nil when nothing has been read.
        var usage: AccountUsage?

        /// Which thresholds have already been announced, keyed by
        /// `"<rule id>|<window instance key>"`. A key absent from the map is a rule that has said
        /// nothing about this turn of its window.
        var fired: [String: [Double]] = [:]

        var now: Date = Date()
    }

    // MARK: - Evaluation

    /// Every rule's answer, in the order the rules are listed.
    static func evaluate(_ input: Input) -> [CustomLimitEvaluation] {
        input.rules.map { evaluate(rule: $0, input: input) }
    }

    /// The key one rule's fired thresholds are stored under for one turn of its window.
    static func firedKey(ruleID: UUID, instance: CustomLimitWindowInstance) -> String {
        "\(ruleID.uuidString)\(CustomLimitEvaluatorDefaults.keySeparator)\(instance.key)"
    }

    // MARK: - Private Methods

    private static func evaluate(rule: CustomLimit, input: Input) -> CustomLimitEvaluation {
        let window = input.usage?.allWindows.first { $0.id == rule.windowID }
        let instance = window.map(CustomLimitWindowInstance.init(window:))
            ?? CustomLimitWindowInstance(windowID: rule.windowID, resetsAt: nil)

        guard rule.isSupported else {
            return CustomLimitEvaluation(
                rule: rule,
                instance: instance,
                consumedOfBound: nil,
                windowFraction: window?.fraction,
                state: .unsupported,
                reason: .notEvaluated(rule.metric),
                crossedThresholds: []
            )
        }

        // An expired window keeps its identity and loses its number: the percentage describes the
        // turn before this one, and reading it as consumption would fire this instance's alerts
        // off last instance's spend.
        let live = window.flatMap { $0.isExpired(at: input.now) ? nil : $0.fraction }

        guard let live else {
            return CustomLimitEvaluation(
                rule: rule,
                instance: instance,
                consumedOfBound: nil,
                windowFraction: nil,
                state: .unknown,
                reason: .noReading,
                crossedThresholds: []
            )
        }

        let consumed = live / rule.bound
        let alreadyFired = Set(input.fired[firedKey(ruleID: rule.id, instance: instance)] ?? [])
        let crossed = rule.thresholds
            .filter { consumed >= $0 - CustomLimitEvaluatorDefaults.crossingTolerance }
            .filter { !alreadyFired.contains($0) }
            .sorted()

        let atBound = consumed >= CustomLimitDefaults.boundThreshold
            - CustomLimitEvaluatorDefaults.crossingTolerance
        let state = self.state(atBound: atBound, consumed: consumed, rule: rule)

        return CustomLimitEvaluation(
            rule: rule,
            instance: instance,
            consumedOfBound: consumed,
            windowFraction: live,
            state: state,
            reason: atBound
                ? .atBound(consumedOfBound: consumed)
                : .underBound(consumedOfBound: consumed),
            crossedThresholds: crossed
        )
    }

    /// Where the reading puts the rule on the ladder. The tier decides only what happens *at* the
    /// bound; everything below it reads the same whatever is armed.
    private static func state(
        atBound: Bool,
        consumed: Double,
        rule: CustomLimit
    ) -> CustomLimitState {
        guard atBound else {
            let lowest = rule.thresholds.first ?? CustomLimitDefaults.boundThreshold
            return consumed >= lowest - CustomLimitEvaluatorDefaults.crossingTolerance
                ? .near
                : .clear
        }
        switch rule.effectiveTier {
        case .show, .notify: return .reached
        case .hold: return .holding
        case .park: return .parked
        }
    }
}

// MARK: - Custom Limit Bounds

/// Which of the user's lines a surface should draw on one window, and what tint that window
/// should take.
///
/// Separate from the evaluator because it answers a different question. The evaluator asks "has
/// this rule anything to say right now"; this asks "where is the line on this bar", which every
/// surface that *draws* a window needs and none of them should compute for itself — a pill, a bar
/// and a menu column disagreeing about which of two rules binds a window would be three readings
/// of one fact.
enum CustomLimitBounds {

    /// The tightest line drawn on one window, or nil when none is.
    ///
    /// **A rule at the provider's own line draws nothing.** Its bound *is* the window, so a tick
    /// at 100% would mark the end of the bar as though the user had put it there — and an
    /// alert-only rule that exists to fire one notification must not add furniture to a gauge.
    /// Rules this build cannot evaluate draw nothing either, for the reason they are not
    /// evaluated: a pace share's bound is a share of elapsed time, and drawn as a fixed tick it
    /// would be a line the user never asked for.
    static func tightest(on windowID: String, in rules: [CustomLimit]) -> CustomLimit? {
        rules
            .filter { $0.isSupported }
            .filter { $0.windowID == windowID }
            .filter { $0.bound < CustomLimitDefaults.boundThreshold }
            .min { $0.bound < $1.bound }
    }

    /// The effective bound on a window: the tighter of the provider's whole window and the user's
    /// own line. `1` when nothing of theirs binds it, which is the shipped formula exactly.
    static func effectiveBound(on windowID: String, in rules: [CustomLimit]) -> Double {
        tightest(on: windowID, in: rules)?.bound ?? CustomLimitDefaults.boundThreshold
    }

    /// The severity a window's reading takes once the user's line is what it is measured against.
    ///
    /// Reuses `warningFraction`/`criticalFraction` on consumed-of-bound rather than inventing a
    /// second severity vocabulary — a login fenced off at half reads as nearly spent at 47% while
    /// still printing 47%. The number is the fact; the tint is the pressure.
    static func severity(
        of fraction: Double?,
        on windowID: String,
        in rules: [CustomLimit]
    ) -> UsageSeverity {
        guard let fraction else { return UsageSeverity.from(fraction: nil) }
        return UsageSeverity.from(
            fraction: fraction / effectiveBound(on: windowID, in: rules)
        )
    }

    /// The rules allowed to move the **always-visible** pill.
    ///
    /// Opt-in per rule, and off by default: the one surface that cannot be dismissed must not
    /// acquire a new red state because a rule was created to fire one quiet 50% alert. Every
    /// other surface — a popover the user opened, a menu they are choosing in — reads every rule,
    /// because they asked to be there.
    static func toolbarRules(_ rules: [CustomLimit]) -> [CustomLimit] {
        rules.filter(\.showsInToolbar)
    }

    /// The same written-out readings with their severities measured against the user's lines.
    ///
    /// One implementation, because two surfaces disagreeing about which of two rules binds a
    /// window would be two readings of one fact — and because the rule that matters here is
    /// negative: **only the tint changes**. The name, the printed value and the length are the
    /// provider's own and are carried through untouched.
    static func retinted(
        _ readings: [AccountUsage.Reading],
        of windows: [AccountUsage.Window],
        in rules: [CustomLimit]
    ) -> [AccountUsage.Reading] {
        guard !rules.isEmpty else { return readings }
        return zip(windows, readings).map { window, reading in
            AccountUsage.Reading(
                name: reading.name,
                value: reading.value,
                severity: severity(of: reading.fraction, on: window.id, in: rules),
                fraction: reading.fraction
            )
        }
    }

    /// The window a session runs out of *first* once the user's own lines are what it is measured
    /// against — the one the toolbar's ring gauges.
    ///
    /// The shipped rule is the fullest window; this is the fullest **share of its bound**, which
    /// is the shipped rule exactly when no line is drawn. A weekly at 56% beside a five-hour at
    /// 40% under a 45% line: the five-hour is what stops the work, and the ring belongs to
    /// whatever stops the work.
    static func bindingWindow(
        among windows: [AccountUsage.Window],
        in rules: [CustomLimit],
        at now: Date = Date()
    ) -> AccountUsage.Window? {
        windows
            .filter { !$0.isExpired(at: now) && $0.fraction != nil }
            .max {
                ($0.fraction ?? 0) / effectiveBound(on: $0.id, in: rules)
                    < ($1.fraction ?? 0) / effectiveBound(on: $1.id, in: rules)
            }
    }
}

// MARK: - Custom Limit Evaluator Defaults

enum CustomLimitEvaluatorDefaults {

    /// Between a rule's id and its window instance in a fired-state key.
    static let keySeparator = "|"

    /// Between a window's identifier and its reset moment in an instance key.
    static let instanceSeparator = "@"

    /// Stands in for the reset moment of a window the provider reports without one.
    static let noResetKey = "none"

    /// How close to a threshold counts as having reached it.
    ///
    /// Half a hundredth of a percentage point. Thresholds are stored rounded to whole percentage
    /// points and fractions arrive as provider decimals, so a line at exactly 0.5 and a reading of
    /// exactly 0.5 must not turn on the last bit of a binary double — a rule that declines to fire
    /// at precisely the number the user typed is the one complaint this feature cannot answer.
    static let crossingTolerance = 0.000_05
}
