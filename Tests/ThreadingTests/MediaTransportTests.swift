import AppKit
import XCTest
@testable import Threading

/// Behaviour, keyboard, accessibility and live-theme coverage for the two transport components.
///
/// The load-bearing claim of `ThemedScrubber` is that **the travel and the commit are different
/// events**, because everything a player does with them is different: the canvas follows the
/// travel, and only the commit is allowed to cost a seek. Most of this file is that claim, stated
/// once per way the control can be moved — pointer, keyboard, VoiceOver.
@MainActor
final class MediaTransportTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppThemePalette.set(.system)
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Assignment is not a scrub

    /// A player states the position it reached; that is not the user scrubbing to it. A control
    /// that echoed its own assignment back would make a state report a feedback loop — the report
    /// moves the knob, the knob seeks, the seek reports.
    func testAssigningTheValueRaisesNeitherCallback() {
        let scrubber = ThemedScrubber(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        var travelled: [Double] = []
        var committed: [Double] = []
        scrubber.onChange = { travelled.append($0) }
        scrubber.onScrubEnd = { committed.append($0) }

        scrubber.value = 0.4
        scrubber.value = 0.9

        XCTAssertEqual(scrubber.value, 0.9)
        XCTAssertTrue(travelled.isEmpty, "assigning the position reported a scrub")
        XCTAssertTrue(committed.isEmpty, "assigning the position reported a seek")
    }

    func testTheValueIsClampedToItsRange() {
        let scrubber = ThemedScrubber(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        scrubber.value = 4
        XCTAssertEqual(scrubber.value, 1)
        scrubber.value = -2
        XCTAssertEqual(scrubber.value, 0)
    }

    // MARK: - The travel and its end

    /// A drag is many changes and exactly one commit. The counts are the assertion: a control
    /// that raised `onScrubEnd` per drag step would look identical on screen and turn one seek
    /// into a queue of them.
    func testADragReportsEveryStepAndCommitsOnce() {
        let scrubber = makeHostedScrubber()
        var travelled: [Double] = []
        var committed: [Double] = []
        scrubber.onChange = { travelled.append($0) }
        scrubber.onScrubEnd = { committed.append($0) }

        scrubber.mouseDown(with: pointerEvent(atFractionOfWidth: 0.1, in: scrubber, type: .leftMouseDown))
        XCTAssertTrue(scrubber.isScrubbing)
        scrubber.mouseDragged(with: pointerEvent(atFractionOfWidth: 0.5, in: scrubber, type: .leftMouseDragged))
        scrubber.mouseDragged(with: pointerEvent(atFractionOfWidth: 0.8, in: scrubber, type: .leftMouseDragged))
        scrubber.mouseUp(with: pointerEvent(atFractionOfWidth: 0.8, in: scrubber, type: .leftMouseUp))

        XCTAssertFalse(scrubber.isScrubbing)
        XCTAssertEqual(travelled.count, 3, "the drag did not report every step it travelled")
        XCTAssertEqual(committed.count, 1, "a drag has one end")
        XCTAssertEqual(committed.first ?? -1, scrubber.value, accuracy: 0.0001)
        XCTAssertGreaterThan(scrubber.value, 0.5)
    }

    /// A drag that leaves the control keeps following the pointer, which is what a scrubber must
    /// do: the pointer wanders off a 4-point track constantly, and a control that stopped
    /// tracking there would drop the gesture halfway through.
    func testADragOutsideTheControlKeepsTracking() {
        let scrubber = makeHostedScrubber()
        scrubber.mouseDown(with: pointerEvent(atFractionOfWidth: 0.5, in: scrubber, type: .leftMouseDown))
        scrubber.mouseDragged(with: pointerEvent(atFractionOfWidth: 3, in: scrubber, type: .leftMouseDragged))
        XCTAssertEqual(scrubber.value, 1, "the drag stopped at the control's edge")
        scrubber.mouseDragged(with: pointerEvent(atFractionOfWidth: -2, in: scrubber, type: .leftMouseDragged))
        XCTAssertEqual(scrubber.value, 0)
    }

    func testADisabledScrubberIgnoresThePointer() {
        let scrubber = makeHostedScrubber()
        scrubber.isEnabled = false
        var committed = 0
        scrubber.onScrubEnd = { _ in committed += 1 }

        scrubber.mouseDown(with: pointerEvent(atFractionOfWidth: 0.7, in: scrubber, type: .leftMouseDown))
        scrubber.mouseUp(with: pointerEvent(atFractionOfWidth: 0.7, in: scrubber, type: .leftMouseUp))

        XCTAssertEqual(scrubber.value, 0)
        XCTAssertEqual(committed, 0)
        XCTAssertFalse(scrubber.isScrubbing)
    }

    // MARK: - Keyboard

    /// One key press is a complete scrub, so it raises both events. Shift is the fine step: a
    /// keyboard user who can only move in 5% jumps cannot land on a frame.
    func testAKeyPressTravelsAndCommitsInOneGo() throws {
        let scrubber = makeHostedScrubber()
        scrubber.value = 0.5
        var travelled: [Double] = []
        var committed: [Double] = []
        scrubber.onChange = { travelled.append($0) }
        scrubber.onScrubEnd = { committed.append($0) }

        scrubber.keyDown(with: try keyEvent(NSRightArrowFunctionKey))
        XCTAssertEqual(scrubber.value, 0.5 + ThemedScrubber.Step.coarse, accuracy: 0.0001)
        XCTAssertEqual(travelled.count, 1)
        XCTAssertEqual(committed.count, 1)

        scrubber.keyDown(with: try keyEvent(NSLeftArrowFunctionKey, modifiers: .shift))
        XCTAssertEqual(
            scrubber.value,
            0.5 + ThemedScrubber.Step.coarse - ThemedScrubber.Step.fine,
            accuracy: 0.0001
        )
        XCTAssertEqual(committed.count, 2)
    }

    func testHomeAndEndReachBothEnds() throws {
        let scrubber = makeHostedScrubber()
        scrubber.value = 0.5
        scrubber.keyDown(with: try keyEvent(NSHomeFunctionKey))
        XCTAssertEqual(scrubber.value, 0)
        scrubber.keyDown(with: try keyEvent(NSEndFunctionKey))
        XCTAssertEqual(scrubber.value, 1)
    }

    /// Already at an end, the key press changes nothing — and therefore must not report a seek
    /// either. A transport that re-sought to zero on every left arrow at the start of a document
    /// is a stutter nobody typed.
    func testAKeyPressAtTheEndOfTheRangeCommitsNothing() throws {
        let scrubber = makeHostedScrubber()
        var committed = 0
        scrubber.onScrubEnd = { _ in committed += 1 }
        scrubber.keyDown(with: try keyEvent(NSLeftArrowFunctionKey))
        XCTAssertEqual(scrubber.value, 0)
        XCTAssertEqual(committed, 0)
    }

    // MARK: - Accessibility

    func testTheScrubberReportsASliderWithItsRangeAndSpokenValue() {
        let scrubber = makeHostedScrubber()
        scrubber.value = 0.25
        scrubber.spokenValue = "0:15 / 1:00"

        XCTAssertTrue(scrubber.isAccessibilityElement())
        XCTAssertEqual(scrubber.accessibilityRole(), .slider)
        XCTAssertEqual(scrubber.accessibilityValue() as? Double, 0.25)
        XCTAssertEqual(scrubber.accessibilityMinValue() as? Double, 0)
        XCTAssertEqual(scrubber.accessibilityMaxValue() as? Double, 1)
        XCTAssertEqual(scrubber.accessibilityValueDescription(), "0:15 / 1:00")
    }

    /// A drawn control has no cell, so VoiceOver's increment and decrement have to be routed by
    /// hand or the position can be read and never moved.
    func testVoiceOverCanMoveTheScrubberAndEachStepIsACompleteScrub() {
        let scrubber = makeHostedScrubber()
        scrubber.value = 0.5
        var committed: [Double] = []
        scrubber.onScrubEnd = { committed.append($0) }

        XCTAssertTrue(scrubber.accessibilityPerformIncrement())
        XCTAssertEqual(scrubber.value, 0.5 + ThemedScrubber.Step.coarse, accuracy: 0.0001)
        XCTAssertTrue(scrubber.accessibilityPerformDecrement())
        XCTAssertEqual(scrubber.value, 0.5, accuracy: 0.0001)
        XCTAssertEqual(committed.count, 2)

        // A position control has no press, and inventing one would put a seek behind VoiceOver's
        // most reflexive gesture.
        XCTAssertFalse(scrubber.accessibilityPerformPress())
    }

    func testADisabledScrubberDeclinesVoiceOverMovement() {
        let scrubber = makeHostedScrubber()
        scrubber.isEnabled = false
        XCTAssertFalse(scrubber.accessibilityPerformIncrement())
        XCTAssertFalse(scrubber.isAccessibilityEnabled())
    }

    // MARK: - Geometry

    /// The knob has to stay inside the control at both ends, including the margin the focus ring
    /// is drawn in — a knob half outside its bounds is a ring clipped to nothing.
    func testTheKnobStaysInsideTheControlAtBothEnds() {
        let scrubber = makeHostedScrubber()
        for value in [0.0, 0.5, 1.0] {
            scrubber.value = value
            XCTAssertTrue(
                scrubber.bounds.contains(scrubber.knobRect),
                "the knob left the control at \(value)"
            )
        }
    }

    // MARK: - Live theme

    /// The scrubber draws from roles at draw time, so a live switch has to reach it. A control
    /// that recorded its colours would keep the palette it was born under.
    func testTheScrubberFollowsALiveThemeSwitch() throws {
        let scrubber = makeHostedScrubber()
        scrubber.value = 0.6

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        AppThemeRefresh.repaint(scrubber)
        let cyber = try renderedPNG(of: scrubber)

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        AppThemeRefresh.repaint(scrubber)
        let swiss = try renderedPNG(of: scrubber)

        XCTAssertNotEqual(cyber, swiss, "the scrubber kept the palette it was built under")
    }

    // MARK: - Transport

    func testTheTransportReadsOutElapsedAndTotal() {
        let transport = MediaTransportView(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        transport.documentDuration = 95
        transport.progress = 0.5
        XCTAssertEqual(transport.readoutTextForTesting, "0:47 / 1:35")
    }

    /// An unparsed duration is not a zero-length document, and saying `0:00 / 0:00` claims it is.
    func testAnUnknownDurationReadsAsADashRatherThanZero() {
        let transport = MediaTransportView(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        XCTAssertEqual(transport.readoutTextForTesting, "–:–– / –:––")
        transport.documentDuration = .infinity
        XCTAssertEqual(transport.readoutTextForTesting, "–:–– / –:––")
    }

    func testTheTimestampGrowsToHoursOnlyWhenThereAreHours() {
        XCTAssertEqual(MediaTransportView.timestamp(0), "0:00")
        XCTAssertEqual(MediaTransportView.timestamp(9), "0:09")
        XCTAssertEqual(MediaTransportView.timestamp(600), "10:00")
        XCTAssertEqual(MediaTransportView.timestamp(3_661), "1:01:01")
        XCTAssertEqual(MediaTransportView.timestamp(nil), "–:––")
    }

    /// The most common defect in a transport driven by a player that also reports position: the
    /// report lands mid-drag and pulls the knob out from under the pointer.
    func testAStateReportDuringADragDoesNotMoveTheKnob() {
        let transport = makeHostedTransport()
        let scrubber = transport.scrubberForTesting
        scrubber.mouseDown(with: pointerEvent(atFractionOfWidth: 0.8, in: scrubber, type: .leftMouseDown))
        let dragged = scrubber.value

        transport.progress = 0.1

        XCTAssertEqual(scrubber.value, dragged, accuracy: 0.0001)
        scrubber.mouseUp(with: pointerEvent(atFractionOfWidth: 0.8, in: scrubber, type: .leftMouseUp))
        transport.progress = 0.1
        XCTAssertEqual(scrubber.value, 0.1, accuracy: 0.0001)
    }

    /// The reading follows the knob while it travels, so a drag reads out the position it is
    /// about to commit rather than the one it left.
    func testTheReadoutFollowsTheKnobWhileScrubbing() {
        let transport = makeHostedTransport()
        transport.documentDuration = 100
        let scrubber = transport.scrubberForTesting
        scrubber.mouseDown(with: pointerEvent(atFractionOfWidth: 0.5, in: scrubber, type: .leftMouseDown))
        XCTAssertTrue(
            transport.readoutTextForTesting.hasSuffix(" / 1:40"),
            "the total changed while scrubbing: \(transport.readoutTextForTesting)"
        )
        XCTAssertNotEqual(transport.readoutTextForTesting, "0:00 / 1:40")
    }

    func testTheTransportRaisesPlayPauseWithoutTogglingItself() {
        let transport = makeHostedTransport()
        var presses = 0
        transport.onPlayPause = { presses += 1 }

        XCTAssertTrue(transport.playButtonForTesting.performPrimaryAction())
        XCTAssertEqual(presses, 1)
        XCTAssertFalse(transport.isPlaying, "the transport decided its own phase")

        transport.isPlaying = true
        XCTAssertEqual(presses, 1, "stating the phase raised the action")
    }

    /// Movies put the primary action over the picture. The row below is then a timeline, not two
    /// copies of Play competing for attention and scrub travel.
    func testTheTransportCanBecomeATimelineWithoutItsPlayControl() {
        let transport = makeHostedTransport()

        transport.showsPlayControl = false

        XCTAssertTrue(transport.playButtonForTesting.isHidden)
        XCTAssertFalse(transport.scrubberForTesting.isHidden)
    }

    func testDisablingTheTransportDisablesItsControls() {
        let transport = makeHostedTransport()
        transport.isEnabled = false
        XCTAssertFalse(transport.playButtonForTesting.isEnabled)
        XCTAssertFalse(transport.scrubberForTesting.isEnabled)
    }

    func testTheTransportIsAGroupWithASpokenReading() {
        let transport = makeHostedTransport()
        transport.documentDuration = 60
        transport.progress = 0.5
        XCTAssertEqual(transport.accessibilityRole(), .group)
        XCTAssertEqual(transport.accessibilityValue() as? String, "0:30 / 1:00")
        XCTAssertEqual(
            transport.scrubberForTesting.accessibilityValueDescription(),
            "0:30 / 1:00"
        )
    }

    /// The whole transport is built from `UI/Design/`, so nothing inside it may be raw AppKit
    /// chrome — the audit is the same one every window in the app answers.
    func testTheTransportTreeContainsNoRawAppKitChrome() {
        let transport = makeHostedTransport()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentLayoutRect)
        host.addSubview(transport)
        window.contentView = host
        defer { window.contentView = nil }

        XCTAssertEqual(ThemeBoundaryAudit.violations(in: window), [])
    }

    // MARK: - Movie overlay

    /// Play remains discoverable while a movie is paused, and the whole picture is the same
    /// primary action rather than a 48-point interaction island. It also accepts the click that
    /// activates an inactive window, as an ordinary playback button does.
    func testThePausedMovieOverlayShowsPlayAndHitsTheWholeCanvas() {
        let overlay = makeHostedPlaybackOverlay()
        var toggles = 0
        overlay.onToggle = { toggles += 1 }

        XCTAssertTrue(overlay.isControlVisibleForTesting)
        XCTAssertEqual(overlay.accessibilityRole(), .button)
        XCTAssertEqual(overlay.accessibilityTitle(), L10n.string("Play"))
        XCTAssertTrue(overlay.hitTest(NSPoint(x: 100, y: 60)) === overlay)
        XCTAssertTrue(overlay.hitTest(NSPoint(x: 4, y: 4)) === overlay)
        XCTAssertNil(overlay.hitTest(NSPoint(x: -1, y: -1)))
        XCTAssertTrue(overlay.acceptsFirstMouse(for: nil))

        overlay.mouseDown(with: pointerEvent(
            atFractionOfWidth: 0.02,
            in: overlay,
            type: .leftMouseDown
        ))
        overlay.mouseUp(with: pointerEvent(
            atFractionOfWidth: 0.02,
            in: overlay,
            type: .leftMouseUp
        ))
        XCTAssertEqual(toggles, 1)
    }

    /// Once playback is under way the picture clears. Entering anywhere over the canvas reveals
    /// Pause — the action the centre control will take — and leaving clears it again.
    func testThePlayingMovieOverlayShowsPauseOnlyWhileHovered() {
        let overlay = makeHostedPlaybackOverlay()
        overlay.isPlaying = true

        XCTAssertFalse(overlay.isControlVisibleForTesting)
        XCTAssertEqual(overlay.accessibilityTitle(), L10n.string("Pause"))

        overlay.mouseEntered(with: PointerEventStub(location: .zero, type: .mouseEntered))
        XCTAssertTrue(overlay.isControlVisibleForTesting)

        overlay.mouseExited(with: PointerEventStub(location: .zero, type: .mouseExited))
        XCTAssertFalse(overlay.isControlVisibleForTesting)
    }

    /// Pointer, keyboard and VoiceOver all raise the same host-owned intent. Stating a new phase
    /// remains presentation only, so a player can mirror its session without recursively acting.
    func testTheMovieOverlayRaisesItsActionWithoutTogglingItself() {
        let overlay = makeHostedPlaybackOverlay()
        var toggles = 0
        overlay.onToggle = { toggles += 1 }

        XCTAssertTrue(overlay.performPrimaryAction())
        XCTAssertTrue(overlay.accessibilityPerformPress())
        XCTAssertEqual(toggles, 2)
        XCTAssertFalse(overlay.isPlaying)

        overlay.isPlaying = true
        XCTAssertEqual(toggles, 2)
    }

    // MARK: - Fixtures

    private func makeHostedScrubber() -> ThemedScrubber {
        let scrubber = ThemedScrubber(frame: NSRect(x: 0, y: 0, width: 220, height: 20))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 20))
        host.addSubview(scrubber)
        host.layoutSubtreeIfNeeded()
        return scrubber
    }

    private func makeHostedTransport() -> MediaTransportView {
        let transport = MediaTransportView(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 40))
        host.addSubview(transport)
        NSLayoutConstraint.activate([
            transport.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            transport.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return transport
    }

    private func makeHostedPlaybackOverlay() -> MediaPlaybackOverlayView {
        // A real movie canvas is offset above its transport row. Keeping that offset in the
        // fixture catches a hit-test implementation that converts an already-local point twice.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 220))
        let overlay = MediaPlaybackOverlayView(
            frame: NSRect(x: 50, y: 50, width: 200, height: 120)
        )
        host.addSubview(overlay)
        host.layoutSubtreeIfNeeded()
        return overlay
    }

    /// A pointer event located by fraction of the control's width, so a fixture that changes size
    /// does not silently change what the test is pressing. Values outside `0…1` are deliberate:
    /// a drag that leaves the control still belongs to it.
    private func pointerEvent(
        atFractionOfWidth fraction: CGFloat,
        in view: NSView,
        type: NSEvent.EventType
    ) -> NSEvent {
        let point = NSPoint(x: view.bounds.width * fraction, y: view.bounds.midY)
        return PointerEventStub(location: view.convert(point, to: nil), type: type)
    }

    private func keyEvent(
        _ functionKey: Int,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        let scalar = try XCTUnwrap(UnicodeScalar(UInt32(functionKey)))
        let characters = String(Character(scalar))
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ))
    }

    private func renderedPNG(of view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

/// A synthetic mouse event whose location the control can read.
///
/// `NSEvent.mouseEvent` needs a window number to build a usable event, and a synthesized
/// `CGEvent` inherits the developer's live modifier keys — the trap recorded in
/// `synthetic-events-inherit-live-modifiers`. Overriding the two members `ThemedScrubber` reads
/// is both smaller and deterministic.
private final class PointerEventStub: NSEvent {
    private let stubLocation: NSPoint
    private let stubType: NSEvent.EventType

    init(location: NSPoint, type: NSEvent.EventType) {
        stubLocation = location
        stubType = type
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var locationInWindow: NSPoint { stubLocation }
    override var type: NSEvent.EventType { stubType }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}
