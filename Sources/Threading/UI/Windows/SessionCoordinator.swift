import AppKit

/// Session-scoped handoff between creation and the deferred sidebar presentation that launches it.
///
/// A dictionary is intentional even though the ordinary path contains one entry for less than a
/// run-loop turn. More than one newly created row can have its presentation interrupted, and a new
/// opening must not overwrite an older session's still-undelivered first turn. Storage and lookup
/// are O(changed session); nothing here is projected into the sidebar or scanned during selection.
struct PendingSessionOpeningPrompts {
    private var promptsBySessionID: [SessionID: String] = [:]

    mutating func stage(_ prompt: String?, for sessionID: SessionID) {
        guard let prompt else {
            promptsBySessionID.removeValue(forKey: sessionID)
            return
        }
        promptsBySessionID[sessionID] = prompt
    }

    mutating func take(for sessionID: SessionID) -> String? {
        promptsBySessionID.removeValue(forKey: sessionID)
    }
}

/// Owns session lifecycle decisions while the window controller owns only navigation chrome.
///
/// Creation, import, worktree targeting, surface switches, and closing all converge here so an
/// opening prompt cannot be stranded in one delegate extension while the launch happens in
/// another. The sidebar and container remain the views through which those decisions appear.
@MainActor
final class SessionCoordinator: SessionComposerViewControllerDelegate {

    typealias ArchiveStateSetter = (
        _ archived: Bool,
        _ sessionID: SessionID,
        _ completion: @escaping ProviderArchiveSync.Completion
    ) -> Void

    /// Not private: `SessionCoordinator+ScheduledMessages` performs a due send against the same
    /// two surfaces every other lifecycle decision here goes through, and a scheduled start that
    /// reached for its own sidebar would be a second answer to "where does a session appear".
    let sidebar: ProjectSidebarViewController
    let container: TerminalContainerViewController
    let environment: AppEnvironment
    let onPresentationChanged: () -> Void
    private let archiveStateSetter: ArchiveStateSetter
    /// Window composition routes sidebar receipts through the swappable navigator shell. Tests
    /// and standalone hosts default to the native sidebar presenter.
    let toastPresenter: (ToastRequest) -> Void

    /// Opening messages waiting for the session they belong to to be presented.
    ///
    /// Sidebar presentation is deliberately deferred by one main-queue turn. Another selection
    /// can cancel that presentation before the container sees it, so this cannot be one global
    /// "next selection" slot: that would let the unrelated selection consume the opening and
    /// leave the new session to launch without its first turn when it is selected later.
    private var pendingPrompts = PendingSessionOpeningPrompts()

    /// One network publication per session. The generated ref makes retries idempotent across
    /// launches; this gate also prevents two finish notifications in the same launch from
    /// racing through discovery and both attempting review creation.
    private var managedWorkspacePublications: Set<SessionID> = []

    /// Native rows leave optimistically, but a customizable row may remain visible until its
    /// facts update. This is therefore the mutation fence, not the presentation: one provider
    /// archive may be in flight for a session, and only its completion clears the pending row.
    private var archiveSessionIDsInFlight: Set<SessionID> = []

    /// Released with this coordinator, which the window owns for its own lifetime.
    private let appEvents = AppEventObservations()

    init(
        sidebar: ProjectSidebarViewController,
        container: TerminalContainerViewController,
        environment: AppEnvironment,
        onPresentationChanged: @escaping () -> Void,
        archiveStateSetter: @escaping ArchiveStateSetter = { archived, sessionID, completion in
            ProviderArchiveSync.shared.setArchived(
                archived,
                for: sessionID,
                completion: completion
            )
        },
        toastPresenter: ((ToastRequest) -> Void)? = nil
    ) {
        self.sidebar = sidebar
        self.container = container
        self.environment = environment
        self.onPresentationChanged = onPresentationChanged
        self.archiveStateSetter = archiveStateSetter
        self.toastPresenter = toastPresenter ?? { sidebar.presentToast($0) }

        // An agent asked to be done with its session, and its turn has now ended. It arrives as
        // an announcement rather than a call because `SessionArchiveScheduler` is in Core and
        // knows nothing about sidebars — and it is observed *here*, in the type that already
        // owns every other lifecycle decision, rather than relayed through the window
        // controller, which would only be passing it straight back down. See
        // `archiveAtAgentRequest(_:reason:)`.
        appEvents.observe(SessionArchiveRequestDidBecomeDue.self) { [weak self] event in
            self?.archiveAtAgentRequest(
                event.sessionID,
                reason: event.reason,
                requestedByManagerID: event.requestedByManagerID
            )
        }

        // The same arrangement again: `SessionExecutionLocusTracker` is in Core and owns only
        // the observation. What to do about a chat found working in another checkout is a
        // policy decision with a confirmation and a receipt attached, so it is decided here.
        // See `reconcileObservedExecutionDrift(_:)`.
        appEvents.observe(SessionExecutionDriftDidChange.self) { [weak self] event in
            self?.reconcileObservedExecutionDrift(event.sessionID)
        }
        appEvents.observe(SessionCheckoutDidMove.self) { [weak self] event in
            guard event.authorityBasis == .observedExecution,
                  let self,
                  let session = self.environment.projectStore.session(withID: event.sessionID)
            else { return }
            self.toastPresenter(Self.observedMoveCompletedToast(
                for: session,
                checkoutDisplayName: event.checkoutDisplayName,
                requestID: event.requestID
            ))
        }
        appEvents.observe(SessionCheckoutMoveDidFail.self) { [weak self] event in
            guard let self,
                  let session = self.environment.projectStore.session(withID: event.sessionID)
            else { return }
            self.toastPresenter(Self.checkoutMoveFailedToast(
                for: session,
                event: event,
                retry: {
                    SessionCheckoutCoordinator.shared.retryPendingMove(
                        sessionID: event.sessionID
                    )
                }
            ))
        }

        // The same arrangement, one feature along: `ScheduledMessageScheduler` is in Core and
        // owns only the clock. See `SessionCoordinator+ScheduledMessages`.
        appEvents.observe(ScheduledMessageDidBecomeDue.self) { [weak self] event in
            self?.performScheduledSend(event.id)
        }

        // And once more: the strip offering a way past a spent usage limit lives inside a
        // session's own pane and knows nothing about migrating, reopening or scheduling. See
        // `SessionCoordinator+LimitEscape`.
        appEvents.observe(LimitEscapeRequested.self) { [weak self] event in
            self?.performLimitEscape(for: event.sessionID)
        }

        // The same move with nobody pressing for it: `LimitRecoveryPolicy.resumeOnBestAccount` and
        // `resumeVia(_:)` have already chosen the login on forced readings, and what is left is
        // the migration itself — the press's own routine, which is why this lands here too.
        appEvents.observe(LimitAccountResumeRequested.self) { [weak self] event in
            self?.performAutomaticLimitEscape(for: event.sessionID, to: event.accountID)
        }

        // The strip's other answer goes straight to the recovery coordinator instead: waiting
        // for the reset moves no conversation and reopens no pane, and it is the same routine
        // the automatic policy runs. Observed here only because this is where the pane's
        // announcements are picked up.
        appEvents.observe(LimitWaitForResetRequested.self) { event in
            LimitRecoveryCoordinator.shared.armWaitForReset(for: event.sessionID)
        }

        appEvents.observe(LimitBankedResetRequested.self) { [weak self] event in
            self?.performBankedUsageReset(for: event.sessionID)
        }

        // And once more, for the clock the user set: `SessionCurfewCenter` owns when a curfew's
        // grace has run out and announces it, because stopping a turn is a gesture on a
        // conversation surface and Core's ratchet on concrete controllers is exact. What became
        // of the stop goes straight back, since that is what the curfew counts.
        appEvents.observe(CurfewInterruptRequested.self) { [weak self] event in
            self?.interruptForCurfew(event.sessionID)
        }
    }

