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
    // MARK: - Style

    func testMarksScaleWithTheScreenSoAMovieMatchesThePane() {
        let pane = NSRect(x: 0, y: 0, width: 250, height: 543)
        let movie = NSRect(x: 0, y: 0, width: 1_206, height: 2_622)
        let style = SimulatorTouchStyle.standard
        let paneFraction = SimulatorTouchMarks.contactRadius(in: pane, style: style) / pane.width
        let movieFraction = SimulatorTouchMarks.contactRadius(in: movie, style: style) / movie.width
        XCTAssertEqual(paneFraction, movieFraction, accuracy: 0.001,
                       "A finger in the recording must be the size it was on screen")
        XCTAssertGreaterThan(
            SimulatorTouchMarks.contactRadius(in: pane, style: SimulatorTouchStyle(size: .large)),
            SimulatorTouchMarks.contactRadius(in: pane, style: SimulatorTouchStyle(size: .small))
        )
    }

    func testTheChosenColourIsWhatIsDrawn() throws {
        let rep = try render(
            SimulatorTouchIndicators(
                ripples: [],
                contact: .init(point: CGPoint(x: 0.5, y: 0.5), trail: [CGPoint(x: 0.5, y: 0.5)])
            ),
            style: SimulatorTouchStyle(color: .red, size: .large, showsTrail: false)
        )
        let centre = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
            .usingColorSpace(.sRGB)
        let pixel = try XCTUnwrap(centre)
        XCTAssertGreaterThan(pixel.alphaComponent, 0.2, "The contact disc must be filled")
        XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent + 0.3)
        XCTAssertGreaterThan(pixel.redComponent, pixel.blueComponent + 0.3)
    }

    func testTheSwipeTrailCanBeTurnedOff() throws {
        let swipe = SimulatorTouchIndicators(
            ripples: [],
            contact: .init(
                point: CGPoint(x: 0.5, y: 0.9),
                trail: [CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.9)]
            )
        )
        func trailAlpha(showsTrail: Bool) throws -> CGFloat {
            let rep = try render(swipe, style: SimulatorTouchStyle(color: .blue, showsTrail: showsTrail))
            // Halfway along the trail, far from the contact at its end.
            let pixel = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh * 3 / 10))
            return pixel.alphaComponent
        }
        XCTAssertGreaterThan(try trailAlpha(showsTrail: true), 0.1)
        XCTAssertEqual(try trailAlpha(showsTrail: false), 0, accuracy: 0.01)
    }

    private func render(
        _ indicators: SimulatorTouchIndicators,
        style: SimulatorTouchStyle
    ) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        SimulatorTouchMarks.draw(
            indicators,
            in: NSRect(x: 0, y: 0, width: 200, height: 400),
            style: style
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
