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
    ///
    /// **Archiving asks nothing and reports afterwards.** It carried a registered confirmation
    /// for as long as the interruption was the only thing that could be said about it, and the
    /// alert stopped everybody who meant it in order to catch the one who did not. Everything
    /// the question was protecting is recoverable — the row comes back, the conversation
    /// resumes by the same id — so the honest shape is to do it, say so, and leave the way back
    /// on screen; only the turn in flight is lost, which is what the toast's detail line says.
    /// See `archiveToast(for:wasRunning:undo:)`.
    func setArchived(_ archived: Bool, for sessionID: SessionID) {
        guard archived else {
            ProjectStore.shared.setArchived(false, for: sessionID)
            sidebar.reload()
            return
        }

        guard let session = ProjectStore.shared.session(withID: sessionID) else { return }
        let wasRunning = AgentRuntime.shared.isRunning(sessionID: sessionID)
        let wasShowing = sessionID == container.currentSessionID

        container.closeTerminal(for: sessionID)
        ProjectStore.shared.setArchived(true, for: sessionID)

        if wasShowing {
            container.show(sessionID: nil)
        }
        sidebar.reload()

        sidebar.presentToast(Self.archiveToast(for: session, wasRunning: wasRunning) { [weak self] in
            self?.restore(sessionID, reselecting: wasShowing)
        })
    }

    /// The undo behind the archive toast.
    ///
    /// It puts the row back and stops there for a session that was merely listed. The one that
    /// was **on screen** is also selected again, because that is the state the archive took
    /// away: the pane went empty, and a row silently reappearing in the list while the pane
    /// stays empty is half an undo. A background session is deliberately not selected — undoing
    /// a stray click must not also move the user off what they are doing.
    ///
    /// The agent does not come back with it. Archiving stopped it, exactly as closing does, and
    /// the session opens on its dormant placeholder with Resume on it; relaunching a process
    /// behind an undo would be a heavier thing than the click being taken back.
    private func restore(_ sessionID: SessionID, reselecting: Bool) {
        ProjectStore.shared.setArchived(false, for: sessionID)
        sidebar.reload()

        guard reselecting else { return }
        sidebar.select(sessionID: sessionID)
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
            container.reopenIfShowing(sessionID: sessionID)
            let alert = NSAlert()
            alert.messageText = L10n.string("Couldn't move the conversation")
            alert.informativeText = error.message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Continues a conversation with another provider.
    ///
    /// The source agent stops so its transcript is a stable snapshot, but its session and
    /// transcript remain resumable. The destination is a new conversation whose deterministic
    /// first turn loads that snapshot through Threading's session-scoped MCP tool.
    func continueSession(_ sessionID: SessionID, with account: AgentAccount) {
        guard confirmContinuationIfRunning(sessionID: sessionID, with: account) else {
            return
        }

        AgentRuntime.shared.discard(sessionID: sessionID)
        switch ConversationContinuation.create(from: sessionID, to: account) {
        case .success(let session):
            pendingPrompt = NewChatOpeningMessage.compose(
                prompt: ConversationContinuation.openingPrompt(for: session),
                reusableMessage: AppSettings.shared.newChatOpeningMessage
            )
            sidebar.reload()
            sidebar.select(sessionID: session.id)
            onPresentationChanged()

        case .failure(let error):
            container.reopenIfShowing(sessionID: sessionID)
            let alert = NSAlert()
            alert.messageText = L10n.string("Couldn't continue the conversation")
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
        let opening = NewChatOpeningMessage.compose(
            prompt: prompt,
            reusableMessage: AppSettings.shared.newChatOpeningMessage
        )
        guard let session = ProjectStore.shared.addSideChat(of: sessionID, title: title)
        else { return }

        EventLog.shared.record(.composer, "Side chat forked", [
            "session": session.id.uuidString,
            "parent": sessionID.uuidString,
            "prompt": opening ?? ""
        ])

        pendingPrompt = opening
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

        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = NewChatOpeningMessage.compose(
            prompt: task,
            reusableMessage: AppSettings.shared.newChatOpeningMessage
        )

        guard let session = ProjectStore.shared.addSession(
            to: targetProjectID,
            kind: kind,
            accountHandle: accountHandle,
            model: model,
            usesNativeUI: usesNativeUI,
            permissionMode: permissionMode,
            title: SessionNaming.promptTitle(from: task)
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
            "prompt": opening ?? ""
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
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = NewChatOpeningMessage.compose(
            prompt: task,
            reusableMessage: AppSettings.shared.newChatOpeningMessage
        )
        guard !task.isEmpty,
              let session = ProjectStore.shared.addSession(
                to: projectID,
                kind: kind,
                accountHandle: accountHandle,
                model: model,
                reasoningEffort: reasoningEffort,
                usesNativeUI: usesNativeUI,
                title: SessionNaming.promptTitle(from: task)
              ) else { return nil }

        EventLog.shared.record(.remote, "Session started remotely", [
            "session": session.id.uuidString,
            "project": projectID.uuidString,
            "agent": kind.rawValue,
            "prompt": opening ?? "",
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
        guard AgentRuntime.shared.isRunning(sessionID: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return true }

        return ConfirmationAlert.ask(Self.closeConfirmation(for: session))
    }

    /// The request is built separately from being asked so a test can hold its wording to what
    /// the action actually does — the same seam the sidebar's menu builders offer. It says
    /// where the session ends up, since "Close" alone does not.
    static func closeConfirmation(for session: AgentSession) -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: .closeRunningSession,
            title: L10n.format("Close “%@”?", session.displayTitle),
            message: session.kind.supportsResume
                ? L10n.string(
                    "The agent will stop. The session stays in the sidebar and can be resumed."
                )
                : L10n.string("The shell will stop. The session stays in the sidebar."),
            confirmTitle: L10n.string("Close Session")
        )
    }

    /// What the archive says after the fact, where its alert used to ask beforehand.
    ///
    /// It carries the same three facts the alert did, in the order a receipt needs them: what
    /// happened and to which session, what stopped along with it, and where the session can be
    /// found once the band is gone — the sidebar lists no archived sessions at all, so nothing
    /// else on screen would say. `Undo` is last because it is the only part that is optional to
    /// read.
    ///
    /// Built separately from being shown, for the reason the confirmations are: this is where a
    /// test can hold the wording to what the action actually did.
    static func archiveToast(
        for session: AgentSession,
        wasRunning: Bool,
        undo: @escaping () -> Void
    ) -> ToastRequest {
        let whereItWent = L10n.string("Restore it from Settings ▸ Archived.")
        let stopped = session.kind.supportsResume
            ? L10n.string("The agent stopped.")
            : L10n.string("The shell stopped.")

        return ToastRequest(
            message: L10n.format("Archived “%@”", session.displayTitle),
            detail: wasRunning ? "\(stopped) \(whereItWent)" : whereItWent,
            actionTitle: L10n.string("Undo"),
            action: undo,
            identifier: "sidebar.toast.archive"
        )
    }

    /// A move interrupts a running agent exactly as a surface switch does, and each carries its
    /// own registered prompt for the same reason close and archive do.
    private func confirmMoveIfRunning(sessionID: SessionID, to account: AgentAccount) -> Bool {
        guard AgentRuntime.shared.isRunning(sessionID: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return true }

        return ConfirmationAlert.ask(ConfirmationRequest(
            prompt: .moveRunningSessionToAccount,
            title: L10n.format(
                "Move “%@” to %@?",
                session.displayTitle,
                AccountName.display(for: account)
            ),
            message: L10n.string("""
                The agent stops and starts again under that account, resuming this conversation \
                where it left off. Anything it is working on right now is interrupted.
                """),
            confirmTitle: L10n.string("Move")
        ))
    }

    private func confirmContinuationIfRunning(
        sessionID: SessionID,
        with account: AgentAccount
    ) -> Bool {
        guard AgentRuntime.shared.isRunning(sessionID: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return true }

        return ConfirmationAlert.ask(Self.continuationConfirmation(
            for: session,
            destination: account.provider
        ))
    }

    static func continuationConfirmation(
        for session: AgentSession,
        destination: AgentKind
    ) -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: .continueRunningSessionWithAnotherProvider,
            title: L10n.format(
                "Continue “%@” with %@?",
                session.displayTitle,
                destination.displayName
            ),
            message: L10n.string(
                "The current agent stops. Threading creates a new session with the other provider "
                    + "and gives it a read-only snapshot of this conversation. The original "
                    + "session stays in the sidebar and can still be resumed. Provider-specific "
                    + "state may not carry over."
            ),
            confirmTitle: L10n.string("Continue")
        )
    }

    private func confirmSurfaceSwitchIfRunning(sessionID: SessionID, toNative: Bool) -> Bool {
        guard AgentRuntime.shared.isRunning(sessionID: sessionID),
              let session = ProjectStore.shared.session(withID: sessionID) else { return true }

        let surface = toNative ? L10n.string("Native UI") : session.kind.originalUITitle
        return ConfirmationAlert.ask(ConfirmationRequest(
            prompt: .switchRunningSessionSurface,
            title: L10n.format(
                "Show “%@” in %@?",
                session.displayTitle,
                surface
            ),
            message: L10n.string("""
                The agent stops and starts again on the new surface, resuming this conversation \
                where it left off. Anything it is working on right now is interrupted.
                """),
            confirmTitle: L10n.string("Switch UI")
        ))
    }
}

// MARK: - New Chat Opening Message

/// Joins the per-chat task with the reusable message from Settings.
///
/// The task remains first so the provider sees the thing this chat is about before the standing
/// instruction, while the blank line keeps two independently-authored messages readable. The
/// caller derives the sidebar title from the task alone: a reusable instruction should not make
/// every chat start with the same name.
enum NewChatOpeningMessage {
    static func compose(prompt: String?, reusableMessage: String) -> String? {
        let parts = [prompt, reusableMessage]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }
}
