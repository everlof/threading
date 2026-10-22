import AppKit
import XCTest
@testable import Threading

/// A session's panel in a window of its own.
///
/// The window shows the same `DisplayPaneController` the side panel and every docked group are,
/// scoped to the window. Two things follow and most of what is worth asserting here comes from
/// them: the panel is **pinned** to one session rather than following the selection — a panel
/// that answered for whatever session it was asked about would hand another session's agent the
/// wrong page — and it holds only what its layout can bring back at the next launch.
@MainActor
final class DetachedPaneWindowTests: HostedStoreTestCase {

    private func makePanel(session: SessionID = SessionID(), windowID: UUID = UUID()) -> DisplayPaneController {
        let panel = DisplayPaneController(scope: .detachedWindow(windowID, session: session))
        _ = panel.view
        panel.showSessionTabs(session)
        return panel
    }

    private func makeWindow(
        session: SessionID = SessionID(),
        windowID: UUID = UUID(),
        droppedAt point: NSPoint? = nil
    ) -> DetachedPaneWindowController {
        DetachedPaneWindowController(sessionID: session, windowID: windowID, droppedAt: point)
    }

    private func document(_ title: String) -> DisplayContent {
        DisplayContent(body: .html("<p>\(title)</p>"), title: title, subtitle: "Document")
    }

    // MARK: - What may travel

    func testAWindowHoldsWhatItsLayoutCanRestore() {
        XCTAssertTrue(PaneTab(body: .browser(BrowserViewController(contextKind: .shared))).canLiveInDetachedWindow)
        XCTAssertTrue(PaneTab(body: .content(document("Report"))).canLiveInDetachedWindow)
        XCTAssertFalse(
            PaneTab(body: .browser(BrowserViewController(contextKind: .private))).canLiveInDetachedWindow,
            "a private context cannot be restored, so a window holding one forgets it on relaunch"
        )
    }

    /// The tab's answer and the window's must agree: the menu offers "Open in New Window" from
    /// the first and the move is refused by the second, so a disagreement is an item that beeps.
    func testTheMenusQuestionAndTheMovesAnswerAreTheSame() {
        let panel = makePanel()
        for tab in [
            PaneTab(body: .browser(BrowserViewController(contextKind: .shared))),
            PaneTab(body: .browser(BrowserViewController(contextKind: .private))),
            PaneTab(body: .content(document("Report")))
        ] {
            XCTAssertEqual(tab.canLiveInDetachedWindow, panel.canAdopt(tab))
        }
    }

    /// `+` in a window offers what the window could hold. A Terminal entry there would build a
    /// shell inked for the main window's palette; a Private Browser one, a tab the next launch
    /// forgets.
    func testAWindowsNewTabMenuOffersOnlyWhatItCanHold() {
        let session = SessionID()
        let ids: (DisplayPaneController) -> Set<String> = { panel in
            Set(panel.newTabEntries(for: session).compactMap { $0.item?.representedValue as? String })
        }
        let window = ids(makePanel(session: session))
        let side = ids(DisplayPaneController())

        for refused in [
            AppCommands.ID.newTerminalTab, "panel.privateBrowser", "panel.notificationTest",
            "panel.webExtensions", AppCommands.ID.currentTheme
        ] {
            XCTAssertFalse(window.contains(refused), "a detached window offered \(refused)")
        }
        XCTAssertTrue(window.contains("panel.browser"))
        XCTAssertTrue(window.contains(AppCommands.ID.review))
        XCTAssertTrue(window.contains("panel.compare"))
        XCTAssertTrue(side.contains(AppCommands.ID.newTerminalTab), "the filter belongs to the window alone")
        XCTAssertTrue(side.contains("panel.privateBrowser"))
    }

    // MARK: - Pinning

    func testThePanelAnswersOnlyForItsOwnSession() {
        let session = SessionID()
        let other = SessionID()
        let panel = makePanel(session: session)
        panel.addBrowserTab(for: session)

        XCTAssertEqual(panel.tabs(for: session as SessionID?).count, 1)
        XCTAssertEqual(panel.browserTabs(for: session).count, 1)
        XCTAssertNotNil(panel.preferredBrowserTabID(for: session))

        XCTAssertTrue(panel.tabs(for: other as SessionID?).isEmpty)
        XCTAssertTrue(panel.browserTabs(for: other).isEmpty)
        XCTAssertNil(
            panel.preferredBrowserTabID(for: other),
            "the window offered its page to a session it does not belong to"
        )
    }

    /// A nil session means "whatever scope you have", which for a pinned panel is its own.
    func testANilSessionMeansThisWindowsOwn() {
        let session = SessionID()
        let panel = makePanel(session: session)
        panel.addContentTab(document("Report"), for: session)
        XCTAssertEqual(panel.tabs(for: nil).count, 1)
    }

