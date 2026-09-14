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
