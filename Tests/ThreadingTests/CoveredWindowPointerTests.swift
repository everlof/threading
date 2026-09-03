import AppKit
import XCTest
@testable import Threading

/// What the pointer can reach while a surface covers the window's content.
///
/// Reported against the dropdown, twice in one screenshot: with a menu open over the composer,
/// the pointer over a menu row was the composer editor's I-beam, and the chips behind the panel
/// lit as hovered while the pointer travelled the rows above them. A menu drawn as a view rather
/// than as a window inherits none of a window's pointer boundary — tracking areas report crossings
/// of a rectangle and know nothing about what is drawn over it. See `CoveredWindowPointer`.
@MainActor
final class CoveredWindowPointerTests: XCTestCase {

    // MARK: - Fixtures

    /// A view that keeps a hover state the way every control here does, and records what it was
    /// told and what it could see at the time.
    private final class HoverSpy: NSView {
        var entered = 0
        var exited = 0
        var cursorUpdates = 0
        /// What `isPointerCovered(at:)` answered at the moment of the last arrival — the question
        /// the sidebar's rows ask on `mouseEntered`, which has to be answered truthfully when a
        /// held-back arrival is finally delivered.
        var wasCoveredOnArrival: Bool?
        private(set) var area: NSTrackingArea!

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func mouseEntered(with event: NSEvent) {
            entered += 1
            wasCoveredOnArrival = isPointerCovered(at: event.locationInWindow)
        }

        override func mouseExited(with event: NSEvent) { exited += 1 }
        override func cursorUpdate(with event: NSEvent) { cursorUpdates += 1 }
    }

    private struct Fixture {
        let window: NSWindow
        let root: NSView
        /// A control under the surface — the chip behind the panel.
        let chip: HoverSpy
        /// The covering surface, added over everything.
        let surface: NSView
        /// A row inside the surface — a menu row.
        let row: HoverSpy
    }

    private func makeFixture() -> Fixture {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        let chip = HoverSpy(frame: NSRect(x: 24, y: 24, width: 140, height: 26))
        root.addSubview(chip)

        let surface = NSView(frame: root.bounds)
        surface.autoresizingMask = [.width, .height]
        root.addSubview(surface)
        let row = HoverSpy(frame: NSRect(x: 40, y: 100, width: 200, height: 24))
        surface.addSubview(row)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        return Fixture(window: window, root: root, chip: chip, surface: surface, row: row)
    }

    /// The events AppKit generates for a crossing cannot be built with their tracking area
    /// attached — no public initializer sets it — so the decision is exercised through the seam
    /// that takes the area alongside a stand-in event.
    private func arrival(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
    }

    private func mouseMoved(at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
    }

    /// Runs one release/dismissal with the pointer deterministically over `view`. Moving an
    /// unshown window under the hardware pointer is not stable near a screen edge because AppKit
    /// may constrain its frame, and moving the hardware pointer would disturb the user.
    private func withPointer(
        over view: NSView,
        in window: NSWindow,
        perform: () -> Void
    ) {
        let target = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        CoveredWindowPointer.withPointerLocationForTesting(target, in: window, perform: perform)
    }

    private func withPointerAway(from window: NSWindow, perform: () -> Void) {
        CoveredWindowPointer.withPointerLocationForTesting(
            NSPoint(x: -5_000, y: -5_000),
            in: window,
            perform: perform
        )
    }

    @discardableResult
    private func withhold(_ type: NSEvent.EventType, for spy: HoverSpy, in window: NSWindow) -> Bool {
        let point = spy.convert(NSPoint(x: spy.bounds.midX, y: spy.bounds.midY), to: nil)
        return CoveredWindowPointer.intercept(
            arrival(type, at: point, in: window),
            type: type,
            area: spy.area,
            window: window
        )
    }

    // MARK: - The Reported Bugs

    func testAnArrivalBeneathTheSurfaceIsWithheldFromItsOwner() {
        let f = makeFixture()
        defer { CoveredWindowPointer.release(f.surface) }
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)

