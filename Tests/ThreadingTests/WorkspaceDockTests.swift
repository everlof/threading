import AppKit
import XCTest
@testable import Threading

@MainActor
final class WorkspaceDockTests: HostedStoreTestCase {
  func testReopeningMovedSingletonsUsesTheirExistingDock() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DockCommands-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
    let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .codex)).id
    let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
    controller.containerViewController.setCurrentSessionForTesting(session)
    controller.syncDisplayPane(to: session)
    let panel = controller.displayPaneController
    let review = try XCTUnwrap(panel.activateReview(for: session))
    let overview = try XCTUnwrap(panel.activateOverview(for: session))
    let destination = try XCTUnwrap(controller.workspaceDock.createGroup(at: .init(
      targetID: nil, edge: .bottom, frame: .zero)))
    for tab in panel.tabs(for: session) where tab.review != nil || tab.overview != nil {
      controller.moveTab(tab.id, from: .displayPanel, to: destination.hostID)
    }
    XCTAssertTrue(panel.activateReview(for: session) === review)
    XCTAssertTrue(panel.activateOverview(for: session, section: .activity) === overview)
    XCTAssertEqual(overview.selectedSection, .activity)
    XCTAssertTrue(panel.tabs(for: session).allSatisfy { $0.review == nil && $0.overview == nil })
    XCTAssertEqual(destination.tabs(for: session).count, 2)
    XCTAssertNotNil(destination.sessionBrowserCount, "docked browsers must share the session-wide cap")
  }

  func testWholeRowThenTwoBottomPanesRoundTripsAndCollapses() throws {
    var layout = WorkspaceDockLayout()
    let logs = UUID(), bluetooth = UUID()
    XCTAssertTrue(layout.insert(logs, beside: nil, edge: .bottom))
    XCTAssertTrue(layout.insert(bluetooth, beside: logs, edge: .left))
    XCTAssertTrue(layout.validated())
    let root = try XCTUnwrap(layout.nodes.first { $0.id == layout.rootID })
    XCTAssertEqual(root.axis, .vertical)
    XCTAssertEqual(root.first, WorkspaceDockLayout.workspaceID)
    let bottom = try XCTUnwrap(layout.nodes.first { $0.id == root.second })
    XCTAssertEqual(bottom.axis, .horizontal)
    XCTAssertEqual(bottom.first, bluetooth)
    XCTAssertEqual(bottom.second, logs)
    let decoded = try JSONDecoder().decode(WorkspaceDockLayout.self, from: JSONEncoder().encode(layout))
    XCTAssertEqual(decoded, layout)
    layout.remove(bluetooth)
    XCTAssertTrue(layout.validated())
    XCTAssertEqual(layout.nodes.first { $0.id == layout.rootID }?.second, logs)
    layout.remove(logs)
    XCTAssertEqual(layout, WorkspaceDockLayout())
  }

  func testBottomScopeCanBeConversationOrDisplayWithoutChangingOtherSide() throws {
    for target in [WorkspaceDockLayout.conversationID, WorkspaceDockLayout.displayID] {
      var layout = WorkspaceDockLayout()
      let dock = UUID()
      XCTAssertTrue(layout.insert(dock, beside: target, edge: .bottom))
      XCTAssertTrue(layout.validated())
      XCTAssertEqual(layout.rootID, WorkspaceDockLayout.workspaceID)
      let branch = try XCTUnwrap(layout.nodes.first { $0.kind == .split })
      XCTAssertEqual(branch.first, target)
      XCTAssertEqual(branch.second, dock)
      let workspace = try XCTUnwrap(layout.nodes.first { $0.kind == .workspace })
      XCTAssertEqual(target == WorkspaceDockLayout.conversationID ? workspace.second : workspace.first,
        target == WorkspaceDockLayout.conversationID ? WorkspaceDockLayout.displayID : WorkspaceDockLayout.conversationID)
    }
  }

  func testInvalidGraphsAndUndeclaredHostsAreRefused() throws {
    var layout = WorkspaceDockLayout()
    let id = UUID()
    layout.insert(id, beside: nil, edge: .bottom)
    var cyclic = layout
    cyclic.nodes[0].first = cyclic.rootID
    XCTAssertFalse(cyclic.validated())
    var orphan = layout
    orphan.nodes.append(.init(id: UUID(), kind: .pane))
    XCTAssertFalse(orphan.validated())
    var invalidFraction = layout
    invalidFraction.nodes[0].fraction = .infinity
    XCTAssertFalse(invalidFraction.validated())
    var reversedAnchors = WorkspaceDockLayout()
    reversedAnchors.nodes[0].first = WorkspaceDockLayout.displayID
    reversedAnchors.nodes[0].second = WorkspaceDockLayout.conversationID
    XCTAssertFalse(reversedAnchors.validated())
    let tab = PersistedTab(id: UUID().uuidString, kind: .deviceLog, subtitle: "",
      mode: "bluetooth", host: PersistedTab.dockHost(UUID()))
    let panel = PersistedPanel(tabs: [tab], activeTabID: nil, observedSignature: nil, dockLayout: layout)
    XCTAssertThrowsError(try JSONDecoder().decode(PersistedPanel.self, from: JSONEncoder().encode(panel)))
  }

  func testAllWritersPreserveDockTabsAndTheirSelection() throws {
    let session = SessionID(), dock = UUID()
    var layout = WorkspaceDockLayout()
    layout.insert(dock, beside: nil, edge: .bottom)
    let store = DisplayPaneStore.shared
    store.saveDockLayout(layout, for: session)
    let tab = PersistedTab(id: UUID().uuidString, kind: .deviceLog, subtitle: "", mode: "bluetooth")
    store.saveDockTabs([tab], activeID: tab.id, dockID: dock, for: session)
    store.saveLayout(tabs: [], activeID: nil, for: session)
    store.saveDrawerLayout(tabs: [], activeID: nil, open: true, for: session)
    store.saveDetachedWindowLayout(.init(id: UUID().uuidString, frame: nil, activeTabID: nil),
      tabs: [], for: session)
    store.saveDockLayout(layout, for: session)
    let restored = try XCTUnwrap(store.loadLayout(for: session))
    XCTAssertEqual(restored.dockTabs.map(\.id), [tab.id])
    XCTAssertEqual(restored.dockLayout?.panes.first?.activeTabID, tab.id)
    XCTAssertEqual(restored.requiredFormatVersion, 7)
  }

  func testDockingKeepsTabIdentityAndOtherSessionsLayout() throws {
    let base = SidebarSplitViewController()
    let conversation = NSViewController(), display = DisplayPaneController()
    conversation.view = NSView()
    let dock = WorkspaceDockController(base: base, conversation: conversation, display: display)
    base.addSplitViewItem(NSSplitViewItem(viewController: dock.conversationBranch))
    base.addSplitViewItem(NSSplitViewItem(viewController: dock.displayBranch))
    let session = SessionID()
    dock.showSession(session)
    _ = dock.view
    let destination = try XCTUnwrap(dock.createGroup(at: .init(targetID: nil, edge: .bottom, frame: .zero)))
    let tab = PaneTab(body: .content(.init(body: .html("<p>retained</p>"), title: "Retained", subtitle: "")))
    display.adopt(tab, at: nil, for: session)
    let transfer = TabTransferCoordinator { id in id == .displayPanel ? display : destination }
    XCTAssertTrue(transfer.move(tabID: tab.id, from: .displayPanel, to: destination.hostID, sessionID: session))
    XCTAssertTrue(destination.tabs(for: session).first === tab)
    let savedLayout = dock.layout
    dock.showSession(SessionID())
    XCTAssertTrue(dock.hosts.isEmpty)
    dock.showSession(session)
    XCTAssertEqual(dock.layout, savedLayout)
    XCTAssertTrue(dock.hosts.first === destination)
    XCTAssertTrue(dock.hosts.first?.tabs(for: session).first === tab)

    let restoredBase = SidebarSplitViewController()
    let restoredConversation = NSViewController()
    restoredConversation.view = NSView()
    let restored = WorkspaceDockController(base: restoredBase,
      conversation: restoredConversation, display: DisplayPaneController())
    restoredBase.addSplitViewItem(NSSplitViewItem(viewController: restored.conversationBranch))
    restoredBase.addSplitViewItem(NSSplitViewItem(viewController: restored.displayBranch))
    restored.showSession(session)
    XCTAssertEqual(restored.layout.rootID, savedLayout.rootID)
    XCTAssertEqual(restored.hosts.first?.tabs(for: session).map(\.id), [tab.id])
    XCTAssertEqual(restored.hosts.first?.activeTabID(for: session), tab.id)
  }

  func testGeometryAndCapacityRemainBoundedAtStressSize() {
    var layout = WorkspaceDockLayout()
    for _ in 0..<WorkspaceDockLayout.maximumPanes { XCTAssertTrue(layout.insert(UUID(), beside: nil, edge: .bottom)) }
    XCTAssertFalse(layout.insert(UUID(), beside: nil, edge: .left))
    XCTAssertTrue(layout.validated())
    let rect = NSRect(x: 0, y: 0, width: 1200, height: 800)
    let start = DispatchTime.now().uptimeNanoseconds
    for index in 0..<100_000 {
      let point = NSPoint(x: index % 1200, y: index % 800)
      if let edge = WorkspaceDockController.edge(at: point, in: rect, band: 22) {
        XCTAssertTrue(rect.contains(WorkspaceDockController.previewFrame(rect, edge: edge, share: 0.3)))
      }
    }
    print("dock.geometry.100000.ms=\(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)")
    XCTAssertEqual(WorkspaceDockController.edge(at: NSPoint(x: 600, y: 3), in: rect, band: 22), .bottom)
    XCTAssertEqual(WorkspaceDockController.edge(at: NSPoint(x: 600, y: 799), in: rect, band: 22), .top)
  }

  func testDockHostRefusesTabOwnedByAnotherSession() {
    let session = SessionID()
    let destination = DisplayPaneController(dockID: UUID(), dockSessionID: session)
    let foreign = PaneTab(body: .content(.init(body: .html("foreign"), title: "Other", subtitle: "")),
      owningSessionID: SessionID())
    XCTAssertFalse(destination.canAdopt(foreign))
  }

  func testMovedAuditModePersistsInItsNewHost() throws {
    let session = SessionID(), group = UUID()
    var layout = WorkspaceDockLayout()
    layout.insert(group, beside: nil, edge: .bottom)
    DisplayPaneStore.shared.saveDockLayout(layout, for: session)
    let source = DisplayPaneController()
    let destination = DisplayPaneController(dockID: group, dockSessionID: session)
    let audit = ExecutionAuditViewController(sessionID: session, browser: BrowserViewController())
    let tab = PaneTab(body: .audit(audit), owningSessionID: session)
    source.adopt(tab, at: nil, for: session)
    let transfer = TabTransferCoordinator { $0 == .displayPanel ? source : destination }
    XCTAssertTrue(transfer.move(tabID: tab.id, from: .displayPanel, to: destination.hostID, sessionID: session))
    audit.setMode(.browserSplit, notify: true)
    let saved = try XCTUnwrap(DisplayPaneStore.shared.loadLayout(for: session))
    XCTAssertEqual(saved.dockTabs.first?.mode, ExecutionAuditViewController.Mode.browserSplit.rawValue)
    XCTAssertTrue(saved.panelTabs.isEmpty)
  }
}
