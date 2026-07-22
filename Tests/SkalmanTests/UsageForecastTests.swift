import XCTest
@testable import Skalman

/// The projection that turns "43% left" into "you will run out at 19:40".
final class UsageForecastTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ minutes: Double, _ fraction: Double, resetsAt: Date? = nil) -> UsageSample {
        UsageSample(
            at: start.addingTimeInterval(minutes * 60),
            fraction: fraction,
            resetsAt: resetsAt
        )
    }

    // MARK: - Rate

    /// 10%/hour for six hours, so the remaining 40% takes four more — and the reset is twelve
    /// hours out, so the window is spent two hours before it refills.
    func testProjectsTheCrossingFromASteadyBurn() {
        let reset = start.addingTimeInterval(12 * 3600)
        let samples = (0...6).map { sample(Double($0) * 60, Double($0) * 0.10, resetsAt: reset) }

        guard case let .exhausting(at, early) = UsageForecast.project(
            samples: samples,
            resetsAt: reset
        ) else { return XCTFail("expected a crossing") }

        // 60% burned in 6 hours is 10%/hour; the remaining 40% takes 4 more.
        XCTAssertEqual(at.timeIntervalSince(start) / 3600, 10, accuracy: 0.01)
        XCTAssertEqual(early / 3600, 2, accuracy: 0.01)
    }

    /// The comfortable case reads differently: the window refills before it empties.
    func testSlowBurnIsWithinBudget() {
        let reset = start.addingTimeInterval(4 * 3600)
        let samples = (0...3).map { sample(Double($0) * 60, Double($0) * 0.02, resetsAt: reset) }

        guard case .withinBudget = UsageForecast.project(samples: samples, resetsAt: reset) else {
            return XCTFail("expected the window to outlast its burn")
        }
    }

    // MARK: - Refusals

    func testTwoReadingsMomentsApartClaimNothing() {
        let samples = [sample(0, 0.10), sample(1, 0.30)]
        XCTAssertEqual(UsageForecast.project(samples: samples, resetsAt: nil), .unknown)
    }

    func testASingleReadingClaimsNothing() {
        XCTAssertEqual(UsageForecast.project(samples: [sample(0, 0.5)], resetsAt: nil), .unknown)
    }

    /// A flat window is not "never" — it is a window nobody is spending, and the honest answer
    /// is that no rate is visible.
    func testFlatUsageProjectsNothing() {
        let samples = (0...5).map { sample(Double($0) * 30, 0.42) }
        XCTAssertEqual(UsageForecast.project(samples: samples, resetsAt: nil), .unknown)
    }

    // MARK: - Window Boundaries

    /// The trap this function exists around: a series that spans a reset falls from nearly full
    /// to nearly empty, and a rate fitted across that boundary is negative — which would report
    /// a fast-filling window as one that never fills.
    func testReadingsBeforeAResetAreDiscarded() {
        let samples = [
            sample(0, 0.80),
            sample(30, 0.90),
            sample(60, 0.98),
            // The window rolls over here.
            sample(90, 0.05),
            sample(150, 0.25),
            sample(210, 0.45)
        ]

        guard case let .exhausting(at, _) = UsageForecast.project(samples: samples, resetsAt: nil)
        else { return XCTFail("expected a crossing from the new window alone") }

        // 40% in two hours after the reset is 20%/hour; 55% remains, so 2h45m more.
        let hoursFromLast = at.timeIntervalSince(self.start.addingTimeInterval(210 * 60)) / 3600
        XCTAssertEqual(hoursFromLast, 2.75, accuracy: 0.05)
    }

    /// The other way a reset shows: the reported reset moment moves on, even where the
    /// fraction happens not to fall.
    func testAMovedResetStartsANewWindow() {
        let first = start.addingTimeInterval(3600)
        let second = start.addingTimeInterval(24 * 3600)

        let samples = [
            sample(0, 0.50, resetsAt: first),
            sample(30, 0.60, resetsAt: first),
            sample(70, 0.62, resetsAt: second),
            sample(130, 0.70, resetsAt: second)
        ]

        // Only the last two count: 8% in an hour, 30% left, so 3h45m past the last reading.
        guard case let .exhausting(at, _) = UsageForecast.project(samples: samples, resetsAt: second)
        else { return XCTFail("expected a crossing") }

        XCTAssertEqual(at.timeIntervalSince(start) / 3600, 2.167 + 3.75, accuracy: 0.05)
    }

    func testUnsortedSamplesAreHandled() {
        let reset = start.addingTimeInterval(10 * 3600)
        let ordered = (0...6).map { sample(Double($0) * 60, Double($0) * 0.10, resetsAt: reset) }

        XCTAssertEqual(
            UsageForecast.project(samples: ordered.reversed(), resetsAt: reset),
            UsageForecast.project(samples: ordered, resetsAt: reset)
        )
    }
}
