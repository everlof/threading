import Foundation
import ThreadingExtensionKit

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
    case registeredFactGroup(ProjectID, ExtensionFactKey, ExtensionFactValue?)
    case session(SessionID)
    case terminal(TerminalID)
    /// The "Show 5 more" row closing a project's chat preview. One per project, so the project
    /// is its whole identity: the row stays the same row while what it offers changes.
    case chatDisclosure(ProjectID)

    /// The project and branch behind a branch heading, or nil for every other row. Lets a
    /// caller ask what a key *is* without a `switch` whose other four cases say nothing.
    var branchGroup: (projectID: ProjectID, branch: String)? {
        guard case .branch(let projectID, let branch) = self else { return nil }
        return (projectID, branch)
    }
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

/// The outline node types' shared surface: which row a node stands for, what hangs under it, and
/// how it takes over from the node a rebuild produced in its place.
protocol SidebarOutlineNode: NSObject {
    var sidebarKey: SidebarNodeKey { get }

    /// What the outline shows under this node, in display order.
    var sidebarChildren: [NSObject] { get }

    /// Objective-C storage used by `NSOutlineView`'s one-callback-per-logical-row expansion.
    /// Swift array bridging in every `child:ofItem:` callback was measurable at 5,000 expanded
    /// rows; nodes invalidate this retained projection only when their child collection changes.
    var sidebarOutlineChildCount: Int { get }
    func sidebarOutlineChild(at index: Int) -> NSObject

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

    /// Standalone terminals owned by this project.
    var terminalNodes: [TerminalNode] = []

    /// What the outline actually shows under the project: the selected branch/fact grouping,
    /// bare session rows where that grouping permits them, standalone terminals, and — last —
    /// the chat preview's disclosure row when the project's chats run past it.
    var childNodes: [NSObject] = [] {
        didSet { outlineChildren = nil }
    }
    private var outlineChildren: NSArray?

    init(projectID: ProjectID) {
        self.projectID = projectID
    }

    /// The row closing this project's chat preview, when its chats run past the first page.
    /// Always the last child, so asking costs one look rather than a walk.
    var chatDisclosureNode: ChatDisclosureNode? {
        childNodes.last as? ChatDisclosureNode
    }
}

extension ProjectNode: SidebarOutlineNode {
    var sidebarKey: SidebarNodeKey { .project(projectID) }
    var sidebarChildren: [NSObject] { childNodes }
    var sidebarOutlineChildCount: Int { materializedOutlineChildren.count }
    func sidebarOutlineChild(at index: Int) -> NSObject {
        materializedOutlineChildren.object(at: index) as! NSObject
    }

    private var materializedOutlineChildren: NSArray {
        if let outlineChildren { return outlineChildren }
        let projected = NSArray(array: childNodes)
        outlineChildren = projected
        return projected
    }

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
    var childNodes: [SessionNode] = [] {
        didSet { outlineChildren = nil }
    }
    private var outlineChildren: NSArray?

    init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

extension SessionNode: SidebarOutlineNode {
    var sidebarKey: SidebarNodeKey { .session(sessionID) }
    var sidebarChildren: [NSObject] { childNodes }
    var sidebarOutlineChildCount: Int { materializedOutlineChildren.count }
    func sidebarOutlineChild(at index: Int) -> NSObject {
        materializedOutlineChildren.object(at: index) as! NSObject
    }

    private var materializedOutlineChildren: NSArray {
        if let outlineChildren { return outlineChildren }
        let projected = NSArray(array: childNodes)
        outlineChildren = projected
        return projected
    }

    func adoptContent(
        of rebuilt: any SidebarOutlineNode,
        substituting: SidebarNodeSubstitution
    ) {
        guard let rebuilt = rebuilt as? SessionNode else { return }
        childNodes = rebuilt.childNodes.map(substituting.callAsFunction)
    }
}

/// The row under a project's first page of chats: "Show 5 more", then "Show remaining", then
/// "Show fewer". See `SidebarChatPreview`.
///
/// Carries its preview as content rather than reading the store when drawn, because what it says
/// depends on the order, the visibility scope and the stage — the tree builder's inputs, not a
/// record's. A rebuild that keeps the row hands the new preview to the node on screen.
final class ChatDisclosureNode: NSObject {
    let projectID: ProjectID
    private(set) var preview: SidebarChatPreview

    init(projectID: ProjectID, preview: SidebarChatPreview) {
        self.projectID = projectID
        self.preview = preview
    }
}

extension ChatDisclosureNode: SidebarOutlineNode {
    var sidebarKey: SidebarNodeKey { .chatDisclosure(projectID) }
    var sidebarChildren: [NSObject] { [] }
    var sidebarOutlineChildCount: Int { 0 }
    func sidebarOutlineChild(at index: Int) -> NSObject {
        preconditionFailure("A chat disclosure node has no outline children")
    }

    func adoptContent(
        of rebuilt: any SidebarOutlineNode,
        substituting: SidebarNodeSubstitution
    ) {
        guard let rebuilt = rebuilt as? ChatDisclosureNode else { return }
        preview = rebuilt.preview
    }
}

/// Reference-typed wrapper for a standalone terminal row.
final class TerminalNode: NSObject {
    let terminalID: TerminalID

    /// The owning project's folder, carried on the node because the row's name is stated
    /// relative to it. A `var` because the row may outlive a rebuild that moved the project.
    private(set) var projectFolderPath: String

