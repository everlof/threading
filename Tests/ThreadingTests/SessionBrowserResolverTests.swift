import AppKit
import XCTest
@testable import Threading

/// Finding the browser an agent drives, once a browser tab can live somewhere other than the
/// display panel.
///
/// Both bugs these cover were the same mistake wearing two hats: resolution that consulted every
/// host paired with confirmation that consulted only the panel. `browser_navigate` built a second
/// browser beside the one the user had moved, and every lease-gated tool refused a page that was
/// plainly on screen.
@MainActor
final class SessionBrowserResolverTests: XCTestCase {

    private final class PayloadStore {
        var panels: [SessionID: PersistedPanel] = [:]
    }

    /// The drawer built the way `TabTransferTests` builds one: in-memory persistence, because the
    /// real store writes through `StateManager.shared` — the developer's own database.
    private func makeDrawer(store: PayloadStore) -> DrawerHostViewController {
        let host = DrawerHostViewController(
            directoryProvider: { _ in URL(fileURLWithPath: NSTemporaryDirectory()) },
            loadPanel: { store.panels[$0] },
            persistDrawer: { tabs, activeID, open, sessionID in
                var panel = store.panels[sessionID]
                    ?? PersistedPanel(tabs: [], activeTabID: nil, observedSignature: nil)
                panel.tabs = panel.panelTabs + tabs
                panel.drawerActiveTabID = activeID
                if let open { panel.drawerOpen = open }
                store.panels[sessionID] = panel
            }
        )
        _ = host.view
        return host
    }

    private func makeResolver(
        panel: DisplayPaneController,
        drawer: DrawerHostViewController
    ) -> SessionBrowserResolver {
        SessionBrowserResolver(hosts: { [(.displayPanel, panel), (.drawer, drawer)] })
    }

    private func closePanelTabs(_ panel: DisplayPaneController, _ sessionID: SessionID) {
        for tab in panel.tabs(for: sessionID) {
            _ = panel.closeTab(id: tab.id, for: sessionID)
        }
    }

    // MARK: - Resolution across hosts

    func testABrowserOutsideThePanelIsStillTheSessionsBrowser() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        drawer.showSession(sessionID)
        defer { closePanelTabs(panel, sessionID) }

        let moved = drawer.addBrowserTab(for: sessionID)
        let resolver = makeResolver(panel: panel, drawer: drawer)

