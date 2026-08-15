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
/// `parked` is declared and not yet produced — it arrives with tier 4, and naming it here keeps
/// that slice from renaming a state a receipt or a test already names.
/// `CustomLimitTier.isImplemented` is what stops this build claiming it.
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

    /// At or over the bound on a tier-3 rule: Threading's own spend has stood down.
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

        /// Sparse fraction history per window id, for the synthetic-window metric. Only the rules
        /// that name a window need it, and only over their own span — nothing here scans a
        /// transcript, and the history is already kept for the dashboard.
        var history: [String: [UsageSample]] = [:]

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

        // A synthetic window measures something else entirely: not where the provider window
        // stands, but how much of it was spent inside the trailing span. Its own branch, because
        // sharing the fixed-cap path would mean dividing a *position* by a *budget*.
        if rule.metric == .syntheticWindow {
            return evaluateTrailing(rule: rule, window: window, instance: instance, input: input)
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

        guard let bound = CustomLimitBounds.resolvedBound(of: rule, window: window, at: input.now) else {
            // The rule is supported but its line cannot be placed from this reading — a pace
            // share on a window whose length the provider never stated. Reported as a missing
            // reading, which is what it is.
            return CustomLimitEvaluation(
                rule: rule,
                instance: instance,
                consumedOfBound: nil,
                windowFraction: live,
                state: .unknown,
                reason: .noReading,
                crossedThresholds: []
            )
        }

        let consumed = CustomLimitBounds.consumedOfBound(fraction: live, bound: bound)
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

    /// A synthetic window's answer: consumption inside the trailing span against its budget.
    ///
    /// The **instance** is the trailing span itself rather than the provider window's turn, which
    /// is what makes a synthetic rule's alerts re-arm sensibly: a trailing sum has no reset to
    /// re-arm on, so a line crossed and then fallen back below is allowed to be crossed again
    /// once consumption has actually left the span. Keying on the provider window's reset would
    /// have meant one announcement per *week* for a rule about five hours.
    private static func evaluateTrailing(
        rule: CustomLimit,
        window: AccountUsage.Window?,
        instance: CustomLimitWindowInstance,
        input: Input
    ) -> CustomLimitEvaluation {
        let live = window.flatMap { $0.isExpired(at: input.now) ? nil : $0.fraction }

        guard let span = rule.trailingSpan,
              let spent = CustomLimitTrailingWindow.consumption(
                  in: input.history[rule.windowID] ?? [],
                  span: span,
                  at: input.now
              ) else {
            return CustomLimitEvaluation(
                rule: rule,
                instance: instance,
                consumedOfBound: nil,
                windowFraction: live,
                state: .unknown,
                reason: .noReading,
                crossedThresholds: []
            )
        }

        let consumed = CustomLimitBounds.consumedOfBound(fraction: spent, bound: rule.bound)
        let trailingInstance = CustomLimitWindowInstance(
            windowID: rule.windowID,
            resetsAt: input.now.addingTimeInterval(span)
        )
        let alreadyFired = Set(
            input.fired[firedKey(ruleID: rule.id, instance: trailingInstance)] ?? []
        )
        let crossed = rule.thresholds
            .filter { consumed >= $0 - CustomLimitEvaluatorDefaults.crossingTolerance }
            .filter { !alreadyFired.contains($0) }
            .sorted()

        let atBound = consumed >= CustomLimitDefaults.boundThreshold
            - CustomLimitEvaluatorDefaults.crossingTolerance

        return CustomLimitEvaluation(
            rule: rule,
            instance: trailingInstance,
            consumedOfBound: consumed,
            // The number a surface *prints* for a synthetic rule is the trailing spend, not the
            // provider window's position: a rule about "any five hours" that printed the weekly's
            // 62% would be naming a figure it is not measuring.
            windowFraction: spent,
            state: state(atBound: atBound, consumed: consumed, rule: rule),
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

    /// The line a rule draws **right now**, as a fraction of the window it names.
    ///
    /// A fixed cap's line is a constant and a pace share's rises with the clock, so every consumer
    /// asks for it at a moment rather than reading `rule.bound` directly — `rule.bound` is what
    /// the *user typed*, and for a pace share that is a share of elapsed time rather than a
    /// position on the bar.
    ///
    /// Nil when the rule cannot be resolved from what is here: a pace share on a window whose
    /// length the provider never stated has no elapsed fraction to take a share of, and inventing
    /// one would draw a line nobody set. Callers read nil as "cannot see", which holds and does
    /// not alert — the asymmetry the whole feature turns on.
    static func resolvedBound(
        of rule: CustomLimit,
        window: AccountUsage.Window?,
        at now: Date = Date()
    ) -> Double? {
        switch rule.metric {
        case .fixedCap:
            return rule.bound
        case .paceShare:
            guard let elapsed = window?.elapsedFraction(at: now) else { return nil }
            return rule.bound * elapsed
        case .syntheticWindow:
            return nil
        }
    }

    /// How much of a rule's line is spent, given the window's own reading.
    ///
    /// **Zero spend is zero consumption, whatever the line is.** A literal pace share opens each
    /// window with a bound of exactly zero, and the division at that instant is `0 / 0`. The
    /// answer is not "infinitely over": nothing has been released and nothing has been spent, so
    /// nothing has been taken from the account's owner. Reading it any other way would put every
    /// pace-share rule in breach for the first minutes of every window, which is the one stretch
    /// where the rule is trivially satisfied.
    static func consumedOfBound(fraction: Double, bound: Double) -> Double {
        guard fraction > 0 else { return 0 }
        guard bound > 0 else { return .infinity }
        return fraction / bound
    }

    /// The tightest line drawn on one window, or nil when none is.
    ///
    /// **A rule at the provider's own line draws nothing.** Its bound *is* the window, so a tick
    /// at 100% would mark the end of the bar as though the user had put it there — and an
    /// alert-only rule that exists to fire one notification must not add furniture to a gauge.
    /// Rules this build cannot evaluate draw nothing either, for the reason they are not
    /// evaluated: a pace share's bound is a share of elapsed time, and drawn as a fixed tick it
    /// would be a line the user never asked for.
    static func tightest(
        on windowID: String,
        in rules: [CustomLimit],
        window: AccountUsage.Window? = nil,
        at now: Date = Date()
    ) -> CustomLimit? {
        rules
            .filter { $0.isSupported && $0.windowID == windowID }
            .filter { rule in
                guard let bound = resolvedBound(of: rule, window: window, at: now) else {
                    return false
                }
                return bound < CustomLimitDefaults.boundThreshold
            }
            .min { left, right in
                let leftBound = resolvedBound(of: left, window: window, at: now)
                    ?? CustomLimitDefaults.boundThreshold
                let rightBound = resolvedBound(of: right, window: window, at: now)
                    ?? CustomLimitDefaults.boundThreshold
                return leftBound < rightBound
            }
    }

    /// The effective bound on a window: the tighter of the provider's whole window and the user's
    /// own line. `1` when nothing of theirs binds it, which is the shipped formula exactly.
    static func effectiveBound(
        on windowID: String,
        in rules: [CustomLimit],
        window: AccountUsage.Window? = nil,
        at now: Date = Date()
    ) -> Double {
        guard let rule = tightest(on: windowID, in: rules, window: window, at: now),
              let bound = resolvedBound(of: rule, window: window, at: now) else {
            return CustomLimitDefaults.boundThreshold
        }
        return bound
    }

    /// The severity a window's reading takes once the user's line is what it is measured against.
    ///
    /// Reuses `warningFraction`/`criticalFraction` on consumed-of-bound rather than inventing a
    /// second severity vocabulary — a login fenced off at half reads as nearly spent at 47% while
    /// still printing 47%. The number is the fact; the tint is the pressure.
    static func severity(
        of fraction: Double?,
        on windowID: String,
        in rules: [CustomLimit],
        window: AccountUsage.Window? = nil,
        at now: Date = Date()
    ) -> UsageSeverity {
        guard let fraction else { return UsageSeverity.from(fraction: nil) }
        return UsageSeverity.from(fraction: consumedOfBound(
            fraction: fraction,
            bound: effectiveBound(on: windowID, in: rules, window: window, at: now)
        ))
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
        in rules: [CustomLimit],
        at now: Date = Date()
    ) -> [AccountUsage.Reading] {
        guard !rules.isEmpty else { return readings }
        return zip(windows, readings).map { window, reading in
            AccountUsage.Reading(
                name: reading.name,
                value: reading.value,
                severity: severity(
                    of: reading.fraction,
                    on: window.id,
                    in: rules,
                    window: window,
                    at: now
                ),
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
    /// Whether Threading-initiated spend stands down on this account, and which rule says so.
    ///
    /// Only rules armed at `hold` or above are asked: a rule that exists to draw a line on a bar
    /// or fire one notification has not been given permission to stop anything, and reading it as
    /// though it had would be the feature taking an authority nobody granted it.
    ///
    /// The **first** binding rule wins rather than the tightest, in the rules' own order, so the
    /// sentence a receipt prints is stable while a reading moves. Unknown beats over-line when
    /// both are present, because it is the one whose remedy is "look again".
    static func hold(
        on usage: AccountUsage?,
        in rules: [CustomLimit],
        history: [String: [UsageSample]] = [:],
        at now: Date = Date()
    ) -> CustomLimitHold {
        var overLine: CustomLimitHold?

        for rule in rules where rule.isSupported && rule.effectiveTier >= .hold {
            let window = usage?.allWindows.first { $0.id == rule.windowID }
            let name = window?.label ?? UsageDefaults.label(forWindowID: rule.windowID)

            let live: Double?
            let bound: Double?
            if rule.metric == .syntheticWindow {
                live = rule.trailingSpan.flatMap { span in
                    CustomLimitTrailingWindow.consumption(
                        in: history[rule.windowID] ?? [],
                        span: span,
                        at: now
                    )
                }
                bound = rule.bound
            } else {
                live = window.flatMap { $0.isExpired(at: now) ? nil : $0.fraction }
                bound = resolvedBound(of: rule, window: window, at: now)
            }

            guard let live, let bound else {
                return .cannotSee(rule: rule, windowName: name)
            }
            if overLine == nil,
               consumedOfBound(fraction: live, bound: bound) >= CustomLimitDefaults.boundThreshold
                   - CustomLimitEvaluatorDefaults.crossingTolerance {
                overLine = .overLine(rule: rule, windowName: name)
            }
        }

        return overLine ?? .clear
    }

    /// Whether sessions on this account are **parked** — held at their next turn boundary — and
    /// which rule says so.
    ///
    /// A park is a hold plus one more consequence, so it asks the same question of a narrower set:
    /// only rules armed at `park`, and only where the user has not already walked through this
    /// turn of the window.
    ///
    /// Two deliberate differences from a provider park, and they are the whole design:
    ///
    /// - **It is not the triangle.** `ThemedWarningMark` means "the provider stopped this and you
    ///   cannot answer it". A self-imposed cap is conduct, not weather, so it reads as a conduct
    ///   mark on an otherwise idle row, and there is no new `SessionActivity` case — the process
    ///   really is idle and the provider really would accept a turn.
    /// - **Continue Anyway is real.** The rule is the user's own, so overriding it is legitimate;
    ///   the override is scoped to this window instance and expires with it.
    static func park(
        on usage: AccountUsage?,
        in rules: [CustomLimit],
        overrides: Set<String> = [],
        history: [String: [UsageSample]] = [:],
        at now: Date = Date()
    ) -> CustomLimitHold {
        var overLine: CustomLimitHold?

        for rule in rules where rule.isSupported && rule.effectiveTier >= .park {
            let window = usage?.allWindows.first { $0.id == rule.windowID }
            let instance = window.map(CustomLimitWindowInstance.init(window:))
                ?? CustomLimitWindowInstance(windowID: rule.windowID, resetsAt: nil)
            if overrides.contains(firedKeyForOverride(ruleID: rule.id, instance: instance)) {
                continue
            }

            let name = window?.label ?? UsageDefaults.label(forWindowID: rule.windowID)

            let live: Double?
            let bound: Double?
            if rule.metric == .syntheticWindow {
                live = rule.trailingSpan.flatMap { span in
                    CustomLimitTrailingWindow.consumption(
                        in: history[rule.windowID] ?? [],
                        span: span,
                        at: now
                    )
                }
                bound = rule.bound
            } else {
                live = window.flatMap { $0.isExpired(at: now) ? nil : $0.fraction }
                bound = resolvedBound(of: rule, window: window, at: now)
            }

            guard let live, let bound else {
                return .cannotSee(rule: rule, windowName: name)
            }
            if overLine == nil,
               consumedOfBound(fraction: live, bound: bound) >= CustomLimitDefaults.boundThreshold
                   - CustomLimitEvaluatorDefaults.crossingTolerance {
                overLine = .overLine(rule: rule, windowName: name)
            }
        }

        return overLine ?? .clear
    }

    /// The key an override is filed under — the evaluator's own, so a park and an alert cannot
    /// disagree about which turn of which window a record belongs to.
    static func firedKeyForOverride(
        ruleID: UUID,
        instance: CustomLimitWindowInstance
    ) -> String {
        CustomLimitEvaluator.firedKey(ruleID: ruleID, instance: instance)
    }

    static func bindingWindow(
        among windows: [AccountUsage.Window],
        in rules: [CustomLimit],
        at now: Date = Date()
    ) -> AccountUsage.Window? {
        windows
            .filter { !$0.isExpired(at: now) && $0.fraction != nil }
            .max { left, right in
                consumedOfBound(
                    fraction: left.fraction ?? 0,
                    bound: effectiveBound(on: left.id, in: rules, window: left, at: now)
                ) < consumedOfBound(
                    fraction: right.fraction ?? 0,
                    bound: effectiveBound(on: right.id, in: rules, window: right, at: now)
                )
            }
    }
}

// MARK: - Custom Limit Hold

/// Whether Threading's **own** spend stands down on an account right now, and why.
///
/// One decision for all four seams — the scheduled-send delivery, the usage-window poke, the
/// escape ranking's eligibility and the control plane's admission — because a hold that four call
/// sites each decided for themselves would be four subtly different lines, and the user drew one.
///
/// The honesty boundary is the whole shape of this type. Threading can guarantee its own conduct;
/// it cannot stop the keyboard. So the two refusing cases are kept apart rather than collapsed
/// into a bool: **"over your line" and "cannot see" have opposite remedies**, and a receipt that
/// says the wrong one sends the reader looking for spend that never happened.
enum CustomLimitHold: Equatable {

    /// Nothing of the user's binds this account, or nothing that binds it is reached.
    case clear

    /// A rule of theirs is at or past its bound.
    case overLine(rule: CustomLimit, windowName: String)

    /// A rule of theirs needs a reading that is not there.
    ///
    /// **Holds engage on unknowns**, asymmetrically with alerts, which go silent on them. An
    /// alert derived from a guess is noise; a hold skipped because the reading was missing spends
    /// the user's quota for a reason they cannot see. "I could not look, so I spent anyway" is the
    /// wrong side of the ask that created the rule.
    case cannotSee(rule: CustomLimit, windowName: String)

    var isHolding: Bool { self != .clear }

    var rule: CustomLimit? {
        switch self {
        case .clear: return nil
        case .overLine(let rule, _), .cannotSee(let rule, _): return rule
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
