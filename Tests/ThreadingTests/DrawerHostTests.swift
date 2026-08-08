import AppKit
import XCTest
@testable import Threading

/// The drawer host's contract: a shell is the default first tab, sessions keep their own tab
/// lists, switching tears nothing down, closing a tab ends only what it held, and the open
/// state survives through the persisted payload.
///
/// Persistence is injected as an in-memory dictionary — the real store writes through
/// `StateManager.shared`, and a behaviour test must never leave fixture rows in the user's
/// database. No shell processes start: nothing here reveals a tab, so `startIfNeeded` never
/// runs, which is itself the deferred-process rule the drawer documents.
@MainActor
final class DrawerHostTests: XCTestCase {

    // MARK: - Fixtures

    /// The in-memory stand-in for the session payload store.
    private final class PayloadStore {
        var panels: [SessionID: PersistedPanel] = [:]
    }

    private var store: PayloadStore!

    override func setUp() {
        super.setUp()
        store = PayloadStore()
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func makeHost() -> DrawerHostViewController {
        let store = store!
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

    // MARK: - Default Shell Tab

    func testFirstOpenCreatesExactlyOneDefaultShellTab() {
        let host = makeHost()
        let session = SessionID()

        host.ensureDefaultShellTab(for: session)
        host.ensureDefaultShellTab(for: session)

        let tabs = host.tabs(for: session)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertNotNil(tabs[0].terminal, "The drawer's default tab is the session's shell")
    }

    // MARK: - Per-Session Isolation

    func testSessionsKeepTheirOwnTabLists() {
        let host = makeHost()
        let sessionA = SessionID()
        let sessionB = SessionID()

        host.ensureDefaultShellTab(for: sessionA)
        _ = host.addTerminalTab(for: sessionA)

        XCTAssertEqual(host.tabs(for: sessionA).count, 2)
        XCTAssertTrue(host.tabs(for: sessionB).isEmpty)
    }

    func testSwitchingSessionsKeepsControllersParentedAndIdentical() {
        let host = makeHost()
        let sessionA = SessionID()
        let sessionB = SessionID()

        host.showSession(sessionA)
        let shell = host.addTerminalTab(for: sessionA)

        host.showSession(sessionB)
        XCTAssertNotNil(
            shell?.parent,
            "A background session's shell must stay parented — detaching is what used to "
                + "separate shells from their scrollback views"
        )

        host.showSession(sessionA)
        XCTAssertTrue(
            host.tabs(for: sessionA).first?.terminal === shell,
            "Coming back must show the same controller, not a rebuilt one"
        )
    }

    // MARK: - Closing

    func testClosingATabEndsOnlyThatTab() throws {
        let host = makeHost()
        let session = SessionID()
        host.showSession(session)

        let first = try XCTUnwrap(host.addTerminalTab(for: session))
        let second = try XCTUnwrap(host.addTerminalTab(for: session))
        let firstID = try XCTUnwrap(host.tabs(for: session).first?.id)

        XCTAssertTrue(host.closeTab(id: firstID, for: session))

        XCTAssertNil(first.parent, "The closed tab's controller must be unparented")
        XCTAssertNotNil(second.parent)
        XCTAssertEqual(host.tabs(for: session).count, 1)
    }

    func testCloseSessionEndsEverythingButKeepsThePayload() throws {
        let host = makeHost()
        let session = SessionID()
        host.showSession(session)
        host.setOpen(true, for: session)
        host.ensureDefaultShellTab(for: session)
        _ = host.addTerminalTab(for: session)
        let persistedCount = store.panels[session]?.drawerTabs.count

        host.closeSession(session)

        XCTAssertEqual(persistedCount, 2, "Both tabs were persisted before the close")
        XCTAssertEqual(
            store.panels[session]?.drawerTabs.count, 2,
            "Closing a session ends its processes, not its remembered layout"
        )

        // A fresh ask rebuilds from the payload: same shape, fresh unstarted controllers.
        XCTAssertEqual(host.tabs(for: session).count, 2)
    }

    // MARK: - Open State

    func testOpenStateRoundTripsThroughThePayload() {
        let host = makeHost()
        let sessionA = SessionID()
        let sessionB = SessionID()

        host.setOpen(true, for: sessionA)

        let second = makeHost()
        XCTAssertTrue(second.isOpen(for: sessionA))
        XCTAssertFalse(second.isOpen(for: sessionB))
    }

    // MARK: - Reordering & Selection

    func testReorderPersistsInListOrder() throws {
        let host = makeHost()
        let session = SessionID()
        host.showSession(session)
        _ = host.addTerminalTab(for: session)
        _ = host.addTerminalTab(for: session)
        let ids = host.tabs(for: session).map(\.id)

        XCTAssertTrue(host.moveTab(id: ids[0], toIndex: 1, for: session))

        XCTAssertEqual(host.tabs(for: session).map(\.id), [ids[1], ids[0]])
        XCTAssertEqual(
            store.panels[session]?.drawerTabs.map(\.id),
            [ids[1].uuidString, ids[0].uuidString]
        )
    }

    func testRestoreRebuildsTerminalTabsWithTheirIDs() {
        let host = makeHost()
        let session = SessionID()
        host.showSession(session)
        host.ensureDefaultShellTab(for: session)
        let ids = host.tabs(for: session).map(\.id)

        let second = makeHost()
        XCTAssertEqual(second.tabs(for: session).map(\.id), ids)
        XCTAssertNotNil(second.tabs(for: session).first?.terminal)
    }

    // MARK: - Standard Tab Menu

    /// The shared builder every strip's context menu comes from, driven through a real host:
    /// each close goes through the host's own `closeTab`, so what a menu bulk-close ends is
    /// exactly what closing each tab by hand would have — processes included.
    func testCloseOtherTabsKeepsOnlyTheAskedTab() throws {
        let host = makeHost()
        let session = SessionID()
        host.showSession(session)
        _ = host.addTerminalTab(for: session)
        _ = host.addTerminalTab(for: session)
        _ = host.addTerminalTab(for: session)
        let keptID = try XCTUnwrap(host.tabs(for: session)[1].id)

        try choose("Close Other Tabs", in: host.standardTabEntries(for: keptID, sessionID: session))

        XCTAssertEqual(host.tabs(for: session).map(\.id), [keptID])
    }

    func testCloseTabsToTheRightClosesOnlyWhatFollows() throws {
        let host = makeHost()
        let session = SessionID()
        host.showSession(session)
        _ = host.addTerminalTab(for: session)
        _ = host.addTerminalTab(for: session)
        _ = host.addTerminalTab(for: session)
        let ids = host.tabs(for: session).map(\.id)

        try choose("Close Tabs to the Right", in: host.standardTabEntries(for: ids[1], sessionID: session))

        XCTAssertEqual(host.tabs(for: session).map(\.id), [ids[0], ids[1]])
    }

    func testCloseAllTabsLeavesTheStripEmpty() throws {
        let host = makeHost()
        let session = SessionID()
        host.showSession(session)
        _ = host.addTerminalTab(for: session)
        _ = host.addTerminalTab(for: session)
        _ = host.addTerminalTab(for: session)
        let firstID = try XCTUnwrap(host.tabs(for: session).first?.id)

        try choose("Close All Tabs", in: host.standardTabEntries(for: firstID, sessionID: session))

        XCTAssertTrue(host.tabs(for: session).isEmpty)
    }

    /// The commands that would do nothing are offered disabled, keeping the menu one shape.
    func testInapplicableCloseCommandsAreDisabledNotHidden() throws {
        let host = makeHost()
        let session = SessionID()
        host.showSession(session)
        _ = host.addTerminalTab(for: session)
        let onlyID = try XCTUnwrap(host.tabs(for: session).first?.id)

        let entries = host.standardTabEntries(for: onlyID, sessionID: session)
        XCTAssertEqual(item("Close Other Tabs", in: entries)?.isEnabled, false)
        XCTAssertEqual(item("Close Tabs to the Right", in: entries)?.isEnabled, false)
        XCTAssertEqual(item("Close Tab", in: entries)?.isEnabled, true)
        XCTAssertEqual(
            item("Close All Tabs", in: entries)?.isEnabled,
            true,
            "With one tab, closing all of them still closes it"
        )
    }

    private func item(_ title: String, in entries: [ThemedMenuEntry]) -> ThemedMenuItem? {
        for entry in entries {
            if case .item(let item) = entry, item.title == L10n.string(title) {
                return item
            }
        }
        return nil
    }

    private func choose(_ title: String, in entries: [ThemedMenuEntry]) throws {
        try XCTUnwrap(item(title, in: entries), "\(title) is missing from the menu").onChoose?()
    }

    // MARK: - Drop Band

    /// The drop zone is the strip's full-width band, not the chips: an emptier strip is
    /// narrower than the drop it invites. The fixture window is built, never shown.
    func testTheDropBandIsTheStripsRowAndNothingBelowIt() {
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

        // Asked in screen coordinates, because the gesture now crosses windows — the fixture
        // converts through its own window exactly as the strip does.
        func onScreen(_ point: NSPoint) -> NSPoint { window.convertPoint(toScreen: point) }

        let inBand = NSPoint(x: 200, y: 300 - ThemedTabStripView.bandHeight / 2)
        XCTAssertTrue(host.dropBandContains(screenPoint: onScreen(inBand)))
        XCTAssertFalse(
            host.dropBandContains(screenPoint: onScreen(NSPoint(x: 200, y: 100))),
            "The shell below the band is the tab's content, not a drop zone"
        )
        XCTAssertFalse(
            host.dropBandContains(screenPoint: onScreen(NSPoint(x: 500, y: inBand.y)))
        )

        let outside = onScreen(inBand)
        host.view.removeFromSuperview()
        XCTAssertFalse(
            host.dropBandContains(screenPoint: outside),
            "Off the window there is no band to hit"
        )
    }

    // MARK: - Shell Inset

    /// The drawer's shell was the one flush terminal in the app: its first row sat on the
    /// strip's rule and its first column on the pane's edge. It takes the same
    /// `TerminalPadding` the agent and project terminals take, and the margin is painted the
    /// terminal's own background so it reads as the terminal's air, not a gap around it.
    /// No process starts: the shell spawns on reveal, and nothing here reveals it.
    func testTheShellTerminalIsInsetInsideItsOwnBackground() throws {
        let shell = ShellDrawerViewController(
            sessionID: SessionID(),
            directory: { URL(fileURLWithPath: NSTemporaryDirectory()) }
        )
        shell.view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        shell.view.layoutSubtreeIfNeeded()

        let terminal = try XCTUnwrap(
            shell.view.subviews.compactMap { $0 as? EmojiFixedTerminalView }.first,
            "the drawer's shell hosts its terminal view directly"
        )
        XCTAssertEqual(terminal.frame.minX, TerminalPadding.leading)
        XCTAssertEqual(
            shell.view.bounds.maxX - terminal.frame.maxX,
            TerminalPadding.trailing
        )
        // Unflipped host: the frame's minY is the bottom margin, under the strip's is the top.
        XCTAssertEqual(terminal.frame.minY, TerminalPadding.bottom)
        XCTAssertEqual(shell.view.bounds.maxY - terminal.frame.maxY, TerminalPadding.top)

        XCTAssertEqual(
            shell.view.layer?.backgroundColor,
            terminal.nativeBackgroundColor.cgColor,
            "the margin must be the terminal's exact background, or it reads as a border"
        )
    }

    // MARK: - Host Contract

    func testTheDrawerRefusesWhatItCannotShow() {
        let host = makeHost()
        let contentTab = PaneTab(body: .content(DisplayContent(
            body: .html("<p>x</p>"), title: nil, subtitle: "Fixture"
        )))

        XCTAssertEqual(host.hostID, .drawer)
        XCTAssertFalse(
            host.canAdopt(contentTab),
            "Rendered content has no controller to reparent until it grows one"
        )
    }
}
