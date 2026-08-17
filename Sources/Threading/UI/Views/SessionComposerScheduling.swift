import AppKit

// MARK: - Scheduling A Session Start

/// Starting a session later, from the screen where one is started now.
///
/// The brief and every decision beside it — which agent, which login, which model, which speed,
/// which checkout — are frozen into a `ScheduledSessionPlan` at the moment it is scheduled. Not
/// read again at launch: the chips will have moved on by Monday morning, and a plan that consulted
/// them then would start whatever happened to be selected rather than what was asked for.
extension SessionComposerViewController {

    // MARK: - The Menu

    /// The offers behind the Schedule chip.
    ///
    /// Refuses rather than offering an unusable menu: there has to be a project and something
    /// written, each with its own sentence, because "nothing happened when I clicked it" is the
    /// worst possible answer. The missing project used to be the exception, answered with an
    /// empty menu, which is that worst answer exactly.
    ///
    /// An attached image used to be a third refusal, on the grounds that a pasted screenshot is
    /// a temporary file. It is now taken custody of instead — see `ScheduledAttachmentStore`.
    func scheduleEntries() -> [ThemedMenuEntry] {
        if let reason = scheduleRefusalReason() {
            return [.item(ThemedMenuItem(title: reason, isEnabled: false))]
        }

        let finishCandidates = ScheduledFinishCandidates.current()
        let account = selectedAgent.supportsAccounts
            ? AgentAccountDiscovery.account(for: selectedAgent, handle: selectedAccountHandle)
            : nil
        if let account { AccountUsageService.shared.refresh(account) }

        return ScheduleMenu.entries(
            usage: account.flatMap { AccountUsageService.shared.usage(for: $0) },
            metering: account.flatMap { modelIdentifierToLaunch(on: $0) },
            canWaitForConversation: !finishCandidates.isEmpty
        ) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .at(let date, let anchor):
                self.scheduleStart(at: date, anchor: anchor)
            case .whenConversationFinishes:
                self.presentScheduledFinishPicker(candidates: finishCandidates)
            case .custom:
                ScheduleMomentPickerViewController.present(
                    over: self,
                    title: L10n.string("Schedule session")
                ) { [weak self] date in
                    guard let self, let date else { return }
                    self.scheduleStart(at: date, anchor: .wallClock)
                }
            }
        }
    }

    private func presentScheduledFinishPicker(candidates: [ScheduledFinishCandidate]) {
        guard !candidates.isEmpty else { return }
        let picker = ScheduledFinishPickerViewController(candidates: candidates)
        picker.onPick = { [weak self, weak picker] candidate in
            guard let self, let picker else { return }
            self.dismiss(picker)
            guard let candidate else { return }
            self.scheduleStart(whenSessionFinishes: candidate.id)
        }
        presentAsSheet(picker)
    }

    /// Opens the offers under the button that asked for them.
    func presentScheduleMenu(from source: NSView) {
        let entries = scheduleEntries()
        guard !entries.isEmpty else { return }
        ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 0),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: {}
        )
    }

    /// Why the button cannot be used, in the words it will say.
    func scheduleRefusalReason() -> String? {
        if projectID == nil {
            // The same sentence the send and the placeholder are already using, so the screen
            // states one blocker once rather than three phrasings of it.
            return ComposerDefaults.chooseProjectFirstReason
        }
        if promptView.attachmentPaths.count > ScheduledAttachmentDefaults.maximumPerMessage {
            return L10n.format(
                "A scheduled session can carry at most %lld images.",
                Int64(ScheduledAttachmentDefaults.maximumPerMessage)
            )
        }
        if promptView.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.string("Write the brief first.")
        }
        return nil
    }

    // MARK: - Scheduling

    func scheduleStart(at date: Date, anchor: ScheduledMessage.Anchor) {
        guard let projectID else { return }
        let brief = promptView.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return }

        let id = ScheduledMessageID()
        guard let attachments = takeCustodyOfAttachments(for: id) else { return }

        let message = ScheduledMessage(
            id: id,
            dueAt: date,
            target: .newSession(frozenPlan(in: projectID, reserving: SessionID())),
            text: brief,
            attachments: attachments,
            anchor: anchor
        )

        _ = storeScheduledStart(message, projectID: projectID, event: [
            "dueAt": ISO8601DateFormatter().string(from: date)
        ])
    }

    func scheduleStart(whenSessionFinishes watchedSessionID: SessionID) {
        guard let projectID else { return }
        let brief = promptView.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return }

        let id = ScheduledMessageID()
        guard let attachments = takeCustodyOfAttachments(for: id) else { return }

        let message = ScheduledMessage(
            id: id,
            whenSessionFinishes: watchedSessionID,
            target: .newSession(frozenPlan(in: projectID, reserving: SessionID())),
            text: brief,
            attachments: attachments
        )

        guard storeScheduledStart(message, projectID: projectID, event: [
            "afterSession": watchedSessionID.uuidString
        ]) else { return }

        ScheduledMessageScheduler.shared.evaluateCompletion(
            of: watchedSessionID,
            acceptsSettledSnapshot: true
        )
    }

    /// The same checkout resolution an immediate start performs, done now rather than at fire
    /// time: the branch named here is the one the user was looking at.
    private func frozenPlan(
        in projectID: ProjectID,
        reserving sessionID: SessionID
    ) -> ScheduledSessionPlan {
        ScheduledSessionPlan(
            reservedSessionID: sessionID,
            projectID: projectID,
            kind: selectedAgent,
            accountHandle: selectedAccountHandle,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            fastMode: selectedFastMode,
            branch: selectedBranch,
            usesNativeUI: usesNativeUI,
            permissionMode: selectedAgent.supportsPermissionModes ? selectedPermissionMode : nil,
            managedWorkspacePlan: selectedManagedWorkspacePlan,
            role: selectedRole
        )
    }

    /// Copies whatever pictures the box is holding into the app's own keeping, under the id the
    /// record is about to be given. Answers nil once the refusal has been shown — the composer
    /// still has everything, so the words and the images stay where the user can act on them.
    private func takeCustodyOfAttachments(
        for id: ScheduledMessageID
    ) -> [ScheduledAttachment]? {
        guard let taken = ScheduledAttachmentStore.shared.take(
            promptView.attachmentPaths,
            for: id
        ) else {
            reportScheduleFailure(L10n.string(
                "The attached images could not be kept, so this was not scheduled."
            ))
            return nil
        }
        return taken
    }

    @discardableResult
    private func storeScheduledStart(
        _ message: ScheduledMessage,
        projectID: ProjectID,
        event details: [String: String]
    ) -> Bool {
        switch ScheduledMessageStore.shared.add(message) {
        case .success:
            let reserved = delegate?.sessionComposer(
                self,
                reserveScheduledStart: message
            ) ?? (ScheduledSessionReservation.reserve(message, in: .shared) != nil)
            guard reserved else {
                // The record is not allowed to outlive the conversation it promised to show.
                // Removing it also releases the attachment copies this attempt owned.
                ScheduledMessageStore.shared.remove(message.id)
                reportScheduleFailure(L10n.string("Its session could not be created."))
                return false
            }

            var fields = details
            fields.merge([
                "project": projectID.uuidString,
                "agent": selectedAgent.rawValue,
                "prompt": message.text
            ]) { _, new in new }
            EventLog.shared.record(.composer, "Session start scheduled", fields)
            promptView.clear()
            DraftStore.shared.clear(for: projectID)
            refreshScheduledStrip()
            return true
        case .failure(let refusal):
            // The record never landed, so nothing owns the copies this attempt took.
            ScheduledMessageStore.shared.attachments.release(message.id)
            reportScheduleFailure(ScheduledRefusalText.sentence(for: refusal))
            return false
        }
    }

    private func reportScheduleFailure(_ reason: String) {
        let alert = ThemedAlert()
        alert.messageText = L10n.string("Couldn't schedule this")
        alert.informativeText = reason
        alert.alertStyle = .warning
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - The Strip

    /// Restates what is waiting to start in this project.
    ///
    /// **Added to the column only while it has something to show, and removed when it does
    /// not.** Hiding it is not enough: a hidden arranged view is detached from the stack's
    /// layout but is still a subview with constraints of its own, and an empty strip left in the
    /// column was enough to pull the composer's width off the pane's — the measurement
    /// `ComposerWindowFitTests.testTheColumnFillsThePaneUpToItsCap` exists to hold, and which it
    /// caught. A view that has nothing to say leaves the room.
    func refreshScheduledStrip() {
        guard isViewLoaded else { return }
        let now = Date()
        let rows = projectID.map { projectID in
            ScheduledMessageStore.shared.sessionStarts(in: projectID).map { message in
                ScheduledMessageStripView.Row(
                    id: message.id,
                    summary: ScheduledTiming.summary(of: message),
                    timing: ScheduledTiming.automaticStartSentence(
                        for: message,
                        from: now,
                        watchedSessionTitle: watchedSessionTitle(for: message)
                    ),
                    problem: ScheduledTiming.problem(for: message.state)
                )
            }
        } ?? []

        scheduledStrip.setRows(rows)
        setScheduledStripAttached(!rows.isEmpty)
    }

    private func watchedSessionTitle(for message: ScheduledMessage) -> String? {
        guard case .sessionFinished(let watchedSessionID) = message.trigger else { return nil }
        return ProjectStore.shared.session(withID: watchedSessionID)?.displayTitle
    }

    /// Puts a frozen plan back into the chips it came from, so editing a scheduled start reopens
    /// the whole decision rather than only its words.
    func adopt(_ plan: ScheduledSessionPlan) {
        selectedAgent = plan.kind
        selectedAccountHandle = plan.accountHandle
        selectedModel = plan.model
        selectedReasoningEffort = plan.reasoningEffort
        selectedFastMode = plan.fastMode
        selectedBranch = plan.branch
        usesNativeUI = plan.usesNativeUI
        selectedPermissionMode = plan.permissionMode
        selectedManagedWorkspacePlan = plan.managedWorkspacePlan
        selectedRole = plan.role ?? .chat
        managedWorkspaceCheckbox.state = plan.managedWorkspacePlan == nil ? .off : .on
        refreshChips()
    }

    func wireScheduledStrip() {
        scheduledStrip.onRemove = { [weak self] id in
            guard let message = ScheduledMessageStore.shared[id] else { return }
            self?.discardScheduledStart(message)
            self?.refreshScheduledStrip()
        }

        // Editing puts the brief and its configuration back where they came from, so a change of
        // mind costs a click rather than retyping the paragraph.
        scheduledStrip.onEdit = { [weak self] id in
            guard let self,
                  let message = ScheduledMessageStore.shared[id],
                  case .newSession(let plan) = message.target else { return }

            // Detached before the removal, and in that order: `remove` deletes the pictures, so
            // taking them back has to happen while the record still owns them.
            let images = ScheduledMessageStore.shared.attachments.detach(message)
            self.discardScheduledStart(message)
            self.promptView.stringValue = message.text
            self.promptView.attachFiles(at: images)
            self.adopt(plan)
            self.view.window?.makeFirstResponder(self.promptView)
            self.refreshScheduledStrip()
        }

        scheduledStrip.onSendNow = { [weak self] id in
            guard let self, ScheduledMessageStore.shared[id] != nil else { return }
            self.delegate?.sessionComposer(self, startScheduledMessageNow: id)
        }
    }

    /// Removes both halves of a scheduled start. The schedule goes first so deleting the
    /// reserved session cannot turn its own record into a failed "target was deleted" item.
    private func discardScheduledStart(_ message: ScheduledMessage) {
        guard ScheduledMessageStore.shared.remove(message.id) else { return }
        guard case .newSession(let plan) = message.target,
              let sessionID = plan.reservedSessionID else { return }
        _ = ProjectStore.shared.removeSession(id: sessionID)
    }
}
