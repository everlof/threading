import AppKit
import XCTest
@testable import Threading

/// The agent-facing chart surface: what a call is allowed to say, where the marks land, what the
/// transcript makes of the call, and what the whole thing looks like.
@MainActor
final class ChartTests: XCTestCase {

    // MARK: - Fixtures

    /// A card at a stated size.
    ///
    /// Setting `frame` on a detached, constraint-driven view states nothing: the layout engine
    /// runs from the constraints alone and is free to collapse it, which is how the first
    /// version of the storybook produced a nil bitmap instead of a chart. Anchors are what a
    /// fixture standing in for a pane actually has to say.
    @discardableResult
    private func laidOut(
        _ card: ChartCardView,
        width: CGFloat = 520
    ) -> ChartCardView {
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: width),
            card.heightAnchor.constraint(
                equalToConstant: ChartCardView.preferredHeight(for: card.spec)
            )
        ])
        card.layoutSubtreeIfNeeded()
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        card.layoutSubtreeIfNeeded()
        return card
    }

    private func comparison(
        kind: ChartSpec.Kind = .bar,
        stacked: Bool = false
    ) -> ChartSpec {
        ChartSpec(
            title: "Cold start by phase",
            summary: nil,
            kind: kind,
            categories: ["parse", "layout", "first paint"],
            series: [
                ChartSpec.Series(
                    name: "Before", values: [42, 31, 68], details: nil, emphasis: .negative
                ),
                ChartSpec.Series(
                    name: "After", values: [26, 24, 39], details: nil, emphasis: .positive
                )
            ],
            stacked: stacked,
            valueFormat: .number,
            unit: "ms",
            maximumValue: nil
        )
    }

    private func single(values: [Double], categories: [String]) -> ChartSpec {
        ChartSpec(
            title: "Durations",
            summary: nil,
            kind: .bar,
            categories: categories,
            series: [
                ChartSpec.Series(name: "Run", values: values, details: nil, emphasis: nil)
            ],
            stacked: false,
            valueFormat: .number,
            unit: nil,
            maximumValue: nil
        )
    }

    // MARK: - Validation

    func testAValidComparisonPassesValidation() throws {
        XCTAssertEqual(try comparison().validated(), comparison())
    }

    func testASeriesShorterThanItsCategoriesIsRefusedByName() {
        let spec = single(values: [1, 2], categories: ["a", "b", "c"])
        XCTAssertThrowsError(try spec.validated()) { error in
            XCTAssertEqual(
                error as? ChartSpec.Failure,
                .lengthMismatch(series: "Run", values: 2, categories: 3)
            )
            // The message has to be actionable by the model that sent it, so it names the
            // series and both counts rather than reporting that decoding failed.
            let described = error.localizedDescription
            XCTAssertTrue(described.contains("\"Run\""), described)
            XCTAssertTrue(described.contains("2 values"), described)
            XCTAssertTrue(described.contains("3 categories"), described)
        }
    }

    func testANonFiniteValueIsRefused() {
        let spec = single(values: [1, .infinity, 3], categories: ["a", "b", "c"])
        XCTAssertThrowsError(try spec.validated()) {
            XCTAssertEqual($0 as? ChartSpec.Failure, .nonFiniteValue(series: "Run"))
        }
    }

    func testANegativeValueIsRefusedOnlyWhenStacked() throws {
        var spec = single(values: [1, -2, 3], categories: ["a", "b", "c"])
        XCTAssertNoThrow(try spec.validated())

        spec.stacked = true
        XCTAssertThrowsError(try spec.validated()) {
            XCTAssertEqual($0 as? ChartSpec.Failure, .negativeStackedValue(series: "Run"))
        }
    }

    func testTooManyMarksAreRefusedEvenWhenEachAxisIsWithinItsCap() {
        // Eight series of sixty categories passes both per-axis caps and is still 480 marks in
        // a pane a few hundred points wide; the product is the bound that matters.
        let categories = (0..<Int(ChartSpec.Limits.maximumCategories)).map { "c\($0)" }
        let series = (0..<ChartSpec.Limits.maximumSeries).map { index in
            ChartSpec.Series(
                name: "s\(index)",
                values: Array(repeating: 1, count: categories.count),
                details: nil,
                emphasis: nil
            )
        }
        let spec = ChartSpec(
            title: "Wide", summary: nil, kind: .bar, categories: categories, series: series,
            stacked: false, valueFormat: .number, unit: nil, maximumValue: nil
        )
        XCTAssertEqual(spec.series.count, ChartSpec.Limits.maximumSeries)
        XCTAssertEqual(spec.categories.count, ChartSpec.Limits.maximumCategories)
        XCTAssertThrowsError(try spec.validated())
    }

    // MARK: - Band scale

    func testCategoriesLandInTheMiddleOfTheirOwnBand() throws {
        let model = comparison().themedModel
        let layout = ThemedChartGeometry.layout(model)
        let first = try XCTUnwrap(layout.series.first)

        // Three categories, so the bands are thirds and the bars stand at 1/6, 1/2, 5/6. The
        // half-step padding is what keeps the outer two off the plot edges: without it they
        // would sit at 0 and 1 and be drawn half outside the chart.
        XCTAssertEqual(first.points.map(\.x), [1.0 / 6, 0.5, 5.0 / 6], accuracy: 0.0001)
    }

    func testEverySeriesSharesOneValueScale() throws {
        let layout = ThemedChartGeometry.layout(comparison().themedModel)
        XCTAssertEqual(layout.series.count, 2)

        // The tallest bar in the chart is 68; every series is normalized against the same
        // domain, which is the whole reason the host owns the scale rather than the caller.
        let tallest = layout.series.flatMap { $0.points.map(\.y) }.max() ?? 0
        let ratio = try XCTUnwrap(layout.series.last?.points.last?.y) / tallest
        XCTAssertEqual(ratio, 39.0 / 68.0, accuracy: 0.01)
    }

    func testBarsStandOnZeroUnlessTheChartIsStacked() throws {
        let grouped = ThemedChartGeometry.layout(comparison().themedModel)
        XCTAssertTrue(grouped.series.allSatisfy { $0.points.allSatisfy { $0.baselineY == 0 } })

        let stacked = ThemedChartGeometry.layout(
            comparison(stacked: true).themedModel,
            composition: .stackedBands
        )
        // The second band starts where the first one ended: the composition already computed
        // the running total, which is exactly what a stacked bar needs for its foot.
        let lower = try XCTUnwrap(stacked.series.first?.points.first)
        let upper = try XCTUnwrap(stacked.series.last?.points.first)
        XCTAssertEqual(upper.baselineY, lower.y, accuracy: 0.0001)
    }

    // MARK: - Presentation

    func testAVerdictOnOneSeriesQuietsTheOthersRatherThanColouringThem() {
        let model = comparison().themedModel
        XCTAssertEqual(model.series.map(\.style), [.negative, .positive])

        // With nothing marked, series are merely different and take categorical hues.
        var plain = comparison()
        plain.series = plain.series.map {
            ChartSpec.Series(name: $0.name, values: $0.values, details: nil, emphasis: nil)
        }
        XCTAssertEqual(plain.themedModel.series.map(\.style), [.categorical(0), .categorical(1)])
    }

    func testTheUnitTravelsWithTheNumbersRatherThanTheTitle() {
        XCTAssertEqual(comparison().resolvedValueFormat, .unit("ms"))

        var currency = comparison()
        currency.valueFormat = .currency
        // An explicit format outranks the suffix; a currency chart must not read "$4 ms".
        XCTAssertEqual(currency.resolvedValueFormat, .currency)
    }

    func testALegendAppearsOnlyWhenThereIsMoreThanOneSeries() {
        XCTAssertTrue(comparison().themedModel.showsLegend)
        XCTAssertFalse(single(values: [1, 2], categories: ["a", "b"]).themedModel.showsLegend)
    }

    func testACategoryNamesItsOwnValueForVoiceOver() throws {
        let model = comparison().themedModel
        let point = try XCTUnwrap(model.series.first?.points.first)
        XCTAssertEqual(point.label, "parse")
        XCTAssertFalse(model.accessibilitySummary.isEmpty)
    }

    // MARK: - Copying out

    func testTheNumbersCanBeCopiedBackOutAsATable() {
        XCTAssertEqual(
            comparison().tabSeparatedValues,
            """
            \tBefore\tAfter
            parse\t42\t26
            layout\t31\t24
            first paint\t68\t39
            """
        )
    }

    func testTheFingerprintFollowsTheNumbersAndSurvivesRelaunch() {
        var changed = comparison()
        changed.series[0] = ChartSpec.Series(
            name: "Before", values: [42, 31, 69], details: nil, emphasis: .negative
        )
        XCTAssertEqual(comparison().fingerprint, comparison().fingerprint)
        XCTAssertNotEqual(comparison().fingerprint, changed.fingerprint)

        // Stable, not `hashValue`: a per-process seed would report every restored chart as new
        // and re-brief the agent about a panel nobody touched.
        XCTAssertEqual(comparison().fingerprint, "2uh99cbimy2cf")
    }

    // MARK: - Reading a call back

    func testAChartCallIsRecognizedFromItsArgumentsWithIntegerValues() throws {
        let input: [String: Any] = [
            "title": "Cold start by phase",
            "categories": ["parse", "layout"],
            // Integers, which is how a model writes a whole number and where an `as? [Double]`
            // cast silently gives up.
            "series": [["name": "Before", "values": [42, 31]]],
            "unit": "ms"
        ]
        let spec = try XCTUnwrap(
            ChartSpec.decoded(
                fromToolNamed: MCPDefaults.allowedToolName("display_chart"),
                input: input
            )
        )
        XCTAssertEqual(spec.title, "Cold start by phase")
        XCTAssertEqual(spec.series.first?.values, [42, 31])
        XCTAssertEqual(spec.kind, .bar)
    }

    func testAnotherToolAndAMalformedCallAreNotCharts() {
        let good: [String: Any] = [
            "title": "T", "categories": ["a"], "series": [["name": "s", "values": [1]]]
        ]
        XCTAssertNil(ChartSpec.decoded(fromToolNamed: "Bash", input: good))

        // Two values against one category is a chart that would lie; the transcript leaves it
        // an ordinary tool row and lets the panel be the one to refuse it.
        let mismatched: [String: Any] = [
            "title": "T", "categories": ["a"], "series": [["name": "s", "values": [1, 2]]]
        ]
        XCTAssertNil(
            ChartSpec.decoded(
                fromToolNamed: MCPDefaults.allowedToolName("display_chart"),
                input: mismatched
            )
        )
    }

    func testTheToolIsAdvertisedWithItsRequiredArguments() throws {
        let definition = try XCTUnwrap(MCPTools.definition(for: .displayChart))
        XCTAssertEqual(definition.inputSchema.required, ["title", "categories", "series"])
        XCTAssertNotNil(definition.inputSchema.properties["series"]?.items?.properties?["values"])
    }

    func testTheDisplayGroupTellsEveryRuntimeWhenToChart() throws {
        let group = try XCTUnwrap(MCPToolCatalog.groups.first { $0.id == "display" })
        XCTAssertTrue(group.tools.contains { $0.builtInTool == .displayChart })
        XCTAssertTrue(group.instruction.contains("display_chart"), group.instruction)
        // display_scene must stop advertising itself as the way to draw a bar chart, or the
        // two tools compete and the geometry-level one wins by being listed first.
        let scene = try XCTUnwrap(MCPTools.definition(for: .displayScene))
        XCTAssertFalse(scene.description.contains("bar chart"), scene.description)
    }

    // MARK: - The card

    func testTheCardNamesItselfAndKeepsItsChartOnRespec() throws {
        let card = laidOut(ChartCardView(spec: comparison()))

        XCTAssertEqual(card.accessibilityLabel(), "Cold start by phase")
        XCTAssertEqual(card.accessibilityRole(), .group)

        var renamed = comparison()
        renamed.title = "Warm start by phase"
        card.setSpec(renamed, animated: false)
        XCTAssertEqual(card.accessibilityLabel(), "Warm start by phase")
        XCTAssertEqual(card.spec.title, "Warm start by phase")
    }

    func testTheChartFillsTheCardRatherThanCollapsingUnderItsTitle() throws {
        let card = laidOut(ChartCardView(spec: comparison()))
        let chart = card.chartForTesting

        // The bug this is here for drew a perfect title over an empty rectangle: the chart was
        // still on its autoresizing mask, so it kept the zero frame it was built with while
        // every other assertion in this file passed.
        XCTAssertGreaterThan(chart.frame.height, 100)
        XCTAssertEqual(chart.frame.width, card.frame.width)
        XCTAssertEqual(chart.renderedPointCount, 6)
    }

    func testTheCardRepaintsWhenTheThemeChangesUnderIt() throws {
        let card = laidOut(ChartCardView(spec: comparison()))

        // The chart holds values, not colours: applying a theme must not need a new spec.
        card.applyTheme()
        XCTAssertEqual(card.spec, comparison())
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: card), [])
    }

    func testARankingAsksForRoomProportionalToItsRows() {
        let short = ChartSpec(
            title: "Slowest", summary: nil, kind: .ranking, categories: ["a", "b"],
            series: [ChartSpec.Series(name: "s", values: [1, 2], details: nil, emphasis: nil)],
            stacked: false, valueFormat: .number, unit: nil, maximumValue: nil
        )
        let long = ChartSpec(
            title: "Slowest", summary: nil, kind: .ranking,
            categories: (0..<24).map { "c\($0)" },
            series: [
                ChartSpec.Series(
                    name: "s", values: Array(repeating: 1, count: 24), details: nil, emphasis: nil
                )
            ],
            stacked: false, valueFormat: .number, unit: nil, maximumValue: nil
        )
        // A virtualized row has to answer its height before the view exists, and twenty-four
        // bars do not fit in the height two bars need.
        XCTAssertGreaterThan(
            ChartCardView.preferredHeight(for: long),
            ChartCardView.preferredHeight(for: short)
        )
    }

    // MARK: - In the panel

    /// Switching off a chart tab has to leave the pane holding one thing.
    ///
    /// Reported from the running app: selecting Attachments drew its list over a chart that was
    /// still there underneath, title and axis and all.
    func testSwitchingAwayFromAChartLeavesNothingOfItBehind() throws {
        let pane = DisplayPaneController()
        let sessionID = SessionID()
        pane.showSession(sessionID)
        pane.view.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        pane.view.layoutSubtreeIfNeeded()

        pane.addContentTab(
            DisplayContent(body: .chart(comparison()), title: "Chart", subtitle: "2 series"),
            for: sessionID
        )
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(chartCards(in: pane.view).count, 1, "the chart should be shown")

        _ = pane.activateBrowser(for: sessionID)
        pane.view.layoutSubtreeIfNeeded()
        for card in chartCards(in: pane.view) {
            var chain: [String] = []
            var node: NSView? = card
            while let current = node, current !== pane.view {
                chain.append("\(type(of: current)) hidden=\(current.isHidden)")
                node = current.superview
            }
            print("LEFTOVER CHART PATH: \(chain.joined(separator: " ← "))")
        }
        XCTAssertEqual(
            chartCards(in: pane.view).count, 0,
            "the chart is still in the pane behind the tab that replaced it"
        )
    }

    /// The pane must stay resizable while a chart is in it.
    ///
    /// Reported from the running app: with a chart open the window could not be made shorter
    /// until the tab was closed. A required height inside pane content becomes the window's own
    /// minimum, so the card states a *preference* and lets the pane scroll instead.
    func testAChartImposesNoRequiredHeightOnThePaneThatHoldsIt() throws {
        let card = ChartCardView(spec: comparison())
        let required = requiredHeightConstraints(in: card)
        XCTAssertEqual(
            required, [],
            "a required height in pane content raises the window's minimum size"
        )

        // And it must actually survive being squeezed to a fraction of what it prefers. The host
        // states its size with anchors: a detached fixture with only a frame constrains nothing,
        // and lays its content out at the size that content would prefer.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(card)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 420),
            host.heightAnchor.constraint(equalToConstant: 120),
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.frame.height, 120, accuracy: 1)
    }

    private func chartCards(in view: NSView) -> [ChartCardView] {
        var found: [ChartCardView] = []
        if let card = view as? ChartCardView { found.append(card) }
        for subview in view.subviews { found.append(contentsOf: chartCards(in: subview)) }
        return found
    }

    private func requiredHeightConstraints(in view: NSView) -> [String] {
        var found: [String] = []
        for constraint in view.constraints
        where constraint.priority == .required
            && (constraint.firstAttribute == .height || constraint.secondAttribute == .height) {
            found.append(constraint.description)
        }
        for subview in view.subviews {
            found.append(contentsOf: requiredHeightConstraints(in: subview))
        }
        return found
    }

    // MARK: - Contrast

    /// The chart's words have to be readable on the ground they are drawn on.
    ///
    /// Measured rather than asserted against a role name, because the role is only half the
    /// answer — the other half is what the surface under it resolves to in that appearance. The
    /// first version of this chart drew its axis in `tertiary`, which comes out at 3.03:1 on
    /// white: correct by the design system's vocabulary and too faint to read.
    func testChartTextClearsTheContrastFloorInBothAppearances() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let bitmap = try render(comparison(), appearance: appearanceName)
            let measured = try XCTUnwrap(
                dominantTextContrast(in: bitmap),
                "no text found in the rendered chart"
            )
            XCTAssertGreaterThanOrEqual(
                measured, 3.5,
                "chart text is \(measured):1 against its own ground in \(appearanceName.rawValue)"
            )
        }
    }

    /// The most common grey that is not the background — the core of the axis glyphs — against
    /// the background, as a WCAG contrast ratio.
    private func dominantTextContrast(in bitmap: NSBitmapImageRep) -> Double? {
        var counts: [NSColor: Int] = [:]
        var background: NSColor?
        var backgroundCount = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 1) {
                guard let colour = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                let count = (counts[colour] ?? 0) + 1
                counts[colour] = count
                if count > backgroundCount {
                    backgroundCount = count
                    background = colour
                }
            }
        }
        guard let background else { return nil }

        // Greys only: a coloured pixel is a bar, and a bar is not text.
        let text = counts
            .filter { colour, _ in
                colour != background
                    && abs(colour.redComponent - colour.greenComponent) < 0.03
                    && abs(colour.greenComponent - colour.blueComponent) < 0.03
                    && contrast(colour, background) > 1.5
            }
            .max { $0.value < $1.value }?
            .key
        return text.map { contrast($0, background) }
    }

    private func contrast(_ one: NSColor, _ other: NSColor) -> Double {
        func luminance(_ colour: NSColor) -> Double {
            func channel(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.03928
                    ? value / 12.92
                    : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(colour.redComponent)
                + 0.7152 * channel(colour.greenComponent)
                + 0.0722 * channel(colour.blueComponent)
        }
        let first = luminance(one)
        let second = luminance(other)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func render(
        _ spec: ChartSpec,
        appearance appearanceName: NSAppearance.Name
    ) throws -> NSBitmapImageRep {
        let appearance = NSAppearance(named: appearanceName)
        var bitmap: NSBitmapImageRep?
        let draw = {
            let card = self.laidOut(ChartCardView(spec: spec))
            card.appearance = appearance
            AppThemeRefresh.repaint(card)
            card.layoutSubtreeIfNeeded()
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return }
            card.cacheDisplay(in: card.bounds, to: rep)
            bitmap = rep
        }
        if #available(macOS 11.0, *) {
            appearance?.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        return try XCTUnwrap(bitmap)
    }

    // MARK: - Rendered state

    /// Appearance is reviewed here by looking at it: several bugs in this codebase were visible
    /// in a picture and in no assertion anyone would have written.
    func testRendersTheChartStorybook() throws {
        let directory: URL = {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var stacked = comparison(stacked: true)
        stacked.title = "Turn cost by part"
        stacked.series = zip(["Input", "Output"], stacked.series).map { name, entry in
            ChartSpec.Series(name: name, values: entry.values, details: nil, emphasis: nil)
        }

        let ranking = ChartSpec(
            title: "Slowest tests", summary: nil, kind: .ranking,
            categories: ["ReflowTests", "ConversationRenderTests", "GitReviewTests", "ThemeTests"],
            series: [
                ChartSpec.Series(
                    name: "Duration", values: [12.4, 9.1, 4.6, 1.2], details: nil, emphasis: nil
                )
            ],
            stacked: false, valueFormat: .number, unit: "s", maximumValue: nil
        )

        var written = 0
        for (story, spec) in [
            ("01-grouped", comparison()),
            ("02-stacked", stacked),
            ("03-ranking", ranking),
            ("04-single-series", single(values: [8, 22, 15, 4], categories: ["a", "b", "c", "d"]))
        ] {
            written += try write(story: story, spec: spec, to: directory)
        }

        XCTAssertEqual(written, 8, "Every story should render in both appearances")
        print("Rendered chart storybook to \(directory.path)")
    }

    private func write(story: String, spec: ChartSpec, to directory: URL) throws -> Int {
        var written = 0
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            var data: Data?
            let render = {
                let card = self.laidOut(ChartCardView(spec: spec))
                card.appearance = appearance
                AppThemeRefresh.repaint(card)
                card.layoutSubtreeIfNeeded()
                card.wantsLayer = true
                card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

                guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else {
                    return
                }
                card.cacheDisplay(in: card.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }

            if #available(macOS 11.0, *) {
                appearance?.performAsCurrentDrawingAppearance(render)
            } else {
                render()
            }

            let image = try XCTUnwrap(data, "Failed to render \(story) in \(name)")
            try image.write(to: directory.appendingPathComponent("chart-\(story)-\(name).png"))
            written += 1
        }
        return written
    }
}

// MARK: - Accuracy for arrays

private func XCTAssertEqual(
    _ actual: [Double],
    _ expected: [Double],
    accuracy: Double,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (index, pair) in zip(actual, expected).enumerated() {
        XCTAssertEqual(
            pair.0, pair.1, accuracy: accuracy,
            "element \(index)", file: file, line: line
        )
    }
}
