import AppKit

/// Resolves navigator rows through the outline's existing identity index. Expansion/reload
/// builds that index once; scrolling, painting and keyboard movement never flatten a second
/// project tree or create views outside the viewport.
@MainActor
struct SidebarVisibleRows {
    enum Row: Equatable, Sendable {
        case repository(identity: String, representativeProjectIndex: Int,
                        representativeProjectID: String)
        case project(projectIndex: Int, id: String)
        case agent(projectIndex: Int, childIndex: Int, id: String)
        case terminal(projectIndex: Int, childIndex: Int, id: String)

        var isExpandableParent: Bool {
            switch self {
            case .repository, .project: return true
            case .agent, .terminal: return false
            }
        }
    }

    // Match the store's recent-runtime query bound, even for a wider diagnostic input.
    nonisolated static let maximumChildrenPerKind = 512

    let outline: NSOutlineView
    let projects: [ProjectSnapshot]
    let projectIndexes: [String: Int]

    var totalCount: Int { outline.numberOfRows }

    func row(at absoluteIndex: Int) -> Row? {
        (outline.item(atRow: absoluteIndex) as? NavigatorOutlineItem)?
            .resolvedRow(in: projects, indexes: projectIndexes)
    }

    enum Direction { case left, right }

    /// Right expands the selected row; Left folds it or selects its parent.
    func navigate(_ direction: Direction, from item: NavigatorOutlineItem) -> NavigatorOutlineItem? {
        guard index(of: item) != nil else { return nil }
        switch direction {
        case .right:
            guard outline.isExpandable(item) else { return item }
            if !outline.isItemExpanded(item) { outline.expandItem(item) }
            return item
        case .left:
            if outline.isExpandable(item), outline.isItemExpanded(item) {
                outline.collapseItem(item)
                return item
            }
            if item.kind == .repository { return item }
            if item.kind == .project {
                guard let source = outline.dataSource as? NavigatorOutlineSource,
                      let identity = source.repositoryIdentityByProject[item.projectID],
                      let group = source.repositoryGroups[identity] else { return item }
                let index = group.representativeProjectIndex
                return NavigatorOutlineItem(repositoryIdentity: identity,
                    representativeProjectID: index.map { projects[$0].id }, projectIndex: index)
            }
            return NavigatorOutlineItem(projectID: item.projectID, projectIndex: item.projectIndex)
        }
    }

    func index(of projectIndex: Int) -> Int? {
        guard projects.indices.contains(projectIndex) else { return nil }
        return index(of: NavigatorOutlineItem(projectID: projects[projectIndex].id,
                                              projectIndex: projectIndex))
    }

    func index(of item: NavigatorOutlineItem) -> Int? {
        let row = outline.row(forItem: item)
        return row >= 0 ? row : nil
    }
}
