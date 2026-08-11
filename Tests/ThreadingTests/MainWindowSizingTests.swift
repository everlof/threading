import AppKit
import XCTest
@testable import Threading

/// What may decide the main window's size, and what may not.
///
/// This exists because the window arrived one morning 3386 points tall on a 1084-point screen,
/// with its composer two thousand points below the bottom of the display — the user could not
/// read what they were typing, and dragging the top edge down did not bring it back. Two
/// separate things have to hold for that to be impossible, and each has its own case here:
/// the window must be *able* to be small, and a saved frame must not be able to put it off
/// screen.
@MainActor
final class MainWindowSizingTests: XCTestCase {

    private enum Fixture {
        /// A screen small enough that a window sized to a long conversation is obviously wrong.
        static let screen = NSRect(x: 0, y: 0, width: 1728, height: 1084)
        /// The frame that shipped the bug, read out of the user's own defaults.
        static let strandedFrame = NSRect(x: 0, y: -2302, width: 1728, height: 3386)
        /// AppKit's own slack: a titled window's frame carries a titlebar the content does not.
        static let titleBarSlack: CGFloat = 40
    }

    private var controller: MainWindowController?
    private var savedFrame: Any?

    override func setUp() {
        super.setUp()
        // `MainWindowController` names an autosave frame, and a hosted test's `UserDefaults` is
        // the developer's own — a window built here would otherwise decide what size the app
        // they are running launches into next. Put back in `tearDown` exactly as found.
        savedFrame = UserDefaults.standard.object(forKey: Self.autosaveKey)
    }

    override func tearDown() {
        controller = nil
        if let savedFrame {
            UserDefaults.standard.set(savedFrame, forKey: Self.autosaveKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.autosaveKey)
        }
        super.tearDown()
    }

    private static let autosaveKey = "NSWindow Frame ThreadingMainWindow"

    // MARK: - The Window Can Be Small

    /// The saved divider is the sidebar rows' final horizontal geometry. Mounting the tree in
    /// `MainWindowController.init` built and laid out the viewport there, then the next-turn
    /// width restore immediately laid the same rows out again. The real outline remains empty
    /// until that geometry turn and mounts before the following display cycle.
    func testTheInitialSidebarTreeWaitsForItsRestoredDivider() throws {
        let previousWidth = SidebarWidth.stored
        defer {
            if let previousWidth {
                SidebarWidth.record(previousWidth)
            } else {
                SidebarWidth.reset()
            }
        }
        let chosenWidth: CGFloat = 360
        SidebarWidth.record(chosenWidth)

        let controller = MainWindowController()
        self.controller = controller
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1_200, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertFalse(
            controller.initialSidebarTreeIsMounted,
            "the viewport mounted before the deferred divider-geometry turn"
        )

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        window.contentView?.layoutSubtreeIfNeeded()

        let sidebar = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        XCTAssertTrue(controller.initialSidebarTreeIsMounted)
        XCTAssertEqual(
            sidebar.viewController.view.frame.width,
            chosenWidth,
            accuracy: 1,
            "the tree mounted without the saved divider becoming its standing geometry"
        )
    }

    /// Nothing in the content may hold the window taller than `WindowDefaults.minHeight`.
    ///
    /// AppKit derives a window's minimum content size from the constraints it finds at
    /// `windowSizeStayPut` and above, so a single required height anywhere in the panes becomes
    /// a floor the user cannot drag through — the window stops, and from the outside that reads
    /// as the window being stuck rather than as a layout bug.
    func testTheWindowCanBeDraggedDownToItsOwnMinimum() throws {
        let controller = MainWindowController()
        self.controller = controller
        let window = try XCTUnwrap(controller.window)

        window.setContentSize(NSSize(
            width: WindowDefaults.minWidth,
            height: WindowDefaults.minHeight
        ))
        window.layoutIfNeeded()

        XCTAssertLessThanOrEqual(
            window.frame.height,
            WindowDefaults.minHeight + Fixture.titleBarSlack,
            """
            the window refused to shrink — something in the content holds a height floor. \
            Tallest offenders: \(Self.tallestSubtrees(of: window))
            """
        )
    }

    // MARK: - A Saved Frame Cannot Strand The Window

    /// The frame restored from the autosave must land on the screen, at a size that fits it.
    ///
    /// `setFrameUsingName` is the one door into a window's frame that AppKit does not police:
    /// measured, it never calls `constrainFrameRect(_:to:)` at all. A titled window is saved
    /// from itself by the *next* thing that constrains it; a frameless one — which is every
    /// window under a chrome-takeover theme — is not, so an oversized frame written once is
    /// restored verbatim on every launch afterwards.
    func testARestoredFrameLargerThanTheScreenIsBroughtBackOnScreen() throws {
        let held = MainWindowFrame.held(Fixture.strandedFrame, within: Fixture.screen)

        XCTAssertEqual(held.height, Fixture.screen.height, "a window may not be taller than the screen")
        XCTAssertEqual(held.width, Fixture.screen.width)
        XCTAssertEqual(held.minY, Fixture.screen.minY, "its bottom edge — the composer — must be reachable")
        XCTAssertEqual(held.minX, Fixture.screen.minX)
    }

