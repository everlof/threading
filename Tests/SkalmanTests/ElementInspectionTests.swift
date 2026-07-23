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
}