    /// The tab has to know whose it is, because a move back reads that rather than the
    /// selection — a window pinned to one session while the main window shows another is
    /// exactly when the two disagree.
    func testAnAdoptedTabTakesTheWindowsSession() {
        let session = SessionID()
        let panel = makePanel(session: session)
        let tab = PaneTab(body: .content(document("Report")))
        XCTAssertNil(tab.owningSessionID)

        panel.adopt(tab, at: nil, for: session)

        XCTAssertEqual(tab.owningSessionID, session)
        XCTAssertEqual(panel.tabs(for: session as SessionID?).map(\.id), [tab.id])
    }

    func testATabOfAnotherSessionIsRefused() {
        let panel = makePanel()
        let tab = PaneTab(body: .content(document("Report")), owningSessionID: SessionID())
        XCTAssertFalse(panel.canAdopt(tab))
    }

    // MARK: - Transfer

    /// The whole promise of a move: the same object, reparented — so the browser keeps its page
    /// rather than being rebuilt from a URL.
    func testAMovedTabKeepsItsController() throws {
        let session = SessionID()
        let source = makePanel(session: session)
        let destination = makePanel(session: session)

        let browser = try XCTUnwrap(source.addBrowserTab(for: session))
        let tabID = try XCTUnwrap(source.tabs(for: session as SessionID?).first?.id)

        let detached = try XCTUnwrap(source.detachTab(id: tabID, for: session))
        XCTAssertTrue(source.tabs(for: session as SessionID?).isEmpty)
        XCTAssertTrue(detached.browser === browser, "the move rebuilt the browser")

        destination.adopt(detached, at: nil, for: session)
        XCTAssertTrue(destination.tabs(for: session as SessionID?).first?.browser === browser)
    }

    // MARK: - Emptying

    /// A window with no tabs is no window: its record must stop carrying any, or the next launch
    /// restores an empty frame.
    func testTheLastTabClosingEmptiesTheWindowAndItsLayout() throws {
        let session = SessionID()
        let controller = makeWindow(session: session)
        defer { controller.window?.orderOut(nil) }
        controller.host.addContentTab(document("Report"), for: session)
        XCTAssertFalse(controller.isEmpty)
        XCTAssertEqual(controller.persistedLayout.tabs.count, 1)

        XCTAssertTrue(controller.closeActiveTabInWindow())

        XCTAssertTrue(controller.isEmpty)
        XCTAssertTrue(controller.persistedLayout.tabs.isEmpty)
        XCTAssertNil(controller.persistedLayout.window.activeTabID)
    }

    /// A window emptied by a *move* is as empty as one emptied by a close, and goes the same way
    /// — otherwise dragging the last tab back leaves a blank window behind.
    func testTheLastTabMovingOutAlsoEmptiesTheWindow() throws {
        let session = SessionID()
        let controller = makeWindow(session: session)
        defer { controller.window?.orderOut(nil) }
        controller.host.addContentTab(document("Report"), for: session)
        let tabID = try XCTUnwrap(controller.host.tabs(for: session as SessionID?).first?.id)

        XCTAssertNotNil(controller.host.detachTab(id: tabID, for: session))

        XCTAssertTrue(controller.isEmpty)
    }

    // MARK: - Keyboard commands

    func testClosingTheActiveTabFromTheKeyboardClosesThatOne() throws {
        let session = SessionID()
        let controller = makeWindow(session: session)
        defer { controller.window?.orderOut(nil) }
        controller.host.addContentTab(document("First"), for: session)
        controller.host.addContentTab(document("Second"), for: session)
        let secondID = try XCTUnwrap(controller.host.tabs(for: session as SessionID?).last?.id)
        XCTAssertEqual(controller.host.activeTabID(for: session), secondID)

        XCTAssertTrue(controller.closeActiveTabInWindow())

        XCTAssertEqual(controller.tabCount, 1)
        XCTAssertFalse(controller.host.tabs(for: session as SessionID?).contains { $0.id == secondID })
    }

    func testCyclingWrapsAndNeedsMoreThanOneTab() throws {
        let session = SessionID()
        let controller = makeWindow(session: session)
        defer { controller.window?.orderOut(nil) }
        controller.host.addContentTab(document("First"), for: session)
        XCTAssertFalse(controller.selectAdjacentTab(offset: 1), "one tab has nothing to cycle to")

        controller.host.addContentTab(document("Second"), for: session)
        let ids = controller.host.tabs(for: session as SessionID?).map(\.id)
        XCTAssertEqual(controller.host.activeTabID(for: session), ids[1])

        XCTAssertTrue(controller.selectAdjacentTab(offset: 1))
        XCTAssertEqual(controller.host.activeTabID(for: session), ids[0], "cycling did not wrap")
        XCTAssertTrue(controller.selectAdjacentTab(offset: -1))
        XCTAssertEqual(controller.host.activeTabID(for: session), ids[1])
    }