        XCTAssertTrue(withhold(.mouseEntered, for: f.chip, in: f.window), "the chip behind the panel was told the pointer arrived")
        XCTAssertTrue(withhold(.cursorUpdate, for: f.chip, in: f.window), "the editor behind the panel was asked for its cursor")
        XCTAssertEqual(f.chip.entered, 0)
        XCTAssertEqual(f.chip.cursorUpdates, 0)
        XCTAssertEqual(CoveredWindowPointer.owedArrivalCount(in: f.window), 2)
    }

    func testAnArrivalInsideTheSurfacePasses() {
        let f = makeFixture()
        defer { CoveredWindowPointer.release(f.surface) }
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)

        XCTAssertFalse(withhold(.mouseEntered, for: f.row, in: f.window), "the menu's own row lost its hover")
        XCTAssertEqual(CoveredWindowPointer.owedArrivalCount(in: f.window), 0)
    }

    /// An area owned by an ancestor of the surface is a view being reached through, not one
    /// standing under the surface — the same reading `NSView.isPointerCovered(at:)` gives it.
    func testAnArrivalForAnAncestorOfTheSurfacePasses() {
        let f = makeFixture()
        defer { CoveredWindowPointer.release(f.surface) }
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)

        let rootArea = NSTrackingArea(rect: f.root.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: f.root)
        let withheld = CoveredWindowPointer.intercept(
            arrival(.mouseEntered, at: NSPoint(x: 10, y: 10), in: f.window),
            type: .mouseEntered,
            area: rootArea,
            window: f.window
        )
        XCTAssertFalse(withheld)
    }

    /// Tooltips are the ordinary case: their areas are owned by the tooltip manager, not by a
    /// view, and a menu row's tooltip has to work as much as anything else's.
    func testAnArrivalNoViewOwnsPasses() {
        let f = makeFixture()
        defer { CoveredWindowPointer.release(f.surface) }
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)

        let owner = NSObject()
        let area = NSTrackingArea(rect: f.chip.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: owner)
        let withheld = CoveredWindowPointer.intercept(
            arrival(.mouseEntered, at: NSPoint(x: 30, y: 30), in: f.window),
            type: .mouseEntered,
            area: area,
            window: f.window
        )
        XCTAssertFalse(withheld)
        withExtendedLifetime(owner) {}
    }

    /// Leaving is the direction that goes wrong visibly — a hover that never ends — and it is
    /// not the one this exists to stop.
    func testALeavingBeneathTheSurfacePassesAndCancelsTheOwedArrival() {
        let f = makeFixture()
        defer { CoveredWindowPointer.release(f.surface) }
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)

        withhold(.mouseEntered, for: f.chip, in: f.window)
        XCTAssertEqual(CoveredWindowPointer.owedArrivalCount(in: f.window), 1)

        XCTAssertFalse(withhold(.mouseExited, for: f.chip, in: f.window), "the chip was never told the pointer left")
        XCTAssertEqual(CoveredWindowPointer.owedArrivalCount(in: f.window), 0, "an arrival the pointer has since undone was still owed")
    }

    func testAnEventOfAnotherKindPassesWithoutBeingRead() {
        let f = makeFixture()
        defer { CoveredWindowPointer.release(f.surface) }
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)

        // `NSEvent.trackingArea` raises for a mouse-moved event; the monitor must not ask.
        let moved = mouseMoved(at: NSPoint(x: 30, y: 30), in: f.window)
        XCTAssertTrue(CoveredWindowPointer.intercept(moved) === moved)
    }

    // MARK: - The Debt

    /// AppKit's book says the pointer is inside the chip's area — it generated the crossing — so
    /// it will not say so again until the pointer leaves and comes back. The surface going is
    /// when the chip learns what it missed.
    func testAnOwedArrivalIsDeliveredWhenTheSurfaceGoesAndThePointerIsStillOnIt() {
        let f = makeFixture()
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)
        withhold(.mouseEntered, for: f.chip, in: f.window)
        withhold(.cursorUpdate, for: f.chip, in: f.window)
        XCTAssertEqual(f.chip.entered, 0)

        f.surface.removeFromSuperview()
        withPointer(over: f.chip, in: f.window) {
            CoveredWindowPointer.release(f.surface)
        }

        XCTAssertEqual(f.chip.entered, 1, "the chip the pointer rests on when the menu closes never lit")
        XCTAssertEqual(f.chip.cursorUpdates, 1, "the editor the pointer rests on when the menu closes never got its cursor back")
        XCTAssertEqual(f.chip.wasCoveredOnArrival, false)
        XCTAssertEqual(CoveredWindowPointer.owedArrivalCount(in: f.window), 0)
    }

    func testAnOwedArrivalThePointerHasLeftIsNotDelivered() {
        let f = makeFixture()
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)
        withhold(.mouseEntered, for: f.chip, in: f.window)

        f.surface.removeFromSuperview()
        withPointerAway(from: f.window) {
            CoveredWindowPointer.release(f.surface)
        }

        XCTAssertEqual(f.chip.entered, 0, "a chip the pointer is nowhere near was lit on the menu's way out")
    }

    /// One arrival per area and kind: the latest crossing describes where the pointer is, and an
    /// older one delivered as well would light the view twice.
    func testRepeatedArrivalsForOneAreaAreOwedOnce() {
        let f = makeFixture()
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)
        withhold(.mouseEntered, for: f.chip, in: f.window)
        withhold(.mouseEntered, for: f.chip, in: f.window)
        XCTAssertEqual(CoveredWindowPointer.owedArrivalCount(in: f.window), 1)

        f.surface.removeFromSuperview()
        withPointer(over: f.chip, in: f.window) {
            CoveredWindowPointer.release(f.surface)
        }
        XCTAssertEqual(f.chip.entered, 1)
    }

    /// A surface closing inside another one hands what it owed to the surface still covering the
    /// window, not to the control — the control is still under something.
    func testAnOwedArrivalMovesToTheSurfaceStillCoveringIt() {
        let f = makeFixture()
        let inner = NSView(frame: f.root.bounds)
        f.root.addSubview(inner)
        defer {
            CoveredWindowPointer.release(inner)
            CoveredWindowPointer.release(f.surface)
        }
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)
        CoveredWindowPointer.claim(inner, covering: f.window, cursor: .arrow)
        withhold(.mouseEntered, for: f.chip, in: f.window)

        inner.removeFromSuperview()
        withPointer(over: f.chip, in: f.window) {
            CoveredWindowPointer.release(inner)
        }
        XCTAssertEqual(f.chip.entered, 0, "the inner surface's release lit a chip the outer one still covers")
        XCTAssertEqual(CoveredWindowPointer.owedArrivalCount(in: f.window), 1, "the outer surface was not handed the debt")
        XCTAssertTrue(CoveredWindowPointer.isClaimed(f.window))

        f.surface.removeFromSuperview()
        withPointer(over: f.chip, in: f.window) {
            CoveredWindowPointer.release(f.surface)
        }
        XCTAssertEqual(f.chip.entered, 1)
        XCTAssertFalse(CoveredWindowPointer.isClaimed(f.window))
    }

    // MARK: - The Arrow

    /// `mouseMoved` cannot be withheld — the manager that computes every crossing in the window
    /// does so inside that event — so the editor beneath still sets its I-beam. The application
    /// puts the arrow back after the event has been dispatched.
    func testTheApplicationPutsTheArrowBackOverTheSurface() {
        let f = makeFixture()
        defer {
            CoveredWindowPointer.release(f.surface)
            NSCursor.arrow.set()
        }
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)

        NSCursor.iBeam.set()
        CoveredWindowPointer.applicationDidDispatch(mouseMoved(at: NSPoint(x: 60, y: 30), in: f.window))
        XCTAssertEqual(NSCursor.current, NSCursor.arrow, "the editor's I-beam stood over the menu")
    }

    /// A mouse-moved event can reach the key window while the pointer is over another one, and
    /// that window's cursor is its own.
    func testTheApplicationLeavesTheCursorAloneAwayFromTheSurface() {
        let f = makeFixture()
        defer {
            CoveredWindowPointer.release(f.surface)
            NSCursor.arrow.set()
        }
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)

        NSCursor.iBeam.set()
        CoveredWindowPointer.applicationDidDispatch(mouseMoved(at: NSPoint(x: -50, y: -50), in: f.window))
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam)
    }

    func testTheApplicationLeavesTheCursorAloneWithNoClaim() {
        let f = makeFixture()
        defer { NSCursor.arrow.set() }

        NSCursor.iBeam.set()
        CoveredWindowPointer.applicationDidDispatch(mouseMoved(at: NSPoint(x: 60, y: 30), in: f.window))
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam)
    }

    // MARK: - The Cursor Policy

    /// A modal's own fields and handles register cursors in the same window's list, so its claim
    /// takes only the crossings half: nothing about the cursor changes.
    func testASurfaceOwnedClaimWithholdsCrossingsAndLeavesTheCursorAlone() {
        let f = makeFixture()
        defer {
            CoveredWindowPointer.release(f.surface)
            NSCursor.arrow.set()
        }
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .surfaceOwned)

        XCTAssertTrue(CoveredWindowPointer.isClaimed(f.window))
        XCTAssertTrue(f.window.areCursorRectsEnabled, "a modal's claim turned off the cursor rectangles its own field needs")
        XCTAssertFalse(CoveredWindowCursor.isClaimed(f.window))
        XCTAssertTrue(withhold(.mouseEntered, for: f.chip, in: f.window), "the chip under the modal was told the pointer arrived")

        NSCursor.iBeam.set()
        CoveredWindowPointer.applicationDidDispatch(mouseMoved(at: NSPoint(x: 60, y: 30), in: f.window))
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "the arrow was forced over a surface that owns its cursor")
    }

    /// A dropdown opened from inside a modal claims the arrow on top; when it goes, the modal's
    /// claim is what the window is under again.
    func testAnArrowClaimOverASurfaceOwnedOneHandsBackToIt() {
        let f = makeFixture()
        let menu = NSView(frame: f.root.bounds)
        f.root.addSubview(menu)
        defer {
            CoveredWindowPointer.release(menu)
            CoveredWindowPointer.release(f.surface)
            NSCursor.arrow.set()
        }
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .surfaceOwned)
        CoveredWindowPointer.claim(menu, covering: f.window, cursor: .arrow)
        XCTAssertFalse(f.window.areCursorRectsEnabled)

        menu.removeFromSuperview()
        CoveredWindowPointer.release(menu)
        XCTAssertTrue(f.window.areCursorRectsEnabled, "the modal was left without the cursor rectangles its field needs")
        XCTAssertTrue(CoveredWindowPointer.isClaimed(f.window))
        NSCursor.iBeam.set()
        CoveredWindowPointer.applicationDidDispatch(mouseMoved(at: NSPoint(x: 60, y: 30), in: f.window))
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam)
    }

    // MARK: - The Modal

    /// `InWindowOverlay` claims for the surface it installs and releases when the presentation is
    /// removed — after both views are out, so the debt is paid to controls that can see the truth.
    func testAModalOnTheScrimClaimsThePointerAndPaysOnRemoval() throws {
        let f = makeFixture()
        f.surface.removeFromSuperview()

        let panel = NSView()
        let presentation = try XCTUnwrap(InWindowOverlay.install(panel, in: f.window, onDismiss: {}))
        XCTAssertTrue(CoveredWindowPointer.isClaimed(f.window))
        XCTAssertTrue(f.window.areCursorRectsEnabled)

        // The panel is pinned to the safe area and may not reach the chip; the chip is under the
        // wash either way, and the surface answers for the whole window.
        withhold(.mouseEntered, for: f.chip, in: f.window)
        XCTAssertEqual(f.chip.entered, 0, "the chip under the modal lit")

        withPointer(over: f.chip, in: f.window) {
            presentation.remove()
        }
        XCTAssertFalse(CoveredWindowPointer.isClaimed(f.window))
        XCTAssertEqual(f.chip.entered, 1, "the chip under the pointer stayed dark after the modal closed")
        XCTAssertEqual(f.chip.wasCoveredOnArrival, false)
    }

    // MARK: - The Dropdown

    /// The presenter claims the pointer with its overlay and releases it on dismissal — the
    /// cursor-rectangle half of that claim included.
    func testAnOpenDropdownClaimsThePointerAndReleasesItOnDismissal() throws {
        let f = makeFixture()
        f.surface.removeFromSuperview()
        let source = NSView(frame: NSRect(x: 24, y: 200, width: 140, height: 26))
        f.root.addSubview(source)

        let token = try XCTUnwrap(ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: [.item(ThemedMenuItem(title: "Rename"))], minimumWidth: 140),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, _ in },
            onDismiss: {}
        ))
        XCTAssertTrue(CoveredWindowPointer.isClaimed(f.window))
        XCTAssertTrue(CoveredWindowCursor.isClaimed(f.window))

        // A crossing beneath the panel while it is up.
        withhold(.mouseEntered, for: f.chip, in: f.window)
        XCTAssertEqual(f.chip.entered, 0, "the chip behind the open dropdown lit")

        withPointer(over: f.chip, in: f.window) {
            ThemedMenuPresenter.dismiss(token)
        }
        XCTAssertFalse(CoveredWindowPointer.isClaimed(f.window))
        XCTAssertFalse(CoveredWindowCursor.isClaimed(f.window))
        XCTAssertEqual(f.chip.entered, 1, "the chip under the pointer stayed dark after the dropdown closed")
        // The overlay is still fading when the debt is paid; it must already have stopped
        // answering hit tests, or a row asking whether it is covered would be told yes.
        XCTAssertEqual(f.chip.wasCoveredOnArrival, false, "the arrival was delivered before the overlay stopped covering the chip")
    }

    // MARK: - The Rule for Position Hovers

    /// `mouseMoved` cannot be withheld, so a hover that reads its position off it asks
    /// `NSView.isPointerCovered(at:)` itself. The seam is the one the 08-13 report was about.
    func testTheSeamDoesNotLightUnderACoveringSurface() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        let split = ThemedSplitView(frame: root.bounds)
        split.isVertical = true
        split.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 260)))
        split.addSubview(NSView(frame: NSRect(x: 201, y: 0, width: 219, height: 260)))
        root.addSubview(split)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        split.adjustSubviews()
        root.layoutSubtreeIfNeeded()

        let seamX = split.arrangedSubviews[0].frame.maxX + split.dividerThickness / 2
        let onSeam = split.convert(NSPoint(x: seamX, y: 130), to: nil)

        split.mouseMoved(with: mouseMoved(at: onSeam, in: window))
        XCTAssertEqual(split.activeDividerIndex, 0, "the fixture's seam does not light at all; the covered case below would prove nothing")

        let surface = NSView(frame: root.bounds)
        root.addSubview(surface)
        split.mouseMoved(with: mouseMoved(at: onSeam, in: window))
        XCTAssertNil(split.activeDividerIndex, "the seam lit under an open dropdown")
    }

    func testTheDiffLineActionDoesNotFollowThePointerUnderACoveringSurface() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: """
        diff --git a/Foo.swift b/Foo.swift
        --- a/Foo.swift
        +++ b/Foo.swift
        @@ -1,2 +1,2 @@
         first
        -old line
        +new line
        """).first)
        let lines = file.hunks.flatMap(\.lines)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        let diff = GitReviewDiffTextView(gitLines: lines, displayCap: 100, path: "Foo.swift", initialLayoutWidth: 400)
        diff.onAddContextAttachment = { _ in }
        root.addSubview(diff)
        NSLayoutConstraint.activate([
            diff.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            diff.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            diff.topAnchor.constraint(equalTo: root.topAnchor)
        ])
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        diff.layoutManager?.ensureLayout(for: try XCTUnwrap(diff.textContainer))

        let firstLine = diff.convert(NSPoint(x: 40, y: diff.textContainerInset.height + 4), to: nil)
        diff.mouseMoved(with: mouseMoved(at: firstLine, in: window))
        XCTAssertEqual(diff.hoveredLineIndex, 0, "the fixture's line does not hover at all; the covered case below would prove nothing")
        diff.mouseExited(with: arrival(.mouseExited, at: firstLine, in: window))
        XCTAssertNil(diff.hoveredLineIndex)

        let surface = NSView(frame: root.bounds)
        root.addSubview(surface)
        diff.mouseMoved(with: mouseMoved(at: firstLine, in: window))
        XCTAssertNil(diff.hoveredLineIndex, "the line action walked the diff under an open dropdown")
    }

    func testTheMinimapPreviewDoesNotFollowThePointerUnderACoveringSurface() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        let rail = ConversationMinimapView(frame: NSRect(x: 0, y: 0, width: 24, height: 600))
        container.addSubview(rail)
        rail.setTurns((1...8).map {
            ConversationTimeline.Turn(
                rowIndex: $0,
                endIndex: $0,
                finalAssistantIndex: $0,
                userText: "Question \($0)",
                assistantText: "Answer \($0)",
                duration: nil
            )
        })
        rail.attachPreview(to: container)
        container.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(container.subviews.first { $0 is ConversationTurnPreview })
        XCTAssertTrue(card.isHidden)

        let surface = NSView(frame: container.bounds)
        container.addSubview(surface)
        rail.mouseMoved(with: mouseMoved(at: rail.convert(NSPoint(x: rail.bounds.midX, y: 300), to: nil), in: window))
        container.layoutSubtreeIfNeeded()
        XCTAssertTrue(card.isHidden, "the rail's preview opened under an open dropdown")
    }

    // MARK: - The Backstop

    /// A surface that leaves its window without releasing stops counting, exactly as the cursor
    /// half does — a window whose pointer never answers again is not a failure to leave to a
    /// `guard` somebody may move.
    func testASurfaceThatLeftItsWindowStopsHoldingThePointer() {
        let f = makeFixture()
        CoveredWindowPointer.claim(f.surface, covering: f.window, cursor: .arrow)
        XCTAssertTrue(CoveredWindowPointer.isClaimed(f.window))

        f.surface.removeFromSuperview()
        XCTAssertFalse(CoveredWindowPointer.isClaimed(f.window))
        XCTAssertFalse(withhold(.mouseEntered, for: f.chip, in: f.window), "a departed surface still withheld the pointer from the window")
        CoveredWindowPointer.release(f.surface)
    }
}