        let location = try XCTUnwrap(
            resolver.location(for: sessionID),
            "a browser in the drawer left the session with no browser at all"
        )
        XCTAssertTrue(location.browser === moved)
        XCTAssertEqual(location.hostID, .drawer)
    }

    /// The lease's own lookup. It used to ask the *panel* for the tab holding a browser the
    /// resolution had already found in another host, so it found nothing and every gated tool
    /// answered "No authorized page is loaded" about a loaded page.
    func testAParticularBrowserIsLocatedOutsideThePanel() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        drawer.showSession(sessionID)
        defer { closePanelTabs(panel, sessionID) }

        let moved = drawer.addBrowserTab(for: sessionID)
        let drawerTabID = try XCTUnwrap(drawer.tabs(for: sessionID).first?.id)
        let resolver = makeResolver(panel: panel, drawer: drawer)

        let location = try XCTUnwrap(resolver.location(of: moved, for: sessionID))
        XCTAssertEqual(location.tabID, drawerTabID)
        XCTAssertEqual(location.hostID, .drawer)

        // The panel genuinely does not hold it — which is exactly why confirming there was wrong.
        XCTAssertFalse(
            panel.tabs(for: sessionID).contains { $0.browser === moved },
            "the fixture no longer reproduces the condition the lease got wrong"
        )
    }

    func testThePanelAnswersBeforeTheDrawer() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        drawer.showSession(sessionID)
        defer { closePanelTabs(panel, sessionID) }

        let inPanel = panel.activateBrowser(for: sessionID)
        _ = drawer.addBrowserTab(for: sessionID)
        let resolver = makeResolver(panel: panel, drawer: drawer)

        let location = try XCTUnwrap(resolver.location(for: sessionID))
        XCTAssertTrue(
            location.browser === inPanel,
            "the drawer answered over the panel, so a session's browser could change hosts by itself"
        )
        XCTAssertEqual(location.hostID, .displayPanel)
    }

    func testNoHostHoldingABrowserResolvesToNothing() {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        drawer.showSession(sessionID)
        defer { closePanelTabs(panel, sessionID) }

        XCTAssertNil(makeResolver(panel: panel, drawer: drawer).browser(for: sessionID))
    }

    /// The panel's own recency survives the move to a shared resolver: content shown in front of
    /// a browser must not change which browser the next action reaches.
    func testContentShownInFrontOfABrowserDoesNotChangeWhichBrowserAnswers() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        defer { closePanelTabs(panel, sessionID) }

        let browser = panel.activateBrowser(for: sessionID)
        panel.addContentTab(
            DisplayContent(body: .html("<p>report</p>"), title: "Report", subtitle: "html"),
            for: sessionID
        )
        let resolver = makeResolver(panel: panel, drawer: drawer)

        XCTAssertTrue(
            resolver.browser(for: sessionID) === browser,
            "a document put in front of the browser stole the next browser action"
        )
    }

    // MARK: - Enumeration across hosts

    /// What the remote workspace mirror lists. It used to add the hosts up by hand with a `+`,
    /// which compiles unchanged when a host is added — so a browser in a new host would vanish
    /// from the phone with nothing failing anywhere.
    func testEveryHostsBrowsersAreEnumeratedInHostOrder() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        drawer.showSession(sessionID)
        defer { closePanelTabs(panel, sessionID) }

        let inPanel = panel.activateBrowser(for: sessionID)
        let inDrawer = drawer.addBrowserTab(for: sessionID)

        let located = makeResolver(panel: panel, drawer: drawer).locations(for: sessionID)

        XCTAssertEqual(located.count, 2)
        XCTAssertTrue(located[0].browser === inPanel)
        XCTAssertEqual(located[0].hostID, .displayPanel)
        XCTAssertTrue(located[1].browser === inDrawer)
        XCTAssertEqual(located[1].hostID, .drawer)
    }

    /// A location carries its tab, so a caller listing browsers reads the strip's own title
    /// rather than deriving a second one that can disagree with it.
    func testALocationCarriesTheTabItWasFoundIn() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        drawer.showSession(sessionID)
        defer { closePanelTabs(panel, sessionID) }

        _ = drawer.addBrowserTab(for: sessionID)
        let drawerTab = try XCTUnwrap(drawer.tabs(for: sessionID).first)

        let located = try XCTUnwrap(
            makeResolver(panel: panel, drawer: drawer).locations(for: sessionID).first
        )
        XCTAssertEqual(located.tabID, drawerTab.id)
        XCTAssertEqual(located.tab.title, drawerTab.title)
    }

    /// Content tabs are not browsers, and a resolver that counted them would hand the agent a
    /// screenshot to click on.
    func testContentTabsAreNotEnumeratedAsBrowsers() {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        defer { closePanelTabs(panel, sessionID) }

        panel.addContentTab(
            DisplayContent(body: .html("<p>report</p>"), title: "Report", subtitle: "html"),
            for: sessionID
        )

        XCTAssertTrue(makeResolver(panel: panel, drawer: drawer).locations(for: sessionID).isEmpty)
    }

    // MARK: - The audit tab's own browser

    /// The Execution audit owns a live browser so its split mode can put tool calls beside the
    /// page they affected. In plain audit mode that browser is hidden and has never loaded
    /// anything — and opening the audit makes it the panel's *active* tab, so it used to capture
    /// the session's browser tools outright. Every lease-gated tool then reported "No authorized
    /// page is loaded" about a page still sitting in the browser tab beside it.
    func testOpeningTheAuditDoesNotStealTheSessionsBrowser() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        defer { closePanelTabs(panel, sessionID) }

        let working = panel.activateBrowser(for: sessionID)
        let audit = try XCTUnwrap(panel.addAuditTab(for: sessionID))

        // The condition the bug needed: the audit is active and does hold a browser.
        XCTAssertEqual(panel.activeTabID(for: sessionID), panel.tabs(for: sessionID).last?.id)
        XCTAssertNotNil(panel.tabs(for: sessionID).last?.browser)

        XCTAssertTrue(
            makeResolver(panel: panel, drawer: drawer).browser(for: sessionID) === working,
            "the audit's hidden browser captured the session's browser tools"
        )
        XCTAssertFalse(audit.browser === working)
    }

    /// The other half of the rule: once the audit is actually *showing* its browser, that browser
    /// is the one on screen and driving it is right.
    func testAnAuditShowingItsBrowserMayBeDriven() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        defer { closePanelTabs(panel, sessionID) }

        let audit = try XCTUnwrap(panel.addAuditTab(for: sessionID))
        audit.setMode(.browserSplit)

        XCTAssertTrue(
            makeResolver(panel: panel, drawer: drawer).browser(for: sessionID) === audit.browser
        )
    }

    /// A session whose only browser is an audit's hidden one has, for the agent's purposes, no
    /// browser at all — so navigation builds a real one rather than driving the blank.
    func testNavigationBuildsARealBrowserRatherThanDrivingTheAudits() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        defer { closePanelTabs(panel, sessionID) }

        let audit = try XCTUnwrap(panel.addAuditTab(for: sessionID))
        let coordinator = AgentToolCoordinator(
            displayPaneController: panel,
            browserResolver: makeResolver(panel: panel, drawer: drawer),
            visibleSessionID: { sessionID },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )

        let activated = coordinator.activateSessionBrowser(for: sessionID)

        XCTAssertFalse(
            activated.browser === audit.browser,
            "navigation drove the audit's hidden, never-loaded browser"
        )
        XCTAssertEqual(activated.hostID, .displayPanel)
    }

    /// Enumeration is deliberately *not* narrowed: a lease re-checking where its browser lives
    /// must find it whatever kind of tab holds it, and the remote mirror lists what exists.
    func testAnAuditsBrowserIsStillEnumerated() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        defer { closePanelTabs(panel, sessionID) }

        let audit = try XCTUnwrap(panel.addAuditTab(for: sessionID))
        let resolver = makeResolver(panel: panel, drawer: drawer)

        XCTAssertNotNil(resolver.location(of: audit.browser, for: sessionID))
        XCTAssertTrue(resolver.locations(for: sessionID).contains { $0.browser === audit.browser })
    }

    // MARK: - Where a prompt belongs

    /// The origin grant is the whole of the browser feature's security, so the alert has to be
    /// raised over the window showing the page it describes. The window is asked of the *host*,
    /// not of the browser's own view, because a host installs only its active tab — a browser
    /// sitting behind another tab is in no window at all and would otherwise send its prompt to
    /// whichever window the app considers primary.
    func testAPromptFollowsTheWindowShowingTheBrowser() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        drawer.showSession(sessionID)
        defer { closePanelTabs(panel, sessionID) }

        _ = drawer.addBrowserTab(for: sessionID)

        // Built, never ordered on screen: an unshown window still answers `view.window`, which
        // is all this asserts, and showing one would queue the terminate-after-last-window
        // decision for a later, unrelated test to trip over.
        let drawerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        drawerWindow.isReleasedWhenClosed = false
        drawerWindow.contentViewController = drawer

        let resolver = makeResolver(panel: panel, drawer: drawer)
        XCTAssertTrue(
            resolver.window(for: sessionID) === drawerWindow,
            "the prompt would have been raised over a window that is not showing the page"
        )
    }

    /// No browser anywhere means no window to name, and the caller — not this type — decides
    /// whether that becomes the app's main window or no sheet at all.
    func testNoBrowserNamesNoWindow() {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        defer { closePanelTabs(panel, sessionID) }

        XCTAssertNil(makeResolver(panel: panel, drawer: drawer).window(for: sessionID))
    }

    /// A host whose view was never loaded must not be built just to answer "which window" —
    /// that would construct a whole pane during a tool call on a session nobody has opened.
    func testAnUnloadedHostIsNotBuiltToAnswerWhichWindow() {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        defer { closePanelTabs(panel, sessionID) }

        _ = panel.activateBrowser(for: sessionID)
        XCTAssertFalse(
            panel.isViewLoaded,
            "the fixture no longer reproduces the condition: the panel loaded its view"
        )
        XCTAssertNil(makeResolver(panel: panel, drawer: drawer).window(for: sessionID))
        XCTAssertFalse(panel.isViewLoaded, "asking which window built the pane")
    }

    // MARK: - The chip left behind

    /// A page moved into a window of its own leaves a chip saying where it went — otherwise the
    /// tab simply vanishes from the pane and the only way back is a menu on a strip that no
    /// longer shows it.
    ///
    /// The proxy is deliberately **not** a `PaneTab`: the panel does not hold that page, and the
    /// agent's `panel_list_tabs` must keep saying so.
    func testAProxyChipIsNotATabTheAgentCanSee() {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        defer { closePanelTabs(panel, sessionID) }
        panel.showSession(sessionID)

        var focused = 0
        panel.detachedWindowProxies = { session in
            guard session == sessionID else { return [] }
            return [DisplayPaneController.DetachedWindowProxy(
                windowID: UUID(),
                title: "Example",
                onFocus: { focused += 1 },
                onBringBack: {}
            )]
        }

        XCTAssertTrue(
            panel.tabs(for: sessionID).isEmpty,
            "the proxy became a tab, so panel_list_tabs would report a page the panel does "
                + "not hold"
        )
        XCTAssertNil(panel.activeTabID(for: sessionID))
        XCTAssertNil(
            panel.browser(for: sessionID),
            "the proxy offered a browser it only points at"
        )
        XCTAssertEqual(focused, 0)
    }

    /// The two answers a proxy offers, and neither of them ends anything: standing for a window
    /// is not holding it.
    func testAProxyOffersFocusAndBringBack() {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        defer { closePanelTabs(panel, sessionID) }
        panel.showSession(sessionID)

        var focused = 0
        var broughtBack = 0
        let windowID = UUID()
        panel.detachedWindowProxies = { _ in
            [DisplayPaneController.DetachedWindowProxy(
                windowID: windowID,
                title: "Example",
                onFocus: { focused += 1 },
                onBringBack: { broughtBack += 1 }
            )]
        }

        let items: [ThemedMenuItem] = panel.tabContextEntries(for: windowID).compactMap {
            if case .item(let item) = $0 { return item }
            return nil
        }
        XCTAssertEqual(
            items.count, 2,
            "a proxy's menu is about the window it points at, not about a tab this pane holds"
        )
        XCTAssertFalse(
            items.contains { $0.title.contains("Close") },
            "the proxy offered to close tabs the panel does not hold"
        )

        items.first?.onChoose?()
        XCTAssertEqual(focused, 1)
        items.last?.onChoose?()
        XCTAssertEqual(broughtBack, 1)
    }

    // MARK: - Navigation

    /// The navigate bug: reaching straight for the panel created a second browser beside the one
    /// the user had moved, and then drove the invisible one.
    func testNavigationUsesTheBrowserTheUserMovedRatherThanBuildingASecond() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        drawer.showSession(sessionID)
        defer { closePanelTabs(panel, sessionID) }

        let moved = drawer.addBrowserTab(for: sessionID)
        let coordinator = AgentToolCoordinator(
            displayPaneController: panel,
            browserResolver: makeResolver(panel: panel, drawer: drawer),
            visibleSessionID: { sessionID },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )

        let activated = coordinator.activateSessionBrowser(for: sessionID)

        XCTAssertTrue(activated.browser === moved)
        XCTAssertEqual(activated.hostID, .drawer)
        XCTAssertTrue(
            panel.tabs(for: sessionID).isEmpty,
            "navigation built a second browser in the panel beside the one the user had moved"
        )
    }

    /// The other half of the same rule: a session with no browser anywhere still gets one, and it
    /// is built in the panel, which is where a session's first browser belongs.
    func testASessionWithNoBrowserAnywhereGetsOneInThePanel() {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let drawer = makeDrawer(store: PayloadStore())
        drawer.showSession(sessionID)
        defer { closePanelTabs(panel, sessionID) }

        let coordinator = AgentToolCoordinator(
            displayPaneController: panel,
            browserResolver: makeResolver(panel: panel, drawer: drawer),
            visibleSessionID: { sessionID },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )

        let activated = coordinator.activateSessionBrowser(for: sessionID)

        XCTAssertEqual(activated.hostID, .displayPanel)
        XCTAssertEqual(panel.tabs(for: sessionID).count, 1)
        XCTAssertTrue(panel.tabs(for: sessionID).first?.browser === activated.browser)
    }

    /// A coordinator built without a window knows only the panel — the shape every other test
    /// uses, kept working so the default cannot quietly start consulting hosts that do not exist.
    func testACoordinatorWithoutAWindowResolvesThePanelAlone() {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        defer { closePanelTabs(panel, sessionID) }

        let coordinator = AgentToolCoordinator(
            displayPaneController: panel,
            visibleSessionID: { sessionID },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
        let browser = panel.activateBrowser(for: sessionID)

        XCTAssertTrue(coordinator.browserResolver.browser(for: sessionID) === browser)
    }
}
