import AppKit
import XCTest
@testable import Threading

@MainActor
final class WorkspaceDockTests: HostedStoreTestCase {
  func testManagedPaneRouteUsesDeclaredDrawerWithoutDuplicatingPlugin() throws {
    let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
    let session = SessionID()
    defer { DisplayPaneStore.shared.removeSession(session) }
    controller.containerViewController.setCurrentSessionForTesting(session)
    controller.syncDisplayPane(to: session)
    let identifier = NativePluginManagedOffer.deviceLogs.identifier
    let route = NativePluginManagedOffer.DeviceLogsRoute.fromDevice
    let drawer = controller.containerViewController.drawerHostController

    XCTAssertFalse(controller.openManagedPluginPane(
      identifier: identifier, routeID: "unknown", arguments: [:], for: session
    ))
    XCTAssertTrue(controller.openManagedPluginPane(
      identifier: identifier, routeID: route,
      arguments: ["deviceID": "first"], for: session
    ))
    let first = try XCTUnwrap(drawer.tabs(for: session).first { tab in
      guard case .nativePlugin = tab.body else { return false }
      return true
    })
    XCTAssertEqual((first.hostedController as? NativePluginPaneViewController)?.paneSection,
      NativePluginManagedOffer.DeviceLogsSection.regular)
    XCTAssertTrue(controller.openManagedPluginPane(
      identifier: identifier, routeID: route,
      arguments: ["deviceID": "second"], for: session
    ))
    XCTAssertEqual(drawer.tabs(for: session).filter {
      if case .nativePlugin = $0.body { return true }
      return false
    }.count, 1)
    XCTAssertTrue(drawer.tabs(for: session).contains { $0 === first })
  }

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
    let destination = DisplayPaneController(scope: .dock(UUID(), session: session))
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
    let destination = DisplayPaneController(scope: .dock(group, session: session))
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

  // MARK: - Review fixes

  func testNearestPaneStaysInsideTheAnchorsBranch() {
    var layout = WorkspaceDockLayout()
    let whole = UUID(), chat = UUID(), below = UUID(), beside = UUID()
    XCTAssertNil(layout.nearestPane(to: WorkspaceDockLayout.displayID))
    layout.insert(whole, beside: nil, edge: .bottom)
    layout.insert(chat, beside: WorkspaceDockLayout.conversationID, edge: .bottom)
    XCTAssertNil(layout.nearestPane(to: WorkspaceDockLayout.displayID),
      "panes under the conversation or across the workspace are not the side panel's neighbours")
    layout.insert(below, beside: WorkspaceDockLayout.displayID, edge: .bottom)
    layout.insert(beside, beside: below, edge: .right)
    XCTAssertTrue(layout.validated())
    XCTAssertTrue(layout.displayBranchHasPanes)
    XCTAssertEqual(layout.nearestPane(to: WorkspaceDockLayout.displayID), below,
      "the leaf touching the panel is the one that grows into its space")
    XCTAssertEqual(layout.nearestPane(to: below), beside)
    XCTAssertEqual(layout.nearestPane(to: beside), below)
  }

