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
}
