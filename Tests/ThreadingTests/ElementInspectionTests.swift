import XCTest
@testable import Threading

/// The inspector's decisions, tested without a window: which view a point means, and what
/// the two reports say about a capture.
@MainActor
final class ElementInspectionTests: XCTestCase {

    // MARK: - Fixtures

    private final class ProbeView: NSView {}
    private final class InnerProbeView: NSView {}

    /// A 100×100 root holding `back` and `front`, overlapping between (20,20) and (60,60).
    private func makeTree() -> (root: NSView, back: NSView, front: NSView) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let back = NSView(frame: NSRect(x: 10, y: 10, width: 50, height: 50))
        let front = NSView(frame: NSRect(x: 20, y: 20, width: 40, height: 40))
        root.addSubview(back)
        root.addSubview(front)
        return (root, back, front)
    }

    // MARK: - Hit Testing

    func testPicksFrontmostViewWhereTwoOverlap() {
        let (root, _, front) = makeTree()

        XCTAssertIdentical(ElementHitTest.topmost(in: root, at: NSPoint(x: 30, y: 30)), front)
    }

    func testPicksBackViewWhereFrontDoesNotReach() {
        let (root, back, _) = makeTree()

        XCTAssertIdentical(ElementHitTest.topmost(in: root, at: NSPoint(x: 12, y: 12)), back)
    }

    func testPicksDeepestDescendant() {
        let (root, _, front) = makeTree()
        let inner = InnerProbeView(frame: NSRect(x: 5, y: 5, width: 10, height: 10))
        front.addSubview(inner)

        // (27, 27) in root space is (7, 7) in front's space — inside inner.
        XCTAssertIdentical(ElementHitTest.topmost(in: root, at: NSPoint(x: 27, y: 27)), inner)
    }

    func testSkipsHiddenViews() {
        let (root, back, front) = makeTree()
        front.isHidden = true

        XCTAssertIdentical(ElementHitTest.topmost(in: root, at: NSPoint(x: 30, y: 30)), back)
    }

    /// The sidebar crossfades its hover controls to zero alpha rather than hiding them; a
    /// hit test that admitted those would report a control the user cannot see.
    func testSkipsFullyTransparentViews() {
        let (root, back, front) = makeTree()
        front.alphaValue = 0

        XCTAssertIdentical(ElementHitTest.topmost(in: root, at: NSPoint(x: 30, y: 30)), back)
    }

    func testFallsBackToTheContainerItself() {
        let (root, _, _) = makeTree()

        XCTAssertIdentical(ElementHitTest.topmost(in: root, at: NSPoint(x: 90, y: 90)), root)
    }

    /// The bug that forced smallest-wins: macOS layers pane-sized chrome *above* content —
    /// a `_NSCoreHostingView` glass sheet over the whole sidebar — and frontmost-wins
    /// stopped at it, so no row was ever reachable. The most specific view is the answer,
    /// however deep it sits and whatever floats above it.
    func testDrillsThroughPaneSizedChromeToTheContentBehindIt() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        let row = ProbeView(frame: NSRect(x: 0, y: 500, width: 300, height: 30))
        let label = InnerProbeView(frame: NSRect(x: 20, y: 5, width: 100, height: 16))
        content.addSubview(row)
        row.addSubview(label)
        let glass = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        root.addSubview(content)
        root.addSubview(glass)

        XCTAssertIdentical(ElementHitTest.topmost(in: root, at: NSPoint(x: 60, y: 510)), label)
        XCTAssertIdentical(ElementHitTest.topmost(in: root, at: NSPoint(x: 250, y: 510)), row)
    }

    func testMissesOutsideTheContainer() {
        let (root, _, _) = makeTree()

        XCTAssertNil(ElementHitTest.topmost(in: root, at: NSPoint(x: 150, y: 150)))
    }

    // MARK: - Element Report

    func testReportWalksTheViewChainLeafToRoot() {
        let (root, _, front) = makeTree()
        let inner = InnerProbeView(frame: NSRect(x: 5, y: 5, width: 10, height: 10))
        front.addSubview(inner)

        let report = ElementReport.build(for: inner)

        XCTAssertEqual(report.viewChain.map(\.className), ["InnerProbeView", "NSView", "NSView"])
        XCTAssertEqual(report.target.className, "InnerProbeView")
        _ = root
    }

    /// A view controller sits on its view's responder chain, which is how the report maps a
    /// pixel to a source file — the chain names the types this project defines.
    func testReportFindsControllersOnTheResponderChain() {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let child = ProbeView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        controller.view.addSubview(child)

        let report = ElementReport.build(for: child)

        XCTAssertEqual(report.controllers, ["NSViewController"])
    }

    func testReportDropsAppKitGeneratedIdentifiers() {
        let named = ProbeView(frame: .zero)
        named.identifier = NSUserInterfaceItemIdentifier("session-row")
        let generated = ProbeView(frame: .zero)
        generated.identifier = NSUserInterfaceItemIdentifier("_NS:123")

        XCTAssertEqual(ElementReport.build(for: named).target.identifier, "session-row")
        XCTAssertNil(ElementReport.build(for: generated).target.identifier)
    }

    func testElementMarkdownNamesTargetChainAndScreenshot() {
        let (_, _, front) = makeTree()
        let inner = InnerProbeView(frame: NSRect(x: 5, y: 5, width: 10, height: 10))
        front.addSubview(inner)

        var report = ElementReport.build(for: inner)
        report.screenshotPath = "/tmp/threading-inspect-test.png"
        let markdown = report.markdown

        XCTAssertTrue(markdown.hasPrefix("## Element report — InnerProbeView"))
        XCTAssertTrue(markdown.contains("InnerProbeView → NSView → NSView"))
        XCTAssertTrue(markdown.contains("10×10"))
        XCTAssertTrue(markdown.contains("/tmp/threading-inspect-test.png"))
    }

    func testElementMarkdownOmitsWhatWasNotCaptured() {
        let view = ProbeView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))

        let markdown = ElementReport.build(for: view).markdown

        XCTAssertFalse(markdown.contains("screenshot"))
        XCTAssertFalse(markdown.contains("Identifier"))
        XCTAssertFalse(markdown.contains("Controllers"))
    }

    // MARK: - Point Report

    /// The report speaks both coordinate spaces: AppKit's bottom-left for code, and the
    /// screenshot's top-left for anyone reading the image.
    func testPointReportFlipsIntoScreenshotCoordinates() {
        let report = PointReport(
            point: NSPoint(x: 512, y: 100),
            windowSize: NSSize(width: 1440, height: 900),
            screenshotPath: nil
        )

        XCTAssertEqual(report.pointFromTopLeft, NSPoint(x: 512, y: 800))
        XCTAssertTrue(report.markdown.contains("(512, 100) in window"))
        XCTAssertTrue(report.markdown.contains("(512, 800) from top-left"))
        XCTAssertTrue(report.markdown.contains("1440×900"))
    }

    // MARK: - Snapshot Annotation

    /// Pins the AppKit behaviour `WindowSnapshot.annotate` is built on: a graphics context
    /// made from a bitmap rep speaks the rep's `size` units — points — and maps them onto
    /// the backing pixels itself. The first version added its own backing-scale transform on
    /// top, which drew every marker displaced and doubled on retina; this is the measurement
    /// that found it, kept so a macOS that changes the contract fails loudly.
    func testBitmapContextSpeaksTheRepsSizeUnits() throws {
        let bounds = NSRect(x: 0, y: 0, width: 100, height: 50)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = bounds.size

        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.red.setFill()
        NSRect(x: 10, y: 10, width: 20, height: 10).fill()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        // A point rect at (10, 10, 20, 10) on a 2× rep must land at pixels x 20..<60 and,
        // in `colorAt`'s top-left rows, 60..<80. Landing at double that means the context
        // has stopped honouring `size` and annotate needs its transform back.
        func isRed(_ x: Int, _ y: Int) -> Bool {
            guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                return false
            }
            return colour.redComponent > 0.9 && colour.greenComponent < 0.1
        }

        XCTAssertTrue(isRed(30, 70), "point-space drawing should land at 2× the pixel offset")
        XCTAssertFalse(isRed(70, 45), "landing here means the context is being scaled twice")
        XCTAssertFalse(isRed(10, 90), "outside the rect entirely")
    }

    /// A sidebar split item's material is drawn for the window from outside the process, so a
    /// `cacheDisplay` capture writes opaque white across the whole column and the sidebar's own
    /// light-on-dark rows vanish into it. Every report was shipping a screenshot with a blank
    /// band where the sidebar should be, which is worse than no screenshot: it looks like a
    /// rendering bug in the app rather than in the capture.
    @MainActor
    func testCaptureSuppliesTheSidebarGroundTheWindowServerDrew() throws {
        let original = WindowBackdrop.ground
        defer { WindowBackdrop.set(original) }
        WindowBackdrop.set(.terminal(NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)))

        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: NSViewController()))
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.contentViewController = split
        // Assigning a content view controller resizes the window to its fitting size, so the
        // intended size lands afterwards — the same order `applyInitialFrame` keeps.
        window.setContentSize(NSSize(width: 600, height: 300))
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(WindowSnapshot.capture(window: window, annotating: nil))

        // Two samples down the sidebar's column: its pane, and the strip above it where the
        // traffic lights float over a full-height sidebar.
        for y in [rep.pixelsHigh / 2, rep.pixelsHigh / 12] {
            let pixel = try XCTUnwrap(rep.colorAt(x: 40, y: y)?.usingColorSpace(.sRGB))
            XCTAssertLessThan(
                pixel.brightnessComponent,
                0.5,
                "the sidebar column captured as white at row \(y) — its ground is missing again"
            )
        }
    }

    func testPointMarkdownCarriesTheScreenshotPathWhenPresent() {
        var report = PointReport(
            point: .zero,
            windowSize: NSSize(width: 100, height: 100),
            screenshotPath: nil
        )
        // "In the screenshot" names the coordinate space and is always there; the *path*
        // line is the one that must only appear once a capture actually landed.
        XCTAssertFalse(report.markdown.contains("Window screenshot"))

        report.screenshotPath = "/tmp/threading-inspect-point.png"
        XCTAssertTrue(report.markdown.contains("/tmp/threading-inspect-point.png"))
    }

    // MARK: - Report Composition

    /// The note leads the copied report — a chat reads the instruction before the evidence —
    /// and an empty or whitespace note leaves the report exactly as it was.
    func testCopiedReportLeadsWithTheNote() {
        let markdown = "## Element report — ProbeView"

        XCTAssertEqual(
            InspectorReportComposer.compose(note: "  make this padding smaller  ", markdown: markdown),
            "make this padding smaller\n\n## Element report — ProbeView"
        )
        XCTAssertEqual(InspectorReportComposer.compose(note: "", markdown: markdown), markdown)
        XCTAssertEqual(InspectorReportComposer.compose(note: "   \n", markdown: markdown), markdown)
    }

    // MARK: - Region Report

    func testRegionRectIsBuiltFromAnyTwoCorners() {
        let expected = NSRect(x: 10, y: 20, width: 30, height: 40)

        let downRight = InspectorGeometry.rect(from: NSPoint(x: 10, y: 60), to: NSPoint(x: 40, y: 20))
        let upLeft = InspectorGeometry.rect(from: NSPoint(x: 40, y: 20), to: NSPoint(x: 10, y: 60))

        XCTAssertEqual(downRight, expected)
        XCTAssertEqual(upLeft, expected)
    }

    // MARK: - Mode

    /// One command, and ⇧ is what suppresses detection while it is held. The chord that used
    /// to be the second command still opens freeflow for exactly this reason: invoking ⌥⇧⌘I
    /// arrives with ⇧ down, and the overlay reads the keyboard rather than the menu item.
    func testModeIsReadFromTheShiftKey() {
        XCTAssertEqual(InspectorMode.held([]), .element)
        XCTAssertEqual(InspectorMode.held(.shift), .freeflow)
        // The layer modifiers do not change which mode is showing, only what is drawn on it.
        XCTAssertEqual(InspectorMode.held([.control, .option]), .element)
        XCTAssertEqual(InspectorMode.held([.shift, .control]), .freeflow)
    }

    // MARK: - Layers

    func testLayersReadTheModifiersHeld() {
        XCTAssertEqual(InspectorLayers.held([]), [])
        XCTAssertEqual(InspectorLayers.held(.control), .hierarchy)
        XCTAssertEqual(InspectorLayers.held(.option), .spacing)
        XCTAssertEqual(InspectorLayers.held([.control, .option]), [.hierarchy, .spacing])
        // A modifier the inspector says nothing about changes nothing.
        XCTAssertEqual(InspectorLayers.held([.command, .shift]), [])
    }

    // MARK: - Hierarchy Levels

    /// A wrapper that exactly fills its parent is *one rectangle on screen*, so it is one
    /// level with two names — a second outline over the same pixels and a second legend row
    /// claim there are two things to look at when there is one.
    func testCoincidentWrappersCollapseIntoOneLevel() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let wrapper = ProbeView(frame: NSRect(x: 20, y: 20, width: 100, height: 60))
        let filling = InnerProbeView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
        root.addSubview(wrapper)
        wrapper.addSubview(filling)

        let levels = InspectorHierarchy.levels(for: filling)

        XCTAssertEqual(levels.count, 2)
        XCTAssertEqual(levels[0].classNames, ["InnerProbeView", "ProbeView"])
        XCTAssertEqual(levels[0].title, "InnerProbeView = ProbeView")
        XCTAssertEqual(levels[0].depth, 0)
        XCTAssertEqual(levels[1].classNames, ["NSView"])
        XCTAssertEqual(levels[1].depth, 1)
    }

    /// Views land on half points routinely, so "the same rectangle" is a tolerance.
    func testHalfPointDriftStillReadsAsOneRectangle() {
        XCTAssertTrue(InspectorHierarchy.coincide(
            NSRect(x: 10, y: 10, width: 100, height: 40),
            NSRect(x: 10.5, y: 10, width: 99.5, height: 40)
        ))
        XCTAssertFalse(InspectorHierarchy.coincide(
            NSRect(x: 10, y: 10, width: 100, height: 40),
            NSRect(x: 8, y: 10, width: 104, height: 40)
        ))
    }

    func testLevelsRunLeafOutwardWithRectsInWindowSpace() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let middle = ProbeView(frame: NSRect(x: 20, y: 20, width: 120, height: 100))
        let leaf = InnerProbeView(frame: NSRect(x: 10, y: 10, width: 40, height: 20))
        root.addSubview(middle)
        middle.addSubview(leaf)

        let levels = InspectorHierarchy.levels(for: leaf)

        XCTAssertEqual(levels.map(\.depth), [0, 1, 2])
        XCTAssertEqual(levels.map(\.title), ["InnerProbeView", "ProbeView", "NSView"])
        XCTAssertEqual(levels[0].rect, NSRect(x: 30, y: 30, width: 40, height: 20))
        XCTAssertEqual(levels[1].rect, NSRect(x: 20, y: 20, width: 120, height: 100))
    }

    /// ⌥ alone is the common ask — "why is this inset like that" — and a measure needs
    /// something to measure to, so it draws one level out and stops there.
    func testShownLevelsFollowWhatIsHeld() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let middle = ProbeView(frame: NSRect(x: 20, y: 20, width: 120, height: 100))
        let leaf = InnerProbeView(frame: NSRect(x: 10, y: 10, width: 40, height: 20))
        root.addSubview(middle)
        middle.addSubview(leaf)
        let levels = InspectorHierarchy.levels(for: leaf)

        XCTAssertEqual(InspectorHierarchy.shown(levels, for: []).count, 1)
        XCTAssertEqual(InspectorHierarchy.shown(levels, for: .spacing).count, 2)
        XCTAssertEqual(InspectorHierarchy.shown(levels, for: .hierarchy).count, 3)
        XCTAssertEqual(InspectorHierarchy.shown(levels, for: [.hierarchy, .spacing]).count, 3)
    }

    /// Hue means depth, and the ramp is shorter than a real view chain — so it cycles, and
    /// the numbered chip on each rectangle is what tells depth 0 from depth 6.
    func testDepthHuesCycleThroughTheCategoricalRamp() {
        let count = Design.Categorical.hues.count

        XCTAssertEqual(Design.Categorical.hue(at: 0).name, Design.Categorical.hues[0].name)
        XCTAssertEqual(Design.Categorical.hue(at: count).name, Design.Categorical.hues[0].name)
        XCTAssertEqual(Design.Categorical.hue(at: count + 1).name, Design.Categorical.hues[1].name)
        XCTAssertEqual(Design.Categorical.ramp.count, count)
    }

    // MARK: - Spacing

    /// Most views are pinned flush to at least one edge, and drawing `0` around a fitted view
    /// is a number saying nothing. Only a gap someone chose earns a line.
    func testGapsDropFlushEdgesAndKeepChosenOnes() {
        let gaps = InspectorSpacing.gaps(
            from: NSRect(x: 12, y: 0, width: 76, height: 40),
            to: NSRect(x: 0, y: 0, width: 100, height: 40)
        )

        XCTAssertEqual(gaps.map(\.edge), [.leading, .trailing])
        XCTAssertEqual(gaps.map(\.label), ["12", "12"])
        XCTAssertEqual(InspectorSpacing.describe(gaps), "leading 12 · trailing 12")
        XCTAssertEqual(InspectorSpacing.describe([]), InspectorStrings.flushOnEverySide)
    }

    /// The one measurement here that is a bug rather than a value to judge: a child wider
    /// than the box holding it. It is reported, negative, rather than filtered out.
    func testGapReportsAnOverflowAsNegative() {
        let gaps = InspectorSpacing.gaps(
            from: NSRect(x: -8, y: 4, width: 120, height: 32),
            to: NSRect(x: 0, y: 0, width: 100, height: 40)
        )

        XCTAssertEqual(
            gaps.first { $0.edge == .leading }?.label,
            "-8"
        )
        XCTAssertEqual(gaps.first { $0.edge == .trailing }?.label, "-12")
    }

    func testMeasureLinesSpanTheGapTheyName() {
        let gaps = InspectorSpacing.gaps(
            from: NSRect(x: 20, y: 10, width: 60, height: 20),
            to: NSRect(x: 0, y: 0, width: 100, height: 50)
        )

        let leading = try? XCTUnwrap(gaps.first { $0.edge == .leading })
        XCTAssertEqual(leading?.start, NSPoint(x: 0, y: 20))
        XCTAssertEqual(leading?.end, NSPoint(x: 20, y: 20))
        XCTAssertEqual(leading?.isHorizontal, true)

        let top = try? XCTUnwrap(gaps.first { $0.edge == .top })
        XCTAssertEqual(top?.start, NSPoint(x: 50, y: 30))
        XCTAssertEqual(top?.end, NSPoint(x: 50, y: 50))
        XCTAssertEqual(top?.isHorizontal, false)
    }

    func testGapsAreMeasuredBetweenEveryConsecutivePair() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let middle = ProbeView(frame: NSRect(x: 20, y: 20, width: 120, height: 100))
        let leaf = InnerProbeView(frame: NSRect(x: 10, y: 10, width: 40, height: 20))
        root.addSubview(middle)
        middle.addSubview(leaf)

        let pairs = InspectorSpacing.gaps(across: InspectorHierarchy.levels(for: leaf))

        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].parent.title, "ProbeView")
        XCTAssertEqual(pairs[1].parent.title, "NSView")
    }

    // MARK: - Hierarchy Report

    /// The screenshot carries the hierarchy as *colours*, which nobody reading the text can
    /// see and no agent can name. The legend is what turns "the orange one is too wide" into
    /// a class to open.
    func testHierarchyMarkdownNamesEachColourAgainstItsClass() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let middle = ProbeView(frame: NSRect(x: 20, y: 20, width: 120, height: 100))
        let leaf = InnerProbeView(frame: NSRect(x: 10, y: 10, width: 40, height: 20))
        root.addSubview(middle)
        middle.addSubview(leaf)

        let markdown = ElementReport.build(for: leaf, layers: .hierarchy).markdown

        XCTAssertTrue(markdown.contains("- Hierarchy, target outward"))
        XCTAssertTrue(markdown.contains("Blue · 0 · InnerProbeView"))
        XCTAssertTrue(markdown.contains("Orange · 1 · ProbeView"))
        XCTAssertTrue(markdown.contains("Purple · 2 · NSView"))
        // Spacing was not held, so no measures are claimed for a screenshot without them.
        XCTAssertFalse(markdown.contains("- Spacing"))
    }

    func testSpacingMarkdownNamesTheParentTheGapLivesIn() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let middle = ProbeView(frame: NSRect(x: 20, y: 20, width: 120, height: 100))
        let leaf = InnerProbeView(frame: NSRect(x: 10, y: 10, width: 40, height: 20))
        root.addSubview(middle)
        middle.addSubview(leaf)

        let markdown = ElementReport.build(for: leaf, layers: .spacing).markdown

        XCTAssertTrue(markdown.contains("- Spacing, inside each parent"))
        XCTAssertTrue(markdown.contains("InnerProbeView inside ProbeView: "))
        XCTAssertTrue(markdown.contains("leading 10"))
        // ⌥ alone draws one level out, so it must not describe a pair it never drew.
        XCTAssertFalse(markdown.contains("inside NSView"))
    }

    /// A plain pick is the report it always was: nothing was drawn in colour, so nothing
    /// claims a colour was.
    func testPlainPickCarriesNoLegend() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let leaf = ProbeView(frame: NSRect(x: 10, y: 10, width: 40, height: 20))
        root.addSubview(leaf)

        let markdown = ElementReport.build(for: leaf).markdown

        XCTAssertFalse(markdown.contains("Hierarchy"))
        XCTAssertFalse(markdown.contains("Spacing"))
    }

    func testRegionReportFlipsIntoScreenshotCoordinates() {
        let report = RegionReport(
            rect: NSRect(x: 100, y: 100, width: 200, height: 50),
            windowSize: NSSize(width: 1440, height: 900),
            screenshotPath: "/tmp/threading-inspect-region.png"
        )

        XCTAssertEqual(
            report.rectFromTopLeft,
            NSRect(x: 100, y: 750, width: 200, height: 50)
        )
        XCTAssertTrue(report.markdown.contains("200×50 at (100, 100) in window"))
        XCTAssertTrue(report.markdown.contains("200×50 at (100, 750) from top-left"))
        XCTAssertTrue(report.markdown.contains("/tmp/threading-inspect-region.png"))
    }

    // MARK: - Control Hint

    /// Every control stays on the line whatever is held, so the hint is a fixed list rather
    /// than a thing that reshuffles under the pointer. What changes is the emphasis.
    func testHintNamesEveryControlAndMarksWhatIsHeld() {
        let levels = InspectorHierarchy.levels(for: makeTree().front)

        let idle = InspectorHint.tokens(for: .element(levels: levels, layers: []))
        XCTAssertEqual(
            idle.map(\.text),
            [
                InspectorStrings.pointHint,
                InspectorStrings.regionHint,
                InspectorStrings.hierarchyHint,
                InspectorStrings.spacingHint,
                InspectorStrings.exitHint
            ]
        )
        XCTAssertTrue(idle.allSatisfy { $0.emphasis == .available })

        let held = InspectorHint.tokens(for: .element(levels: levels, layers: .hierarchy))
        XCTAssertEqual(held.map(\.text), idle.map(\.text), "the line does not reshuffle")
        XCTAssertEqual(
            held.first { $0.text == InspectorStrings.hierarchyHint }?.emphasis,
            .held,
            "the hint doubles as a readout of what is on"
        )
        XCTAssertEqual(
            held.first { $0.text == InspectorStrings.spacingHint }?.emphasis,
            .available
        )
    }

    /// Nothing is detected under ⇧ or mid-drag, so ⌃ and ⌥ have no element to layer onto. They
    /// stay listed and read as off — a control that vanishes reads as a control that broke.
    func testHintCallsTheLayerModifiersOffWhereNothingIsDetected() {
        let point = InspectorHint.tokens(for: .point(NSPoint(x: 10, y: 10), label: "(10, 10)"))
        let region = InspectorHint.tokens(
            for: .region(NSRect(x: 0, y: 0, width: 40, height: 20), label: "40×20")
        )

        for tokens in [point, region] {
            XCTAssertEqual(
                tokens.first { $0.text == InspectorStrings.hierarchyHint }?.emphasis,
                .inapplicable
            )
            XCTAssertEqual(
                tokens.first { $0.text == InspectorStrings.spacingHint }?.emphasis,
                .inapplicable
            )
            XCTAssertEqual(
                tokens.first { $0.text == InspectorStrings.exitHint }?.emphasis,
                .available,
                "Esc backs out of everything"
            )
        }

        XCTAssertEqual(point.first { $0.text == InspectorStrings.pointHint }?.emphasis, .held)
        XCTAssertEqual(region.first { $0.text == InspectorStrings.regionHint }?.emphasis, .held)
    }

    /// The key takes the bottom corner away from the pick; the hint takes the other one. The
    /// two therefore divide the window between them, and neither jumps when ⌃ is pressed.
    func testTheHintTakesTheBottomCornerTheKeyDoesNot() {
        let bounds = NSRect(x: 0, y: 0, width: 720, height: 460)
        let levels = [
            InspectorLevel(
                depth: 0,
                rect: NSRect(x: 600, y: 300, width: 60, height: 24),
                classNames: ["ProbeView"],
                address: "0x0",
                identifier: nil
            )
        ]
        let indicator = InspectorIndicator.element(levels: levels, layers: .hierarchy)

        XCTAssertEqual(
            InspectorLegendPlacement.preferredCorner(target: levels[0].rect, within: bounds),
            .bottomLeading,
            "a pick on the right pushes the key left"
        )
        XCTAssertEqual(
            InspectorHint.preferredCorner(for: indicator, within: bounds),
            .bottomTrailing
        )
    }

    // MARK: - Panel Placement

    /// The requested corner when it is clear — the rule the key has always followed.
    func testAPanelTakesItsPreferredCornerWhenNothingIsInTheWay() {
        let bounds = NSRect(x: 0, y: 0, width: 720, height: 460)
        let size = NSSize(width: 200, height: 60)

        let placement = InspectorPanelPlacement.place(
            size: size,
            preferring: .bottomTrailing,
            avoiding: [NSRect(x: 40, y: 300, width: 100, height: 40)],
            within: bounds
        )

        XCTAssertFalse(placement.isObstructed)
        XCTAssertEqual(
            placement.rect,
            InspectorPanelPlacement.rect(size: size, corner: .bottomTrailing, within: bounds)
        )
    }

    /// The point of the change: a panel pinned to one corner covers the capture whenever the
    /// capture is in that corner, which is exactly when the picture matters most.
    func testAPanelStepsAsideWhenItsPreferredCornerIsCovered() {
        let bounds = NSRect(x: 0, y: 0, width: 720, height: 460)
        let size = NSSize(width: 200, height: 60)
        let preferred = InspectorPanelPlacement.rect(
            size: size,
            corner: .bottomTrailing,
            within: bounds
        )

        let placement = InspectorPanelPlacement.place(
            size: size,
            preferring: .bottomTrailing,
            avoiding: [preferred],
            within: bounds
        )

        XCTAssertFalse(placement.isObstructed)
        XCTAssertNotEqual(placement.rect, preferred)
        XCTAssertFalse(placement.rect.intersects(preferred))
    }

    /// A drag across the whole window covers every corner. Moving is then no longer an answer,
    /// so it fades in place: a panel that keeps running away is worse than one to read through.
    func testAPanelFadesInPlaceWhenEveryCornerIsCovered() {
        let bounds = NSRect(x: 0, y: 0, width: 720, height: 460)
        let size = NSSize(width: 200, height: 60)

        let placement = InspectorPanelPlacement.place(
            size: size,
            preferring: .bottomLeading,
            avoiding: [bounds],
            within: bounds
        )

        XCTAssertTrue(placement.isObstructed)
        XCTAssertEqual(
            placement.rect,
            InspectorPanelPlacement.rect(size: size, corner: .bottomLeading, within: bounds),
            "it stays where it was asked to be and is drawn faded instead"
        )
    }
}