    /// ⌘9 is not a request for the last tab; it is a miss.
    func testAnOutOfRangeNumberFailsRatherThanClamping() {
        let session = SessionID()
        let controller = makeWindow(session: session)
        defer { controller.window?.orderOut(nil) }
        controller.host.addContentTab(document("Only"), for: session)

        XCTAssertTrue(controller.selectTab(atIndex: 0))
        XCTAssertFalse(controller.selectTab(atIndex: 1))
        XCTAssertFalse(controller.selectTab(atIndex: -1))
    }

    /// **The invariant the whole routing rests on.** The menu items are nil-target, so a key
    /// detached window intercepts them by implementing the *same selectors* the application
    /// delegate does. Nothing in the type system ties the two together — rename the handler on
    /// one side and the window silently stops answering, which is how ⌘W goes back to closing a
    /// tab in the window behind. So the coupling is asserted directly.
    func testTheWindowAnswersTheSelectorsTheApplicationDelegateDoes() {
        let controller = makeWindow()
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
        let session = SessionID()
        let controller = makeWindow(session: session)
        defer { controller.window?.orderOut(nil) }

        let close = NSMenuItem(title: "", action: #selector(
            DetachedPaneWindowController.closeActiveTab
        ), keyEquivalent: "")
        let next = NSMenuItem(title: "", action: #selector(
            DetachedPaneWindowController.selectNextTab
        ), keyEquivalent: "")
        let second = NSMenuItem(title: "", action: #selector(
            DetachedPaneWindowController.selectTabByNumber(_:)
        ), keyEquivalent: "")
        second.tag = 2

        XCTAssertFalse(controller.validateMenuItem(close), "an empty window offered Close Tab")
        XCTAssertFalse(controller.validateMenuItem(next))
        XCTAssertFalse(controller.validateMenuItem(second))

        controller.host.addContentTab(document("First"), for: session)
        XCTAssertTrue(controller.validateMenuItem(close))
        XCTAssertFalse(controller.validateMenuItem(next), "one tab has nothing to cycle to")
        XCTAssertFalse(controller.validateMenuItem(second), "there is no second tab")

        controller.host.addContentTab(document("Second"), for: session)
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

        let controller = makeWindow(droppedAt: drop)
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

        let controller = makeWindow(droppedAt: corner)
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
        let controller = makeWindow()
        defer { controller.window?.orderOut(nil) }
        let frame = try XCTUnwrap(controller.window?.frame)

        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
    }

    // MARK: - Drop band

    /// The band is asked in **screen** coordinates, because the gesture crosses windows: there is
    /// no single window whose coordinates both ends of a drag from the display panel into this
    /// window would share. Each host converts into its own.
    func testTheDropBandIsTheStripsRowInScreenSpace() {
        let panel = makePanel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        panel.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(panel.view)
        window.contentView?.layoutSubtreeIfNeeded()

        func onScreen(_ point: NSPoint) -> NSPoint { window.convertPoint(toScreen: point) }
        let inBand = NSPoint(x: 200, y: 300 - PaneHeaderView.bandHeight / 2)

        XCTAssertTrue(panel.isDropBandVisible)
        XCTAssertTrue(panel.dropBandContains(screenPoint: onScreen(inBand)))
        XCTAssertFalse(
            panel.dropBandContains(screenPoint: onScreen(NSPoint(x: 200, y: 100))),
            "the content below the band is the tab's, not a drop zone"
        )
        XCTAssertFalse(
            panel.dropBandContains(screenPoint: onScreen(NSPoint(x: 500, y: inBand.y)))
        )

        let outside = onScreen(inBand)
        panel.view.removeFromSuperview()
        XCTAssertFalse(panel.isDropBandVisible)
        XCTAssertFalse(
            panel.dropBandContains(screenPoint: outside),
            "off the window there is no band to hit"
        )
    }

    // MARK: - Persistence

    func testTheLayoutNamesThisWindowAndItsSelection() throws {
        let session = SessionID()
        let controller = makeWindow(session: session)
        defer { controller.window?.orderOut(nil) }
        controller.host.addContentTab(document("Report"), for: session)
        let tabID = try XCTUnwrap(controller.host.tabs(for: session as SessionID?).first?.id)

        let layout = controller.persistedLayout
        XCTAssertEqual(layout.window.id, controller.windowID.uuidString)
        XCTAssertEqual(layout.window.activeTabID, tabID.uuidString)
        XCTAssertEqual(layout.tabs.map(\.id), [tabID.uuidString])
        XCTAssertEqual(layout.tabs.first?.kind, .html)
        XCTAssertEqual(layout.tabs.first?.detachedWindowID, controller.windowID)
        XCTAssertEqual(controller.windowTitle, "Report", "the window is named for the tab on show")
    }

    /// A browser with no page is nothing to restore, so it is not written — and the selection
    /// must not name a tab that was dropped, or the document refuses to load next launch.
    func testAPagelessBrowserIsNotPersistedAndCannotBeTheSelection() {
        let session = SessionID()
        let controller = makeWindow(session: session)
        defer { controller.window?.orderOut(nil) }
        controller.host.addBrowserTab(for: session)

        XCTAssertTrue(controller.persistedLayout.tabs.isEmpty)
        XCTAssertNil(
            controller.persistedLayout.window.activeTabID,
            "the selection named a tab the document does not contain"
        )
    }

    /// Its own id, so a session with two windows keeps them apart in one flat tab list.
    func testEachWindowsTabsCarryItsOwnIdentifier() {
        let session = SessionID()
        let first = makeWindow(session: session)
        let second = makeWindow(session: session)
        defer {
            first.window?.orderOut(nil)
            second.window?.orderOut(nil)
        }
        first.host.addContentTab(document("A"), for: session)
        second.host.addContentTab(document("B"), for: session)

        XCTAssertNotEqual(first.windowID, second.windowID)
        XCTAssertEqual(first.persistedLayout.tabs.first?.detachedWindowID, first.windowID)
        XCTAssertEqual(second.persistedLayout.tabs.first?.detachedWindowID, second.windowID)
    }

    /// **The point of building the window from the panel.** The browser-only window rebuilt every
    /// stored tab as a browser; this one reads its slice back through the restore every pane uses,
    /// so each tab returns as the kind it left as, in its order, with its selection.
    func testARestoredWindowBringsEachTabBackAsItsOwnKind() throws {
        let session = SessionID()
        let windowID = UUID()
        let documentID = UUID().uuidString
        let browserID = UUID().uuidString
        let host = PersistedTab.detachedWindowHost(windowID)
        DisplayPaneStore.shared.saveDetachedWindowLayout(
            PersistedDetachedWindow(
                id: windowID.uuidString, frame: nil, activeTabID: documentID, isFullScreen: nil
            ),
            tabs: [
                PersistedTab(
                    id: browserID, kind: .browser, title: "Page", subtitle: "",
                    url: "https://example.invalid/page", html: nil, cacheFile: nil, host: host
                ),
                PersistedTab(
                    id: documentID, kind: .html, title: "Report", subtitle: "Document",
                    url: nil, html: "<p>Report</p>", cacheFile: nil, host: host
                )
            ],
            for: session
        )

        let controller = makeWindow(session: session, windowID: windowID)
        defer { controller.window?.orderOut(nil) }
        let tabs = controller.host.tabs(for: session as SessionID?)

        XCTAssertEqual(tabs.map(\.id.uuidString), [browserID, documentID])
        XCTAssertEqual(tabs.first?.browser?.restoredURL, "https://example.invalid/page")
        guard case .html("<p>Report</p>")? = tabs.last?.content?.body else {
            return XCTFail("the document came back as something other than itself")
        }
        XCTAssertEqual(controller.host.activeTabID(for: session)?.uuidString, documentID)
        XCTAssertEqual(controller.persistedLayout.tabs.map(\.id), [browserID, documentID])
    }

    /// A build that predates this rebuilt every tab in a window as a browser and would write the
    /// loss back, so a window holding anything else has to make that build refuse the document.
    /// A browser-only window stays readable by it.
    func testAWindowHoldingMoreThanBrowsersNeedsTheNewFormat() {
        let windowID = UUID()
        let host = PersistedTab.detachedWindowHost(windowID)
        var panel = PersistedPanel(tabs: [], activeTabID: nil, observedSignature: nil)
        panel.detachedWindows = [PersistedDetachedWindow(id: windowID.uuidString)]

        panel.tabs = [PersistedTab(id: "b", kind: .browser, title: nil, subtitle: "", host: host)]
        XCTAssertEqual(panel.requiredFormatVersion, 2)

        panel.tabs.append(PersistedTab(id: "d", kind: .html, title: nil, subtitle: "", html: "<p>", host: host))
        XCTAssertEqual(panel.requiredFormatVersion, 9)
        XCTAssertEqual(PersistedPanel.currentFormatVersion, 9)
    }
}
