import XCTest
@testable import Threading

// MARK: - Conversation Minimap Motion

/// The turn rail with the pointer moving, frame by frame.
///
/// The taper is the only thing on this control that moves, and no still can say whether it moves
/// *smoothly*. That matters here because the bug this guards against passes every still: widths
/// were sampled at the mark the pointer was **nearest**, so the pointer crossed most of the gap
/// between two marks with the picture unchanged, and then every mark in the taper took a new width
/// in one frame. Each individual screenshot looked correct. Only the sequence was wrong.
///
/// So these tests capture a sequence and assert on the property a screenshot has no way to hold:
/// that consecutive frames differ. `renderFrames` writes them out as well (under
/// `THREADING_RENDER_OUT`, like the other render tests) so the motion can be watched rather than
/// only asserted.
///
/// No window is ordered on screen — the fixture window exists because the ramp refuses to run
/// outside one, and stays unshown. Frames call the real drawing boundary directly rather than
/// relying on an unshown layer's display cache. This belongs in `fast`.
@MainActor
final class ConversationMinimapMotionTests: XCTestCase {

    private enum Fixture {
        static let turnCount = 12
        static let paneHeight: CGFloat = 600
        static let railWidth: CGFloat = 40

        /// Two points per frame across four mark spacings: fine enough that the old sampling
        /// would repeat frames for most of it, coarse enough to stay watchable.
        static let sweepStep: CGFloat = 2
        static let sweepSpan = 4 * ConversationMinimap.Metrics.markerSpacing

        static let rampFrames = 12
    }

    private var window: NSWindow?

    override func tearDown() {
        Design.Motion.reduceMotionOverrideForTesting = nil
        // The rail's ramp driver retains it. Leaving the window is what stands it down.
        window?.contentView = nil
        window = nil
        super.tearDown()
    }

    // MARK: - The Sweep

    func testTheTaperMovesWithThePointerRatherThanWithTheMarkItIsNearest() throws {
        let rail = makeRail()
        openTaper(on: rail)

        let sweep = try sweepFrames(on: rail, snappedToMarks: false)
        let stepped = try sweepFrames(on: rail, snappedToMarks: true)

        try write(sweep, named: "minimap-sweep-after")
        try write(stepped, named: "minimap-sweep-before")

        // The regression, stated in pixels. Sampling at the nearest mark can only produce as many
        // distinct pictures as there are marks the pointer passed; following the pointer produces
        // one per position it was actually at.
        let smoothly = Set(sweep).count
        let steppily = Set(stepped).count
        XCTAssertGreaterThan(
            smoothly, steppily,
            "The taper produced no more pictures than there were marks — it is still snapping"
        )

        for (index, pair) in zip(sweep, sweep.dropFirst()).enumerated() {
            XCTAssertNotEqual(
                pair.0, pair.1,
                "Frames \(index) and \(index + 1) are identical: the taper held still while the pointer moved \(Fixture.sweepStep)pt"
            )
        }
    }

    // MARK: - The Ramp

    func testTheTaperOpensAndClosesOverTimeRatherThanCuttingToIt() throws {
        Design.Motion.reduceMotionOverrideForTesting = false

        let rail = makeRail()
        let opening = try rampFrames(on: rail, opening: true)
        let closing = try rampFrames(on: rail, opening: false)

        try write(opening, named: "minimap-ramp-open")
        try write(closing, named: "minimap-ramp-close")

        XCTAssertNotEqual(opening.first, opening.last, "The taper never opened")
        XCTAssertNotEqual(closing.first, closing.last, "The taper never closed")
        XCTAssertGreaterThan(
            Set(opening).count, 2,
            "Opening produced two pictures, which is a cut with extra steps rather than a ramp"
        )

        // Where it ends is the resting rail — the same picture as one that was never pointed at.
        let untouched = try drawing(of: makeRail())
        XCTAssertEqual(closing.last, untouched, "The taper closed to something other than rest")
    }

    func testUnderReduceMotionTheTaperLandsRatherThanRamping() throws {
        Design.Motion.reduceMotionOverrideForTesting = true

        let rail = makeRail()
        let opening = try rampFrames(on: rail, opening: true)

        XCTAssertEqual(
            Set(opening).count, 1,
            "Reduce Motion still got a ramp: every frame should already be the arrived state"
        )
    }

    // MARK: - Fixture