    /// Ends the turn a curfew has run out of patience with, and reports what happened.
    private func interruptForCurfew(_ sessionID: SessionID) {
        guard let conversation = environment.agentRuntime.conversation(for: sessionID) else {
            return
        }
        conversation.stopCurrentTurn { receipt in
            SessionCurfewCenter.shared.noteInterruptOutcome(
                sessionID: sessionID,
                receipt: receipt
            )
        }
    }

    func takePendingPrompt(for sessionID: SessionID) -> String? {
        pendingPrompts.take(for: sessionID)
    }

    func newSession() {
        let projectID: ProjectID?
        if let sessionID = container.currentSessionID {
            projectID = environment.projectStore.project(forSessionID: sessionID)?.id
        } else {
            projectID = environment.projectStore.projects.first?.id
        }

        guard let projectID else {
            // No projects yet: land in the composer's choose-a-project mode rather than a bare
            // folder panel — the chip offers both existing folders and new ones.
            container.showComposer(projectID: nil)
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
        guard let project = environment.projectStore.addProject(folderURL: url) else { return }
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
    @discardableResult
    func setArchived(
        _ archived: Bool,
        for sessionID: SessionID
    ) -> Bool {
        guard archived else {
            restore(sessionID, reselecting: false)
            return true
        }

        // A person filing an unfinished managed session is not the finish handshake. Preserve
        // its checkout explicitly; only the agent's post-turn archive route validates, merges
        // and removes it.
        if let workspace = environment.projectStore.session(withID: sessionID)?.managedWorkspace,
           workspace.state == .active {
            environment.projectStore.update(sessionID: sessionID) {
                $0.managedWorkspace = ManagedGitWorkspace.keepForReview(workspace)
            }
        }

        return archive(
            sessionID,
            receipt: { session, wasRunning, undo in
                Self.archiveToast(for: session, wasRunning: wasRunning, undo: undo)
            }
        )
    }

    /// Files a session away because its own agent asked to be done with it.
    ///
    /// The same action as the menu's Archive, and deliberately not a quieter one: the row goes,
    /// the agent stops, and the way back is on screen. What differs is the receipt, which has to
    /// say *who* acted and to hold longer for it — nobody just clicked anything, and the user
    /// asked for this a turn ago, in words, and has been reading something else since. See
    /// `agentArchiveToast(for:reason:wasRunning:undo:)`.
    ///
    /// Arriving here at all means the request already waited for the turn to end
    /// (`SessionArchiveScheduler`); this is only the archive.
    func archiveAtAgentRequest(
        _ sessionID: SessionID,
        reason: String?,
        requestedByManagerID managerID: SessionID? = nil
    ) {
        if let workspace = environment.projectStore.session(withID: sessionID)?.managedWorkspace {
            if workspace.publication != nil {
                publishManagedWorkspaceAndArchive(
                    workspace,
                    sessionID: sessionID,
                    reason: reason,
                    requestedByManagerID: managerID
                )
                return
            }
            switch ManagedGitWorkspace.finishLocalDelivery(workspace) {
            case .completed(let completed):
                environment.projectStore.update(sessionID: sessionID) {
                    $0.managedWorkspace = completed
                }

            case .needsAttention(let failed):
                let message = failed.lastError
                    ?? L10n.string("Managed workspace needs attention")
                environment.projectStore.update(sessionID: sessionID) {
                    $0.managedWorkspace = failed
                }
                toastPresenter(ToastRequest(
                    message: L10n.string("Managed workspace needs attention"),
                    detail: message,
                    identifier: "sidebar.toast.managed-workspace.failed"
                ))
                environment.eventLog.record(.session, "Managed workspace integration refused", [
                    "session": sessionID.uuidString,
                    "reason": message
                ])
                return
            }
        }

        finishAgentRequestedArchive(
            sessionID,
            reason: reason,
            requestedByManagerID: managerID
        )
    }

    private func finishAgentRequestedArchive(
        _ sessionID: SessionID,
        reason: String?,
        requestedByManagerID managerID: SessionID?
    ) {
        archive(
            sessionID,
            receipt: { session, wasRunning, undo in
                Self.agentArchiveToast(
                    for: session,
                    reason: reason,
                    wasRunning: wasRunning,
                    undo: undo
                )
            },
            onArchived: {
                if let managerID {
                    _ = ControlGrantStore.shared.archive(childID: sessionID, by: managerID)
                }
                // The band is on screen for fourteen seconds and then the row is simply gone. A
                // session filed away by something other than a click is exactly the change the
                // durable journal exists to answer for afterwards.
                self.environment.eventLog.record(.session, "Session archived by its agent", [
                    "session": sessionID.uuidString,
                    "reason": reason ?? "none"
                ])
            },
            onArchiveFailed: { [weak self] in
                self?.recoverManagedWorkspaceAfterArchiveFailure(sessionID)
            }
        )
    }

    /// Remote publication is the second opt-in, and therefore the only managed finish that may
    /// cross the network. The review receipt is persisted before local disposal so a crash or a
    /// cleanup refusal can retry by discovering the same generated branch rather than creating
    /// a duplicate change request.
    private func publishManagedWorkspaceAndArchive(
        _ workspace: ManagedWorkspace,
        sessionID: SessionID,
        reason: String?,
        requestedByManagerID managerID: SessionID?
    ) {
        guard managedWorkspacePublications.insert(sessionID).inserted else { return }
        let publisher = ManagedWorkspacePublisher.live()
        Task { [weak self] in
            guard let self else { return }
            defer { self.managedWorkspacePublications.remove(sessionID) }
            do {
                let result = try await publisher.publish(workspace)
                guard let session = environment.projectStore.session(withID: sessionID),
                      var recorded = session.managedWorkspace,
                      recorded.worktreeRoot == workspace.worktreeRoot else { return }

                recorded.finalCommit = result.finalCommit
                recorded.changeRequest = result.changeRequest
                recorded.remoteBranchState = .awaitingReviewCompletion
                recorded.lastError = nil
                environment.projectStore.update(sessionID: sessionID) {
                    $0.managedWorkspace = recorded
                }

                if result.wasCreated {
                    ChangeRequestReceiptStore.shared.append(ChangeRequestReceipt(
                        date: Date(),
                        action: result.changeRequest.isDraft ? .createdDraft : .createdReady,
                        repository: result.changeRequest.repository,
                        branch: result.changeRequest.branch,
                        url: result.changeRequest.url,
                        credentialSource: result.credentialSource
                    ))
                }

                // A person may have archived the row while publication was in flight. Manual
                // archive means preserve the checkout; retain the remote receipt without
                // overriding that newer choice or filing the session a second time.
                guard !session.isArchived, recorded.state != .kept else { return }

                let completed = try ManagedGitWorkspace.cleanPublished(recorded)
                environment.projectStore.update(sessionID: sessionID) {
                    $0.managedWorkspace = completed
                }
                self.finishAgentRequestedArchive(
                    sessionID,
                    reason: reason,
                    requestedByManagerID: managerID
                )
            } catch {
                self.recordManagedWorkspaceFailure(
                    sessionID: sessionID,
                    message: error.localizedDescription,
                    event: "Managed workspace publication refused"
                )
            }
        }
    }

    private func recordManagedWorkspaceFailure(
        sessionID: SessionID,
        message: String,
        event: String
    ) {
        var shouldPresent = false
        environment.projectStore.update(sessionID: sessionID) {
            guard var failed = $0.managedWorkspace,
                  failed.state != .kept,
                  failed.state != .published else { return }
            failed.state = .needsAttention
            failed.lastError = message
            $0.managedWorkspace = failed
            shouldPresent = true
        }
        guard shouldPresent else { return }
        toastPresenter(ToastRequest(
            message: L10n.string("Managed workspace needs attention"),
            detail: message,
            identifier: "sidebar.toast.managed-workspace.failed"
        ))
        environment.eventLog.record(.session, event, [
            "session": sessionID.uuidString,
            "reason": message
        ])
    }

    /// Archiving the repair chat once its work has been accepted.
    ///
    /// The receipt names the *repaired* conversation rather than the row that is leaving, because
    /// that is what the user pressed a button about. Everything else — agent first, provider
    /// before the local row — is `archive`'s, unchanged.
    func archiveAfterRecovery(
        _ sessionID: SessionID,
        repaired title: String,
        onReport: @escaping () -> Void
    ) {
        archive(sessionID, receipt: { _, _, _ in
            ToastRequest(
                message: L10n.format("Repaired “%@”", title),
                detail: L10n.string("The repair chat has been filed away."),
                actionTitle: L10n.string("Report This…"),
                action: onReport,
                identifier: "sidebar.toast.archive.afterRecovery"
            )
        })
    }

    /// Archiving, with the receipt left to the caller.
    ///
    /// The process/provider order remains load-bearing: the agent stops before a provider moves
    /// its rollout, and the durable flag changes only after both sides agree. Presentation does
    /// not wait on that transaction. The row and, when applicable, its pane leave at the press
    /// edge; a refusal puts the row back from the unchanged durable record.
    @discardableResult
    private func archive(
        _ sessionID: SessionID,
        receipt: @escaping (AgentSession, Bool, @escaping () -> Void) -> ToastRequest,
        onArchived: @escaping () -> Void = {},
        onArchiveFailed: @escaping () -> Void = {}
    ) -> Bool {
        guard let session = environment.projectStore.session(withID: sessionID),
              !session.isArchived else { return false }
        // Repeated presses while the same durable transaction is pending are an accepted no-op,
        // not a missing target. The caller must not turn that benign race into an error toast.
        guard archiveSessionIDsInFlight.insert(sessionID).inserted else { return true }

        let wasRunning = environment.agentRuntime.isRunning(sessionID: sessionID)
        let presentation = Self.archivePresentationResolution(
            archivedSessionID: sessionID,
            visibleSessionID: container.currentSessionID,
            selectedSessionID: environment.projectStore.selectedSessionID
        )
        sidebar.setArchivePresentationPending(true, for: sessionID)
        if presentation.clearsVisibleSession {
            container.show(sessionID: nil)
        }
        archiveStateSetter(true, sessionID) { [weak self] result in
            guard let self else { return }
            archiveSessionIDsInFlight.remove(sessionID)
            sidebar.setArchivePresentationPending(false, for: sessionID)
            switch result {
            case .success:
                let toast = receipt(session, wasRunning) { [weak self] in
                    self?.restore(
                        sessionID,
                        reselecting: presentation.reselectsOnUndo
                    )
                }
                toastPresenter(toast)
                onArchived()
            case .failure(let failure):
                // A failure may arrive after another row was selected. Only rebuild the pane
                // this archive itself cleared, and only while its persisted selection still
                // proves nothing newer owns the workspace.
                if presentation.clearsVisibleSession,
                   container.currentSessionID == nil,
                   environment.projectStore.selectedSessionID == sessionID {
                    sidebar.select(sessionID: sessionID)
                }
                onArchiveFailed()
                let toast = Self.archiveFailureToast(
                    for: session,
                    failure: failure,
                    wasRunning: wasRunning
                )
                toastPresenter(toast)
            }
        }
        return true
    }

    /// Resolves navigation at the archive presentation edge. A newer selection owns the pane
    /// and must survive the older archive's eventual completion or failure.
    ///
    /// The archive-state event can clear the target before this completion runs. In that case
    /// the persisted sidebar selection is the evidence that this archive took the page away and
    /// that Undo should restore it. An explicit move to another session updates that selection,
    /// so the archived page cannot reclaim focus from its replacement.
    static func archivePresentationResolution(
        archivedSessionID: SessionID,
        visibleSessionID: SessionID?,
        selectedSessionID: SessionID?
    ) -> (clearsVisibleSession: Bool, reselectsOnUndo: Bool) {
        if visibleSessionID == archivedSessionID {
            let stillSelected = selectedSessionID == nil
                || selectedSessionID == archivedSessionID
            return (stillSelected, stillSelected)
        }
        if visibleSessionID == nil, selectedSessionID == archivedSessionID {
            return (false, true)
        }
        return (false, false)
    }

    /// Integration happens before provider filing because the process must still have reached
    /// its final turn before repository state moves. If provider filing then refuses, put the
    /// removed cwd back so the still-visible session remains launchable.
    private func recoverManagedWorkspaceAfterArchiveFailure(_ sessionID: SessionID) {
        guard let workspace = environment.projectStore.session(withID: sessionID)?.managedWorkspace
        else { return }
        do {
            let active = try ManagedGitWorkspace.restore(workspace)
            environment.projectStore.update(sessionID: sessionID) {
                $0.managedWorkspace = active
            }
        } catch {
            let message = error.localizedDescription
            environment.projectStore.update(sessionID: sessionID) {
                guard var failed = $0.managedWorkspace else { return }
                failed.state = .needsAttention
                failed.lastError = message
                $0.managedWorkspace = failed
            }
            toastPresenter(ToastRequest(
                message: L10n.string("Couldn’t restore the managed workspace"),
                detail: message,
                identifier: "sidebar.toast.managed-workspace.archive-recovery.failed"
            ))
        }
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
        let session = environment.projectStore.session(withID: sessionID)

        if let workspace = session?.managedWorkspace,
           workspace.state == .integrated
            || workspace.state == .published
            || workspace.state == .kept {
            do {
                let restored = try ManagedGitWorkspace.restore(workspace)
                environment.projectStore.update(sessionID: sessionID) {
                    $0.managedWorkspace = restored
                }
            } catch {
                toastPresenter(ToastRequest(
                    message: L10n.string("Couldn’t restore the managed workspace"),
                    detail: error.localizedDescription,
                    identifier: "sidebar.toast.managed-workspace.restore.failed"
                ))
                return
            }
        }

        archiveStateSetter(false, sessionID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                guard reselecting else { return }
                sidebar.select(sessionID: sessionID)
            case .failure(let failure):
                toastPresenter(Self.restoreFailureToast(
                    for: session,
                    failure: failure
                ))
            }
        }
    }

    // MARK: - Naming

    /// Whether this session can be asked to name itself, which decides whether the menu offers
    /// it at all rather than offering it greyed out.
    ///
    /// Three conditions, and the third is the one that is easy to miss: with the session tool
    /// group switched off on the Tools page the agent has no `set_session_name` to call, so the
    /// request would spend a turn on an instruction it cannot carry out.
    static func canAskAgentToRename(
        _ sessionID: SessionID,
        agentRuntime: AgentRuntime
    ) -> Bool {
        agentRuntime.isRunning(sessionID: sessionID)
            && agentRuntime.runtimeSnapshot(sessionID: sessionID).isPromptReady
            && MCPToolCatalog.isEnabled(MCPToolCatalog.session)
    }

    /// Asks the session's own agent to rename it, by sending it one line.
    ///
    /// The agent already holding the conversation is the cheapest thing that can name it: the
    /// context sits on the provider's side and has been paid for once, so this costs one short
    /// turn against a warm cache. The two alternatives both pay again for what this agent
    /// already knows — a fork copies the whole transcript and replays it cold, and a headless
    /// run buys a fresh system prompt and tool schemas to be told the same thing.
    ///
    /// Offered only between turns (`canAskAgentToRename`). Text sent into a working agent lands
    /// in whatever it has on screen — a permission prompt, a half-typed composer line — so the
    /// item is absent rather than disabled while a turn is in flight.
    func askAgentToRename(_ sessionID: SessionID) {
        guard Self.canAskAgentToRename(
            sessionID,
            agentRuntime: environment.agentRuntime
        ) else { return }

        let prompt = L10n.string(SessionRenameRequest.promptKey)

        // Both caches can hold the same session — a surface switch leaves the old renderer
        // behind — so each candidate is asked whether it is the one still running rather than
        // native being assumed to win. Its stream applies the same validation the composer does.
        if let conversation = environment.agentRuntime.conversation(for: sessionID),
           conversation.isRunning {
            conversation.sendAppPrompt(prompt)
            return
        }

        // A PTY has no send-or-refuse — the text is typed in, and the carriage return is what
        // submits it, exactly as the user pressing Return would. In two writes, not one:
        // arriving in the same chunk as the text, the return is part of what the CLI's paste
        // heuristic treats as pasted content, and Claude Code inserts it as a line break with
        // the request left sitting unsent in its composer. A beat later it is a keypress.
        guard let controller = environment.agentRuntime.controller(for: sessionID),
              controller.isRunning else { return }
        controller.session.insertText(prompt)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SessionRenameRequest.submitDelay
        ) { [weak self] in
            guard let controller = self?.environment.agentRuntime.controller(for: sessionID),
                  controller.isRunning else { return }
            controller.session.insertText(SessionRenameRequest.submitKey)
        }
    }

