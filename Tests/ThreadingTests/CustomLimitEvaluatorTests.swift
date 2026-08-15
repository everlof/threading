import XCTest
@testable import Threading

/// The user's own limits, ahead of the provider's.
///
/// Every case here is table-driven and pure — no network, no home directory, no clock of its own.
/// That is the point of the evaluator being a separate type: a rule that stands between a person
/// and their own quota has to be arguable from a table, because the failures are all *quiet* ones.
/// An alert that does not fire and a hold that engages on nothing look identical from outside the
/// app, and only these assertions tell them apart.
final class CustomLimitEvaluatorTests: XCTestCase {

    // MARK: - Fixtures

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func window(
        id: String = UsageDefaults.weeklyWindowID,
        fraction: Double?,
        resetsIn: TimeInterval = 3 * 86_400,
        duration: TimeInterval = UsageDefaults.sevenDaySeconds
    ) -> AccountUsage.Window {
        AccountUsage.Window(
            id: id,
            label: UsageDefaults.weeklyLabel,
            fraction: fraction,
            resetsAt: now.addingTimeInterval(resetsIn),
            windowDuration: duration
        )
    }

    private func usage(_ windows: [AccountUsage.Window]) -> AccountUsage {
        AccountUsage(
            windows: windows,
            planLabel: "Max",
            observedAt: now,
            source: .api
        )
    }

    private func evaluate(
        _ rules: [CustomLimit],
        _ usage: AccountUsage?,
        fired: [String: [Double]] = [:],
        at moment: Date? = nil
    ) -> [CustomLimitEvaluation] {
        CustomLimitEvaluator.evaluate(CustomLimitEvaluator.Input(
            rules: rules,
            usage: usage,
            fired: fired,
            now: moment ?? now
        ))
    }

    // MARK: - Consumed Of Bound

