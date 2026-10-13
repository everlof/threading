import AppKit

/// Window-owned docking. Pointer tracking only reads the bounded visible tree; controllers,
/// persistence and split views are created on a committed drop, never during a hover.
final class WorkspaceDockController: NSViewController {
  /// Where a dragged tab would land: beside its target, or — with no edge — into the target
  /// pane's own tabs.
  struct Landing: Equatable {
    /// nil wraps the whole workspace; otherwise an anchor or a docked pane.
    var targetID: UUID?
    /// nil joins the target pane rather than splitting it.
    var edge: WorkspaceDockLayout.Edge?
    var frame: NSRect
  }

  private enum Metrics {
    /// The window's outermost points target the whole workspace.
    static let workspaceEdgeBand: CGFloat = 22
    /// How far inside a pane its edges still mean "beside this pane".
    static let paneEdgeBand: CGFloat = 90
    /// Each edge takes at most this share of a small pane, so every pane keeps a centre that
    /// joins it.
    static let paneEdgeShare: CGFloat = 0.28
  }

  /// The split tree's shape without its divider positions or selections. Two layouts with the
  /// same skeleton install the same view hierarchy.
  private struct Skeleton: Equatable {
    struct Node: Equatable {
      let id: UUID
      let kind: WorkspaceDockLayout.Node.Kind
      let axis: WorkspaceDockLayout.Axis?
      let first: UUID?
      let second: UUID?
    }
    let rootID: UUID
    let nodes: [Node]

    init(_ layout: WorkspaceDockLayout) {
      rootID = layout.rootID
      nodes = layout.nodes.map {
        Node(id: $0.id, kind: $0.kind, axis: $0.axis, first: $0.first, second: $0.second)
      }
    }
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
  private var installedSkeleton: Skeleton?
  private var changingLayout = false
  var configureHost: ((DisplayPaneController) -> Void)?
  /// Whether a screen point lies on a tab row. A row takes a tab at a slot or not at all, so a
  /// landing is never offered underneath one. Supplied by the window, which owns every row.
  var isOverTabRow: ((NSPoint) -> Bool)?

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