  func testLandingIsDecidedByPlaceAndNeverByATabRow() throws {
    // Conversation on the left, side panel on the right, one docked pane under the panel.
    let bounds = NSRect(x: 0, y: 0, width: 1200, height: 800)
    let pane = UUID()
    let targets: [WorkspaceDockController.Target] = [
      .init(id: pane, host: .dock(pane), frame: NSRect(x: 800, y: 0, width: 400, height: 300)),
      .init(id: WorkspaceDockLayout.conversationID, host: nil, frame: NSRect(x: 0, y: 0, width: 800, height: 800)),
      .init(id: WorkspaceDockLayout.displayID, host: .displayPanel,
        frame: NSRect(x: 800, y: 300, width: 400, height: 500)),
    ]
    func landing(_ point: NSPoint, from source: TabHostID = .drawer, tabs: Int = 2,
      canAddPane: Bool = true, overTabRow: Bool = false) -> WorkspaceDockController.Landing? {
      WorkspaceDockController.landing(at: point, in: bounds, targets: targets, sourceID: source,
        sourceTabCount: tabs, canAddPane: canAddPane, overTabRow: overTabRow)
    }

    XCTAssertNil(landing(NSPoint(x: 1000, y: 790), overTabRow: true),
      "the panel's row is a row: it never turns into a split however close to an edge")
    let whole = try XCTUnwrap(landing(NSPoint(x: 400, y: 5)))
    XCTAssertNil(whole.targetID)
    XCTAssertEqual(whole.edge, .bottom)

    let middle = try XCTUnwrap(landing(NSPoint(x: 1000, y: 550)))
    XCTAssertNil(middle.edge, "the middle of a pane that holds tabs joins it")
    XCTAssertEqual(middle.targetID, WorkspaceDockLayout.displayID)
    XCTAssertEqual(middle.frame, targets[2].frame)

    let split = try XCTUnwrap(landing(NSPoint(x: 1000, y: 330)))
    XCTAssertEqual(split.edge, .bottom)
    XCTAssertEqual(split.targetID, WorkspaceDockLayout.displayID)

    XCTAssertNil(landing(NSPoint(x: 400, y: 400)), "the conversation holds no tabs to join")
    XCTAssertNil(landing(NSPoint(x: 1000, y: 550), from: .displayPanel, tabs: 1),
      "the panel's only tab can neither split nor rejoin the pane it fills")
    XCTAssertNil(landing(NSPoint(x: 1000, y: 150), from: .dock(pane), tabs: 2),
      "a pane's own middle is not somewhere to move its tab")
    XCTAssertEqual(landing(NSPoint(x: 1000, y: 150))?.targetID, pane)

    XCTAssertNil(landing(NSPoint(x: 1000, y: 330), canAddPane: false),
      "at the pane ceiling, edges offer nothing…")
    let joinAtCeiling = try XCTUnwrap(landing(NSPoint(x: 1000, y: 550), canAddPane: false),
      "…but the middle of a pane still joins it")
    XCTAssertNil(joinAtCeiling.edge)
    XCTAssertEqual(joinAtCeiling.targetID, WorkspaceDockLayout.displayID)
  }

  func testSwitchingBetweenUndockedSessionsLeavesTheWorkspaceInTheWindow() throws {
    let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
    let window = try XCTUnwrap(controller.window)
    let first = SessionID(), second = SessionID()
    controller.containerViewController.setCurrentSessionForTesting(first)
    controller.syncDisplayPane(to: first)
    let conversationProbe = WindowMoveProbe(), panelProbe = WindowMoveProbe()
    controller.containerViewController.view.addSubview(conversationProbe)
    controller.displayPaneController.view.addSubview(panelProbe)
    let moves = (conversationProbe.moves, panelProbe.moves)
    for session in [second, first, second, first] {
      controller.containerViewController.setCurrentSessionForTesting(session)
      controller.syncDisplayPane(to: session)
    }
    XCTAssertEqual(conversationProbe.moves, moves.0,
      "a session switch with no docked panes must not take the conversation out of the window")
    XCTAssertEqual(panelProbe.moves, moves.1)
    XCTAssertTrue(conversationProbe.window === window)
  }

  func testClosingThePanelsLastTabLetsItsDockedNeighbourTakeItsPlace() throws {
    let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
    let session = SessionID()
    controller.containerViewController.setCurrentSessionForTesting(session)
    controller.syncDisplayPane(to: session)
    let panel = controller.displayPaneController
    let kept = contentTab("Kept", session), docked = contentTab("Docked", session)
    let other = contentTab("Other", session)
    for tab in [kept, docked, other] { panel.adopt(tab, at: nil, for: session) }
    controller.setDisplayPaneVisible(true, animated: false)
    let below = try XCTUnwrap(controller.workspaceDock.createGroup(at: .init(
      targetID: WorkspaceDockLayout.displayID, edge: .bottom, frame: .zero)))
    controller.moveTab(docked.id, from: .displayPanel, to: below.hostID)
    controller.moveTab(other.id, from: .displayPanel, to: below.hostID)
    XCTAssertTrue(below.activateTab(id: docked.id, for: session))

    XCTAssertTrue(panel.closeTab(id: kept.id, for: session))
    XCTAssertTrue(controller.workspaceDock.hosts.isEmpty, "the emptied half closes")
    XCTAssertEqual(panel.tabs(for: session).map(\.id), [docked.id, other.id])
    XCTAssertTrue(panel.tabs(for: session).first === docked, "the neighbour's live tabs move, not copies")
    XCTAssertEqual(panel.activeTabID(for: session), docked.id, "and keep the neighbour's selection")
    XCTAssertFalse(try XCTUnwrap(controller.contentSplitController.splitViewItems.last).isCollapsed)
    XCTAssertNil(DisplayPaneStore.shared.loadLayout(for: session)?.dockLayout)
  }

