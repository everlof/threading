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
        guard let session = currentSession else { return [] }
        let finishCandidates = ScheduledFinishCandidates.current()
        let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        )
        if let account { AccountUsageService.shared.refresh(account) }

        return ScheduleMenu.entries(
            usage: account.flatMap { AccountUsageService.shared.usage(for: $0) },
            metering: session.model,
            canWaitForConversation: !finishCandidates.isEmpty
        ) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .at(let date, let anchor):
                self.scheduleComposerContents(at: date, anchor: anchor)
            case .whenConversationFinishes:
                self.presentScheduledFinishPicker(candidates: finishCandidates)
            case .custom:
                ScheduleMomentPickerViewController.present(
                    over: self,
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
    ///
    /// **Images come too.** This surface never refused them the way the draft view did — it
    /// simply read the text and the context and left the pictures in the box to be cleared, so a
    /// reply scheduled with a screenshot attached arrived without it. They are taken custody of
    /// here for the same reason and by the same route as a scheduled session start.
    func scheduleComposerContents(at date: Date, anchor: ScheduledMessage.Anchor) {
        let prompt = ConversationPrompt(
            text: promptView.stringValue,
            context: promptView.contextAttachments
        )
        let id = ScheduledMessageID()
        guard let attachments = takeCustodyOfAttachments(for: id) else { return }
        guard !prompt.isEmpty || !attachments.isEmpty else { return }

        let message = ScheduledMessage(
            id: id,
            dueAt: date,
            target: .session(sessionID),
            text: prompt.text,
            context: prompt.context,
            attachments: attachments,
            anchor: anchor
        )

        storeComposerContents(message)
    }

    func scheduleComposerContents(whenSessionFinishes watchedSessionID: SessionID) {
        let prompt = ConversationPrompt(
            text: promptView.stringValue,
            context: promptView.contextAttachments
        )
        let id = ScheduledMessageID()
        guard let attachments = takeCustodyOfAttachments(for: id) else { return }
        guard !prompt.isEmpty || !attachments.isEmpty else { return }

        let message = ScheduledMessage(
            id: id,
            whenSessionFinishes: watchedSessionID,
            target: .session(sessionID),
            text: prompt.text,
            context: prompt.context,
            attachments: attachments
        )
        guard storeComposerContents(message) else { return }

        // The watched turn may have ended while the sheet was open, after its last activity
        // event but before the record reached disk. Re-read the settled snapshot exactly once.
        ScheduledMessageScheduler.shared.evaluateCompletion(
            of: watchedSessionID,
            acceptsSettledSnapshot: true
        )
    }

    /// Copies the box's pictures into the app's own keeping under the id this record will have.
    /// Answers nil once the refusal has been said, leaving the composer holding everything.
    private func takeCustodyOfAttachments(
        for id: ScheduledMessageID
    ) -> [ScheduledAttachment]? {
        guard let taken = ScheduledAttachmentStore.shared.take(
            promptView.attachmentPaths,
            for: id
        ) else {
            apply(timeline.appendNotice(
                L10n.string("The attached images could not be kept, so this was not scheduled."),
                kind: .error
            ))
            return nil
        }
        return taken
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
            // Nothing owns the copies this attempt took once the record is refused.
            ScheduledMessageStore.shared.attachments.release(message.id)
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
                    summary: ScheduledTiming.summary(of: message),
                    timing: ScheduledTiming.sentence(
                        for: message,
                        from: now,
                        watchedSessionTitle: watchedSessionTitle(for: message)
                    ),
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

            // Before the removal: `remove` deletes the pictures this record owns.
            let images = ScheduledMessageStore.shared.attachments.detach(message)
            ScheduledMessageStore.shared.remove(id)
            self.promptView.stringValue = message.text
            self.promptView.clearContextAttachments()
            self.promptView.attachFiles(at: images)
            for attachment in message.context {
                self.promptView.addContextAttachment(attachment)
            }
            SessionContinuityStore.shared.setConversationDraft(
                message.text,
                context: message.context,
                for: self.sessionID
            )
            self.view.window?.makeFirstResponder(self.promptView)
            self.refreshOutboxRail()
            self.refreshScheduledStrip()
        }

        scheduledStrip.onSendNow = { [weak self] id in
            guard let self, let message = ScheduledMessageStore.shared[id] else { return }
            let images = ScheduledMessageStore.shared.attachments.detach(message)
            ScheduledMessageStore.shared.remove(id)
            let handover = self.handingOver(images, appendedTo: message.text)
            _ = self.sendAppPrompt(
                handover.text,
                context: message.context,
                attachmentIDs: handover.attachmentIDs
            )
            self.refreshScheduledStrip()
        }
    }

    /// Files a waiting send's pictures with this conversation and puts their paths on the end of
    /// its words, which is the only form of an image either CLI reads.
    private func handingOver(
        _ paths: [String],
        appendedTo text: String
    ) -> (text: String, attachmentIDs: [String]) {
        // The folder comes from the store rather than from the controller's own `project`, which
        // is private to its file — and the store is the same answer the unattended delivery uses,
        // so a picture lands in the same place whichever route sent it.
        guard !paths.isEmpty,
              let folder = projectedWorkingDirectory(for: sessionID)
        else { return (text, []) }

        let handover = PromptAttachment.handOverRecording(
            paths: paths,
            sessionID: sessionID,
            projectRoot: URL(fileURLWithPath: folder, isDirectory: true)
        )
        return (
            PromptAttachment.appending(paths: handover.paths, to: text),
            handover.attachments.map(\.id)
        )
    }

    private func watchedSessionTitle(for message: ScheduledMessage) -> String? {
        guard case .sessionFinished(let watchedSessionID) = message.trigger else { return nil }
        return projectedSession(for: watchedSessionID)?.displayTitle
    }

    // MARK: - The Curfew Chip

    /// Restates the footer's curfew chip from the resolution, and nothing else.
    ///
    /// **Present only while a curfew resolves**, whichever scope answered — the chat's own rule,
    /// its checkout's, or the standing quiet hours every session follows. A conversation with no
    /// curfew is the ordinary case and gets no chip, rather than a permanent slot saying so.
    ///
    /// The title is a glance and the tooltip is the ledger: "Until 04:00" is what somebody needs
    /// while typing, and the whole ladder — the wrap-up, each interrupt, the honest clause where
    /// Threading cannot tell whether the session is working — is what they need once they stop to
    /// ask. Same sentence as the pane's own strip, from the same writer.
    func refreshCurfewChip() {
        guard isViewLoaded else { return }
        let now = Date()
        let answer = CurfewResolution.answer(forSessionID: sessionID, now: now)
        if case .usageThreshold(let percent, _, _, let windowID)? = answer.condition,
           answer.curfew == nil {
            curfewChip.isHidden = false
            curfewChip.configure(
                symbolName: CurfewDefaults.symbol,
                title: CurfewReceiptWords.usageThreshold(percent: percent, windowID: windowID)
            )
            curfewChip.toolTip = CurfewReceiptWords.usageThresholdHelp
            return
        }
        guard let curfew = answer.curfew else {
            curfewChip.isHidden = true
            return
        }

        curfewChip.isHidden = false
        let title: String
        if case .usageReset(_, _, _, let windowID)? = answer.condition,
           now < curfew.deadline {
            title = L10n.format("Until the %@ window resets", windowID)
        } else {
            title = Self.curfewChipTitle(for: curfew, now: now)
        }
        curfewChip.configure(
            symbolName: CurfewDefaults.symbol,
            title: title
        )
        // `configure` puts the title on the tooltip, so what the chip does not have room to say
        // has to be said after it.
        if case .usageReset(_, _, _, let windowID)? = answer.condition,
           now < curfew.deadline {
            curfewChip.toolTip = L10n.format(
                "Stops at the %@ window’s scheduled reset, or sooner if the provider resets that same window early.",
                windowID
            )
        } else {
            curfewChip.toolTip = CurfewReceiptWords.stripSentence(
                curfew: curfew,
                state: SessionCurfewCenter.shared.state(for: sessionID),
                canTellWorking: SessionCurfewCenter.shared.canTellWorking(sessionID: sessionID),
                now: now
            )
        }
    }

    /// Two tenses, the strip's own rule and its own words: a fence that has not closed yet and one
    /// that has are different news, and the chip is read at a glance rather than as a ledger.
    private static func curfewChipTitle(for curfew: ResolvedCurfew, now: Date) -> String {
        let time = ScheduledTimePresets.time(curfew.deadline)
        return now < curfew.deadline
            ? L10n.format("Until %@", time)
            : L10n.format("Curfew since %@", time)
    }

    /// The rows behind the chip — the same menu the sidebar fold and the draft view open, so the
    /// question is answered identically wherever it is asked.
    ///
    /// Built fresh on every open, like the schedule menu beside it: a quiet-hours window switched
    /// on since the last press, or a usage window that reset five minutes ago, must not still be
    /// offered as it was.
    func curfewMenuEntries() -> [ThemedMenuEntry] {
        guard let session = currentSession else { return [] }
        let now = Date()

        // The account's cached reading, refreshed once for the whole menu rather than once per
        // row — `scheduleMenuEntries`' rule, and the same reason: a menu is built in one run-loop
        // pass and a usage fetch is a network round trip.
        let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        )
        if let account { AccountUsageService.shared.refresh(account) }

        return CurfewMenu.entries(
            now: now,
            usage: account.flatMap { AccountUsageService.shared.usage(for: $0) },
            metering: session.model,
            quietHours: CurfewSettings.shared.preferences.quietHours,
            resolved: CurfewResolution.answer(forSessionID: sessionID, now: now),
            holds: CurfewHoldPolicy.isHeld(sessionID: sessionID, at: now)
        ) { [weak self] choice in
            self?.chooseCurfew(choice)
        }
    }

    private func chooseCurfew(_ choice: CurfewMenu.Choice) {
        switch choice {
        case .atUsage(let percent, let windowID):
            SessionCurfewCenter.shared.setCurfewAtUsage(
                percent: percent, windowID: windowID, forSessionID: sessionID
            )
        case .at(let deadline):
            SessionCurfewCenter.shared.setCurfew(.until(deadline), forSessionID: sessionID)
        case .atQuietHours(let start):
            // Resolved to a moment here rather than stored as a standing intention. The draft
            // view keeps the *choice* because the session it belongs to does not exist yet and
            // its start may be days away; this conversation is already running, so "when quiet
            // hours next begin" has exactly one answer and it is the one the menu just named.
            SessionCurfewCenter.shared.setCurfew(.until(start), forSessionID: sessionID)
        case .untilUsageReset(let expectedAt, let windowID):
            SessionCurfewCenter.shared.setCurfewUntilUsageReset(
                expectedAt: expectedAt,
                windowID: windowID,
                forSessionID: sessionID
            )
        case .exempt:
            // Nil where nothing would have held this chat anyway: an exemption from a standing
            // window that is switched off is a rule about nothing, and writing it would stop the
            // session following the window the user turns on tomorrow. `chooseLimitRecovery`'s
            // rule, which is why the field is optional rather than a plain flag.
            let inherited = CurfewResolution.inherited(beyondSessionID: sessionID)
            SessionCurfewCenter.shared.setCurfew(
                inherited == nil ? nil : .exempt,
                forSessionID: sessionID
            )
        case .inherit:
            SessionCurfewCenter.shared.setCurfew(nil, forSessionID: sessionID)
        case .lift:
            SessionCurfewCenter.shared.lift(sessionID: sessionID)
        case .custom:
            ScheduleMomentPickerViewController.present(
                over: self,
                title: L10n.string("End this session"),
                confirmTitle: L10n.string("Set Curfew")
            ) { [weak self] date in
                guard let self, let date else { return }
                SessionCurfewCenter.shared.setCurfew(.until(date), forSessionID: self.sessionID)
            }
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

    /// What a waiting row says it is holding.
    ///
    /// The pictures are counted rather than left implicit: by the time this row is read the file
    /// the user attached is gone from the temporary directory, and the count is the only evidence
    /// on screen that the app took its own copy. A send with no images reads exactly as before.
    static func summary(of message: ScheduledMessage) -> String {
        let words = message.summary
        // A wordless send already *is* its count, and appending it would read "1 image · 1 image".
        guard let note = message.attachmentNote, words != note else { return words }
        return L10n.format("%@ · %@", words, note)
    }

    static func sentence(
        for message: ScheduledMessage,
        from now: Date = Date(),
        watchedSessionTitle: String? = nil
    ) -> String {
        switch message.trigger {
        case .time(let time):
            return sentence(for: time.dueAt, from: now)
        case .sessionFinished:
            let title = watchedSessionTitle ?? L10n.string("Conversation")
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

    /// The stronger receipt for a session that does not exist yet.
    ///
    /// A conversation row only has to say when its already-known message sends. On the draft
    /// surface, the primary button still says "Start session", so a bare "When … finishes"
    /// looks like a condition waiting for that button rather than confirmation that Threading
    /// will create the session itself. State both facts in one line.
    static func automaticStartSentence(
        for message: ScheduledMessage,
        from now: Date = Date(),
        watchedSessionTitle: String? = nil
    ) -> String {
        switch message.trigger {
        case .time(let time):
            return L10n.format(
                "Scheduled · starts automatically %@",
                sentence(for: time.dueAt, from: now)
            )
        case .sessionFinished:
            let title = watchedSessionTitle ?? L10n.string("Conversation")
            return L10n.format(
                "Scheduled · starts automatically when “%@” finishes",
                title
            )
        }
    }

    /// The trigger phrased as a cause for the scheduled conversation's empty state.
    ///
    /// Reset-backed clock records still carry an exact instant, but the reset is the reason the
    /// session starts. Naming both prevents the timestamp from making that dependency invisible.
    static func automaticStartCauseSentence(
        for message: ScheduledMessage,
        from now: Date = Date(),
        watchedSessionTitle: String? = nil
    ) -> String {
        switch message.trigger {
        case .time(let time):
            switch time.anchor {
            case .wallClock:
                return L10n.format(
                    "Starts automatically %@",
                    sentence(for: time.dueAt, from: now)
                )
            case .usageWindowReset:
                return L10n.format(
                    "Starts automatically after the usage window resets · expected %@",
                    sentence(for: time.dueAt, from: now)
                )
            }
        case .sessionFinished:
            let title = watchedSessionTitle ?? L10n.string("Conversation")
            return L10n.format(
                "Starts automatically when “%@” finishes",
                title
            )
        }
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
