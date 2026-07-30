import Foundation

// MARK: - Outline Nodes

/// Reference-typed wrapper for a project row.
///
/// `NSOutlineView` identifies rows by object identity, which value types cannot provide,
/// so nodes are rebuilt from `ProjectStore` on every reload.
final class ProjectNode: NSObject {
    let projectID: ProjectID

    /// Every session in the project, flat, regardless of how it is displayed. Lookup paths
    /// (selection, row refresh) go through this so they need not care about grouping.
    var sessionNodes: [SessionNode] = []

    /// What the outline actually shows under the project: a `BranchGroupNode` where a
    /// branch gathered several sessions, a bare `SessionNode` everywhere else.
    var childNodes: [NSObject] = []

    init(projectID: ProjectID) {
        self.projectID = projectID
    }
}

/// Reference-typed wrapper for a session row.
final class SessionNode: NSObject {
    let sessionID: SessionID

    /// Side chats forked from this session. Empty for almost every row, and a row with none
    /// is not expandable — the same "earns its level" rule the repository and branch groups
    /// follow, applied one level further down.
    var childNodes: [SessionNode] = []

    init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

/// Groups the checkouts of one repository.
///
/// Only created when a repository has more than one checkout added, so a repository with a
/// single checkout keeps the flatter two-level layout.
final class RepoGroupNode: NSObject {
    let name: String
    var projectNodes: [ProjectNode] = []

    init(name: String) {
        self.name = name
    }
}

/// Gathers a project's sessions that ran on the same branch.
///
/// Only created when grouping is enabled and the branch has more than one session — the
/// same rule that keeps single-checkout repositories flat, applied one level down. Sessions
/// with no recorded branch stay directly under the project.
final class BranchGroupNode: NSObject {
    let branch: String
    let projectID: ProjectID
    var sessionNodes: [SessionNode] = []

    init(branch: String, projectID: ProjectID) {
        self.branch = branch
        self.projectID = projectID
    }
}

// MARK: - Tree Builder

/// Builds the sidebar's node tree from the store's projects.
///
/// Pure construction — it reads the store and git metadata but holds no view state, which
/// is what lets it live beside the node types rather than in the view controller. Main-actor
/// because the name order reads `displayTitle`, which is; its only callers — the sidebar
/// and its tests — already are.
@MainActor
enum SidebarTreeBuilder {

    /// Arranges projects into the tree, grouping only where a repository has more than one
    /// checkout added. A single-checkout repository stays a plain project row, so the extra
    /// level never appears without cause.
    static func rootNodes(from projects: [Project]) -> [NSObject] {
        let identities = projects.map { GitInfo.repositoryIdentity(for: $0.folderPath) }

        var checkoutCounts: [String: Int] = [:]
        for identity in identities.compactMap({ $0 }) {
            checkoutCounts[identity, default: 0] += 1
        }

        var roots: [NSObject] = []
        var groupsByIdentity: [String: RepoGroupNode] = [:]

        for (project, identity) in zip(projects, identities) {
            let node = ProjectNode(projectID: project.id)
            // Archived sessions are gathered separately, below the projects.
            let order = AppSettings.sidebarSessionOrder
            let activeSessions = project.sessions
                .filter { !$0.isArchived }
                .enumerated()
                .sorted { precedes($0, $1, order: order) }
                .map(\.element)
            node.sessionNodes = activeSessions.map { SessionNode(sessionID: $0.id) }

            // Side chats hang off the session they were forked from, so only what remains
            // at the project's own level is grouped by branch below.
            let top = attachSideChats(sessions: activeSessions, nodes: node.sessionNodes)
            node.childNodes = childNodes(
                projectID: project.id,
                sessions: top.sessions,
                sessionNodes: top.nodes
            )

            guard let identity, checkoutCounts[identity, default: 0] > 1 else {
                roots.append(node)
                continue
            }

            if let group = groupsByIdentity[identity] {
                group.projectNodes.append(node)
                continue
            }

            let group = RepoGroupNode(name: GitInfo.repositoryName(forIdentity: identity))
            group.projectNodes.append(node)
            groupsByIdentity[identity] = group
            roots.append(group)
        }

        // Archived sessions are not shown here at all — they live in Settings, so the sidebar
        // stays a list of what is active.
        return roots
    }

    /// The rows that must be open for a session's row to exist at all, outermost first.
    ///
    /// Deeper than it looks: a checkout can sit under a repository heading, a session under a
    /// branch heading, and a side chat under the session it was forked from — which nests
    /// again, since a side chat can be forked in turn. Anything that *selects* a session has
    /// to walk the whole chain, because `NSOutlineView` has no row for a hidden item and
    /// `row(forItem:)` answers `-1`, which reads as "nothing to do" at every call site.
    ///
    /// Walked down from the roots rather than up from the row: `parent(forItem:)` only
    /// answers for an item the outline view has already been asked to display, which a
    /// folded-away side chat is precisely not.
    static func ancestors(of sessionID: SessionID, in roots: [NSObject]) -> [NSObject] {
        func path(from node: NSObject) -> [NSObject]? {
            if let session = node as? SessionNode, session.sessionID == sessionID { return [] }

            for child in children(of: node) {
                if let rest = path(from: child) { return [node] + rest }
            }
            return nil
        }

        for root in roots {
            if let found = path(from: root) { return found }
        }
        return []
    }