    init(terminalID: TerminalID, projectFolderPath: String) {
        self.terminalID = terminalID
        self.projectFolderPath = projectFolderPath
    }
}

extension TerminalNode: SidebarOutlineNode {
    var sidebarKey: SidebarNodeKey { .terminal(terminalID) }
    var sidebarChildren: [NSObject] { [] }
    var sidebarOutlineChildCount: Int { 0 }
    func sidebarOutlineChild(at index: Int) -> NSObject {
        preconditionFailure("A terminal node has no outline children")
    }

    func adoptContent(
        of rebuilt: any SidebarOutlineNode,
        substituting: SidebarNodeSubstitution
    ) {
        guard let rebuilt = rebuilt as? TerminalNode else { return }
        projectFolderPath = rebuilt.projectFolderPath
    }
}

/// The root row of one repository, holding every checkout of it that has been added.
///
/// Created for every repository, at one checkout as well as at five — see
/// `SidebarTreeBuilder.rootNodes` for why the old "two or more" threshold was dropped.
final class RepoGroupNode: NSObject {
    /// The repository this row stands for — its identity on disk, which is what makes the
    /// root the same root across rebuilds. The `name` below is only what it is *called*.
    let identity: String
    fileprivate(set) var name: String

    /// The checkout that answers for the repository where a row needs a record rather than an
    /// identity: whose icon the root draws, and where its `+` starts a chat. The main worktree
    /// when available, otherwise the first available checkout in the user's own order. Nil
    /// when every checkout is unavailable, so `+` cannot target a missing path.
    ///
    /// A repository has no record of its own — only checkouts do — so this is the alternative
    /// to inventing a second place to store a repository's icon, which would then disagree with
    /// the icon of the checkout the user actually set.
    fileprivate(set) var representativeProjectID: ProjectID?

    var projectNodes: [ProjectNode] = [] {
        didSet { outlineChildren = nil }
    }
    private var outlineChildren: NSArray?

    init(identity: String, name: String) {
        self.identity = identity
        self.name = name
    }

    /// Takes the repository's main working tree as the checkout that answers for it — its name
    /// as well as its record.
    ///
    /// The name matters because a project can be renamed, and the main working tree's record
    /// *is* the repository's: a user who renames it is naming the repository, and a root that
    /// kept saying what the directory holding `.git` is called would throw that away. Only the
    /// main working tree may do this. A linked worktree is named for its branch, and a monorepo
    /// package is named for the package, so either one naming the root would be wrong.
    fileprivate func adopt(named projectName: String, as projectID: ProjectID) {
        representativeProjectID = projectID
        name = projectName
    }
}

extension RepoGroupNode: SidebarOutlineNode {
    var sidebarKey: SidebarNodeKey { .repository(identity) }
    var sidebarChildren: [NSObject] { projectNodes }
    var sidebarOutlineChildCount: Int { materializedOutlineChildren.count }
    func sidebarOutlineChild(at index: Int) -> NSObject {
        materializedOutlineChildren.object(at: index) as! NSObject
    }

    private var materializedOutlineChildren: NSArray {
        if let outlineChildren { return outlineChildren }
        let projected = NSArray(array: projectNodes)
        outlineChildren = projected
        return projected
    }

    func adoptContent(
        of rebuilt: any SidebarOutlineNode,
        substituting: SidebarNodeSubstitution
    ) {
        guard let rebuilt = rebuilt as? RepoGroupNode else { return }
        name = rebuilt.name
        representativeProjectID = rebuilt.representativeProjectID
        projectNodes = rebuilt.projectNodes.map(substituting.callAsFunction)
    }
}

/// Gathers a project's chats and standalone terminals that stand on the same branch.
///
/// Only created when grouping is enabled and the branch has more than one session — the
/// same rule that keeps single-checkout repositories flat, applied one level down. Sessions
/// with no recorded branch stay directly under the project.
final class BranchGroupNode: NSObject {
    /// Mutable because a checkout moving between branches renames the heading over the rows
    /// that were already under it. The identity of a group is the rows it gathers, not the
    /// label on it — see `SidebarOutlineUpdate.branchRenames(from:to:)`.
    var branch: String
    let projectID: ProjectID
    var sessionNodes: [SessionNode] = [] {
        didSet { outlineChildren = nil }
    }
    var terminalNodes: [TerminalNode] = [] {
        didSet { outlineChildren = nil }
    }
    var terminalsFirst = false {
        didSet { outlineChildren = nil }
    }
    private var outlineChildren: NSArray?

    var childNodes: [NSObject] {
        if terminalsFirst {
            return terminalNodes.map { $0 as NSObject } + sessionNodes.map { $0 as NSObject }
        }
        return sessionNodes.map { $0 as NSObject } + terminalNodes.map { $0 as NSObject }
    }

    init(branch: String, projectID: ProjectID) {
        self.branch = branch
        self.projectID = projectID
    }
}

extension BranchGroupNode: SidebarOutlineNode {
    var sidebarKey: SidebarNodeKey { .branch(projectID, branch) }
    var sidebarChildren: [NSObject] { childNodes }
    var sidebarOutlineChildCount: Int { materializedOutlineChildren.count }
    func sidebarOutlineChild(at index: Int) -> NSObject {
        materializedOutlineChildren.object(at: index) as! NSObject
    }

