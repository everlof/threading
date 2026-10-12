import AppKit

/// Window-owned docking. Pointer tracking only reads the bounded visible tree; controllers,
/// persistence and split views are created on a committed drop, never during a hover.
final class WorkspaceDockController: NSViewController {
  struct Landing: Equatable {
    var targetID: UUID?
    var edge: WorkspaceDockLayout.Edge
    var frame: NSRect
  }

  let base: NSViewController
  let conversation: NSViewController
  let display: NSViewController
  let conversationBranch = WorkspaceDockBranchController()
  let displayBranch = WorkspaceDockBranchController()
  private(set) var sessionID: SessionID?
  private(set) var layout = WorkspaceDockLayout()
  private var layouts: [SessionID: WorkspaceDockLayout] = [:]
  private var groups: [SessionID: [UUID: DisplayPaneController]] = [:]
  private var hostIndex: [UUID: DisplayPaneController] = [:]
  private var splitControllers: [UUID: WorkspaceDockSplitController] = [:]
  private let preview = WorkspaceDockPreview()
  private var installed: NSViewController?
  private var changingLayout = false
  private var headerHover: (pane: UUID, edge: WorkspaceDockLayout.Edge, since: TimeInterval)?
  func clearHover() { headerHover = nil }
  var configureHost: ((DisplayPaneController) -> Void)?

  var hosts: [DisplayPaneController] {
    guard let sessionID else { return [] }
    return layout.panes.compactMap { groups[sessionID]?[$0.id] }
  }

  func hosts(for session: SessionID) -> [DisplayPaneController] {
    (layouts[session]?.panes ?? []).compactMap { groups[session]?[$0.id] }
  }

  var allHosts: [DisplayPaneController] {
    groups.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { session in
      (layouts[session]?.panes ?? []).compactMap { groups[session]?[$0.id] }
    }
  }

  init(base: NSViewController, conversation: NSViewController, display: NSViewController) {
    self.base = base
    self.conversation = conversation
    self.display = display
    super.init(nibName: nil, bundle: nil)
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    view = NSView()
    installTree()
  }

  func showSession(_ sessionID: SessionID?) {
    guard self.sessionID != sessionID else { return }
    hosts.forEach { $0.showSessionTabs(nil) }
    self.sessionID = sessionID
    if let sessionID {
      layout = layouts[sessionID] ?? DisplayPaneStore.shared.loadLayout(for: sessionID)?.dockLayout
        ?? WorkspaceDockLayout()
      layouts[sessionID] = layout
      for node in layout.panes { _ = host(node.id, for: sessionID) }
      hosts.forEach { $0.showSessionTabs(sessionID) }
    } else { layout = WorkspaceDockLayout() }
    if isViewLoaded { installTree() }
  }

  func resolve(_ id: UUID) -> DisplayPaneController? {
    hostIndex[id]
  }

  private func host(_ id: UUID, for session: SessionID) -> DisplayPaneController {
    if let existing = groups[session]?[id] { return existing }
    let host = DisplayPaneController(dockID: id, dockSessionID: session)
    groups[session, default: [:]][id] = host
    hostIndex[id] = host
    configureHost?(host)
    host.onTabsChanged = { [weak self] in
      // Never remove the strip currently inside its mouse-tracking callback.
      DispatchQueue.main.async { [weak self] in self?.pruneEmptyGroups() }
    }
    return host
  }

  /// Returns an empty destination only after the caller has validated the source tab.
  func createGroup(at landing: Landing) -> DisplayPaneController? {
    guard let sessionID else { return nil }
    let span = PerformanceRecorder.shared.begin("workspace-dock.commit", category: "workspace.ui",
      metadata: ["panes": String(layout.panes.count), "edge": landing.edge.rawValue])
    defer { span.end() }
    let id = UUID()
    guard layout.insert(id, beside: landing.targetID, edge: landing.edge) else { return nil }
    persist()
    let destination = host(id, for: sessionID)
    destination.showSessionTabs(sessionID)
    installTree()
    return destination
  }

  func pruneEmptyGroups() {
    guard !changingLayout, let sessionID else { return }
    let empty = hosts.filter { $0.tabs(for: sessionID).isEmpty }.compactMap(\.dockID)
    guard !empty.isEmpty else { return }
    for id in empty {
      layout.remove(id)
      groups[sessionID]?[id] = nil
      hostIndex[id] = nil
    }
    persist()
    installTree()
  }