  func testMovingThePanelsOnlyTabIntoItsDockedNeighbourLeavesOnePane() throws {
    let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
    let session = SessionID()
    controller.containerViewController.setCurrentSessionForTesting(session)
    controller.syncDisplayPane(to: session)
    let panel = controller.displayPaneController
    let only = contentTab("Only", session), neighbour = contentTab("Neighbour", session)
    panel.adopt(only, at: nil, for: session)
    panel.adopt(neighbour, at: nil, for: session)
    controller.setDisplayPaneVisible(true, animated: false)
    let below = try XCTUnwrap(controller.workspaceDock.createGroup(at: .init(
      targetID: WorkspaceDockLayout.displayID, edge: .bottom, frame: .zero)))
    controller.moveTab(neighbour.id, from: .displayPanel, to: below.hostID)

    controller.moveTab(only.id, from: .displayPanel, to: below.hostID)
    XCTAssertTrue(controller.workspaceDock.hosts.isEmpty)
    XCTAssertEqual(panel.tabs(for: session).map(\.id), [neighbour.id, only.id])
    XCTAssertEqual(panel.activeTabID(for: session), only.id)
    XCTAssertFalse(try XCTUnwrap(controller.contentSplitController.splitViewItems.last).isCollapsed)
  }

  func testRestoredPaneWithNothingStoredIsNotShownEmpty() {
    let session = SessionID(), group = UUID()
    var layout = WorkspaceDockLayout()
    layout.insert(group, beside: nil, edge: .bottom)
    DisplayPaneStore.shared.saveDockLayout(layout, for: session)
    let base = SidebarSplitViewController()
    let conversation = NSViewController()
    conversation.view = NSView()
    let dock = WorkspaceDockController(base: base, conversation: conversation, display: DisplayPaneController())
    base.addSplitViewItem(NSSplitViewItem(viewController: dock.conversationBranch))
    base.addSplitViewItem(NSSplitViewItem(viewController: dock.displayBranch))
    dock.showSession(session)
    _ = dock.view
    XCTAssertTrue(dock.hosts.isEmpty)
    XCTAssertEqual(dock.layout, WorkspaceDockLayout())
    XCTAssertNil(DisplayPaneStore.shared.loadLayout(for: session)?.dockLayout)
  }

  func testSplitMenuNamesWhatItDividesAndEachRowWearsItsHalf() throws {
    let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
    let session = SessionID()
    controller.containerViewController.setCurrentSessionForTesting(session)
    controller.syncDisplayPane(to: session)
    let panel = controller.displayPaneController
    let first = contentTab("First", session), second = contentTab("Second", session)
    panel.adopt(first, at: nil, for: session)

    func splitBand(_ entries: [ThemedMenuEntry]) -> (header: String, rows: [ThemedMenuItem])? {
      guard let index = entries.firstIndex(where: { if case .header = $0 { return true }; return false }),
        case let .header(title) = entries[index] else { return nil }
      let rows = entries[(index + 1)...].compactMap { entry -> ThemedMenuItem? in
        if case let .item(item) = entry { return item }
        return nil
      }
      return (title, rows)
    }
    let lone = try XCTUnwrap(splitBand(panel.tabContextEntries(for: first.id)))
    XCTAssertEqual(lone.header, L10n.string("Whole workspace"), "a lone tab docks at the workspace edge")
    XCTAssertEqual(lone.rows.map(\.title), WorkspaceDockLayout.Edge.allCases.map { L10n.string($0.title) })
    XCTAssertTrue(lone.rows.allSatisfy { $0.image != nil }, "every Split row wears the half it creates")

    panel.adopt(second, at: nil, for: session)
    XCTAssertEqual(try XCTUnwrap(splitBand(panel.tabContextEntries(for: first.id))).header,
      L10n.string("Side panel"), "a tab with company splits the pane it is in")
  }

