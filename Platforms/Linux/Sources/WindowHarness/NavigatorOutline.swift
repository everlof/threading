import AppKit

/// Stable outline identities and the native navigator’s bounded project-child source.
struct NavigatorOutlineItem: Hashable {
    enum Kind: Hashable { case project, agent, terminal }
    let kind: Kind
    let projectID: String
    let id: String
    let projectIndex: Int
    let childIndex: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.projectID == rhs.projectID && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(projectID)
        hasher.combine(id)
    }

    init(projectID: String, projectIndex: Int) {
        kind = .project
        self.projectID = projectID
        id = projectID
        self.projectIndex = projectIndex
        childIndex = -1
    }

    init(kind: Kind, projectID: String, id: String, projectIndex: Int, childIndex: Int) {
        self.kind = kind
        self.projectID = projectID
        self.id = id
        self.projectIndex = projectIndex
        self.childIndex = childIndex
    }

    init(_ row: SidebarVisibleRows.Row, projects: [ProjectSnapshot]) {
        switch row {
        case .project(let projectIndex, let id):
            self.init(projectID: id, projectIndex: projectIndex)
        case .agent(let projectIndex, let childIndex, let id):
            self.init(kind: .agent, projectID: projects[projectIndex].id, id: id,
                      projectIndex: projectIndex, childIndex: childIndex)
        case .terminal(let projectIndex, let childIndex, let id):
            self.init(kind: .terminal, projectID: projects[projectIndex].id, id: id,
                      projectIndex: projectIndex, childIndex: childIndex)
        }
    }

    func resolvedRow(in projects: [ProjectSnapshot], indexes: [String: Int])
        -> SidebarVisibleRows.Row? {
        guard let projectIndex = indexes[projectID], projects.indices.contains(projectIndex),
              projects[projectIndex].id == projectID else { return nil }
        let project = projects[projectIndex]
        switch kind {
        case .project: return .project(projectIndex: projectIndex, id: projectID)
        case .agent:
            let children = project.recentAgents.prefix(SidebarVisibleRows.maximumChildrenPerKind)
            let current = children.indices.contains(childIndex) && children[childIndex].id == id
                ? childIndex : children.firstIndex(where: { $0.id == id })
            guard let childIndex = current else { return nil }
            return .agent(projectIndex: projectIndex, childIndex: childIndex, id: id)
        case .terminal:
            let children = project.recentTerminals.prefix(SidebarVisibleRows.maximumChildrenPerKind)
            let current = children.indices.contains(childIndex) && children[childIndex].id == id
                ? childIndex : children.firstIndex(where: { $0.id == id })
            guard let childIndex = current else { return nil }
            return .terminal(projectIndex: projectIndex, childIndex: childIndex, id: id)
        }
    }
}

@MainActor
final class NavigatorOutlineSource: NSOutlineViewDataSource, NSOutlineViewDelegate {
    var projects: [ProjectSnapshot] = []
    var projectIndexes: [String: Int] = [:]
    var canChangeExpansion: (() -> Bool)?
    var expansionChanged: ((NavigatorOutlineItem, Bool) -> Void)?
    var makeRow: ((NSOutlineView, NavigatorOutlineItem) -> NSView?)?
    var makeChrome: ((NSOutlineView, NavigatorOutlineItem) -> NSTableRowView?)?

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        canChangeExpansion?() ?? true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        canChangeExpansion?() ?? true
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? NavigatorOutlineItem else { return }
        expansionChanged?(item, true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? NavigatorOutlineItem else { return }
        expansionChanged?(item, false)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return projects.count }
        guard let item = item as? NavigatorOutlineItem, item.kind == .project,
              let index = projectIndexes[item.projectID], projects.indices.contains(index)
        else { return 0 }
        let project = projects[index]
        return min(project.recentAgents.count, SidebarVisibleRows.maximumChildrenPerKind)
            + min(project.recentTerminals.count, SidebarVisibleRows.maximumChildrenPerKind)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else {
            return NavigatorOutlineItem(projectID: projects[index].id, projectIndex: index)
        }
        let parent = item as! NavigatorOutlineItem
        let projectIndex = projectIndexes[parent.projectID]!
        let project = projects[projectIndex]
        let agentCount = min(project.recentAgents.count, SidebarVisibleRows.maximumChildrenPerKind)
        if index < agentCount {
            return NavigatorOutlineItem(kind: .agent, projectID: parent.projectID,
                id: project.recentAgents[index].id, projectIndex: projectIndex, childIndex: index)
        }
        let childIndex = index - agentCount
        return NavigatorOutlineItem(kind: .terminal, projectID: parent.projectID,
            id: project.recentTerminals[childIndex].id,
            projectIndex: projectIndex, childIndex: childIndex)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? NavigatorOutlineItem, item.kind == .project,
              let index = projectIndexes[item.projectID], projects.indices.contains(index)
        else { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? NavigatorOutlineItem else { return nil }
        return makeRow?(outlineView, item)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any)
        -> NSTableRowView? {
        guard let item = item as? NavigatorOutlineItem else { return nil }
        return makeChrome?(outlineView, item)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? NavigatorOutlineItem else { return SidebarDefaults.rowHeight }
        return item.kind == .project
            ? SidebarDefaults.projectCompactRowHeight : SidebarDefaults.rowHeight
    }
}
