import XCTest
import SwiftUI
import UIKit
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
        XCTAssertTrue(dashboard.limitSeries.allSatisfy { ($0.windowDuration ?? 0) > 0 })
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(dashboard).count, 384 * 1_024)

        for summary in dashboard.limitSeries {
            let detail = try RemoteUsageDemo.limit(seriesID: summary.id, days: 90)
            XCTAssertLessThanOrEqual(detail.observed.count, 280)
            XCTAssertLessThanOrEqual(detail.resets.count, 118)
            XCTAssertEqual(detail.series.bankedResetCount, summary.bankedResetCount)
            if let projection = detail.projection {
                XCTAssertEqual(detail.observed.last?.at, projection.observedAt)
                XCTAssertEqual(detail.observed.last?.fraction, projection.observedFraction)
            }
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

    /// A weekly window is a line at every range. A five-hour window is a line at none of them,
    /// and its column bucket grows with the range: the window itself over a week, whole days
    /// over a month, three-day spans over a quarter. Without a stated window length the
    /// observed discontinuities decide.
    func testLimitChartFormFollowsWindowDensity() {
        let day = 86_400.0
        let hour = 3_600.0
        XCTAssertEqual(
            MobileUsageLimitChartProjection.form(for: limitDetail(windowDuration: 7 * day, days: 7)),
            .line
        )
        XCTAssertEqual(
            MobileUsageLimitChartProjection.form(for: limitDetail(windowDuration: 7 * day, days: 90)),
            .line
        )
        XCTAssertEqual(
            MobileUsageLimitChartProjection.form(for: limitDetail(windowDuration: 5 * hour, days: 7)),
            .peaks(bucket: 5 * hour)
        )
        XCTAssertEqual(
            MobileUsageLimitChartProjection.form(for: limitDetail(windowDuration: 5 * hour, days: 30)),
            .peaks(bucket: day)
        )
        XCTAssertEqual(
            MobileUsageLimitChartProjection.form(for: limitDetail(windowDuration: 5 * hour, days: 90)),
            .peaks(bucket: 3 * day)
        )
        XCTAssertEqual(
            MobileUsageLimitChartProjection.form(
                for: limitDetail(windowDuration: nil, days: 30, segments: 40)
            ),
            .peaks(bucket: day)
        )
        XCTAssertEqual(
            MobileUsageLimitChartProjection.form(
                for: limitDetail(windowDuration: nil, days: 30, segments: 3)
            ),
            .line
        )
    }

    /// A column is the highest reading inside its bucket, a day-sized bucket starts on the
    /// calendar day rather than at the range's own hour, a reading at the ceiling names the
    /// limit, and a point outside the range is not a column.
    func testPeakColumnsKeepTheHighestReadingPerBucketAndNameTheLimit() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = 86_400.0
        let start = 1_800_000_000.0
        let startOfDay = calendar.startOfDay(for: Date(timeIntervalSince1970: start)).timeIntervalSince1970
        XCTAssertLessThan(startOfDay, start, "the fixture must begin inside a day, not on its edge")
        let end = start + 3 * day
        let detail = RemoteUsageLimitDTO(
            series: series("dense", windowDuration: 5 * 3_600),
            days: 3,
            start: start,
            end: end,
            observed: [
                .init(at: start, fraction: 0.2, segment: 0),
                .init(at: start + 3_600, fraction: 0.9, segment: 0),
                .init(at: start + 4 * 3_600, fraction: 0.05, segment: 1),
                .init(at: start + day, fraction: 1, segment: 2),
                .init(at: start + 2 * day + 3_600, fraction: 0.4, segment: 3),
                .init(at: end + 10, fraction: 0.99, segment: 4),
            ],
            resets: [],
            recordedResetCount: 4,
            restoredPaceFraction: 0,
            projection: nil,
            preparedAt: end
        )

        let daily = MobileUsageLimitChartProjection.peaks(for: detail, bucket: day, calendar: calendar)
        XCTAssertEqual(daily.map(\.start), [startOfDay, startOfDay + day, startOfDay + 2 * day])
        XCTAssertEqual(daily.map(\.fraction), [0.9, 1, 0.4])
        XCTAssertEqual(daily.map(\.observations), [3, 1, 1])
        XCTAssertEqual(daily.map(\.reachedLimit), [false, true, false])

        let perWindow = MobileUsageLimitChartProjection.peaks(
            for: detail,
            bucket: 5 * 3_600,
            calendar: calendar
        )
        XCTAssertEqual(perWindow.first?.start, start, "a window-sized bucket starts with the range")
        XCTAssertEqual(perWindow.first?.fraction, 0.9)
    }

    /// Ticks fall on whole days at an even step, near the asked-for count, and never so close
    /// to either end of the domain that the label centred on them would be cut at the plot's
    /// edge — the weekly tick two days before a projected reset is the one that read "18…".
    func testAxisTicksKeepClearOfTheDomainEdges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        calendar.firstWeekday = 2
        let day = 86_400.0
        // A Monday at noon, thirty days of history, and a projected reset two days past a Monday.
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 2, day: 18, hour: 12)))
        let start = monday.addingTimeInterval(-2 * day)
        let end = monday.addingTimeInterval(30 * day)
        let ticks = MobileUsageAxisTicks.dates(in: start...end, desiredCount: 4, calendar: calendar)

        // Five Mondays fall inside the span; the first is two days after the start and the last
        // two days before the end, and both are dropped for the same reason.
        XCTAssertEqual(ticks.count, 3)
        XCTAssertEqual(ticks.first, calendar.date(from: DateComponents(year: 2030, month: 2, day: 25)))
        XCTAssertTrue(ticks.allSatisfy { calendar.component(.weekday, from: $0) == 2 })
        XCTAssertTrue(ticks.allSatisfy { calendar.startOfDay(for: $0) == $0 })
        let clearance = end.timeIntervalSince(start) * MobileUsageAxisTicks.edgeClearance
        XCTAssertTrue(ticks.allSatisfy {
            $0.timeIntervalSince(start) >= clearance && end.timeIntervalSince($0) >= clearance
        })
        XCTAssertLessThan(
            try XCTUnwrap(ticks.last),
            end.addingTimeInterval(-2 * day),
            "the Monday two days before the end is the one that used to be cut"
        )

        let week = MobileUsageAxisTicks.dates(in: start...start.addingTimeInterval(7 * day), desiredCount: 4, calendar: calendar)
        XCTAssertTrue((2...4).contains(week.count), "\(week.count) ticks over a week")
        let quarter = MobileUsageAxisTicks.dates(in: start...start.addingTimeInterval(90 * day), desiredCount: 4, calendar: calendar)
        XCTAssertTrue((2...4).contains(quarter.count), "\(quarter.count) ticks over a quarter")
        XCTAssertTrue(quarter.allSatisfy { calendar.component(.day, from: $0) == 1 })
        XCTAssertEqual(MobileUsageAxisTicks.dates(in: start...start, desiredCount: 4, calendar: calendar), [])
    }

    /// The daily chart's bands stand on one another only when every series shares one
    /// timestamp sequence; otherwise each stands on zero, because summing unaligned points
    /// draws a total nobody measured.
    func testDailyBandsStandOnOneAnotherOnlyWhenAligned() {
        let timestamps = [1.0, 2.0, 3.0]
        func chartSeries(_ id: String, _ values: [Double], at: [Double] = timestamps) -> RemoteUsageChartSeriesDTO {
            RemoteUsageChartSeriesDTO(
                id: id,
                title: id,
                isOther: false,
                styleIndex: 0,
                points: zip(at, values).map { RemoteUsageChartPointDTO(at: $0, value: $1) }
            )
        }

        let stacked = MobileUsageStackProjection.bands(for: [
            chartSeries("a", [1, 2, 3]),
            chartSeries("b", [4, 0, 1]),
        ])
        XCTAssertEqual(stacked.map(\.id), ["a", "b"])
        XCTAssertEqual(stacked[0].edges.map(\.lower), [0, 0, 0])
        XCTAssertEqual(stacked[0].edges.map(\.upper), [1, 2, 3])
        XCTAssertEqual(stacked[1].edges.map(\.lower), [1, 2, 3])
        XCTAssertEqual(stacked[1].edges.map(\.upper), [5, 2, 4])

        let independent = MobileUsageStackProjection.bands(for: [
            chartSeries("a", [1, 2, 3]),
            chartSeries("c", [7], at: [2]),
        ])
        XCTAssertEqual(independent[1].edges.map(\.lower), [0])
        XCTAssertEqual(independent[1].edges.map(\.upper), [7])
    }

    /// The demo's five-hour window is dense at every range, stays inside the wire's budgets,
    /// carries no weekly projection, and reaches the limit somewhere so the evidence capture
    /// shows a column in the negative role.
    func testDenseDemoWindowDrawsPeakColumnsWithinWireBudgets() throws {
        let summary = try XCTUnwrap(
            RemoteUsageDemo.dashboard().limitSeries.first { ($0.windowDuration ?? .infinity) < 86_400 }
        )
        for days in [7, 30, 90] {
            let detail = try RemoteUsageDemo.limit(seriesID: summary.id, days: days)
            XCTAssertLessThanOrEqual(detail.observed.count, 280)
            XCTAssertLessThanOrEqual(detail.resets.count, 118)
            XCTAssertNil(detail.projection)
            XCTAssertEqual(detail.recordedResetCount, detail.resets.count)
            guard case .peaks(let bucket) = MobileUsageLimitChartProjection.form(for: detail) else {
                XCTFail("the five-hour window over \(days) days should be drawn as columns")
                continue
            }
            let peaks = MobileUsageLimitChartProjection.peaks(for: detail, bucket: bucket)
            XCTAssertLessThanOrEqual(peaks.count, MobileUsageLimitChartProjection.maximumBuckets + 1)
            XCTAssertGreaterThan(peaks.count, 1)
            XCTAssertTrue(peaks.contains(where: \.reachedLimit))
        }
    }

    private func limitDetail(
        windowDuration: Double?,
        days: Int,
        segments: Int = 1
    ) -> RemoteUsageLimitDTO {
        let now = 1_800_000_000.0
        let start = now - Double(days) * 86_400
        let count = max(2, segments)
        return RemoteUsageLimitDTO(
            series: series("window", resetsAt: now + 3_600, windowDuration: windowDuration),
            days: days,
            start: start,
            end: now,
            observed: (0..<count).map { index in
                RemoteUsageLimitPointDTO(
                    at: start + Double(index) * 3_600,
                    fraction: 0.3,
                    segment: min(index, segments - 1)
                )
            },
            resets: [],
            recordedResetCount: 0,
            restoredPaceFraction: 0,
            projection: nil,
            preparedAt: now
        )
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

    /// Opened from a chat, the rail starts on that chat's login: matched by runtime and account
    /// first, by account name alone when the runtime's display name differs between the
    /// catalogue and the usage index, and on the first login when nothing matches.
    func testRailStartsOnTheFocusedLoginByRuntimeThenByNameThenFirst() {
        let accounts = MobileUsageFleetProjection.accounts(from: [
            series("claude-work", runtime: "Claude Code", account: "Work", window: "Weekly"),
            series("codex-home", runtime: "Codex", account: "Home", window: "Weekly"),
            series("codex-work", runtime: "Codex", account: "Work", window: "Weekly"),
        ])
        XCTAssertEqual(accounts.count, 3)
        let second = accounts[1]

        let exact = MobileUsageFleetProjection.startingAccountID(
            in: accounts,
            focus: MobileUsageAccountFocus(
                runtimeName: second.runtimeName,
                accountName: second.accountName
            )
        )
        XCTAssertEqual(exact, second.id)

        let byName = MobileUsageFleetProjection.startingAccountID(
            in: accounts,
            focus: MobileUsageAccountFocus(runtimeName: "Some Other Runtime", accountName: second.accountName)
        )
        XCTAssertEqual(byName?.split(separator: "|").last.map(String.init), second.accountName)

        let unknown = MobileUsageFleetProjection.startingAccountID(
            in: accounts,
            focus: MobileUsageAccountFocus(runtimeName: "Nobody", accountName: "Nobody")
        )
        XCTAssertEqual(unknown, accounts.first?.id)
        XCTAssertEqual(
            MobileUsageFleetProjection.startingAccountID(in: accounts, focus: nil),
            accounts.first?.id
        )
    }

    func testHiddenOrIdenticalLabelsDoNotMergeDistinctAccounts() {
        let accounts = MobileUsageFleetProjection.accounts(from: [
            series("first", account: "", accountID: "claude:first"),
            series("second", account: "", accountID: "claude:second")
        ])
        XCTAssertEqual(Set(accounts.map(\.id)), ["claude:first", "claude:second"])
        XCTAssertEqual(MobileUsageFleetProjection.startingAccountID(in: accounts,
            focus: .init(runtimeName: "Claude", accountName: "", accountID: "claude:second")),
            "claude:second")
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

    func testCapacityTimeMarkMeasuresLinearlyElapsedWindowTime() throws {
        let reference = 1_800_000_000.0
        let weekly = series(
            "weekly",
            resetsAt: reference + 3 * 86_400,
            windowDuration: 7 * 86_400
        )

        XCTAssertEqual(
            try XCTUnwrap(MobileUsageCapacityProjection.elapsedFraction(
                for: weekly,
                at: reference
            )),
            4.0 / 7.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MobileUsageCapacityProjection.elapsedFraction(
                for: weekly,
                at: reference - 5 * 86_400
            ),
            0
        )
        XCTAssertEqual(
            MobileUsageCapacityProjection.elapsedFraction(
                for: weekly,
                at: reference + 4 * 86_400
            ),
            1
        )
        XCTAssertNil(MobileUsageCapacityProjection.elapsedFraction(
            for: series("unknown-duration", resetsAt: reference + 3_600),
            at: reference
        ))
    }

    private func series(
        _ id: String,
        runtime: String = "Claude",
        account: String = "Default",
        window: String = "5-hour",
        fraction: Double? = 0.20,
        resetsAt: Double = 1_800_003_600,
        windowDuration: Double? = nil,
        accountID: String? = nil
    ) -> RemoteUsageLimitSeriesSummaryDTO {
        RemoteUsageLimitSeriesSummaryDTO(
            id: id,
            accountID: accountID,
            runtimeName: runtime,
            accountName: account,
            windowLabel: window,
            currentFraction: fraction,
            resetsAt: resetsAt,
            windowDuration: windowDuration,
            bankedResetCount: nil,
            nextBankedResetExpiresAt: nil
        )
    }
}

@MainActor
final class MobileUsageChartRenderingTests: XCTestCase {
    func testDailyGeometryKeepsCumulativeReadingsAndFractionalCosts() {
        let series = [[0.01, 0.09, 0.01], [0.03, 0.0, 0.06]].enumerated().map { index, values in
            RemoteUsageChartSeriesDTO(
                id: "\(index)", title: nil, isOther: false, styleIndex: index,
                points: values.enumerated().map { day, value in
                    .init(at: Double(day) * 86_400, value: value)
                }
            )
        }
        let geometry = MobileUsageDailyGeometry(bands: MobileUsageStackProjection.bands(for: series))
        XCTAssertEqual(geometry.bands.count, 2)
        for (band, expected) in zip(geometry.bands, [[0.01, 0.09, 0.01], [0.04, 0.09, 0.07]]) {
            var readings: [CGFloat] = []
            band.line.forEach { element in
                switch element {
                case .move(let point): readings.append(point.y)
                case .curve(let point, let first, let second):
                    readings.append(point.y)
                    XCTAssertTrue((0...1).contains(first.y))
                    XCTAssertTrue((0...1).contains(second.y))
                default: XCTFail("Daily curves must preserve each measured point")
                }
            }
            XCTAssertEqual(readings.count, expected.count)
            for (actual, value) in zip(readings, expected) {
                XCTAssertEqual(actual, 1 - value / 0.09, accuracy: 0.000_001)
            }
            XCTAssertGreaterThanOrEqual(band.fill.boundingRect.minY, 0)
            XCTAssertLessThanOrEqual(band.fill.boundingRect.maxY, 1)
        }
    }

    func testDailyGeometryHandlesEmptyAndZeroCostProviders() {
        XCTAssertTrue(MobileUsageDailyGeometry(bands: []).bands.isEmpty)
        let band = MobileUsageStackProjection.Band(
            id: "local", title: "Local", isOther: false, styleIndex: 2,
            edges: (0..<90).map { .init(at: Double($0) * 86_400, lower: 0, upper: 0) }
        )
        let geometry = MobileUsageDailyGeometry(bands: [band])
        XCTAssertEqual(geometry.bands.count, 1)
        XCTAssertEqual(geometry.bands[0].line.boundingRect.minY, 1)
        XCTAssertEqual(geometry.bands[0].line.boundingRect.maxY, 1)
    }

    /// The maximum daily chart is four aligned providers × 90 days. Measure the actual
    /// production plot mounting and rendering; manufacture DTOs outside the timed operation.
    func testDailyChartMountPerformance() throws {
        let start = 1_770_000_000.0
        let series = (0..<4).map { provider in
            RemoteUsageChartSeriesDTO(
                id: "provider-\(provider)", title: "Provider \(provider)", isOther: false,
                styleIndex: provider,
                points: (0..<90).map { day in
                    .init(at: start + Double(day) * 86_400,
                          value: Double((day * 7 + provider * 3) % 23))
                }
            )
        }
        let bands = MobileUsageStackProjection.bands(for: series)
        var durations: [Double] = []
        for _ in 0..<5 {
            let plot = MobileUsageDailyPlot(bands: bands, ticks: [], metricTitle: "Cost", summary: "Fixture")
            let host = UIHostingController(rootView: plot)
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 240)
            let began = CACurrentMediaTime()
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            _ = renderer.image { window.layer.render(in: $0.cgContext) }
            durations.append((CACurrentMediaTime() - began) * 1_000)
            window.isHidden = true
            window.rootViewController = nil
        }
        let warm = durations.dropFirst().sorted()
        print("USAGE_DAILY_MOUNT points=360 median_ms=\((warm[1] + warm[2]) / 2) max_ms=\(warm.last!) cold_ms=\(durations[0])")
        XCTAssertLessThan(warm.last!, 2_000, "daily chart mount must remain bounded")
    }

    /// The wire allows 280 observations and 118 resets. Weekly history normally contains
    /// 2–13 segments; stress uses 119, still inside that same transport envelope. Preparation
    /// is outside the timer; this measures the shipping chart's mount, layout and raster.
    func testSegmentedHistoryRendering() throws {
        for segmentCount in [13, 119] {
            let detail = Self.detail(segmentCount: segmentCount)
            var elapsed: [Double] = []
            for iteration in 0..<4 {
                let controller = UIHostingController(rootView:
                    MobileUsageLimitChart(detail: detail)
                        .padding(.horizontal, 16)
                        .padding(.top, 240)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Color.black)
                )
                let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
                window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
                let start = CACurrentMediaTime()
                window.rootViewController = controller
                window.makeKeyAndVisible()
                window.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image {
                    window.layer.render(in: $0.cgContext)
                }
                elapsed.append((CACurrentMediaTime() - start) * 1_000)
                if iteration == 3 {
                    let attachment = XCTAttachment(image: rendered)
                    attachment.name = "usage-history-\(segmentCount)-segments"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                window.isHidden = true
            }
            let warm = elapsed.dropFirst().sorted()
            print("USAGE_CHART segments=\(segmentCount) points=\(detail.observed.count) warmMedianMS=\(warm[1]) warmMaxMS=\(warm.last!) coldMS=\(elapsed[0])")
        }
    }

    func testResetGapsHaveSeparateZeroBasedFills() {
        let geometry = MobileUsageLimitLineGeometry(observed: [
            .init(at: 0, fraction: 0.2, segment: 0),
            .init(at: 2, fraction: 0.6, segment: 0),
            .init(at: 5, fraction: 0.1, segment: 1),
            .init(at: 10, fraction: 0.8, segment: 1)
        ], domain: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 10))
        XCTAssertEqual(geometry.lines.count, 2)
        XCTAssertEqual(geometry.fills.count, 2)
        XCTAssertEqual(geometry.lines[0].boundingRect.minX, 0)
        XCTAssertEqual(geometry.lines[0].boundingRect.maxX, 0.2, accuracy: 0.00001)
        XCTAssertEqual(geometry.lines[1].boundingRect.minX, 0.5)
        XCTAssertEqual(geometry.lines[1].boundingRect.minY, 0.2, accuracy: 0.00001)
        XCTAssertEqual(geometry.fills[0].boundingRect.maxY, 1, accuracy: 0.000001)
        XCTAssertEqual(geometry.fills[1].boundingRect.maxY, 1, accuracy: 0.000001)
    }

    func testOutOfDomainInkCannotDrawAboveThePlot() throws {
        let controller = UIHostingController(rootView:
            MobileUsageLimitChart(detail: Self.detail(segmentCount: 13, peakFraction: 2))
                .padding(.horizontal, 16)
                .padding(.top, 240)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color.black)
        )
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image {
            window.layer.render(in: $0.cgContext)
        }
        func inkCount(_ rect: CGRect) throws -> Int {
            let crop = try XCTUnwrap(rendered.cgImage?.cropping(to: rect))
            var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: crop.width, height: crop.height,
                                                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return stride(from: 0, to: bytes.count, by: 4).filter {
                bytes[$0] > 0 || bytes[$0 + 1] > 0 || bytes[$0 + 2] > 0
            }.count
        }
        XCTAssertEqual(try inkCount(CGRect(x: 80, y: 100, width: 280, height: 130)), 0)
        XCTAssertGreaterThan(try inkCount(CGRect(x: 80, y: 340, width: 280, height: 130)), 100,
                             "the containment assertion must inspect a rendered chart, not a blank capture")
    }

    static func detail(segmentCount: Int, peakFraction: Double = 0.95) -> RemoteUsageLimitDTO {
        let end = 1_800_000_000.0
        let span = 90.0 * 86_400
        let start = end - span
        let points = (0..<280).map { index in
            let segment = min(segmentCount - 1, index * segmentCount / 280)
            return RemoteUsageLimitPointDTO(
                at: start + Double(index) / 279 * span,
                fraction: index.isMultiple(of: 2) ? 0.2 : peakFraction,
                segment: segment
            )
        }
        return RemoteUsageLimitDTO(
            series: .init(id: "weekly", runtimeName: "Claude", accountName: "Fixture",
                          windowLabel: "Weekly", currentFraction: 0.95, resetsAt: end + 86_400,
                          windowDuration: 7 * 86_400, bankedResetCount: nil,
                          nextBankedResetExpiresAt: nil),
            days: 90, start: start, end: end, observed: points,
            resets: (1..<segmentCount).map { index in
                .init(id: "reset-\(index)", detectedAt: start + Double(index) / Double(segmentCount) * span,
                      previousObservedAt: start + Double(index) / Double(segmentCount) * span - 60,
                      cause: .scheduled, restoredFraction: 0.8,
                      elapsedFraction: 1, paceGainFraction: 0)
            },
            recordedResetCount: segmentCount - 1, restoredPaceFraction: 0,
            projection: nil, preparedAt: end
        )
    }
}