  func testSplitCommandDividesThePaneTheActiveTabIsIn() throws {
    let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
    let session = SessionID()
    controller.containerViewController.setCurrentSessionForTesting(session)
    controller.syncDisplayPane(to: session)
    let panel = controller.displayPaneController
    let first = contentTab("First", session), second = contentTab("Second", session)
    panel.adopt(first, at: nil, for: session)
    panel.adopt(second, at: nil, for: session)
    XCTAssertTrue(panel.activateTab(id: second.id, for: session))
    controller.setDisplayPaneVisible(true, animated: false)

    XCTAssertTrue(controller.canSplitActiveTab)
    controller.splitActiveTab(.bottom)
    let pane = try XCTUnwrap(controller.workspaceDock.hosts.first)
    XCTAssertEqual(pane.tabs(for: session).map(\.id), [second.id])
    XCTAssertEqual(panel.tabs(for: session).map(\.id), [first.id])
    XCTAssertTrue(controller.workspaceDock.layout.displayBranchHasPanes, "the side panel was divided")
    XCTAssertEqual(controller.workspaceDock.layout.rootID, WorkspaceDockLayout.workspaceID)
  }

  func testDockedPaneHeaderKeepsNoRoomForTheWindowToggle() {
    func corner(_ pane: DisplayPaneController) -> CGFloat {
      pane.view.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
      pane.view.layoutSubtreeIfNeeded()
      return pane.panelToggleSlot.frame.width
    }
    XCTAssertEqual(corner(DisplayPaneController()), ThemedIconButton.Target.toolbar.size.width)
    XCTAssertEqual(corner(DisplayPaneController(scope: .dock(UUID(), session: SessionID()))), 0)
  }

  func testDeviceLogsAndBluetoothCommandsEachOpenOnlyTheirOwnTab() throws {
    try XCTSkipIf(NativePluginCatalog.deviceLogsBundle == nil, "Device Logs is not bundled in this build")
    let logs = PanelCommandTarget.nativePluginSection(
      identifier: NativePluginManagedOffer.deviceLogs.identifier,
      section: NativePluginManagedOffer.DeviceLogsSection.regular
    )
    let bluetoothLogs = PanelCommandTarget.nativePluginSection(
      identifier: NativePluginManagedOffer.deviceLogs.identifier,
      section: NativePluginManagedOffer.DeviceLogsSection.bluetooth
    )
    let panel = DisplayPaneController()
    let session = SessionID()
    panel.showSession(session)
    func sections() -> [String] {
      panel.tabs(for: session).compactMap { tab in
        if case let .nativePlugin(plugin) = tab.body { return plugin.paneSection }
        return nil
      }
    }
    XCTAssertTrue(PanelCommands.additionalCommands.contains {
      $0.id == "panel.bluetoothLogs" && $0.panelTarget == bluetoothLogs
    })

    XCTAssertTrue(panel.performPanelCommand(logs, title: "", for: session))
    XCTAssertEqual(sections(), ["regular"], "Device Logs must not also open a Bluetooth tab")
    XCTAssertTrue(panel.performPanelCommand(bluetoothLogs, title: "", for: session))
    XCTAssertEqual(sections(), ["regular", "bluetooth"])
    XCTAssertEqual(panel.activeTabID(for: session), panel.tabs(for: session).last?.id)

    // Each command reveals its own tab again rather than adding one.
    let bluetooth = try XCTUnwrap(panel.tabs(for: session).last)
    XCTAssertTrue(panel.performPanelCommand(logs, title: "", for: session))
    XCTAssertEqual(panel.activeTabID(for: session), panel.tabs(for: session).first?.id)
    XCTAssertTrue(panel.performPanelCommand(bluetoothLogs, title: "", for: session))
    XCTAssertEqual(panel.activeTabID(for: session), bluetooth.id)
    XCTAssertEqual(sections(), ["regular", "bluetooth"])

    XCTAssertTrue(panel.closeTab(id: bluetooth.id, for: session))
    XCTAssertTrue(panel.performPanelCommand(logs, title: "", for: session))
    XCTAssertEqual(sections(), ["regular"], "revealing Device Logs must not reopen what the user closed")
    panel.removeSession(session)
  }

