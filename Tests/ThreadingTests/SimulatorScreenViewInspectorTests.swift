import AppKit
import XCTest
@testable import Threading

@MainActor
final class SimulatorScreenViewInspectorTests: XCTestCase {
    /// A view whose bounds match the image's aspect ratio, so the fitted framebuffer fills the
    /// bounds and a normalized frame maps predictably (no letterboxing to reason about).
    private func makeView() -> SimulatorScreenView {
        let view = SimulatorScreenView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        view.image = NSImage(size: NSSize(width: 200, height: 400))
        return view
    }

    private func annotation(_ frame: CGRect, name: String) -> SimulatorScreenView.ElementAnnotation {
        .init(normalizedFrame: frame, label: name, name: name, copyText: name, emphasized: true)
    }

    func testOptionClickAddsOneNoteWithoutTouchingTheDeviceOrEnablingMode() throws {
        let view = makeView()
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        view.interactionState = .ready(touch: true, keyboard: true)
        var notes: [CGPoint] = []
        var taps: [CGPoint] = []
        view.onAddNote = { notes.append($0) }
        view.onTap = { taps.append($0) }
        let point = view.convert(CGPoint(x: 100, y: 200), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: .option,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
            if type == .leftMouseDown { view.mouseDown(with: event) }
            else { view.mouseUp(with: event) }
        }
        XCTAssertEqual(notes, [CGPoint(x: 0.5, y: 0.5)])
        XCTAssertTrue(taps.isEmpty)
        XCTAssertFalse(view.isAnnotatingNotes)
    }

    func testAnnotationModeAccessibilityPressAddsANoteInsteadOfTapping() {
        let view = makeView()
        view.isAnnotatingNotes = true
        var note: CGPoint?
        view.onAddNote = { note = $0 }
        view.onTap = { _ in XCTFail("Annotation press reached the device") }
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(note, CGPoint(x: 0.5, y: 0.5))
    }

    func testHoverPicksTheSmallestContainingElement() {
        let view = makeView()
        view.annotations = [
            annotation(CGRect(x: 0, y: 0, width: 1, height: 1), name: "root"),
            annotation(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), name: "inner"),
        ]
        // Device centre (0.5, 0.5) → view (100, 200); both contain it, so the inner one wins.
        XCTAssertEqual(view.annotationIndex(under: CGPoint(x: 100, y: 200)), 1)
    }

    func testHoverFallsBackToAnOuterElementWhereNoInnerOneCovers() {
        let view = makeView()
        view.annotations = [
            annotation(CGRect(x: 0, y: 0, width: 1, height: 1), name: "root"),
            annotation(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), name: "inner"),
        ]
        // Near the top-left corner only the full-screen element covers the point.
        XCTAssertEqual(view.annotationIndex(under: CGPoint(x: 10, y: 390)), 0)
    }

    func testPointOutsideTheFramebufferHasNoHover() {
        let view = makeView()
        view.annotations = [annotation(CGRect(x: 0, y: 0, width: 1, height: 1), name: "root")]
        XCTAssertNil(view.annotationIndex(under: CGPoint(x: -5, y: 200)))
    }

    func testNoAnnotationsMeansNoHover() {
        let view = makeView()
        XCTAssertNil(view.annotationIndex(under: CGPoint(x: 100, y: 200)))
    }

    func testMouseWheelSendsScrollDeltasOnlyWhenScreenAcceptsInput() throws {
        let view = makeView()
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        window.setFrameOrigin(.zero)
        view.interactionState = .ready(touch: true, keyboard: true)
        var requests: [(point: CGPoint, delta: CGPoint)] = []
        view.onScroll = { point, x, y in
            requests.append((point, CGPoint(x: x, y: y)))
        }

        let wheel = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 3,
            wheel2: -2,
            wheel3: 0
        ))
        wheel.flags = []
        // CGEvent uses a top-left global origin; NSEvent exposes the corresponding AppKit point.
        let screenTop = try XCTUnwrap(NSScreen.main).frame.maxY
        wheel.location = CGPoint(x: 100, y: screenTop - 200)
        let event = try XCTUnwrap(NSEvent(cgEvent: wheel))
        view.scrollWheel(with: event)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.point, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(requests.first?.delta, CGPoint(x: -2, y: 3))

        view.isAnnotatingNotes = true
        view.scrollWheel(with: event)
        XCTAssertEqual(requests.count, 1)
    }

    func testTheInspectorOverlayRendersInBothAppearances() throws {
        for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)] {
            let view = makeView()
            view.appearance = appearance
            view.annotations = [
                annotation(CGRect(x: 0, y: 0, width: 1, height: 1), name: "AXApplication · App"),
                annotation(CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.06), name: "AXButton · Go"),
            ]
            let representation = try XCTUnwrap(
                view.bitmapImageRepForCachingDisplay(in: view.bounds)
            )
            // Drawing the overlay (all-bounds context; a hover badge needs an event) must not crash.
            view.cacheDisplay(in: view.bounds, to: representation)
            XCTAssertNotNil(representation.representation(using: .png, properties: [:]))
        }
    }
}