    private var materializedOutlineChildren: NSArray {
        if let outlineChildren { return outlineChildren }
        let projected = NSArray(array: childNodes)
        outlineChildren = projected
        return projected
    }

    func adoptContent(
        of rebuilt: any SidebarOutlineNode,
        substituting: SidebarNodeSubstitution
    ) {
        guard let rebuilt = rebuilt as? BranchGroupNode else { return }
        // The name last, so a heading adopted across a rename ends up saying what the
        // checkout is on now while still being the row the outline already has.
        branch = rebuilt.branch
        sessionNodes = rebuilt.sessionNodes.map(substituting.callAsFunction)
        terminalNodes = rebuilt.terminalNodes.map(substituting.callAsFunction)
        terminalsFirst = rebuilt.terminalsFirst
    }
}

/// Gathers a project's top-level sessions by one selected public fact.
///
/// Unlike a branch group, this heading has no branch mutation or grouping controls. Its identity
/// is the typed scalar bucket rather than its presentation label, so a provider may relabel a
/// value without replacing the row or losing expansion state.
final class RegisteredFactGroupNode: NSObject {
    let projectID: ProjectID
    let factKey: ExtensionFactKey
    let value: ExtensionFactValue?
    var title: String
    var sessionNodes: [SessionNode] = [] {
        didSet { outlineChildren = nil }
    }
    private var outlineChildren: NSArray?

    init(
        projectID: ProjectID,
        factKey: ExtensionFactKey,
        value: ExtensionFactValue?,
        title: String
    ) {
        self.projectID = projectID
        self.factKey = factKey
        self.value = value
        self.title = title
    }
}

extension RegisteredFactGroupNode: SidebarOutlineNode {
    var sidebarKey: SidebarNodeKey { .registeredFactGroup(projectID, factKey, value) }
    var sidebarChildren: [NSObject] { sessionNodes }
    var sidebarOutlineChildCount: Int { materializedOutlineChildren.count }
    func sidebarOutlineChild(at index: Int) -> NSObject {
        materializedOutlineChildren.object(at: index) as! NSObject
    }

    private var materializedOutlineChildren: NSArray {
        if let outlineChildren { return outlineChildren }
        let projected = NSArray(array: sessionNodes)
        outlineChildren = projected
        return projected
    }

