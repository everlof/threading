import AppKit
import XCTest
@testable import Threading

/// The gesture every other Mac window has: double-click the strip beside the traffic lights and
/// the window fills the screen.
///
/// It was missing here, and the reason is a platform behaviour rather than anything this app does
/// with the click. `testTheTitlebarStripHitTestsToTheContentViewOnlyWhenBothFlagsAreSet` pins that
/// behaviour where `PaneHeaderTests` pins its own: `.fullSizeContentView` alone leaves the strip
/// hit-testing to the titlebar, a transparent titlebar alone leaves it there too, and only the two
/// together hand the click to the content view — past the titlebar that implements zoom. If Apple
/// ever changes that, the test fails and `TitlebarActionWindow` can go with it.
@MainActor
final class TitlebarDoubleClickTests: HostedStoreTestCase {

    private enum Fixture {
        static let size = NSSize(width: 700, height: 500)
        /// Wide enough for the real window's own floors — both panes state a minimum — so the
        /// sidebar in it is the width it would really be.
        static let realWindowSize = NSSize(width: 1_000, height: 700)
        static let origin = NSPoint(x: 120, y: 120)
        /// Far enough down to be in the strip on any toolbar style, far enough right to be clear
        /// of the window's own controls — though the window is asked last either way.
        static let stripInset: CGFloat = 12
    }

    private var controller: MainWindowController?

    /// Every fixture window this class made in the running test.
    private var windows: [NSWindow] = []

    override func tearDown() {
        // Every fixture disables AppKit window animation at creation, so it owns no deferred
        // transform to outlive teardown. Detach it from its view/controller graph before the
        // XCTest autorelease pool drains; parking these windows for the whole process was the
        // largest late-suite contribution to AppKit's live-window threshold.
        for window in windows {
            window.orderOut(nil)
            window.delegate = nil
            window.contentView = nil
        }
        windows.removeAll()
        if let window = controller?.window {
            window.orderOut(nil)
            window.delegate = nil
            window.contentView = nil
            controller?.window = nil
        }
        controller = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeWindow(
        fullSizeContentView: Bool = true,
        transparentTitlebar: Bool = true
    ) -> TitlebarActionWindow {
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if fullSizeContentView { mask.insert(.fullSizeContentView) }

        let window = TitlebarActionWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = transparentTitlebar
        window.contentView = NSView()
        window.setFrameOrigin(Fixture.origin)
        // No transform animation to outlive anything. `zoom()` on an unshown window still
        // spawns `_NSWindowTransformAnimation`, which holds its window unretained and
        // commits on a later Core Animation transaction — a use-after-free that detonates
        // in whichever test happens to pump the run loop next, two suites away and with
        // nothing of its own on the stack. What these tests assert is the *frame* zoom
        // produces, which is animation-independent.
        window.animationBehavior = .none
        windows.append(window)
        return window
    }

    /// Delivers the click where AppKit would deliver it: to the view under the point, whose
    /// default `mouseDown` walks the responder chain to the window. A view that claims the click
    /// and does not call `super` stops it here exactly as it would in the running app, which is
    /// the whole question the real-window test asks.
    ///
    /// Not through `NSWindow.sendEvent`: it declines to route a synthesized mouse event into a
    /// window that was never ordered on screen, which is every window in this suite — asserted
    /// below rather than described, because a helper that silently delivers nothing would make
    /// every test here pass for the wrong reason.
    private func doubleClick(
        _ window: NSWindow,
        at point: NSPoint,
        clickCount: Int = TitlebarDoubleClick.clickCount
    ) {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ) else {
            return XCTFail("Could not build a mouse event")
        }

        if let target = window.contentView?.hitTest(point) {
            target.mouseDown(with: event)
        } else {
            window.mouseDown(with: event)
        }
    }

    private func pointInStrip(of window: NSWindow) -> NSPoint {
        NSPoint(x: window.frame.width / 2, y: window.frame.height - Fixture.stripInset)
    }

    // MARK: - The Gesture

    func testDoubleClickingTheTitlebarStripFillsTheScreen() throws {
        let window = makeWindow()
        window.doubleClickAction = { .zoom }
        let before = window.frame

        doubleClick(window, at: pointInStrip(of: window))

        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        XCTAssertNotEqual(window.frame, before, "The strip's double-click did nothing")
        XCTAssertEqual(window.frame, screen.visibleFrame, "Zoom fills the screen it is on")
    }

    func testASecondDoubleClickPutsTheWindowBack() {
        let window = makeWindow()
        window.doubleClickAction = { .zoom }
        let before = window.frame

        doubleClick(window, at: pointInStrip(of: window))
        XCTAssertNotEqual(window.frame, before, "The first click has to land, or this proves nothing")

        doubleClick(window, at: pointInStrip(of: window))
        XCTAssertEqual(window.frame, before, "Zoom is a toggle, and so is the gesture that drives it")
    }

    func testASingleClickInTheStripLeavesTheWindowAlone() {
        let window = makeWindow()
        window.doubleClickAction = { .zoom }
        let before = window.frame

        doubleClick(window, at: pointInStrip(of: window), clickCount: 1)

        XCTAssertEqual(window.frame, before)
    }

