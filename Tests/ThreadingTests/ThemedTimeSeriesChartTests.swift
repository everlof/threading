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