@MainActor
final class MobileUsagePeriodTests: XCTestCase {
    @MainActor
    private final class Loader {
        var pending: [Int: CheckedContinuation<RemoteUsageLimitDTO, Error>] = [:]
        var heldDays: Set<Int> = []
        func fetch(_ id: String, _ days: Int) async throws -> RemoteUsageLimitDTO {
            if heldDays.contains(days) {
                return try await withCheckedThrowingContinuation { pending[days] = $0 }
            }
            return try RemoteUsageDemo.limit(seriesID: id, days: days)
        }
        func finish(_ days: Int, id: String) throws {
            pending.removeValue(forKey: days)?.resume(returning: try RemoteUsageDemo.limit(seriesID: id, days: days))
        }
        func fail(_ days: Int) {
            pending.removeValue(forKey: days)?.resume(throwing: URLError(.timedOut))
        }
    }

    func testPeriodRequestKeepsTheShippingSheetsScrollExtent() async throws {
        let link = try XCTUnwrap(RemoteConnectionLink(string: "https://demo.invalid/#usage-test"))
        let loader = Loader()
        let model = RemoteUsageDashboardModel(link: link, isDemo: true, fetchLimit: loader.fetch)
        await model.load()
        let id = try XCTUnwrap(model.limitSeries.first { $0.windowDuration == 7 * 86_400 }?.id)
        model.selectedLimitID = id
        await model.loadLimit(seriesID: id, days: 30)
        let root = Color.black.sheet(isPresented: .constant(true)) {
            RemoteUsageDashboardView(link: link, isDemo: true, model: model)
                .mobileTheme(RemoteThemePalette(nil))
        }
        let controller = UIHostingController(rootView: root)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await settle(window)
        let sheet = try XCTUnwrap(controller.presentedViewController)
        let scroll = try XCTUnwrap(descendants(sheet.view, of: UIScrollView.self).first {
            $0.contentSize.height > $0.bounds.height
        })
        let picker = try XCTUnwrap(descendants(sheet.view, of: UISegmentedControl.self).first {
            $0.numberOfSegments == 3 && ($0.titleForSegment(at: 0)?.contains("7") == true)
        })
        let offset = min(180, scroll.contentSize.height - scroll.bounds.height)
        XCTAssertGreaterThan(offset, 20, "the fixture must actually scroll")
        scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        await settle(window)
        let beforeOffset = scroll.contentOffset.y
        let beforeHeight = scroll.contentSize.height
        capture(window, name: "usage-period-before")
        loader.heldDays = [7]
        picker.selectedSegmentIndex = 0
        picker.sendActions(for: .valueChanged)
        await settle(window)
        XCTAssertNotNil(loader.pending[7], "drive the real period control and its request")
        XCTAssertEqual(scroll.contentSize.height, beforeHeight, accuracy: 1,
                       "pending history must not remove the chart, legend and summary")
        XCTAssertEqual(scroll.contentOffset.y, beforeOffset, accuracy: 1)
        capture(window, name: "usage-period-loading")
        try loader.finish(7, id: id)
        await settle(window)
        XCTAssertEqual(model.limit?.days, 7)
        XCTAssertEqual(scroll.contentOffset.y, beforeOffset, accuracy: 1)

        loader.heldDays.insert(90)
        picker.selectedSegmentIndex = 2
        picker.sendActions(for: .valueChanged)
        await settle(window)
        XCTAssertNotNil(loader.pending[90])
        loader.fail(90)
        await settle(window)
        XCTAssertNotNil(model.limitErrorMessage)
        XCTAssertEqual(model.limit?.days, 7, "failure retains the last displayed history")
        XCTAssertEqual(scroll.contentOffset.y, beforeOffset, accuracy: 1)
        capture(window, name: "usage-period-error")
    }

