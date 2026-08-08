import XCTest
@testable import Threading

/// Measuring how long this account takes to spend a window, from the readings already on disk.
///
/// The lead the poke fires at is derived from this number, so every way of getting it wrong has
/// a visible consequence: too high and the window opens too late to help, too low and it expires
/// before anyone arrives. The estimator is deliberately a rate *while moving* rather than a span
/// from window start, and these tests are about the difference.
final class UsageWindowBurnTests: XCTestCase {

    private let windowLength = UsageDefaults.fiveHourSeconds
    private let start = Date(timeIntervalSince1970: 1_785_000_000)

    /// Readings taken every `spacing`, each adding `growth` to the spent fraction.
    private func samples(
        count: Int,
        spacing: TimeInterval = 15 * 60,
        growth: Double,
        from origin: Date? = nil,
        fraction base: Double = 0,
        resetsAt: Date? = nil
    ) -> [UsageSample] {
        let origin = origin ?? start
        return (0..<count).map { index in
            UsageSample(
                at: origin.addingTimeInterval(spacing * Double(index)),
                fraction: base + growth * Double(index),
                resetsAt: resetsAt
            )
        }
    }

    // MARK: - The Rate

    /// Half a window spent over ninety minutes of steady work is three hours to a whole one.
    func testTheBurnIsTheRateWhileMovingInverted() throws {
        let estimate = try XCTUnwrap(
            UsageWindowBurn.estimate(
                from: samples(count: 7, growth: 0.5 / 6),
                windowLength: windowLength
            )
        )

        XCTAssertEqual(estimate.burn, 3 * 3600, accuracy: 60)
        XCTAssertEqual(estimate.observedFraction, 0.5, accuracy: 0.01)
        XCTAssertEqual(estimate.activeTime, 90 * 60, accuracy: 1)
    }

    /// An hour at lunch is not an hour of work. Counting it would stretch the burn towards the
    /// window's own length and make the lead too short, which is the failure that ends a morning
    /// capped at eleven — the exact thing the feature exists to prevent.
    func testIdleTimeIsNotCountedAsWork() throws {
        var series = samples(count: 4, growth: 0.5 / 6)
        let paused = try XCTUnwrap(series.last)

        // An hour later, nothing has been spent.
        series.append(UsageSample(
            at: paused.at.addingTimeInterval(3600),
            fraction: paused.fraction,
            resetsAt: nil
        ))
        // Then work resumes at the same rate as before.
        series += samples(
            count: 4,
            growth: 0.5 / 6,
            from: paused.at.addingTimeInterval(3600 + 15 * 60),
            fraction: paused.fraction + 0.5 / 6
        )

        let estimate = try XCTUnwrap(
            UsageWindowBurn.estimate(from: series, windowLength: windowLength)
        )

        XCTAssertEqual(estimate.burn, 3 * 3600, accuracy: 120)
    }

    /// Usage that appeared while Threading was not running says nothing about a rate: the app
    /// cannot tell four hours of work from four hours away from the desk with a phone. The pair
    /// spanning the gap is dropped rather than averaged.
    func testAGapTooLongToBeWorkIsIgnored() throws {
        var series = samples(count: 5, growth: 0.5 / 6)
        let last = try XCTUnwrap(series.last)

        series.append(UsageSample(
            at: last.at.addingTimeInterval(4 * 3600),
            fraction: last.fraction + 0.3,
            resetsAt: nil
        ))

        let estimate = try XCTUnwrap(
            UsageWindowBurn.estimate(from: series, windowLength: windowLength)
        )

        // The trailing jump contributed neither its time nor its growth, so the rate is still
        // the one measured over the hour that was watched.
        XCTAssertEqual(estimate.burn, 3 * 3600, accuracy: 120)
        XCTAssertEqual(estimate.activeTime, 60 * 60, accuracy: 1)
    }

    /// A window resetting is a boundary, not a rate. The fraction falls, or the reported reset
    /// moves on, and a pair straddling either describes no window at all.
    func testAPairCrossingAResetIsNotARate() throws {
        let firstReset = start.addingTimeInterval(windowLength)
        var series = samples(
            count: 5,
            growth: 0.5 / 6,
            resetsAt: firstReset
        )
        let last = try XCTUnwrap(series.last)

        // The next window: a later reset, and a fraction that starts over.
        series += samples(
            count: 5,
            growth: 0.5 / 6,
            from: last.at.addingTimeInterval(15 * 60),
            resetsAt: firstReset.addingTimeInterval(windowLength)
        )

        let estimate = try XCTUnwrap(
            UsageWindowBurn.estimate(from: series, windowLength: windowLength)
        )

        // Two windows watched at the same rate still measure that rate, rather than the
        // boundary between them dragging it anywhere.
        XCTAssertEqual(estimate.burn, 3 * 3600, accuracy: 120)
    }

    // MARK: - Refusing

    /// Nil is a real answer. Twenty minutes of history has no rate in it, and a confident wrong
    /// lead is worse than an assumed one that says it is assumed, because nobody re-checks a
    /// number that looks measured.
    func testTooLittleObservedSpendHasNoEstimate() {
        XCTAssertNil(
            UsageWindowBurn.estimate(
                from: samples(count: 3, spacing: 5 * 60, growth: 0.01),
                windowLength: windowLength
            )
        )
    }

    func testAnAccountThatSpentNothingHasNoEstimate() {
        XCTAssertNil(
            UsageWindowBurn.estimate(
                from: samples(count: 10, growth: 0),
                windowLength: windowLength
            )
        )
    }

    func testAnEmptyHistoryHasNoEstimate() {
        XCTAssertNil(UsageWindowBurn.estimate(from: [], windowLength: windowLength))
    }

    /// A near-zero rate would otherwise produce a burn of days. Past one window's length the
    /// planner refuses anyway, so the value is capped rather than allowed to become nonsense on
    /// the settings page.
    func testAVerySlowRateIsCappedRatherThanReportedAsDays() throws {
        let estimate = try XCTUnwrap(
            UsageWindowBurn.estimate(
                from: samples(count: 30, spacing: 20 * 60, growth: 0.02),
                windowLength: windowLength
            )
        )

        XCTAssertLessThanOrEqual(
            estimate.burn,
            windowLength * UsageWindowBurnDefaults.maximumBurnMultiple
        )
    }
}