    func adoptContent(
        of rebuilt: any SidebarOutlineNode,
        substituting: SidebarNodeSubstitution
    ) {
        guard let rebuilt = rebuilt as? RegisteredFactGroupNode else { return }
        title = rebuilt.title
        sessionNodes = rebuilt.sessionNodes.map(substituting.callAsFunction)
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

    /// Arranges projects into the tree: every checkout of a repository sits under that
    /// repository's own root row, whether the repository has one checkout added or five.
    ///
    /// This used to group only at two or more checkouts, on an "earns its level" argument. The
    /// argument was wrong in practice for two reasons. The shape of a repository changed as
    /// worktrees were added and removed, so the row a user aimed at moved and the branch a row
    /// stated appeared and disappeared with it; and the repository row is the only place
    /// `New Worktree…` belongs, so a repository without one had no way to grow a second
    /// checkout from the sidebar at all. One shape at one checkout and at five is worth the
    /// level.
    ///
    /// A folder outside any repository has no repository to sit under and stays a plain project
    /// row. The scratchpad is pinned to the top and never grouped — see `pinningScratchpad`.
    static func rootNodes(
        from projects: [Project],
        visibility: SidebarSessionVisibility = .attention,
        excludingSessionIDs: Set<SessionID> = [],
        at date: Date = Date(),
        optionValues: NativeSidebarPipelineOptionValues = NativeSidebarPipelineOptions.current,
        factSnapshot: ExtensionFactSnapshot? = nil,
        chatPreviewStages: [ProjectID: SidebarChatPreviewStage] = [:],
        revealingSessionIDs: Set<SessionID> = []
    ) -> [NSObject] {
        let classifiedProjects = NativeSidebarParity.fact(.projectManualOrder, projects)
        let visibilityScope = NativeSidebarParity.host(.visibilityScope, visibility)
        let transientExclusions = NativeSidebarParity.host(
            .transientExclusion,
            excludingSessionIDs
        )
        let evaluationDate = NativeSidebarParity.host(.clock, date)
        let registeredFactSnapshot = NativeSidebarParity.host(
            .registeredFactResolution,
            factSnapshot
        )
        let previewStages = NativeSidebarParity.host(.transientDisclosure, chatPreviewStages)
        let revealedSessions = NativeSidebarParity.host(
            .transientDisclosure,
            revealingSessionIDs
        )
        let arranged = pinningScratchpad(classifiedProjects)
        // The scratchpad answers "no repository" for grouping even though it is one, which is
        // what keeps it out of a repository heading — and, just as importantly, keeps it from
        // *causing* one: counted as a checkout, it would drag a project the user added inside it
        // under a heading that exists only because the scratchpad is there.
        let repositoryContexts: [(identity: String?, available: Bool)] = arranged.map { project in
            let isScratchpad = NativeSidebarParity.fact(
                .projectScratchpad,
                project.isTheScratchpad
            )
            if isScratchpad { return (nil, false) }
            let localRepositoryPath = NativeSidebarParity.host(
                .localRepositoryContext,
                project.folderPath
            )
            let rememberedIdentity = NativeSidebarParity.host(
                .localRepositoryContext,
                project.lastKnownRepositoryIdentity
            )
            let liveIdentity = NativeSidebarParity.host(
                .localRepositoryContext,
                GitInfo.repositoryIdentity(for: localRepositoryPath)
            )
            return (liveIdentity ?? rememberedIdentity, liveIdentity != nil)
        }
        var roots: [NSObject] = []
        var groupsByIdentity: [String: RepoGroupNode] = [:]

        for (project, context) in zip(arranged, repositoryContexts) {
            // Standalone terminals are not sessions and cannot be snoozed, so they stay in the
            // ordinary attention view and never leak into the dedicated Snoozed scope.
            let terminals = NativeSidebarParity.facts(
                [.terminalProjectMembership, .terminalManualOrder],
                project.terminals
            )
            let node = makeProjectNode(
                from: project,
                terminals: visibilityScope == .attention
                    ? terminals
                    : [],
                optionValues: optionValues,
                visibility: visibilityScope,
                excludingSessionIDs: transientExclusions,
                date: evaluationDate,
                checkoutBranch: context.identity == nil ? nil : checkoutBranch(of: project),
                factSnapshot: registeredFactSnapshot,
                chatPreviewStage: previewStages[
                    NativeSidebarParity.host(.entityIdentity, project.id)
                ] ?? .compact,
                revealingSessionIDs: revealedSessions
            )

            guard let identity = context.identity else {
                roots.append(node)
                continue
            }

            // The repository's main working tree answers for it wherever a record is needed.
            // Asked for by what it *is* rather than by position, because the checkouts are in
            // the user's arrangement and the main one is not necessarily first in it — and
            // because "first" would let a monorepo package speak for the whole repository.
            let speaksForTheRepository = isTheRepositoriesMainWorkingTree(
                NativeSidebarParity.host(.localRepositoryContext, project.folderPath)
            )

            if let group = groupsByIdentity[identity] {
                group.projectNodes.append(node)
                if group.representativeProjectID == nil && context.available {
                    group.representativeProjectID = node.projectID
                }
                if speaksForTheRepository {
                    group.adopt(
                        named: NativeSidebarParity.fact(.projectName, project.name),
                        as: node.projectID
                    )
                }
                continue
            }

            let group = RepoGroupNode(
                identity: identity,
                name: NativeSidebarParity.host(
                    .localRepositoryContext,
                    GitInfo.repositoryName(forIdentity: identity)
                )
            )
            group.projectNodes.append(node)
            // An available checkout stands in until the main working tree turns up. A root
            // containing only missing checkouts has no safe target for `+`.
            group.representativeProjectID = context.available ? node.projectID : nil
            if speaksForTheRepository {
                group.adopt(
                    named: NativeSidebarParity.fact(.projectName, project.name),
                    as: node.projectID
                )
            }
            groupsByIdentity[identity] = group
            roots.append(group)
        }

        // Archived sessions are not shown here at all — they live in Settings, so the sidebar
        // stays a list of what is active.
        return roots
    }

    /// The scratchpad first, everything else in the order the user arranged it.
    ///
    /// A partition rather than a `sorted(by:)`: Swift's sort is not stable, so a comparator
    /// that only knows "scratchpad before anything else" is free to reshuffle the checkouts
    /// underneath it — and the order of those rows is the user's own arrangement.
    static func pinningScratchpad(_ projects: [Project]) -> [Project] {
        guard projects.contains(where: {
            NativeSidebarParity.fact(.projectScratchpad, $0.isTheScratchpad)
        }) else { return projects }
        return projects.filter {
            NativeSidebarParity.fact(.projectScratchpad, $0.isTheScratchpad)
        } + projects.filter {
            !NativeSidebarParity.fact(.projectScratchpad, $0.isTheScratchpad)
        }
    }

    /// Rebuilds only one project's descendants for a content change that can alter their
    /// ordering but cannot add or remove a project/repository row. This keeps a session rename
    /// in Name order proportional to its project rather than every conversation in the app.
    static func projectNode(
        for projectID: ProjectID,
        from projects: [Project],
        visibility: SidebarSessionVisibility = .attention,
        excludingSessionIDs: Set<SessionID> = [],
        optionValues: NativeSidebarPipelineOptionValues = NativeSidebarPipelineOptions.current,
        factSnapshot: ExtensionFactSnapshot? = nil,
        chatPreviewStage: SidebarChatPreviewStage = .compact,
        revealingSessionIDs: Set<SessionID> = []
    ) -> ProjectNode? {
        let classifiedProjectID = NativeSidebarParity.host(.entityIdentity, projectID)
        let classifiedProjects = NativeSidebarParity.fact(.projectManualOrder, projects)
        let visibilityScope = NativeSidebarParity.host(.visibilityScope, visibility)
        let transientExclusions = NativeSidebarParity.host(
            .transientExclusion,
            excludingSessionIDs
        )
        let registeredFactSnapshot = NativeSidebarParity.host(
            .registeredFactResolution,
            factSnapshot
        )
        guard let project = classifiedProjects.first(where: {
            NativeSidebarParity.host(.entityIdentity, $0.id) == classifiedProjectID
        }) else { return nil }
        let terminals = NativeSidebarParity.facts(
            [.terminalProjectMembership, .terminalManualOrder],
            project.terminals
        )
        return makeProjectNode(
            from: project,
            terminals: visibilityScope == .attention ? terminals : [],
            optionValues: optionValues,
            visibility: visibilityScope,
            excludingSessionIDs: transientExclusions,
            checkoutBranch: checkoutBranch(of: project),
            factSnapshot: registeredFactSnapshot,
            chatPreviewStage: NativeSidebarParity.host(.transientDisclosure, chatPreviewStage),
            revealingSessionIDs: NativeSidebarParity.host(
                .transientDisclosure,
                revealingSessionIDs
            )
        )
    }

    /// Whether this project is the repository's own working tree, rather than a linked worktree
    /// or a directory inside one — the row that answers for the repository.
    ///
    /// The rule itself is `GitInfo.isMainWorkingTree`, because the paired phone has to reach the
    /// same verdict for a repository it can only see over the wire, and two spellings of "which
    /// checkout speaks for this repository" would be two chances to disagree.
    private static func isTheRepositoriesMainWorkingTree(_ path: String) -> Bool {
        NativeSidebarParity.host(.localRepositoryContext, GitInfo.isMainWorkingTree(path))
    }

    /// The branch a checkout row states about itself, or nil for a folder outside a repository.
    ///
    /// One small read of the worktree's `HEAD` on top of the `worktreeLocation` memo the
    /// grouping pass has already warmed for this path — the same read the row itself makes
    /// when it names itself.
    ///
    /// Internal rather than private because the sidebar's exact-insertion path has to reach the
    /// same answer: it decides whether an arriving row would earn a branch heading without
    /// rebuilding the project, and a copy of that rule missing this one clause sent every new
    /// chat through a project rebuild it did not need.
    static func checkoutBranch(of project: Project) -> String? {
        NativeSidebarParity.host(
            .localRepositoryContext,
            GitInfo.currentBranch(for: project.folderPath)
        )
    }

    private static func makeProjectNode(
        from project: Project,
        terminals: [ProjectTerminal],
        optionValues: NativeSidebarPipelineOptionValues,
        visibility: SidebarSessionVisibility = .attention,
        excludingSessionIDs: Set<SessionID> = [],
        date: Date = Date(),
        checkoutBranch: String? = nil,
        factSnapshot: ExtensionFactSnapshot? = nil,
        chatPreviewStage: SidebarChatPreviewStage = .compact,
        revealingSessionIDs: Set<SessionID> = []
    ) -> ProjectNode {
        let order = optionValues.sessionOrder
        let isReversed = optionValues.sessionOrderReversed
        let projectID = NativeSidebarParity.host(.entityIdentity, project.id)
        let projectSessions = NativeSidebarParity.facts(
            [.sessionProjectMembership, .sessionManualOrder],
            project.sessions
        )
        let node = ProjectNode(projectID: projectID)
        // Archived sessions are gathered separately, below the projects.
        let activeSessions = orderedActiveSessions(
            projectSessions,
            order: order,
            isReversed: isReversed,
            visibility: visibility,
            excludingSessionIDs: excludingSessionIDs,
            date: date,
            registeredSortKey: optionValues.sortByFact,
            factSnapshot: factSnapshot
        )
        node.sessionNodes = activeSessions.map {
            SessionNode(sessionID: NativeSidebarParity.host(.entityIdentity, $0.id))
        }
        node.terminalNodes = terminals.map {
            TerminalNode(
                terminalID: NativeSidebarParity.host(.entityIdentity, $0.id),
                projectFolderPath: NativeSidebarParity.host(
                    .localRepositoryContext,
                    project.folderPath
                )
            )
        }

        // Side chats hang off the session they were forked from, so only what remains
        // at the project's own level is grouped by branch below.
        let top = attachSideChats(sessions: activeSessions, nodes: node.sessionNodes)
        // The preview cuts before grouping, so a heading gathers only rows that are showing and
        // a hidden chat never becomes a row, a view or a constraint. Side chats travel with the
        // chat they were forked from. The snoozed scope is a list asked for on purpose, and shows
        // it whole — the phone's archived and snoozed lists do the same.
        let shown = chatPreview(
            sessions: top.sessions,
            nodes: top.nodes,
            isEnabled: optionValues.chatPreview && visibility == .attention,
            stage: chatPreviewStage,
            revealing: revealingSessionIDs
        )
        node.childNodes = childNodes(
            projectID: projectID,
            sessions: shown.sessions,
            sessionNodes: shown.nodes,
            terminals: terminals,
            terminalNodes: node.terminalNodes,
            optionValues: optionValues,
            checkoutBranch: checkoutBranch,
            factSnapshot: factSnapshot
        )
        if let preview = shown.preview {
            node.childNodes.append(ChatDisclosureNode(projectID: projectID, preview: preview))
        }
        return node
    }

    /// The top-level chats a project's preview shows, and what its disclosure row says about the
    /// rest — nil when the preview is off or the project fits its first page.
    ///
    /// A revealed chat — the selected one — raises the stage just far enough to include it, so a
    /// chat opened from a notification or search is never selected into a row that does not
    /// exist. The work is bounded by the chats being cut, and the reveal walk only runs over the
    /// ones past the stage when something asks to be revealed at all.
    private static func chatPreview(
        sessions: [AgentSession],
        nodes: [SessionNode],
        isEnabled: Bool,
        stage: SidebarChatPreviewStage,
        revealing: Set<SessionID>
    ) -> (sessions: [AgentSession], nodes: [SessionNode], preview: SidebarChatPreview?) {
        guard isEnabled,
              SidebarChatPreview.isWorthShowing(totalCount: nodes.count) else {
            return (sessions, nodes, nil)
        }

        func contains(_ node: SessionNode) -> Bool {
            revealing.contains(node.sessionID) || node.childNodes.contains(where: contains)
        }

        var effectiveStage = stage
        if !revealing.isEmpty, stage.limit < nodes.count {
            // Walked from the end, so the first match is the deepest revealed chat.
            for offset in nodes.indices.reversed() where offset >= stage.limit {
                guard contains(nodes[offset]) else { continue }
                effectiveStage = .revealing(offset: offset)
                break
            }
        }

        let visibleCount = min(nodes.count, effectiveStage.limit)
        var hiddenSessionIDs = Set<SessionID>()
        func collect(_ node: SessionNode) {
            hiddenSessionIDs.insert(node.sessionID)
            node.childNodes.forEach(collect)
        }
        nodes.dropFirst(visibleCount).forEach(collect)

        return (
            Array(sessions.prefix(visibleCount)),
            Array(nodes.prefix(visibleCount)),
            SidebarChatPreview(
                stage: effectiveStage,
                totalCount: nodes.count,
                visibleCount: visibleCount,
                hiddenSessionIDs: hiddenSessionIDs
            )
        )
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
        excludingSessionIDs: Set<SessionID> = [],
        date: Date = Date(),
        registeredSortKey: ExtensionFactKey? = nil,
        factSnapshot: ExtensionFactSnapshot? = nil
    ) -> [AgentSession] {
        let active = sessions.filter {
            let isArchived = NativeSidebarParity.fact(.sessionArchived, $0.isArchived)
            let sessionID = NativeSidebarParity.host(.entityIdentity, $0.id)
            guard !isArchived, !excludingSessionIDs.contains(sessionID) else { return false }
            let evaluationDate = NativeSidebarParity.host(.clock, date)
            let isSnoozed = NativeSidebarParity.fact(
                .sessionSnoozed,
                $0.isSnoozed(at: evaluationDate)
            )
            return visibility == .snoozed ? isSnoozed : !isSnoozed
        }

        if order == .manual || order == .type {
            let reversesSessions = order == .manual && isReversed
            let pinnedCount = active.reduce(into: 0) { count, session in
                if NativeSidebarParity.fact(.sessionPinned, session.isPinned) { count += 1 }
            }
            guard pinnedCount > 0 else {
                let staticallyOrdered = reversesSessions ? Array(active.reversed()) : active
                return dynamicallySortedSessions(
                    staticallyOrdered,
                    by: registeredSortKey,
                    isReversed: isReversed,
                    snapshot: factSnapshot
                )
            }

            var pinned: [AgentSession] = []
            var unpinned: [AgentSession] = []
            pinned.reserveCapacity(pinnedCount)
            unpinned.reserveCapacity(active.count - pinnedCount)
            for session in active {
                if NativeSidebarParity.fact(.sessionPinned, session.isPinned) {
                    pinned.append(session)
                } else {
                    unpinned.append(session)
                }
            }
            if reversesSessions {
                pinned.reverse()
                unpinned.reverse()
            }
            pinned.append(contentsOf: unpinned)
            return dynamicallySortedSessions(
                pinned,
                by: registeredSortKey,
                isReversed: isReversed,
                snapshot: factSnapshot
            )
        }

        // Sort lightweight offsets rather than repeatedly moving the comparatively large
        // session value. Name order also derives each display title once: that property reads
        // the agent-title preference, and doing so from every comparison turned one 5,000-row
        // rebuild into tens of thousands of defaults reads.
        let displayTitles = order == .name
            ? active.map { NativeSidebarParity.fact(.sessionTitle, $0.displayTitle) }
            : []
        let orderedOffsets = active.indices.sorted { lhsOffset, rhsOffset in
            let lhs = active[lhsOffset]
            let rhs = active[rhsOffset]
            let lhsIsPinned = NativeSidebarParity.fact(.sessionPinned, lhs.isPinned)
            let rhsIsPinned = NativeSidebarParity.fact(.sessionPinned, rhs.isPinned)
            if lhsIsPinned != rhsIsPinned {
                return lhsIsPinned
            }

            switch order {
            case .manual:
                // Handled by the linear path above.
                break
            case .recentActivity:
                let lhsLastUsed = NativeSidebarParity.fact(
                    .sessionLastUsed,
                    lhs.lastUsedAt
                )
                let rhsLastUsed = NativeSidebarParity.fact(
                    .sessionLastUsed,
                    rhs.lastUsedAt
                )
                if lhsLastUsed != rhsLastUsed {
                    let isNewer = lhsLastUsed > rhsLastUsed
                    return isReversed ? !isNewer : isNewer
                }
            case .name:
                let comparison = displayTitles[lhsOffset]
                    .localizedCaseInsensitiveCompare(displayTitles[rhsOffset])
                if comparison != .orderedSame {
                    let isEarlier = comparison == .orderedAscending
                    return isReversed ? !isEarlier : isEarlier
                }
            case .type:
                // Handled by the linear path above. Type orders terminal and session groups;
                // it does not reverse the rows within either group.
                break
            }

            // This tie-break stays forward under a reversed derived order, because it stops
            // indistinguishable rows from jittering; it is not part of the selected sort.
            return lhsOffset < rhsOffset
        }
        return dynamicallySortedSessions(
            orderedOffsets.map { active[$0] },
            by: registeredSortKey,
            isReversed: isReversed,
            snapshot: factSnapshot
        )
    }

    /// Applies the selected public fact ahead of Native's standing order. The latter has already
    /// been reduced to stable ranks, so it becomes the exact static tie-break promised by the
    /// registered-fact contract without re-reading titles, timestamps, defaults, or providers
    /// from inside the comparator.
    private static func dynamicallySortedSessions(
        _ staticallyOrdered: [AgentSession],
        by key: ExtensionFactKey?,
        isReversed: Bool,
        snapshot: ExtensionFactSnapshot?
    ) -> [AgentSession] {
        guard let key,
              let snapshot,
              let definition = snapshot.definition(for: key),
              NativeSidebarParity.host(
                  .registeredFactResolution,
                  ExtensionFactRegistry.isRegisteredFactDefinitionEligible(
                      definition,
                      for: .sortable
                  )
              ) else { return staticallyOrdered }

        let values = staticallyOrdered.map { session in
            snapshot.fact(
                key,
                for: .session(
                    NativeSidebarParity.host(.entityIdentity, session.id)
                        .uuidString.lowercased()
                )
            )?.fact.value
        }
        let pinned = staticallyOrdered.map {
            NativeSidebarParity.fact(.sessionPinned, $0.isPinned)
        }
        let offsets = staticallyOrdered.indices.sorted { lhsOffset, rhsOffset in
            if pinned[lhsOffset] != pinned[rhsOffset] {
                return pinned[lhsOffset]
            }
            switch (values[lhsOffset], values[rhsOffset]) {
            case (nil, nil):
                return lhsOffset < rhsOffset
            case (nil, _):
                return false
            case (_, nil):
                return true
            case let (.some(lhsValue), .some(rhsValue)):
                let comparison = compareExtensionFactValues(lhsValue, rhsValue)
                guard comparison != 0 else { return lhsOffset < rhsOffset }
                return isReversed ? comparison > 0 : comparison < 0
            }
        }
        return offsets.map { staticallyOrdered[$0] }
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

    /// The rows that must be open for a standalone terminal's project-owned row to exist.
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

    /// What the outline view shows under a node. The node types' differing child
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
            let sessionID = NativeSidebarParity.host(.entityIdentity, session.id)
            let parentID = NativeSidebarParity.fact(.sessionParent, session.forkedFrom)
            parentIDs[sessionID] = parentID
        }

        var nodesByID: [SessionID: SessionNode] = [:]
        for node in nodes {
            nodesByID[node.sessionID] = node
        }

        var topSessions: [AgentSession] = []
        var topNodes: [SessionNode] = []

        for (session, node) in zip(sessions, nodes) {
            let parentSessionID = NativeSidebarParity.host(.entityIdentity, session.id)
            guard let parentID = NativeSidebarParity.fact(.sessionParent, session.forkedFrom),
                  let parent = nodesByID[parentID],
                  !formsCycle(from: parentID, back: parentSessionID, parentIDs: parentIDs) else {
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
    /// earned the level (`loneBranchHeadings`): a heading over the shared branch
    /// beside a bare row on its own branch reads as though the bare row had none, but a
    /// project whose branches are all singletons stays flat — all-or-nothing labelling, so
    /// the extra level never appears without cause.
    ///
    /// `checkoutBranch` is the branch the *row above* already states, and the one branch that
    /// therefore earns no heading here: a checkout named `dev/feature/live-fw-logs` holding a
    /// heading of the same name is one row saying a thing and the next row repeating it, which
    /// is how this shipped and read as duplicated rows. Only that branch is suppressed. A
    /// checkout can `git switch`, and a chat records the branch it *ran* on, so the other
    /// branches under a checkout are genuinely other branches and keep their headings — they
    /// are the ones saying something the row above does not.
    private static func childNodes(
        projectID: ProjectID,
        sessions: [AgentSession],
        sessionNodes: [SessionNode],
        terminals: [ProjectTerminal],
        terminalNodes: [TerminalNode],
        optionValues: NativeSidebarPipelineOptionValues,
        checkoutBranch: String? = nil,
        factSnapshot: ExtensionFactSnapshot? = nil
    ) -> [NSObject] {
        let order = optionValues.sessionOrder
        let isReversed = optionValues.sessionOrderReversed
        let terminalsFirst = order == .type && isReversed
        if let key = optionValues.groupByFact {
            let groups = registeredFactGroups(
                projectID: projectID,
                sessions: sessions,
                sessionNodes: sessionNodes,
                key: key,
                snapshot: factSnapshot
            )
            if terminalsFirst {
                return terminalNodes.map { $0 as NSObject } + groups.map { $0 as NSObject }
            }
            return groups.map { $0 as NSObject } + terminalNodes.map { $0 as NSObject }
        }
        let usesBranchGrouping = optionValues.branchGrouping
        guard usesBranchGrouping else {
            if terminalsFirst {
                return terminalNodes.map { $0 as NSObject } + sessionNodes.map { $0 as NSObject }
            }
            return sessionNodes.map { $0 as NSObject } + terminalNodes.map { $0 as NSObject }
        }

        // The checkout's own branch is left out of the census as well as out of the headings.
        // It cannot earn a level it is not allowed to occupy, and counting it would let a
        // suppressed heading be the reason every *other* lone branch grew one.
        func isNamedByTheRowAbove(_ branch: String) -> Bool { branch == checkoutBranch }

        var itemCounts: [String: Int] = [:]
        for session in sessions {
            if let branch = NativeSidebarParity.fact(.sessionBranch, session.branch),
               !isNamedByTheRowAbove(branch) {
                itemCounts[branch, default: 0] += 1
            }
        }
        for terminal in terminals {
            if let branch = NativeSidebarParity.fact(.terminalBranch, terminal.branch),
               !isNamedByTheRowAbove(branch) {
                itemCounts[branch, default: 0] += 1
            }
        }

        let hasSharedBranch = itemCounts.values.contains { $0 > 1 }
        let groupsLoneBranches = optionValues.loneBranchHeadings && hasSharedBranch

        var children: [NSObject] = []
        var groupsByBranch: [String: BranchGroupNode] = [:]

        func append(_ session: AgentSession, node: SessionNode) {
            guard let branch = NativeSidebarParity.fact(.sessionBranch, session.branch),
                  !isNamedByTheRowAbove(branch),
                  groupsLoneBranches || itemCounts[branch, default: 0] > 1 else {
                children.append(node)
                return
            }

            if let group = groupsByBranch[branch] {
                group.sessionNodes.append(node)
                return
            }

            let group = BranchGroupNode(branch: branch, projectID: projectID)
            group.terminalsFirst = terminalsFirst
            group.sessionNodes.append(node)
            groupsByBranch[branch] = group
            children.append(group)
        }

        func append(_ terminal: ProjectTerminal, node: TerminalNode) {
            guard let branch = NativeSidebarParity.fact(.terminalBranch, terminal.branch),
                  !isNamedByTheRowAbove(branch),
                  groupsLoneBranches || itemCounts[branch, default: 0] > 1 else {
                children.append(node)
                return
            }

            if let group = groupsByBranch[branch] {
                group.terminalNodes.append(node)
                return
            }

            let group = BranchGroupNode(branch: branch, projectID: projectID)
            group.terminalsFirst = terminalsFirst
            group.terminalNodes.append(node)
            groupsByBranch[branch] = group
            children.append(group)
        }

        if terminalsFirst {
            for (terminal, node) in zip(terminals, terminalNodes) { append(terminal, node: node) }
            for (session, node) in zip(sessions, sessionNodes) { append(session, node: node) }
        } else {
            for (session, node) in zip(sessions, sessionNodes) { append(session, node: node) }
            for (terminal, node) in zip(terminals, terminalNodes) { append(terminal, node: node) }
        }

        return children
    }

    /// Buckets only top-level sessions. Side chats are already attached to their source row and
    /// therefore move with it; standalone terminals keep Native's host-owned placement because
    /// format-1 registered choices deliberately admit only facts resolvable from session source.
    private static func registeredFactGroups(
        projectID: ProjectID,
        sessions: [AgentSession],
        sessionNodes: [SessionNode],
        key: ExtensionFactKey,
        snapshot: ExtensionFactSnapshot?
    ) -> [RegisteredFactGroupNode] {
        enum Bucket: Hashable {
            case value(ExtensionFactValue)
            case unknown
        }

        let isAvailable = snapshot?.definition(for: key).map { definition in
            NativeSidebarParity.host(
                .registeredFactResolution,
                ExtensionFactRegistry.isRegisteredFactDefinitionEligible(
                    definition,
                    for: .groupable
                )
            )
        } ?? false
        var members: [Bucket: [(node: SessionNode, label: String?)]] = [:]
        for (session, node) in zip(sessions, sessionNodes) {
            let resolved = isAvailable ? snapshot?.fact(
                key,
                for: .session(
                    NativeSidebarParity.host(.entityIdentity, session.id)
                        .uuidString.lowercased()
                )
            ) : nil
            let bucket = resolved.map { Bucket.value($0.fact.value) } ?? .unknown
            members[bucket, default: []].append((node, resolved?.fact.label))
        }

        let ordered = members.keys.sorted { lhsBucket, rhsBucket in
            switch (lhsBucket, rhsBucket) {
            case (.unknown, .unknown): false
            case (.unknown, _): false
            case (_, .unknown): true
            case let (.value(lhsValue), .value(rhsValue)):
                compareExtensionFactValues(lhsValue, rhsValue) < 0
            }
        }
        return ordered.compactMap { bucket in
            guard let bucketMembers = members[bucket], !bucketMembers.isEmpty else { return nil }
            let value: ExtensionFactValue?
            let title: String
            switch bucket {
            case .unknown:
                value = nil
                title = L10n.string("Unknown")
            case .value(let scalar):
                value = scalar
                title = bucketMembers.lazy.compactMap(\.label).first
                    ?? extensionFactValueText(scalar)
            }
            let group = RegisteredFactGroupNode(
                projectID: projectID,
                factKey: key,
                value: value,
                title: title
            )
            group.sessionNodes = bucketMembers.map(\.node)
            return group
        }
    }
}
