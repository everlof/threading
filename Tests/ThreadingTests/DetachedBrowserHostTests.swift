import AppKit
import XCTest
@testable import Threading

/// The tab host inside a detached browser window.
///
/// Its one real difference from the panel and the drawer is that it is **pinned**: it holds one
/// session for its whole life rather than following the selection. Most of what is worth
/// asserting here follows from that — a host that answered for whatever session it was asked
/// about would hand another session's agent the wrong page.
@MainActor
final class DetachedBrowserHostTests: XCTestCase {

    private func makeHost(session: SessionID = SessionID()) -> DetachedBrowserHostViewController {
        let host = DetachedBrowserHostViewController(sessionID: session)
        _ = host.view
        return host
    }

    // MARK: - What may travel

    func testOnlySharedBrowsersMayLiveInAWindow() {
        let shared = PaneTab(body: .browser(BrowserViewController(contextKind: .shared)))
        let secret = PaneTab(body: .browser(BrowserViewController(contextKind: .private)))

        XCTAssertTrue(DetachedBrowserHostViewController.canHold(shared))
        XCTAssertFalse(
            DetachedBrowserHostViewController.canHold(secret),
            "a private context cannot be restored, so a window holding one forgets it on relaunch"
        )
        XCTAssertTrue(makeHost().canAdopt(shared))
        XCTAssertFalse(makeHost().canAdopt(secret))
    }

    /// The static and the instance answer must agree: the menu offers "Open in New Window" from
    /// the first and the move is refused by the second, so a disagreement is an item that beeps.
    func testTheMenusQuestionAndTheMovesAnswerAreTheSame() {
        let host = makeHost()
        for tab in [
            PaneTab(body: .browser(BrowserViewController(contextKind: .shared))),
            PaneTab(body: .browser(BrowserViewController(contextKind: .private)))
        ] {
            XCTAssertEqual(DetachedBrowserHostViewController.canHold(tab), host.canAdopt(tab))
        }
    }

    // MARK: - Pinning

    func testTheHostAnswersOnlyForItsOwnSession() {
        let session = SessionID()
        let other = SessionID()
        let host = makeHost(session: session)
        host.addBrowserTab()

        XCTAssertEqual(host.tabs(for: session).count, 1)
        XCTAssertEqual(host.browserTabs(for: session).count, 1)
        XCTAssertNotNil(host.preferredBrowserTabID(for: session))

        XCTAssertTrue(host.tabs(for: other).isEmpty)
        XCTAssertTrue(host.browserTabs(for: other).isEmpty)
        XCTAssertNil(
            host.preferredBrowserTabID(for: other),
            "the window offered its page to a session it does not belong to"
        )
    }

    /// A nil session means "whatever scope you have", which for a pinned host is its own.
    func testANilSessionMeansThisHostsOwn() {
        let host = makeHost()
        host.addBrowserTab()
        XCTAssertEqual(host.tabs(for: nil).count, 1)
    }

    /// The tab has to know whose it is, because a move back reads that rather than the
    /// selection — a window pinned to one session while the main window shows another is
    /// exactly when the two disagree.
    func testAnAdoptedTabTakesTheWindowsSession() {
        let session = SessionID()
        let host = makeHost(session: session)
        let tab = PaneTab(body: .browser(BrowserViewController(contextKind: .shared)))
        XCTAssertNil(tab.owningSessionID)

        host.adopt(tab, at: nil, for: session)

        XCTAssertEqual(tab.owningSessionID, session)
    }

    func testACreatedTabAlsoKnowsWhoseItIs() {
        let session = SessionID()
        let host = makeHost(session: session)
        host.addBrowserTab()
        XCTAssertEqual(host.tabs(for: session).first?.owningSessionID, session)
    }

    // MARK: - Transfer

