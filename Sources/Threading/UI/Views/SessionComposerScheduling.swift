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
        // While an edit holds the box, choosing a moment re-aims the record being edited
        // rather than scheduling a second one beside it.
        guard editingScheduledStartID == nil else {
            commitScheduledStartEdit(.at(date, anchor), reporting: true)
            return
        }
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
        guard editingScheduledStartID == nil else {
            commitScheduledStartEdit(.whenSessionFinishes(watchedSessionID), reporting: true)
            return
        }
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
            role: selectedRole,
            // The end travels as the *choice*, not as a moment. `atQuietHours` resolved here
            // would write down tonight's 04:00 into a plan that fires on Thursday; the plan is
            // read back against the settings in force when the session actually starts. The
            // waiting row is not under curfew either way — there is nothing yet to wind down,
            // hold or interrupt, so a start that is cancelled leaves nothing to lift.
            curfew: selectedCurfew
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

            // A reserved scheduled conversation is an accepted start just as an immediate one
            // is; its frozen provider/model choice should seed the next fresh composer too.
            rememberSuccessfulNewSessionChoice()

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

        // The record an edit is holding can leave underneath it — its trigger fired, or it was
        // cancelled from the sidebar or the reserved conversation's own surface. The box then
        // holds the only copy of its words, so the edit ends by keeping them as the draft.
        if let editingID = editingScheduledStartID, ScheduledMessageStore.shared[editingID] == nil {
            endScheduledStartEdit(keepingBoxContents: true)
            return
        }

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
                    problem: ScheduledTiming.problem(for: message.state),
                    isEditing: message.id == editingScheduledStartID
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
        // The chip follows the record being edited rather than the last draft written in this
        // box: an edit reopens the whole decision, and the end is one of them. A record from
        // before curfews existed carries none, which reads correctly as a session with no end.
        selectedCurfew = plan.curfew
        managedWorkspaceCheckbox.state = plan.managedWorkspacePlan == nil ? .off : .on
        refreshChips()
    }

    func wireScheduledStrip() {
        scheduledStrip.onRemove = { [weak self] id in
            guard let message = ScheduledMessageStore.shared[id] else { return }
            self?.discardScheduledStart(message)
            self?.refreshScheduledStrip()
        }

        // Editing borrows the box; it never spends the record. The first version detached the
        // pictures, removed the record and reserved session, and poured the text into the box —
        // so tapping a row silently unscheduled it, and tapping a second row destroyed both
        // while the box kept only one. The record now stays in the store, still armed, until
        // Save rewrites it in place.
        scheduledStrip.onEdit = { [weak self] id in
            self?.beginEditingScheduledStart(id)
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

    // MARK: - Editing A Scheduled Start

    /// Opens a waiting record in the composer without spending it.
    ///
    /// The record stays in the store, still armed and still the authority — a trigger reaching
    /// its moment mid-edit fires the message as it was written, which is what "the schedule
    /// remains the authority" has meant since reservation. What the composer receives are
    /// loans: the words into the box, *copies* of the pictures (`ScheduledAttachmentStore
    /// .copies(of:)`), and the frozen plan into the chips. Save rewrites the record in place;
    /// Cancel hands the box back untouched.
    ///
    /// Opening a second row while one is already open saves the first — the words typed into
    /// the borrowed box are the user's work, and this is what makes tapping around the strip
    /// lossless where the old detach gesture destroyed a record per tap.
    func beginEditingScheduledStart(_ id: ScheduledMessageID) {
        guard let message = ScheduledMessageStore.shared[id],
              case .newSession(let plan) = message.target else { return }
        if editingScheduledStartID == id {
            view.window?.makeFirstResponder(promptView)
            return
        }
        if editingScheduledStartID != nil {
            guard commitScheduledStartEdit() else { return }
        }

        // What the box held before the loan, put back when the edit ends. The text is already
        // durable in `DraftStore` (whose writes pause during the edit); the attachment paths
        // have exactly the composer's own in-memory durability.
        if editingScheduledStartID == nil {
            scheduledEditDraftStash = (
                text: promptView.stringValue,
                attachmentPaths: promptView.attachmentPaths
            )
        }

        promptView.clearAttachments()
        promptView.stringValue = message.text
        promptView.attachFiles(at: ScheduledMessageStore.shared.attachments.copies(of: message))
        adopt(plan)
        editingScheduledStartID = id
        applyScheduledEditPresentation()
        view.window?.makeFirstResponder(promptView)
    }

    /// The moment an edited record keeps or takes on the way back into the store.
    enum EditedMoment {
        /// Save: the content changed, the trigger did not.
        case unchanged
        case at(Date, ScheduledMessage.Anchor)
        case whenSessionFinishes(SessionID)
    }

    /// Rewrites the record being edited from what the composer holds now.
    ///
    /// In-place and atomic where it matters: custody of the pictures is staged under a fresh id
    /// first (`take`, so every ceiling and refusal applies), the record is rewritten in one
    /// verified store commit, and only then are the staged bytes adopted and the old ones
    /// released — a refusal at any step leaves the schedule exactly as it was, edit still open.
    ///
    /// The reservation survives an edit that changed only the words or the moment; its sidebar
    /// row keeps its identity and takes the new title. A changed *configuration* is honestly a
    /// different conversation, so it is re-reserved under a fresh session id and the old empty
    /// row leaves — with the record rewritten in between, so `forget(sessionID:)` never sees a
    /// record naming the row being removed.
    @discardableResult
    func commitScheduledStartEdit(
        _ moment: EditedMoment = .unchanged,
        reporting: Bool = true
    ) -> Bool {
        guard let editingID = editingScheduledStartID else { return false }
        guard let original = ScheduledMessageStore.shared[editingID],
              case .newSession(let originalPlan) = original.target else {
            // The record left while the box held it — fired, or removed elsewhere. The box now
            // holds the only copy of its words, so the edit ends by keeping them.
            endScheduledStartEdit(keepingBoxContents: true)
            return false
        }
        guard let projectID else { return false }

        if let reason = scheduleRefusalReason() {
            if reporting { reportScheduleFailure(reason) }
            return false
        }
        let brief = promptView.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let stagingID = ScheduledMessageID()
        guard let attachments = ScheduledMessageStore.shared.attachments.take(
            promptView.attachmentPaths,
            for: stagingID
        ) else {
            if reporting {
                reportScheduleFailure(L10n.string(
                    "The attached images could not be kept, so this was not scheduled."
                ))
            }
            return false
        }

        let keptPlan = frozenPlan(
            in: projectID,
            reserving: originalPlan.reservedSessionID ?? SessionID()
        )
        let configurationChanged = keptPlan != originalPlan
        let plan = configurationChanged ? frozenPlan(in: projectID, reserving: SessionID()) : originalPlan

        var updated: ScheduledMessage
        switch moment {
        case .unchanged:
            updated = original
            updated.text = brief
            updated.attachments = attachments
            updated.target = .newSession(plan)
        case .at(let date, let anchor):
            updated = ScheduledMessage(
                id: original.id,
                createdAt: original.createdAt,
                dueAt: date,
                target: .newSession(plan),
                text: brief,
                attachments: attachments,
                anchor: anchor
            )
        case .whenSessionFinishes(let watched):
            updated = ScheduledMessage(
                id: original.id,
                createdAt: original.createdAt,
                whenSessionFinishes: watched,
                target: .newSession(plan),
                text: brief,
                attachments: attachments
            )
        }

        if configurationChanged {
            // Reserved directly rather than through the delegate's reservation, whose contract
            // is the *first* schedule: it selects the reserved row, and a commit must not
            // navigate away from the composer mid-edit. The sidebar reloads itself from
            // `ProjectsDidChange`.
            guard ScheduledSessionReservation.reserve(updated, in: .shared) != nil else {
                ScheduledMessageStore.shared.attachments.release(stagingID)
                if reporting {
                    reportScheduleFailure(L10n.string("Its session could not be created."))
                }
                return false
            }
        }

        guard ScheduledMessageStore.shared.replace(editingID, with: updated) else {
            ScheduledMessageStore.shared.attachments.release(stagingID)
            if configurationChanged, let newSessionID = plan.reservedSessionID {
                // The record still names the old reservation, so removing this one is safe.
                _ = ProjectStore.shared.removeSession(id: newSessionID)
            }
            if reporting {
                reportScheduleFailure(ScheduledRefusalText.sentence(for: .writesBlocked))
            }
            return false
        }
        ScheduledMessageStore.shared.attachments.adopt(stagingID, as: editingID)

        if configurationChanged {
            if let oldSessionID = originalPlan.reservedSessionID {
                // After the replace on purpose: the record now names the new reservation, so
                // `forget(sessionID:)` passes it by.
                _ = ProjectStore.shared.removeSession(id: oldSessionID)
            }
        } else if let sessionID = plan.reservedSessionID {
            // The kept row follows the rewritten brief; a name the user or an agent gave the
            // row keeps its authority (`applyReservedPromptTitle` refuses to touch either).
            ProjectStore.shared.applyReservedPromptTitle(brief, forSessionID: sessionID)
        }

        if case .whenSessionFinishes(let watched) = moment {
            // The watched turn may have ended while the picker was open; re-read the settled
            // snapshot exactly once, as the first schedule does.
            ScheduledMessageScheduler.shared.evaluateCompletion(
                of: watched,
                acceptsSettledSnapshot: true
            )
        }

        EventLog.shared.record(.composer, "Scheduled start edited", [
            "message": editingID.uuidString,
            "project": projectID.uuidString,
            "configurationChanged": configurationChanged ? "yes" : "no",
            "prompt": brief
        ])
        endScheduledStartEdit(keepingBoxContents: false)
        return true
    }

    /// Ends the edit with the record exactly as it was.
    func cancelScheduledStartEdit() {
        guard editingScheduledStartID != nil else { return }
        endScheduledStartEdit(keepingBoxContents: false)
    }

    /// Hands the box back and leaves the mode.
    ///
    /// `keepingBoxContents` is for the one exit where the box holds the only copy of the words —
    /// the record left the store mid-edit — and then what it holds becomes the project's draft.
    /// Every other exit restores what the box held before the edit borrowed it.
    private func endScheduledStartEdit(keepingBoxContents: Bool) {
        let stash = scheduledEditDraftStash
        scheduledEditDraftStash = nil
        editingScheduledStartID = nil

        if keepingBoxContents {
            if let projectID {
                DraftStore.shared.setDraft(promptView.stringValue, for: projectID)
            }
        } else {
            promptView.clearAttachments()
            promptView.stringValue = stash?.text ?? ""
            let survivingPaths = (stash?.attachmentPaths ?? [])
                .filter { FileManager.default.fileExists(atPath: $0) }
            if !survivingPaths.isEmpty {
                promptView.attachFiles(at: survivingPaths)
            }
            if let projectID {
                DraftStore.shared.setDraft(promptView.stringValue, for: projectID)
            }
        }

        applyScheduledEditPresentation()
    }
}
