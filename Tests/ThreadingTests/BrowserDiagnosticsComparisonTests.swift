import XCTest

@testable import Threading

/// The non-pixel diffs: timings against a noise floor, and console, network and accessibility
/// findings matched on fingerprints rather than on anything document-local.
final class BrowserDiagnosticsComparisonTests: XCTestCase {

    // MARK: - Fingerprints

    /// The reason fingerprints exist: a line carrying a timestamp, a request id or a retry counter
    /// is otherwise new on every capture, which turns "you introduced a warning" into noise.
    func testDigitsAreMaskedSoAnIdDoesNotMakeEveryLineNew() {
        let first = BrowserDiagnosticsFingerprint.of("Request 4821 failed after 3 retries")
        let second = BrowserDiagnosticsFingerprint.of("Request 9137 failed after 5 retries")
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(
            first,
            BrowserDiagnosticsFingerprint.of("Request 4821 succeeded after 3 retries"),
            "Masking digits must not also erase the words"
        )
    }

    func testAURLCollapsesItsIdentifierSegmentsAndDropsTheQuery() {
        let first = BrowserDiagnosticsFingerprint.ofURL("https://example.com/users/8213/avatar?t=1")
        let second = BrowserDiagnosticsFingerprint.ofURL("https://example.com/users/4/avatar?t=99")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "https://example.com/users/*/avatar")
        XCTAssertNotEqual(
            first,
            BrowserDiagnosticsFingerprint.ofURL("https://example.com/users/8213/settings")
        )
    }

    // MARK: - Timings

    /// A three-millisecond move is measurement noise. Presenting it as a regression is how a report
    /// teaches everybody to ignore it.
    func testASmallTimingMoveIsNotCalledAChange() throws {
        let comparison = BrowserDiagnosticsComparator.compare(
            baseline: Self.snapshot(lcp: 1200),
            actual: Self.snapshot(lcp: 1203)
        )
        let lcp = try XCTUnwrap(comparison.timings.first { $0.name == "LCP" })
        XCTAssertFalse(lcp.exceedsNoiseFloor)
        XCTAssertFalse(comparison.hasChanges)
    }

    func testALargeTimingMoveIsReportedWithItsSignedDelta() throws {
        let comparison = BrowserDiagnosticsComparator.compare(
            baseline: Self.snapshot(lcp: 1200),
            actual: Self.snapshot(lcp: 2400)
        )
        let lcp = try XCTUnwrap(comparison.timings.first { $0.name == "LCP" })
        XCTAssertTrue(lcp.exceedsNoiseFloor)
        XCTAssertEqual(try XCTUnwrap(lcp.delta), 1200, accuracy: 0.001)
        XCTAssertTrue(comparison.hasChanges)
    }

    func testLayoutShiftHasItsOwnFloorBecauseItIsNotMilliseconds() throws {
        let quiet = BrowserDiagnosticsComparator.compare(
            baseline: Self.snapshot(cls: 0.010),
            actual: Self.snapshot(cls: 0.014)
        )
        XCTAssertFalse(
            try XCTUnwrap(quiet.timings.first { $0.name == "Layout shift" }).exceedsNoiseFloor
        )
        let loud = BrowserDiagnosticsComparator.compare(
            baseline: Self.snapshot(cls: 0.01),
            actual: Self.snapshot(cls: 0.25)
        )
        XCTAssertTrue(
            try XCTUnwrap(loud.timings.first { $0.name == "Layout shift" }).exceedsNoiseFloor
        )
    }

    // MARK: - Membership

    func testANewConsoleLineIsReportedAndAnUnchangedOneIsNot() {
        let before = Self.snapshot(console: [("warning", "Deprecated API")])
        let after = Self.snapshot(console: [
            ("warning", "Deprecated API"),
            ("error", "Cannot read property of undefined")
        ])
        let comparison = BrowserDiagnosticsComparator.compare(baseline: before, actual: after)
        XCTAssertEqual(comparison.consoleAdded.count, 1)
        XCTAssertEqual(comparison.consoleAdded.first?.level, "error")
        XCTAssertTrue(comparison.consoleRemoved.isEmpty)
    }

    /// The same line appearing more often is not a new line. Membership is the claim that survives
    /// a short capture window; a count is not.
    func testTheSameLineHappeningMoreOftenIsNotANewLine() {
        var before = Self.snapshot(console: [("warning", "Slow frame")])
        var after = Self.snapshot(console: [("warning", "Slow frame")])
        before = Self.withConsoleCount(before, 1)
        after = Self.withConsoleCount(after, 47)
        let comparison = BrowserDiagnosticsComparator.compare(baseline: before, actual: after)
        XCTAssertTrue(comparison.consoleAdded.isEmpty)
        XCTAssertTrue(comparison.consoleRemoved.isEmpty)
    }

    func testAccessibilityFindingsMatchWithoutRefs() {
        let before = Self.snapshot(findings: [("serious", "button-name", "button")])
        let after = Self.snapshot(findings: [
            ("serious", "button-name", "button"),
            ("serious", "image-alt", "img")
        ])
        let comparison = BrowserDiagnosticsComparator.compare(baseline: before, actual: after)
        XCTAssertEqual(comparison.accessibilityAdded.map(\.code), ["image-alt"])
        XCTAssertTrue(comparison.accessibilityRemoved.isEmpty)
    }

    // MARK: - Windows

    /// Counts collected over a five-second window and a five-minute one are not comparable, and the
    /// report says so instead of normalising into a rate the page never reported.
    func testMismatchedWindowsAreStatedRatherThanNormalised() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let short = Self.snapshot(window: (start, start.addingTimeInterval(5)))
        let long = Self.snapshot(window: (start, start.addingTimeInterval(600)))
        let comparison = BrowserDiagnosticsComparator.compare(baseline: short, actual: long)
        let mismatch = try XCTUnwrap(comparison.windowMismatch)
        XCTAssertTrue(mismatch.contains("5"))
        XCTAssertTrue(mismatch.contains("600"))

        let even = BrowserDiagnosticsComparator.compare(baseline: short, actual: short)
        XCTAssertNil(even.windowMismatch)
    }

    // MARK: - Fixtures

    private static func snapshot(
        lcp: Double? = 1000,
        cls: Double? = 0,
        console: [(String, String)] = [],
        findings: [(String, String, String)] = [],
        window: (Date, Date)? = nil
    ) -> BrowserDiagnosticsSnapshot {
        BrowserDiagnosticsSnapshot(
            schemaVersion: BrowserDiagnosticsDefaults.schemaVersion,
            capturedAt: Date(timeIntervalSince1970: 0),
            windowStart: window?.0,
            windowEnd: window?.1,
            performance: BrowserDiagnosticsSnapshot.Performance(
                timeToFirstByte: 100,
                domContentLoaded: 400,
                loadComplete: 900,
                firstContentfulPaint: 500,
                largestContentfulPaint: lcp,
                cumulativeLayoutShift: cls,
                longTaskCount: 0,
                longTaskDuration: 0,
                resourceCount: 3,
                resourceTransferSize: 1000
            ),
            console: console.map {
                BrowserDiagnosticsSnapshot.ConsoleEntry(level: $0.0, fingerprint: $0.1, count: 1)
            },
            network: [],
            accessibility: findings.map {
                BrowserDiagnosticsSnapshot.AccessibilityFinding(
                    severity: $0.0, code: $0.1, element: $0.2
                )
            },
            truncated: false
        )
    }

    private static func withConsoleCount(
        _ snapshot: BrowserDiagnosticsSnapshot,
        _ count: Int
    ) -> BrowserDiagnosticsSnapshot {
        BrowserDiagnosticsSnapshot(
            schemaVersion: snapshot.schemaVersion,
            capturedAt: snapshot.capturedAt,
            windowStart: snapshot.windowStart,
            windowEnd: snapshot.windowEnd,
            performance: snapshot.performance,
            console: snapshot.console.map {
                BrowserDiagnosticsSnapshot.ConsoleEntry(
                    level: $0.level, fingerprint: $0.fingerprint, count: count
                )
            },
            network: snapshot.network,
            accessibility: snapshot.accessibility,
            truncated: snapshot.truncated
        )
    }
}
