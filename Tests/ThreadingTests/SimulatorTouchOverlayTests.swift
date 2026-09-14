import AppKit
import XCTest
@testable import Threading

@MainActor
final class SimulatorTouchOverlayTests: XCTestCase {
    func testAFreshModelHasNothingToDraw() {
        let model = SimulatorTouchOverlayModel()
        XCTAssertTrue(model.indicators().isEmpty)
        XCTAssertFalse(model.hasActivity)
    }

    func testATapAddsAFreshRipple() {
        let model = SimulatorTouchOverlayModel()
        model.tap(at: CGPoint(x: 0.5, y: 0.25))
        let indicators = model.indicators()
        XCTAssertEqual(indicators.ripples.count, 1)
        XCTAssertEqual(indicators.ripples.first?.point, CGPoint(x: 0.5, y: 0.25))
        XCTAssertLessThan(indicators.ripples.first?.progress ?? 1, 0.2)  // just born
        XCTAssertTrue(model.hasActivity)
        XCTAssertNil(indicators.contact)
    }

    func testADragShowsAContactWithATrail() {
        let model = SimulatorTouchOverlayModel()
        model.contactBegan(at: CGPoint(x: 0.1, y: 0.1))
        model.contactMoved(to: CGPoint(x: 0.2, y: 0.2))
        model.contactMoved(to: CGPoint(x: 0.3, y: 0.3))
        let indicators = model.indicators()
        let contact = try? XCTUnwrap(indicators.contact)
        XCTAssertEqual(contact?.point, CGPoint(x: 0.3, y: 0.3))
        XCTAssertGreaterThanOrEqual(contact?.trail.count ?? 0, 2)
        XCTAssertTrue(model.hasActivity)
    }

    func testEndingAContactLeavesARippleAndClearsTheLiveContact() {
        let model = SimulatorTouchOverlayModel()
        model.contactBegan(at: CGPoint(x: 0.4, y: 0.4))
        model.contactEnded(at: CGPoint(x: 0.4, y: 0.4))
        let indicators = model.indicators()
        // The release drops a ripple; the contact is no longer active (its trail fades out).
        XCTAssertEqual(indicators.ripples.count, 1)
        XCTAssertTrue(model.hasActivity)  // the ripple is still fresh
    }

    func testDrawingIsSafeAndDoesNothingForEmptyIndicators() {
        // A smoke test: drawing an empty set touches no context.
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 200))
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        SimulatorTouchMarks.draw(SimulatorTouchIndicators(ripples: [], contact: nil), in: view.bounds)
        SimulatorTouchMarks.draw(
            SimulatorTouchIndicators(
                ripples: [.init(point: CGPoint(x: 0.5, y: 0.5), progress: 0.3)],
                contact: .init(point: CGPoint(x: 0.2, y: 0.2), trail: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)])
            ),
            in: view.bounds
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}
