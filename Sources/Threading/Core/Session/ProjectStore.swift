import Foundation

enum ProjectIconMutationError: Error {
    case projectNotFound
    case unusableImage
    case storageFailed
    case persistenceRefused
}

/// What happened to an agent-supplied conversation title.
///
/// A boolean used to collapse every refusal into "that was probably a noisy title". That was
/// especially unsafe for `set_session_name`: its `.chosen` mutation was acknowledged before the
/// coalesced database write, so recovery mode or a failed store could roll it back after the agent
/// had already told the user the rename succeeded.
enum AgentTitleMutationResult: Equatable {
    case accepted
    case cleared
    case sessionNotFound
    case refusedAsNoise
    case protectedByStrongerSource
    case persistenceRefused
}

/// The durable outcome of a project-graph mutation whose caller has work to do afterwards.
///
/// UI-only setters can repaint from the store after `save()` rolls a refused write back. Remote
/// callers and process-owning callers cannot: acknowledging the request or killing the old
/// process is an irreversible second step, so they need to know whether SQLite accepted the
/// first one. `unchanged` is success — the requested durable state already stands.
enum ProjectMutationResult: Equatable {
    case applied
    case unchanged
    case targetNotFound
    case unsupportedValue
    case persistenceRefused

    var succeeded: Bool {
        self == .applied || self == .unchanged
    }
}

/// Why durable project mutations are currently refused.
///
/// Storage exhaustion is separate because it has a verified in-process recovery path. Every
/// other failed write remains fail-closed, and a failed load stays distinct because the visible
/// in-memory graph is not authoritative.
enum ProjectStorePersistenceBlock: Equatable, Sendable {
    case recoveryMode
    case failedLoad
    case storageExhausted
    case failedWrite
}

/// Owns the project list and its persistence.
///
/// This is the model layer only: it knows nothing about running processes. Live agent surfaces
/// are managed by `AgentRuntime`; standalone terminal surfaces are managed by
/// `ProjectTerminalRuntime`, each keyed by the durable identifiers stored here.
@MainActor
final class ProjectStore {

    private enum StateWritePolicy {
        case allowed
        case recoveryMode
        case failedLoad
        case storageExhausted
        case failedWrite

        var allowsWrites: Bool {
            if case .allowed = self { return true }
            return false
        }
    }

    // MARK: - Singleton

    /// AppDelegate's live environment stays lazy until after `RecoveryMode.enter`, because this
    /// initializer must know the launch's write policy before `load()` can migrate anything.
    static let shared = ProjectStore()

    // MARK: - Properties

    private(set) var projects: [Project] = []

    /// False for the rest of a launch after a corrupt or unsupported state file was found.
    /// Consumers must not interpret the resulting empty project list as authoritative.
    private(set) var didLoadStateSuccessfully = true

    /// A failed load is never followed by writes in the same launch. Even when quarantine
    /// succeeded, the empty in-memory graph is not authoritative replacement state.
    ///
    /// A recovery launch seeds a different refusal for a different reason: the store is read so
    /// the sidebar can show that the projects survived, and nothing about a launch that started
    /// no session is worth writing back over them. The reason is seeded at construction rather
    /// than set afterwards because `load()` runs inside `init` and takes a write of its own — the
    /// legacy theme-assignment migration — so a policy set on the finished object would arrive
    /// one save too late.
    private var stateWritePolicy: StateWritePolicy

    private let stateManager: StateManager
    private var isRestoringState = false

    /// The last graph SQLite accepted. Mutations are presented from `projects`, but a refused
    /// write restores this snapshot before callers announce the change. Array/struct copy-on-
    /// write keeps the steady-state cost small and gives every mutation one rollback boundary.
    private var persistedProjects: [Project] = []
    private var persistedSelectedSessionID: SessionID?

    /// Identity indexes for the model's hot lookup paths. Project/session identifiers do not
    /// change; the indexes are rebuilt only after a structural edit, while title, activity and
    /// settings mutations keep their locations.
    private var projectIndicesByID: [ProjectID: Int] = [:]
    private var sessionLocationsByID: [
        SessionID: (projectIndex: Int, sessionIndex: Int)
    ] = [:]
    private var terminalLocationsByID: [
        TerminalID: (projectIndex: Int, terminalIndex: Int)
    ] = [:]

    /// Pending high-frequency row writes. Keeping their identities means a title or turn edge
    /// can coalesce without making the eventual write reconcile the complete project graph.
    private var saveTimer: Timer?
    private var pendingSessionSaveIDs: Set<SessionID> = []
    private var pendingProjectSaveIDs: Set<ProjectID> = []

    /// Whether a multi-system transaction may safely begin a side effect that it will later
    /// need this store to record. This is a preflight, not a promise that the next disk write
    /// cannot fail; callers must still inspect the mutation result.
    var acceptsDurableMutations: Bool { stateWritePolicy.allowsWrites }

    var persistenceBlockReason: ProjectStorePersistenceBlock? {
        switch stateWritePolicy {
        case .allowed: return nil
        case .recoveryMode: return .recoveryMode
        case .failedLoad: return .failedLoad
        case .storageExhausted: return .storageExhausted
        case .failedWrite: return .failedWrite
        }
    }

    /// The session currently shown in the terminal pane.
    var selectedSessionID: SessionID? {
        didSet {
            guard !isRestoringState, selectedSessionID != oldValue else { return }
            // Its own gate, because this write does not go through `save()`: selection is
            // navigation state, not a structural edit, and rewriting every project and session
            // here made sidebar clicks progressively slower as the store grew. A recovery launch
            // still lists and selects — the sidebar is the evidence somebody came for — and must
            // not record where they browsed as the selection the next normal launch restores.
            guard stateWritePolicy.allowsWrites else {
                restorePersistedSelection()
                return
            }
            if stateManager.saveSelectedSessionID(selectedSessionID) {
                persistedSelectedSessionID = selectedSessionID
            } else {
                recordFailedWritePolicy()
                restorePersistedSelection()
                notifyChanged()
            }
        }
    }

    // MARK: - Initialization

    init(
        stateManager: StateManager = .shared,
        refusesWrites: Bool = RecoveryMode.isActive
    ) {
        self.stateManager = stateManager
        self.stateWritePolicy = refusesWrites ? .recoveryMode : .allowed
        load()
        rebuildLookupIndexes()
    }

    // MARK: - Project Management

    /// Adds a project for a folder, naming it after the enclosing git repository when there
    /// is one. Returns the existing project if the folder was already added.
    @discardableResult
    func addProject(folderURL: URL) -> Project? {
        let normalizedPath = folderURL.standardizedFileURL.resolvingSymlinksInPath().path

        if let existing = projects.first(where: { $0.folderPath == normalizedPath }) {
            return existing
        }

        var project = Project(
            name: GitInfo.suggestedProjectName(for: folderURL),
            folderURL: folderURL
        )
        project.folderPath = normalizedPath

        guard flushPendingRecordSaves() else {
            notifyChanged()
            return nil
        }
        projects.append(project)
        rebuildLookupIndexes()
        guard saveProjectAddition(project, at: projects.count - 1) else {
            notifyChanged()
            return nil
        }
        notifyChanged()

        return project
    }

    // MARK: - Scratchpad

    /// The scratchpad, or nil when this user has never started one — which is also what makes
    /// the folder lazy: no row, no directory.
    var scratchpadProject: Project? {
        projects.first(where: \.isTheScratchpad)
    }

    /// Find-or-create, and re-point when the folder moved.
    ///
    /// Three cases, in the order they have to be checked:
    ///
    /// 1. **A scratchpad already exists.** It keeps its identity — and therefore its chats —
    ///    across a move, so a changed path updates the row rather than making a second one.
    /// 2. **The folder was already added as an ordinary project.** Adopting it beats adding a
    ///    duplicate row for the same path, which is the same call `addProject` makes.
    /// 3. **Neither.** Add it, flagged.
    @discardableResult
    func ensureScratchpadProject(at folderURL: URL) -> Project? {
        let normalizedPath = folderURL.standardizedFileURL.resolvingSymlinksInPath().path

        if let index = projects.firstIndex(where: \.isTheScratchpad) {
            guard projects[index].folderPath != normalizedPath else { return projects[index] }
            projects[index].folderPath = normalizedPath
            return commitScratchpadChange(at: index, isAddition: false)
        }

        if let index = projects.firstIndex(where: { $0.folderPath == normalizedPath }) {
            projects[index].isScratchpad = true
            return commitScratchpadChange(at: index, isAddition: false)
        }

        var project = Project(name: L10n.string("Scratchpad"), folderURL: folderURL)
        project.folderPath = normalizedPath
        project.isScratchpad = true
        projects.append(project)
        return commitScratchpadChange(at: projects.count - 1, isAddition: true)
    }

    /// Saves an edit to the scratchpad row and hands it back, or nil when the store refused the
    /// write — the same contract `addProject` has, so a caller cannot mistake a refused save for
    /// a successful one and go on to select a row that was not persisted.
    private func commitScratchpadChange(at index: Int, isAddition: Bool) -> Project? {
        rebuildLookupIndexes()
        let saved = isAddition
            ? saveProjectAddition(projects[index], at: index)
            : saveProjectRecord(at: index)
        guard saved else {
            notifyChanged()
            return nil
        }
        notifyChanged()
        return projects[index]
    }

    @discardableResult
    func removeProject(id: ProjectID) -> ProjectMutationResult {
        guard let projectIndex = index(ofProject: id) else { return .targetNotFound }
        let removedProject = projects[projectIndex]
        guard flushPendingRecordSaves() else {
            notifyChanged()
            return .persistenceRefused
        }

        projects.remove(at: projectIndex)
        if let selectedSessionID,
           removedProject.sessions.contains(where: { $0.id == selectedSessionID }) {
            setSelectedSessionWithoutPersistence(nil)
        }
        rebuildLookupIndexes()
        guard saveProjectRemoval(id, at: projectIndex) else {
            notifyChanged()
            return .persistenceRefused
        }

        // Destructive auxiliary cleanup follows the authoritative commit. Doing it first can
        // restore a project whose icon, handoff, audit and scheduled work were already erased
        // when SQLite refuses the deletion.
        AgentWorkTraceStore.shared.remove(projectID: id)
        if let icon = removedProject.icon {
            ProjectIconStore.remove(fileName: icon.fileName)
        }
        let removedSessionIDs = Set(removedProject.sessions.map(\.id))
        let removedTerminalIDs = Set(removedProject.terminals.map(\.id))
        // Checkpoint refs are collected here rather than before the commit, with the same
        // reasoning as the cleanup above. Losing the repository is not destructive: discard
        // keeps a checkpoint's metadata when its root no longer resolves, and the orphaned-ref
        // reconciliation pass collects it later. Each auxiliary owner receives one bounded
        // project-sized mutation rather than one whole-store pass per session.
        GitTurnBaselineStore.shared.remove(sessionIDs: removedSessionIDs)
        ConversationHandoffStore.removeInBackground(for: removedSessionIDs)
        ExecutionAuditStore.shared.removeInBackground(sessionIDs: removedSessionIDs)
        DraftStore.shared.clear(for: id)
        // Session starts waiting on this project would otherwise fire into a folder the app no
        // longer knows, or be re-armed forever against a project id nothing can resolve.
        ScheduledMessageStore.shared.forget(
            sessionIDs: removedSessionIDs,
            projectID: id
        )
        notifyChanged(sidebarImpact: .projectRemoved(
            projectID: id,
            sessionIDs: removedSessionIDs,
            terminalIDs: removedTerminalIDs
        ))
        return .applied
    }

