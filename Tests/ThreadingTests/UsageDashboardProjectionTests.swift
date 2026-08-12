import XCTest
import ThreadingRemoteKit
@testable import Threading

final class UsageDashboardProjectionTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testOverviewProjectionCapsBreakdownsWithoutLosingTheirTotals() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let today = calendar.startOfDay(for: now)
        let cells = (0..<(UsageDashboardProjectionDefaults.maximumBreakdownRows + 75)).map { index in
            makeCell(index: index, day: today)
        }
        let report = TranscriptUsageReport(cells: cells, builtAt: now)

        let projection = try XCTUnwrap(
            UsageDashboardProjector.overview(report: report, now: now, calendar: calendar)
        )
        let range = try XCTUnwrap(projection.range(days: 30))
        let models = range.breakdown(.models)

        XCTAssertEqual(projection.ranges.map(\.days), [7, 30, 90])
        XCTAssertEqual(models.rows.count, UsageDashboardProjectionDefaults.maximumBreakdownRows)
        XCTAssertEqual(models.omittedRowCount, 75)
        XCTAssertEqual(
            models.rows.reduce(0) { $0 + $1.tokens } + models.omittedTokens,
            range.tokens.processed
        )
        XCTAssertLessThanOrEqual(range.costMetric.chartSeries.count, 4)
        XCTAssertLessThanOrEqual(range.tokenMetric.chartSeries.count, 4)
        XCTAssertTrue(range.costMetric.chartSeries.allSatisfy { $0.points.count == 30 })
        XCTAssertEqual(
            range.costMetric.chartSeries.flatMap(\.points).reduce(0) { $0 + $1.value },
            range.cost.totalUSD,
            accuracy: 0.000_001
        )
    }

    func testLimitProjectionKeepsNilAndZeroBankedResetsDistinct() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let expiry = now.addingTimeInterval(2 * 86_400)
        let samples = [
            makeSample(series: 0, index: 0, now: now, credits: nil, expiry: nil),
            makeSample(series: 1, index: 0, now: now, credits: 0, expiry: nil),
            makeSample(series: 2, index: 0, now: now, credits: 3, expiry: expiry)
        ]

        let projection = UsageDashboardProjector.limits(
            from: .init(samples: samples, resets: [], loadedAt: now),
            now: now
        )
        let credits = Dictionary(uniqueKeysWithValues: projection.series.map {
            ($0.accountName, $0.resetCreditCount)
        })

        XCTAssertTrue(credits.keys.contains("Account 0"))
        XCTAssertNil(credits["Account 0"]!)
        XCTAssertEqual(credits["Account 1"]!, 0)
        XCTAssertEqual(credits["Account 2"]!, 3)
        XCTAssertEqual(
            projection.series.first { $0.accountName == "Account 2" }?.nextResetCreditExpiresAt,
            expiry
        )
    }

    /// Deterministic real-path fixture for the scaling contract. Set
    /// `THREADING_USAGE_STRESS=1` to exercise the documented 100k/250k/50k inputs.
    func testProjectionStressFixtureStaysWithinOutputAndTimeBudgets() throws {
        let isStress = ProcessInfo.processInfo.environment["THREADING_USAGE_STRESS"] == "1"
        let cellCount = isStress ? 100_000 : 10_000
        let sampleCount = isStress ? 250_000 : 25_000
        let resetCount = isStress ? 50_000 : 5_000
        let seriesCount = isStress ? 300 : 30
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let today = calendar.startOfDay(for: now)
        let cells = (0..<cellCount).map { index in
            makeCell(
                index: index,
                day: calendar.date(byAdding: .day, value: -(index % 90), to: today)!
            )
        }
        let report = TranscriptUsageReport(cells: cells, builtAt: now)
        let samples = (0..<sampleCount).map { index in
            makeSample(
                series: index % seriesCount,
                index: index,
                now: now,
                credits: (index % seriesCount) % 3,
                expiry: now.addingTimeInterval(2 * 86_400)
            )
        }
        let resets = (0..<resetCount).map { index in
            makeReset(series: index % seriesCount, index: index, now: now)
        }
        let snapshot = UsageLimitHistorySnapshot(samples: samples, resets: resets, loadedAt: now)

        var elapsed: [TimeInterval] = []
        for _ in 0..<3 {
            let started = CFAbsoluteTimeGetCurrent()
            let overview = try XCTUnwrap(
                UsageDashboardProjector.overview(report: report, now: now, calendar: calendar)
            )
            let limits = UsageDashboardProjector.limits(from: snapshot, now: now)
            let limitIndex = UsageDashboardProjector.limitIndex(from: snapshot, now: now)
            let remote = RemoteUsageBridge.dashboard(
                overview: overview,
                limitIndex: limitIndex,
                isBuilding: false,
                limitOffset: 0,
                limitCount: RemoteUsageBridge.maximumLimitPageSize
            )
            let remoteData = try JSONEncoder().encode(remote)
            elapsed.append(CFAbsoluteTimeGetCurrent() - started)

            XCTAssertEqual(overview.ranges.count, 3)
            XCTAssertLessThanOrEqual(
                limits.series.count,
                UsageDashboardProjectionDefaults.maximumLimitSeries
            )
            XCTAssertLessThanOrEqual(
                limitIndex.series.count,
                UsageDashboardProjectionDefaults.maximumLimitSeries
            )
            XCTAssertLessThanOrEqual(
                remote.limitSeries.count,
                RemoteUsageBridge.maximumLimitPageSize
            )
            XCTAssertLessThanOrEqual(
                remoteData.count,
                RemoteUsageBridge.maximumOverviewResponseBytes
            )
            XCTAssertTrue(remote.ranges.allSatisfy { range in
                range.breakdowns.allSatisfy {
                    $0.rows.count <= RemoteUsageBridge.maximumBreakdownRowsPerKind
                }
            })
            for series in limits.series {
                for range in series.ranges {
                    XCTAssertLessThanOrEqual(
                        range.observed.count,
                        UsageDashboardProjectionDefaults.maximumLimitSamplesPerRange
                    )
                    XCTAssertLessThanOrEqual(
                        range.resetMarkers.count,
                        UsageDashboardProjectionDefaults.maximumLimitMarkersPerRange
                    )
                }
            }
        }

        print("usage-projection \(isStress ? "stress" : "ordinary") runs=\(elapsed)")
        XCTAssertLessThan(
            elapsed.max() ?? .infinity,
            isStress ? 12 : 8,
            "Projection runs: \(elapsed)"
        )
    }

    private func makeCell(index: Int, day: Date) -> TranscriptUsageReport.Cell {
        let routes: [UsageOrigin] = [
            .direct(.claude),
            .direct(.codex),
            .direct(.grok),
            .direct(.openCode),
            .openCode(providerID: "openrouter")
        ]
        return .init(
            day: day,
            origin: routes[index % routes.count],
            accountID: "account-\(index % 80)",
            accountName: "Account \(index % 80)",
            model: "model-\(index)",
            checkoutPath: "/project/\(index % 700)",
            checkoutLabel: "Project \(index % 700)",
            tokens: .init(uncachedInput: 80, cachedInput: 20, output: 10),
            providerReportedCostUSD: 0.002,
            catalogCostUSD: 0,
            unpricedTokens: 0,
            cacheSavingsUSD: 0.001,
            records: 1
        )
    }

    private func makeSample(
        series: Int,
        index: Int,
        now: Date,
        credits: Int?,
        expiry: Date?
    ) -> UsageSample {
        UsageSample(
            at: now.addingTimeInterval(-TimeInterval(index % (90 * 24 * 60)) * 60),
            fraction: Double(index % 1_000) / 1_000,
            resetsAt: now.addingTimeInterval(7 * 86_400),
            runtimeID: AgentKind.codex.rawValue,
            accountID: "account-\(series)",
            accountName: "Account \(series)",
            windowID: "weekly",
            windowLabel: "Weekly",
            windowDuration: 7 * 86_400,
            source: .codexAPI,
            nextResetCreditExpiresAt: expiry,
            resetCreditCount: credits
        )
    }

    private func makeReset(series: Int, index: Int, now: Date) -> UsageLimitResetEvent {
        let detected = now.addingTimeInterval(-TimeInterval(index % (90 * 24 * 60)) * 60)
        return .init(
            id: "reset-\(index)",
            runtimeID: AgentKind.codex.rawValue,
            accountID: "account-\(series)",
            accountName: "Account \(series)",
            windowID: "weekly",
            windowLabel: "Weekly",
            previousObservedAt: detected.addingTimeInterval(-60),
            detectedAt: detected,
            oldScheduledResetAt: detected,
            newScheduledResetAt: detected.addingTimeInterval(7 * 86_400),
            restoredFraction: 0.8,
            elapsedFraction: 0.4,
            secondsEarly: 0,
            cause: index.isMultiple(of: 4) ? .bankedCredit : .scheduled
        )
    }
}
