import Foundation

// MARK: - Node Identity

/// What makes a row *the same row* across two builds of the tree.
///
/// `NSOutlineView` identifies rows by object identity and the tree is rebuilt from the store
/// whenever the shape changes, so identity has to be carried by something a rebuild preserves.
/// This is that something: equal keys mean the same row, which is what lets a rebuild hand its
/// content to the node already on screen instead of replacing it — and a replaced node cannot be
/// animated, only reloaded. See `SidebarTreeShape`.
enum SidebarNodeKey: Hashable {
    /// The repository's identity on disk rather than its display name: two unrelated
    /// repositories can be called the same thing, and a heading whose name changed is still the
    /// same heading.
    case repository(String)
    case project(ProjectID)
    case branch(ProjectID, String)
    case session(SessionID)
    case terminal(TerminalID)
}

/// Maps a node from a freshly built tree to the node standing for the same row on screen.
///
/// Generic over the node type because every key belongs to exactly one type, so a substitution
/// never changes what a node *is* — which is what lets the nodes' own arrays stay typed.
struct SidebarNodeSubstitution {
    private let nodesByRebuilt: [ObjectIdentifier: NSObject]

    init(nodesByRebuilt: [ObjectIdentifier: NSObject]) {
        self.nodesByRebuilt = nodesByRebuilt
    }

    func callAsFunction<Node: NSObject>(_ rebuilt: Node) -> Node {
        nodesByRebuilt[ObjectIdentifier(rebuilt)] as? Node ?? rebuilt
    }
}

/// The four node types' shared surface: which row a node stands for, what hangs under it, and
/// how it takes over from the node a rebuild produced in its place.
protocol SidebarOutlineNode: NSObject {
    var sidebarKey: SidebarNodeKey { get }

    /// What the outline shows under this node, in display order.
    var sidebarChildren: [NSObject] { get }

    /// Takes everything the rebuild produced — its children, and any content the row draws from
    /// the node rather than from the store — mapping every node it references through
    /// `substituting`, so the tree ends up made of the objects the outline already knows.
    func adoptContent(of rebuilt: any SidebarOutlineNode, substituting: SidebarNodeSubstitution)
}

// MARK: - Outline Nodes

/// Reference-typed wrapper for a project row.
///
/// `NSOutlineView` identifies rows by object identity, which value types cannot provide. The
/// tree is rebuilt from `ProjectStore` whenever its shape changes, but a node whose identity
/// survives keeps its object and takes the rebuild's content — see `SidebarOutlineUpdate.adopt`.
final class ProjectNode: NSObject {
    let projectID: ProjectID

    /// Every session in the project, flat, regardless of how it is displayed. Lookup paths
    /// (selection, row refresh) go through this so they need not care about grouping.
    var sessionNodes: [SessionNode] = []

    /// Standalone terminals currently positioned in this project by their cwd.
    var terminalNodes: [TerminalNode] = []

    /// What the outline actually shows under the project: a `BranchGroupNode` where a
    /// branch gathered several sessions, a bare `SessionNode` everywhere else.
    var childNodes: [NSObject] = []

    init(projectID: ProjectID) {
        self.projectID = projectID
    }
}

extension ProjectNode: SidebarOutlineNode {
    var sidebarKey: SidebarNodeKey { .project(projectID) }
    var sidebarChildren: [NSObject] { childNodes }

