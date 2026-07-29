import AppKit

/// Owns session lifecycle decisions while the window controller owns only navigation chrome.
///
/// Creation, import, worktree targeting, surface switches, and closing all converge here so an
/// opening prompt cannot be stranded in one delegate extension while the launch happens in
/// another. The sidebar and container remain the views through which those decisions appear.
@MainActor
final class SessionCoordinator: SessionComposerViewControllerDelegate {

    private let sidebar: ProjectSidebarViewController
    private let container: TerminalContainerViewController
    private let onPresentationChanged: () -> Void

    /// Consumed by the next selected session exactly once.
    private var pendingPrompt: String?

    init(
        sidebar: ProjectSidebarViewController,
        container: TerminalContainerViewController,
        onPresentationChanged: @escaping () -> Void
    ) {
        self.sidebar = sidebar
        self.container = container
        self.onPresentationChanged = onPresentationChanged
    }

    func takePendingPrompt() -> String? {
        defer { pendingPrompt = nil }
        return pendingPrompt
    }

    func newSession() {
        let projectID: ProjectID?
        if let sessionID = container.currentSessionID {
            projectID = ProjectStore.shared.project(forSessionID: sessionID)?.id
        } else {
            projectID = ProjectStore.shared.projects.first?.id
        }

        guard let projectID else {
            addProject()
            return
        }
        sidebar.select(projectID: projectID)
    }

    func addProject() {
        ProjectFolderPrompt.chooseExistingFolder { [weak self] url in
            self?.adoptProject(at: url)
        }
    }

    func newProject() {
        ProjectFolderPrompt.createNewFolder { [weak self] url in
            self?.adoptProject(at: url)
        }
    }

    private func adoptProject(at url: URL) {
        let project = ProjectStore.shared.addProject(folderURL: url)
        sidebar.reload()
        sidebar.select(projectID: project.id)
    }

    func closeCurrentSession() {
        guard let sessionID = container.currentSessionID else { return }
        closeSession(sessionID)
    }

    /// Ends a session's agent and releases its terminal, keeping the row in the sidebar to be
    /// resumed. Cmd+W and the row's `⋯` menu both land here so they cannot drift — the menu
    /// used to discard the process directly, skipping the confirmation Cmd+W asked for.
    func closeSession(_ sessionID: SessionID) {
        guard confirmCloseIfRunning(sessionID: sessionID) else { return }

        container.closeTerminal(for: sessionID)
        sidebar.refreshRows()
    }

    /// Files a session away, or restores it.
    ///
    /// Archiving implies closing: the row leaves the sidebar, and an agent nothing lists must
    /// not keep running unseen. The remote archive route has always stopped the process first;
    /// this is the sidebar reaching the same rule. Restoring implies nothing — a dormant
    /// session returns to the sidebar dormant.
    func setArchived(_ archived: Bool, for sessionID: SessionID) {
        if archived {
            guard confirmArchiveIfRunning(sessionID: sessionID) else { return }
            container.closeTerminal(for: sessionID)
        }

        ProjectStore.shared.setArchived(archived, for: sessionID)

        if archived, sessionID == container.currentSessionID {
            container.show(sessionID: nil)
        }
        sidebar.reload()
    }

    func setUsesNativeUI(_ usesNative: Bool, for sessionID: SessionID) {
        guard confirmSurfaceSwitchIfRunning(sessionID: sessionID, toNative: usesNative) else {
            return
        }

        AgentRuntime.shared.discard(sessionID: sessionID)
        ProjectStore.shared.setUsesNativeUI(usesNative, for: sessionID)
        container.reopenIfShowing(sessionID: sessionID)
        sidebar.reload()
        onPresentationChanged()
    }