    func testAnOlderPeriodResponseCannotReplaceTheLatestRequestOrClearItsLoadingState() async throws {
        let link = try XCTUnwrap(RemoteConnectionLink(string: "https://demo.invalid/#usage-test"))
        let loader = Loader()
        let model = RemoteUsageDashboardModel(link: link, isDemo: true, fetchLimit: loader.fetch)
        await model.load()
        let id = try XCTUnwrap(model.selectedLimitID)
        loader.heldDays = [7, 90]
        let older = Task { await model.loadLimit(seriesID: id, days: 7) }
        await waitForRequest(7, loader: loader)
        let newer = Task { await model.loadLimit(seriesID: id, days: 90) }
        await waitForRequest(90, loader: loader)
        try loader.finish(7, id: id)
        await older.value
        XCTAssertTrue(model.isLoadingLimit, "the older request cannot finish the newer request's spinner")
        XCTAssertNil(model.limit, "a superseded result cannot be presented")
        try loader.finish(90, id: id)
        await newer.value
        XCTAssertEqual(model.limit?.days, 90)
        XCTAssertFalse(model.isLoadingLimit)
    }

    func testReturningToTheDisplayedPeriodRetiresAnInFlightRequest() async throws {
        let link = try XCTUnwrap(RemoteConnectionLink(string: "https://demo.invalid/#usage-test"))
        let loader = Loader()
        let model = RemoteUsageDashboardModel(link: link, isDemo: true, fetchLimit: loader.fetch)
        await model.load()
        let id = try XCTUnwrap(model.selectedLimitID)
        await model.loadLimit(seriesID: id, days: 30)
        loader.heldDays = [7]
        let pending = Task { await model.loadLimit(seriesID: id, days: 7) }
        await waitForRequest(7, loader: loader)
        await model.loadLimit(seriesID: id, days: 30)
        XCTAssertFalse(model.isLoadingLimit)
        try loader.finish(7, id: id)
        await pending.value
        XCTAssertEqual(model.limit?.days, 30)
        XCTAssertNil(model.limitErrorMessage)
    }

    func testSupersededFailureDoesNotCoverTheNewHistory() async throws {
        let link = try XCTUnwrap(RemoteConnectionLink(string: "https://demo.invalid/#usage-test"))
        let loader = Loader()
        let model = RemoteUsageDashboardModel(link: link, isDemo: true, fetchLimit: loader.fetch)
        await model.load()
        let id = try XCTUnwrap(model.selectedLimitID)
        loader.heldDays = [7]
        let pending = Task { await model.loadLimit(seriesID: id, days: 7) }
        await waitForRequest(7, loader: loader)
        await model.loadLimit(seriesID: id, days: 90)
        loader.fail(7)
        await pending.value
        XCTAssertEqual(model.limit?.days, 90)
        XCTAssertNil(model.limitErrorMessage)
        XCTAssertFalse(model.isLoadingLimit)
    }

    private func waitForRequest(_ days: Int, loader: Loader) async {
        for _ in 0..<100 where loader.pending[days] == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(loader.pending[days])
    }

    private func capture(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? [])
            + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func settle(_ window: UIWindow) async {
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
        }
    }
}
