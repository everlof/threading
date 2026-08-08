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
    /// Refuses rather than offering an unusable menu: there has to be a project, something
    /// written, and no images — each with its own sentence, because "nothing happened when I
    /// clicked it" is the worst of the three possible answers.
    func scheduleEntries() -> [ThemedMenuEntry] {
        guard projectID != nil else { return [] }

        if let reason = scheduleRefusalReason() {
            return [.item(ThemedMenuItem(title: reason, isEnabled: false))]
        }

        let account = selectedAgent.supportsAccounts
            ? AgentAccountDiscovery.account(for: selectedAgent, handle: selectedAccountHandle)
            : nil
        if let account { AccountUsageService.shared.refresh(account) }

        return ScheduleMenu.entries(
            usage: account.flatMap { AccountUsageService.shared.usage(for: $0) },
            metering: account.flatMap { modelIdentifierToLaunch(on: $0) }
        ) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .at(let date, let anchor):
                self.scheduleStart(at: date, anchor: anchor)
            case .custom:
                ScheduleMessageAlert.present(
                    over: self.view.window,
                    title: L10n.string("Schedule session")
                ) { [weak self] date in
                    guard let self, let date else { return }
                    self.scheduleStart(at: date, anchor: .wallClock)
                }
            }
        }
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
        if !promptView.attachmentPaths.isEmpty {
            return L10n.string("Images can't be scheduled — they are temporary files.")
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

        // The same checkout resolution an immediate start performs, done now rather than at fire
        // time: the branch named here is the one the user was looking at.
        let plan = ScheduledSessionPlan(
            projectID: projectID,
            kind: selectedAgent,
            accountHandle: selectedAccountHandle,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            fastMode: selectedFastMode,
            branch: selectedBranch,
            usesNativeUI: usesNativeUI,
            permissionMode: selectedAgent.supportsPermissionModes ? selectedPermissionMode : nil,
            managedWorkspacePlan: selectedManagedWorkspacePlan
        )

        let message = ScheduledMessage(
            dueAt: date,
            target: .newSession(plan),
            text: brief,
            anchor: anchor
        )

        switch ScheduledMessageStore.shared.add(message) {
        case .success:
            EventLog.shared.record(.composer, "Session start scheduled", [
                "project": projectID.uuidString,
                "agent": selectedAgent.rawValue,
                "dueAt": ISO8601DateFormatter().string(from: date),
                "prompt": brief
            ])
            promptView.clear()
            DraftStore.shared.clear(for: projectID)
            refreshScheduledStrip()
        case .failure(let refusal):
            let alert = ThemedAlert()
            alert.messageText = L10n.string("Couldn't schedule this")
            alert.informativeText = ScheduledRefusalText.sentence(for: refusal)
            alert.alertStyle = .warning
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
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
                    summary: message.summary,
                    timing: ScheduledTiming.sentence(for: message.dueAt, from: now),
                    problem: ScheduledTiming.problem(for: message.state)
                )
            }
        } ?? []

        scheduledStrip.setRows(rows)
        setScheduledStripAttached(!rows.isEmpty)
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
        managedWorkspaceCheckbox.state = plan.managedWorkspacePlan == nil ? .off : .on
        refreshChips()
    }

    func wireScheduledStrip() {
        scheduledStrip.onRemove = { [weak self] id in
            ScheduledMessageStore.shared.remove(id)
            self?.refreshScheduledStrip()
        }

        // Editing puts the brief and its configuration back where they came from, so a change of
        // mind costs a click rather than retyping the paragraph.
        scheduledStrip.onEdit = { [weak self] id in
            guard let self,
                  let message = ScheduledMessageStore.shared[id],
                  case .newSession(let plan) = message.target else { return }

            ScheduledMessageStore.shared.remove(id)
            self.promptView.stringValue = message.text
            self.adopt(plan)
            self.view.window?.makeFirstResponder(self.promptView)
            self.refreshScheduledStrip()
        }

        scheduledStrip.onSendNow = { [weak self] id in
            guard let self, let message = ScheduledMessageStore.shared[id] else { return }
            ScheduledMessageStore.shared.remove(id)
            self.promptView.stringValue = message.text
            if case .newSession(let plan) = message.target { self.adopt(plan) }
            self.refreshScheduledStrip()
            self.startTapped()
        }
    }
}