  var canAddPane: Bool { layout.panes.count < WorkspaceDockLayout.maximumPanes }

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
      let restoring = layouts[sessionID] == nil
      layout = layouts[sessionID] ?? DisplayPaneStore.shared.loadLayout(for: sessionID)?.dockLayout
        ?? WorkspaceDockLayout()
      layouts[sessionID] = layout
      for node in layout.panes { _ = host(node.id, for: sessionID) }
      hosts.forEach { $0.showSessionTabs(sessionID) }
      if restoring { removeGroupsThatRestoredEmpty(for: sessionID) }
    } else { layout = WorkspaceDockLayout() }
    if isViewLoaded { installTree() }
  }

  func resolve(_ id: UUID) -> DisplayPaneController? {
    hostIndex[id]
  }

  /// The docked pane nearest an anchor, inside that anchor's own branch.
  func nearestHost(to anchor: UUID) -> DisplayPaneController? {
    guard let sessionID, let id = layout.nearestPane(to: anchor) else { return nil }
    return groups[sessionID]?[id]
  }

  private func host(_ id: UUID, for session: SessionID) -> DisplayPaneController {
    if let existing = groups[session]?[id] { return existing }
    let host = DisplayPaneController(dockID: id, dockSessionID: session)
    groups[session, default: [:]][id] = host
    hostIndex[id] = host
    configureHost?(host)
    host.onTabsChanged = { [weak self] in
      // Never remove the strip currently inside its mouse-tracking callback.
      DispatchQueue.main.async { [weak self] in self?.pruneEmptyGroups(in: session) }
    }
    return host
  }

  /// Returns an empty destination only after the caller has validated the source tab.
  func createGroup(at landing: Landing) -> DisplayPaneController? {
    guard let sessionID, let edge = landing.edge else { return nil }
    let span = PerformanceRecorder.shared.begin("workspace-dock.commit", category: "workspace.ui",
      metadata: ["panes": String(layout.panes.count), "edge": edge.rawValue])
    defer { span.end() }
    let id = UUID()
    guard layout.insert(id, beside: landing.targetID, edge: edge) else { return nil }
    persist()
    let destination = host(id, for: sessionID)
    destination.showSessionTabs(sessionID)
    installTree()
    return destination
  }

  /// Collapses every pane of `session` (the one on screen by default) that holds no tabs.
  func pruneEmptyGroups(in session: SessionID? = nil) {
    guard !changingLayout, let session = session ?? sessionID else { return }
    let empty = (layouts[session]?.panes ?? []).map(\.id).filter {
      groups[session]?[$0]?.tabs(for: session).isEmpty ?? true
    }
    removeGroups(empty, in: session)
  }

  /// A pane whose tabs never came back is not shown as an empty frame. One whose stored tabs
  /// could not be rebuilt yet — an extension that loads later — keeps its place and its slice.
  private func removeGroupsThatRestoredEmpty(for session: SessionID) {
    let stored = Set(DisplayPaneStore.shared.loadLayout(for: session)?.dockTabs.compactMap(\.dockID) ?? [])
    let empty = (layouts[session]?.panes ?? []).map(\.id).filter {
      !stored.contains($0) && (groups[session]?[$0]?.tabs(for: session).isEmpty ?? true)
    }
    removeGroups(empty, in: session)
  }

  private func removeGroups(_ ids: [UUID], in session: SessionID) {
    guard !ids.isEmpty, var target = layouts[session] else { return }
    for id in ids {
      target.remove(id)
      groups[session]?[id] = nil
      hostIndex[id] = nil
    }
    layouts[session] = target
    DisplayPaneStore.shared.saveDockLayout(target, for: session)
    guard session == sessionID else { return }
    layout = target
    if isViewLoaded { installTree() }
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

  /// The tab host a joining landing names.
  func hostID(joining landing: Landing) -> TabHostID? {
    guard landing.edge == nil, let id = landing.targetID else { return nil }
    if id == WorkspaceDockLayout.displayID { return .displayPanel }
    return hostIndex[id] == nil ? nil : .dock(id)
  }

  /// A pane a landing can be offered over, in the dock view's coordinates.
  struct Target {
    let id: UUID
    /// The host that would take the tab into its row; nil for the conversation, which holds
    /// no tabs to join.
    let host: TabHostID?
    let frame: NSRect
  }

  func landing(at screenPoint: NSPoint, sourceID: TabHostID, sourceTabCount: Int) -> Landing? {
    guard sessionID != nil, let window = view.window, window.isVisible, !window.isMiniaturized,
      window.occlusionState.contains(.visible) else { return nil }
    let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
    var panes: [(id: UUID, host: TabHostID?, controller: NSViewController)] = hosts.compactMap { host in
      host.dockID.map { (id: $0, host: host.hostID, controller: host) }
    }
    panes.append((WorkspaceDockLayout.conversationID, nil, conversation))
    panes.append((WorkspaceDockLayout.displayID, .displayPanel, display))
    let targets = panes.compactMap { pane -> Target? in
      guard pane.controller.isViewLoaded, !pane.controller.view.isHiddenOrHasHiddenAncestor else { return nil }
      return Target(id: pane.id, host: pane.host,
        frame: view.convert(pane.controller.view.bounds, from: pane.controller.view))
    }
    return Self.landing(at: point, in: view.bounds, targets: targets, sourceID: sourceID,
      sourceTabCount: sourceTabCount, canAddPane: canAddPane,
      overTabRow: isOverTabRow?(screenPoint) == true)
  }

  /// The pure decision behind a landing: where the pointer is, never how long it has rested.
  /// Window edges create a full row/column. Inner edges subdivide the pane under the hand, and a
  /// pane that holds tabs takes the tab into its own row when the hand is over its middle. A
  /// tab row is never a landing — it takes the tab at a slot, or nothing.
  static func landing(
    at point: NSPoint, in bounds: NSRect, targets: [Target], sourceID: TabHostID,
    sourceTabCount: Int, canAddPane: Bool, overTabRow: Bool
  ) -> Landing? {
    guard bounds.contains(point), !overTabRow else { return nil }
    if canAddPane, let edge = edge(at: point, in: bounds, band: Metrics.workspaceEdgeBand) {
      return Landing(targetID: nil, edge: edge, frame: previewFrame(bounds, edge: edge,
        share: WorkspaceDockLayout.workspaceShare))
    }
    guard let target = targets.first(where: { $0.frame.contains(point) }) else { return nil }
    // A lone tab can neither split nor rejoin the pane it already fills: either would leave
    // that pane empty beside the result.
    let isSource = target.host == sourceID
    if isSource && sourceTabCount <= 1 { return nil }
    if let edge = edge(at: point, in: target.frame, band: edgeBand(for: target.frame)) {
      guard canAddPane else { return nil }
      return Landing(targetID: target.id, edge: edge, frame: previewFrame(target.frame, edge: edge,
        share: WorkspaceDockLayout.paneShare))
    }
    guard target.host != nil, !isSource else { return nil }
    return Landing(targetID: target.id, edge: nil, frame: target.frame)
  }

  static func edgeBand(for frame: NSRect) -> CGFloat {
    min(Metrics.paneEdgeBand, min(frame.width, frame.height) * Metrics.paneEdgeShare)
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

  /// "Split Below · Side panel", "Move Here · This pane": what the drop does, then where.
  static func title(for landing: Landing) -> String {
    let scope: String
    switch landing.targetID {
    case nil: scope = L10n.string("Whole workspace")
    case WorkspaceDockLayout.conversationID: scope = L10n.string("Conversation")
    case WorkspaceDockLayout.displayID: scope = L10n.string("Side panel")
    default: scope = L10n.string("This pane")
    }
    let action = landing.edge.map { L10n.string($0.title) } ?? L10n.string("Move Here")
    return action + " · " + scope
  }

  func showPreview(_ landing: Landing?) {
    guard let landing else {
      preview.present(nil, title: "")
      return
    }
    preview.present(preview.convert(landing.frame, from: view), title: Self.title(for: landing))
  }

  /// Installs the split tree for `layout`. A layout with the installed shape — every switch
  /// between undocked sessions — changes nothing; otherwise only controllers whose parent
  /// changes are moved, so a leaf that keeps its place never leaves the window.
  private func installTree() {
    changingLayout = true
    defer { changingLayout = false }
    showPreview(nil)
    let skeleton = Skeleton(layout)
    guard installed == nil || skeleton != installedSkeleton else { return }
    installedSkeleton = skeleton
    let retired = splitControllers
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
    if root !== installed {
      // The previous root may now be nested inside the new one; only a root still parented
      // here is taken down.
      if let installed, installed.parent === self {
        installed.view.removeFromSuperview()
        installed.removeFromParent()
      }
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
    }
    // What the new tree did not adopt — another session's panes — leaves with its old split.
    for split in retired.values { split.releaseChildren() }
    if view.subviews.last !== preview {
      preview.removeFromSuperview()
      preview.frame = view.bounds
      preview.autoresizingMask = [.width, .height]
      view.addSubview(preview)
    }
  }
}

private final class WorkspaceDockSplitController: NSViewController, NSSplitViewDelegate {
  /// Neither side of a docked split may be pushed below this share of it.
  private static let minimumShare = 0.1

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

  /// Takes down only the children still parented here; a leaf the new tree adopted has moved.
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
    (split.isVertical ? split.bounds.width : split.bounds.height) * Self.minimumShare
  }

  func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximum: CGFloat,
    ofSubviewAt dividerIndex: Int) -> CGFloat {
    (split.isVertical ? split.bounds.width : split.bounds.height) * (1 - Self.minimumShare)
  }

  func splitViewDidResizeSubviews(_ notification: Notification) {
    let length = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
    guard length > 0, let first = split.arrangedSubviews.first else { return }
    let share = (split.isVertical ? first.frame.width : first.frame.height) / length
    fraction = min(1 - Self.minimumShare, max(Self.minimumShare, share))
  }
}

/// A stable split item whose contents can acquire their own dock tree.
final class WorkspaceDockBranchController: NSViewController {
  override func loadView() { view = NSView() }

  /// Hosts `controller`. Already hosting it is a no-op, so a branch whose content did not change
  /// never takes that content out of the window.
  func install(_ controller: NSViewController?) {
    if let controller, children.count == 1, children.first === controller,
      controller.view.superview === view { return }
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
