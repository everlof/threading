import Foundation

/// Owns the project list and its persistence.
///
/// This is the model layer only: it knows nothing about running processes. Live terminals
/// are managed by `AgentRuntime`, keyed by the session identifiers stored here.
@MainActor
final class ProjectStore {

    // MARK: - Singleton

    static let shared = ProjectStore()

    // MARK: - Properties

    private(set) var projects: [Project] = []

    /// False for the rest of a launch after a corrupt or unsupported state file was found.
    /// Consumers must not interpret the resulting empty project list as authoritative.
    private(set) var didLoadStateSuccessfully = true

    /// A failed quarantine leaves the original file in place, so no write may replace it.
    private var stateWritesAllowed = true

    private let stateManager: StateManager
    private var isRestoringState = false

    /// Pending coalesced write, see `scheduleSave()`.
    private var saveTimer: Timer?

    /// The session currently shown in the terminal pane.
    var selectedSessionID: SessionID? {
        didSet {
            guard !isRestoringState, selectedSessionID != oldValue else { return }
            // Selection is navigation state, not a structural edit. Rewriting every project
            // and session here made sidebar clicks progressively slower as the store grew.
            stateManager.saveSelectedSessionID(selectedSessionID)
        }
    }

    // MARK: - Initialization

    init(stateManager: StateManager = .shared) {
        self.stateManager = stateManager
        load()
    }

    // MARK: - Project Management

    /// Adds a project for a folder, naming it after the enclosing git repository when there
    /// is one. Returns the existing project if the folder was already added.
    @discardableResult
    func addProject(folderURL: URL) -> Project {
        let normalizedPath = folderURL.standardizedFileURL.resolvingSymlinksInPath().path

        if let existing = projects.first(where: { $0.folderPath == normalizedPath }) {
            return existing
        }

        var project = Project(
            name: GitInfo.suggestedProjectName(for: folderURL),
            folderURL: folderURL
        )
        project.folderPath = normalizedPath

        projects.append(project)
        save()
        notifyChanged()

        return project
    }

    func removeProject(id: ProjectID) {
        if let icon = project(withID: id)?.icon {
            ProjectIconStore.remove(fileName: icon.fileName)
        }

        DraftStore.shared.clear(for: id)

        projects.removeAll { $0.id == id }
        save()
        notifyChanged()
    }

    func renameProject(id: ProjectID, to name: String) {
        guard let index = index(ofProject: id) else { return }
        projects[index].name = name
        save()
        notifyChanged()
    }

    func setProject(id: ProjectID, expanded: Bool) {
        guard let index = index(ofProject: id) else { return }
        projects[index].isExpanded = expanded
        save()
    }

    /// Records a project's sidebar icon, or clears it. The icon's image file is owned by
    /// `ProjectIconStore`; this only records which file and where it came from.
    func setIcon(_ icon: ProjectIcon?, for projectID: ProjectID) {
        guard let index = index(ofProject: projectID),
              projects[index].icon != icon else { return }

        // Replacement rewrites the same file (it is named after the project), so only a
        // record pointing at a *different* file leaves one to clean up.
        if let old = projects[index].icon, old.fileName != icon?.fileName {
            ProjectIconStore.remove(fileName: old.fileName)
        }

        projects[index].icon = icon
        save()
        notifyChanged()
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
        usesNativeUI: Bool = false,
        permissionMode: AgentPermissionMode? = nil,
        title: String? = nil
    ) -> AgentSession? {
        guard let index = index(ofProject: projectID) else { return nil }

        // No title means unnamed, not named after the agent: the display falls back to a
        // generic label until the first prompt supplies a name (`applyPromptTitle`). The
        // agent and account are the row's icon slot's job, not the name's.
        var session = AgentSession(
            kind: kind,
            title: title ?? "",
            accountHandle: accountHandle,
            model: model,
            reasoningEffort: reasoningEffort,
            usesNativeUI: usesNativeUI
        )
        session.branch = GitInfo.currentBranch(for: projects[index].folderPath)
        session.permissionMode = permissionMode

        projects[index].sessions.append(session)
        save()
        notifyChanged()

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
        guard parent.resumeState.isResumable else { return nil }

        var session = AgentSession(
            kind: parent.kind,
            title: title ?? AgentDefaults.sideChatTitle,
            accountHandle: parent.accountHandle,
            model: parent.model,
            usesNativeUI: parent.usesNativeUI,
            forkedFrom: parentID
        )
        session.branch = parent.branch
        // A side chat asks a question *about* the parent's work, so it inherits the parent's
        // posture along with its agent, account and surface — including a deliberate nil,
        // which keeps it following the app default exactly as the parent does.
        session.permissionMode = parent.permissionMode

        projects[location.projectIndex].sessions.append(session)
        save()
        notifyChanged()

        return session
    }