  func removeSessions(_ ids: Set<SessionID>) {
    if let sessionID, ids.contains(sessionID) { showSession(nil) }
    for session in ids {
      for (id, host) in groups.removeValue(forKey: session) ?? [:] {
        host.removeSession(session)
        hostIndex[id] = nil
      }
      layouts[session] = nil
    }
  }

  private func persist() {
    guard let sessionID else { return }
    layouts[sessionID] = layout
    DisplayPaneStore.shared.saveDockLayout(layout, for: sessionID)
  }

  func landing(at screenPoint: NSPoint, sourceID: TabHostID, sourceTabCount: Int,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Landing? {
    guard sessionID != nil, layout.panes.count < WorkspaceDockLayout.maximumPanes,
      let window = view.window, window.isVisible, !window.isMiniaturized,
      window.occlusionState.contains(.visible) else { return nil }
    let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
    let bounds = view.bounds
    var overHeader = false
    defer { if !overHeader { clearHover() } }
    guard bounds.contains(point) else { return nil }
    // Window edges create a full row/column. Inner edges subdivide the pane under the hand.
    if let edge = Self.edge(at: point, in: bounds, band: 22) {
      return Landing(targetID: nil, edge: edge, frame: Self.previewFrame(bounds, edge: edge, share: 0.3))
    }
    for host in hosts {
      guard !host.view.isHiddenOrHasHiddenAncestor else { continue }
      let frame = view.convert(host.view.bounds, from: host.view)
      guard frame.contains(point), let id = host.dockID else { continue }
      if sourceID == host.hostID && sourceTabCount <= 1 { return nil }
      guard let edge = Self.edge(at: point, in: frame, band: min(90, min(frame.width, frame.height) * 0.28))
      else { return nil }
      if edge == .top, frame.maxY - point.y < ThemedTabStripView.bandHeight {
        overHeader = true
        let side: WorkspaceDockLayout.Edge = point.x < frame.midX ? .left : .right
        if headerHover?.pane != id || headerHover?.edge != side { headerHover = (id, side, now) }
        guard let hover = headerHover, now - hover.since >= 0.4 else { return nil }
        return Landing(targetID: id, edge: side, frame: Self.previewFrame(frame, edge: side, share: 0.5))
      }
      return Landing(targetID: id, edge: edge, frame: Self.previewFrame(frame, edge: edge, share: 0.5))
    }
    for (id, controller) in [(WorkspaceDockLayout.conversationID, conversation),
                              (WorkspaceDockLayout.displayID, display)] {
      guard controller.isViewLoaded, !controller.view.isHiddenOrHasHiddenAncestor else { continue }
      let frame = view.convert(controller.view.bounds, from: controller.view)
      if let edge = Self.edge(at: point, in: frame, band: 90) {
        return Landing(targetID: id, edge: edge, frame: Self.previewFrame(frame, edge: edge, share: 0.5))
      }
    }
    return nil
  }

  // AppKit's base view is unflipped: top is maxY. The preview converts this rect into its
  // flipped coordinates before painting, so the shaded half and committed split agree.
  static func edge(at point: NSPoint, in rect: NSRect, band: CGFloat) -> WorkspaceDockLayout.Edge? {
    guard rect.contains(point) else { return nil }
    let distances: [(WorkspaceDockLayout.Edge, CGFloat)] = [
      (.left, point.x - rect.minX), (.right, rect.maxX - point.x),
      (.top, rect.maxY - point.y), (.bottom, point.y - rect.minY),
    ]
    guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= band else { return nil }
    return nearest.0
  }

  static func previewFrame(_ rect: NSRect, edge: WorkspaceDockLayout.Edge, share: CGFloat) -> NSRect {
    switch edge {
    case .left: return NSRect(x: rect.minX, y: rect.minY, width: rect.width * share, height: rect.height)
    case .right: return NSRect(x: rect.maxX - rect.width * share, y: rect.minY, width: rect.width * share, height: rect.height)
    case .top: return NSRect(x: rect.minX, y: rect.maxY - rect.height * share, width: rect.width, height: rect.height * share)
    case .bottom: return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * share)
    }
  }

  func showPreview(_ landing: Landing?) {
    preview.landing = landing.map { preview.convert($0.frame, from: view) }
    preview.title = landing.map { target in
      let scope: String
      switch target.targetID {
      case nil: scope = L10n.string("Whole workspace")
      case WorkspaceDockLayout.conversationID: scope = L10n.string("Conversation")
      case WorkspaceDockLayout.displayID: scope = L10n.string("Side panel")
      default: scope = L10n.string("This pane")
      }
      return L10n.string(target.edge.title) + " · " + scope
    } ?? ""
    preview.isHidden = landing == nil
  }