    func testADoubleClickBelowTheStripLeavesTheWindowAlone() {
        let window = makeWindow()
        window.doubleClickAction = { .zoom }
        let before = window.frame

        doubleClick(window, at: NSPoint(x: window.frame.midX, y: window.frame.midY))

        XCTAssertEqual(window.frame, before, "Only the chrome carries this gesture")
    }

    func testTheStripIsWhateverThePlatformHeldBackFromTheContent() {
        let window = makeWindow()
        let strip = window.frame.height - window.contentLayoutRect.height

        XCTAssertGreaterThan(strip, 0, "A titled window always holds a band back")
        XCTAssertTrue(window.isInTitlebarStrip(NSPoint(x: 10, y: window.frame.height - 1)))
        XCTAssertFalse(
            window.isInTitlebarStrip(NSPoint(x: 10, y: window.frame.height - strip - 1)),
            "One point below the band is content, not chrome"
        )
    }

    /// The one the user actually reported: the strip over the *sidebar*, on the real window, with
    /// every real pane under it. A view that claimed the click — a backdrop, a header host, a web
    /// view pinned too high — would swallow it before the window is asked, and this is the only
    /// test that would notice.
    func testTheRealWindowZoomsFromTheStripAboveTheSidebar() throws {
        let controller = makeMainWindowController()
        self.controller = controller
        let window = try XCTUnwrap(controller.window as? TitlebarActionWindow)
        window.doubleClickAction = { .zoom }
        // See `makeWindow`: no transform animation, so nothing outlives this window.
        window.animationBehavior = .none
        window.setFrame(NSRect(origin: Fixture.origin, size: Fixture.realWindowSize), display: false)
        window.layoutIfNeeded()
        let before = window.frame

        // The sidebar's own trailing edge, measured rather than guessed: far enough right of the
        // toolbar's controls that none of them claims the click, and short of the divider, which
        // starts a drag of its own.
        let splitView = try XCTUnwrap(firstSplitView(in: window.contentView))
        let sidebar = try XCTUnwrap(splitView.arrangedSubviews.first)
        let sidebarEdge = sidebar.convert(sidebar.bounds, to: nil).maxX
        XCTAssertGreaterThan(
            sidebarEdge,
            PaneHeaderDefaults.assumedWindowControlsWidth,
            "The column has to be wider than the controls floating over it, or there is no "
                + "point in it left to click"
        )
        let point = NSPoint(
            x: (PaneHeaderDefaults.assumedWindowControlsWidth + sidebarEdge) / 2,
            y: window.frame.height - Fixture.stripInset
        )

        doubleClick(window, at: point)

        XCTAssertNotEqual(window.frame, before, "A pane's view swallowed the strip's double-click")
    }

    private func firstSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for subview in view.subviews {
            if let split = firstSplitView(in: subview) { return split }
        }
        return nil
    }

    // MARK: - The System's Own Setting

    func testTheGestureIsWhateverSystemSettingsSaysItIs() {
        XCTAssertEqual(TitlebarDoubleClick.action(forPreference: "Minimize"), .minimize)
        XCTAssertEqual(TitlebarDoubleClick.action(forPreference: "None"), .doNothing)
        XCTAssertEqual(TitlebarDoubleClick.action(forPreference: "Maximize"), .zoom)
        XCTAssertEqual(
            TitlebarDoubleClick.action(forPreference: "Fill"),
            .zoom,
            "System Settings has renamed zoom before; an unknown spelling is still zoom"
        )
        XCTAssertEqual(
            TitlebarDoubleClick.action(forPreference: nil),
            .zoom,
            "Unset is the platform's default, which is zoom"
        )
    }

    func testTurningTheGestureOffLeavesTheWindowAlone() {
        let window = makeWindow()
        window.doubleClickAction = { .doNothing }
        let before = window.frame

        doubleClick(window, at: pointInStrip(of: window))

        XCTAssertEqual(window.frame, before, "\"Do Nothing\" has to mean it here too")
    }

    // MARK: - Why This Class Exists

    func testTheTitlebarStripHitTestsToTheContentViewOnlyWhenBothFlagsAreSet() throws {
        func contentViewAnswersTheStrip(fullSize: Bool, transparent: Bool) throws -> Bool {
            let window = makeWindow(fullSizeContentView: fullSize, transparentTitlebar: transparent)
            let frameView = try XCTUnwrap(window.contentView?.superview)
            return frameView.hitTest(pointInStrip(of: window)) === window.contentView
        }

        for combination in [(false, false), (false, true), (true, false)] {
            XCTAssertFalse(
                try contentViewAnswersTheStrip(fullSize: combination.0, transparent: combination.1),
                "fullSize=\(combination.0) transparent=\(combination.1): the titlebar still "
                    + "answers here, so AppKit's own double-click reaches it"
            )
        }

        XCTAssertTrue(
            try contentViewAnswersTheStrip(fullSize: true, transparent: true),
            "The platform behaviour TitlebarActionWindow exists for is gone; delete the class"
        )
    }
}
