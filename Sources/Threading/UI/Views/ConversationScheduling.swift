import AppKit

// MARK: - Scheduling, On Top Of The Conversation

/// Sending a reply later, and showing what is waiting.
///
/// Split out for the same reason the outbox coordination is: the conversation already owns a
/// transcript, a permission broker, a queue and a composer, and "not now, then" is a subject of
/// its own. Nothing here names a provider — the account whose usage windows are offered comes
/// from the session's own record.
extension ConversationViewController {

    // MARK: - The Menu

    /// The rows behind the chevron beside the send.
    ///
    /// Built fresh on every open, so a window that reset in the last five minutes is not still
    /// being offered as a moment to aim at.
    func scheduleMenuEntries() -> [ThemedMenuEntry] {
        let finishCandidates = ScheduledFinishCandidates.current()
        let account = AgentAccountDiscovery.account(
            for: agentSession.kind,
            handle: agentSession.accountHandle
        )
        if let account { AccountUsageService.shared.refresh(account) }

        return ScheduleMenu.entries(
            usage: account.flatMap { AccountUsageService.shared.usage(for: $0) },
            metering: agentSession.model,
            canWaitForConversation: !finishCandidates.isEmpty
        ) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .at(let date, let anchor):
                self.scheduleComposerContents(at: date, anchor: anchor)
            case .whenConversationFinishes:
                self.presentScheduledFinishPicker(candidates: finishCandidates)
            case .custom:
                ScheduleMessageAlert.present(
                    over: self.view.window,
                    title: L10n.string("Schedule message")
                ) { [weak self] date in
                    guard let self, let date else { return }
                    self.scheduleComposerContents(at: date, anchor: .wallClock)
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
            self.scheduleComposerContents(whenSessionFinishes: candidate.id)
        }
        presentAsSheet(picker)
    }

    // MARK: - Scheduling

    /// Takes what is in the composer and files it for later.
    ///
    /// Empties the box on success only, which is the rule the immediate send already follows: a
    /// refusal has to leave the words where the user can still act on them.
    func scheduleComposerContents(at date: Date, anchor: ScheduledMessage.Anchor) {
        let prompt = ConversationPrompt(
            text: promptView.stringValue,
            context: promptView.contextAttachments
        )
        guard !prompt.isEmpty else { return }

        let message = ScheduledMessage(
            dueAt: date,
            target: .session(sessionID),
            text: prompt.text,
            context: prompt.context,
            anchor: anchor
        )

        storeComposerContents(message)
    }

    func scheduleComposerContents(whenSessionFinishes watchedSessionID: SessionID) {
        let prompt = ConversationPrompt(
            text: promptView.stringValue,
            context: promptView.contextAttachments
        )
        guard !prompt.isEmpty else { return }

        let message = ScheduledMessage(
            whenSessionFinishes: watchedSessionID,
            target: .session(sessionID),
            text: prompt.text,
            context: prompt.context
        )
        guard storeComposerContents(message) else { return }

        // The watched turn may have ended while the sheet was open, after its last activity
        // event but before the record reached disk. Re-read the settled snapshot exactly once.
        ScheduledMessageScheduler.shared.evaluateCompletion(
            of: watchedSessionID,
            acceptsSettledSnapshot: true
        )
    }

    @discardableResult
    private func storeComposerContents(_ message: ScheduledMessage) -> Bool {
        switch ScheduledMessageStore.shared.add(message) {
        case .success:
            promptView.clear()
            SessionContinuityStore.shared.setConversationDraft("", for: sessionID)
            refreshScheduledStrip()
            return true
        case .failure(let refusal):
            apply(timeline.appendNotice(ScheduledRefusalText.sentence(for: refusal), kind: .error))
            return false
        }
    }

    // MARK: - The Strip

