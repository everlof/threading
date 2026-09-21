import XCTest
@testable import DeviceLogsPlugin

/// Focus is what an agent drives when it says "this is what matters" — so what it folds, what it
/// keeps, and what it costs are all worth pinning.
final class LogFocusTests: XCTestCase {

    private func rows(_ count: Int, errorEvery: Int = 50) -> [DeviceLogRow] {
        (0..<count).map { index -> DeviceLogRow in
            let isError = index % errorEvery == 0
            return DeviceLogRow(
                time: "16:21:01.000",
                level: isError ? "Error" : "Debug",
                process: "SpringBoard",
                subsystem: nil,
                message: isError ? "failed to open socket " + String(index) : "routine " + String(index),
                timestamp: nil
            )
        }
    }

    func testNothingIsFoldedUntilSomethingIsAskedFor() {
        let entries = LogFocusLayout.entries(rows: rows(100), focus: LogFocus())
        XCTAssertEqual(entries.count, 100)
        XCTAssertEqual(entries.filter { $0.hiddenCount > 0 }.count, 0)
    }

    /// The shape the feature exists for: the matches and their surroundings stay, the long runs
    /// between them become one line each that says how much is in there.
    func testTheUninterestingRunsBecomeOneLineEach() {
        let focus = LogFocus(pattern: "failed", context: 2)
        let entries = LogFocusLayout.entries(rows: rows(200), focus: focus)

        let gaps = entries.filter { $0.hiddenCount > 0 }
        XCTAssertEqual(gaps.count, 4, "one fold between each pair of matches, and one at the end")
        // 4 matches, each keeping itself and two either side.
        XCTAssertEqual(entries.count - gaps.count, 4 * 5 - 2, "the first match has nothing before it")
        XCTAssertEqual(gaps.reduce(0) { $0 + $1.hiddenCount } + (entries.count - gaps.count), 200,
                       "every row is either shown or inside a fold — none are lost")
    }

    /// Context is the reason a fold is not a filter: the lines that explain a failure are usually
    /// the ones just before it.
    func testAMatchKeepsItsNeighbours() {
        let entries = LogFocusLayout.entries(
            rows: rows(20, errorEvery: 10),
            focus: LogFocus(pattern: "failed", context: 2)
        )
        guard case .row(let first) = entries.first else { return XCTFail("expected a row first") }
        XCTAssertEqual(first, 0, "the match at 0")
        XCTAssertTrue(entries.contains(.row(8)), "two rows before the match at 10")
        XCTAssertTrue(entries.contains(.row(12)), "two rows after it")
        XCTAssertTrue(entries.contains(.gap(3..<8)), "the run between is folded")
    }

    func testAnOpenedFoldShowsItsRowsAndTheRestStayFolded() {
        let focus = LogFocus(pattern: "failed", context: 1)
        let closed = LogFocusLayout.entries(rows: rows(120), focus: focus)
        let gap = closed.compactMap { entry -> Range<Int>? in
            if case .gap(let range) = entry { return range }
            return nil
        }.first!

        let opened = LogFocusLayout.entries(rows: rows(120), focus: focus, expanded: [gap.lowerBound])
        XCTAssertFalse(opened.contains(.gap(gap)), "the opened fold is gone")
        XCTAssertTrue(opened.contains(.row(gap.lowerBound)), "and its rows are there instead")
        XCTAssertTrue(opened.contains { $0.hiddenCount > 0 }, "the other folds stay closed")
    }

    func testLevelAloneIsEnoughToFocus() {
        let entries = LogFocusLayout.entries(
            rows: rows(100),
            focus: LogFocus(minimumSeverity: 3, context: 0)
        )
        XCTAssertEqual(entries.filter { $0.hiddenCount == 0 }.count, 2, "the two errors")
    }

    /// The layout runs over the whole ring whenever the stream ticks, so its cost is the thing
    /// that decides whether focus can stay on while a device is talking.
    ///
    /// **Measured 8.9 ms in Release** for a full 50,000-row ring — 9% of one 100 ms drain, which is
    /// what the app actually runs. Debug is normally ~30–40 ms because none of this inlines; the
    /// bound below is set for Debug, where the suite runs, and is still tight enough to catch the
    /// regression that matters. Two other spellings of the same search were tried: `lowercased()` per field cost
    /// 57 ms and `range(of:options:.caseInsensitive)` cost 158 ms, so a return to either fails
    /// here rather than quietly making focus unusable while a device is talking.
    func testLayingOutAFullRingIsCheapEnoughToDoOnEveryTick() {
        let full = rows(DeviceLogLimits.ringCapacity)
        let focus = LogFocus(pattern: "failed", context: 2)
        var slowest = 0.0
        for _ in 0..<5 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = LogFocusLayout.entries(rows: full, focus: focus)
            slowest = max(slowest, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        print(String(format: "FOCUS layout of %d rows: %.1f ms worst of 5", full.count, slowest))
        XCTAssertLessThan(slowest, 120, "a drain happens ten times a second")
    }
}