    @discardableResult
    func renameProject(id: ProjectID, to name: String) -> ProjectMutationResult {
        guard let index = index(ofProject: id) else { return .targetNotFound }
        guard projects[index].name != name else { return .unchanged }
        projects[index].name = name
        guard saveProjectRecord(at: index) else {
            notifyChanged(sidebarImpact: .projectRow(id))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .projectRow(id))
        return .applied
    }

    func setProject(id: ProjectID, expanded: Bool) {
        guard let index = index(ofProject: id),
              projects[index].isExpanded != expanded else { return }
        projects[index].isExpanded = expanded
        guard stateWritePolicy.allowsWrites else {
            restorePersistedSnapshot()
            notifyChanged()
            return
        }
        let persistenceSpan = PerformanceRecorder.shared.begin(
            "sidebar.disclosure.persist",
            category: "sidebar",
            metadata: ["expanded": String(expanded)]
        )
        let saved = stateManager.saveProject(projects[index], position: index)
        persistenceSpan.end(metadata: ["saved": String(saved)])
        if saved {
            recordPersistedProject(at: index)
        } else {
            recordFailedWritePolicy()
            restorePersistedSnapshot()
            notifyChanged()
        }
    }

    /// Records a project's sidebar icon, or clears it. The icon's image file is owned by
    /// `ProjectIconStore`; this only records which file and where it came from.
    @discardableResult
    func setIcon(_ icon: ProjectIcon?, for projectID: ProjectID) -> Bool {
        guard let index = index(ofProject: projectID) else { return false }
        guard projects[index].icon != icon else { return true }

        // Candidate icon writes use fresh names. Retire the standing file only after the
        // replacement record commits; removing it earlier would turn rollback into a record
        // that points at bytes which no longer exist.
        let old = projects[index].icon
        projects[index].icon = icon
        guard saveProjectRecord(at: index) else {
            notifyChanged(sidebarImpact: .projectRow(projectID))
            return false
        }
        if let old, old.fileName != icon?.fileName {
            ProjectIconStore.remove(fileName: old.fileName)
        }
        notifyChanged(sidebarImpact: .projectRow(projectID))
        return true
    }

    /// Commits icon bytes and their project record as one candidate transaction.
    ///
    /// The candidate has a fresh file name, so a refused database write can remove it without
    /// reconstructing bytes it overwrote. Only after the record commits does `setIcon` remove
    /// the previous file.
    func setIcon(
        imageData: Data,
        source: ProjectIconSource,
        for projectID: ProjectID
    ) -> Result<ProjectIcon, ProjectIconMutationError> {
        guard project(withID: projectID) != nil else { return .failure(.projectNotFound) }

        let fileName: String
        do {
            fileName = try ProjectIconStore.store(imageData: imageData, for: projectID)
        } catch ProjectIconStoreError.unusableImage {
            return .failure(.unusableImage)
        } catch {
            return .failure(.storageFailed)
        }

        let icon = ProjectIcon(source: source, fileName: fileName)
        guard setIcon(icon, for: projectID) else {
            ProjectIconStore.remove(fileName: fileName)
            return .failure(.persistenceRefused)
        }
        return .success(icon)
    }

    // MARK: - Session Management

    /// Creates a new session inside a project and returns it.
    @discardableResult
    func addSession(
        to projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle = .standard,
        model: String? = nil,
        reasoningEffort: String? = nil,
        fastMode: Bool? = nil,
        usesNativeUI: Bool = false,
        permissionMode: AgentPermissionMode? = nil,
        title: String? = nil,
        handoff: ConversationHandoff? = nil,
        managedWorkspace: ManagedWorkspace? = nil,
        id: SessionID = SessionID()
    ) -> AgentSession? {
        let account = kind.supportsAccounts
            ? AgentAccountDiscovery.account(for: kind, handle: accountHandle)
            : nil
        let validEffort = AgentModels.supports(
            reasoningEffort: reasoningEffort,
            kind: kind,
            model: model,
            account: account
        )

        guard validEffort,
              let index = index(ofProject: projectID),
              sessionLocationsByID[id] == nil,
              let configuration = AgentSessionConfiguration(
                kind: kind,
                reasoningEffort: reasoningEffort,
                accountHandle: accountHandle,
                permissionMode: permissionMode
              ),
              handoff == nil || handoff?.isValid(destinationID: id, destinationKind: kind) == true
        else { return nil }

        // No title means unnamed, not named after the agent: the display falls back to a
        // generic label until the first prompt supplies a name (`applyPromptTitle`). The
        // agent and account are the row's icon slot's job, not the name's.
        var session = AgentSession(
            configuration: configuration,
            title: title ?? "",
            accountHandle: accountHandle,
            model: model,
            usesNativeUI: usesNativeUI,
            handoff: handoff,
            id: id
        )
        session.managedWorkspace = managedWorkspace
        session.fastMode = fastMode
        session.branch = managedWorkspace?.targetBranch
            ?? GitInfo.currentBranch(for: projects[index].folderPath)
        session.permissionMode = permissionMode

        // Preserve any coalesced title/turn observations before changing row positions. They are
        // exact row writes too, so this does not reintroduce the whole-graph creation pause.
        guard flushPendingRecordSaves() else {
            notifyChanged()
            return nil
        }

        projects[index].sessions.append(session)
        let position = projects[index].sessions.count - 1
        sessionLocationsByID[session.id] = (index, position)
        guard saveSessionAddition(
            session,
            to: projectID,
            position: position
        ) else {
            notifyChanged(sidebarImpact: .projectStructure(projectID))
            return nil
        }
        notifyChanged(sidebarImpact: .sessionAdded(
            projectID: projectID,
            sessionID: session.id
        ))

        return session
    }

    /// Creates a **side chat**: a session that starts from a copy of another's context, so a
    /// question can be asked without joining the conversation it asks about.
    ///
    /// It lands in the parent's own project and inherits its agent, account, model and
    /// surface — none of those are choices here. A fork resumes the parent's transcript,
    /// which lives under the parent's account and is found through the parent's folder, so
    /// changing either would simply fail to find the conversation.
    ///
    /// Refused when the parent is not resumable: there is no conversation yet, and a
    /// fork of nothing is just an ordinary new session.
    @discardableResult
    func addSideChat(of parentID: SessionID, title: String? = nil) -> AgentSession? {
        guard let location = locate(sessionID: parentID) else { return nil }

        let parent = projects[location.projectIndex].sessions[location.sessionIndex]
        guard let configuration = parent.forkedConfiguration,
              parent.resumeState.isResumable else { return nil }

        var session = AgentSession(
            configuration: configuration,
            title: title ?? AgentDefaults.sideChatTitle,
            accountHandle: parent.accountHandle,
            model: parent.model,
            usesNativeUI: parent.usesNativeUI
        )
        session.branch = parent.branch
        // A side chat asks a question *about* the parent's work, so it inherits the parent's
        // posture along with its agent, account and surface — including a deliberate nil,
        // which keeps it following the app default exactly as the parent does.
        session.permissionMode = parent.permissionMode

        guard flushPendingRecordSaves() else {
            notifyChanged()
            return nil
        }
        projects[location.projectIndex].sessions.append(session)
        let position = projects[location.projectIndex].sessions.count - 1
        sessionLocationsByID[session.id] = (location.projectIndex, position)
        let projectID = projects[location.projectIndex].id
        guard saveSessionAddition(session, to: projectID, position: position) else {
            notifyChanged(sidebarImpact: .projectStructure(projectID))
            return nil
        }
        notifyChanged(sidebarImpact: .sessionAdded(
            projectID: projectID,
            sessionID: session.id
        ))

        return session
    }

    /// Durably records or cancels a validated move request before its calling turn may continue.
    /// This is intentionally an immediate exact-row write: a coalescing timer would let quitting
    /// the app forget the fence while the provider has already been told the request succeeded.
    @discardableResult
    func setPendingCheckoutMove(
        _ move: PendingCheckoutMove?,
        forSessionID sessionID: SessionID
    ) -> Bool {
        guard let location = locate(sessionID: sessionID),
              flushPendingRecordSaves(),
              prepareForImmediateSave("pending checkout move") else { return false }

        let previous = projects[location.projectIndex].sessions[location.sessionIndex]
        guard previous.pendingCheckoutMove != move else { return true }
        projects[location.projectIndex].sessions[location.sessionIndex].pendingCheckoutMove = move
        let project = projects[location.projectIndex]
        let session = project.sessions[location.sessionIndex]
        guard stateManager.saveSession(
            session,
            in: project.id,
            position: location.sessionIndex
        ) else {
            recordFailedWritePolicy()
            projects[location.projectIndex].sessions[location.sessionIndex] = previous
            notifyChanged(sidebarImpact: .sessionRow(sessionID))
            return false
        }
        recordPersistedSession(
            projectIndex: location.projectIndex,
            sessionIndex: location.sessionIndex
        )
        notifyChanged(sidebarImpact: .sessionRow(sessionID))
        return true
    }

