import XCTest
@testable import Skalman

/// The inspector's decisions, tested without a window: which view a point means, and what
/// the two reports say about a capture.
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
        report.screenshotPath = "/tmp/skalman-inspect-test.png"
        let markdown = report.markdown

        XCTAssertTrue(markdown.hasPrefix("## Element report — InnerProbeView"))
        XCTAssertTrue(markdown.contains("InnerProbeView → NSView → NSView"))
        XCTAssertTrue(markdown.contains("10×10"))
        XCTAssertTrue(markdown.contains("/tmp/skalman-inspect-test.png"))
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

    func testPointMarkdownCarriesTheScreenshotPathWhenPresent() {
        var report = PointReport(
            point: .zero,
            windowSize: NSSize(width: 100, height: 100),
            screenshotPath: nil
        )
        // "In the screenshot" names the coordinate space and is always there; the *path*
        // line is the one that must only appear once a capture actually landed.
        XCTAssertFalse(report.markdown.contains("Window screenshot"))

        report.screenshotPath = "/tmp/skalman-inspect-point.png"
        XCTAssertTrue(report.markdown.contains("/tmp/skalman-inspect-point.png"))
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

    func testRegionReportFlipsIntoScreenshotCoordinates() {
        let report = RegionReport(
            rect: NSRect(x: 100, y: 100, width: 200, height: 50),
            windowSize: NSSize(width: 1440, height: 900),
            screenshotPath: "/tmp/skalman-inspect-region.png"
        )

        XCTAssertEqual(
            report.rectFromTopLeft,
            NSRect(x: 100, y: 750, width: 200, height: 50)
        )
        XCTAssertTrue(report.markdown.contains("200×50 at (100, 100) in window"))
        XCTAssertTrue(report.markdown.contains("200×50 at (100, 750) from top-left"))
        XCTAssertTrue(report.markdown.contains("/tmp/skalman-inspect-region.png"))
    }
}