    /// Restates the strip from the store. One direction only, exactly as the outbox rail is
    /// drawn: the store is the truth and the view is drawn from it.
    func refreshScheduledStrip() {
        guard isViewLoaded else { return }
        let now = Date()
        scheduledStrip.setRows(
            ScheduledMessageStore.shared.messages(for: sessionID).map { message in
                ScheduledMessageStripView.Row(
                    id: message.id,
                    summary: message.summary,
                    timing: ScheduledTiming.sentence(for: message, from: now),
                    problem: ScheduledTiming.problem(for: message.state)
                )
            }
        )
    }

    func wireScheduledStrip() {
        scheduledStrip.onRemove = { [weak self] id in
            ScheduledMessageStore.shared.remove(id)
            self?.refreshScheduledStrip()
        }

        // Editing puts it back where it came from, reusing the queue's own rule: whatever is
        // half-typed is not thrown away to make room for it.
        scheduledStrip.onEdit = { [weak self] id in
            guard let self, let message = ScheduledMessageStore.shared[id] else { return }

            let draft = ConversationPrompt(
                text: self.promptView.stringValue,
                context: self.promptView.contextAttachments
            )
            if !draft.isEmpty { self.outbox.append(draft) }

            ScheduledMessageStore.shared.remove(id)
            self.promptView.stringValue = message.text
            self.promptView.clearContextAttachments()
            for attachment in message.context {
                self.promptView.addContextAttachment(attachment)
            }
            SessionContinuityStore.shared.setConversationDraft(message.text, for: self.sessionID)
            self.view.window?.makeFirstResponder(self.promptView)
            self.refreshOutboxRail()
            self.refreshScheduledStrip()
        }

        scheduledStrip.onSendNow = { [weak self] id in
            guard let self, let message = ScheduledMessageStore.shared[id] else { return }
            ScheduledMessageStore.shared.remove(id)
            _ = self.sendAppPrompt(message.text, context: message.context)
            self.refreshScheduledStrip()
        }
    }
}

// MARK: - Timing Sentences

/// How a waiting send says when it goes, and what is wrong when something is.
///
/// Its own type so the strip, the review sheet and the draft view cannot describe the same record
/// three different ways.
@MainActor
enum ScheduledTiming {

    static func sentence(for message: ScheduledMessage, from now: Date = Date()) -> String {
        switch message.trigger {
        case .time(let time):
            return sentence(for: time.dueAt, from: now)
        case .sessionFinished(let sessionID):
            let title = ProjectStore.shared.session(withID: sessionID)?.displayTitle
                ?? L10n.string("Conversation")
            return L10n.format("When “%@” finishes", title)
        }
    }

    static func sentence(for date: Date, from now: Date = Date()) -> String {
        L10n.format(
            "%@ · in %@",
            UsageFormat.absolute(date, from: now),
            UsageFormat.remaining(until: date, from: now)
        )
    }

    /// The sentence that replaces the timing when the clock is no longer the thing to say.
    static func problem(for state: ScheduledMessage.State) -> String? {
        switch state {
        case .armed: return nil
        case .waiting(let reason): return reason
        case .missed: return L10n.string("Missed while Threading was closed")
        case .failed(let reason): return reason
        }
    }
}

// MARK: - Refusal Sentences

/// The prose for a refusal the store stated as a value.
@MainActor
enum ScheduledRefusalText {
    static func sentence(for refusal: ScheduledMessageStore.Refusal) -> String {
        switch refusal {
        case .empty:
            return L10n.string("There is nothing here to schedule.")
        case .targetFull(let limit):
            return L10n.format(
                "%lld messages are already scheduled here. Send or remove one first.",
                Int64(limit)
            )
        case .storeFull(let limit):
            return L10n.format(
                "%lld messages are already scheduled. Send or remove one first.",
                Int64(limit)
            )
        case .inThePast:
            return L10n.string("That moment has already passed.")
        case .writesBlocked:
            return L10n.string("Scheduled messages could not be saved, so this was not taken.")
        }
    }
}