  private func installTree() {
    changingLayout = true
    defer { changingLayout = false }
    showPreview(nil)
    installed?.view.removeFromSuperview()
    installed?.removeFromParent()
    // Reuse every leaf controller. Rebuilding the small split skeleton never rebuilds content.
    conversationBranch.install(nil)
    displayBranch.install(nil)
    for split in splitControllers.values { split.releaseChildren() }
    splitControllers.removeAll()
    func build(_ id: UUID) -> NSViewController {
      guard let node = layout.nodes.first(where: { $0.id == id }) else { return base }
      switch node.kind {
      case .workspace:
        conversationBranch.install(build(node.first!))
        displayBranch.install(build(node.second!))
        return base
      case .conversation: return conversation
      case .display: return display
      case .pane: return groups[sessionID!]![id]!
      case .split:
        let split = WorkspaceDockSplitController(node: node, first: build(node.first!), second: build(node.second!))
        split.onResize = { [weak self] fraction in
          guard let self, !changingLayout,
            let index = layout.nodes.firstIndex(where: { $0.id == id }) else { return }
          layout.nodes[index].fraction = fraction
          persist()
        }
        splitControllers[id] = split
        return split
      }
    }
    let root = build(layout.rootID)
    root.removeFromParent()
    addChild(root)
    root.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(root.view)
    NSLayoutConstraint.activate([
      root.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      root.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      root.view.topAnchor.constraint(equalTo: view.topAnchor),
      root.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    installed = root
    preview.removeFromSuperview()
    preview.frame = view.bounds
    preview.autoresizingMask = [.width, .height]
    view.addSubview(preview)
  }
}

private final class WorkspaceDockSplitController: NSViewController, NSSplitViewDelegate {
  let split = ThemedSplitView()
  let node: WorkspaceDockLayout.Node
  var onResize: ((Double) -> Void)?
  private var fraction: Double

  init(node: WorkspaceDockLayout.Node, first: NSViewController, second: NSViewController) {
    self.node = node
    fraction = node.fraction
    super.init(nibName: nil, bundle: nil)
    split.isVertical = node.axis == .horizontal
    split.delegate = self
    view = split
    for child in [first, second] {
      child.view.removeFromSuperview()
      child.removeFromParent()
      addChild(child)
      child.view.translatesAutoresizingMaskIntoConstraints = true
      split.addArrangedSubview(child.view)
    }
    split.dividerDragDidEnd = { [weak self] _, _ in
      guard let self else { return }
      onResize?(fraction)
    }
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func releaseChildren() {
    for child in children {
      child.view.removeFromSuperview()
      child.removeFromParent()
    }
  }

  func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
    let length = split.isVertical ? split.bounds.width : split.bounds.height
    let available = max(0, length - split.dividerThickness)
    let first = available * fraction
    guard split.arrangedSubviews.count == 2 else { return }
    if split.isVertical {
      split.arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: first, height: split.bounds.height)
      split.arrangedSubviews[1].frame = NSRect(x: first + split.dividerThickness, y: 0,
        width: available - first, height: split.bounds.height)
    } else {
      split.arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: split.bounds.width, height: first)
      split.arrangedSubviews[1].frame = NSRect(x: 0, y: first + split.dividerThickness,
        width: split.bounds.width, height: available - first)
    }
  }

  func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimum: CGFloat,
    ofSubviewAt dividerIndex: Int) -> CGFloat {
    (split.isVertical ? split.bounds.width : split.bounds.height) * 0.1
  }

  func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximum: CGFloat,
    ofSubviewAt dividerIndex: Int) -> CGFloat {
    (split.isVertical ? split.bounds.width : split.bounds.height) * 0.9
  }

  func splitViewDidResizeSubviews(_ notification: Notification) {
    let length = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
    guard length > 0, let first = split.arrangedSubviews.first else { return }
    fraction = min(0.9, max(0.1, (split.isVertical ? first.frame.width : first.frame.height) / length))
  }
}

/// A stable split item whose contents can acquire their own dock tree.
final class WorkspaceDockBranchController: NSViewController {
  override func loadView() { view = NSView() }
  func install(_ controller: NSViewController?) {
    for child in children { child.view.removeFromSuperview(); child.removeFromParent() }
    guard let controller else { return }
    controller.view.removeFromSuperview()
    controller.removeFromParent()
    addChild(controller)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controller.view)
    NSLayoutConstraint.activate([
      controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controller.view.topAnchor.constraint(equalTo: view.topAnchor),
      controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
}
