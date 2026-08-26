import AppKit
import XCTest
@testable import Threading

/// The Usage page before it has numbers, and while it is getting new ones.
///
/// Three states, and the page has to keep them apart: nothing measured, a first scan running with
/// nothing to show yet, and a rescan behind a report that is already on screen. They used to be
/// two: one sentence, printed in the chart, beside the hero total and under all five metric cards.
@MainActor
final class UsageDashboardWaitingTests: XCTestCase {

    private func dashboard(
        report: TranscriptUsageReport? = nil,
        isBuilding: Bool,
        progress: UsageScanProgress? = nil
    ) -> UsageDashboardView {
        let view = UsageDashboardView()
        view.update(
            report: report,
            limits: [],
            isBuilding: isBuilding,
            scanProgress: progress,
            animated: false
        )
        return view
    }

    /// One day of one route: enough for the page to have a report to keep on screen.
    private func report() -> TranscriptUsageReport {
        var scan = TranscriptUsageReport.ScanStatistics()
        scan.sourceFiles = 3
        scan.distinctRecords = 12
        return TranscriptUsageReport(
            cells: [TranscriptUsageReport.Cell(
                day: Calendar.autoupdatingCurrent.startOfDay(for: Date()),
                origin: .direct(.claude),
                accountID: "claude:fixture",
                accountName: "Personal",
                model: "claude-opus-4",
                checkoutPath: "/Users/example/repo",
                checkoutLabel: "Example",
                tokens: .init(
                    uncachedInput: 1_000,
                    cachedInput: 4_000,
                    cacheWrite: 200,
                    output: 900,
                    reasoning: 100
                ),
                providerReportedCostUSD: 0,
                catalogCostUSD: 1.25,
                unpricedTokens: 0,
                cacheSavingsUSD: 2,
                records: 12
            )],
            coverage: [],
            scan: scan,
            builtAt: Date()
        )
    }

    // MARK: - Nothing measured

    func testConsumptionIsTheDefaultAndTheDashboardShowsExactlyOneSection() {
        let view = dashboard(isBuilding: false)

        XCTAssertEqual(view.selectedDashboardSectionForTesting, .consumption)
        XCTAssertEqual(
            view.dashboardSectionTitlesForTesting,
            [L10n.string("Consumption"), L10n.string("Limit history")]
        )
        XCTAssertEqual(view.visibleDashboardSectionCountForTesting, 1)

        view.selectDashboardSectionForTesting(.limitHistory)

        XCTAssertEqual(view.selectedDashboardSectionForTesting, .limitHistory)
        XCTAssertEqual(view.visibleDashboardSectionCountForTesting, 1)
    }

    func testAnEmptyPageSaysWhatWouldFillIt() {
        let view = dashboard(isBuilding: false)
        XCTAssertEqual(view.usagePlaceholderForTesting, .empty)
        XCTAssertNotNil(
            view.usagePlaceholderDetailForTesting,
            "a chart that says only \"no usage\" answers none of the questions a reader has"
        )
        XCTAssertFalse(view.scanStripForTesting.isVisible)
    }

    func testTheStatusIsNotRepeatedUnderEveryMetricCard() {
        for isBuilding in [true, false] {
            let details = dashboard(isBuilding: isBuilding).statBandDetailsForTesting
            XCTAssertEqual(
                details.filter({ !$0.isEmpty }).count,
                0,
                "the page's one sentence belongs in the chart, not under five dashes"
            )
        }
    }

    // MARK: - The first scan

    func testCountingTheSourcesIsIndeterminate() {
        let view = dashboard(isBuilding: true)
        XCTAssertEqual(view.usagePlaceholderForTesting, .loading(progress: nil))
        XCTAssertEqual(view.usagePlaceholderTitleForTesting, L10n.string("Reading usage sources…"))
    }

    func testReadingThemReportsHowFarItHasGot() {
        let view = dashboard(
            isBuilding: true,
            progress: UsageScanProgress(
                sourceName: "Claude Code",
                completedSources: 100,
                totalSources: 400
            )
        )
        XCTAssertEqual(view.usagePlaceholderForTesting, .loading(progress: 0.25))
        XCTAssertEqual(
            view.usagePlaceholderDetailForTesting?.contains("Claude Code"),
            true,
            "the detail names the source being read"
        )
        XCTAssertFalse(
            view.scanStripForTesting.isVisible,
            "with nothing on screen to refresh, the chart carries the status by itself"
        )
    }

    func testAProgressTickReachesTheChartWithoutAReport() {
        let view = dashboard(isBuilding: true)
        view.updateScanProgress(
            UsageScanProgress(sourceName: "Codex", completedSources: 3, totalSources: 6),
            isBuilding: true
        )
        XCTAssertEqual(view.usagePlaceholderForTesting, .loading(progress: 0.5))
    }

    // MARK: - A rescan behind a report

    func testARescanIsAnnouncedBesideTheTabsRatherThanOverTheChart() throws {
        let view = dashboard(report: report(), isBuilding: true)
        XCTAssertNil(
            view.usagePlaceholderForTesting,
            "the chart is showing real numbers; a status over them would cover what is being refreshed"
        )
        XCTAssertTrue(view.scanStripForTesting.isVisible)
        XCTAssertNil(view.scanStripForTesting.progress, "the sources have not been counted yet")

        view.updateScanProgress(
            UsageScanProgress(sourceName: "Claude Code", completedSources: 30, totalSources: 40),
            isBuilding: true
        )
        XCTAssertEqual(try XCTUnwrap(view.scanStripForTesting.progress), 0.75, accuracy: 0.001)
        XCTAssertGreaterThan(
            view.usageRenderedPointCountForTesting,
            0,
            "a progress tick must not take the report off the page"
        )
    }

    func testTheStripGoesWhenTheScanEnds() {
        let view = dashboard(report: report(), isBuilding: true)
        XCTAssertTrue(view.scanStripForTesting.isVisible)
        view.update(report: report(), limits: [], isBuilding: false, animated: false)
        XCTAssertFalse(view.scanStripForTesting.isVisible)
    }
}
