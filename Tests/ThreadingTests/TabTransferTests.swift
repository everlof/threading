import AppKit
import XCTest
@testable import Threading

/// Moving a tab between hosts is the same object reparented, never a rebuild: the controller
/// keeps its identity (and with it the shell's process and the browser's page), the source
/// forgets it, the destination shows it, and a refused move refuses *before* anything detaches.
///
/// Driven through two drawer hosts with in-memory stores — the coordinator resolves hosts
/// through a closure, so what matters here is the contract, not which pane answered.
@MainActor
final class TabTransferTests: XCTestCase {

    private final class PayloadStore {
        var panels: [SessionID: PersistedPanel] = [:]
    }

    /// A destination that says no to everything — what matters is that the refusal lands
    /// *before* anything detaches, whichever host it comes from.
    private final class RefusingHost: TabHosting {
        var hostID: TabHostID { .displayPanel }
        func tabs(for sessionID: SessionID?) -> [PaneTab] { [] }
        func activeTabID(for sessionID: SessionID?) -> UUID? { nil }
        func activateTab(id: UUID, for sessionID: SessionID?) -> Bool { false }
        func closeTab(id: UUID, for sessionID: SessionID?) -> Bool { false }
        func moveTab(id: UUID, toIndex index: Int, for sessionID: SessionID?) -> Bool { false }
        func canAdopt(_ tab: PaneTab) -> Bool { false }
        func detachTab(id: UUID, for sessionID: SessionID?) -> PaneTab? { nil }
        func adopt(_ tab: PaneTab, at index: Int?, for sessionID: SessionID?) {}
    }

    private func makeHost(store: PayloadStore) -> DrawerHostViewController {
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

    func testAMovedTabKeepsItsControllerAndChangesHands() throws {
        let sourceStore = PayloadStore()
        let destinationStore = PayloadStore()
        let source = makeHost(store: sourceStore)
        let destination = makeHost(store: destinationStore)
        let session = SessionID()
        source.showSession(session)
        destination.showSession(session)

        let shell = try XCTUnwrap(source.addTerminalTab(for: session))
        let tabID = try XCTUnwrap(source.tabs(for: session).first?.id)

        let coordinator = TabTransferCoordinator(host: { id in
            id == .drawer ? source : destination
        })

        XCTAssertTrue(coordinator.move(
            tabID: tabID, from: .drawer, to: .displayPanel, sessionID: session
        ))

        XCTAssertTrue(source.tabs(for: session).isEmpty)
        XCTAssertTrue(
            destination.tabs(for: session).first?.terminal === shell,
            "A move reparents the controller; a rebuilt one would have lost its process"
        )
        XCTAssertEqual(destination.activeTabID(for: session), tabID)
        XCTAssertTrue(
            shell.parent === destination,
            "The destination must own what it adopted"
        )

        // Both stores reflect the move: the tab lives in exactly one of them.
        XCTAssertTrue(sourceStore.panels[session]?.drawerTabs.isEmpty ?? true)
        XCTAssertEqual(destinationStore.panels[session]?.drawerTabs.count, 1)
    }

    func testARefusedMoveDetachesNothing() throws {
        let store = PayloadStore()
        let source = makeHost(store: store)
        let session = SessionID()
        source.showSession(session)
        _ = source.addTerminalTab(for: session)
        let tabID = try XCTUnwrap(source.tabs(for: session).first?.id)

        let refusing = RefusingHost()
        let coordinator = TabTransferCoordinator(host: { id -> TabHosting? in
            id == .drawer ? source : refusing
        })

        XCTAssertFalse(coordinator.canMove(
            tabID: tabID, from: .drawer, to: .displayPanel, sessionID: session
        ))
        XCTAssertFalse(coordinator.move(
            tabID: tabID, from: .drawer, to: .displayPanel, sessionID: session
        ))
        XCTAssertEqual(
            source.tabs(for: session).count, 1,
            "A refused move must not have detached the tab on its way to the refusal"
        )
    }

    /// A drag names a slot; the adopted tab takes exactly that slot, and the front.
    func testADroppedTabLandsAtThePointedSlot() throws {
        let source = makeHost(store: PayloadStore())
        let destination = makeHost(store: PayloadStore())
        let session = SessionID()
        source.showSession(session)
        destination.showSession(session)

        _ = destination.addTerminalTab(for: session)
        _ = destination.addTerminalTab(for: session)
        _ = source.addTerminalTab(for: session)
        let tabID = try XCTUnwrap(source.tabs(for: session).first?.id)

        let coordinator = TabTransferCoordinator(host: { id in
            id == .drawer ? source : destination
        })
        XCTAssertTrue(coordinator.move(
            tabID: tabID, from: .drawer, to: .displayPanel, index: 1, sessionID: session
        ))

        XCTAssertEqual(destination.tabs(for: session)[1].id, tabID)
        XCTAssertEqual(destination.activeTabID(for: session), tabID)
    }

    func testAMoveToTheSameHostIsRefused() throws {
        let store = PayloadStore()
        let host = makeHost(store: store)
        let session = SessionID()
        host.showSession(session)
        _ = host.addTerminalTab(for: session)
        let tabID = try XCTUnwrap(host.tabs(for: session).first?.id)

        let coordinator = TabTransferCoordinator(host: { _ in host })

        XCTAssertFalse(coordinator.move(
            tabID: tabID, from: .drawer, to: .drawer, sessionID: session
        ))
    }

    func testAStaleTabIDMovesNothing() {
        let store = PayloadStore()
        let source = makeHost(store: store)
        let destination = makeHost(store: PayloadStore())
        let session = SessionID()
        let coordinator = TabTransferCoordinator(host: { id in
            id == .drawer ? source : destination
        })

        XCTAssertFalse(coordinator.move(
            tabID: UUID(), from: .drawer, to: .displayPanel, sessionID: session
        ))
    }
}
