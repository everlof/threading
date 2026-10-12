import AppKit
import ThreadingPluginKit
import XCTest
@testable import Threading

@MainActor
final class WorkspaceDockInteractionTests: HostedStoreTestCase {
  func testFindFollowsBrowserAfterItsOriginalPanelCollapses() throws {
    let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
    let window = try XCTUnwrap(controller.window)
    defer { window.orderOut(nil) }
    let session = SessionID()
    controller.containerViewController.setCurrentSessionForTesting(session)
    controller.syncDisplayPane(to: session)
    let browser = BrowserViewController()
    let tab = PaneTab(body: .browser(browser), owningSessionID: session)
    controller.displayPaneController.adopt(tab, at: nil, for: session)
    let destination = try XCTUnwrap(controller.workspaceDock.createGroup(at: .init(
      targetID: nil, edge: .bottom, frame: .zero)))
    controller.moveTab(tab.id, from: .displayPanel, to: destination.hostID)
    window.orderFrontRegardless()
    window.contentView?.layoutSubtreeIfNeeded()
    XCTAssertTrue(try XCTUnwrap(controller.contentSplitController.splitViewItems.last).isCollapsed)
    XCTAssertTrue(controller.showFind(), "Find must reach the moved browser with its old panel closed")
    func findBar(in view: NSView) -> BrowserFindBar? {
      if let bar = view as? BrowserFindBar { return bar }
      return view.subviews.lazy.compactMap { findBar(in: $0) }.first
    }
    XCTAssertFalse(try XCTUnwrap(findBar(in: browser.view)).isHiddenOrHasHiddenAncestor)
  }

  func testMovingLastPanelTabBelowPanelKeepsDestinationVisible() throws {
    let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
    let window = try XCTUnwrap(controller.window)
    defer { window.orderOut(nil) }
    let session = SessionID()
    controller.containerViewController.setCurrentSessionForTesting(session)
    controller.syncDisplayPane(to: session)
    let onlyTab = tab(session)
    controller.displayPaneController.adopt(onlyTab, at: nil, for: session)
    controller.setDisplayPaneVisible(true, animated: false)
    window.orderFrontRegardless()
    let destination = try XCTUnwrap(controller.workspaceDock.createGroup(at: .init(
      targetID: WorkspaceDockLayout.displayID, edge: .bottom, frame: .zero)))
    controller.moveTab(onlyTab.id, from: .displayPanel, to: destination.hostID)
    window.contentView?.layoutSubtreeIfNeeded()
    XCTAssertFalse(try XCTUnwrap(controller.contentSplitController.splitViewItems.last).isCollapsed)
    XCTAssertFalse(destination.view.isHiddenOrHasHiddenAncestor)
    XCTAssertTrue(destination.tabs(for: session).first === onlyTab)
    let other = SessionID()
    controller.containerViewController.setCurrentSessionForTesting(other)
    controller.syncDisplayPane(to: other)
    controller.containerViewController.setCurrentSessionForTesting(session)
    controller.syncDisplayPane(to: session)
    window.contentView?.layoutSubtreeIfNeeded()
    XCTAssertFalse(try XCTUnwrap(controller.contentSplitController.splitViewItems.last).isCollapsed)
    XCTAssertFalse(destination.view.isHiddenOrHasHiddenAncestor)
  }