    /// The bound is the denominator. A window at 60% under an 80% line is three quarters spent —
    /// which is the number a tint reads, while the number *printed* stays 60%.
    func testConsumptionIsMeasuredAgainstTheUsersOwnLine() throws {
        let rule = CustomLimit(windowID: UsageDefaults.weeklyWindowID, bound: 0.8)
        let result = try XCTUnwrap(evaluate([rule], usage([window(fraction: 0.6)])).first)

        XCTAssertEqual(try XCTUnwrap(result.consumedOfBound), 0.75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.windowFraction), 0.6, accuracy: 0.0001)
    }

    /// The raw fraction survives every rule, because a bar's length and the percentage beside it
    /// come from it. A bar drawing full at 40% would lie about the figure it sits under.
    func testTheRawProviderFractionIsCarriedAlongsideTheDerivedOne() throws {
        let rule = CustomLimit(windowID: UsageDefaults.weeklyWindowID, bound: 0.5)
        let result = try XCTUnwrap(evaluate([rule], usage([window(fraction: 0.47)])).first)

        XCTAssertEqual(try XCTUnwrap(result.windowFraction), 0.47, accuracy: 0.0001)
        XCTAssertEqual(
            UsageSeverity.from(fraction: 0.47),
            .normal,
            "the provider reads this account as comfortable, which is the point of the next line"
        )
        XCTAssertEqual(
            result.severity,
            .critical,
            "a login fenced off at half should read as nearly spent while printing 47%"
        )
    }

    // MARK: - Crossings

    /// The whole point of the fired state: a line is announced once per turn of its window.
    func testALineIsAnnouncedOnceAndThenStaysQuiet() throws {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        let reading = usage([window(fraction: 0.52)])

        let first = try XCTUnwrap(evaluate([rule], reading).first)
        XCTAssertEqual(first.crossedThresholds, [1.0])
        XCTAssertTrue(first.wantsNotification)

        let key = CustomLimitEvaluator.firedKey(ruleID: rule.id, instance: first.instance)
        let second = try XCTUnwrap(evaluate([rule], reading, fired: [key: [1.0]]).first)
        XCTAssertEqual(second.crossedThresholds, [])
        XCTAssertFalse(second.wantsNotification)
    }

    /// A sparse reading that steps over two lines at once fires **once**, naming the highest.
    /// Both lines are still marked, so the one stepped over never arrives late.
    func testASparseJumpNamesTheHighestLineAndMarksThemAll() throws {
        let rule = CustomLimit.everyStep(
            windowID: UsageDefaults.weeklyWindowID,
            step: CustomLimitDefaults.tenPercentStep
        )

        let before = try XCTUnwrap(evaluate([rule], usage([window(fraction: 0.48)])).first)
        XCTAssertEqual(before.announcedThreshold.map { ($0 * 100).rounded() }, 40)

        let key = CustomLimitEvaluator.firedKey(ruleID: rule.id, instance: before.instance)
        let after = try XCTUnwrap(
            evaluate([rule], usage([window(fraction: 0.61)]), fired: [key: before.crossedThresholds])
                .first
        )

        XCTAssertEqual(
            after.announcedThreshold.map { ($0 * 100).rounded() },
            60,
            "the jump should name the line it landed past, not the one below it"
        )
        XCTAssertEqual(
            after.crossedThresholds.map { ($0 * 100).rounded() },
            [50, 60],
            "the line stepped over must be marked too, or it arrives one reading late"
        )
    }

    /// A rule at exactly the number the user typed must fire at exactly that number. Thresholds
    /// are stored as rounded percentage points and fractions arrive as provider decimals, so this
    /// is the one place a binary double could decline to answer.
    func testALineFiresAtPreciselyTheNumberItNames() throws {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        let result = try XCTUnwrap(evaluate([rule], usage([window(fraction: 0.5)])).first)

        XCTAssertEqual(result.crossedThresholds, [1.0])
        XCTAssertEqual(result.state, .reached)
    }

    // MARK: - Re-Arming

    /// A reset re-arms everything, and it does so by *identity*: the fired record belongs to the
    /// turn of the window that ended, and its key no longer matches.
    func testAResetGivesTheRuleItsVoiceBack() throws {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)

        let thisWeek = try XCTUnwrap(evaluate([rule], usage([window(fraction: 0.52)])).first)
        let key = CustomLimitEvaluator.firedKey(ruleID: rule.id, instance: thisWeek.instance)

        // Same rule, same window identifier, a week later: a different instance, so the record
        // above says nothing about it.
        let nextWeek = try XCTUnwrap(
            evaluate(
                [rule],
                usage([window(fraction: 0.55, resetsIn: 10 * 86_400)]),
                fired: [key: [1.0]]
            ).first
        )

        XCTAssertNotEqual(nextWeek.instance, thisWeek.instance)
        XCTAssertEqual(nextWeek.crossedThresholds, [1.0])
        XCTAssertTrue(nextWeek.wantsNotification)
    }

    /// Two turns of the same window are two instances; two windows are two instances even when
    /// they reset together.
    func testWindowInstanceIdentityIsTheWindowAndItsReset() {
        let reset = now.addingTimeInterval(3_600)
        let weekly = CustomLimitWindowInstance(windowID: "7d", resetsAt: reset)

        XCTAssertEqual(weekly, CustomLimitWindowInstance(windowID: "7d", resetsAt: reset))
        XCTAssertNotEqual(weekly, CustomLimitWindowInstance(windowID: "5h", resetsAt: reset))
        XCTAssertNotEqual(
            weekly,
            CustomLimitWindowInstance(windowID: "7d", resetsAt: reset.addingTimeInterval(60))
        )
        XCTAssertNotEqual(
            weekly.key,
            CustomLimitWindowInstance(windowID: "7d", resetsAt: nil).key
        )
    }

    // MARK: - Honesty

    /// An alert derived from a guess is noise. Notify goes silent on an unknown reading, and says
    /// so as a missing *reading* rather than as consumption — the two have opposite remedies.
    func testAnUnknownReadingNeverFires() throws {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)

        let readings: [AccountUsage?] = [usage([window(fraction: nil)]), usage([]), nil]
        for reading in readings {
            let result = try XCTUnwrap(evaluate([rule], reading).first)
            XCTAssertEqual(result.state, .unknown)
            XCTAssertEqual(result.reason, .noReading)
            XCTAssertNil(result.consumedOfBound)
            XCTAssertFalse(result.wantsNotification)
        }
    }

    /// An expired window keeps its identity and loses its number. Reading the leftover as
    /// consumption would fire this instance's alerts off the previous instance's spend.
    func testAnExpiredWindowsPercentageIsNotThisInstancesSpend() throws {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        let stale = usage([window(fraction: 0.97, resetsIn: -60)])

        let result = try XCTUnwrap(evaluate([rule], stale).first)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertFalse(result.wantsNotification)
    }

    /// A rule written by a later build is listed and not evaluated. Reading a synthetic window's
    /// bound as a fixed cap would fire alerts at a line the user never drew — its bound is a
    /// budget per trailing span, not a position on this window's bar.
    func testAMetricThisBuildDoesNotUnderstandIsNotGuessedAt() throws {
        let rule = CustomLimit(
            windowID: UsageDefaults.weeklyWindowID,
            metric: .syntheticWindow,
            bound: 0.5
        )
        let result = try XCTUnwrap(evaluate([rule], usage([window(fraction: 0.9)])).first)

        XCTAssertEqual(result.state, .unsupported)
        XCTAssertEqual(result.reason, .notEvaluated(.syntheticWindow))
        XCTAssertFalse(result.wantsNotification)
    }

    /// A rule names its window, so it keeps meaning that window on a morning when another one is
    /// the fuller one. A line that wandered between windows without the user touching it would be
    /// unarguable.
    func testARuleMeasuresTheWindowItNamesAndNotThePeak() throws {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        let reading = usage([
            window(id: UsageDefaults.fiveHourWindowID, fraction: 0.98, resetsIn: 3_600),
            window(fraction: 0.2)
        ])

        let result = try XCTUnwrap(evaluate([rule], reading).first)
        XCTAssertEqual(try XCTUnwrap(result.windowFraction), 0.2, accuracy: 0.0001)
        XCTAssertFalse(result.wantsNotification)
    }

    // MARK: - Tiers

    /// A `show` rule draws its line and says nothing. The tier is what arms the notification, not
    /// the crossing.
    func testAShowOnlyRuleCrossesItsLineSilently() throws {
        let rule = CustomLimit(
            windowID: UsageDefaults.weeklyWindowID,
            bound: 0.5,
            tier: .show
        )
        let result = try XCTUnwrap(evaluate([rule], usage([window(fraction: 0.6)])).first)

        XCTAssertEqual(result.crossedThresholds, [1.0])
        XCTAssertFalse(result.wantsNotification)
        XCTAssertEqual(result.state, .reached)
    }

    /// A rule stored at a tier this build does not implement still evaluates, clamped to what can
    /// actually be done. A limit that decodes and then does nothing is the silent forgetting the
    /// stored raw values exist to prevent.
    ///
    /// Asserted as the **invariant** rather than against one tier, because the ceiling moves as
    /// the ladder is implemented: a test pinned to yesterday's ceiling fails the day the next
    /// tier lands, and the thing worth protecting is that no rule ever acts *above* the ceiling.
    func testATierIsNeverActedOnAboveWhatThisBuildImplements() throws {
        for tier in CustomLimitTier.allCases {
            let rule = CustomLimit(windowID: UsageDefaults.weeklyWindowID, bound: 0.5, tier: tier)
            let result = try XCTUnwrap(evaluate([rule], usage([window(fraction: 0.6)])).first)

            XCTAssertLessThanOrEqual(
                rule.effectiveTier,
                CustomLimitDefaults.highestImplementedTier,
                "a \(tier.rawValue) rule armed above what this build implements"
            )
            XCTAssertLessThanOrEqual(rule.effectiveTier, tier, "a rule was armed above its own tier")
            XCTAssertTrue(result.state.isAtBound)
        }
    }

    // MARK: - The Record

    /// The bound is a fraction and stays one: zero is permanently crossed, which is a rule that
    /// can only ever be noise.
    func testABoundIsHeldInsideTheRangeAFractionCanOccupy() {
        XCTAssertEqual(CustomLimit(windowID: "7d", bound: 0).bound, CustomLimitDefaults.minimumBound)
        XCTAssertEqual(CustomLimit(windowID: "7d", bound: 4).bound, 1.0)
        XCTAssertEqual(CustomLimit(windowID: "7d", bound: .nan).bound, 1.0)
    }

    func testThresholdsAreSortedDeduplicatedAndNeverEmpty() {
        XCTAssertEqual(
            CustomLimit(windowID: "7d", bound: 1, thresholds: [0.9, 0.5, 0.5, 0.75]).thresholds,
            [0.5, 0.75, 0.9]
        )
        XCTAssertEqual(
            CustomLimit(windowID: "7d", bound: 1, thresholds: [0, -1, 2]).thresholds,
            [1.0],
            "a rule with no usable line should keep the bound itself, not fall silent"
        )
    }

    /// "Every 10%" is ten lines ending on the bound, not nine or eleven.
    func testTheEveryStepTemplateEndsOnTheBound() {
        let rule = CustomLimit.everyStep(
            windowID: "7d",
            step: CustomLimitDefaults.tenPercentStep
        )
        XCTAssertEqual(rule.thresholds.count, 10)
        XCTAssertEqual(rule.thresholds.last, 1.0)
        XCTAssertEqual(rule.thresholds.first, 0.1)
    }

    /// An alert-only rule puts the line where the user said and arms nothing above notify.
    func testTheAlertTemplateIsTheLineItself() {
        let rule = CustomLimit.alert(windowID: "7d", at: 0.5)
        XCTAssertEqual(rule.bound, 0.5)
        XCTAssertEqual(rule.thresholds, [1.0])
        XCTAssertEqual(rule.tier, .notify)
        XCTAssertFalse(
            rule.showsInToolbar,
            "a rule made to fire one quiet alert must not give the pill a new red state"
        )
    }

    /// The window percentages a bar or a chart would draw the ticks at.
    func testWindowThresholdsAreTheLinesAsTheWindowReadsThem() {
        let rule = CustomLimit(windowID: "7d", bound: 0.8, thresholds: [0.5, 1.0])
        XCTAssertEqual(rule.windowThresholds.map { ($0 * 100).rounded() }, [40, 80])
    }

    // MARK: - Receipts

    /// The percentage a sentence names is always the one the *window* reads, because that is the
    /// number printed everywhere else. A notification quoting a fraction of a bound would be the
    /// only place in the app where "60%" meant something else.
    func testAnAnnouncementNamesTheWindowsOwnPercentage() throws {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        let result = try XCTUnwrap(evaluate([rule], usage([window(fraction: 0.52)])).first)

        let sentence = CustomLimitReceipt.announcement(for: result, windowName: "Weekly")
        XCTAssertTrue(sentence.contains("50%"), sentence)
        XCTAssertTrue(sentence.contains("Weekly"), sentence)
    }

    /// A missing reading is reported as a missing reading. "Over your line" and "cannot see" have
    /// opposite remedies, and a receipt that confuses them sends the reader hunting for spend
    /// that never happened.
    func testAMissingReadingSaysSoRatherThanReportingSpend() throws {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        let result = try XCTUnwrap(evaluate([rule], nil).first)

        let sentence = CustomLimitReceipt.status(for: result, windowName: "Weekly")
        XCTAssertEqual(sentence, "No Weekly reading yet.")
    }

    /// A rule at the provider's own line has no "your limit" to name, and saying "100% of your
    /// 100% limit" would be the feature reading as its own parody.
    func testARuleAtTheProvidersOwnLineDoesNotInventAUserLimit() throws {
        let rule = CustomLimit.everyStep(
            windowID: UsageDefaults.weeklyWindowID,
            step: CustomLimitDefaults.tenPercentStep
        )
        let result = try XCTUnwrap(evaluate([rule], usage([window(fraction: 0.61)])).first)

        let sentence = CustomLimitReceipt.announcement(for: result, windowName: "Weekly")
        XCTAssertEqual(sentence, "Weekly has reached 60%.")
    }
}