    /// The whole promise of a move: the same object, reparented — so the browser keeps its page
    /// rather than being rebuilt from a URL.
    func testAMovedTabKeepsItsBrowser() throws {
        let session = SessionID()
        let source = makeHost(session: session)
        let destination = makeHost(session: session)

        let browser = source.addBrowserTab()
        let tabID = try XCTUnwrap(source.tabs(for: session).first?.id)

        let detached = try XCTUnwrap(source.detachTab(id: tabID, for: session))
        XCTAssertTrue(source.tabs(for: session).isEmpty)
        XCTAssertTrue(detached.browser === browser, "the move rebuilt the browser")

        destination.adopt(detached, at: nil, for: session)
        XCTAssertTrue(destination.tabs(for: session).first?.browser === browser)
    }

    // MARK: - Emptying

    func testTheLastTabLeavingReportsTheWindowEmpty() throws {
        let session = SessionID()
        let host = makeHost(session: session)
        host.addBrowserTab()
        let tabID = try XCTUnwrap(host.tabs(for: session).first?.id)

        var emptied = false
        host.onEmptied = { emptied = true }

        XCTAssertTrue(host.closeTab(id: tabID, for: session))
        XCTAssertTrue(emptied, "a window with no tabs would have stayed on screen empty")
        XCTAssertTrue(host.isEmpty)
    }

    /// A window emptied by a *move* is as empty as one emptied by a close, and has to go the
    /// same way — otherwise dragging the last tab back leaves a blank window behind.
    func testTheLastTabMovingOutAlsoReportsEmpty() throws {
        let session = SessionID()
        let host = makeHost(session: session)
        host.addBrowserTab()
        let tabID = try XCTUnwrap(host.tabs(for: session).first?.id)

        var emptied = false
        host.onEmptied = { emptied = true }

        _ = host.detachTab(id: tabID, for: session)
        XCTAssertTrue(emptied)
    }

    // MARK: - Keyboard commands

    func testClosingTheActiveTabFromTheKeyboardClosesThatOne() throws {
        let session = SessionID()
        let host = makeHost(session: session)
        host.addBrowserTab()
        let second = host.addBrowserTab()
        let secondID = try XCTUnwrap(host.tabs(for: session).last?.id)
        XCTAssertEqual(host.activeTabID(for: session), secondID)

        XCTAssertTrue(host.closeActiveTab())

        XCTAssertEqual(host.tabCount, 1)
        XCTAssertFalse(host.tabs(for: session).contains { $0.browser === second })
    }

    func testCyclingWrapsAndNeedsMoreThanOneTab() throws {
        let session = SessionID()
        let host = makeHost(session: session)
        host.addBrowserTab()
        XCTAssertFalse(host.selectAdjacentTab(offset: 1), "one tab has nothing to cycle to")

        host.addBrowserTab()
        let ids = host.tabs(for: session).map(\.id)
        XCTAssertEqual(host.activeTabID(for: session), ids[1])

        XCTAssertTrue(host.selectAdjacentTab(offset: 1))
        XCTAssertEqual(host.activeTabID(for: session), ids[0], "cycling did not wrap")
        XCTAssertTrue(host.selectAdjacentTab(offset: -1))
        XCTAssertEqual(host.activeTabID(for: session), ids[1])
    }

    /// ⌘9 is not a request for the last tab; it is a miss.
    func testAnOutOfRangeNumberFailsRatherThanClamping() {
        let host = makeHost()
        host.addBrowserTab()

        XCTAssertTrue(host.selectTab(atIndex: 0))
        XCTAssertFalse(host.selectTab(atIndex: 1))
        XCTAssertFalse(host.selectTab(atIndex: -1))
    }