  func testWindowDragShowsScopesCancelsAndCommitsNestedBottomSplit() throws {
    let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
    let window = try XCTUnwrap(controller.window)
    defer { window.orderOut(nil) }
    window.setContentSize(NSSize(width: 1280, height: 760))
    let session = SessionID()
    controller.containerViewController.setCurrentSessionForTesting(session)
    controller.syncDisplayPane(to: session)
    let panel = controller.displayPaneController
    let first = tab(session), second = tab(session), third = tab(session)
    for tab in [first, second, third] { panel.adopt(tab, at: nil, for: session) }
    controller.setDisplayPaneVisible(true, animated: false)
    // The test host can be inactive while another app owns the front. Expose this real window
    // without taking keyboard focus, and wait for the window server's visibility notification.
    window.level = .floating
    window.center()
    window.orderFrontRegardless()
    window.contentView?.layoutSubtreeIfNeeded()
    let exposureDeadline = Date(timeIntervalSinceNow: 2)
    while !window.occlusionState.contains(.visible), Date() < exposureDeadline {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    try XCTSkipUnless(window.occlusionState.contains(.visible),
      "The desktop could not expose the drag fixture (for example, while locked).")
    let dock = controller.workspaceDock
    func point(_ view: NSView, _ point: NSPoint) -> NSPoint { view.convert(point, to: nil) }
    let wholeBottom = point(dock.view, NSPoint(x: dock.view.bounds.midX, y: 5))
    let sideFrame = dock.view.convert(panel.view.bounds, from: panel.view)
    let sideBottom = point(dock.view, NSPoint(x: sideFrame.midX, y: sideFrame.minY + 55))
    let chatFrame = dock.view.convert(controller.containerViewController.view.bounds,
      from: controller.containerViewController.view)
    let chatBottom = point(dock.view, NSPoint(x: chatFrame.midX, y: chatFrame.minY + 55))
    for (position, expected) in [(wholeBottom, Optional<UUID>.none),
      (sideBottom, Optional(WorkspaceDockLayout.displayID)),
      (chatBottom, Optional(WorkspaceDockLayout.conversationID))] {
      let landing = try XCTUnwrap(dock.landing(at: window.convertPoint(toScreen: position),
        sourceID: .displayPanel, sourceTabCount: 3))
      XCTAssertEqual(landing.targetID, expected)
      XCTAssertEqual(landing.edge, .bottom)
    }

    func strip(_ view: NSView) -> ThemedTabStripView? {
      if let strip = view as? ThemedTabStripView { return strip }
      return view.subviews.lazy.compactMap { strip($0) }.first
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    let tabStrip = try XCTUnwrap(strip(panel.view))
    let chip = try XCTUnwrap(tabStrip.chipView(for: third.id))
    let start = point(chip, NSPoint(x: chip.bounds.midX, y: chip.bounds.midY))
    chip.mouseDown(with: try event(.leftMouseDown, start))
    chip.mouseDragged(with: try event(.leftMouseDragged, wholeBottom))
    XCTAssertTrue(dock.hosts.isEmpty, "preview cannot create controllers or mutate layout")
    XCTAssertNotNil(dock.view.subviews.compactMap { $0 as? WorkspaceDockPreview }.first?.landing)
    chip.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: wholeBottom,
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
    XCTAssertTrue(dock.hosts.isEmpty)
    XCTAssertNil(dock.view.subviews.compactMap { $0 as? WorkspaceDockPreview }.first?.landing)

    chip.mouseDown(with: try event(.leftMouseDown, start))
    chip.mouseDragged(with: try event(.leftMouseDragged, wholeBottom))
    chip.mouseUp(with: try event(.leftMouseUp, wholeBottom))
    window.contentView?.layoutSubtreeIfNeeded()
    let left = try XCTUnwrap(dock.hosts.first)
    XCTAssertTrue(left.tabs(for: session).first === third)
    XCTAssertFalse(panel.tabs(for: session).contains { $0.id == third.id })
    let leftFrame = dock.view.convert(left.view.bounds, from: left.view)
    let headerPoint = window.convertPoint(toScreen: point(dock.view,
      NSPoint(x: leftFrame.minX + leftFrame.width * 0.7, y: leftFrame.maxY - 14)))
    XCTAssertNil(dock.landing(at: headerPoint, sourceID: .displayPanel, sourceTabCount: 2, now: 100))
    let held = try XCTUnwrap(dock.landing(at: headerPoint, sourceID: .displayPanel,
      sourceTabCount: 2, now: 100.5))
    XCTAssertEqual(held.targetID, left.dockID)
    XCTAssertEqual(held.edge, .right)
    dock.clearHover()
    let innerRight = point(dock.view, NSPoint(x: leftFrame.maxX - 55, y: leftFrame.midY))
    XCTAssertTrue(panel.dragOutDestination?(second.id, innerRight) ?? false)
    panel.performDragOut?(second.id, innerRight)
    panel.dragOutEnded?(second.id)
    window.contentView?.layoutSubtreeIfNeeded()
    XCTAssertEqual(dock.hosts.count, 2)
    let right = try XCTUnwrap(dock.hosts.first { $0 !== left })
    XCTAssertTrue(right.tabs(for: session).first === second)
    XCTAssertEqual(left.view.bounds.height, right.view.bounds.height, accuracy: 1)
    XCTAssertGreaterThan(left.view.bounds.width, 300)
    let verticalSplit = try XCTUnwrap(dock.view.subviews.first { $0 is ThemedSplitView } as? ThemedSplitView)
    XCTAssertFalse(verticalSplit.isVertical)
    let before = try XCTUnwrap(dock.layout.nodes.first { $0.id == dock.layout.rootID }).fraction
    let dividerY = try XCTUnwrap(verticalSplit.arrangedSubviews.first).frame.maxY
    let grab = verticalSplit.convert(NSPoint(x: verticalSplit.bounds.midX, y: dividerY + verticalSplit.dividerThickness / 2), to: nil)
    let release = verticalSplit.convert(NSPoint(x: verticalSplit.bounds.midX, y: dividerY - 50), to: nil)
    window.postEvent(try event(.leftMouseDragged, release), atStart: false)
    for _ in 0..<3 { window.postEvent(try event(.leftMouseUp, release), atStart: false) }
    verticalSplit.mouseDown(with: try event(.leftMouseDown, grab))
    window.contentView?.layoutSubtreeIfNeeded()
    let saved = try XCTUnwrap(DisplayPaneStore.shared.loadLayout(for: session)?.dockLayout)
    let after = try XCTUnwrap(saved.nodes.first { $0.id == saved.rootID }).fraction
    XCTAssertLessThan(after, before - 0.02, "dragging a horizontal divider must save its new height")
    XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 1280, height: 760))
  }

  private func tab(_ session: SessionID) -> PaneTab {
    let plugin = NativePluginPaneViewController(bundleURL: URL(fileURLWithPath: "/fixture.bundle"),
      owningSessionID: session, loadPlugin: { _ in .success(DockFixturePlugin()) })
    return PaneTab(body: .nativePlugin(plugin), owningSessionID: session)
  }
}

@MainActor
private final class DockFixturePlugin: NSObject, ThreadingNativePlugin {
  required override init() { super.init() }
  static let pluginAPIVersion = 5
  var pluginIdentifier: String { "codes.threading.tests.docking" }
  func makePaneView(context: PluginContext) -> NSView { NSView() }
  func apply(theme: PluginTheme) {}
}
