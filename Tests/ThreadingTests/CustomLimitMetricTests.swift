import XCTest
@testable import Threading

/// The two metrics beyond a fixed cap: a **pace share** whose line rises with the clock, and a
/// **synthetic window** that measures a trailing span the provider does not meter.
///
/// Both exist because a fixed cap answers only one of the three instructions people actually give
/// about their own quota. Both are also the two shapes where reading `rule.bound` directly would
/// be wrong — a pace share's bound is a share of elapsed time and a synthetic window's is a budget
/// per span — so most of what is asserted here is that nothing treats either as a position on a
/// bar.
final class CustomLimitMetricTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)
    private let weekly = UsageDefaults.weeklyWindowID

    // MARK: - Fixtures

    /// A weekly window with a chosen amount of its span already elapsed.
    private func window(fraction: Double?, elapsed: Double) -> AccountUsage.Window {
        AccountUsage.Window(
            id: weekly,
            label: UsageDefaults.weeklyLabel,
            fraction: fraction,
            resetsAt: now.addingTimeInterval(UsageDefaults.sevenDaySeconds * (1 - elapsed)),
            windowDuration: UsageDefaults.sevenDaySeconds
        )
    }

    private func usage(_ windows: [AccountUsage.Window]) -> AccountUsage {
        AccountUsage(windows: windows, planLabel: nil, observedAt: now, source: .api)
    }

    private func evaluate(
        _ rules: [CustomLimit],
        _ usage: AccountUsage?,
        history: [String: [UsageSample]] = [:],
        fired: [String: [Double]] = [:]
    ) -> [CustomLimitEvaluation] {
        CustomLimitEvaluator.evaluate(CustomLimitEvaluator.Input(
            rules: rules,
            usage: usage,
            fired: fired,
            history: history,
            now: now
        ))
    }

    private func sample(_ minutesAgo: Double, _ fraction: Double, resetsIn: TimeInterval = 86_400) -> UsageSample {
        UsageSample(
            at: now.addingTimeInterval(-minutesAgo * 60),
            fraction: fraction,
            resetsAt: now.addingTimeInterval(resetsIn),
            runtimeID: nil,
            accountID: nil,
            accountName: nil,
            windowID: weekly,
            windowLabel: nil,
            nextResetCreditExpiresAt: nil,
            resetCreditCount: nil
        )
    }

    // MARK: - Pace Share

    /// The line **rises with the clock**. Half the week gone, a half share: the line sits at a
    /// quarter of the window, and 20% spent is comfortably inside it.
    func testAPaceShareLineRisesWithTheClock() throws {
        let rule = CustomLimit.paceShare(windowID: weekly, share: 0.5)
        let halfway = window(fraction: 0.2, elapsed: 0.5)

        let bound = try XCTUnwrap(
            CustomLimitBounds.resolvedBound(of: rule, window: halfway, at: now)
        )
        XCTAssertEqual(bound, 0.25, accuracy: 0.001)

        let result = try XCTUnwrap(evaluate([rule], usage([halfway])).first)
        XCTAssertEqual(try XCTUnwrap(result.consumedOfBound), 0.8, accuracy: 0.01)
        XCTAssertFalse(result.state.isAtBound)
    }

    /// The guarantee, read the other way round: at any instant at least `(1 − share)` of what
    /// linear time has released is still waiting for the account's owner. Spending past that is
    /// what the rule is for.
    func testSpendingPastTheShareIsAtTheLine() throws {
        let rule = CustomLimit.paceShare(windowID: weekly, share: 0.5)
        let result = try XCTUnwrap(
            evaluate([rule], usage([window(fraction: 0.3, elapsed: 0.5)])).first
        )

        XCTAssertTrue(result.state.isAtBound)
    }

    /// **Zero spend is zero consumption, whatever the line is.**
    ///
    /// A literal pace share opens each window with a bound of exactly zero, and the division at
    /// that instant is `0 / 0`. The answer is not "infinitely over": nothing has been released and
    /// nothing has been taken from the account's owner. The draft asked whether the metric needs a
    /// grace floor at window open; it does not — this is the whole of what the floor would have
    /// bought, and the literal reading is what the instruction actually says.
    func testAPaceShareIsSatisfiedAtWindowOpenWithNothingSpent() throws {
        let rule = CustomLimit.paceShare(windowID: weekly, share: 0.5)
        let open = window(fraction: 0, elapsed: 0)

        let result = try XCTUnwrap(evaluate([rule], usage([open])).first)
        XCTAssertEqual(result.consumedOfBound, 0)
        XCTAssertFalse(result.state.isAtBound)
        XCTAssertEqual(
            CustomLimitBounds.hold(on: usage([open]), in: [rule], at: now),
            .clear
        )
    }

    /// And spending in the first instant *is* over the line, which is the strict reading and the
    /// right one: nothing has been released yet, so anything spent is the owner's share.
    func testSpendingAtWindowOpenIsOverAPaceShare() throws {
        let rule = CustomLimit.paceShare(windowID: weekly, share: 0.5)
        let result = try XCTUnwrap(
            evaluate([rule], usage([window(fraction: 0.01, elapsed: 0)])).first
        )
        XCTAssertTrue(result.state.isAtBound)
    }

    /// A window whose length the provider never stated has no elapsed fraction to take a share
    /// of. Reported as a missing reading — which holds and does not alert — rather than as a line
    /// invented from one side of the arithmetic.
    func testAPaceShareOnAWindowWithNoLengthCannotBePlaced() throws {
        let rule = CustomLimit.paceShare(windowID: weekly, share: 0.5)
        let lengthless = AccountUsage.Window(
            id: weekly,
            label: UsageDefaults.weeklyLabel,
            fraction: 0.4,
            resetsAt: now.addingTimeInterval(86_400),
            windowDuration: nil
        )

        let result = try XCTUnwrap(evaluate([rule], usage([lengthless])).first)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, .noReading)

        guard case .cannotSee = CustomLimitBounds.hold(
            on: usage([lengthless]),
            in: [rule],
            at: now
        ) else {
            return XCTFail("an unplaceable pace share did not hold")
        }
    }

    // MARK: - Synthetic Windows

    /// The arithmetic: what was spent inside the trailing span, in the provider's own unit.
    ///
    /// The span opens 300 minutes ago and the last sample at or before it is the 400-minute one,
    /// so the subtraction runs from `0.30` — **not** from the 200-minute sample inside the span.
    func testTrailingConsumptionIsTheFractionDeltaOverTheSpan() throws {
        let samples = [sample(400, 0.30), sample(200, 0.38), sample(10, 0.44)]

        let spent = try XCTUnwrap(CustomLimitTrailingWindow.consumption(
            in: samples,
            span: UsageDefaults.fiveHourSeconds,
            at: now
        ))
        XCTAssertEqual(spent, 0.14, accuracy: 0.0001, "0.44 − 0.30, from the last sample before the span")
    }

    /// The start is the last sample **at or before** the boundary rather than the first one inside
    /// it, and the direction is deliberate: history is sparse, so the true value at the boundary
    /// is unknown, and the two candidates bracket it. Starting earlier can only over-count, which
    /// holds sooner; starting later would under-count, which lets a burst through. A rule that
    /// exists to notice a burst errs toward noticing.
    func testTheSpanStartsFromTheLastSampleBeforeItRatherThanTheFirstInsideIt() throws {
        let samples = [sample(400, 0.30), sample(299, 0.40), sample(10, 0.44)]

        let spent = try XCTUnwrap(CustomLimitTrailingWindow.consumption(
            in: samples,
            span: UsageDefaults.fiveHourSeconds,
            at: now
        ))
        XCTAssertEqual(spent, 0.14, accuracy: 0.0001)
        XCTAssertGreaterThan(spent, 0.04, "starting inside the span would have under-counted")
    }

    /// A reset inside the span ends the subtraction at the reset evidence. Subtracting across the
    /// boundary would read a clear as *negative* consumption, which then reads as headroom — on
    /// the one metric whose whole purpose is to notice a burst.
    func testAResetInsideTheSpanEndsTheSubtraction() throws {
        let samples = [
            sample(280, 0.90, resetsIn: 60),
            sample(200, 0.02, resetsIn: 86_400),
            sample(10, 0.20, resetsIn: 86_400)
        ]

        let spent = try XCTUnwrap(CustomLimitTrailingWindow.consumption(
            in: samples,
            span: UsageDefaults.fiveHourSeconds,
            at: now
        ))
        XCTAssertEqual(spent, 0.18, accuracy: 0.0001, "0.20 − 0.02, measured from the reset")
    }

    /// History that does not reach back far enough cannot answer a five-hour question. Reading
    /// the oldest sample as the start would call the unobserved hours zero.
    func testHistoryShorterThanTheSpanCannotAnswer() {
        XCTAssertNil(CustomLimitTrailingWindow.consumption(
            in: [sample(60, 0.10), sample(10, 0.30)],
            span: UsageDefaults.fiveHourSeconds,
            at: now
        ))
        XCTAssertNil(CustomLimitTrailingWindow.consumption(
            in: [],
            span: UsageDefaults.fiveHourSeconds,
            at: now
        ))
    }

    /// And that "cannot answer" holds rather than alerting.
    func testASyntheticWindowWithoutEnoughHistoryHolds() throws {
        let rule = CustomLimit.syntheticWindow(
            windowID: weekly,
            budget: 0.15,
            span: UsageDefaults.fiveHourSeconds
        )
        let reading = usage([window(fraction: 0.6, elapsed: 0.5)])

        let result = try XCTUnwrap(evaluate([rule], reading).first)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertFalse(result.wantsNotification)

        guard case .cannotSee = CustomLimitBounds.hold(on: reading, in: [rule], at: now) else {
            return XCTFail("a synthetic window with no history did not hold")
        }
    }

    /// The whole point: a burst inside the span crosses the budget while the provider window it
    /// is funded from is nowhere near its own limit.
    func testABurstCrossesTheBudgetWhileTheWeeklyLooksComfortable() throws {
        let rule = CustomLimit.syntheticWindow(
            windowID: weekly,
            budget: 0.15,
            span: UsageDefaults.fiveHourSeconds
        )
        let history = [weekly: [sample(400, 0.10), sample(10, 0.42)]]
        let reading = usage([window(fraction: 0.42, elapsed: 0.2)])

        let result = try XCTUnwrap(evaluate([rule], reading, history: history).first)

        XCTAssertTrue(result.state.isAtBound, "a third of the week in five hours passed a 15% budget")
        XCTAssertEqual(
            UsageSeverity.from(fraction: 0.42),
            .normal,
            "the provider still reads this account as comfortable, which is the point"
        )
        XCTAssertTrue(CustomLimitBounds.hold(on: reading, in: [rule], history: history, at: now).isHolding)
    }

    /// A synthetic rule prints the **trailing spend**, not the provider window's position: a rule
    /// about "any five hours" that printed the weekly's 42% would be naming a figure it is not
    /// measuring.
    func testASyntheticRuleReportsWhatItMeasures() throws {
        let rule = CustomLimit.syntheticWindow(
            windowID: weekly,
            budget: 0.15,
            span: UsageDefaults.fiveHourSeconds
        )
        let result = try XCTUnwrap(evaluate(
            [rule],
            usage([window(fraction: 0.42, elapsed: 0.2)]),
            history: [weekly: [sample(400, 0.10), sample(10, 0.20)]]
        ).first)

        XCTAssertEqual(try XCTUnwrap(result.windowFraction), 0.10, accuracy: 0.0001)
        XCTAssertTrue(
            CustomLimitReceipt.status(for: result, windowName: "Weekly").contains("10%"),
            CustomLimitReceipt.status(for: result, windowName: "Weekly")
        )
    }

    /// A synthetic rule with no span is a question with no length. It decodes and is listed; it is
    /// not evaluated.
    func testASyntheticRuleWithNoSpanIsNotEvaluated() throws {
        let rule = CustomLimit(windowID: weekly, metric: .syntheticWindow, bound: 0.15)

        XCTAssertFalse(rule.isSupported)
        let result = try XCTUnwrap(
            evaluate([rule], usage([window(fraction: 0.9, elapsed: 0.5)])).first
        )
        XCTAssertEqual(result.state, .unsupported)
    }

    /// **Re-arm for a trailing window.** Its instance is the span rather than the provider
    /// window's turn, so a line crossed and then left behind can be crossed again once the spend
    /// has aged out — the draft's fourth open question, answered by construction rather than by a
    /// quiet-interval rule bolted on top.
    func testATrailingRuleReArmsAsConsumptionLeavesTheSpan() throws {
        let rule = CustomLimit.syntheticWindow(
            windowID: weekly,
            budget: 0.15,
            span: UsageDefaults.fiveHourSeconds
        )

        let crossing = try XCTUnwrap(evaluate(
            [rule],
            usage([window(fraction: 0.42, elapsed: 0.2)]),
            history: [weekly: [sample(400, 0.10), sample(10, 0.30)]]
        ).first)
        XCTAssertFalse(crossing.crossedThresholds.isEmpty)

        // An hour later the same rule is a different instance, because the span it names has
        // moved. Its fired record from the crossing above says nothing about it.
        let key = CustomLimitEvaluator.firedKey(ruleID: rule.id, instance: crossing.instance)
        let later = CustomLimitEvaluator.evaluate(CustomLimitEvaluator.Input(
            rules: [rule],
            usage: usage([window(fraction: 0.60, elapsed: 0.3)]),
            fired: [key: crossing.crossedThresholds],
            history: [weekly: [sample(-60, 0.42), sample(-110, 0.60)]],
            now: now.addingTimeInterval(3_600)
        )).first

        XCTAssertNotEqual(try XCTUnwrap(later).instance, crossing.instance)
    }

    // MARK: - How They Are Named

    /// Each metric is named after what it *is*, because "Keep Weekly under 50%" on a pace share
    /// would state a line that is only true at one instant of the week.
    func testEachMetricNamesItselfForWhatItMeasures() {
        XCTAssertEqual(
            CustomLimitReceipt.name(
                for: .paceShare(windowID: weekly, share: 0.5),
                windowName: "Weekly"
            ),
            "Leave 50% of Weekly for its owner"
        )
        XCTAssertEqual(
            CustomLimitReceipt.name(
                for: .syntheticWindow(
                    windowID: weekly,
                    budget: 0.15,
                    span: UsageDefaults.fiveHourSeconds
                ),
                windowName: "Weekly"
            ),
            "No more than 15% of Weekly in any 5h"
        )
        XCTAssertEqual(
            CustomLimitReceipt.name(
                for: .cap(windowID: weekly, at: 0.8),
                windowName: "Weekly"
            ),
            "Keep Weekly under 80%"
        )
    }

    /// A record written before synthetic windows existed decodes unchanged.
    func testRecordsWrittenBeforeTheSpanExistedStillDecode() throws {
        let legacy = Data("""
            {"id":"\(UUID().uuidString)","windowID":"7d","metric":"fixedCap","bound":0.5,\
            "tier":"notify","thresholds":[1],"showsInToolbar":false}
            """.utf8)
        let decoded = try JSONDecoder().decode(CustomLimit.self, from: legacy)

        XCTAssertEqual(decoded.bound, 0.5)
        XCTAssertNil(decoded.trailingSpan)
        XCTAssertTrue(decoded.isSupported)
    }
}