    // MARK: - Reporting Back

    /// Whether this side chat can be asked to send its conclusion to the session it was forked
    /// from — which decides whether the menu offers it at all, absent rather than greyed.
    ///
    /// The rename gate's conditions, plus lineage: this is a side chat, its parent is still an
    /// unarchived row to deliver to, and the workspace tool group is on — with it off the agent
    /// has no `send_to_session` to call, and the request would spend a turn on an instruction
    /// it cannot carry out. Readiness is `SessionMessageDelivery`'s own answer, so the item
    /// cannot offer a send the delivery would then refuse (a booting terminal, most narrowly).
    static func canAskForReportBack(
        _ sessionID: SessionID,
        projectStore: ProjectStore,
        agentRuntime: AgentRuntime
    ) -> Bool {
        SessionReportBackRequest.hasReportableParent(
            of: projectStore.session(withID: sessionID),
            parent: { projectStore.session(withID: $0) }
        )
            && agentRuntime.runtimeSnapshot(sessionID: sessionID).isPromptReady
            && SessionMessageDelivery.isReadyForDelivery(sessionID)
            && MCPToolCatalog.isEnabled(MCPToolCatalog.workspace)
    }

    /// Asks the side chat's own agent to report its conclusion to its parent, by sending it
    /// one line naming `send_to_session` and the parent's id.
    ///
    /// The same reasoning as `askAgentToRename`: the agent holding the conversation is the
    /// cheapest thing that can summarize it, and the request goes through the ordinary input
    /// path so it is echoed into the transcript as a user turn — visible, correctable, and
    /// openly spending the user's usage. The delivery itself then carries Threading's
    /// provenance header into the parent, exactly as any cross-session message does.
    /// **The receipt form, and a receipt on screen when it fails.** The gate passed a moment
    /// ago, which is not the same as the request landing: a side chat mid-`/compact` swallows
    /// the paste and reports no turn, and the earlier shape — the synchronous overload, its
    /// outcome discarded — left the user believing they had asked for something that was never
    /// asked. Success stays silent because the transcript shows it; only a failure needs words.
    func askAgentToReportBack(_ sessionID: SessionID) {
        guard Self.canAskForReportBack(
            sessionID,
            projectStore: environment.projectStore,
            agentRuntime: environment.agentRuntime
        ),
              let session = environment.projectStore.session(withID: sessionID),
              let parentID = session.forkedFrom
        else { return }

        SessionMessageDelivery.deliver(
            SessionReportBackRequest.prompt(parentID: parentID),
            to: sessionID
        ) { [weak self] outcome in
            guard let self, let detail = Self.reportBackFailure(outcome) else { return }
            self.toastPresenter(ToastRequest(
                message: L10n.format("Couldn’t ask “%@” to report back", session.displayTitle),
                detail: detail,
                identifier: "sidebar.toast.reportBack.failed"
            ))
        }
    }