    /// Moves a conversation to another account of the same agent and reopens it there.
    ///
    /// The same shape as the surface switch, and for the same reason: `SessionMigration` stops
    /// the live process — it belongs to the old account and is still writing the transcript
    /// being copied — so the session on screen has no terminal until something puts one back.
    /// Reloading the sidebar alone left the pane blank until the session was selected again,
    /// which read as the move having done nothing.
    func moveSession(_ sessionID: SessionID, to account: AgentAccount) {
        guard confirmMoveIfRunning(sessionID: sessionID, to: account) else { return }

        switch SessionMigration.move(sessionID: sessionID, to: account) {
        case .success:
            container.reopenIfShowing(sessionID: sessionID)
            sidebar.reload()
            onPresentationChanged()
        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = L10n.string("Couldn't move the conversation")
            alert.informativeText = error.message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    func createSideChat(of sessionID: SessionID, prompt: String?) {
        // "Ask on the Side" carries its question, which names the chat the same way the
        // composer's prompt names an ordinary session. A plain fork stays "Side Chat" until
        // its first prompt does.
        let title = prompt.flatMap(SessionNaming.promptTitle(from:))
        guard let session = ProjectStore.shared.addSideChat(of: sessionID, title: title)
        else { return }

        EventLog.shared.record(.composer, "Side chat forked", [
            "session": session.id.uuidString,
            "parent": sessionID.uuidString,
            "prompt": prompt ?? ""
        ])

        pendingPrompt = prompt
        sidebar.reload()
        sidebar.select(sessionID: session.id)
    }

    // MARK: - Composer

    func sessionComposer(
        _ composer: SessionComposerViewController,
        startSessionIn projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle,
        model: String?,
        branch: String?,
        usesNativeUI: Bool,
        permissionMode: AgentPermissionMode?,
        prompt: String
    ) {
        let targetProjectID = Self.targetProjectID(
            startingAt: projectID,
            branch: branch,
            checkout: ProjectStore.shared.checkout(onBranch:inRepositoryOf:)
        )

        let opening = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let session = ProjectStore.shared.addSession(
            to: targetProjectID,
            kind: kind,
            accountHandle: accountHandle,
            model: model,
            usesNativeUI: usesNativeUI,
            permissionMode: permissionMode,
            title: SessionNaming.promptTitle(from: opening)
        ) else { return }

        // The mode is recorded as chosen — nil included, which reads as "inherit" rather than
        // as a mode. Reading the resolved flag back belongs to the "Launching agent" entry,
        // which carries the whole command line.
        EventLog.shared.record(.composer, "Session started from composer", [
            "session": session.id.uuidString,
            "project": targetProjectID.uuidString,
            "agent": kind.rawValue,
            "account": accountHandle.name,
            "permissionMode": permissionMode?.rawValue ?? "inherit",
            "prompt": opening
        ])

        DraftStore.shared.clear(for: projectID)
        pendingPrompt = opening
        sidebar.reload()
        sidebar.select(sessionID: session.id)
    }

    /// Starts a session requested by the paired owner device through the same one-shot prompt
    /// route as the Mac composer. Selecting it is intentional: a terminal must be installed in
    /// a laid-out view before its PTY can start, and the native surface follows the same
    /// one-live-process path. The window is not activated, so the phone never steals Mac focus.
    @discardableResult
    func startRemoteSession(
        in projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle,
        model: String?,
        reasoningEffort: String?,
        usesNativeUI: Bool,
        prompt: String
    ) -> AgentSession? {
        let opening = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !opening.isEmpty,
              let session = ProjectStore.shared.addSession(
                to: projectID,
                kind: kind,
                accountHandle: accountHandle,
                model: model,
                reasoningEffort: reasoningEffort,
                usesNativeUI: usesNativeUI,
                title: SessionNaming.promptTitle(from: opening)
              ) else { return nil }

        EventLog.shared.record(.remote, "Session started remotely", [
            "session": session.id.uuidString,
            "project": projectID.uuidString,
            "agent": kind.rawValue,
            "prompt": opening,
        ])

        pendingPrompt = opening
        sidebar.reload()
        sidebar.select(sessionID: session.id)
        return session
    }

    func sessionComposer(
        _ composer: SessionComposerViewController,
        importSession session: ImportableSession,
        into projectID: ProjectID
    ) {
        guard let adopted = ProjectStore.shared.importSession(session, into: projectID) else {
            return
        }

        sidebar.reload()
        sidebar.select(sessionID: adopted.id)
    }

    func sessionComposer(
        _ composer: SessionComposerViewController,
        didCreateWorktreeAt url: URL,
        branch: String
    ) {
        let project = ProjectStore.shared.addProject(folderURL: url)
        sidebar.reload()
        container.showComposer(projectID: project.id)
    }

    /// A branch selection targets its existing checkout; a missing or removed checkout falls
    /// back to the project where the composer opened.
    static func targetProjectID(
        startingAt projectID: ProjectID,
        branch: String?,
        checkout: (String, ProjectID) -> ProjectID?
    ) -> ProjectID {
        branch.flatMap { checkout($0, projectID) } ?? projectID
    }

    // MARK: - Confirmation

    private func confirmCloseIfRunning(sessionID: SessionID) -> Bool {
        guard AppSettings.shared.confirmsBeforeClosingRunningSession,
              AgentRuntime.shared.isRunning(sessionID: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return true }

        return Self.closeConfirmationAlert(for: session).runModal() == .alertFirstButtonReturn
    }

    /// Archiving interrupts a running agent exactly as closing does, so it asks under the same
    /// setting — with its own wording, because what happens next differs: the session leaves
    /// the sidebar rather than staying to be resumed.
    private func confirmArchiveIfRunning(sessionID: SessionID) -> Bool {
        guard AppSettings.shared.confirmsBeforeClosingRunningSession,
              AgentRuntime.shared.isRunning(sessionID: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return true }

        return Self.archiveConfirmationAlert(for: session).runModal() == .alertFirstButtonReturn
    }

    /// The two alerts are built separately from run so a test can hold their wording to what
    /// the action actually does — the same seam the sidebar's menu builders offer. Each one
    /// says where the session ends up, since "Close" and "Archive" alone do not.
    static func closeConfirmationAlert(for session: AgentSession) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L10n.format("Close “%@”?", session.displayTitle)
        alert.informativeText = session.kind.supportsResume
            ? L10n.string(
                "The agent will stop. The session stays in the sidebar and can be resumed."
            )
            : L10n.string("The shell will stop. The session stays in the sidebar.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("Close Session"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        return alert
    }

    static func archiveConfirmationAlert(for session: AgentSession) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L10n.format("Archive “%@”?", session.displayTitle)
        alert.informativeText = session.kind.supportsResume
            ? L10n.string(
                "The agent will stop, and the session moves out of the sidebar into "
                    + "Settings ▸ Archived. The conversation is kept and can be restored from there."
            )
            : L10n.string(
                "The shell will stop, and the session moves out of the sidebar into "
                    + "Settings ▸ Archived, where it can be restored."
            )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("Archive"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        return alert
    }

    /// A move interrupts a running agent exactly as a surface switch does, so it asks under the
    /// same setting rather than inventing a policy of its own.
    private func confirmMoveIfRunning(sessionID: SessionID, to account: AgentAccount) -> Bool {
        guard AppSettings.shared.confirmsBeforeClosingRunningSession,
              AgentRuntime.shared.isRunning(sessionID: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return true }

        let alert = NSAlert()
        alert.messageText = L10n.format(
            "Move “%@” to %@?",
            session.displayTitle,
            AccountName.display(for: account)
        )
        alert.informativeText = L10n.string("""
            The agent stops and starts again under that account, resuming this conversation \
            where it left off. Anything it is working on right now is interrupted.
            """)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("Move"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmSurfaceSwitchIfRunning(sessionID: SessionID, toNative: Bool) -> Bool {
        guard AppSettings.shared.confirmsBeforeClosingRunningSession,
              AgentRuntime.shared.isRunning(sessionID: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return true }

        let surface = toNative ? L10n.string("Native UI") : session.kind.originalUITitle
        let alert = NSAlert()
        alert.messageText = L10n.format(
            "Show “%@” in %@?",
            session.displayTitle,
            surface
        )
        alert.informativeText = L10n.string("""
            The agent stops and starts again on the new surface, resuming this conversation \
            where it left off. Anything it is working on right now is interrupted.
            """)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("Switch UI"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