    private func makeRail() -> ConversationMinimapView {
        let rail = ConversationMinimapView(frame: NSRect(
            x: 0, y: 0, width: Fixture.railWidth, height: Fixture.paneHeight
        ))
        rail.setTurns((0..<Fixture.turnCount).map {
            ConversationTimeline.Turn(
                rowIndex: $0,
                endIndex: $0,
                finalAssistantIndex: $0,
                userText: "Question \($0)",
                assistantText: "Answer \($0)",
                duration: nil
            )
        })

        // The ramp refuses to run outside a window, so there is one. It is never ordered on
        // screen: an unshown window still lays out and still draws through `cacheDisplay`.
        let host = NSView(frame: rail.bounds)
        host.appearance = NSAppearance(named: .darkAqua)
        host.addSubview(rail)
        let window = NSWindow(
            contentRect: rail.bounds, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window

        // The rail paints marks and nothing behind them, and its own fade is a separate concern
        // from the taper. Both are settled by hand so each frame is a picture of the taper only.
        rail.layer?.backgroundColor = Design.Surface.ground.cgColor
        rail.alphaValue = 1
        host.layoutSubtreeIfNeeded()
        return rail
    }

    private var railTop: CGFloat {
        let height = ConversationMinimap.railHeight(
            turnCount: Fixture.turnCount, paneHeight: Fixture.paneHeight
        )
        return (Fixture.paneHeight - height) / 2
    }

    /// Brings the taper fully open without filming the ramp, so a sweep is a picture of pointer
    /// tracking alone.
    private func openTaper(on rail: ConversationMinimapView) {
        Design.Motion.reduceMotionOverrideForTesting = true
        rail.mouseEntered(with: pointerEvent(on: rail, atRailY: railTop))
        Design.Motion.reduceMotionOverrideForTesting = false
        rail.alphaValue = 1
    }

    // MARK: - Frames

    private func sweepFrames(
        on rail: ConversationMinimapView,
        snappedToMarks: Bool
    ) throws -> [Data] {
        let height = ConversationMinimap.railHeight(
            turnCount: Fixture.turnCount, paneHeight: Fixture.paneHeight
        )
        let start = railTop + height / 2 - Fixture.sweepSpan / 2

        return try stride(from: 0, through: Fixture.sweepSpan, by: Fixture.sweepStep).map { offset in
            var y = start + offset

            // The old behaviour, reproduced through the same drawing code rather than described:
            // a pointer that only ever reports the centre of the mark it is nearest *is* sampling
            // by nearest mark. Nothing about the view is stubbed to get it.
            if snappedToMarks {
                let marks = ConversationMinimap.markCount(
                    turnCount: Fixture.turnCount, railHeight: height
                )
                let nearest = ConversationMinimap.mark(
                    atY: y - railTop, markCount: marks, railHeight: height
                ) ?? 0
                y = railTop + ConversationMinimap.markerCenterY(
                    mark: nearest, markCount: marks, railHeight: height
                )
            }

            rail.mouseMoved(with: pointerEvent(on: rail, atRailY: y))
            return try drawing(of: rail)
        }
    }

    private func rampFrames(on rail: ConversationMinimapView, opening: Bool) throws -> [Data] {
        let midRail = railTop + ConversationMinimap.railHeight(
            turnCount: Fixture.turnCount, paneHeight: Fixture.paneHeight
        ) / 2

        if !opening {
            // Closing starts from open, and the opening it starts from is not part of the film.
            Design.Motion.reduceMotionOverrideForTesting = true
            rail.mouseEntered(with: pointerEvent(on: rail, atRailY: midRail))
            Design.Motion.reduceMotionOverrideForTesting = false
        }

        let duration = opening ? Design.Motion.quick : Design.Motion.vanish
        if opening {
            rail.mouseEntered(with: pointerEvent(on: rail, atRailY: midRail))
        } else {
            rail.mouseExited(with: pointerEvent(on: rail, atRailY: midRail))
        }

        return try (0...Fixture.rampFrames).map { frame in
            if duration > 0 {
                let phase = CGFloat(frame) / CGFloat(Fixture.rampFrames)
                rail.advanceFisheye(toPhase: phase)
            }
            rail.alphaValue = 1
            return try drawing(of: rail)
        }
    }

    private func pointerEvent(on rail: NSView, atRailY y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: rail.convert(NSPoint(x: rail.bounds.midX, y: y), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: rail.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) ?? NSEvent()
    }

    /// What the rail actually drew, as bytes.
    ///
    /// A layer-backed view hands `cacheDisplay` whatever its layer already holds. On macOS 26 an
    /// unshown window can keep that cache after `display()`, so this fixture supplies a bitmap
    /// context and calls the view's real drawing boundary synchronously for every requested state.
    private func drawing(of rail: NSView) throws -> Data {
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(rail.bounds.width * scale)),
            pixelsHigh: max(1, Int(rail.bounds.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = rail.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        rail.effectiveAppearance.performAsCurrentDrawingAppearance {
            rail.draw(rail.bounds)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: - Output

    private func write(_ frames: [Data], named name: String) throws {
        // The same resolution the other render tests use, so one environment variable redirects
        // every rendered output in the suite.
        let root = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)

        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (index, frame) in frames.enumerated() {
            let file = directory.appendingPathComponent(String(format: "%03d.png", index))
            try frame.write(to: file)
        }
    }
}