  func testPluginToolSectionRevealStaysWithItsOwningPanel() throws {
    try XCTSkipIf(NativePluginCatalog.deviceLogsBundle == nil, "Device Logs is not bundled in this build")
    let first = DisplayPaneController()
    let second = DisplayPaneController()
    let firstSession = SessionID()
    let secondSession = SessionID()
    first.showSession(firstSession)
    second.showSession(secondSession)
    let firstPane = try XCTUnwrap(first.activateDeviceLog(for: firstSession))
    _ = try XCTUnwrap(second.activateDeviceLog(for: secondSession))

    XCTAssertEqual(firstPane.onRevealSection?("bluetooth"), true)
    XCTAssertEqual(firstPane.onRevealSection?("not-a-section"), false)

    func sections(_ panel: DisplayPaneController, session: SessionID) -> [String] {
      panel.tabs(for: session).compactMap { tab in
        if case let .nativePlugin(plugin) = tab.body { return plugin.paneSection }
        return nil
      }
    }
    XCTAssertEqual(sections(first, session: firstSession), ["regular", "bluetooth"])
    XCTAssertEqual(sections(second, session: secondSession), ["regular"])
    first.removeSession(firstSession)
    second.removeSession(secondSession)
  }

  func testSharedPluginOwnerRevealsSectionInItsSiblingHost() throws {
    try XCTSkipIf(NativePluginCatalog.deviceLogsBundle == nil, "Device Logs is not bundled in this build")
    let session = SessionID()
    let source = DisplayPaneController()
    let destination = DisplayPaneController(scope: .dock(UUID(), session: session))
    source.showSession(session)
    destination.showSession(session)
    let owner = try XCTUnwrap(source.activateDeviceLog(for: session))
    _ = try XCTUnwrap(source.activateBluetoothLog(for: session))
    let bluetoothTab = try XCTUnwrap(source.tabs(for: session).last)
    let transfer = TabTransferCoordinator { hostID in
      hostID == source.hostID ? source : destination
    }
    XCTAssertTrue(transfer.move(
      tabID: bluetoothTab.id, from: source.hostID,
      to: destination.hostID, sessionID: session
    ))
    var sourceReveals = 0
    var destinationReveals = 0
    source.onNativePluginToolReveal = { _ in sourceReveals += 1 }
    destination.onNativePluginToolReveal = { _ in destinationReveals += 1 }
    XCTAssertTrue(owner.revealToolSection("bluetooth"))
    XCTAssertEqual(sourceReveals, 0)
    XCTAssertEqual(destinationReveals, 1)
    XCTAssertEqual(destination.activeTabID(for: session), bluetoothTab.id)
    XCTAssertEqual(source.tabs(for: session).count, 1)
    XCTAssertEqual(destination.tabs(for: session).count, 1)
    source.removeSession(session)
    destination.removeSession(session)
  }

  func testBluetoothOpensAloneBeforeDeviceLogs() throws {
    try XCTSkipIf(NativePluginCatalog.deviceLogsBundle == nil, "Device Logs is not bundled in this build")
    let panel = DisplayPaneController()
    let session = SessionID()
    panel.showSession(session)
    func sections() -> [String] {
      panel.tabs(for: session).compactMap { tab in
        if case let .nativePlugin(plugin) = tab.body { return plugin.paneSection }
        return nil
      }
    }
    let bluetooth = try XCTUnwrap(panel.activateBluetoothLog(for: session))
    XCTAssertEqual(sections(), ["bluetooth"])
    let logs = try XCTUnwrap(panel.activateDeviceLog(for: session))
    XCTAssertFalse(logs === bluetooth)
    XCTAssertEqual(sections(), ["bluetooth", "regular"])
    panel.removeSession(session)
  }

  private func contentTab(_ title: String, _ session: SessionID) -> PaneTab {
    PaneTab(body: .content(.init(body: .html("<p>\(title)</p>"), title: title, subtitle: "")),
      owningSessionID: session)
  }
}

/// Counts how often a view enters or leaves a window, which is what a reparent costs.
private final class WindowMoveProbe: NSView {
  private(set) var moves = 0
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    moves += 1
  }
}
