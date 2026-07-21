import Foundation

/// Owns the project list and its persistence.
///
/// This is the model layer only: it knows nothing about running processes. Live terminals
/// are managed by `AgentRuntime`, keyed by the session identifiers stored here.
final class ProjectStore {

    // MARK: - Singleton

    static let shared = ProjectStore()

    // MARK: - Properties

    private(set) var projects: [Project] = []

    /// Pending coalesced write, see `scheduleSave()`.
    private var saveTimer: Timer?

    /// The session currently shown in the terminal pane.
    var selectedSessionID: UUID? {
        didSet {
            guard selectedSessionID != oldValue else { return }
            save()
        }
    }

    // MARK: - Initialization

    private init() {
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

    func removeProject(id: UUID) {
        projects.removeAll { $0.id == id }
        save()
        notifyChanged()
    }

    func renameProject(id: UUID, to name: String) {
        guard let index = index(ofProject: id) else { return }
        projects[index].name = name
        save()
        notifyChanged()
    }

    func setProject(id: UUID, expanded: Bool) {
        guard let index = index(ofProject: id) else { return }
        projects[index].isExpanded = expanded
        save()
    }

    // MARK: - Session Management

    /// Creates a new session inside a project and returns it.
    @discardableResult
    func addSession(
        to projectID: UUID,
        kind: AgentKind,
        accountHandle: String? = nil,
        model: String? = nil,
        usesNativeUI: Bool = false,
        title: String? = nil
    ) -> AgentSession? {
        guard let index = index(ofProject: projectID) else { return nil }

        let session = AgentSession(
            kind: kind,
            title: title ?? defaultSessionTitle(
                for: kind,
                accountHandle: accountHandle,
                in: projects[index]
            ),
            accountHandle: accountHandle,
            model: model,
            usesNativeUI: usesNativeUI
        )

        projects[index].sessions.append(session)
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
    func importSession(_ found: ImportableSession, into projectID: UUID) -> AgentSession? {
        guard let index = index(ofProject: projectID) else { return nil }

        guard !projects[index].sessions.contains(where: { $0.agentSessionID == found.agentSessionID })
        else { return nil }

        var session = AgentSession(
            kind: found.kind,
            title: found.title,
            accountHandle: found.accountHandle
        )
        session.agentSessionID = found.agentSessionID
        session.hasLaunched = true
        session.lastActiveAt = found.lastActiveAt

        projects[index].sessions.append(session)
        save()
        notifyChanged()

        return session
    }

    /// Files a session away, or restores it. Its conversation is untouched either way.
    func setArchived(_ archived: Bool, for sessionID: UUID) {
        update(sessionID: sessionID) { $0.isArchived = archived }
        notifyChanged()
    }

    /// Every archived session, newest first, paired with the project it belongs to.
    func archivedSessions() -> [(project: Project, session: AgentSession)] {
        projects
            .flatMap { project in project.sessions.map { (project, $0) } }
            .filter { $0.1.isArchived }
            .sorted { $0.1.lastActiveAt > $1.1.lastActiveAt }
    }

    func removeSession(id sessionID: UUID) {
        guard let location = locate(sessionID: sessionID) else { return }
        projects[location.projectIndex].sessions.remove(at: location.sessionIndex)

        if selectedSessionID == sessionID {
            selectedSessionID = nil
        }

        save()
        notifyChanged()
    }

    /// Applies an explicit name to a session. Pass nil or blank to fall back to the
    /// terminal's own title again.
    func renameSession(id sessionID: UUID, to title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(sessionID: sessionID) { $0.customTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed }
        notifyChanged()
    }

    /// Records the title reported by a session's terminal.
    ///
    /// Agents update this frequently, so the write is coalesced rather than hitting disk on
    /// every change.
    func updateTerminalTitle(_ title: String, for sessionID: UUID) {
        guard let location = locate(sessionID: sessionID) else { return }

        let cleaned = Self.strippingDecoration(from: title)
        guard projects[location.projectIndex].sessions[location.sessionIndex].terminalTitle != cleaned
        else { return }

        projects[location.projectIndex].sessions[location.sessionIndex].terminalTitle = cleaned
        scheduleSave()
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

    /// Applies a mutation to a stored session and persists the result.
    func update(sessionID: UUID, _ mutate: (inout AgentSession) -> Void) {
        guard let location = locate(sessionID: sessionID) else { return }
        mutate(&projects[location.projectIndex].sessions[location.sessionIndex])
        save()
    }

    // MARK: - Lookup

    func project(withID projectID: UUID) -> Project? {
        projects.first { $0.id == projectID }
    }

    func session(withID sessionID: UUID) -> AgentSession? {
        guard let location = locate(sessionID: sessionID) else { return nil }
        return projects[location.projectIndex].sessions[location.sessionIndex]
    }

    /// Returns the project that owns a session.
    func project(forSessionID sessionID: UUID) -> Project? {
        guard let location = locate(sessionID: sessionID) else { return nil }
        return projects[location.projectIndex]
    }

    // MARK: - Private Methods

    private func index(ofProject projectID: UUID) -> Int? {
        projects.firstIndex { $0.id == projectID }
    }

    private func locate(sessionID: UUID) -> (projectIndex: Int, sessionIndex: Int)? {
        for (projectIndex, project) in projects.enumerated() {
            if let sessionIndex = project.sessions.firstIndex(where: { $0.id == sessionID }) {
                return (projectIndex, sessionIndex)
            }
        }
        return nil
    }

    /// Names a new session after its agent, numbering repeats within the same project.
    ///
    /// Sessions on an alternate account are named after that account, since the user already
    /// knows it by that name and the account is the meaningful distinction between them.
    private func defaultSessionTitle(
        for kind: AgentKind,
        accountHandle: String?,
        in project: Project
    ) -> String {
        let account = AgentAccountDiscovery.account(for: kind, handle: accountHandle)
        let baseName = (account.map { $0.isDefault } ?? true)
            ? kind.displayName
            : account?.displayName ?? kind.displayName

        let sameNameCount = project.sessions.filter {
            $0.kind == kind && $0.accountHandle == accountHandle
        }.count

        return sameNameCount == 0 ? baseName : "\(baseName) \(sameNameCount + 1)"
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .projectsDidChange, object: self)
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
            self?.save()
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

        let state = ProjectsState(
            projects: projects,
            selectedSessionID: selectedSessionID
        )
        StateManager.shared.saveProjectsState(state)
    }

    private func load() {
        guard let state = StateManager.shared.loadProjectsState() else { return }
        projects = state.projects
        selectedSessionID = state.selectedSessionID
    }
}