    func adoptContent(
        of rebuilt: any SidebarOutlineNode,
        substituting: SidebarNodeSubstitution
    ) {
        guard let rebuilt = rebuilt as? ProjectNode else { return }
        sessionNodes = rebuilt.sessionNodes.map(substituting.callAsFunction)
        terminalNodes = rebuilt.terminalNodes.map(substituting.callAsFunction)
        childNodes = rebuilt.childNodes.map(substituting.callAsFunction)
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

extension SessionNode: SidebarOutlineNode {
    var sidebarKey: SidebarNodeKey { .session(sessionID) }
    var sidebarChildren: [NSObject] { childNodes }

    func adoptContent(
        of rebuilt: any SidebarOutlineNode,
        substituting: SidebarNodeSubstitution
    ) {
        guard let rebuilt = rebuilt as? SessionNode else { return }
        childNodes = rebuilt.childNodes.map(substituting.callAsFunction)
    }
}

/// Reference-typed wrapper for a standalone terminal row.
final class TerminalNode: NSObject {
    let terminalID: TerminalID

    /// The folder of the project this row is *shown* under, carried on the node because the
    /// row's name is stated relative to it. Placement is resolved once here for the whole tree
    /// and reads git metadata off disk for every project; a row that asked again would repeat
    /// that per row, per reload.
    ///
    /// A `var` because the row it belongs to outlives the rebuild that renamed it: a terminal
    /// whose cwd moved it under another checkout keeps its row and takes the new folder.
    private(set) var displayProjectFolderPath: String

    init(terminalID: TerminalID, displayProjectFolderPath: String) {
        self.terminalID = terminalID
        self.displayProjectFolderPath = displayProjectFolderPath
    }
}

extension TerminalNode: SidebarOutlineNode {
    var sidebarKey: SidebarNodeKey { .terminal(terminalID) }
    var sidebarChildren: [NSObject] { [] }

    func adoptContent(
        of rebuilt: any SidebarOutlineNode,
        substituting: SidebarNodeSubstitution
    ) {
        guard let rebuilt = rebuilt as? TerminalNode else { return }
        displayProjectFolderPath = rebuilt.displayProjectFolderPath
    }
}

/// Groups the checkouts of one repository.
///
/// Only created when a repository has more than one checkout added, so a repository with a
/// single checkout keeps the flatter two-level layout.
final class RepoGroupNode: NSObject {
    /// The repository this heading stands for — its identity on disk, which is what makes the
    /// heading the same heading across rebuilds. The `name` below is only what it is *called*.
    let identity: String
    private(set) var name: String
    var projectNodes: [ProjectNode] = []

    init(identity: String, name: String) {
        self.identity = identity
        self.name = name
    }
}

extension RepoGroupNode: SidebarOutlineNode {
    var sidebarKey: SidebarNodeKey { .repository(identity) }
    var sidebarChildren: [NSObject] { projectNodes }

    func adoptContent(
        of rebuilt: any SidebarOutlineNode,
        substituting: SidebarNodeSubstitution
    ) {
        guard let rebuilt = rebuilt as? RepoGroupNode else { return }
        name = rebuilt.name
        projectNodes = rebuilt.projectNodes.map(substituting.callAsFunction)
    }
}

/// Gathers a project's chats and standalone terminals that stand on the same branch.
///
/// Only created when grouping is enabled and the branch has more than one session — the
/// same rule that keeps single-checkout repositories flat, applied one level down. Sessions
/// with no recorded branch stay directly under the project.
final class BranchGroupNode: NSObject {
    let branch: String
    let projectID: ProjectID
    var sessionNodes: [SessionNode] = []
    var terminalNodes: [TerminalNode] = []

    var childNodes: [NSObject] {
        sessionNodes.map { $0 as NSObject } + terminalNodes.map { $0 as NSObject }
    }

    /// The outline asks for a count once, then for every child by index. Keep that indexed path
    /// allocation-free: materializing `childNodes` for each request turns one large branch into
    /// a quadratic launch walk even though the outline ultimately retains only logical indexes.
    var outlineChildCount: Int {
        sessionNodes.count + terminalNodes.count
    }

    func outlineChild(at index: Int) -> NSObject {
        precondition(index >= 0 && index < outlineChildCount)
        if index < sessionNodes.count {
            return sessionNodes[index]
        }
        return terminalNodes[index - sessionNodes.count]
    }

    init(branch: String, projectID: ProjectID) {
        self.branch = branch
        self.projectID = projectID
    }
}

extension BranchGroupNode: SidebarOutlineNode {
    var sidebarKey: SidebarNodeKey { .branch(projectID, branch) }
    var sidebarChildren: [NSObject] { childNodes }

    func adoptContent(
        of rebuilt: any SidebarOutlineNode,
        substituting: SidebarNodeSubstitution
    ) {
        guard let rebuilt = rebuilt as? BranchGroupNode else { return }
        sessionNodes = rebuilt.sessionNodes.map(substituting.callAsFunction)
        terminalNodes = rebuilt.terminalNodes.map(substituting.callAsFunction)
    }
}

// MARK: - Tree Builder

/// Which attention layer the authoritative project hierarchy presents. This filters session
/// membership only; it never manufactures a second grouping model or changes stored ownership.
enum SidebarSessionVisibility: Equatable {
    case attention
    case snoozed
}

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
    static func rootNodes(
        from projects: [Project],
        visibility: SidebarSessionVisibility = .attention,
        at date: Date = Date()
    ) -> [NSObject] {
        let identities = projects.map { GitInfo.repositoryIdentity(for: $0.folderPath) }
        let order = AppSettings.sidebarSessionOrder
        let isReversed = AppSettings.sidebarSessionOrderIsReversed

        var checkoutCounts: [String: Int] = [:]
        for identity in identities.compactMap({ $0 }) {
            checkoutCounts[identity, default: 0] += 1
        }

        var roots: [NSObject] = []
        var groupsByIdentity: [String: RepoGroupNode] = [:]

        let terminalsByDisplayProject = terminalsByDisplayProject(from: projects)

        for (project, identity) in zip(projects, identities) {
            // Standalone terminals are not sessions and cannot be snoozed, so they stay in the
            // ordinary attention view and never leak into the dedicated Snoozed scope.
            let node = makeProjectNode(
                from: project,
                terminals: visibility == .attention
                    ? terminalsByDisplayProject[project.id] ?? []
                    : [],
                order: order,
                isReversed: isReversed,
                visibility: visibility,
                date: date
            )

            guard let identity, checkoutCounts[identity, default: 0] > 1 else {
                roots.append(node)
                continue
            }

            if let group = groupsByIdentity[identity] {
                group.projectNodes.append(node)
                continue
            }

            let group = RepoGroupNode(
                identity: identity,
                name: GitInfo.repositoryName(forIdentity: identity)
            )
            group.projectNodes.append(node)
            groupsByIdentity[identity] = group
            roots.append(group)
        }

        // Archived sessions are not shown here at all — they live in Settings, so the sidebar
        // stays a list of what is active.
        return roots
    }

    /// Rebuilds only one project's descendants for a content change that can alter their
    /// ordering but cannot add or remove a project/repository row. This keeps a session rename
    /// in Name order proportional to its project rather than every conversation in the app.
    static func projectNode(
        for projectID: ProjectID,
        from projects: [Project],
        visibility: SidebarSessionVisibility = .attention
    ) -> ProjectNode? {
        guard let project = projects.first(where: { $0.id == projectID }) else { return nil }
        let terminals = terminalsByDisplayProject(from: projects)[projectID] ?? []
        return makeProjectNode(
            from: project,
            terminals: visibility == .attention ? terminals : [],
            order: AppSettings.sidebarSessionOrder,
            isReversed: AppSettings.sidebarSessionOrderIsReversed,
            visibility: visibility
        )
    }

    private static func terminalsByDisplayProject(
        from projects: [Project]
    ) -> [ProjectID: [ProjectTerminal]] {
        var result: [ProjectID: [ProjectTerminal]] = [:]
        for homeProject in projects {
            for terminal in homeProject.terminals {
                let displayProjectID = ProjectTerminalPlacement.projectID(
                    for: terminal,
                    homeProject: homeProject,
                    projects: projects
                )
                result[displayProjectID, default: []].append(terminal)
            }
        }
        return result
    }

    private static func makeProjectNode(
        from project: Project,
        terminals: [ProjectTerminal],
        order: SidebarSessionOrder,
        isReversed: Bool,
        visibility: SidebarSessionVisibility = .attention,
        date: Date = Date()
    ) -> ProjectNode {
        let node = ProjectNode(projectID: project.id)
        // Archived sessions are gathered separately, below the projects.
        let activeSessions = orderedActiveSessions(
            project.sessions,
            order: order,
            isReversed: isReversed,
            visibility: visibility,
            date: date
        )
        node.sessionNodes = activeSessions.map { SessionNode(sessionID: $0.id) }
        node.terminalNodes = terminals.map {
            TerminalNode(terminalID: $0.id, displayProjectFolderPath: project.folderPath)
        }

        // Side chats hang off the session they were forked from, so only what remains
        // at the project's own level is grouped by branch below.
        let top = attachSideChats(sessions: activeSessions, nodes: node.sessionNodes)
        node.childNodes = childNodes(
            projectID: project.id,
            sessions: top.sessions,
            sessionNodes: top.nodes,
            terminals: terminals,
            terminalNodes: node.terminalNodes
        )
        return node
    }

    /// Filters and orders one project's visible sessions.
    ///
    /// Manual order is already encoded by the store array. Running it through comparison sort
    /// merely rediscovers every element's index at O(n log n), which made a rare full sidebar
    /// rebuild pay tens of milliseconds at several thousand sessions. Pinning only requires a
    /// stable partition, and the overwhelmingly common no-pin case can return the filtered array
    /// directly (or reverse it once).
    private static func orderedActiveSessions(
        _ sessions: [AgentSession],
        order: SidebarSessionOrder,
        isReversed: Bool,
        visibility: SidebarSessionVisibility = .attention,
        date: Date = Date()
    ) -> [AgentSession] {
        let active = sessions.filter {
            guard !$0.isArchived else { return false }
            let isSnoozed = $0.isSnoozed(at: date)
            return visibility == .snoozed ? isSnoozed : !isSnoozed
        }

        if order == .manual {
            let pinnedCount = active.reduce(into: 0) { count, session in
                if session.isPinned { count += 1 }
            }
            guard pinnedCount > 0 else {
                return isReversed ? Array(active.reversed()) : active
            }

            var pinned: [AgentSession] = []
            var unpinned: [AgentSession] = []
            pinned.reserveCapacity(pinnedCount)
            unpinned.reserveCapacity(active.count - pinnedCount)
            for session in active {
                if session.isPinned {
                    pinned.append(session)
                } else {
                    unpinned.append(session)
                }
            }
            if isReversed {
                pinned.reverse()
                unpinned.reverse()
            }
            pinned.append(contentsOf: unpinned)
            return pinned
        }

        // Sort lightweight offsets rather than repeatedly moving the comparatively large
        // session value. Name order also derives each display title once: that property reads
        // the agent-title preference, and doing so from every comparison turned one 5,000-row
        // rebuild into tens of thousands of defaults reads.
        let displayTitles = order == .name ? active.map(\.displayTitle) : []
        let orderedOffsets = active.indices.sorted { lhsOffset, rhsOffset in
            let lhs = active[lhsOffset]
            let rhs = active[rhsOffset]
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }

            switch order {
            case .manual:
                // Handled by the linear path above.
                break
            case .recentActivity:
                if lhs.lastActiveAt != rhs.lastActiveAt {
                    let isNewer = lhs.lastActiveAt > rhs.lastActiveAt
                    return isReversed ? !isNewer : isNewer
                }
            case .name:
                let comparison = displayTitles[lhsOffset]
                    .localizedCaseInsensitiveCompare(displayTitles[rhsOffset])
                if comparison != .orderedSame {
                    let isEarlier = comparison == .orderedAscending
                    return isReversed ? !isEarlier : isEarlier
                }
            }

            // This tie-break stays forward under a reversed derived order, because it stops
            // indistinguishable rows from jittering; it is not part of the selected sort.
            return lhsOffset < rhsOffset
        }
        return orderedOffsets.map { active[$0] }
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

    /// The rows that must be open for a standalone terminal's cwd-positioned row to exist.
    static func ancestors(of terminalID: TerminalID, in roots: [NSObject]) -> [NSObject] {
        func path(from node: NSObject) -> [NSObject]? {
            if let terminal = node as? TerminalNode, terminal.terminalID == terminalID { return [] }
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

    /// What the outline view shows under a node. The four node types' differing child
    /// properties are reconciled by `SidebarOutlineNode`; anything else has no children.
    static func children(of node: NSObject) -> [NSObject] {
        (node as? any SidebarOutlineNode)?.sidebarChildren ?? []
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
        sessionNodes: [SessionNode],
        terminals: [ProjectTerminal],
        terminalNodes: [TerminalNode]
    ) -> [NSObject] {
        guard AppSettings.groupsSessionsByBranch else {
            return sessionNodes.map { $0 as NSObject } + terminalNodes.map { $0 as NSObject }
        }

        var itemCounts: [String: Int] = [:]
        for session in sessions {
            if let branch = session.branch {
                itemCounts[branch, default: 0] += 1
            }
        }
        for terminal in terminals {
            if let branch = terminal.branch {
                itemCounts[branch, default: 0] += 1
            }
        }

        let hasSharedBranch = itemCounts.values.contains { $0 > 1 }
        let groupsLoneBranches = AppSettings.groupsLoneBranches && hasSharedBranch

        var children: [NSObject] = []
        var groupsByBranch: [String: BranchGroupNode] = [:]

        for (session, sessionNode) in zip(sessions, sessionNodes) {
            guard let branch = session.branch,
                  groupsLoneBranches || itemCounts[branch, default: 0] > 1 else {
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

        for (terminal, terminalNode) in zip(terminals, terminalNodes) {
            guard let branch = terminal.branch,
                  groupsLoneBranches || itemCounts[branch, default: 0] > 1 else {
                children.append(terminalNode)
                continue
            }

            if let group = groupsByBranch[branch] {
                group.terminalNodes.append(terminalNode)
                continue
            }

            let group = BranchGroupNode(branch: branch, projectID: projectID)
            group.terminalNodes.append(terminalNode)
            groupsByBranch[branch] = group
            children.append(group)
        }

        return children
    }
}
