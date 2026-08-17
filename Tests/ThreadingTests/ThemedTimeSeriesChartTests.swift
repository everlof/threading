import AppKit
import XCTest
@testable import Threading

@MainActor
final class ThemedTimeSeriesChartTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    func testGeometryBoundsLargeSeriesAndKeepsExtremaAndSegments() {
        var points = (0..<20_000).map { index in
            ThemedChartPoint(
                at: start.addingTimeInterval(TimeInterval(index)),
                value: Double(index % 100) / 100,
                segment: index < 10_000 ? 0 : 1
            )
        }
        points[4_321] = ThemedChartPoint(at: points[4_321].at, value: 50, segment: 0)
        points[4_322] = ThemedChartPoint(at: points[4_322].at, value: -20, segment: 0)

        let bounded = ThemedChartGeometry.downsample(points, maximumCount: 240)
        let rendered = ThemedChartGeometry.render(model(points: points))

        XCTAssertLessThanOrEqual(bounded.count, 240)
        XCTAssertTrue(bounded.contains(points[4_321]))
        XCTAssertTrue(bounded.contains(points[4_322]))
        XCTAssertTrue(bounded.contains(points[9_999]))
        XCTAssertTrue(bounded.contains(points[10_000]))
        XCTAssertLessThanOrEqual(rendered[0].points.count, Design.Chart.maximumRenderedPoints)
    }

    func testGeometryBudgetSurvivesMoreSegmentBoundariesThanItCanDraw() {
        let points = (0..<20_000).map { index in
            ThemedChartPoint(
                at: start.addingTimeInterval(TimeInterval(index)),
                value: index.isMultiple(of: 2) ? 0.95 : 0.05,
                segment: index / 2
            )
        }

        let bounded = ThemedChartGeometry.downsample(points, maximumCount: 240)
        let rendered = ThemedChartGeometry.render(model(points: points))

        XCTAssertLessThanOrEqual(bounded.count, 240)
        XCTAssertEqual(bounded.first, points.first)
        XCTAssertEqual(bounded.last, points.last)
        XCTAssertTrue(zip(bounded, bounded.dropFirst()).contains { pair in
            pair.0.segment != pair.1.segment
        })
        XCTAssertLessThanOrEqual(rendered[0].points.count, Design.Chart.maximumRenderedPoints)
    }

    func testMarkerGeometryIsBoundedAndKeepsTheTimeRangeEndpoints() {
        let markers = (0..<20_000).map { index in
            ThemedChartMarker(
                id: "marker-\(index)",
                at: start.addingTimeInterval(TimeInterval(index)),
                title: "Reset",
                detail: nil,
                kind: .reset
            )
        }

        let bounded = ThemedChartGeometry.downsample(markers)

        XCTAssertEqual(bounded.count, Design.Chart.maximumRenderedMarkers)
        XCTAssertEqual(bounded.first, markers.first)
        XCTAssertEqual(bounded.last, markers.last)
    }

    func testStackedBandsUseThicknessForEachSeriesAndUpperEdgeForTheTotal() {
        let dates = [start, start.addingTimeInterval(60)]
        let model = ThemedChartModel(
            title: "Stacked usage",
            accessibilitySummary: "Two additive providers",
            series: [
                ThemedChartSeries(
                    id: "a",
                    title: "A",
                    points: [
                        ThemedChartPoint(at: dates[0], value: 2),
                        ThemedChartPoint(at: dates[1], value: 4)
                    ]
                ),
                ThemedChartSeries(
                    id: "b",
                    title: "B",
                    points: [
                        ThemedChartPoint(at: dates[0], value: 3),
                        ThemedChartPoint(at: dates[1], value: 1)
                    ]
                )
            ],
            yRange: 0...10
        )

        let independent = ThemedChartGeometry.render(model)
        let stacked = ThemedChartGeometry.render(model, composition: .stackedBands)

        XCTAssertEqual(independent[1].points[0].baselineY, 0, accuracy: 0.000_1)
        XCTAssertEqual(independent[1].points[0].y, 0.3, accuracy: 0.000_1)
        XCTAssertEqual(stacked[0].points[0].baselineY, 0, accuracy: 0.000_1)
        XCTAssertEqual(stacked[0].points[0].y, 0.2, accuracy: 0.000_1)
        XCTAssertEqual(stacked[1].points[0].baselineY, 0.2, accuracy: 0.000_1)
        XCTAssertEqual(stacked[1].points[0].y, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(stacked[1].points[1].baselineY, 0.4, accuracy: 0.000_1)
        XCTAssertEqual(stacked[1].points[1].y, 0.5, accuracy: 0.000_1)
    }

    func testStackedTransitionMorphsBothBandEdgesWithoutChangingItsPointBudget() {
        let old = stackedModel(lower: [1, 2, 3], upper: [2, 3, 4])
        let new = stackedModel(lower: [4, 3, 2], upper: [1, 2, 3])
        let source = ThemedChartGeometry.render(old, composition: .stackedBands)
        let target = ThemedChartGeometry.render(new, composition: .stackedBands)
        let middle = ThemedChartGeometry.interpolate(
            from: source,
            to: target,
            composition: .stackedBands,
            progress: 0.5
        )

        XCTAssertEqual(middle.map(\.points.count), target.map(\.points.count))
        for seriesIndex in middle.indices {
            for pointIndex in middle[seriesIndex].points.indices {
                let point = middle[seriesIndex].points[pointIndex]
                XCTAssertLessThanOrEqual(point.baselineY, point.y)
                XCTAssertGreaterThanOrEqual(
                    point.baselineY,
                    min(
                        source[seriesIndex].points[pointIndex].baselineY,
                        target[seriesIndex].points[pointIndex].baselineY
                    )
                )
                XCTAssertLessThanOrEqual(
                    point.baselineY,
                    max(
                        source[seriesIndex].points[pointIndex].baselineY,
                        target[seriesIndex].points[pointIndex].baselineY
                    )
                )
            }
        }
    }

    func testTransitionMorphsDifferentPointCountsWithoutJumpingAtEitherEnd() {
        let old = ThemedChartGeometry.render(model(points: points(count: 20, slope: 0.2)))
        let new = ThemedChartGeometry.render(model(points: points(count: 90, slope: 0.8)))

        let beginning = ThemedChartGeometry.interpolate(from: old, to: new, progress: 0)
        let middle = ThemedChartGeometry.interpolate(from: old, to: new, progress: 0.5)
        let end = ThemedChartGeometry.interpolate(from: old, to: new, progress: 1)

        XCTAssertEqual(beginning[0].points.count, new[0].points.count)
        XCTAssertEqual(end, new)
        XCTAssertNotEqual(middle, beginning)
        XCTAssertNotEqual(middle, end)
        for index in middle[0].points.indices {
            XCTAssertGreaterThanOrEqual(middle[0].points[index].y, min(
                beginning[0].points[index].y,
                end[0].points[index].y
            ))
            XCTAssertLessThanOrEqual(middle[0].points[index].y, max(
                beginning[0].points[index].y,
                end[0].points[index].y
            ))
        }
    }

    func testInterruptedAnimationRestartsFromItsPresentationGeometry() {
        Design.Motion.reduceMotionOverrideForTesting = false
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let chart = ThemedTimeSeriesChartView(frame: NSRect(x: 0, y: 0, width: 700, height: 260))
        let window = NSWindow(contentRect: chart.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = chart
        chart.setModel(model(points: points(count: 30, slope: 0.2)), animated: false)
        chart.setModel(model(points: points(count: 30, slope: 0.8)), animated: true)
        chart.advanceAnimation(now: CACurrentMediaTime() + Design.Motion.standard / 2)
        let presentation = chart.displayedGeometryForTesting

        chart.setModel(model(points: points(count: 30, slope: 0.5)), animated: true)

        XCTAssertEqual(chart.displayedGeometryForTesting, presentation)
        XCTAssertEqual(chart.animationProgress, 0)
    }

    func testReduceMotionLandsSynchronouslyAndChartIsAccessible() {
        Design.Motion.reduceMotionOverrideForTesting = true
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let chart = ThemedTimeSeriesChartView(frame: NSRect(x: 0, y: 0, width: 700, height: 260))
        chart.setModel(model(points: points(count: 20, slope: 0.4)), animated: true)

        XCTAssertEqual(chart.animationProgress, 1)
        XCTAssertEqual(chart.displayedGeometryForTesting, ThemedChartGeometry.render(chart.model))
        XCTAssertEqual(chart.accessibilityRole(), .group)
        XCTAssertEqual(chart.accessibilityTitle(), "Usage over time")
        XCTAssertTrue(chart.accessibilityPerformPress())
        XCTAssertTrue((chart.accessibilityValue() as? String)?.contains("tokens") == true)
    }

    func testAutomaticYAxisUsesReadableGridIntervals() {
        let chart = ThemedTimeSeriesChartView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 260)
        )
        chart.setModel(model(points: [
            ThemedChartPoint(at: start, value: 184_453.3)
        ]), animated: false)

        let range = chart.resolvedYRangeForTesting
        XCTAssertEqual(range, 0...200_000)
        let interval = range.upperBound / Double(Design.Chart.gridLineCount - 1)
        XCTAssertEqual(interval, 50_000)
    }

    /// A ranking's names are drawn in a fixed-width gutter, so a long one is an ellipsized stub.
    /// Pointing at the stub is how a reader asks what it says, and the gutter is part of the band
    /// it labels rather than dead chrome beside it.
    func testPointingAtATruncatedCategoryNameStatesTheWholeEntry() {
        let chart = ThemedTimeSeriesChartView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        chart.setModel(rankingModel(), animated: false)
        let plot = chart.plotRectForTesting

        chart.hoverForTesting(at: NSPoint(x: Design.Spacing.inset, y: bandCentre(1, in: plot)))

        XCTAssertTrue(chart.inspectionForTesting.contains(Self.categories[1]))
        XCTAssertTrue(chart.inspectionForTesting.contains("49 GB"))
        XCTAssertTrue(
            (chart.accessibilityValue() as? String)?.contains(Self.categories[1]) == true
        )
    }

    /// The band and its name are one target: pointing at the bar answers with the same lines the
    /// name does, so a reader who found the entry either way reads the same thing.
    func testPointingAtTheBarAndAtItsNameAnswerAlike() {
        let chart = ThemedTimeSeriesChartView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        chart.setModel(rankingModel(), animated: false)
        let plot = chart.plotRectForTesting
        let row = bandCentre(0, in: plot)

        chart.hoverForTesting(at: NSPoint(x: plot.midX, y: row))
        let overTheBar = chart.inspectionForTesting
        chart.hoverForTesting(at: NSPoint(x: Design.Spacing.inset, y: row))

        XCTAssertEqual(chart.inspectionForTesting, overTheBar)
        XCTAssertEqual(overTheBar, [Self.categories[0], "91 GB"])
    }

    /// A categorical point's label is its *name*, so the reading has to be stated as well — a
    /// compressed ranking prints no number beside a thin bar, and a time series must not repeat
    /// its own reading, which is what its label already is.
    func testInspectionStatesANameAndItsReadingButNeverTheReadingTwice() {
        let ranking = ThemedTimeSeriesChartView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        ranking.setModel(rankingModel(), animated: false)
        let plot = ranking.plotRectForTesting
        ranking.hoverForTesting(at: NSPoint(x: plot.midX, y: bandCentre(2, in: plot)))

        let series = ThemedTimeSeriesChartView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        series.setModel(model(points: points(count: 8, slope: 0.5)), animated: false)
        series.hoverForTesting(at: NSPoint(
            x: series.plotRectForTesting.midX,
            y: series.plotRectForTesting.midY
        ))

        XCTAssertEqual(ranking.inspectionForTesting, [Self.categories[2], "41 GB"])
        XCTAssertEqual(series.inspectionForTesting.filter { $0.hasSuffix("tokens") }.count, 1)
        XCTAssertFalse(series.inspectionForTesting.contains { $0.isEmpty })
    }

    /// A time chart's leading gutter holds values rather than names, so there is nothing there to
    /// point at — and answering a hover would name whichever point sits against the left edge.
    func testAValueAxisGutterIsNotAHoverTarget() {
        let chart = ThemedTimeSeriesChartView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        chart.setModel(model(points: points(count: 12, slope: 0.5)), animated: false)
        let plot = chart.plotRectForTesting

        chart.hoverForTesting(at: NSPoint(x: plot.midX, y: plot.midY))
        XCTAssertFalse(chart.inspectionForTesting.isEmpty)
        chart.hoverForTesting(at: NSPoint(x: Design.Spacing.inset, y: plot.midY))

        XCTAssertEqual(chart.inspectionForTesting, [])
    }

    /// Where category *index* is centred when the value axis runs across the page.
    private func bandCentre(_ index: Int, in plot: NSRect) -> CGFloat {
        let band = plot.height / CGFloat(Self.categories.count)
        return plot.maxY - (CGFloat(index) + 0.5) * band
    }

    private static let categories = [
        "/tmp/claude-501/-Users-david-repo-AnotherTerminal",
        "Xcode DerivedData and module caches",
        "~/Library/Application Support"
    ]

    private func rankingModel() -> ThemedChartModel {
        ThemedChartModel.categorical(
            title: "What is consuming the volume",
            accessibilitySummary: "Storage by location",
            categories: Self.categories,
            series: [ThemedChartSeries(
                id: "size",
                // No title: one series needs no key, and the tooltip must not open on a blank line.
                title: "",
                values: [91, 49, 41],
                categories: Self.categories,
                style: .primary
            )],
            orientation: .horizontal,
            valueFormat: .unit("GB")
        )
    }

    private func points(count: Int, slope: Double) -> [ThemedChartPoint] {
        (0..<count).map { index in
            ThemedChartPoint(
                at: start.addingTimeInterval(TimeInterval(index * 60)),
                value: Double(index) * slope,
                label: "\(index) tokens"
            )
        }
    }

    private func model(points: [ThemedChartPoint]) -> ThemedChartModel {
        ThemedChartModel(
            title: "Usage over time",
            accessibilitySummary: "Token usage over time",
            series: [ThemedChartSeries(id: "tokens", title: "Tokens", points: points)],
            valueFormat: .tokens
        )
    }

    private func stackedModel(lower: [Double], upper: [Double]) -> ThemedChartModel {
        let values = [lower, upper]
        return ThemedChartModel(
            title: "Stacked usage",
            accessibilitySummary: "Stacked transition fixture",
            series: values.enumerated().map { seriesIndex, series in
                ThemedChartSeries(
                    id: "stack-\(seriesIndex)",
                    title: "Stack \(seriesIndex)",
                    points: series.enumerated().map { pointIndex, value in
                        ThemedChartPoint(
                            at: start.addingTimeInterval(TimeInterval(pointIndex * 60)),
                            value: value
                        )
                    }
                )
            },
            yRange: 0...10
        )
    }
}
