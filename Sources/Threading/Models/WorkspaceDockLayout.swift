import Foundation

/// A bounded, flat tree. Decoding never recursively allocates an untrusted layout.
struct WorkspaceDockLayout: Codable, Equatable {
  static let maximumPanes = 8
  static let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

  static let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  static let displayID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

  enum Axis: String, Codable { case horizontal, vertical }
  enum Edge: String, CaseIterable { case left, right, top, bottom
    var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    var precedes: Bool { self == .left || self == .top }
    var title: String {
      switch self {
      case .left: return "Split Left"
      case .right: return "Split Right"
      case .top: return "Split Above"
      case .bottom: return "Split Below"
      }
    }
  }

  struct Node: Codable, Equatable {
    enum Kind: String, Codable { case workspace, conversation, display, pane, split }
    var id: UUID
    var kind: Kind
    var axis: Axis? = nil
    var first: UUID? = nil
    var second: UUID? = nil
    var fraction: Double = 0.5
    var activeTabID: String? = nil
  }

  var rootID = workspaceID
  var nodes = [
    Node(id: workspaceID, kind: .workspace, first: conversationID, second: displayID),
    Node(id: conversationID, kind: .conversation), Node(id: displayID, kind: .display),
  ]
  var panes: [Node] { nodes.filter { $0.kind == .pane } }

  func validated() -> Bool {
    guard !nodes.isEmpty, nodes.count <= Self.maximumPanes * 2 + 3,
      Set(nodes.map(\.id)).count == nodes.count,
      nodes.filter({ $0.kind == .workspace }).map(\.id) == [Self.workspaceID],
      nodes.filter({ $0.kind == .conversation }).map(\.id) == [Self.conversationID],
      nodes.filter({ $0.kind == .display }).map(\.id) == [Self.displayID],
      panes.count <= Self.maximumPanes
    else { return false }
    let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    var pending = [rootID]
    var visited = Set<UUID>()
    while let id = pending.popLast() {
      guard visited.insert(id).inserted, let node = byID[id],
        node.fraction.isFinite, (0.1...0.9).contains(node.fraction)
      else { return false }
      if node.kind == .split || node.kind == .workspace {
        guard (node.kind == .workspace || node.axis != nil), let first = node.first, let second = node.second,
          node.activeTabID == nil, node.kind != .workspace || node.axis == nil else { return false }
        pending += [first, second]
      } else if node.first != nil || node.second != nil || node.axis != nil {
        return false
      } else if node.kind != .pane, node.activeTabID != nil {
        return false
      }
    }
    guard visited.count == nodes.count, let workspace = byID[Self.workspaceID],
      let first = workspace.first, let second = workspace.second else { return false }
    func contains(_ anchor: UUID, below root: UUID) -> Bool {
      var branch = [root]
      while let id = branch.popLast() {
        if id == anchor { return true }
        if let node = byID[id], let first = node.first, let second = node.second {
          branch += [first, second]
        }
      }
      return false
    }
    return contains(Self.conversationID, below: first) && contains(Self.displayID, below: second)
  }

  /// nil wraps the entire workspace; a pane id subdivides just that pane.
  @discardableResult
  mutating func insert(_ paneID: UUID, beside targetID: UUID?, edge: Edge) -> Bool {
    let target = targetID ?? rootID
    guard panes.count < Self.maximumPanes, !nodes.contains(where: { $0.id == paneID }),
      nodes.contains(where: { $0.id == target }) else { return false }
    let splitID = UUID()
    if let parent = nodes.firstIndex(where: { $0.first == target || $0.second == target }) {
      if nodes[parent].first == target { nodes[parent].first = splitID }
      else { nodes[parent].second = splitID }
    } else { rootID = splitID }
    nodes.append(Node(id: paneID, kind: .pane))
    nodes.append(Node(id: splitID, kind: .split, axis: edge.axis,
      first: edge.precedes ? paneID : target, second: edge.precedes ? target : paneID,
      fraction: targetID == nil ? (edge.precedes ? 0.3 : 0.7) : 0.5))
    return true
  }

  mutating func remove(_ paneID: UUID) {
    guard nodes.contains(where: { $0.id == paneID && $0.kind == .pane }),
      let parent = nodes.first(where: { $0.first == paneID || $0.second == paneID }),
      let sibling = parent.first == paneID ? parent.second : parent.first else { return }
    for index in nodes.indices {
      if nodes[index].first == parent.id { nodes[index].first = sibling }
      if nodes[index].second == parent.id { nodes[index].second = sibling }
    }
    if rootID == parent.id { rootID = sibling }
    nodes.removeAll { $0.id == paneID || $0.id == parent.id }
  }
}