    /// What the outline view shows under a node — the one place the four node types' differing
    /// child properties are reconciled.
    private static func children(of node: NSObject) -> [NSObject] {
        switch node {
        case let repo as RepoGroupNode: return repo.projectNodes
        case let project as ProjectNode: return project.childNodes
        case let branch as BranchGroupNode: return branch.sessionNodes
        case let session as SessionNode: return session.childNodes
        default: return []
        }
    }

    /// Whether `lhs` sorts ahead of `rhs` under the chosen order.
    ///
    /// Pinned sessions are hoisted first under every order — pinning is a stronger statement
    /// than any sort. The store offset breaks every tie, so orders built on fields that can
    /// collide (two untouched sessions share a `lastActiveAt` second, two prompts start with
    /// the same line) stay stable instead of jittering between rebuilds.
    private static func precedes(
        _ lhs: (offset: Int, element: AgentSession),
        _ rhs: (offset: Int, element: AgentSession),
        order: SidebarSessionOrder
    ) -> Bool {
        if lhs.element.isPinned != rhs.element.isPinned {
            return lhs.element.isPinned
        }

        switch order {
        case .manual:
            break
        case .recentActivity:
            if lhs.element.lastActiveAt != rhs.element.lastActiveAt {
                return lhs.element.lastActiveAt > rhs.element.lastActiveAt
            }
        case .name:
            let comparison = lhs.element.displayTitle
                .localizedCaseInsensitiveCompare(rhs.element.displayTitle)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        }

        return lhs.offset < rhs.offset
    }

    /// Moves every side chat under the node it was forked from, returning what is left at the
    /// project's own level — sessions and nodes still parallel, since the branch grouping
    /// zips them.
    ///
    /// Two records are deliberately tolerated rather than trusted, because this reads a file
    /// that outlives any one release:
    ///
    /// - **A missing parent** (deleted, or archived out of this list) leaves the side chat at
    ///   the project level. The lineage dangles; the row must not vanish with it.
    /// - **A cycle** is refused. Nothing in the app can create one, but the outline view asks
    ///   for children lazily and would happily recurse forever on a corrupt file.
    private static func attachSideChats(
        sessions: [AgentSession],
        nodes: [SessionNode]
    ) -> (sessions: [AgentSession], nodes: [SessionNode]) {
        var parentIDs: [SessionID: SessionID?] = [:]
        for session in sessions {
            parentIDs[session.id] = session.forkedFrom
        }

        var nodesByID: [SessionID: SessionNode] = [:]
        for node in nodes {
            nodesByID[node.sessionID] = node
        }

        var topSessions: [AgentSession] = []
        var topNodes: [SessionNode] = []

        for (session, node) in zip(sessions, nodes) {
            guard let parentID = session.forkedFrom,
                  let parent = nodesByID[parentID],
                  !formsCycle(from: parentID, back: session.id, parentIDs: parentIDs) else {
                topSessions.append(session)
                topNodes.append(node)
                continue
            }

            parent.childNodes.append(node)
        }

        return (topSessions, topNodes)
    }

    /// Whether walking up from `start` reaches `target`, which would make the two each
    /// other's ancestor. Bounded by the record count, so a ring with no root still ends.
    private static func formsCycle(
        from start: SessionID,
        back target: SessionID,
        parentIDs: [SessionID: SessionID?]
    ) -> Bool {
        var current: SessionID? = start
        var steps = 0

        while let id = current, steps <= parentIDs.count {
            if id == target { return true }
            current = parentIDs[id] ?? nil
            steps += 1
        }

        return false
    }

    /// Arranges a project's sessions for display, gathering a branch's sessions under a
    /// `BranchGroupNode` when the branch has more than one — the "group only where it earns
    /// its level" rule, applied inside a project. Sessions with no recorded branch stay
    /// directly under the project; a group takes the position of its first session, so the
    /// list keeps its familiar order.
    ///
    /// A branch with a *single* session earns a heading only once some branch has already
    /// earned the level (`AppSettings.groupsLoneBranches`): a heading over the shared branch
    /// beside a bare row on its own branch reads as though the bare row had none, but a
    /// project whose branches are all singletons stays flat — all-or-nothing labelling, so
    /// the extra level never appears without cause.
    private static func childNodes(
        projectID: ProjectID,
        sessions: [AgentSession],
        sessionNodes: [SessionNode]
    ) -> [NSObject] {
        guard AppSettings.groupsSessionsByBranch else { return sessionNodes }

        var sessionCounts: [String: Int] = [:]
        for session in sessions {
            if let branch = session.branch {
                sessionCounts[branch, default: 0] += 1
            }
        }

        let hasSharedBranch = sessionCounts.values.contains { $0 > 1 }
        let groupsLoneBranches = AppSettings.groupsLoneBranches && hasSharedBranch

        var children: [NSObject] = []
        var groupsByBranch: [String: BranchGroupNode] = [:]

        for (session, sessionNode) in zip(sessions, sessionNodes) {
            guard let branch = session.branch,
                  groupsLoneBranches || sessionCounts[branch, default: 0] > 1 else {
                children.append(sessionNode)
                continue
            }

            if let group = groupsByBranch[branch] {
                group.sessionNodes.append(sessionNode)
                continue
            }

            let group = BranchGroupNode(branch: branch, projectID: projectID)
            group.sessionNodes.append(sessionNode)
            groupsByBranch[branch] = group
            children.append(group)
        }

        return children
    }
}
