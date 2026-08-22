import XCTest
import ThreadingRemoteKit
@testable import ThreadingMobile

final class RemoteUsageDashboardTests: XCTestCase {
    func testDemoCoversAllRangesAndBankedResetStatesWithinWireBudgets() throws {
        let dashboard = RemoteUsageDemo.dashboard()

        XCTAssertEqual(dashboard.ranges.map(\.days), [7, 30, 90])
        XCTAssertTrue(dashboard.ranges.allSatisfy { range in
            range.costMetric.chartSeries.count <= 4
                && range.tokenMetric.chartSeries.count <= 4
                && range.costMetric.chartSeries.allSatisfy {
                    $0.points.count == range.days
                }
        })
        XCTAssertTrue(dashboard.limitSeries.contains { $0.bankedResetCount == nil })
        XCTAssertTrue(dashboard.limitSeries.contains { $0.bankedResetCount == 0 })
        XCTAssertTrue(dashboard.limitSeries.contains { ($0.bankedResetCount ?? 0) > 0 })
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(dashboard).count, 384 * 1_024)

        for summary in dashboard.limitSeries {
            let detail = try RemoteUsageDemo.limit(seriesID: summary.id, days: 90)
            XCTAssertLessThanOrEqual(detail.observed.count, 280)
            XCTAssertLessThanOrEqual(detail.resets.count, 118)
            XCTAssertEqual(detail.series.bankedResetCount, summary.bankedResetCount)
            XCTAssertEqual(detail.observed.last?.at, detail.projection?.observedAt)
            XCTAssertEqual(detail.observed.last?.fraction, detail.projection?.observedFraction)
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(detail).count, 192 * 1_024)

            for (previous, current) in zip(detail.observed, detail.observed.dropFirst())
                where previous.segment != current.segment {
                XCTAssertGreaterThan(previous.fraction, current.fraction)
                XCTAssertTrue(detail.resets.contains {
                    $0.detectedAt >= previous.at && $0.detectedAt <= current.at
                })
            }
        }
    }

    func testLimitDemoRejectsUnknownSeriesWithoutBroadeningSelection() {
        XCTAssertThrowsError(try RemoteUsageDemo.limit(seriesID: "unknown", days: 30))
    }

    func testLimitChartDomainExcludesLaterBankedResetExpiry() throws {
        let summary = try XCTUnwrap(
            RemoteUsageDemo.dashboard().limitSeries.first { ($0.bankedResetCount ?? 0) > 0 }
        )
        let detail = try RemoteUsageDemo.limit(seriesID: summary.id, days: 7)
        let domain = MobileUsageLimitChartDomain.range(for: detail)
        let expiry = try XCTUnwrap(detail.series.nextBankedResetExpiresAt)
        let projectionEnd = detail.projection.map {
            $0.projectedExhaustionAt ?? $0.resetsAt
        }
        let expectedEnd = [detail.end, projectionEnd, detail.series.resetsAt]
            .compactMap { $0 }
            .max()

        XCTAssertEqual(domain.lowerBound.timeIntervalSince1970, detail.start, accuracy: 0.001)
        XCTAssertEqual(
            domain.upperBound.timeIntervalSince1970,
            try XCTUnwrap(expectedEnd),
            accuracy: 0.001
        )
        XCTAssertLessThan(
            domain.upperBound.timeIntervalSince1970,
            expiry,
            "a later banked-reset expiry compressed the selected history into the chart's edge"
        )
    }

    func testFleetProjectionGroupsProviderWindowsByAccount() {
        let accounts = MobileUsageFleetProjection.accounts(from: [
            series("weekly", runtime: "Claude", account: "Work", window: "Weekly"),
            series("five-hour", runtime: "Claude", account: "Work", window: "5-hour"),
            series("codex", runtime: "Codex", account: "Personal", window: "Weekly")
        ])

        XCTAssertEqual(accounts.map(\.id), ["Claude|Work", "Codex|Personal"])
        XCTAssertEqual(accounts[0].windows.map(\.id), ["five-hour", "weekly"])
    }

    func testFleetSummaryNamesAccountStatesAndUsesRealActiveResetTimes() {
        let reference = 1_800_000_000.0
        let accounts = MobileUsageFleetProjection.accounts(from: [
            series("ready", account: "Ready", fraction: 0.20, resetsAt: reference + 7_200),
            series("constrained", account: "Busy", fraction: 0.75, resetsAt: reference + 3_600),
            series("unknown", account: "Unknown", fraction: nil, resetsAt: reference + 1_800),
            series("expired", account: "Expired", fraction: 0.99, resetsAt: reference - 60)
        ])

        let summary = MobileUsageFleetProjection.summary(
            for: accounts,
            referenceTime: reference
        )

        XCTAssertEqual(summary.accountCount, 4)
        XCTAssertEqual(summary.readyCount, 1)
        XCTAssertEqual(summary.constrainedCount, 1)
        XCTAssertEqual(summary.unknownCount, 2)
        XCTAssertEqual(summary.nextReset, reference + 1_800)
    }

    private func series(
        _ id: String,
        runtime: String = "Claude",
        account: String = "Default",
        window: String = "5-hour",
        fraction: Double? = 0.20,
        resetsAt: Double = 1_800_003_600
    ) -> RemoteUsageLimitSeriesSummaryDTO {
        RemoteUsageLimitSeriesSummaryDTO(
            id: id,
            runtimeName: runtime,
            accountName: account,
            windowLabel: window,
            currentFraction: fraction,
            resetsAt: resetsAt,
            bankedResetCount: nil,
            nextBankedResetExpiresAt: nil
        )
    }
}