    /// Atomically changes which checkout project owns a bounded set of related conversations.
    ///
    /// Validation belongs to `SessionCheckoutCoordinator`; this method consumes its canonical
    /// identities and performs only the graph transaction. The destination project is born in
    /// the same SQLite transaction as the moved rows, so a failed move cannot leave an empty
    /// checkout behind.
    func moveSessionsToCheckout(
        _ sessionIDs: [SessionID],
        checkoutPath: String,
        repositoryIdentity: String,
        worktreeIdentity: String,
        branch: String
    ) -> SessionCheckoutStoreMoveResult {
        var seenIDs: Set<SessionID> = []
        let uniqueIDs = sessionIDs.filter { seenIDs.insert($0).inserted }
        let movingIDSet = Set(uniqueIDs)
        guard !uniqueIDs.isEmpty,
              uniqueIDs.allSatisfy({ sessionLocationsByID[$0] != nil }) else {
            return .sessionNotFound
        }
        guard flushPendingRecordSaves(),
              prepareForImmediateSave("session checkout move") else {
            return .persistenceRefused
        }

        let destinationIndex = projects.firstIndex { candidate in
            let canonicalPath = URL(fileURLWithPath: candidate.folderPath, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path
            guard let location = GitInfo.worktreeLocation(for: canonicalPath) else {
                return false
            }
            return location.repositoryIdentity == repositoryIdentity
                && location.worktreeIdentity == worktreeIdentity
        }
        let alreadyThere = destinationIndex.map { index in
            uniqueIDs.allSatisfy { sessionLocationsByID[$0]?.projectIndex == index }
        } ?? false
        if alreadyThere, let destinationIndex {
            for id in uniqueIDs {
                guard let location = locate(sessionID: id) else { continue }
                projects[location.projectIndex].sessions[location.sessionIndex].branch = branch
                projects[location.projectIndex].sessions[location.sessionIndex]
                    .pendingCheckoutMove = nil
            }
            guard stateManager.moveSessions(affectedProjects: [
                (projects[destinationIndex], destinationIndex)
            ]) else {
                recordFailedWritePolicy()
                restorePersistedSnapshot()
                return .persistenceRefused
            }
            recordPersistedSnapshot()
            let destination = SessionCheckoutStoreDestination(
                projectID: projects[destinationIndex].id,
                checkoutPath: projects[destinationIndex].folderPath,
                branch: branch,
                createdProject: false
            )
            notifyChanged(sidebarImpact: .structure)
            return .unchanged(destination)
        }

        let previousProjects = projects
        let createdProject = destinationIndex == nil
        let targetIndex: Int
        if let destinationIndex {
            targetIndex = destinationIndex
        } else {
            var project = Project(
                name: GitInfo.suggestedProjectName(for: URL(fileURLWithPath: checkoutPath)),
                folderURL: URL(fileURLWithPath: checkoutPath, isDirectory: true)
            )
            project.folderPath = checkoutPath
            projects.append(project)
            targetIndex = projects.index(before: projects.endIndex)
        }

        var moving: [AgentSession] = []
        var sourceProjectIDs: Set<ProjectID> = []
        for id in uniqueIDs {
            guard let location = locate(sessionID: id) else { continue }
            sourceProjectIDs.insert(projects[location.projectIndex].id)
            moving.append(projects[location.projectIndex].sessions[location.sessionIndex])
        }
        for projectIndex in projects.indices {
            projects[projectIndex].sessions.removeAll { movingIDSet.contains($0.id) }
        }
        for index in moving.indices {
            moving[index].branch = branch
            moving[index].pendingCheckoutMove = nil
        }
        projects[targetIndex].sessions.append(contentsOf: moving)
        rebuildLookupIndexes()

        let affectedProjectIDs = sourceProjectIDs.union([projects[targetIndex].id])
        let affected = projects.enumerated().compactMap { index, project in
            affectedProjectIDs.contains(project.id) ? (project, index) : nil
        }
        guard stateManager.moveSessions(affectedProjects: affected) else {
            recordFailedWritePolicy()
            projects = previousProjects
            rebuildLookupIndexes()
            restorePersistedSnapshot()
            notifyChanged(sidebarImpact: .structure)
            return .persistenceRefused
        }

        let sourceBySession = Dictionary(uniqueKeysWithValues: uniqueIDs.compactMap { id in
            previousProjects.first(where: { $0.sessions.contains(where: { $0.id == id }) })
                .map { (id, $0.id) }
        })
        recordPersistedSnapshot()
        for id in uniqueIDs {
            if let source = sourceBySession[id], source != projects[targetIndex].id {
                AgentWorkTraceStore.shared.move(
                    sessionID: id,
                    from: source,
                    to: projects[targetIndex].id
                )
            }
        }
        let destination = SessionCheckoutStoreDestination(
            projectID: projects[targetIndex].id,
            checkoutPath: projects[targetIndex].folderPath,
            branch: branch,
            createdProject: createdProject
        )
        notifyChanged(sidebarImpact: .structure)
        return .moved(destination)
    }

    /// Adopts conversations found on disk, so they can be resumed like any other session.
    ///
    /// Each session is created already launched and carrying its identifier: it exists because
    /// a conversation exists, so selecting it must resume that conversation rather than start
    /// a new one. Adopting the same conversation twice is refused, since both entries would
    /// resume the same transcript — whether the repeat is of something already tracked or of
    /// another conversation in the same batch.
    ///
    /// Plural, and one save for the batch: both callers adopt in bulk — onboarding's import
    /// page and the import sheet's multiple selection — and a write plus a notification per
    /// conversation is what made a large import stutter, since each notification reloads the
    /// sidebar.
    @discardableResult
    func importSessions(
        _ found: [ImportableSession],
        into projectID: ProjectID
    ) -> [AgentSession] {
        guard let index = index(ofProject: projectID), !found.isEmpty else { return [] }

        let branch = GitInfo.currentBranch(for: projects[index].folderPath)
        var known = Set(projects[index].sessions.compactMap { $0.resumeState.transcriptID })
        var adopted: [AgentSession] = []

        for conversation in found {
            guard known.insert(conversation.agentSessionID).inserted else { continue }

            var session = AgentSession(
                kind: conversation.kind,
                title: conversation.title,
                accountHandle: conversation.accountHandle
            )
            session.resumeState = .resumable(conversation.agentSessionID)
            session.hasLaunched = true
            session.lastActiveAt = conversation.lastActiveAt
            session.branch = branch
            adopted.append(session)
        }

        guard !adopted.isEmpty else { return [] }
        guard flushPendingRecordSaves() else {
            notifyChanged()
            return []
        }
        let firstPosition = projects[index].sessions.count
        projects[index].sessions.append(contentsOf: adopted)
        rebuildLookupIndexes()
        let writes = adopted.enumerated().map { offset, session in
            ProjectDatabase.SessionWrite(
                session: session,
                projectID: projectID,
                position: firstPosition + offset
            )
        }
        guard saveSessionAdditions(writes) else {
            notifyChanged(sidebarImpact: .projectStructure(projectID))
            return []
        }
        notifyChanged(sidebarImpact: .projectStructure(projectID))

        return adopted
    }

    /// Changes Threading's filing state only.
    ///
    /// User-facing archive routes go through `ProviderArchiveSync`, which calls this primitive
    /// only for runtimes without a reversible provider archive. Keeping the primitive local is
    /// intentional: a capability-less runtime must never turn Archive into its destructive
    /// Delete command, and tests/import migrations sometimes need to construct local state.
    @discardableResult
    func setArchived(
        _ archived: Bool,
        for sessionID: SessionID,
        at date: Date = Date()
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        let projectID = projects[location.projectIndex].id
        guard projects[location.projectIndex].sessions[location.sessionIndex].isArchived
            != archived else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex].isArchived = archived
        projects[location.projectIndex].sessions[location.sessionIndex].archivedAt = archived
            ? date
            : nil
        // Archiving ends a snooze rather than preserving it: the row leaves the list, so a
        // "Snoozed"/"Woke" overlay it carries back on restore would describe a wait nobody is
        // still having. Archive semantics themselves are unchanged.
        if archived { projects[location.projectIndex].sessions[location.sessionIndex].clearAttentionOverlay() }
        guard saveSessionRecords(at: [location], description: "archive") else {
            notifyChanged()
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .sessionStructure(
            projectID: projectID,
            sessionID: sessionID
        ))
        return .applied
    }

    /// Commits values that have been observed or applied on both sides of provider archive sync.
    /// One changed-row transaction and notification for a launch reconciliation, however many
    /// retained sessions it initializes. Standing neighbours are neither encoded nor written.
    @discardableResult
    func synchronizeArchiveStates(
        _ states: [SessionID: Bool],
        at date: Date = Date()
    ) -> ProjectMutationResult {
        var changedLocations: [(projectIndex: Int, sessionIndex: Int)] = []
        var changedProjectIDs: Set<ProjectID> = []
        for (sessionID, archived) in states {
            guard let location = locate(sessionID: sessionID) else { continue }
            guard projects[location.projectIndex].sessions[location.sessionIndex]
                .synchronizeArchiveState(archived, at: date) else { continue }
            changedLocations.append(location)
            changedProjectIDs.insert(projects[location.projectIndex].id)
        }

        guard !changedLocations.isEmpty else { return .unchanged }
        guard saveSessionRecords(at: changedLocations, description: "archive reconciliation")
        else {
            notifyChanged()
            return .persistenceRefused
        }
        if changedProjectIDs.count == 1, let projectID = changedProjectIDs.first {
            notifyChanged(sidebarImpact: .projectStructure(projectID))
        } else {
            notifyChanged()
        }
        return .applied
    }