    /// A frame that already fits is left alone, down to the point.
    func testAFrameThatFitsIsUntouched() {
        let fits = NSRect(x: 100, y: 100, width: 900, height: 600)

        XCTAssertEqual(MainWindowFrame.held(fits, within: Fixture.screen), fits)
    }

    /// Off the edge in each direction, the window is moved in rather than resized.
    func testAFrameOffTheEdgeIsMovedInsideAtItsOwnSize() {
        let offRight = MainWindowFrame.held(
            NSRect(x: 1700, y: 200, width: 900, height: 600), within: Fixture.screen
        )
        XCTAssertEqual(offRight, NSRect(x: 828, y: 200, width: 900, height: 600))

        let offTop = MainWindowFrame.held(
            NSRect(x: 100, y: 900, width: 900, height: 600), within: Fixture.screen
        )
        XCTAssertEqual(offTop, NSRect(x: 100, y: 484, width: 900, height: 600))

        let offBottom = MainWindowFrame.held(
            NSRect(x: 100, y: -500, width: 900, height: 600), within: Fixture.screen
        )
        XCTAssertEqual(offBottom, NSRect(x: 100, y: 0, width: 900, height: 600))
    }

    // MARK: - Which Screen The Frame Is On

    /// A frame saved on a second display is held inside *that* display, not the first one.
    ///
    /// `window.screen` is nil until the window is ordered on screen and `NSScreen.main` is the key
    /// window's screen, so choosing either would move a second-display window across the desk on
    /// every launch — a worse bug than the one this fixes.
    func testAFrameOnASecondDisplayIsHeldWithinThatDisplay() throws {
        let built_in = MainWindowFrame.Screen(
            frame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: Fixture.screen
        )
        let external = MainWindowFrame.Screen(
            frame: NSRect(x: 1728, y: 0, width: 2560, height: 1440),
            visibleFrame: NSRect(x: 1728, y: 0, width: 2560, height: 1400)
        )
        let onExternal = NSRect(x: 2000, y: 100, width: 1200, height: 900)

        let bounds = try XCTUnwrap(
            MainWindowFrame.bounds(for: onExternal, among: [built_in, external])
        )

        XCTAssertEqual(bounds, external.visibleFrame)
        XCTAssertEqual(MainWindowFrame.held(onExternal, within: bounds), onExternal,
                       "a frame that already fits its own display must not be moved at all")
    }

    /// A frame straddling two displays belongs to the one showing most of it.
    func testAStraddlingFrameBelongsToTheDisplayShowingMostOfIt() throws {
        let left = MainWindowFrame.Screen(
            frame: NSRect(x: 0, y: 0, width: 1728, height: 1117), visibleFrame: Fixture.screen
        )
        let right = MainWindowFrame.Screen(
            frame: NSRect(x: 1728, y: 0, width: 2560, height: 1440),
            visibleFrame: NSRect(x: 1728, y: 0, width: 2560, height: 1400)
        )
        let mostlyRight = NSRect(x: 1600, y: 100, width: 1000, height: 800)

        XCTAssertEqual(
            MainWindowFrame.bounds(for: mostlyRight, among: [left, right]), right.visibleFrame
        )
    }

    /// A display that has since been unplugged leaves the frame on no screen at all, and the
    /// caller — not this — decides where such a window goes.
    func testAFrameOnNoScreenHasNoBounds() {
        let built_in = MainWindowFrame.Screen(
            frame: NSRect(x: 0, y: 0, width: 1728, height: 1117), visibleFrame: Fixture.screen
        )
        let onAVanishedDisplay = NSRect(x: 4000, y: 2000, width: 1200, height: 900)

        XCTAssertNil(MainWindowFrame.bounds(for: onAVanishedDisplay, among: [built_in]))
    }

    /// The rule above is AppKit's own, not one invented here: a *titled* window asked the same
    /// questions answers the same way. This is the case that keeps the two from drifting.
    func testTheHeldFrameMatchesWhatAppKitDoesForATitledWindow() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let titled = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: WindowChromeCoordinator.nativeMask,
            backing: .buffered,
            defer: false
        )
        let cases = [
            Fixture.strandedFrame,
            NSRect(x: 0, y: 0, width: 4000, height: 600),
            NSRect(x: 100, y: 900, width: 900, height: 600),
            NSRect(x: 1700, y: 200, width: 900, height: 600),
            NSRect(x: 100, y: 100, width: 900, height: 600)
        ]

        for rect in cases {
            XCTAssertEqual(
                MainWindowFrame.held(rect, within: screen.visibleFrame),
                titled.constrainFrameRect(rect, to: screen),
                "\(rect) is held differently than AppKit holds a titled window"
            )
        }
    }

    // MARK: - Diagnostics

    /// The subtrees asking for the most height, tallest first — what a failure needs to name.
    private static func tallestSubtrees(of window: NSWindow, limit: Int = 5) -> String {
        guard let root = window.contentView else { return "no content view" }
        var found: [(String, CGFloat)] = []

        func walk(_ view: NSView, depth: Int) {
            let height = view.fittingSize.height
            if height > WindowDefaults.minHeight {
                found.append(("\(String(repeating: "·", count: depth))\(type(of: view))", height))
            }
            for subview in view.subviews { walk(subview, depth: depth + 1) }
        }
        walk(root, depth: 0)

        return found
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { "\($0.0) wants \(Int($0.1))pt" }
            .joined(separator: ", ")
    }
}
