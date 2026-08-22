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

    // MARK: - How much room a chart takes

    /// A ranking's vertical axis is its *categories*, and a category axis says nothing more for
    /// being taller. Reported from the running app: eight rows in a full-height panel drew eight
    /// 130-point bands that were almost entirely gap.
    func testARankingTakesTheRoomItsRowsNeedRatherThanTheWholePane() throws {
        let spec = ranking(rows: 12)
        let (host, card) = try pane(spec, width: 560, height: 1_000)

        XCTAssertEqual(
            card.frame.height,
            ChartCardView.preferredHeight(for: spec),
            accuracy: 1
        )
        // And the room it did not take is left as ground under it, rather than being distributed
        // into the bands: the card sits at the top of a pane it no longer fills.
        XCTAssertGreaterThan(host.frame.height - card.frame.height, 400)
    }

    /// The transcript's ceiling belongs to the transcript. A row nobody can scroll past is a
    /// reason to cap a chart *inline*; a panel opened to read a forty-row ranking is the one place
    /// it should be forty rows tall.
    func testALongRankingUsesTheWholePaneRatherThanTheTranscriptsCeiling() throws {
        let spec = ranking(rows: 30)
        let (_, card) = try pane(spec, width: 560, height: 1_400)

        XCTAssertGreaterThan(card.frame.height, Design.Chart.maximumCardHeight)
        XCTAssertEqual(
            card.frame.height,
            try XCTUnwrap(ChartCardView.boundedHeight(for: spec)),
            accuracy: 1
        )
        // Inline, the same chart is still capped — the two answers are different on purpose.
        XCTAssertLessThan(
            ChartCardView.preferredHeight(for: spec),
            card.frame.height
        )
    }

    /// The same rule the other way round: a column chart's vertical axis is the **value**, which
    /// is data — a taller plot resolves it better, so that one still takes the pane.
    func testAColumnChartStillUsesTheHeightItIsGiven() throws {
        let (_, card) = try pane(comparison(), width: 560, height: 1_000)

        XCTAssertGreaterThan(card.frame.height, 800)
    }

    /// A bound is a preference, not a floor: a pane shorter than the chart's own height still
    /// gets a chart that fits inside it. (`testAChartImposesNoRequiredHeightOnThePaneThatHoldsIt`
    /// is the other half of this — the window has to stay resizable.)
    func testAPaneShorterThanTheRankingCompressesItRatherThanOverflowing() throws {
        let (host, card) = try pane(ranking(rows: 12), width: 560, height: 220)

        XCTAssertLessThanOrEqual(card.frame.height, host.frame.height)
        XCTAssertGreaterThan(card.frame.height, 100)
    }

    /// **A title is a sentence, not a measurement.** Reported from the running app with a
    /// screenshot: the panel would not be dragged narrower than the title of the chart open in
    /// it, and the title was exactly as wide as the pane.
    ///
    /// A split item is positioned by a constraint at its holding priority — 260 for this panel —
    /// while an `NSTextField` resists compression at 750, so a label held inside the card by a
    /// required `<=` simply outranked the drag. Measured on the reported chart: an 854pt floor
    /// under a panel whose own chrome is 82. The title now ends in an ellipsis, with the whole of
    /// it on the pointer.
    ///
    /// Asserted as *the same floor either way* rather than against a number, because the number
    /// is the pane's own business — it is the chart's two copy controls and the panel's chrome —
    /// while the defect was that it moved with what an agent happened to write.
    func testALongTitleIsNotHowNarrowThePaneMayBe() throws {
        let sentence = "One watch instance costs ~0.9 CPU cores, and most of it is pushing "
            + "pixels — not simulating"
        let floor = DisplayPaneDefaults.slimmestWidth

        let (wordy, card) = try pane(
            titled(sentence),
            width: floor,
            height: 640,
            widthHeldAt: DisplayPaneDefaults.holdingPriority
        )
        let (brief, _) = try pane(
            titled("Cost"),
            width: floor,
            height: 640,
            widthHeldAt: DisplayPaneDefaults.holdingPriority
        )

        XCTAssertEqual(
            wordy.frame.width, brief.frame.width, accuracy: 1,
            "the pane stopped at the width of the title rather than at its own floor"
        )
        XCTAssertLessThan(
            wordy.frame.width, 120,
            "a chart tab may cost the pane its own controls, and nothing else"
        )
        XCTAssertLessThanOrEqual(card.frame.width, wordy.frame.width)
        // The same width is what the *window* is charged: a pane minimum in a split window is the
        // window's own minimum, and `fittingSize` resolves below an ordinary label's resistance
        // rather than above it.
        XCTAssertEqual(wordy.fittingSize.width, brief.fittingSize.width, accuracy: 1)

        // And it gives way with an ellipsis rather than by clipping mid-glyph. Found by looking
        // at the render: only the *string* can make that promise, because attributed content
        // carries its own paragraph style and it outranks the field's line-break mode.
        let title = try XCTUnwrap(labels(in: wordy).first { $0.stringValue == sentence })
        let paragraph = title.attributedStringValue.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(paragraph?.lineBreakMode, .byTruncatingTail)
    }

    private func labels(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let label = view as? NSTextField { found.append(label) }
        for subview in view.subviews { found.append(contentsOf: labels(in: subview)) }
        return found
    }

    /// The reported chart, retitled: two categories, one series, a sentence at the top.
    private func titled(_ title: String) -> ChartSpec {
        ChartSpec(
            title: title,
            summary: nil,
            kind: .bar,
            categories: ["display on", "display off"],
            series: [ChartSpec.Series(
                name: "WebContent", values: [37.6, 30.1], details: nil, emphasis: nil
            )],
            stacked: false,
            valueFormat: .percent,
            unit: nil,
            maximumValue: nil
        )
    }

    /// A tall, narrow pane is not a reason to draw a tall, narrow chart.
    ///
    /// The height of a column chart is its value axis and more of it does resolve the values
    /// better — up to the point where the plot has stopped being a picture. Dragged narrow, the
    /// panel drew 700 points of column over 120 points of plot: bars reduced to threads, with no
    /// room under them for the names of the categories they measure.
    func testATallNarrowPaneGetsBackTheHeightTheChartCannotUse() throws {
        let (host, card) = try pane(comparison(), width: 260, height: 900)
        let plot = card.chartForTesting

        XCTAssertLessThanOrEqual(
            plot.frame.height,
            plot.frame.width * Design.Chart.maximumPlotAspect + 1,
            "the plot is standing taller than its own width allows"
        )
        // What it gave back is ground under the chart, which is the same answer a ranking gives —
        // and it is still a chart, not a sliver: the floor under it holds.
        XCTAssertGreaterThan(host.frame.height - card.frame.height, 200)
        XCTAssertGreaterThanOrEqual(plot.frame.height, Design.Chart.minimumCardHeight)
    }

    /// The cap is about the *value* axis, so the one chart whose height is its categories is
    /// exempt: a ranking in a narrow pane keeps every row rather than compressing thirty of them
    /// into a proportion nobody reads. Same exception, same reason, as `boundedHeight(for:)`.
    func testANarrowPaneStillGivesARankingEveryOneOfItsRows() throws {
        let spec = ranking(rows: 30)
        let (_, card) = try pane(spec, width: 260, height: 1_400)

        XCTAssertEqual(
            card.frame.height,
            try XCTUnwrap(ChartCardView.boundedHeight(for: spec)),
            accuracy: 1
        )
    }

    // MARK: - Taking the chart with you

    /// A chart the reader opened is a chart they want to put in a message, and until now the
    /// only route out of the panel was a screenshot.
    ///
    /// Drawn from the live card rather than re-rendered, so the picture is the theme, the width
    /// and the thinned axis labels they are actually looking at. Written to a pasteboard of this
    /// test's own: a hosted test shares the developer's session, and the general pasteboard is
    /// theirs.
    func testTheChartCanBeTakenAsAPicture() throws {
        let (_, card) = try pane(comparison(), width: 520, height: 620)
        let controller = try XCTUnwrap(panes.last)
        let board = scratchPasteboard()

        XCTAssertTrue(controller.copyPicture(to: board))

        let pasted = try XCTUnwrap(
            board.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage
        )
        // The card, with the air a pane gives it on every side.
        let padding = Design.Spacing.inset * 2
        XCTAssertEqual(pasted.size.width, card.frame.width + padding, accuracy: 1)
        XCTAssertEqual(pasted.size.height, card.frame.height + padding, accuracy: 1)
        XCTAssertTrue(
            isOpaque(pasted),
            "a transparent picture is chart ink on whatever the document underneath happens to be"
        )
    }

    /// The numbers stay one press away too — and they had to move to reach the reader at all.
    ///
    /// They were in the panel's own `⋯` menu, which for a chart tab sits *underneath* the hosted
    /// content: the panel adds that view last, it runs to the foot of the pane, and a chart's
    /// ground is opaque. The action existed and no pointer could reach it.
    func testTheNumbersAreOnTheChartRatherThanUnderTheCoveredMenu() throws {
        _ = try pane(comparison(), width: 520, height: 620)
        let controller = try XCTUnwrap(panes.last)
        let board = scratchPasteboard()

        XCTAssertTrue(controller.copyNumbers(to: board))

        let pasted = try XCTUnwrap(board.string(forType: .string))
        XCTAssertEqual(pasted, comparison().tabSeparatedValues)
    }

    /// Both actions are on the pane itself, where a pointer can reach them.
    func testBothWaysOutAreOfferedOnThePane() throws {
        let (host, _) = try pane(comparison(), width: 520, height: 620)

        let names = iconButtons(in: host).compactMap { $0.accessibilityTitle() }

        XCTAssertTrue(names.contains(L10n.string("Copy the chart as a picture")), "\(names)")
        XCTAssertTrue(names.contains(L10n.string("Copy the numbers behind the chart")), "\(names)")
    }

    private func scratchPasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("threading.chart.tests"))
        board.clearContents()
        return board
    }

    /// Whether every pixel of the picture is fully opaque, sampled at its corners and centre.
    private func isOpaque(_ image: NSImage) -> Bool {
        guard let rep = image.representations.first as? NSBitmapImageRep else { return false }
        let points = [
            (0, 0),
            (rep.pixelsWide - 1, 0),
            (0, rep.pixelsHigh - 1),
            (rep.pixelsWide - 1, rep.pixelsHigh - 1),
            (rep.pixelsWide / 2, rep.pixelsHigh / 2)
        ]
        return points.allSatisfy { rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent == 1 }
    }

    private func iconButtons(in view: NSView) -> [ThemedIconButton] {
        var found: [ThemedIconButton] = []
        if let button = view as? ThemedIconButton { found.append(button) }
        for subview in view.subviews { found.append(contentsOf: iconButtons(in: subview)) }
        return found
    }

    /// A bar's thickness carries no reading — only its length does — so it must not grow with the
    /// container. Below the cap the group keeps its share of the band; above it the band keeps
    /// the slack as gap.
    func testABarStopsThickeningOnceTheBandIsBiggerThanItNeeds() {
        let narrow = Design.Chart.barGroupExtent(band: 40, members: 1)
        let wide = Design.Chart.barGroupExtent(band: 900, members: 1)
        let pair = Design.Chart.barGroupExtent(band: 900, members: 2)

        XCTAssertEqual(narrow, 40 * Design.Chart.barBandFraction, accuracy: 0.001)
        XCTAssertEqual(wide, Design.Chart.maximumBarThickness, accuracy: 0.001)
        // A grouped chart's bars stay adjacent to each other: the cap is per bar, so the group
        // it belongs to may be that much wider rather than being squeezed into one bar's room.
        XCTAssertEqual(pair, Design.Chart.maximumBarThickness * 2, accuracy: 0.001)
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

    /// A ranking of `rows` named places, the shape an agent produces from a disk or timing report.
    private func ranking(rows: Int) -> ChartSpec {
        ChartSpec(
            title: "What is consuming the volume",
            summary: nil,
            kind: .ranking,
            categories: (0..<rows).map { "~/Library/Application Support/place-\($0)" },
            series: [ChartSpec.Series(
                name: "Size",
                values: (0..<rows).map { Double(rows - $0) },
                details: nil,
                emphasis: nil
            )],
            stacked: false,
            valueFormat: .number,
            unit: "GB",
            maximumValue: nil
        )
    }

    /// A chart tab's content at the size a pane gives it.
    ///
    /// The host states its size with anchors and the controller's view fills it, which is exactly
    /// what `DisplayPaneController` does — and, unlike a bare frame, is a claim the layout engine
    /// actually has to satisfy.
    private func pane(
        _ spec: ChartSpec,
        width: CGFloat,
        height: CGFloat,
        widthHeldAt widthPriority: NSLayoutConstraint.Priority = .required
    ) throws -> (NSView, ChartCardView) {
        let controller = ChartPaneViewController(spec: spec, subtitle: "1 series")
        panes.append(controller)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        // A split item is *positioned*, not pinned: `NSSplitViewController` states its width with
        // a constraint at the item's holding priority, which is the number the pane's content is
        // allowed to argue with. Required is the right fixture for a question about height and
        // the wrong one for a question about width — it wins the argument the drag would lose.
        let paneWidth = host.widthAnchor.constraint(equalToConstant: width)
        paneWidth.priority = widthPriority
        NSLayoutConstraint.activate([
            paneWidth,
            host.heightAnchor.constraint(equalToConstant: height),
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return (host, try XCTUnwrap(chartCards(in: host).first))
    }

    /// The controllers the pane fixtures built, kept alive for the length of the test case.
    private var panes: [ChartPaneViewController] = []

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
        let previousTheme = AppThemePalette.current
        AppThemePalette.set(.system)
        defer { AppThemePalette.set(previousTheme) }

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

    /// The most common ink in the value-axis gutter — the core of the axis glyphs — against the
    /// background, as a WCAG contrast ratio.
    ///
    /// Looking across the whole card stopped measuring text once the grid became long enough:
    /// its straight rules contain far more identical pixels than any antialiased glyph, and in
    /// Aqua their neutral-blue tint is close enough to grey to pass the colour guard below. The
    /// value-axis gutter is the surface this assertion is actually about. It contains the tick
    /// labels, while the plot (and therefore every grid rule) starts at `axisLeading`. Its scan
    /// begins at the content inset so the card's long border cannot impersonate a glyph either.
    private func dominantTextContrast(in bitmap: NSBitmapImageRep) -> Double? {
        var counts: [NSColor: Int] = [:]
        var background: NSColor?
        var backgroundCount = 0
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let contentInset = Int((Design.Spacing.inset * scale).rounded(.up))
        let gutterWidth = min(
            bitmap.pixelsWide,
            Int((Design.Chart.axisLeading * scale).rounded(.down))
        )
        let titleHeight = Int((Design.Spacing.pane * scale).rounded(.up))
        let axisTop = max(contentInset, bitmap.pixelsHigh - titleHeight)
        for y in stride(from: contentInset, to: axisTop, by: 1) {
            for x in stride(from: contentInset, to: gutterWidth, by: 1) {
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

        // The gutter contains no marks, so its most common non-ground colour is text. Do not
        // demand a mathematical grey here: styled themes are allowed to tint their label ink.
        let text = counts
            .filter { colour, _ in
                colour != background
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