    /// What to say about a report-back request that did not land, or nil where it did.
    static func reportBackFailure(_ outcome: SessionMessageDelivery.Outcome) -> String? {
        switch outcome {
        case .sentNow, .queuedBehindTurn:
            return nil
        case .typedUnconfirmed:
            return L10n.string(
                "It was typed into the session, which never confirmed a turn started."
            )
        case .busyTerminal, .noLiveSurface, .notTaken:
            return L10n.string("Its agent could not take the request. Try again when it is idle.")
        }
    }

    func setUsesNativeUI(_ usesNative: Bool, for sessionID: SessionID) {
        guard confirmSurfaceSwitchIfRunning(sessionID: sessionID, toNative: usesNative) else {
            return
        }

        let result = environment.projectStore.setUsesNativeUI(usesNative, for: sessionID)
        guard result == .applied else { return }

        // The old process remains authoritative until the surface choice is durable. Stopping it
        // first turns a refused SQLite write into a dead session whose stored surface never moved.
        environment.agentRuntime.discard(sessionID: sessionID)
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
        moveSessionWithoutConfirmation(sessionID, to: account)
    }

    /// The same move, for a caller whose own control already named the whole action.
    ///
    /// The confirmation exists because a menu item reading "Nova Hartley" says nothing about
    /// stopping the agent; the usage-limit escape's button says *Continue as Nova Hartley* on
    /// its face and is pressed by somebody looking at a session that has already stopped, so a
    /// second dialog would only ask them to agree with what they just pressed.
    ///
    /// `alertingOnFailure` is the one thing an unattended caller changes. A move that could not be
    /// saved is news to whoever asked for it — but a `LimitRecoveryPolicy` asked hours ago and is
    /// not in the room, and a modal alert with nobody to dismiss it stops the application until
    /// somebody comes back. That caller reports the failure through its own surfaces instead; see
    /// `SessionCoordinator+LimitEscape`.
    @discardableResult
    func moveSessionWithoutConfirmation(
        _ sessionID: SessionID,
        to account: AgentAccount,
        alertingOnFailure: Bool = true
    ) -> Bool {
        switch SessionMigration.move(sessionID: sessionID, to: account) {
        case .success:
            container.reopenIfShowing(sessionID: sessionID)
            sidebar.reload()
            onPresentationChanged()
            return true
        case .failure(let error):
            container.reopenIfShowing(sessionID: sessionID)
            guard alertingOnFailure else { return false }
            let alert = ThemedAlert()
            alert.messageText = L10n.string("Couldn't move the conversation")
            alert.informativeText = error.message
            alert.alertStyle = .warning
            alert.runModal()
            return false
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

        ConversationContinuation.create(from: sessionID, to: account) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let session):
                self.pendingPrompts.stage(
                    NewChatOpeningMessage.compose(
                        prompt: ConversationContinuation.openingPrompt(for: session),
                        prefix: environment.settings.newChatOpeningPrefix,
                        suffix: environment.settings.newChatOpeningSuffix
                    ),
                    for: session.id
                )
                self.sidebar.reload()
                self.sidebar.select(sessionID: session.id)
                self.onPresentationChanged()

            case .failure(let error):
                self.container.reopenIfShowing(sessionID: sessionID)
                let alert = ThemedAlert()
                alert.messageText = L10n.string("Couldn't continue the conversation")
                alert.informativeText = error.message
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    func createSideChat(of sessionID: SessionID, prompt: String?) {
        // "Ask on the Side" carries its question, which names the chat the same way the
        // composer's prompt names an ordinary session. A plain fork stays "Side Chat" until
        // its first prompt does.
        let title = prompt.flatMap(SessionNaming.promptTitle(from:))
        let opening = NewChatOpeningMessage.compose(
            prompt: prompt,
            prefix: environment.settings.newChatOpeningPrefix,
            suffix: environment.settings.newChatOpeningSuffix
        )
        guard let session = environment.projectStore.addSideChat(of: sessionID, title: title)
        else { return }

        environment.eventLog.record(.composer, "Side chat forked", [
            "session": session.id.uuidString,
            "parent": sessionID.uuidString,
            "prompt": opening ?? ""
        ])

        pendingPrompts.stage(opening, for: session.id)
        sidebar.reload()
        sidebar.select(sessionID: session.id)
    }

    // MARK: - Composer

    @discardableResult
    func sessionComposer(
        _ composer: SessionComposerViewController,
        reserveScheduledStart message: ScheduledMessage
    ) -> Bool {
        guard let session = ScheduledSessionReservation.reserve(
            message,
            in: environment.projectStore
        ) else { return false }

        if case .newSession(let plan) = message.target,
           plan.role == .manager,
           ControlGrantStore.shared.conferManager(
               sessionID: session.id,
               origin: .newManagerTemplate
           ) == nil {
            _ = environment.projectStore.removeSession(id: session.id)
            return false
        }

        environment.eventLog.record(.composer, "Scheduled session reserved", [
            "session": session.id.uuidString,
            "prompt": message.text
        ])
        sidebar.reload()
        sidebar.select(sessionID: session.id)
        onPresentationChanged()
        return true
    }

    func sessionComposer(
        _ composer: SessionComposerViewController,
        startScheduledMessageNow id: ScheduledMessageID
    ) {
        startScheduledMessageNow(id)
    }

    @discardableResult
    func sessionComposer(
        _ composer: SessionComposerViewController,
        startSessionIn projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle,
        model: String?,
        reasoningEffort: String?,
        fastMode: Bool?,
        branch: String?,
        usesNativeUI: Bool,
        permissionMode: AgentPermissionMode?,
        managedWorkspacePlan: ManagedWorkspacePlan?,
        role: SessionRole,
        prompt: String,
        attachmentPaths: [String],
        curfew: ScheduledCurfewPlan?
    ) -> Bool {
        let targetProjectID = Self.targetProjectID(
            startingAt: projectID,
            branch: branch,
            checkout: environment.projectStore.checkout(onBranch:inRepositoryOf:)
        )

        guard let targetProject = environment.projectStore.project(withID: targetProjectID) else {
            presentSessionStartFailure(in: composer)
            return false
        }
        if let folderFailure = ProjectLaunchPreflight.failure(
            forFolderPath: targetProject.folderPath
        ) {
            environment.eventLog.record(.composer, "Session start refused", [
                "project": targetProjectID.uuidString,
                "cause": folderFailure.knownCause
            ])
            toastPresenter(Self.sessionStartFolderFailureToast(folderFailure))
            return false
        }

        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var opening = NewChatOpeningMessage.compose(
            prompt: task,
            prefix: environment.settings.newChatOpeningPrefix,
            suffix: environment.settings.newChatOpeningSuffix
        )

        let sessionID = SessionID()
        // Named once and used twice: the sidebar row and, for a managed session, the checkout
        // the agent spends the whole conversation standing in.
        let title = SessionNaming.promptTitle(from: task)
        let managedWorkspace: ManagedWorkspace?
        if let managedWorkspacePlan {
            guard ManagedWorkspaceEligibility.supportsFinishHandshake(
                kind: kind,
                usesNativeUI: usesNativeUI
            ) else {
                let alert = ThemedAlert()
                alert.messageText = L10n.string("Could not create managed workspace")
                alert.informativeText = L10n.string(
                    "Managed workspaces require an agent surface with Threading session tools."
                )
                alert.alertStyle = .warning
                if let window = composer.view.window {
                    alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
                return false
            }
            do {
                managedWorkspace = try ManagedGitWorkspace.provision(
                    sessionID: sessionID,
                    from: targetProject,
                    plan: managedWorkspacePlan,
                    title: title
                )
                opening = ManagedWorkspaceInstructions.append(
                    to: opening,
                    plan: managedWorkspacePlan
                )
            } catch {
                let alert = ThemedAlert()
                alert.messageText = L10n.string("Could not create managed workspace")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                if let window = composer.view.window {
                    alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
                return false
            }
        } else {
            managedWorkspace = nil
        }

        guard let session = environment.projectStore.addSession(
            to: targetProjectID,
            kind: kind,
            accountHandle: accountHandle,
            model: model,
            reasoningEffort: reasoningEffort,
            fastMode: fastMode,
            usesNativeUI: usesNativeUI,
            permissionMode: permissionMode,
            title: title,
            managedWorkspace: managedWorkspace,
            id: sessionID
        ) else {
            if let managedWorkspace {
                try? ManagedGitWorkspace.discardUnstarted(managedWorkspace)
            }
            presentSessionStartFailure(in: composer)
            return false
        }

        if role == .manager,
           ControlGrantStore.shared.conferManager(
               sessionID: session.id,
               origin: .newManagerTemplate
           ) == nil {
            _ = environment.projectStore.removeSession(id: session.id)
            if let managedWorkspace { try? ManagedGitWorkspace.discardUnstarted(managedWorkspace) }
            presentSessionStartFailure(in: composer)
            return false
        }

        // Armed now the session exists, and never before it: the draft carried a *plan*, and a
        // curfew belongs to a conversation somebody can see, hold and lift.
        armCurfew(curfew, forSessionID: session.id)

        // The mode is recorded as chosen — nil included, which reads as "inherit" rather than
        // as a mode. Reading the resolved flag back belongs to the "Launching agent" entry,
        // which carries the whole command line.
        environment.eventLog.record(.composer, "Session started from composer", [
            "session": session.id.uuidString,
            "project": targetProjectID.uuidString,
            "agent": kind.rawValue,
            "account": accountHandle.name,
            "reasoningEffort": reasoningEffort ?? "inherit",
            "speed": fastMode.map { $0 ? "fast" : "standard" } ?? "inherit",
            "permissionMode": permissionMode?.rawValue ?? "inherit",
            "prompt": opening ?? ""
        ])

        // Filed the moment the session exists, through the same declared door a drop on a running
        // terminal uses. This was the one user handoff that showed a picture, sent its path, and
        // recorded nothing: the opening prompt's images were the only ones a session could never
        // show back, and the temporary file the path points at outlives the turn by nothing.
        if !attachmentPaths.isEmpty,
           let folder = environment.projectStore.workingDirectory(forSessionID: session.id) {
            PromptAttachment.record(
                paths: attachmentPaths,
                sessionID: session.id,
                projectRoot: URL(fileURLWithPath: folder, isDirectory: true),
                turnPlacement: .next
            )
        }

        // The box just typed in becomes the box the conversation replies from. Only from here,
        // and only where the surface arriving has a box to become: a terminal start, a resume,
        // a sidebar click and a remote start all reach the same attach with nothing on screen
        // to move. Marked before the selection that performs that attach, and spent by it — see
        // `TerminalContainerViewController.consumeComposerHandoff(for:)`.
        if session.usesNativeUI, session.kind.supportsNativeUI {
            container.prepareComposerHandoff(for: session.id)
        }

        DraftStore.shared.clear(for: projectID)
        pendingPrompts.stage(opening, for: session.id)
        sidebar.reload()
        sidebar.select(sessionID: session.id)
        return true
    }

    /// Turns every refused Start press — button or Command-Return, which share this path — into
    /// visible feedback while leaving the brief intact. A full-volume refusal offers the only
    /// recovery this process can safely perform; every other persistence refusal stays closed.
    private func presentSessionStartFailure(in composer: SessionComposerViewController) {
        let reason = environment.projectStore.persistenceBlockReason
        let retry: (() -> Void)? = reason == .storageExhausted ? { [weak self, weak composer] in
            // The presenter's action dismisses its current band after invoking this closure.
            // Continue on the next main-actor turn so a recovery failure can put the standing
            // report back without that dismissal immediately taking the replacement with it.
            Task { @MainActor [weak self, weak composer] in
                guard let self, let composer else { return }
                guard self.environment.projectStore.recoverFromStorageExhaustion() else {
                    self.presentSessionStartFailure(in: composer)
                    return
                }
                composer.startTapped()
            }
        } : nil

        toastPresenter(Self.sessionStartFailureToast(reason: reason, retry: retry))
    }

    /// Turns the end a draft chose into the rule a live session runs under.
    ///
    /// **After the session exists, and only then.** A plan is an intention about a conversation
    /// that may never happen — a scheduled start can be cancelled, an immediate one can fail on a
    /// blocked store — and a curfew armed on either would be a rule holding nothing, which nobody
    /// can see and nobody can lift.
    ///
    /// A plan that names no moment by the time it fires is **journalled and dropped**, never
    /// forced: a wall-clock end that has already passed would hold the session from its first
    /// breath, which is not what "end it at four" asked for, and a standing window switched off
    /// in the meantime names nothing at all. The next morning's question is *why did this session
    /// have no curfew*, and the answer is in `EventLog(.curfew)`.
    func armCurfew(_ plan: ScheduledCurfewPlan?, forSessionID sessionID: SessionID) {
        switch ScheduledCurfewPlanResolution.deadline(
            for: plan,
            preferences: CurfewSettings.shared.preferences,
            now: Date()
        ) {
        case .noCurfew:
            return
        case .arm(let deadline):
            SessionCurfewCenter.shared.setCurfew(.until(deadline), forSessionID: sessionID)
        case .armUsageReset(let expectedAt, let windowID):
            SessionCurfewCenter.shared.setCurfewUntilUsageReset(
                expectedAt: expectedAt,
                windowID: windowID,
                forSessionID: sessionID
            )
        case .skipped(let reason):
            environment.eventLog.record(.curfew, "Planned curfew not armed", [
                "session": sessionID.uuidString,
                "reason": reason.rawValue
            ])
        }
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
        fastMode: Bool?,
        permissionMode: AgentPermissionMode?,
        usesNativeUI: Bool,
        managedWorkspacePlan: ManagedWorkspacePlan?,
        role: SessionRole = .chat,
        openingAttachmentPaths: [String] = [],
        prompt: String
    ) -> AgentSession? {
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var opening = NewChatOpeningMessage.compose(
            prompt: task,
            prefix: environment.settings.newChatOpeningPrefix,
            suffix: environment.settings.newChatOpeningSuffix
        )
        guard !task.isEmpty,
              let project = environment.projectStore.project(withID: projectID) else { return nil }

        // Named once and used twice, as in the composer: the sidebar row, and the checkout a
        // managed session stands in for the whole conversation.
        let sessionID = SessionID()
        let title = SessionNaming.promptTitle(from: task)

        // The server has already refused an ineligible request, so a failure here is the
        // repository saying no — a locked index, a missing branch — and the honest answer is no
        // session rather than one silently running in the checkout the workspace was meant to
        // protect.
        let managedWorkspace: ManagedWorkspace?
        if let managedWorkspacePlan {
            guard let provisioned = try? ManagedGitWorkspace.provision(
                      sessionID: sessionID,
                      from: project,
                      plan: managedWorkspacePlan,
                      title: title
                  ) else { return nil }
            managedWorkspace = provisioned
            opening = ManagedWorkspaceInstructions.append(
                to: opening,
                plan: managedWorkspacePlan
            )
        } else {
            managedWorkspace = nil
        }

        if !openingAttachmentPaths.isEmpty {
            let workingDirectory = managedWorkspace?.executionPath ?? project.folderPath
            guard let handed = ComposerAttachmentHandover.handOverStaged(
                paths: openingAttachmentPaths,
                sessionID: sessionID,
                projectRoot: URL(fileURLWithPath: workingDirectory, isDirectory: true)
            ), let currentOpening = opening else {
                SessionAttachmentStore.shared.removeSession(sessionID)
                if let managedWorkspace {
                    try? ManagedGitWorkspace.discardUnstarted(managedWorkspace)
                }
                return nil
            }
            opening = ComposerAttachmentHandover.appending(
                paths: handed,
                to: currentOpening
            )
        }

        guard let session = environment.projectStore.addSession(
            to: projectID,
            kind: kind,
            accountHandle: accountHandle,
            model: model,
            reasoningEffort: reasoningEffort,
            fastMode: fastMode,
            usesNativeUI: usesNativeUI,
            permissionMode: permissionMode,
            title: title,
            managedWorkspace: managedWorkspace,
            id: sessionID
        ) else {
            SessionAttachmentStore.shared.removeSession(sessionID)
            if let managedWorkspace {
                try? ManagedGitWorkspace.discardUnstarted(managedWorkspace)
            }
            return nil
        }

        // The same rule the composer's Start applies: a manager that cannot be granted its
        // project is not started as a chat that merely calls itself one.
        if role == .manager,
           ControlGrantStore.shared.conferManager(
               sessionID: session.id,
               origin: .newManagerTemplate
           ) == nil {
            _ = environment.projectStore.removeSession(id: session.id)
            SessionAttachmentStore.shared.removeSession(session.id)
            if let managedWorkspace { try? ManagedGitWorkspace.discardUnstarted(managedWorkspace) }
            return nil
        }

        environment.eventLog.record(.remote, "Session started remotely", [
            "session": session.id.uuidString,
            "project": projectID.uuidString,
            "agent": kind.rawValue,
            "role": role.rawValue,
            "speed": fastMode.map { $0 ? "fast" : "standard" } ?? "inherit",
            "permissionMode": permissionMode?.rawValue ?? "inherit",
            "workspace": managedWorkspace?.delivery.rawValue ?? "projectCheckout",
            "prompt": opening ?? "",
        ])

        pendingPrompts.stage(opening, for: session.id)
        // `ProjectStore.addSession` publishes the exact structural insertion synchronously.
        // Rebuilding the complete sidebar here made remote creation scale with every archived
        // session and duplicated work the store notification had already completed.
        sidebar.select(sessionID: session.id)
        return session
    }

    /// Creates the session a scheduled start named, without selecting it.
    ///
    /// Deliberately *not* `startRemoteSession`'s route. That one selects the row, because a
    /// phone asking for a session wants it on screen when its owner looks; a schedule firing at
    /// 09:00 must not reach across whatever the user is reading and replace it. The launch is
    /// `container.launchInBackground`'s job, and the selected-session opening handoff is not
    /// involved at all.
    func startSessionUnattended(plan: ScheduledSessionPlan, title: String) -> AgentSession? {
        let targetProjectID = Self.targetProjectID(
            startingAt: plan.projectID,
            branch: plan.branch,
            checkout: environment.projectStore.checkout(onBranch:inRepositoryOf:)
        )
        guard let targetProject = environment.projectStore.project(withID: targetProjectID) else {
            return nil
        }

        let sessionID = plan.reservedSessionID ?? SessionID()
        let sessionName = SessionNaming.promptTitle(from: title)
        if let existing = environment.projectStore.session(withID: sessionID) {
            guard !existing.hasLaunched, !existing.isArchived else { return nil }

            // A failed first launch may already have provisioned the workspace. Reuse it on an
            // explicit retry instead of creating a second checkout for the same conversation.
            if plan.managedWorkspacePlan == nil || existing.managedWorkspace != nil {
                return existing
            }
        }

        let workspace: ManagedWorkspace?
        if let managedPlan = plan.managedWorkspacePlan {
            guard ManagedWorkspaceEligibility.supportsFinishHandshake(
                kind: plan.kind,
                usesNativeUI: plan.usesNativeUI
            ) else { return nil }
            workspace = try? ManagedGitWorkspace.provision(
                sessionID: sessionID,
                from: targetProject,
                plan: managedPlan,
                title: sessionName
            )
            guard workspace != nil else { return nil }
        } else {
            workspace = nil
        }

        if let existing = environment.projectStore.session(withID: sessionID) {
            guard let workspace else { return existing }
            let result = environment.projectStore.update(sessionID: sessionID) {
                $0.managedWorkspace = workspace
                $0.branch = workspace.targetBranch
            }
            guard result == .applied else {
                try? ManagedGitWorkspace.discardUnstarted(workspace)
                return nil
            }
            return environment.projectStore.session(withID: sessionID)
        }

        let session = environment.projectStore.addSession(
            to: targetProjectID,
            kind: plan.kind,
            accountHandle: plan.accountHandle,
            model: plan.model,
            reasoningEffort: plan.reasoningEffort,
            fastMode: plan.fastMode,
            usesNativeUI: plan.usesNativeUI,
            permissionMode: plan.permissionMode,
            title: sessionName,
            managedWorkspace: workspace,
            id: sessionID
        )
        if session == nil, let workspace {
            try? ManagedGitWorkspace.discardUnstarted(workspace)
        }
        return session
    }

    func sessionComposer(
        _ composer: SessionComposerViewController,
        importSessions sessions: [ImportableSession],
        into projectID: ProjectID
    ) {
        // One write and one notification however many were chosen, and the newest is selected:
        // it is the row at the top of the sheet, and the one somebody adopting a single
        // conversation asked for.
        let adopted = environment.projectStore.importSessions(sessions, into: projectID)
        guard let first = adopted.first else { return }

        sidebar.reload()
        sidebar.select(sessionID: first.id)
    }

    func sessionComposer(
        _ composer: SessionComposerViewController,
        didCreateWorktreeAt url: URL,
        branch: String
    ) {
        guard let project = environment.projectStore.addProject(folderURL: url) else { return }
        sidebar.reload()
        container.showComposer(projectID: project.id)
    }

    func sessionComposer(
        _ composer: SessionComposerViewController,
        didSelectProject projectID: ProjectID
    ) {
        // Through the sidebar, so selection, the header tab, and the composer all move on the
        // one path project selection already takes.
        sidebar.select(projectID: projectID)
    }

    func sessionComposerDidRequestAddFolder(_ composer: SessionComposerViewController) {
        addProject()
    }

    func sessionComposerDidRequestNewFolder(_ composer: SessionComposerViewController) {
        newProject()
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
        guard environment.agentRuntime.isRunning(sessionID: sessionID),
              let session = environment.projectStore.session(withID: sessionID) else { return true }

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
    static func archiveFailureToast(
        for session: AgentSession,
        failure: ProviderArchiveFailure,
        wasRunning: Bool
    ) -> ToastRequest {
        let stopped = wasRunning && failure.stoppedAgentBeforeFailure
            ? L10n.string("The agent stopped.")
            : nil
        return ToastRequest(
            message: L10n.format("Couldn’t archive “%@”", session.displayTitle),
            detail: [failure.localizedDescription, stopped].compactMap { $0 }.joined(separator: " "),
            identifier: "sidebar.toast.archive.failed"
        )
    }

    static func sessionStartFailureToast(
        reason: ProjectStorePersistenceBlock?,
        retry: (() -> Void)?
    ) -> ToastRequest {
        switch reason {
        case .storageExhausted:
            return ToastRequest(
                message: L10n.string("Session not started — disk full"),
                detail: L10n.string(
                    "Your brief is still here. Clear some disk space, then retry."
                ),
                actionTitle: retry == nil ? nil : L10n.string("Retry"),
                action: retry,
                identifier: "sidebar.toast.session-start.storage-full",
                persistsUntilDismissed: true,
                replacementID: "storage.cleanup"
            )
        case .failedLoad:
            return ToastRequest(
                message: L10n.string("Session not started"),
                detail: L10n.string(
                    "Threading could not safely load project data. Your brief is still here; restart Threading to recover."
                ),
                identifier: "sidebar.toast.session-start.persistence",
                persistsUntilDismissed: true,
                replacementID: "persistence.blocked"
            )
        case .recoveryMode:
            return ToastRequest(
                message: L10n.string("Session not started in Recovery Mode"),
                detail: L10n.string("Your brief is still here. Restart Threading normally to save changes."),
                identifier: "sidebar.toast.session-start.persistence",
                persistsUntilDismissed: true,
                replacementID: "persistence.blocked"
            )
        case .failedWrite:
            return ToastRequest(
                message: L10n.string("Session not started"),
                detail: L10n.string(
                    "Threading could not safely save project data. Your brief is still here; restart Threading and try again."
                ),
                identifier: "sidebar.toast.session-start.persistence",
                persistsUntilDismissed: true,
                replacementID: "persistence.blocked"
            )
        case nil:
            return ToastRequest(
                message: L10n.string("Session not started"),
                detail: L10n.string("Your brief is still here. Check the selected project and try again."),
                identifier: "sidebar.toast.session-start.failed"
            )
        }
    }

    /// A checkout removed outside Threading is refused before a session row exists. The composer
    /// interprets `false` as "keep everything", so the receipt says both halves: what is gone and
    /// that the submitted brief is still available after the failed Start press.
    static func sessionStartFolderFailureToast(
        _ failure: ProjectLaunchPreflight.Failure
    ) -> ToastRequest {
        ToastRequest(
            message: L10n.string("Session not started"),
            detail: [
                failure.summary,
                L10n.string("Your brief is still here. Check the selected project and try again.")
            ].joined(separator: " "),
            identifier: "sidebar.toast.session-start.folder-missing",
            persistsUntilDismissed: true
        )
    }

    static func restoreFailureToast(
        for session: AgentSession?,
        failure: ProviderArchiveFailure
    ) -> ToastRequest {
        ToastRequest(
            message: session.map { L10n.format("Couldn’t restore “%@”", $0.displayTitle) }
                ?? L10n.string("Couldn’t restore this conversation"),
            detail: failure.localizedDescription,
            identifier: "sidebar.toast.restore.failed"
        )
    }

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

    /// The same receipt, for an archive nobody clicked.
    ///
    /// Two things change, and both come from the same fact — the user asked for this in words, a
    /// turn ago, and has been reading something else since it landed.
    ///
    /// **It names the agent.** "Archived “X”" beside a row that vanished on its own is a report
    /// with no actor in it, and the first thing anyone asks of a window that rearranged itself is
    /// who did that. The agent's own name is the answer, and it is also the only part that says
    /// this was not a misclick.
    ///
    /// **It holds longer** (`ToastDefaults.unattendedDwell`): the six seconds behind the clicked
    /// archive are measured from the click, and there was none here.
    ///
    /// The agent's reason leads, when it gave one, because it is the only part of the receipt
    /// the user cannot already work out — it says which piece of work this was the end of.
    static func agentArchiveToast(
        for session: AgentSession,
        reason: String?,
        wasRunning: Bool,
        undo: @escaping () -> Void
    ) -> ToastRequest {
        let whereItWent = L10n.string("Restore it from Settings ▸ Archived.")
        let stopped = session.kind.supportsResume
            ? L10n.string("The agent stopped.")
            : L10n.string("The shell stopped.")

        let sentences = [
            reason.map(Self.asSentence),
            wasRunning ? stopped : nil,
            whereItWent
        ].compactMap { $0 }

        return ToastRequest(
            message: L10n.format(
                "%@ archived “%@”",
                session.kind.displayName,
                session.displayTitle
            ),
            detail: sentences.joined(separator: " "),
            actionTitle: L10n.string("Undo"),
            action: undo,
            dwell: ToastDefaults.unattendedDwell,
            identifier: "sidebar.toast.archive.agent"
        )
    }

    /// Sets the agent's fragment beside the app's own sentences without rewriting it: capitalised
    /// so it does not read as a continuation of the title above it, and closed so the two
    /// sentences after it do not run into it. Anything longer was already bounded on arrival —
    /// see `SessionArchiveDefaults.maximumReasonLength`.
    private static func asSentence(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }

        let opened = first.uppercased() + trimmed.dropFirst()
        return trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")
            ? opened
            : opened + "."
    }

    /// A move interrupts a running agent exactly as a surface switch does, and each carries its
    /// own registered prompt for the same reason close and archive do.
    private func confirmMoveIfRunning(sessionID: SessionID, to account: AgentAccount) -> Bool {
        guard environment.agentRuntime.isRunning(sessionID: sessionID),
              let session = environment.projectStore.session(withID: sessionID) else { return true }

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
        guard environment.agentRuntime.isRunning(sessionID: sessionID),
              let session = environment.projectStore.session(withID: sessionID) else { return true }

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
        guard environment.agentRuntime.isRunning(sessionID: sessionID),
              let session = environment.projectStore.session(withID: sessionID) else { return true }

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

// MARK: - Session Rename Request

/// The one line the app sends an agent when the user asks it to name its own session.
///
/// It names the tool outright rather than describing the wish. An agent asked in prose to
/// "rename this chat" answers in prose — the CLIs have their own `/rename` and their own idea
/// of a title — and the sidebar would learn nothing. Naming `set_session_name` is what turns
/// the request into the one call that reaches the store.
enum SessionRenameRequest {
    /// English source copy, and the key it is looked up by, like every other string here.
    static let promptKey = """
        Call set_session_name to rename this chat, using two to five words for what it has \
        actually been about. Reply with just the new name.
        """

    /// What submits the line in a terminal. Return, as the user's own keypress arrives — not
    /// `\n`, which several TUI composers insert as a newline instead of sending.
    static let submitKey = TerminalDefaults.submitSequence

    /// How long after the text the return is sent, in its own write. This request measured the
    /// rule; `TerminalDefaults` now states it, because every path that types on the user's
    /// behalf owes the same beat — a phone's composer as much as this one.
    static let submitDelay = TerminalDefaults.submitSequenceDelay
}

// MARK: - Session Report-Back Request

/// The one line the app sends a side chat when the user asks it to report its conclusion to
/// the session it was forked from.
///
/// `SessionRenameRequest`'s twin, for `SessionRenameRequest`'s reason: it names the tool and
/// the target id outright rather than describing the wish, because an agent asked in prose to
/// "tell your parent" answers in prose, in its own transcript, and the parent hears nothing.
enum SessionReportBackRequest {
    /// English source copy, and the key it is looked up by. `%@` is the parent's Threading id.
    static let promptKey = """
        Call send_to_session with session_id %@ — the session this side chat was forked \
        from — and report your conclusion: what was found or decided, in a few sentences, \
        not the transcript. Then reply here with one line saying what you sent.
        """

    static func prompt(parentID: SessionID) -> String {
        L10n.format(promptKey, parentID.uuidString.lowercased())
    }

    /// The lineage half of the offer's gate, pure so a test can hold it without a store: a
    /// side chat, whose parent is still an unarchived row to deliver to.
    static func hasReportableParent(
        of session: AgentSession?,
        parent lookup: (SessionID) -> AgentSession?
    ) -> Bool {
        guard let session,
              let parentID = session.forkedFrom,
              let parent = lookup(parentID),
              !parent.isArchived
        else { return false }
        return true
    }
}

// MARK: - New Chat Opening Message

/// Joins the per-chat task with the reusable text from Settings, on either side of it.
///
/// Two standing fields rather than one because the two jobs read differently to a model: text
/// before the task frames what is about to be asked, and text after it is an instruction about
/// the answer. Blank lines keep independently-authored parts readable, and an empty field is
/// simply absent rather than a blank paragraph. The caller derives the sidebar title from the
/// task alone: reusable text should not make every chat start with the same name.
enum NewChatOpeningMessage {
    static func compose(prompt: String?, prefix: String, suffix: String) -> String? {
        let parts = [prefix, prompt, suffix]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }
}