    /// Adopts a conversation found on disk, so it can be resumed like any other session.
    ///
    /// The session is created already launched and carrying its identifier: it exists because
    /// a conversation exists, so selecting it must resume that conversation rather than start
    /// a new one. Adopting the same conversation twice is refused, since both entries would
    /// resume the same transcript.
    @discardableResult
    func importSession(_ found: ImportableSession, into projectID: ProjectID) -> AgentSession? {
        guard let index = index(ofProject: projectID) else { return nil }

        guard !projects[index].sessions.contains(where: {
            $0.resumeState.transcriptID == found.agentSessionID
        })
        else { return nil }

        var session = AgentSession(
            kind: found.kind,
            title: found.title,
            accountHandle: found.accountHandle
        )
        session.resumeState = .resumable(found.agentSessionID)
        session.hasLaunched = true
        session.lastActiveAt = found.lastActiveAt
        session.branch = GitInfo.currentBranch(for: projects[index].folderPath)

        projects[index].sessions.append(session)
        save()
        notifyChanged()

        return session
    }

    /// Files a session away, or restores it. Its conversation is untouched either way.
    func setArchived(_ archived: Bool, for sessionID: SessionID) {
        update(sessionID: sessionID) { $0.isArchived = archived }
        notifyChanged()
    }

    func setPinned(_ pinned: Bool, for sessionID: SessionID) {
        update(sessionID: sessionID) { $0.isPinned = pinned }
        notifyChanged()
    }

    /// Switches which surface renders a session: Skalman's own conversation view, or the
    /// agent's terminal. The conversation itself is untouched — both surfaces resume it by
    /// the same id. Stopping whatever is running belongs to the caller, since this store
    /// knows nothing about live processes.
    func setUsesNativeUI(_ usesNative: Bool, for sessionID: SessionID) {
        update(sessionID: sessionID) { $0.usesNativeUI = usesNative }
        notifyChanged()
    }

    /// Records this conversation's own answer about Claude's Remote Control bridge. Nil clears
    /// it, so the session follows `AppSettings.claudeRemoteControl` — and Claude's own `/config`
    /// beyond that — again.
    ///
    /// Applied on the session's next launch, where the settings file is written. Nothing here
    /// disconnects a bridge that is already open; that is `/remote-control` inside the session,
    /// or a relaunch.
    func setRemoteControl(_ remoteControl: Bool?, for sessionID: SessionID) {
        update(sessionID: sessionID) { $0.remoteControl = remoteControl }
        notifyChanged()
    }

    /// Records how much this conversation may do before it has to ask. Nil clears it, so the
    /// session follows `AppSettings.defaultPermissionMode` — and the CLI's own configuration
    /// beyond that — again.
    ///
    /// Applied on the session's next launch, where the flags are built. Nothing here changes the
    /// mode of a session that is already running: Claude's own Shift+Tab does that, and the CLI
    /// does not report the result back.
    func setPermissionMode(_ mode: AgentPermissionMode?, for sessionID: SessionID) {
        update(sessionID: sessionID) { $0.permissionMode = mode }
        notifyChanged()
    }

    /// Records which theme a session's terminal draws with. Nil clears the assignment, so the
    /// session inherits its project's theme — and the app default beyond that — again.
    func setThemeID(_ themeID: TerminalThemeID?, forSessionID sessionID: SessionID) {
        update(sessionID: sessionID) { $0.themeID = themeID }
        notifyChanged()
    }

    /// The same for a project, which every session inside it follows unless it chooses its own.
    func setThemeID(_ themeID: TerminalThemeID?, forProjectID projectID: ProjectID) {
        guard let index = index(ofProject: projectID) else { return }
        projects[index].themeID = themeID
        save()
        notifyChanged()
    }

    /// Silences one conversation's notifications, or lets it speak. Nil returns it to
    /// following its project — the same three scopes as the theme above, and the reason both
    /// setters take an optional. Withdrawing anything already on screen belongs to the caller:
    /// this store knows nothing about notifications.
    func setNotificationsMuted(_ muted: Bool?, forSessionID sessionID: SessionID) {
        update(sessionID: sessionID) { $0.notificationsMuted = muted }
        notifyChanged()
    }

    /// The same for a whole checkout.
    func setNotificationsMuted(_ muted: Bool?, forProjectID projectID: ProjectID) {
        guard let index = index(ofProject: projectID) else { return }
        projects[index].notificationsMuted = muted
        save()
        notifyChanged()
    }

    /// Every archived session, newest first, paired with the project it belongs to.
    func archivedSessions() -> [(project: Project, session: AgentSession)] {
        projects
            .flatMap { project in project.sessions.map { (project, $0) } }
            .filter { $0.1.isArchived }
            .sorted { $0.1.lastActiveAt > $1.1.lastActiveAt }
    }