    /// **The invariant the whole routing rests on.** The menu items are nil-target, so a key
    /// detached window intercepts them by implementing the *same selectors* the application
    /// delegate does. Nothing in the type system ties the two together — rename the handler on
    /// one side and the window silently stops answering, which is how ⌘W goes back to closing a
    /// tab in the window behind. So the coupling is asserted directly.
    func testTheWindowAnswersTheSelectorsTheApplicationDelegateDoes() {
        let controller = DetachedBrowserWindowController(
            host: makeHost(),
            restoredFrame: nil
        )
        defer { controller.window?.orderOut(nil) }
        let delegate = AppDelegate()

        for name in [
            "closeActiveTab",
            "selectPreviousTab",
            "selectNextTab",
            "selectTabByNumber:"
        ] {
            let selector = Selector(name)
            XCTAssertTrue(
                delegate.responds(to: selector),
                "\(name) is no longer the application delegate's selector, so the detached "
                    + "window is intercepting a command nothing sends"
            )
            XCTAssertTrue(
                controller.responds(to: selector),
                "a key detached window would not answer \(name), so it would reach the main "
                    + "window and act on the tabs behind it"
            )
        }
    }

    func testTheWindowValidatesTheTabCommandsAgainstItsOwnTabs() {
        let host = makeHost()
        let controller = DetachedBrowserWindowController(host: host, restoredFrame: nil)
        defer { controller.window?.orderOut(nil) }

        let close = NSMenuItem(title: "", action: #selector(
            DetachedBrowserWindowController.closeActiveTab
        ), keyEquivalent: "")
        let next = NSMenuItem(title: "", action: #selector(
            DetachedBrowserWindowController.selectNextTab
        ), keyEquivalent: "")
        let second = NSMenuItem(title: "", action: #selector(
            DetachedBrowserWindowController.selectTabByNumber(_:)
        ), keyEquivalent: "")
        second.tag = 2

        XCTAssertFalse(controller.validateMenuItem(close), "an empty window offered Close Tab")
        XCTAssertFalse(controller.validateMenuItem(next))
        XCTAssertFalse(controller.validateMenuItem(second))

        host.addBrowserTab()
        XCTAssertTrue(controller.validateMenuItem(close))
        XCTAssertFalse(controller.validateMenuItem(next), "one tab has nothing to cycle to")
        XCTAssertFalse(controller.validateMenuItem(second), "there is no second tab")

        host.addBrowserTab()
        XCTAssertTrue(controller.validateMenuItem(next))
        XCTAssertTrue(controller.validateMenuItem(second))
    }

    // MARK: - Where a torn-off window lands

    /// Carried out of the window by hand, so the new window arrives under that hand rather than
    /// wherever the app would have cascaded it.
    func testATornOffWindowLandsUnderThePointerThatDroppedIt() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        let drop = NSPoint(x: visible.midX, y: visible.midY)

        let controller = DetachedBrowserWindowController(
            host: makeHost(),
            restoredFrame: nil,
            droppedAt: drop
        )
        defer { controller.window?.orderOut(nil) }
        let frame = try XCTUnwrap(controller.window?.frame)

        // The promise is "the window arrives under the hand", not an exact offset: the default
        // window is nearly as large as a laptop display, so the clamp that keeps it on screen
        // routinely moves it. Asserting the offset would have been asserting the clamp.
        XCTAssertTrue(
            frame.contains(drop),
            "the window did not arrive under the pointer that dropped the tab"
        )
        XCTAssertTrue(visible.intersects(frame))
    }

    /// A window whose titlebar is off the top of a display cannot be dragged back, so the drop
    /// is clamped to the screen it happened on.
    func testATornOffWindowIsClampedToItsScreen() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        let corner = NSPoint(x: visible.maxX - 2, y: visible.maxY - 2)

        let controller = DetachedBrowserWindowController(
            host: makeHost(),
            restoredFrame: nil,
            droppedAt: corner
        )
        defer { controller.window?.orderOut(nil) }
        let frame = try XCTUnwrap(controller.window?.frame)

        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX + 1)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY + 1)
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX - 1)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY - 1)
    }

    /// No drop point means the menu's own "Open in New Window", which cascades off the main
    /// window instead — the two entrances place the window differently on purpose.
    func testWithoutADropPointTheWindowIsNotPlacedAtThePointer() throws {
        let controller = DetachedBrowserWindowController(host: makeHost(), restoredFrame: nil)
        defer { controller.window?.orderOut(nil) }
        let frame = try XCTUnwrap(controller.window?.frame)

        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
    }

    // MARK: - Drop band

    /// The band is asked in **screen** coordinates, because the gesture now crosses windows:
    /// there is no single window whose coordinates both ends of a drag from the display panel
    /// into this window would share. Each host converts into its own.
    func testTheDropBandIsTheStripsRowInScreenSpace() {
        let host = makeHost()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(host.view)
        window.contentView?.layoutSubtreeIfNeeded()

        func onScreen(_ point: NSPoint) -> NSPoint { window.convertPoint(toScreen: point) }
        let inBand = NSPoint(x: 200, y: 300 - ThemedTabStripView.bandHeight / 2)

        XCTAssertTrue(host.isDropBandVisible)
        XCTAssertTrue(host.dropBandContains(screenPoint: onScreen(inBand)))
        XCTAssertFalse(
            host.dropBandContains(screenPoint: onScreen(NSPoint(x: 200, y: 100))),
            "the page below the band is the tab's content, not a drop zone"
        )
        XCTAssertFalse(
            host.dropBandContains(screenPoint: onScreen(NSPoint(x: 500, y: inBand.y)))
        )

        let outside = onScreen(inBand)
        host.view.removeFromSuperview()
        XCTAssertFalse(host.isDropBandVisible)
        XCTAssertFalse(
            host.dropBandContains(screenPoint: outside),
            "off the window there is no band to hit"
        )
    }

    // MARK: - Persistence

    func testPersistedTabsCarryThisWindowsHost() throws {
        let session = SessionID()
        let host = makeHost(session: session)
        let browser = try XCTUnwrap(host.addBrowserTab())
        browser.restoredURL = "https://example.com/page"

        let persisted = host.persistedTabs
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.detachedWindowID, host.windowID)
        XCTAssertEqual(persisted.first?.url, "https://example.com/page")
        XCTAssertEqual(persisted.first?.kind, .browser)
    }

    /// A browser with no page is nothing to restore, so it is not written — and the selection
    /// must not name a tab that was dropped, or the document refuses to load next launch.
    func testAPagelessBrowserIsNotPersistedAndCannotBeTheSelection() {
        let host = makeHost()
        host.addBrowserTab()

        XCTAssertTrue(host.persistedTabs.isEmpty)
        XCTAssertNil(
            host.persistedActiveTabID,
            "the selection named a tab the document does not contain"
        )
    }

    func testARestoredWindowComesBackWithItsTabs() throws {
        let session = SessionID()
        let host = makeHost(session: session)

        let tabID = UUID()
        host.restore(
            [PaneTab(
                id: tabID,
                body: .browser(host.makeRestoredBrowser(url: "https://example.com/restored"))
            )],
            activeID: tabID
        )

        XCTAssertEqual(host.tabs(for: session).map(\.id), [tabID])
        XCTAssertEqual(host.activeTabID(for: session), tabID)
        XCTAssertEqual(host.tabs(for: session).first?.owningSessionID, session)
        XCTAssertEqual(host.persistedTabs.first?.url, "https://example.com/restored")
    }

    /// Its own id, so a session with two windows keeps them apart in one flat tab list.
    func testEachWindowsTabsCarryItsOwnIdentifier() {
        let session = SessionID()
        let first = makeHost(session: session)
        let second = makeHost(session: session)
        first.addBrowserTab()?.restoredURL = "https://example.com/a"
        second.addBrowserTab()?.restoredURL = "https://example.com/b"

        XCTAssertNotEqual(first.windowID, second.windowID)
        XCTAssertEqual(first.persistedTabs.first?.detachedWindowID, first.windowID)
        XCTAssertEqual(second.persistedTabs.first?.detachedWindowID, second.windowID)
    }
}
