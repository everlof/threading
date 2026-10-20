import AppKit
@testable import CoreSlice

/// Stable outline identities and the native navigator’s bounded project-child source.
struct NavigatorOutlineItem: Hashable {
    enum Kind: Hashable { case repository, project, agent, terminal }
    let kind: Kind
    let projectID: String
    let id: String
    let projectIndex: Int
    let childIndex: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind == .repository || rhs.kind == .repository {
            return lhs.kind == rhs.kind && lhs.id == rhs.id
        }
        return lhs.kind == rhs.kind && lhs.projectID == rhs.projectID && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        if kind != .repository { hasher.combine(projectID) }
        hasher.combine(id)
    }

    init(repositoryIdentity: String, representativeProjectID: String?, projectIndex: Int?) {
        kind = .repository
        projectID = representativeProjectID ?? ""
        id = repositoryIdentity
        self.projectIndex = projectIndex ?? -1
        childIndex = -1
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
        case .repository(let identity, let projectIndex, let projectID):
            self.init(repositoryIdentity: identity, representativeProjectID: projectID,
                      projectIndex: projectIndex)
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
        if kind == .repository {
            return .repository(identity: id, representativeProjectIndex: projectIndex,
                               representativeProjectID: projectID)
        }
        guard let projectIndex = indexes[projectID], projects.indices.contains(projectIndex),
              projects[projectIndex].id == projectID else { return nil }
        let project = projects[projectIndex]
        switch kind {
        case .repository: return nil
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

struct NavigatorRepositoryGroup {
    let identity: String
    var name: String
    var projectIndexes: [Int]
    var representativeProjectIndex: Int?
}

@MainActor
final class NavigatorOutlineSource: NSOutlineViewDataSource, NSOutlineViewDelegate {
    var projects: [ProjectSnapshot] = []
    var projectIndexes: [String: Int] = [:]
    private(set) var roots: [NavigatorOutlineItem] = []
    private var repositoryItemsByIdentity: [String: NavigatorOutlineItem] = [:]
    private(set) var repositoryGroups: [String: NavigatorRepositoryGroup] = [:]
    private(set) var repositoryIdentityByProject: [String: String] = [:]
    private(set) var checkoutCatalog = LinuxGitCheckoutCatalog.empty
    var branchOverrides: [String: CheckoutBranchDisplay] = [:]
    var canChangeExpansion: (() -> Bool)?
    var expansionChanged: ((NavigatorOutlineItem, Bool) -> Void)?
    var makeRow: ((NSOutlineView, NavigatorOutlineItem) -> NSView?)?
    var makeChrome: ((NSOutlineView, NavigatorOutlineItem) -> NSTableRowView?)?

    func branch(for projectID: String) -> String? {
        if let override = branchOverrides[projectID] { return override.name }
        return checkoutCatalog.checkouts[projectID]?.branch
    }

    func rebuildRepositories(catalogue: LinuxGitCheckoutCatalog) {
        checkoutCatalog = catalogue
        roots = []
        repositoryGroups = [:]
        repositoryIdentityByProject = [:]
        for (index, project) in projects.enumerated() {
            let identity = project.isScratchpad ? nil :
                (catalogue.checkouts[project.id]?.repositoryIdentity
                    ?? project.lastKnownRepositoryIdentity)
            guard let identity else {
                roots.append(NavigatorOutlineItem(projectID: project.id, projectIndex: index))
                continue
            }
            repositoryIdentityByProject[project.id] = identity
            let checkout = catalogue.checkouts[project.id]
            let isMainWorktree = checkout?.identity == identity && checkout?.root == project.path
            if var group = repositoryGroups[identity] {
                group.projectIndexes.append(index)
                if group.representativeProjectIndex == nil && checkout != nil {
                    group.representativeProjectIndex = index
                }
                if isMainWorktree {
                    group.name = project.name
                    group.representativeProjectIndex = index
                }
                repositoryGroups[identity] = group
            } else {
                let repositoryPath = URL(fileURLWithPath: identity).deletingLastPathComponent()
                let group = NavigatorRepositoryGroup(identity: identity,
                    name: isMainWorktree ? project.name : repositoryPath.lastPathComponent,
                    projectIndexes: [index],
                    representativeProjectIndex: checkout == nil ? nil : index)
                repositoryGroups[identity] = group
                roots.append(NavigatorOutlineItem(repositoryIdentity: identity,
                    representativeProjectID: nil, projectIndex: nil))
            }
        }
        roots = roots.map { item in
            guard item.kind == .repository, let group = repositoryGroups[item.id],
                  let index = group.representativeProjectIndex else { return item }
            return NavigatorOutlineItem(repositoryIdentity: item.id,
                representativeProjectID: projects[index].id, projectIndex: index)
        }
        repositoryItemsByIdentity = Dictionary(uniqueKeysWithValues: roots.compactMap { item in
            item.kind == .repository ? (item.id, item) : nil
        })
    }

    func repositoryItem(for projectID: String) -> NavigatorOutlineItem? {
        guard let identity = repositoryIdentityByProject[projectID] else { return nil }
        return repositoryItemsByIdentity[identity]
    }

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
        guard let item else { return roots.count }
        guard let item = item as? NavigatorOutlineItem else { return 0 }
        if item.kind == .repository {
            return repositoryGroups[item.id]?.projectIndexes.count ?? 0
        }
        guard item.kind == .project,
              let index = projectIndexes[item.projectID], projects.indices.contains(index)
        else { return 0 }
        let project = projects[index]
        return min(project.recentAgents.count, SidebarVisibleRows.maximumChildrenPerKind)
            + min(project.recentTerminals.count, SidebarVisibleRows.maximumChildrenPerKind)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else {
            return roots[index]
        }
        let parent = item as! NavigatorOutlineItem
        if parent.kind == .repository {
            let projectIndex = repositoryGroups[parent.id]!.projectIndexes[index]
            return NavigatorOutlineItem(projectID: projects[projectIndex].id,
                                        projectIndex: projectIndex)
        }
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
        guard let item = item as? NavigatorOutlineItem else { return false }
        if item.kind == .repository { return repositoryGroups[item.id] != nil }
        guard item.kind == .project,
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
        if item.kind == .repository { return SidebarDefaults.headingRowHeight }
        return item.kind == .project
            ? SidebarDefaults.projectCompactRowHeight : SidebarDefaults.rowHeight
    }
}