    func removeSession(id sessionID: SessionID) {
        guard let location = locate(sessionID: sessionID) else { return }
        projects[location.projectIndex].sessions.remove(at: location.sessionIndex)

        if selectedSessionID == sessionID {
            // The property's observer persists the removal together with the selection change.
            selectedSessionID = nil
        } else {
            save()
        }

        notifyChanged()
    }

    /// Applies an explicit name to a session. Pass nil or blank to fall back to the
    /// terminal's own title again.
    func renameSession(id sessionID: SessionID, to title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(sessionID: sessionID) { $0.customTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed }
        notifyChanged()
    }

    /// Records the agent's own name for a conversation, from either transport — the terminal
    /// title while a PTY is attached, or the transcript's title records read at turn end.
    ///
    /// A title that is really the product, account or project name is ignored rather than
    /// stored: Claude's TUI titles itself "Claude Code" until it has an AI title, and Codex
    /// titles itself after the working directory. Neither names the conversation, and neither
    /// is worth displacing a real title that arrived earlier.
    ///
    /// Agents update this frequently, so the write is coalesced rather than hitting disk on
    /// every change.
    func updateAgentTitle(_ title: String, for sessionID: SessionID) {
        guard let location = locate(sessionID: sessionID) else { return }

        let project = projects[location.projectIndex]
        let session = project.sessions[location.sessionIndex]

        let cleaned = Self.strippingDecoration(from: title)
        guard session.agentTitle != cleaned else { return }

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
            ) else { return }
        }

        projects[location.projectIndex].sessions[location.sessionIndex].agentTitle = cleaned
        scheduleSave()
        notifyChanged()
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
        save()
        notifyChanged()
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
        save()
        notifyChanged()
    }

    /// Re-reads a checkout's branch and applies it to every session standing in that
    /// checkout — `CheckoutBranchFollower`'s write path, and the meaning of Settings >
    /// General's "Follow the checkout's branch".
    ///
    /// `refreshBranch(forSessionID:)` records what one session just ran on; this keeps the
    /// *others* honest when the checkout moves under them — switched by a different session,
    /// the shell drawer, or a terminal outside Skalman entirely. Sessions match by
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

        var changed = false
        for projectIndex in projects.indices
        where GitInfo.worktreeIdentity(for: projects[projectIndex].folderPath) == identity {
            for sessionIndex in projects[projectIndex].sessions.indices
            where projects[projectIndex].sessions[sessionIndex].branch != branch {
                projects[projectIndex].sessions[sessionIndex].branch = branch
                changed = true
            }
        }

        guard changed else { return }
        save()
        notifyChanged()
    }

    /// Applies a mutation to a stored session and persists the result.
    func update(sessionID: SessionID, _ mutate: (inout AgentSession) -> Void) {
        guard let location = locate(sessionID: sessionID) else { return }
        mutate(&projects[location.projectIndex].sessions[location.sessionIndex])
        save()
    }

    // MARK: - Lookup

    func project(withID projectID: ProjectID) -> Project? {
        projects.first { $0.id == projectID }
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

    // MARK: - Private Methods

    private func index(ofProject projectID: ProjectID) -> Int? {
        projects.firstIndex { $0.id == projectID }
    }

    private func locate(sessionID: SessionID) -> (projectIndex: Int, sessionIndex: Int)? {
        for (projectIndex, project) in projects.enumerated() {
            if let sessionIndex = project.sessions.firstIndex(where: { $0.id == sessionID }) {
                return (projectIndex, sessionIndex)
            }
        }
        return nil
    }

    private func notifyChanged() {
        NotificationCenter.default.post(ProjectsDidChange())
    }

    // MARK: - Persistence

    /// Coalesces rapid changes into a single write.
    ///
    /// Structural edits persist immediately; only high-frequency updates such as terminal
    /// titles come through here, where losing the last fraction of a second costs nothing.
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(
            withTimeInterval: ProjectStoreDefaults.saveCoalescingInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.save()
            }
        }
    }

    /// Flushes any pending coalesced write, used before the app exits.
    func flushPendingSave() {
        guard saveTimer != nil else { return }
        saveTimer?.invalidate()
        saveTimer = nil
        save()
    }

    private func save() {
        saveTimer?.invalidate()
        saveTimer = nil

        guard stateWritesAllowed else {
            SkalmanLogger.agent.error(
                "Refusing to save projects state because its failed load could not be quarantined"
            )
            return
        }

        let state = ProjectsState(
            projects: projects,
            selectedSessionID: selectedSessionID
        )
        stateManager.saveProjectsState(state)
    }

    private func load() {
        switch stateManager.loadProjectsState() {
        case .missing:
            return
        case .loaded(let state):
            isRestoringState = true
            projects = state.projects
            selectedSessionID = state.selectedSessionID
            isRestoringState = false
            if migrateLegacyThemeAssignments() {
                save()
            }
        case .failed(let quarantinedAt):
            didLoadStateSuccessfully = false
            stateWritesAllowed = quarantinedAt != nil
        }
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
