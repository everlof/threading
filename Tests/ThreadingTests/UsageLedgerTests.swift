import XCTest
@testable import Threading
import ThreadingUsage

/// The app-side half of the ledger tests: aggregation through `UsageLedgerBuilder` and range
/// selection over `TranscriptUsageReport`. Normalization and pricing are tested in
/// `Packages/ThreadingUsage`.
final class UsageLedgerTests: XCTestCase {
    /// `UsageRuntime` is the package's neutral name for a runtime, and its identifier and name are
    /// persisted in every ledger row's `UsageOrigin`. They must stay equal to `AgentKind`'s.
    func testUsageRuntimeMatchesAgentKindIdentifiersAndNames() {
        XCTAssertEqual(
            UsageRuntime.allCases.map(\.rawValue),
            AgentKind.allCases.map(\.rawValue)
        )
        for kind in AgentKind.allCases {
            let runtime = UsageRuntime(rawValue: kind.rawValue)
            XCTAssertEqual(runtime?.displayName, kind.displayName)
        }
    }

    func testBuilderDeduplicatesAcrossSourceCachesBeforeAggregation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(UsageLedgerDate.parse("2026-08-08T12:00:00Z"))
        let duplicated = makeRecord(
            identity: "shared-response",
            at: now,
            tokens: .init(uncachedInput: 10, output: 5)
        )
        var scan = TranscriptUsageReport.ScanStatistics()
        scan.rawRecords = 2

        let report = UsageLedgerBuilder.build(
            records: [duplicated, duplicated],
            coverage: [],
            projects: [],
            scan: scan,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(report.scan.distinctRecords, 1)
        XCTAssertEqual(report.turns, 1)
        XCTAssertEqual(report.billedTokens, 15)
    }

    func testBuilderMergesStreamingPartialsByMaximumCounterInEitherOrder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(UsageLedgerDate.parse("2026-08-08T12:00:00Z"))
        let partial = makeRecord(
            identity: "streamed-response",
            at: now,
            tokens: .init(uncachedInput: 10, cachedInput: 20, cacheWrite: 30, output: 5)
        )
        let complete = makeRecord(
            identity: "streamed-response",
            at: now,
            tokens: .init(uncachedInput: 10, cachedInput: 20, cacheWrite: 30, output: 160)
        )

        for records in [[partial, complete], [complete, partial]] {
            var scan = TranscriptUsageReport.ScanStatistics()
            scan.rawRecords = records.count
            let report = UsageLedgerBuilder.build(
                records: records,
                coverage: [],
                projects: [],
                scan: scan,
                now: now,
                calendar: calendar
            )

            XCTAssertEqual(report.scan.distinctRecords, 1)
            XCTAssertEqual(report.turns, 1)
            XCTAssertEqual(report.billedTokens, 200)
            XCTAssertEqual(report.cachedTokens, 20)
            XCTAssertEqual(report.sessionCells?.first?.tokens.output, 160)
        }
    }

    func testRangeSelectionUsesLocalCalendarDayBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 2 * 60 * 60))
        let now = try XCTUnwrap(UsageLedgerDate.parse("2026-08-08T22:30:00Z"))
        let today = calendar.startOfDay(for: now)
        let old = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: today))
        let report = TranscriptUsageReport(cells: [
            makeCell(day: today, records: 2),
            makeCell(day: old, records: 9)
        ])

        XCTAssertEqual(report.selection(days: 7, now: now, calendar: calendar).records, 2)
        XCTAssertEqual(report.selection(days: 8, now: now, calendar: calendar).records, 11)
    }

    private func makeRecord(
        identity: String,
        at: Date? = Date(timeIntervalSince1970: 1_770_000_000),
        origin: UsageOrigin = .direct(.codex),
        model: String = "gpt-5.4",
        tokens: UsageTokenCounts,
        reportedCostUSD: Double? = nil
    ) -> UsageLedgerRecord {
        UsageLedgerRecord(
            identity: identity,
            sessionID: "session",
            at: at,
            origin: origin,
            accountID: "codex:default",
            accountName: "Codex",
            model: model,
            workingDirectory: "/tmp/project",
            tokens: tokens,
            reportedCostUSD: reportedCostUSD
        )
    }

    private func makeCell(day: Date, records: Int) -> TranscriptUsageReport.Cell {
        .init(
            day: day,
            origin: .direct(.codex),
            accountID: "codex:default",
            accountName: "Codex",
            model: "gpt-5.4",
            checkoutPath: "/tmp/project",
            checkoutLabel: "project",
            tokens: .init(uncachedInput: Int64(records)),
            providerReportedCostUSD: 0,
            catalogCostUSD: 0,
            unpricedTokens: 0,
            cacheSavingsUSD: 0,
            records: records
        )
    }
}
