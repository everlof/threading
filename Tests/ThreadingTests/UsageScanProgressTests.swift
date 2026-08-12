import XCTest
@testable import Threading

/// The progress a usage scan reports while it reads transcripts.
///
/// Two contracts: a reader always gets told when the shape of the wait changes (the total is
/// known, the source being read changed), and a warm scan reading thousands of cached files a
/// second cannot flood the main actor with reports nobody could read.
final class UsageScanProgressTests: XCTestCase {

    /// A hand-wound clock, because a coalescing rule tested against the wall clock is a
    /// coalescing rule tested against how busy the machine is.
    private final class Clock {
        var now: CFTimeInterval = 0
        func read() -> CFTimeInterval { now }
    }

    private func reporter(
        interval: CFTimeInterval = 0.1,
        clock: Clock,
        into reports: Reports
    ) -> UsageScanProgressReporter {
        UsageScanProgressReporter(
            interval: interval,
            clock: clock.read,
            publish: { reports.values.append($0) }
        )
    }

    private final class Reports {
        var values: [UsageScanProgress] = []
    }

    // MARK: - Fraction

    func testTheFractionIsUnknownUntilTheSourcesAreCounted() {
        let counting = UsageScanProgress(sourceName: nil, completedSources: 0, totalSources: 0)
        XCTAssertNil(counting.fraction, "a bar pinned at zero would lie about a wait with no end")
        let known = UsageScanProgress(sourceName: "Claude Code", completedSources: 3, totalSources: 12)
        XCTAssertEqual(try XCTUnwrap(known.fraction), 0.25, accuracy: 0.0001)
    }

    func testTheFractionNeverLeavesItsBounds() throws {
        let overrun = UsageScanProgress(sourceName: nil, completedSources: 40, totalSources: 12)
        XCTAssertEqual(try XCTUnwrap(overrun.fraction), 1, accuracy: 0.0001)
    }

    // MARK: - Coalescing

    func testCountingTheSourcesIsAlwaysReported() {
        let clock = Clock()
        let reports = Reports()
        let reporter = reporter(clock: clock, into: reports)
        reporter.begin(totalSources: 400)

        XCTAssertEqual(reports.values.count, 1)
        XCTAssertEqual(reports.values.first?.totalSources, 400)
        XCTAssertEqual(reports.values.first?.completedSources, 0)
    }

    func testFilesReadInsideOneIntervalAreCollapsed() {
        let clock = Clock()
        let reports = Reports()
        let reporter = reporter(clock: clock, into: reports)
        reporter.begin(totalSources: 5_000)

        for _ in 0..<5_000 { reporter.advance(sourceName: "Claude Code") }

        // The first advance names a source nothing was reading yet, so it reports; the other
        // 4,999 land inside the same interval and do not.
        XCTAssertEqual(
            reports.values.count,
            2,
            "a warm scan must not post a main-actor hop per cached transcript"
        )
        XCTAssertEqual(reports.values.last?.completedSources, 1)
    }

    func testTimePassingLetsTheNextTickThrough() {
        let clock = Clock()
        let reports = Reports()
        let reporter = reporter(clock: clock, into: reports)
        reporter.begin(totalSources: 300)

        reporter.advance(sourceName: "Claude Code")
        reporter.advance(sourceName: "Claude Code")
        XCTAssertEqual(reports.values.count, 2)

        clock.now += 0.2
        reporter.advance(sourceName: "Claude Code")
        XCTAssertEqual(reports.values.count, 3)
        XCTAssertEqual(reports.values.last?.completedSources, 3)
        XCTAssertEqual(reports.values.last?.sourceName, "Claude Code")
    }

    func testANewSourceIsReportedWithoutWaitingForTheClock() {
        let clock = Clock()
        let reports = Reports()
        let reporter = reporter(clock: clock, into: reports)
        reporter.begin(totalSources: 300)
        reporter.advance(sourceName: "Claude Code")
        let beforeSwitch = reports.values.count

        // Without this rule "Claude Code" would sit on screen through the whole Codex half of a
        // scan that never paused long enough to tick.
        reporter.advance(sourceName: "Codex")
        XCTAssertEqual(reports.values.count, beforeSwitch + 1)
        XCTAssertEqual(reports.values.last?.sourceName, "Codex")
    }

    func testEveryReportCarriesTheTotalItWasGiven() {
        let clock = Clock()
        let reports = Reports()
        let reporter = reporter(clock: clock, into: reports)
        reporter.begin(totalSources: 42)
        clock.now += 1
        reporter.advance(sourceName: "Codex")

        XCTAssertEqual(Set(reports.values.map(\.totalSources)), [42])
    }
}
