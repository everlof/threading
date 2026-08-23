import AppKit
import XCTest
@testable import Threading

/// What a mark answers to the pointer.
///
/// A scene's marks were hit-tested against their bounding rectangles while being drawn as
/// circles. Nothing about that was visible in an assertion — every test that existed placed
/// rectangles, where the box *is* the mark — and it only became wrong once a hierarchy started
/// packing circles: tangent circles have overlapping boxes, so the corners of one leaf's box are
/// places where its parent or its neighbour is the thing on screen.
@MainActor
final class SemanticSceneHitTests: XCTestCase {

    // MARK: - The shape itself

    func testACirclesBoundingBoxCornerIsNotTheCircle() {
        let circle = SemanticSceneView.Item.Shape.ellipse
        let frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(circle.contains(NSPoint(x: 50, y: 50), in: frame))
        // Either side of the rim on the diagonal: 50 ± 50/√2 is 85.36.
        XCTAssertTrue(circle.contains(NSPoint(x: 85, y: 85), in: frame))
        XCTAssertFalse(circle.contains(NSPoint(x: 86, y: 86), in: frame))
        // The corners of the box, which is where a neighbouring mark's box reaches.
        XCTAssertFalse(circle.contains(NSPoint(x: 96, y: 96), in: frame))
        XCTAssertFalse(circle.contains(NSPoint(x: 4, y: 96), in: frame))
    }

    /// A mark's shape decides its own answer: a rectangle is still its whole box. The point was
    /// never to make hit testing stricter in general.
    func testARectangleIsStillItsWholeBox() {
        let rectangle = SemanticSceneView.Item.Shape.rectangle
        let frame = NSRect(x: 10, y: 10, width: 40, height: 20)
        XCTAssertTrue(rectangle.contains(NSPoint(x: 10, y: 10), in: frame))
        XCTAssertTrue(rectangle.contains(NSPoint(x: 49, y: 29), in: frame))
        XCTAssertFalse(rectangle.contains(NSPoint(x: 51, y: 29), in: frame))
    }

    func testARoundedRectangleGivesUpOnlyItsCorners() {
        let rounded = SemanticSceneView.Item.Shape.roundedRectangle
        let frame = NSRect(x: 0, y: 0, width: 120, height: 60)
        XCTAssertGreaterThan(
            rounded.cornerRadius(in: frame),
            2,
            "the fixture needs a corner big enough to cut something away"
        )
        XCTAssertTrue(
            rounded.contains(NSPoint(x: 60, y: 1), in: frame),
            "the flat middle of an edge is inside"
        )
        XCTAssertFalse(
            rounded.contains(NSPoint(x: 0.5, y: 0.5), in: frame),
            "the square corner the arc cuts away is not"
        )
    }

    // MARK: - The mark under the pointer

    /// The failure this prevents, stated as the scene a hierarchy actually draws: two circles
    /// inside a parent, near enough to tangency that their bounding boxes overlap while the
    /// circles do not. The overlap is somewhere only the parent is drawn, and it used to activate
    /// whichever sibling happened to be painted last.
    func testAPointInTwoOverlappingBoxesAndNeitherCircleIsTheParent() throws {
        var activated: [String] = []
        let scene = packing { activated.append($0) }
        let window = host(scene)

        try click(scene, at: windowPoint(x: 155, y: 197), in: window)
        XCTAssertEqual(activated, ["parent"])

        // The middle of a sibling is still that sibling.
        try click(scene, at: windowPoint(x: 120, y: 120), in: window)
        XCTAssertEqual(activated, ["parent", "left"])
    }

    /// Hover follows the same rule, because the highlight and the pointing-hand cursor are a
    /// promise that a click will land there. Offering them over a mark that will not answer is
    /// worse than offering nothing.
    func testHoverDoesNotClaimAMarkThePointerIsNotOver() throws {
        let scene = packing { _ in }
        let window = host(scene)

        scene.mouseMoved(with: try event(
            .mouseMoved,
            at: windowPoint(x: 120, y: 120),
            in: window
        ))
        XCTAssertEqual(scene.toolTip, "left", "the middle of a circle is that circle")

        scene.mouseMoved(with: try event(
            .mouseMoved,
            at: windowPoint(x: 155, y: 197),
            in: window
        ))
        XCTAssertEqual(scene.toolTip, "parent")
    }

    // MARK: - Fixture

    /// Three circles on a 400-point canvas. After the canvas's one-point mark gap: `parent` is
    /// centred at (200, 200) with radius 199, `left` at (120, 120) with radius 79, and `right` at
    /// (240, 240) with radius 89. The two children are 169.7 apart and their radii sum to 168, so
    /// they do not touch — while their boxes share the square from (151, 151) to (199, 199).
    private func packing(
        _ activate: @escaping (String) -> Void
    ) -> SemanticSceneView {
        SemanticSceneView(
            accessibilityLabel: "Packing",
            items: [
                mark("parent", NSRect(x: 0, y: 0, width: 1, height: 1), activate),
                mark("left", NSRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4), activate),
                mark("right", NSRect(x: 0.375, y: 0.375, width: 0.45, height: 0.45), activate)
            ]
        )
    }

    private func mark(
        _ id: String,
        _ frame: NSRect,
        _ activate: @escaping (String) -> Void
    ) -> SemanticSceneView.Item {
        SemanticSceneView.Item(
            id: id,
            normalizedFrame: frame,
            shape: .ellipse,
            color: .accent,
            label: id,
            detail: nil,
            accessibilityLabel: id,
            accessibilityValue: nil,
            isEnabled: true,
            isSelected: false,
            onActivate: { activate(id) }
        )
    }

    /// The canvas is flipped, so a point read off the fixture's own geometry has to be turned
    /// back over to become a location in the window an event carries.
    private func windowPoint(x: CGFloat, y: CGFloat) -> NSPoint {
        NSPoint(x: x, y: Fixture.side - y)
    }

    private enum Fixture {
        static let side: CGFloat = 400
    }

    /// Unshown, per the fast-lane rule: the scene lays out and hit-tests without the window
    /// server, and nothing here asks who holds the keyboard.
    private func host(_ scene: SemanticSceneView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Fixture.side, height: Fixture.side),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = scene
        scene.frame = NSRect(x: 0, y: 0, width: Fixture.side, height: Fixture.side)
        scene.layoutSubtreeIfNeeded()
        return window
    }

    private func click(
        _ scene: SemanticSceneView,
        at location: NSPoint,
        in window: NSWindow
    ) throws {
        scene.mouseDown(with: try event(.leftMouseDown, at: location, in: window))
        scene.mouseUp(with: try event(.leftMouseUp, at: location, in: window))
    }

    private func event(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