    @discardableResult
    func setPinned(_ pinned: Bool, for sessionID: SessionID) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        let projectID = projects[location.projectIndex].id
        guard projects[location.projectIndex].sessions[location.sessionIndex].isPinned != pinned
        else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex].isPinned = pinned
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: .sessionStructure(
                projectID: projectID,
                sessionID: sessionID
            ))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .sessionStructure(
            projectID: projectID,
            sessionID: sessionID
        ))
        return .applied
    }

    /// Applies the visibility overlay without touching process or provider state.
    func setSnoozed(
        until deadline: Date,
        at date: Date,
        hadTurnInFlight: Bool,
        for sessionID: SessionID
    ) {
        guard let session = session(withID: sessionID),
              let projectID = project(forSessionID: sessionID)?.id,
              !session.isArchived,
              deadline > date else {
            return
        }
        update(sessionID: sessionID) {
            $0.snoozedAt = date
            $0.snoozedUntil = deadline
            $0.hadTurnInFlightWhenSnoozed = hadTurnInFlight
            $0.wake = nil
        }
        // The row moves between the attention and Snoozed scopes.
        notifyChanged(sidebarImpact: .sessionStructure(
            projectID: projectID,
            sessionID: sessionID
        ))
    }

    func clearSnooze(for sessionID: SessionID) {
        guard let session = session(withID: sessionID),
              let projectID = project(forSessionID: sessionID)?.id,
              session.snoozedAt != nil || session.snoozedUntil != nil else { return }
        update(sessionID: sessionID) {
            $0.snoozedAt = nil
            $0.snoozedUntil = nil
            $0.hadTurnInFlightWhenSnoozed = false
        }
        // The row moves from Snoozed back into the attention scope.
        notifyChanged(sidebarImpact: .sessionStructure(
            projectID: projectID,
            sessionID: sessionID
        ))
    }

    func wakeSnoozedSession(
        _ sessionID: SessionID,
        reason: SessionWakeReason,
        at date: Date
    ) {
        guard session(withID: sessionID)?.snoozedAt != nil,
              let projectID = project(forSessionID: sessionID)?.id else { return }
        update(sessionID: sessionID) {
            $0.snoozedAt = nil
            $0.snoozedUntil = nil
            $0.hadTurnInFlightWhenSnoozed = false
            $0.wake = SessionWake(reason: reason, wokeAt: date)
        }
        // An early or deadline wake moves the row between sidebar scopes.
        notifyChanged(sidebarImpact: .sessionStructure(
            projectID: projectID,
            sessionID: sessionID
        ))
    }

    func acknowledgeWake(for sessionID: SessionID) {
        guard session(withID: sessionID)?.wake != nil else { return }
        update(sessionID: sessionID) { $0.wake = nil }
        notifyChanged(sidebarImpact: .sessionRow(sessionID))
    }

    /// Switches which surface renders a session: Threading's own conversation view, or the
    /// agent's terminal. The conversation itself is untouched — both surfaces resume it by
    /// the same id. Stopping whatever is running belongs to the caller, since this store
    /// knows nothing about live processes.
    @discardableResult
    func setUsesNativeUI(
        _ usesNative: Bool,
        for sessionID: SessionID
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        let session = projects[location.projectIndex].sessions[location.sessionIndex]
        guard !usesNative || session.kind.supportsNativeUI else { return .unsupportedValue }
        guard session.usesNativeUI != usesNative else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex].usesNativeUI = usesNative
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: .sessionRow(sessionID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .sessionRow(sessionID))
        return .applied
    }

    /// Re-points a resumable conversation at another routed account after its transcript copy
    /// has been installed there. `SessionMigration` owns that file transaction; this is its
    /// durable commitment point.
    @discardableResult
    func setAccountHandle(
        _ accountHandle: AccountHandle,
        for sessionID: SessionID
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        let session = projects[location.projectIndex].sessions[location.sessionIndex]
        guard session.kind.supportsAccounts else { return .unsupportedValue }
        guard session.accountHandle != accountHandle else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex].accountHandle = accountHandle
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: .sessionRow(sessionID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .sessionRow(sessionID))
        return .applied
    }

    /// Records this conversation's own answer about Claude's Remote Control bridge. Nil clears
    /// it, so the session follows `AppSettings.claudeRemoteControl` — and Claude's own `/config`
    /// beyond that — again.
    ///
    /// Applied on the session's next launch, where the settings file is written. Nothing here
    /// disconnects a bridge that is already open; that is `/remote-control` inside the session,
    /// or a relaunch.
    @discardableResult
    func setRemoteControl(
        _ remoteControl: Bool?,
        for sessionID: SessionID
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        guard projects[location.projectIndex].sessions[location.sessionIndex]
            .kind.supports(.remoteControl)
        else { return .unsupportedValue }
        guard projects[location.projectIndex].sessions[location.sessionIndex].remoteControl
            != remoteControl else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex]
            .setClaudeRemoteControl(remoteControl)
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: .sessionRow(sessionID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .sessionRow(sessionID))
        return .applied
    }

    /// Records how much this conversation may do before it has to ask. Nil clears it, so the
    /// session follows `AppSettings.defaultPermissionMode` — and the CLI's own configuration
    /// beyond that — again.
    ///
    /// Applied on the session's next launch, where the flags are built. Nothing here changes the
    /// mode of a session that is already running: Claude's own Shift+Tab does that, and the CLI
    /// does not report the result back.
    @discardableResult
    func setPermissionMode(
        _ mode: AgentPermissionMode?,
        for sessionID: SessionID
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        guard projects[location.projectIndex].sessions[location.sessionIndex]
            .kind.supportsPermissionModes else { return .unsupportedValue }
        guard projects[location.projectIndex].sessions[location.sessionIndex].permissionMode != mode
        else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex].permissionMode = mode
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: .sessionRow(sessionID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .sessionRow(sessionID))
        return .applied
    }

    /// Records which theme a session's terminal draws with. Nil clears the assignment, so the
    /// session inherits its project's theme — and the app default beyond that — again.
    @discardableResult
    func setThemeID(
        _ themeID: TerminalThemeID?,
        forSessionID sessionID: SessionID
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        guard projects[location.projectIndex].sessions[location.sessionIndex].themeID != themeID
        else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex].themeID = themeID
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: .sessionRow(sessionID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .sessionRow(sessionID))
        return .applied
    }

    /// The same for a project, which every session inside it follows unless it chooses its own.
    @discardableResult
    func setThemeID(
        _ themeID: TerminalThemeID?,
        forProjectID projectID: ProjectID
    ) -> ProjectMutationResult {
        guard let index = index(ofProject: projectID) else { return .targetNotFound }
        guard projects[index].themeID != themeID else { return .unchanged }
        projects[index].themeID = themeID
        guard saveProjectRecord(at: index) else {
            notifyChanged(sidebarImpact: .projectStructure(projectID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .projectStructure(projectID))
        return .applied
    }

    // MARK: - Standalone Terminal Management

    /// Creates a durable terminal record. Its live PTY is owned separately by
    /// `ProjectTerminalRuntime` and begins when the row is presented.
    @discardableResult
    func addTerminal(
        to projectID: ProjectID,
        id: TerminalID = TerminalID(),
        currentDirectory: String? = nil
    ) -> ProjectTerminal? {
        guard let projectIndex = index(ofProject: projectID) else { return nil }

        let terminal = ProjectTerminal(
            currentDirectory: currentDirectory ?? projects[projectIndex].folderPath,
            id: id
        )
        projects[projectIndex].terminals.append(terminal)
        rebuildLookupIndexes()
        guard saveProjectRecord(at: projectIndex) else {
            notifyChanged(sidebarImpact: .projectStructure(projectID))
            return nil
        }
        notifyChanged(sidebarImpact: .projectStructure(projectID))
        return terminal
    }

    @discardableResult
    func removeTerminal(id terminalID: TerminalID) -> ProjectMutationResult {
        guard let location = locate(terminalID: terminalID) else { return .targetNotFound }
        let projectID = projects[location.projectIndex].id
        projects[location.projectIndex].terminals.remove(at: location.terminalIndex)
        rebuildLookupIndexes()
        guard saveProjectRecord(at: location.projectIndex) else {
            notifyChanged(sidebarImpact: .projectStructure(projectID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .projectStructure(projectID))
        return .applied
    }

    @discardableResult
    func renameTerminal(id terminalID: TerminalID, to title: String?) -> ProjectMutationResult {
        guard let location = locate(terminalID: terminalID) else { return .targetNotFound }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard projects[location.projectIndex].terminals[location.terminalIndex].customTitle != stored
        else { return .unchanged }
        projects[location.projectIndex].terminals[location.terminalIndex].customTitle = stored
        guard saveProjectRecord(at: location.projectIndex) else {
            notifyChanged(sidebarImpact: .terminalRow(terminalID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .terminalRow(terminalID))
        return .applied
    }

    /// Records a shell-reported title without displacing an explicit user rename.
    ///
    /// Nil retires the title. A program that names its own window — `vim`, `ssh`, `tmux` — has
    /// no counterpart that unnames it when it exits, so the terminal's owner tells us when the
    /// program that set one is gone (`TerminalSession.refreshForegroundProcess()`). Retiring it
    /// drops the row back to its derived name instead of leaving it stuck on a file some
    /// long-closed editor was showing.
    /// Returns whether anything moved, so a caller that must repaint for a *different* reason
    /// can tell whether this call has already done it.
    @discardableResult
    func updateTerminalTitle(_ title: String?, for terminalID: TerminalID) -> Bool {
        guard let location = locate(terminalID: terminalID) else { return false }
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stored = cleaned.isEmpty ? TerminalNamingDefaults.fallback : cleaned
        guard projects[location.projectIndex].terminals[location.terminalIndex].title != stored
        else { return false }

        projects[location.projectIndex].terminals[location.terminalIndex].title = stored
        scheduleProjectSave(projects[location.projectIndex].id)
        notifyChanged(sidebarImpact: .terminalRow(terminalID))
        return true
    }

    /// Records the shell's live location and branch whenever OSC 7 or process fallback reports
    /// a new working directory. The terminal stays owned by the project where it was created;
    /// changing directories changes runtime context, not sidebar ownership.
    func updateTerminalLocation(_ directory: String, for terminalID: TerminalID) {
        guard let location = locate(terminalID: terminalID) else { return }
        let normalized = URL(fileURLWithPath: directory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let branch = GitInfo.currentBranch(for: normalized)
        let terminal = projects[location.projectIndex].terminals[location.terminalIndex]
        guard terminal.currentDirectory != normalized || terminal.branch != branch else { return }

        projects[location.projectIndex].terminals[location.terminalIndex].currentDirectory = normalized
        projects[location.projectIndex].terminals[location.terminalIndex].branch = branch
        _ = saveProjectRecord(at: location.projectIndex)
        notifyChanged(sidebarImpact: .terminalRow(terminalID))
    }

    /// Records a terminal-only override. Nil returns to its owning project, then the app theme.
    @discardableResult
    func setThemeID(
        _ themeID: TerminalThemeID?,
        forTerminalID terminalID: TerminalID
    ) -> ProjectMutationResult {
        guard let location = locate(terminalID: terminalID) else { return .targetNotFound }
        guard projects[location.projectIndex].terminals[location.terminalIndex].themeID != themeID
        else { return .unchanged }
        projects[location.projectIndex].terminals[location.terminalIndex].themeID = themeID
        guard saveProjectRecord(at: location.projectIndex) else {
            notifyChanged(sidebarImpact: .terminalRow(terminalID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .terminalRow(terminalID))
        return .applied
    }

    /// Silences one conversation's notifications, or lets it speak. Nil returns it to
    /// following its project — the same three scopes as the theme above, and the reason both
    /// setters take an optional. Withdrawing anything already on screen belongs to the caller:
    /// this store knows nothing about notifications.
    @discardableResult
    func setNotificationsMuted(
        _ muted: Bool?,
        forSessionID sessionID: SessionID
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        guard projects[location.projectIndex].sessions[location.sessionIndex].notificationsMuted
            != muted else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex].notificationsMuted = muted
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: .sessionRow(sessionID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .sessionRow(sessionID))
        return .applied
    }

    /// The same for a whole checkout.
    @discardableResult
    func setNotificationsMuted(
        _ muted: Bool?,
        forProjectID projectID: ProjectID
    ) -> ProjectMutationResult {
        guard let index = index(ofProject: projectID) else { return .targetNotFound }
        guard projects[index].notificationsMuted != muted else { return .unchanged }
        projects[index].notificationsMuted = muted
        guard saveProjectRecord(at: index) else {
            notifyChanged(sidebarImpact: .projectStructure(projectID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .projectStructure(projectID))
        return .applied
    }

    /// Records what one conversation does when its account's usage limit refuses it. Nil returns
    /// it to following its project, and the Settings choice beyond that — the same three scopes
    /// as the theme and the mute above, and optional for the same reason.
    ///
    /// Arming the recovery is all this stores. Acting on a refusal that is *already* standing is
    /// `LimitRecoveryCoordinator`'s, because it needs a live process to type into.
    @discardableResult
    func setLimitRecoveryPolicy(
        _ policy: LimitRecoveryPolicy?,
        forSessionID sessionID: SessionID
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        guard projects[location.projectIndex].sessions[location.sessionIndex].limitRecoveryPolicy
            != policy else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex].limitRecoveryPolicy = policy
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: .sessionRow(sessionID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .sessionRow(sessionID))
        return .applied
    }

    /// The same for a whole checkout, which its chats follow unless they answered for themselves.
    @discardableResult
    func setLimitRecoveryPolicy(
        _ policy: LimitRecoveryPolicy?,
        forProjectID projectID: ProjectID
    ) -> ProjectMutationResult {
        guard let index = index(ofProject: projectID) else { return .targetNotFound }
        guard projects[index].limitRecoveryPolicy != policy else { return .unchanged }
        projects[index].limitRecoveryPolicy = policy
        guard saveProjectRecord(at: index) else {
            notifyChanged(sidebarImpact: .projectStructure(projectID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .projectStructure(projectID))
        return .applied
    }

    /// Records when one conversation stops being spent. Nil returns it to following its
    /// checkout, and the standing quiet hours beyond that — the same three scopes as the mute
    /// and the limit recovery above, and optional for the same reason.
    ///
    /// **A changed rule clears the state in the same write.** The complete rule is the curfew
    /// instance's identity: a new one owes its wrap-up again, announces its hold again and
    /// starts its interrupt budget at zero. This matters even when two reset conditions share
    /// an expected date, because their account, window and arming moment are different fences.
    /// Clearing the rule does the same, because the receipts describe a fence that no longer
    /// stands. Both happen here rather than in the engine so that the two facts reach SQLite as
    /// one write and a crash between them cannot leave somebody else's receipts behind.
    ///
    /// Arming the fence is all this stores. Acting on it — the wrap-up, the hold, the
    /// interrupt — is `SessionCurfewCenter`'s, because it needs a live session to act on.
    @discardableResult
    func setCurfewRule(
        _ rule: CurfewRule?,
        forSessionID sessionID: SessionID
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        let standing = projects[location.projectIndex].sessions[location.sessionIndex].curfewRule
        guard standing != rule else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex].curfewRule = rule
        // The rule itself is the instance identity. This used to compare only deadlines, but a
        // reset-conditioned rule has no deadline until its provider event arrives; re-arming it
        // must not inherit the previous condition's hold or interrupt receipts.
        projects[location.projectIndex].sessions[location.sessionIndex].curfewState = nil
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: .sessionRow(sessionID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .sessionRow(sessionID))
        return .applied
    }

    /// The same for a whole checkout, which can exempt its chats and cannot end them.
    ///
    /// Deadline and reset-conditioned rules are refused rather than stored: each names one
    /// session's finite fence, and one written here would keep ending chats created weeks later
    /// for a condition nobody chose. The scope that names a one-shot end is the conversation;
    /// the scope that names a standing window is Settings.
    @discardableResult
    func setCurfewRule(
        _ rule: CurfewRule?,
        forProjectID projectID: ProjectID
    ) -> ProjectMutationResult {
        guard let index = index(ofProject: projectID) else { return .targetNotFound }
        switch rule {
        case .until, .untilUsageReset:
            return .unsupportedValue
        case .exempt, nil:
            break
        }
        guard projects[index].curfewRule != rule else { return .unchanged }
        projects[index].curfewRule = rule
        guard saveProjectRecord(at: index) else {
            notifyChanged(sidebarImpact: .projectStructure(projectID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .projectStructure(projectID))
        return .applied
    }

    /// Writes what one session's curfew has already done — and nothing else.
    ///
    /// Separate from the rule above because they have different authors: the rule is the user's
    /// answer, and this is the engine's record of what followed from it. Handed over whole, the
    /// way `setSoundOverrides` is, so a caller reads the current state, records the one receipt
    /// it means and passes the result back.
    @discardableResult
    func updateCurfewState(
        _ state: SessionCurfewState?,
        forSessionID sessionID: SessionID
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        guard projects[location.projectIndex].sessions[location.sessionIndex].curfewState
            != state else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex].curfewState = state
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: .sessionRow(sessionID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .sessionRow(sessionID))
        return .applied
    }

    /// Records which sounds one conversation overrides. Nil clears the record's whole say, so it
    /// follows its project — and the app beyond that — again.
    ///
    /// The map is handed over **whole** rather than one key at a time, and it is the record's
    /// own `[String: String]`: a key written by a later build, naming an event this one has
    /// never heard of, has to survive a read and a write here. Callers read the current map,
    /// change the level they mean, and pass the result back — see `SoundOverrides.setting`.
    @discardableResult
    func setSoundOverrides(
        _ overrides: [String: String]?,
        forSessionID sessionID: SessionID
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        guard projects[location.projectIndex].sessions[location.sessionIndex].soundOverrides
            != overrides else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex].soundOverrides = overrides
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: .sessionRow(sessionID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .sessionRow(sessionID))
        return .applied
    }

    /// The same for a whole checkout, which its chats and standalone terminals follow unless
    /// they answered for themselves.
    @discardableResult
    func setSoundOverrides(
        _ overrides: [String: String]?,
        forProjectID projectID: ProjectID
    ) -> ProjectMutationResult {
        guard let index = index(ofProject: projectID) else { return .targetNotFound }
        guard projects[index].soundOverrides != overrides else { return .unchanged }
        projects[index].soundOverrides = overrides
        guard saveProjectRecord(at: index) else {
            notifyChanged(sidebarImpact: .projectStructure(projectID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .projectStructure(projectID))
        return .applied
    }

    /// The same for one standalone terminal. Nil returns it to the project that persists it,
    /// and then to the app.
    @discardableResult
    func setSoundOverrides(
        _ overrides: [String: String]?,
        forTerminalID terminalID: TerminalID
    ) -> ProjectMutationResult {
        guard let location = locate(terminalID: terminalID) else { return .targetNotFound }
        guard projects[location.projectIndex].terminals[location.terminalIndex].soundOverrides
            != overrides else { return .unchanged }
        projects[location.projectIndex].terminals[location.terminalIndex].soundOverrides = overrides
        guard saveProjectRecord(at: location.projectIndex) else {
            notifyChanged(sidebarImpact: .terminalRow(terminalID))
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: .terminalRow(terminalID))
        return .applied
    }

    /// Every archived session, newest archive action first, paired with its project.
    ///
    /// `lastActiveAt` is only the migration fallback for records written before archive
    /// chronology existed. Runtime launch/exit activity must not reorder a filed conversation.
    func archivedSessions() -> [(project: Project, session: AgentSession)] {
        projects
            .flatMap { project in project.sessions.map { (project, $0) } }
            .filter { $0.1.isArchived }
            .sorted {
                let lhsDate = $0.1.archivedAt ?? $0.1.lastActiveAt
                let rhsDate = $1.1.archivedAt ?? $1.1.lastActiveAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return $0.1.id.uuidString < $1.1.id.uuidString
            }
    }

    @discardableResult
    func removeSession(id sessionID: SessionID) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        // Flush standing rows before positions change; an exact write made afterwards must not
        // use the shifted in-memory position and then have the delete transaction shift it again.
        guard flushPendingRecordSaves() else {
            notifyChanged()
            return .persistenceRefused
        }
        let projectID = projects[location.projectIndex].id
        let sessionPosition = location.sessionIndex
        let indexSpan = PerformanceRecorder.shared.begin(
            "sidebar.session-remove.indexes",
            category: "sidebar",
            metadata: [
                "projects": String(projects.count),
                "project_sessions": String(projects[location.projectIndex].sessions.count)
            ]
        )
        projects[location.projectIndex].sessions.remove(at: location.sessionIndex)
        sessionLocationsByID.removeValue(forKey: sessionID)
        let shiftedSessionCount = projects[location.projectIndex].sessions.count - sessionPosition
        if shiftedSessionCount > 0 {
            for sessionIndex in sessionPosition..<projects[location.projectIndex].sessions.count {
                let shiftedID = projects[location.projectIndex].sessions[sessionIndex].id
                sessionLocationsByID[shiftedID] = (location.projectIndex, sessionIndex)
            }
        }
        indexSpan.end(metadata: ["shifted_sessions": String(shiftedSessionCount)])

        if selectedSessionID == sessionID {
            // Selection and graph are one transaction. The observer's optimized scalar write
            // cannot persist the session deletion and was the reason a selected deleted session
            // returned after relaunch.
            setSelectedSessionWithoutPersistence(nil)
        }
        guard saveSessionRemoval(
            sessionID,
            from: projectID,
            at: sessionPosition
        ) else {
            notifyChanged(sidebarImpact: .projectStructure(projectID))
            return .persistenceRefused
        }

        // Archive/Restore never enters this method. Permanent removal collects only refs in
        // Threading's private namespace, and follows the authoritative commit so a refused
        // deletion cannot erase the history of a session that is still there.
        GitTurnBaselineStore.shared.remove(sessionID: sessionID)
        AgentWorkTraceStore.shared.remove(sessionID: sessionID, projectID: projectID)
        ConversationHandoffStore.remove(for: sessionID)
        ExecutionAuditStore.shared.remove(sessionID: sessionID)
        // Here rather than in the sidebar's delete gesture: this is the one door every deletion
        // route passes through, and Settings ▸ Archived removes sessions without going near the
        // sidebar at all. A scheduled send left behind would keep naming a session that is gone.
        ScheduledMessageStore.shared.forget(sessionID: sessionID)
        notifyChanged(sidebarImpact: .sessionRemoved(
            projectID: projectID,
            sessionID: sessionID
        ))
        return .applied
    }

    /// Applies an explicit name to a session. Pass nil or blank to fall back to the
    /// terminal's own title again.
    @discardableResult
    func renameSession(id sessionID: SessionID, to title: String?) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard projects[location.projectIndex].sessions[location.sessionIndex].customTitle != stored
        else { return .unchanged }
        projects[location.projectIndex].sessions[location.sessionIndex].customTitle = stored
        let sidebarImpact: ProjectsDidChange.SidebarImpact = .sessionTitle(
            sessionID,
            reorders: NativeSidebarPipelineOptions.sessionOrder == .name
        )
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: sidebarImpact)
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: sidebarImpact)
        return .applied
    }

    /// Follows a scheduled brief that was edited before its reserved session ever launched: the
    /// row's creation title tracks the brief exactly while nothing stronger has named it.
    ///
    /// The creation title rather than `customTitle`, deliberately — a rename here is automatic,
    /// and recording it as the user's own choice would let it outrank the agent titles that
    /// arrive once the session finally runs. A user's rename (`customTitle`) or an agent's name
    /// (`agentTitle`) therefore keeps its authority, and this refuses to touch either.
    @discardableResult
    func applyReservedPromptTitle(
        _ prompt: String,
        forSessionID sessionID: SessionID
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        let session = projects[location.projectIndex].sessions[location.sessionIndex]
        guard session.customTitle == nil,
              session.agentTitle == nil,
              let title = SessionNaming.promptTitle(from: prompt),
              title != session.title
        else { return .unchanged }

        projects[location.projectIndex].sessions[location.sessionIndex].title = title
        let sidebarImpact: ProjectsDidChange.SidebarImpact = .sessionTitle(
            sessionID,
            reorders: NativeSidebarPipelineOptions.sessionOrder == .name
        )
        guard saveSessionRecord(at: location) else {
            notifyChanged(sidebarImpact: sidebarImpact)
            return .persistenceRefused
        }
        notifyChanged(sidebarImpact: sidebarImpact)
        return .applied
    }

    /// Records the agent's own name for a conversation: a transient transport report, canonical
    /// provider metadata, or `set_session_name`, which passes `.chosen`.
    ///
    /// A title that is really the product, account or project name is ignored rather than
    /// stored: Claude's TUI titles itself "Claude Code" until it has an AI title, and Codex
    /// titles itself after the working directory. Neither names the conversation, and neither
    /// is worth displacing a real title that arrived earlier.
    ///
    /// The replacement order is reported < provider < chosen. In particular, a Codex `/rename`
    /// read from its session index must survive the TUI re-asserting an older OSC caption, while
    /// a name deliberately selected through Threading must survive both automatic sources. The
    /// user's direct row rename still outranks all three in `displayTitle`.
    ///
    /// Agents update this frequently, so the write is coalesced rather than hitting disk on
    /// every change.
    ///
    /// Automatic transports ignore the result, because a terminal that reports "Claude Code"
    /// every second is not asking a question. `set_session_name` is: `.chosen` changes therefore
    /// bypass coalescing and return `.accepted` only after SQLite commits. Each refusal stays
    /// distinct so the tool cannot turn a storage failure into advice to choose different words.
    @discardableResult
    func updateAgentTitle(
        _ title: String,
        for sessionID: SessionID,
        source: AgentTitleSource = .reported
    ) -> AgentTitleMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .sessionNotFound }

        let project = projects[location.projectIndex]
        let session = project.sessions[location.sessionIndex]

        let cleaned = Self.strippingDecoration(from: title)
        guard session.agentTitle != cleaned else {
            // The words already read right, but their authority may have moved: a canonical
            // provider name must stop a stale OSC caption replacing it, and asking for those
            // same words through Threading must still pin them.
            if source.canReplace(session.agentTitleSource),
               source != session.agentTitleSource,
                cleaned != nil {
                guard stateWritePolicy.allowsWrites else { return .persistenceRefused }
                projects[location.projectIndex].sessions[location.sessionIndex]
                    .agentTitleSource = source
                if source == .chosen {
                    guard saveSessionRecord(at: location) else { return .persistenceRefused }
                } else {
                    scheduleSessionSave(sessionID)
                }
            }
            return cleaned == nil ? .cleared : .accepted
        }

        guard source.canReplace(session.agentTitleSource) else {
            return .protectedByStrongerSource
        }

        if let cleaned {
            let account = AgentAccountDiscovery.account(
                for: session.kind,
                handle: session.accountHandle
            )
            guard !SessionNaming.isNoiseTitle(
                cleaned,
                kind: session.kind,
                accountDisplayName: account?.displayName,
                projectName: project.name,
                folderBasename: project.folderURL.lastPathComponent
            ) else { return .refusedAsNoise }
        }

        guard stateWritePolicy.allowsWrites else { return .persistenceRefused }

        projects[location.projectIndex].sessions[location.sessionIndex].agentTitle = cleaned
        // A cleared title has no provenance left to defend.
        projects[location.projectIndex].sessions[location.sessionIndex].agentTitleSource =
            cleaned == nil ? nil : source
        if source == .chosen {
            guard saveSessionRecord(at: location) else { return .persistenceRefused }
        } else {
            scheduleSessionSave(sessionID)
        }
        let titleCanReorderSidebar = NativeSidebarPipelineOptions.sessionOrder == .name
            && AppSettings.usesAgentTitleInSidebar
        notifyChanged(
            sidebarImpact: .sessionTitle(sessionID, reorders: titleCanReorderSidebar)
        )
        return cleaned == nil ? .cleared : .accepted
    }

    /// Names a session after its first prompt, once.
    ///
    /// Applies only while the title still says nothing — empty, or a leftover of the old
    /// agent-name scheme — so a name derived from a prompt never replaces one the user chose
    /// or an earlier prompt already supplied.
    func applyPromptTitle(_ prompt: String, forSessionID sessionID: SessionID) {
        guard let location = locate(sessionID: sessionID) else { return }

        let session = projects[location.projectIndex].sessions[location.sessionIndex]
        let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        )

        guard SessionNaming.isPlaceholderTitle(
            session.title,
            kind: session.kind,
            accountDisplayName: account?.displayName
        ), let title = SessionNaming.promptTitle(from: prompt), title != session.title
        else { return }

        projects[location.projectIndex].sessions[location.sessionIndex].title = title
        _ = saveSessionRecord(at: location)
        notifyChanged(
            sidebarImpact: .sessionTitle(
                sessionID,
                reorders: NativeSidebarPipelineOptions.sessionOrder == .name
            )
        )
    }

    /// Removes the decorative glyph agents prefix their terminal title with.
    ///
    /// Claude Code reports titles such as `✻ testings`; that marker exists to identify the
    /// agent in a plain terminal tab, but the sidebar already shows an agent icon, so it
    /// would just be a third symbol before the name. A title made only of symbols is left
    /// alone rather than reduced to nothing.
    private static func strippingDecoration(from title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let decoration = CharacterSet.symbols
            .union(.punctuationCharacters)
            .union(.whitespaces)

        let stripped = trimmed.drop { character in
            character.unicodeScalars.allSatisfy(decoration.contains)
        }

        let result = String(stripped).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? trimmed : result
    }

    /// Re-reads the checkout's branch for a session that just stopped working.
    ///
    /// Called at that moment because it is when an agent is most likely to have switched
    /// branches. It is also the only mover of the record with Settings > General's
    /// "Follow the checkout's branch" off — dormant sessions then keep the branch they
    /// last ran on. With it on (the default), `CheckoutBranchFollower` additionally keeps
    /// dormant records tracking the checkout through `refreshBranches(forCheckoutAt:)`.
    /// Saves and notifies only on an actual change, since a change can regroup the sidebar.
    func refreshBranch(forSessionID sessionID: SessionID) {
        guard let location = locate(sessionID: sessionID) else { return }

        let folderPath = projects[location.projectIndex].folderPath
        GitInfo.invalidateCache(for: folderPath)
        let branch = GitInfo.currentBranch(for: folderPath)
        guard projects[location.projectIndex].sessions[location.sessionIndex].branch != branch
        else { return }

        projects[location.projectIndex].sessions[location.sessionIndex].branch = branch
        _ = saveSessionRecord(at: location)
        notifyChanged(sidebarImpact: .sessionStructure(
            projectID: projects[location.projectIndex].id,
            sessionID: sessionID
        ))
    }

    /// Re-reads a checkout's branch and applies it to every session standing in that
    /// checkout — `CheckoutBranchFollower`'s write path, and the meaning of Settings >
    /// General's "Follow the checkout's branch".
    ///
    /// `refreshBranch(forSessionID:)` records what one session just ran on; this keeps the
    /// *others* honest when the checkout moves under them — switched by a different session,
    /// the shell drawer, or a terminal outside Threading entirely. Sessions match by
    /// `worktreeIdentity`, so projects added at different folders of one checkout move
    /// together while another checkout of the same repository does not.
    ///
    /// A detached reading is dropped rather than applied: a rebase detaches `HEAD` for
    /// seconds at a time, and clearing every record for that flicker would regroup the
    /// sidebar twice per rebase. A genuine detachment still lands per session through
    /// `refreshBranch` when that session next stops working.
    func refreshBranches(forCheckoutAt folderPath: String) {
        GitInfo.invalidateCache(for: folderPath)
        guard let identity = GitInfo.worktreeIdentity(for: folderPath),
              let branch = GitInfo.currentBranch(for: folderPath) else { return }

        var changedSessionLocations: [(projectIndex: Int, sessionIndex: Int)] = []
        var changedProjectIndexes: Set<Int> = []
        for projectIndex in projects.indices
        where GitInfo.worktreeIdentity(for: projects[projectIndex].folderPath) == identity {
            for sessionIndex in projects[projectIndex].sessions.indices
            where projects[projectIndex].sessions[sessionIndex].branch != branch {
                projects[projectIndex].sessions[sessionIndex].branch = branch
                changedSessionLocations.append((projectIndex, sessionIndex))
            }
        }

        for projectIndex in projects.indices {
            for terminalIndex in projects[projectIndex].terminals.indices
            where GitInfo.worktreeIdentity(
                for: projects[projectIndex].terminals[terminalIndex].currentDirectory
            ) == identity
                && projects[projectIndex].terminals[terminalIndex].branch != branch
            {
                projects[projectIndex].terminals[terminalIndex].branch = branch
                changedProjectIndexes.insert(projectIndex)
            }
        }

        guard !changedSessionLocations.isEmpty || !changedProjectIndexes.isEmpty else { return }
        if !changedSessionLocations.isEmpty,
           !saveSessionRecords(
               at: changedSessionLocations,
               description: "checkout branch sessions"
           ) {
            notifyChanged()
            return
        }
        for projectIndex in changedProjectIndexes.sorted() {
            guard saveProjectRecord(at: projectIndex) else {
                notifyChanged()
                return
            }
        }
        notifyChanged()
    }

    /// Applies a mutation to a stored session and persists the result.
    @discardableResult
    func update(
        sessionID: SessionID,
        _ mutate: (inout AgentSession) -> Void
    ) -> ProjectMutationResult {
        guard let location = locate(sessionID: sessionID) else { return .targetNotFound }
        mutate(&projects[location.projectIndex].sessions[location.sessionIndex])
        guard saveSessionRecord(at: location) else { return .persistenceRefused }
        return .applied
    }

    /// Records that a turn began in this conversation, which is what "recently used" means.
    ///
    /// `lastActiveAt` cannot answer that question: the runtime stamps it on launch and on exit,
    /// so a background relaunch marks every session it brings back as active today and the launch
    /// restore window would keep feeding itself its own last launch.
    ///
    /// Coalesced on purpose. Losing the last fraction of a second of this costs nothing, and the
    /// quit flushes what is pending, while a whole-graph write on every turn boundary of every
    /// running session would be the one avoidable cost here. Nothing visible changes either, so
    /// no observer is told: rows read activity from the tracker, never from this field.
    func noteTurnStarted(sessionID: SessionID) {
        guard let location = locate(sessionID: sessionID),
              stateWritePolicy.allowsWrites else { return }
        projects[location.projectIndex].sessions[location.sessionIndex].lastTurnAt = Date()
        scheduleSessionSave(sessionID)
    }

    // MARK: - Lookup

    func project(withID projectID: ProjectID) -> Project? {
        guard let index = index(ofProject: projectID) else { return nil }
        return projects[index]
    }

    func session(withID sessionID: SessionID) -> AgentSession? {
        guard let location = locate(sessionID: sessionID) else { return nil }
        return projects[location.projectIndex].sessions[location.sessionIndex]
    }

    /// Returns the project that owns a session.
    func project(forSessionID sessionID: SessionID) -> Project? {
        guard let location = locate(sessionID: sessionID) else { return nil }
        return projects[location.projectIndex]
    }

    /// The folder a session actually executes in, which differs from its logical Project only
    /// for the explicitly opted-in managed-workspace path.
    func workingDirectory(forSessionID sessionID: SessionID) -> String? {
        guard let location = locate(sessionID: sessionID) else { return nil }
        let project = projects[location.projectIndex]
        return project.sessions[location.sessionIndex].workingDirectory(in: project)
    }

    /// A copy suitable for APIs whose existing contract takes a Project but whose work must be
    /// scoped to the session's actual checkout. The persisted Project is never rewritten.
    func executionProject(forSessionID sessionID: SessionID) -> Project? {
        guard let location = locate(sessionID: sessionID) else { return nil }
        var project = projects[location.projectIndex]
        project.folderPath = project.sessions[location.sessionIndex].workingDirectory(in: project)
        return project
    }

    func terminal(withID terminalID: TerminalID) -> ProjectTerminal? {
        guard let location = locate(terminalID: terminalID) else { return nil }
        return projects[location.projectIndex].terminals[location.terminalIndex]
    }

    /// The project where the terminal was created and whose record persists it.
    func homeProject(forTerminalID terminalID: TerminalID) -> Project? {
        guard let location = locate(terminalID: terminalID) else { return nil }
        return projects[location.projectIndex]
    }

    // MARK: - Private Methods

    private func index(ofProject projectID: ProjectID) -> Int? {
        guard let index = projectIndicesByID[projectID],
              projects.indices.contains(index),
              projects[index].id == projectID else { return nil }
        return index
    }

    private func locate(sessionID: SessionID) -> (projectIndex: Int, sessionIndex: Int)? {
        guard let location = sessionLocationsByID[sessionID],
              projects.indices.contains(location.projectIndex),
              projects[location.projectIndex].sessions.indices.contains(location.sessionIndex),
              projects[location.projectIndex].sessions[location.sessionIndex].id == sessionID
        else { return nil }
        return location
    }

    private func locate(terminalID: TerminalID) -> (projectIndex: Int, terminalIndex: Int)? {
        guard let location = terminalLocationsByID[terminalID],
              projects.indices.contains(location.projectIndex),
              projects[location.projectIndex].terminals.indices.contains(location.terminalIndex),
              projects[location.projectIndex].terminals[location.terminalIndex].id == terminalID
        else { return nil }
        return location
    }

    private func rebuildLookupIndexes() {
        projectIndicesByID.removeAll(keepingCapacity: true)
        sessionLocationsByID.removeAll(keepingCapacity: true)
        terminalLocationsByID.removeAll(keepingCapacity: true)

        for (projectIndex, project) in projects.enumerated() {
            // Preserve the old first-match behavior if a damaged persisted document contains
            // duplicate identities; validation can report that corruption separately.
            if projectIndicesByID[project.id] == nil {
                projectIndicesByID[project.id] = projectIndex
            }
            for (sessionIndex, session) in project.sessions.enumerated()
            where sessionLocationsByID[session.id] == nil {
                sessionLocationsByID[session.id] = (projectIndex, sessionIndex)
            }
            for (terminalIndex, terminal) in project.terminals.enumerated()
            where terminalLocationsByID[terminal.id] == nil {
                terminalLocationsByID[terminal.id] = (projectIndex, terminalIndex)
            }
        }
    }

    private func setSelectedSessionWithoutPersistence(_ id: SessionID?) {
        isRestoringState = true
        selectedSessionID = id
        isRestoringState = false
    }

    private func recordPersistedSnapshot() {
        persistedProjects = projects
        persistedSelectedSessionID = selectedSessionID
    }

    /// `saveProject` deliberately does not rewrite session rows. Record only the project payload
    /// it committed while keeping the last durable sessions in the rollback snapshot.
    private func recordPersistedProject(at index: Int) {
        guard projects.indices.contains(index) else { return }
        let persistedIndex: Int
        if persistedProjects.indices.contains(index),
           persistedProjects[index].id == projects[index].id {
            persistedIndex = index
        } else if let located = persistedProjects.firstIndex(where: {
            $0.id == projects[index].id
        }) {
            // Structural saves refresh the complete snapshot, so this is a defensive recovery
            // path rather than ordinary lookup work.
            persistedIndex = located
        } else {
            return
        }
        var committed = projects[index]
        committed.sessions = persistedProjects[persistedIndex].sessions
        persistedProjects[persistedIndex] = committed
    }

    /// Records the one session row an O(changed) write committed, preserving every neighbouring
    /// payload in the rollback snapshot without copying persistence work back into the database.
    private func recordPersistedSession(
        projectIndex: Int,
        sessionIndex: Int
    ) {
        guard projects.indices.contains(projectIndex),
              projects[projectIndex].sessions.indices.contains(sessionIndex) else { return }
        let persistedProjectIndex: Int
        if persistedProjects.indices.contains(projectIndex),
           persistedProjects[projectIndex].id == projects[projectIndex].id {
            persistedProjectIndex = projectIndex
        } else if let located = persistedProjects.firstIndex(where: {
            $0.id == projects[projectIndex].id
        }) {
            persistedProjectIndex = located
        } else {
            return
        }
        let session = projects[projectIndex].sessions[sessionIndex]
        let persistedSessionIndex: Int
        if persistedProjects[persistedProjectIndex].sessions.indices.contains(sessionIndex),
           persistedProjects[persistedProjectIndex].sessions[sessionIndex].id == session.id {
            persistedSessionIndex = sessionIndex
        } else if let located = persistedProjects[persistedProjectIndex].sessions.firstIndex(
            where: { $0.id == session.id }
        ) {
            persistedSessionIndex = located
        } else {
            return
        }
        persistedProjects[persistedProjectIndex].sessions[persistedSessionIndex] = session
    }

    private func restorePersistedSelection() {
        setSelectedSessionWithoutPersistence(persistedSelectedSessionID)
    }

    private func restorePersistedSnapshot() {
        projects = persistedProjects
        restorePersistedSelection()
        rebuildLookupIndexes()
    }

    private func notifyChanged(
        sidebarImpact: ProjectsDidChange.SidebarImpact = .structure
    ) {
        NotificationCenter.default.post(ProjectsDidChange(sidebarImpact: sidebarImpact))
    }

    // MARK: - Persistence

    /// Coalesces rapid changes while retaining which durable rows actually changed.
    private func scheduleSessionSave(_ sessionID: SessionID) {
        pendingSessionSaveIDs.insert(sessionID)
        schedulePendingRecordSave()
    }

    private func scheduleProjectSave(_ projectID: ProjectID) {
        pendingProjectSaveIDs.insert(projectID)
        schedulePendingRecordSave()
    }

    private func schedulePendingRecordSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(
            withTimeInterval: ProjectStoreDefaults.saveCoalescingInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.flushPendingRecordSaves() else { return }
                self.notifyChanged()
            }
        }
    }

    /// Flushes any pending coalesced write, used before the app exits.
    func flushPendingSave() {
        _ = flushPendingRecordSaves()
    }

    /// Flushes only the coalesced project/session rows. The complete burst shares one SQLite
    /// transaction so commit cost does not multiply with the number of dirty rows.
    @discardableResult
    private func flushPendingRecordSaves() -> Bool {
        guard saveTimer != nil
                || !pendingProjectSaveIDs.isEmpty
                || !pendingSessionSaveIDs.isEmpty else { return true }

        saveTimer?.invalidate()
        saveTimer = nil
        let projectIDs = pendingProjectSaveIDs
        let sessionIDs = pendingSessionSaveIDs
        pendingProjectSaveIDs.removeAll(keepingCapacity: true)
        pendingSessionSaveIDs.removeAll(keepingCapacity: true)

        var projectWrites: [ProjectDatabase.ProjectWrite] = []
        var projectIndexes: [Int] = []
        projectWrites.reserveCapacity(projectIDs.count)
        projectIndexes.reserveCapacity(projectIDs.count)
        for projectID in projectIDs {
            guard let projectIndex = index(ofProject: projectID) else { continue }
            projectWrites.append(ProjectDatabase.ProjectWrite(
                project: projects[projectIndex],
                position: projectIndex
            ))
            projectIndexes.append(projectIndex)
        }

        var sessionWrites: [ProjectDatabase.SessionWrite] = []
        var sessionLocations: [(projectIndex: Int, sessionIndex: Int)] = []
        sessionWrites.reserveCapacity(sessionIDs.count)
        sessionLocations.reserveCapacity(sessionIDs.count)
        for sessionID in sessionIDs {
            guard let location = locate(sessionID: sessionID) else { continue }
            let project = projects[location.projectIndex]
            let session = project.sessions[location.sessionIndex]
            sessionWrites.append(ProjectDatabase.SessionWrite(
                session: session,
                projectID: project.id,
                position: location.sessionIndex
            ))
            sessionLocations.append(location)
        }

        guard !projectWrites.isEmpty || !sessionWrites.isEmpty else { return true }
        guard prepareForImmediateSave("coalesced records") else { return false }

        let span = PerformanceRecorder.shared.begin(
            "persistence.records.save",
            category: "persistence",
            metadata: [
                "project_rows": String(projectWrites.count),
                "session_rows": String(sessionWrites.count),
            ]
        )
        let saved = stateManager.saveRecords(
            projects: projectWrites,
            sessions: sessionWrites
        )
        span.end(metadata: ["saved": String(saved)])
        guard saved else {
            recordFailedWritePolicy()
            restorePersistedSnapshot()
            return false
        }

        for projectIndex in projectIndexes {
            recordPersistedProject(at: projectIndex)
        }
        for location in sessionLocations {
            recordPersistedSession(
                projectIndex: location.projectIndex,
                sessionIndex: location.sessionIndex
            )
        }
        return true
    }

    private func discardPendingRecordSaves() {
        saveTimer?.invalidate()
        saveTimer = nil
        pendingProjectSaveIDs.removeAll(keepingCapacity: true)
        pendingSessionSaveIDs.removeAll(keepingCapacity: true)
    }

    @discardableResult
    private func save() -> Bool {
        // A whole-state save includes every pending row, so it supersedes their timer.
        discardPendingRecordSaves()

        guard prepareForImmediateSave("projects state") else { return false }

        let state = ProjectsState(
            projects: projects,
            selectedSessionID: selectedSessionID
        )
        guard stateManager.saveProjectsState(state) else {
            recordFailedWritePolicy()
            restorePersistedSnapshot()
            return false
        }
        recordPersistedSnapshot()
        return true
    }

    /// The new-project fast path: one row and one graph-generation edge.
    private func saveProjectAddition(_ project: Project, at position: Int) -> Bool {
        guard flushPendingRecordSaves(), prepareForImmediateSave("project addition") else {
            restorePersistedSnapshot()
            return false
        }
        guard stateManager.addProject(project, position: position) else {
            recordFailedWritePolicy()
            restorePersistedSnapshot()
            return false
        }
        recordPersistedSnapshot()
        return true
    }

    /// The new-row fast path: one validated SQL upsert plus the graph-generation edge.
    private func saveSessionAddition(
        _ session: AgentSession,
        to projectID: ProjectID,
        position: Int
    ) -> Bool {
        guard prepareForImmediateSave("session addition") else {
            restorePersistedSnapshot()
            return false
        }
        guard stateManager.addSession(session, to: projectID, position: position) else {
            recordFailedWritePolicy()
            restorePersistedSnapshot()
            return false
        }
        recordPersistedSnapshot()
        return true
    }

    /// The bulk-import fast path: only the appended rows, committed together.
    private func saveSessionAdditions(_ writes: [ProjectDatabase.SessionWrite]) -> Bool {
        guard prepareForImmediateSave("session additions") else {
            restorePersistedSnapshot()
            return false
        }
        guard stateManager.addSessions(writes) else {
            recordFailedWritePolicy()
            restorePersistedSnapshot()
            return false
        }
        recordPersistedSnapshot()
        return true
    }

    /// The standing-row fast path used by launch bookkeeping and other isolated mutations.
    private func saveSessionRecord(
        at location: (projectIndex: Int, sessionIndex: Int)
    ) -> Bool {
        saveSessionRecords(at: [location], description: "session")
    }

    /// Writes exactly the standing rows named by the caller. Multi-session provider
    /// reconciliation is atomic, but never pays for unrelated projects or archived history.
    private func saveSessionRecords(
        at locations: [(projectIndex: Int, sessionIndex: Int)],
        description: String
    ) -> Bool {
        var writes: [ProjectDatabase.SessionWrite] = []
        writes.reserveCapacity(locations.count)
        var validLocations: [(projectIndex: Int, sessionIndex: Int)] = []
        validLocations.reserveCapacity(locations.count)
        var includedSessionIDs: Set<SessionID> = []

        for location in locations {
            guard projects.indices.contains(location.projectIndex),
                  projects[location.projectIndex].sessions.indices.contains(location.sessionIndex)
            else { return false }
            let project = projects[location.projectIndex]
            let session = project.sessions[location.sessionIndex]
            guard includedSessionIDs.insert(session.id).inserted else { continue }
            writes.append(ProjectDatabase.SessionWrite(
                session: session,
                projectID: project.id,
                position: location.sessionIndex
            ))
            validLocations.append(location)
        }

        guard !writes.isEmpty else { return true }
        // This exact write includes each target's latest coalesced fields. Unrelated dirty rows
        // stay coalesced; an Enter-key rename must not synchronously drain background updates.
        pendingSessionSaveIDs.subtract(includedSessionIDs)
        cancelSaveTimerIfNoPendingRecords()
        guard prepareForImmediateSave(description) else {
            restorePersistedSnapshot()
            return false
        }

        let span = PerformanceRecorder.shared.begin(
            "persistence.sessions.save",
            category: "persistence",
            metadata: ["changed_rows": String(writes.count)]
        )
        let saved = stateManager.saveSessions(writes)
        span.end(metadata: ["saved": String(saved)])
        guard saved else {
            recordFailedWritePolicy()
            restorePersistedSnapshot()
            return false
        }
        for location in validLocations {
            recordPersistedSession(
                projectIndex: location.projectIndex,
                sessionIndex: location.sessionIndex
            )
        }
        return true
    }

    /// Writes one project's own payload (including its standalone terminals) without touching
    /// session rows. Used by terminal startup metadata such as OSC 7 location reports.
    private func saveProjectRecord(at projectIndex: Int) -> Bool {
        guard projects.indices.contains(projectIndex) else { return false }
        let projectID = projects[projectIndex].id
        pendingProjectSaveIDs.remove(projectID)
        cancelSaveTimerIfNoPendingRecords()
        guard prepareForImmediateSave("project") else {
            restorePersistedSnapshot()
            return false
        }
        guard stateManager.saveProject(projects[projectIndex], position: projectIndex) else {
            recordFailedWritePolicy()
            restorePersistedSnapshot()
            return false
        }
        recordPersistedProject(at: projectIndex)
        return true
    }

    private func cancelSaveTimerIfNoPendingRecords() {
        guard pendingProjectSaveIDs.isEmpty, pendingSessionSaveIDs.isEmpty else { return }
        saveTimer?.invalidate()
        saveTimer = nil
    }

    /// The permanent-delete fast path: one SQL delete and one positional shift, instead of
    /// encoding and upserting every session in every project on the main actor.
    private func saveSessionRemoval(
        _ sessionID: SessionID,
        from projectID: ProjectID,
        at position: Int
    ) -> Bool {
        guard prepareForImmediateSave("session removal") else { return false }

        let span = PerformanceRecorder.shared.begin(
            "sidebar.session-remove.persist",
            category: "sidebar",
            metadata: [
                "projects": String(projects.count),
                "sessions": String(projects.reduce(0) { $0 + $1.sessions.count })
            ]
        )
        let saved = stateManager.removeSession(
            id: sessionID,
            from: projectID,
            at: position,
            selectedSessionID: selectedSessionID
        )
        span.end(metadata: ["saved": String(saved)])
        guard saved else {
            recordFailedWritePolicy()
            restorePersistedSnapshot()
            return false
        }
        recordPersistedSnapshot()
        return true
    }

    /// The project-delete fast path: one delete/cascade and a positional shift of later projects.
    private func saveProjectRemoval(_ projectID: ProjectID, at position: Int) -> Bool {
        guard prepareForImmediateSave("project removal") else {
            restorePersistedSnapshot()
            return false
        }
        guard stateManager.removeProject(
            id: projectID,
            at: position,
            selectedSessionID: selectedSessionID
        ) else {
            recordFailedWritePolicy()
            restorePersistedSnapshot()
            return false
        }
        recordPersistedSnapshot()
        return true
    }

    /// Applies the store-owned refusal policy before any immediate persistence operation.
    private func prepareForImmediateSave(_ description: String) -> Bool {
        guard stateWritePolicy.allowsWrites else {
            // The reason is stored with the refusal. Consulting the process-global recovery
            // flag here made an injected recovery store report a fictional failed quarantine,
            // and collapsed a failed write into a failed load in real diagnostics.
            switch stateWritePolicy {
            case .recoveryMode:
                RecoveryMode.refuse("a \(description) save")
            case .failedLoad:
                ThreadingLogger.agent.error(
                    "Refusing to save \(description, privacy: .public) because its earlier load was not authoritative"
                )
            case .storageExhausted:
                ThreadingLogger.agent.error(
                    "Refusing to save \(description, privacy: .public) because storage is full"
                )
            case .failedWrite:
                ThreadingLogger.agent.error(
                    "Refusing to save \(description, privacy: .public) because an earlier write failed"
                )
            case .allowed:
                break
            }
            restorePersistedSnapshot()
            return false
        }
        return true
    }

    /// Reads the store, and records that it was read.
    ///
    /// **The checkpoint is here rather than in `AppDelegate`.** The launch does not open this
    /// store at a line anyone chose — it opens when something first asks for it, which today is
    /// inside the first window's layout — and putting the checkpoint in the launch sequence would
    /// mean opening the store early so that it could be observed. Moving a real load to observe
    /// it is not observing it. The consequence to expect when reading a ledger: `persistenceOpened`
    /// lands *after* `mainWindowConstructed`. Checkpoints are timestamped facts, not an order.
    private func load() {
        switch stateManager.loadProjectsState() {
        case .missing:
            LaunchLedger.shared.record(.persistenceOpened, detail: [
                StartupCheckpointDefaults.storeStateField: StartupCheckpointDefaults.storeMissing
            ])
            recordPersistedSnapshot()
            return
        case .loaded(let state):
            LaunchLedger.shared.record(.persistenceOpened, detail: [
                StartupCheckpointDefaults.storeStateField: StartupCheckpointDefaults.storeLoaded
            ])
            isRestoringState = true
            projects = state.projects
            selectedSessionID = state.selectedSessionID
            isRestoringState = false
            recordPersistedSnapshot()
            if migrateLegacyThemeAssignments() {
                save()
            }
        case .failed(let quarantinedAt):
            LaunchLedger.shared.record(.persistenceOpened, detail: [
                StartupCheckpointDefaults.storeStateField: StartupCheckpointDefaults.storeFailed
            ])
            didLoadStateSuccessfully = false
            stateWritePolicy = stateManager.persistenceHealth == .storageExhausted
                ? .storageExhausted
                : .failedLoad
            if let quarantinedAt {
                ThreadingLogger.agent.error(
                    "Projects state requires recovery from \(quarantinedAt.path, privacy: .private(mask: .hash))"
                )
            }
        }
    }

    /// Reloads the authoritative graph after `StateManager` has proved the database healthy and
    /// writable. The UI can call this after approved cleanup or from an explicit Retry action;
    /// no other refusal reason is weakened.
    @discardableResult
    func recoverFromStorageExhaustion() -> Bool {
        guard case .storageExhausted = stateWritePolicy else {
            return stateWritePolicy.allowsWrites
        }

        switch stateManager.recoverFromStorageExhaustion() {
        case .missing:
            isRestoringState = true
            projects = []
            selectedSessionID = nil
            isRestoringState = false
        case .loaded(let state):
            isRestoringState = true
            projects = state.projects
            selectedSessionID = state.selectedSessionID
            isRestoringState = false
        case .failed:
            recordFailedWritePolicy()
            return false
        }

        didLoadStateSuccessfully = true
        stateWritePolicy = .allowed
        rebuildLookupIndexes()
        recordPersistedSnapshot()
        notifyChanged()
        return true
    }

    private func recordFailedWritePolicy() {
        stateWritePolicy = stateManager.persistenceHealth == .storageExhausted
            ? .storageExhausted
            : .failedWrite
    }

    /// Converts the tagged names decoded from old `projects.json` files into current IDs.
    private func migrateLegacyThemeAssignments() -> Bool {
        var changed = false

        for projectIndex in projects.indices {
            if let stored = projects[projectIndex].themeID,
               let canonical = ThemeManager.shared.canonicalID(for: stored),
               canonical != stored {
                projects[projectIndex].themeID = canonical
                changed = true
            }

            for sessionIndex in projects[projectIndex].sessions.indices {
                guard let stored = projects[projectIndex].sessions[sessionIndex].themeID,
                      let canonical = ThemeManager.shared.canonicalID(for: stored),
                      canonical != stored else { continue }
                projects[projectIndex].sessions[sessionIndex].themeID = canonical
                changed = true
            }
        }

        return changed
    }
}
