import AppKit
import XCTest
@testable import Threading

/// What a chart says when it has nothing to plot.
///
/// The two states it can be in are the whole point: "nothing was measured" is a finished answer
/// and stands still, "the sources are being read" is a promise and has to show the work. Both used
/// to be one grey sentence drawn across a value axis that printed 0/0.2/0.5/0.8/1 for a domain
/// nobody had measured anything in.
@MainActor
final class ThemedChartPlaceholderTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.set(.system)
        Design.Motion.reduceMotionOverrideForTesting = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func chart(_ model: ThemedChartModel) -> ThemedTimeSeriesChartView {
        let view = ThemedTimeSeriesChartView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        view.appearance = NSAppearance(named: .darkAqua)
        view.setModel(model, animated: false)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func emptyModel(
        placeholder: ThemedChartPlaceholder = .empty,
        detail: String? = "Cost and tokens appear here once an agent session has run."
    ) -> ThemedChartModel {
        ThemedChartModel(
            title: "Daily usage",
            accessibilitySummary: "Nothing measured",
            series: [],
            emptyMessage: "No usage recorded yet",
            emptyDetail: detail,
            placeholder: placeholder
        )
    }

    private func populatedModel() -> ThemedChartModel {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        return ThemedChartModel(
            title: "Daily usage",
            accessibilitySummary: "Measured",
            series: [ThemedChartSeries(
                id: "one",
                title: "One",
                points: (0..<12).map {
                    ThemedChartPoint(
                        at: start.addingTimeInterval(Double($0) * 86_400),
                        value: Double($0 % 5) + 1
                    )
                },
                style: .primary,
                fillsArea: true
            )]
        )
    }

    // MARK: - When it appears

    func testAChartWithDataBuildsNoPlaceholderAtAll() {
        let view = chart(populatedModel())
        XCTAssertFalse(view.showsPlaceholder)
        XCTAssertNil(
            view.placeholderViewForTesting,
            "a chart that never lacked data must not construct the status subtree"
        )
    }

    func testAnEmptySeriesStillCountsAsNothingToPlot() {
        let model = ThemedChartModel(
            title: "Daily usage",
            accessibilitySummary: "",
            series: [ThemedChartSeries(id: "one", title: "One", points: [])]
        )
        XCTAssertTrue(chart(model).showsPlaceholder)
    }

    func testDataArrivingTakesThePlaceholderAway() {
        let view = chart(emptyModel())
        XCTAssertEqual(view.placeholderViewForTesting?.isHidden, false)
        view.setModel(populatedModel(), animated: false)
        XCTAssertEqual(
            view.placeholderViewForTesting?.isHidden,
            true,
            "the status must not stay over a chart that now has marks under it"
        )
    }

    func testThePlaceholderCoversThePlotRatherThanTheWholeControl() throws {
        let view = chart(emptyModel())
        view.layoutSubtreeIfNeeded()
        let placeholder = try XCTUnwrap(view.placeholderViewForTesting)
        // Inset by the axis gutters on both sides: the message belongs where the marks would be.
        XCTAssertGreaterThanOrEqual(placeholder.frame.minX, Design.Chart.axisLeading)
        XCTAssertLessThan(placeholder.frame.maxY, view.bounds.maxY)
    }

    // MARK: - The value axis

    func testAnEmptyChartPrintsNoValueTicks() {
        XCTAssertEqual(
            chart(populatedModel()).valueAxisLabels.count,
            Design.Chart.gridLineCount,
            "a chart with data labels its value axis"
        )
        XCTAssertTrue(
            chart(emptyModel()).valueAxisLabels.isEmpty,
            "an empty chart used to print 0/0.2/0.5/0.8/1, which is the automatic domain "
                + "describing itself rather than anything anyone measured"
        )
    }

    func testTheTicksComeBackWithTheData() {
        let view = chart(emptyModel())
        XCTAssertTrue(view.valueAxisLabels.isEmpty)
        view.setModel(populatedModel(), animated: false)
        XCTAssertEqual(view.valueAxisLabels.count, Design.Chart.gridLineCount)
    }

    // MARK: - Loading

    func testLoadingShowsADeterminateBarAndEmptyDoesNot() throws {
        let loading = chart(emptyModel(placeholder: .loading(progress: 0.25), detail: "Claude Code"))
        let bar = try XCTUnwrap(
            loading.placeholderViewForTesting?.progressBarForTesting,
            "a scan with a known total reports how far it has got"
        )
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.progress, 0.25, accuracy: 0.001)

        let counting = chart(emptyModel(placeholder: .loading(progress: nil)))
        XCTAssertEqual(
            counting.placeholderViewForTesting?.progressBarForTesting?.isHidden,
            true,
            "a bar pinned at zero for the length of the count is worse than no bar"
        )

        let empty = chart(emptyModel())
        XCTAssertEqual(empty.placeholderViewForTesting?.progressBarForTesting?.isHidden, true)
    }

    func testAnOutOfRangeFractionIsClamped() throws {
        let view = chart(emptyModel(placeholder: .loading(progress: 4.2)))
        let bar = try XCTUnwrap(view.placeholderViewForTesting?.progressBarForTesting)
        XCTAssertEqual(bar.progress, 1, accuracy: 0.001)
    }

    /// The component gallery constructs the complete retained catalogue before its document has
    /// a viewport. A chart therefore owns a real zero-width placeholder for one layout pass.
    /// Required negative-width constraints used to make every gallery test emit AppKit's
    /// unsatisfiable-constraints warning before settling at its final width.
    func testAZeroWidthConstructionPassHasNoImpossibleRequiredWidthsAndRecovers() throws {
        let placeholder = ThemedChartPlaceholderView(frame: .zero)
        placeholder.show(.loading(progress: 0.5), title: "Reading usage", detail: "Claude Code")

        placeholder.layoutSubtreeIfNeeded()
        let progress = try XCTUnwrap(placeholder.progressBarForTesting)
        func constraints(in view: NSView) -> [NSLayoutConstraint] {
            view.constraints + view.subviews.flatMap { constraints(in: $0) }
        }
        let authored: [String: NSLayoutConstraint] = Dictionary(
            uniqueKeysWithValues: constraints(in: placeholder).compactMap {
                constraint -> (String, NSLayoutConstraint)? in
                guard let identifier = constraint.identifier,
                      identifier.hasPrefix("chartPlaceholder.") else { return nil }
                return (identifier, constraint)
            }
        )
        XCTAssertEqual(authored["chartPlaceholder.preferredInsetWidth"]?.priority, .defaultHigh)
        XCTAssertEqual(
            authored["chartPlaceholder.hardWidthCeiling"]?.constant,
            0,
            "the required ceiling must remain satisfiable while the owner is zero wide"
        )
        XCTAssertEqual(authored["chartPlaceholder.hardWidthCeiling"]?.priority, .required)
        XCTAssertLessThan(
            authored["chartPlaceholder.preferredProgressWidth"]?.priority.rawValue ?? .infinity,
            NSLayoutConstraint.Priority.required.rawValue,
            "the progress bar's preferred width must be allowed to collapse"
        )
        XCTAssertEqual(authored["chartPlaceholder.progressHardCeiling"]?.priority, .required)

        placeholder.frame.size = NSSize(width: 420, height: 180)
        placeholder.layoutSubtreeIfNeeded()
        XCTAssertEqual(progress.frame.width, 132, accuracy: 0.001)
        XCTAssertLessThanOrEqual(progress.frame.maxX, placeholder.bounds.maxX)
    }

    func testTheGhostBreathesOnlyWhileWorkIsInFlight() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        defer { window.orderOut(nil) }

        let view = chart(emptyModel(placeholder: .loading(progress: 0.5)))
        window.contentView?.addSubview(view)
        let placeholder = try XCTUnwrap(view.placeholderViewForTesting)
        XCTAssertTrue(placeholder.isBreathing, "hosted in a window, the ghost breathes")

        Design.Motion.reduceMotionOverrideForTesting = true
        NotificationCenter.default.post(AccessibilityDisplayOptionsDidChange())
        XCTAssertFalse(
            placeholder.isBreathing,
            "Reduce Motion removes the perpetual animation rather than slowing it"
        )
        XCTAssertFalse(placeholder.isHidden, "the silhouette stays: it is the status")

        Design.Motion.reduceMotionOverrideForTesting = false
        NotificationCenter.default.post(AccessibilityDisplayOptionsDidChange())
        XCTAssertTrue(placeholder.isBreathing)

        view.setModel(emptyModel(), animated: false)
        XCTAssertFalse(
            placeholder.isBreathing,
            "a finished answer stands still; only work in flight moves"
        )
    }

    // MARK: - Appearance

    func testItDrawsInkUnderSystemAndTwoStyledThemes() throws {
        for theme in [.system, AppThemeStyles.cyberpunk, AppThemeStyles.swissMinimalist] {
            AppThemePalette.set(theme)
            let view = chart(emptyModel(placeholder: .loading(progress: 0.4)))
            let placeholder = try XCTUnwrap(view.placeholderViewForTesting)
            AppThemeRefresh.repaint(view)
            view.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(
                placeholder.bitmapImageRepForCachingDisplay(in: placeholder.bounds)
            )
            placeholder.cacheDisplay(in: placeholder.bounds, to: rep)
            var inked = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 4) where
                    (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    inked += 1
                }
            }
            XCTAssertGreaterThan(inked, 20, "the placeholder drew nothing under \(theme.name)")
        }
    }

    func testALiveThemeSwitchReachesTheLabels() throws {
        AppThemePalette.set(.system)
        let view = chart(emptyModel(placeholder: .loading(progress: 0.5)))
        // In a window, unshown: AppKit keeps no pending display for a view with nowhere to draw,
        // so a windowless fixture answers `needsDisplay` false however often it is invalidated.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(view)
        let placeholder = try XCTUnwrap(view.placeholderViewForTesting)
        placeholder.needsDisplay = false

        // What `AppThemeLibrary.apply` does: swap the palette, then say so. The palette alone is
        // a silent store, which is exactly why every drawn component subscribes to the event.
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.cyberpunk.id))
        XCTAssertTrue(
            placeholder.needsDisplay,
            "the label ink is applied rather than drawn, so the switch has to reach it"
        )
    }

    /// The silhouette is drawn from a role, so a material that answers that role differently must
    /// change the picture. Classic Player is the sharpest case: its analyzer well has no neutral
    /// grey in it, and the ghost is drawn in the accent it already glows with.
    func testTheGhostFollowsTheMaterialItIsDrawnIn() throws {
        var pictures: [Data] = []
        for theme in [AppTheme.system, AppThemeStyles.classicPlayer] {
            AppThemePalette.set(theme)
            let view = chart(emptyModel(placeholder: .loading(progress: 0.5)))
            let band = try XCTUnwrap(view.placeholderViewForTesting).bandForTesting
            AppThemeRefresh.repaint(view)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(band.bitmapImageRepForCachingDisplay(in: band.bounds))
            band.cacheDisplay(in: band.bounds, to: rep)
            pictures.append(try XCTUnwrap(rep.representation(using: .png, properties: [:])))
        }
        XCTAssertNotEqual(
            pictures.first,
            pictures.last,
            "the ghost drew the same ink under two materials that state different ones"
        )
    }

    // MARK: - Interaction and accessibility

    func testThePlaceholderIsNotATarget() throws {
        let view = chart(emptyModel())
        view.layoutSubtreeIfNeeded()
        let placeholder = try XCTUnwrap(view.placeholderViewForTesting)
        XCTAssertNil(
            placeholder.hitTest(NSPoint(x: placeholder.bounds.midX, y: placeholder.bounds.midY)),
            "the chart underneath keeps its own hover and selection"
        )
        XCTAssertFalse(placeholder.isAccessibilityElement())
    }

    func testTheChartStillAnswersWithTheStatus() {
        let view = chart(emptyModel())
        XCTAssertEqual(view.accessibilityValue() as? String, "Nothing measured")
    }
}
