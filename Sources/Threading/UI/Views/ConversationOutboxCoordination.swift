import AppKit

/// Queueing, steering and stopping, on top of `ConversationViewController`.
///
/// Split out for the same reason the rendering is: the conversation already owns a transcript, a
/// permission broker, a minimap and a composer, and the rules below are a subject of their own.
/// Nothing here names a provider — every question about what the transport can do goes through
/// `ConversationStreamSession`'s turn-control surface.
extension ConversationViewController {

    // MARK: - What The Composer Is For

    /// Resolves the transport's answers into the one value `PromptView` understands.
    ///
    /// Called on every send-availability change, every lifecycle report and every settle, because
    /// all three can move it and the box must never be offering something the wire has stopped
    /// accepting.
    func refreshComposerMode() {
        guard isViewLoaded else { return }

        let mode: PromptComposerMode = stream.canSend
            ? .ready
            : .working(
                canStop: stream.canInterrupt,
                canSteer: stream.steerAvailability.isAvailable
            )

        promptView.composerMode = mode
        promptView.placeholder = placeholder(for: mode)
        refreshOutboxRail()
    }

    /// What the empty box invites, which is not the same sentence in all three states.
    ///
    /// A composer that says "Reply to Claude" while Claude is mid-turn is describing something
    /// that will not happen for a minute — and the difference between "this sends" and "this
    /// waits" is exactly what somebody needs to know before they start typing.
    private func placeholder(for mode: PromptComposerMode) -> String {
        switch mode {
        case .ready:
            L10n.format("Reply to %@", agentSession.kind.displayName)
        case .working(_, let canSteer) where canSteer:
            L10n.string("Queue a message, or ⌘Return to add it to this turn")
        case .working:
            L10n.string("Queue a message for when this turn finishes")
        }
    }

    // MARK: - Queueing

    /// Takes a message the transport cannot accept yet.
    ///
    /// The alternative this replaces was silence: `submit` guarded on `stream.canSend` and
    /// returned false, so Return did nothing at all while the agent worked and the text simply
    /// sat in the box. Somebody would type a follow-up, press Return, watch nothing happen, and
    /// have no way to know whether it had been taken.
    @discardableResult
    func enqueue(_ prompt: ConversationPrompt) -> Bool {
        guard outbox.acceptsMore else {
            apply(timeline.appendNotice(
                L10n.format(
                    "The queue is full at %lld messages. Send or remove one before adding another.",
                    Int64(ConversationOutboxDefaults.maximumItems)
                ),
                kind: .error
            ))
            return false
        }

        guard outbox.append(prompt) != nil else { return false }

        promptView.clear()
        SessionContinuityStore.shared.setConversationDraft("", for: sessionID)
        refreshOutboxRail()
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
        return true
    }

    /// Hands the next queued message over, once the turn that was blocking it has settled.
    ///
    /// One at a time. Two messages somebody wrote separately are two turns, and concatenating
    /// them would be the composer making a decision the user did not.
    ///
    /// Routed through the same `prepareTurn` baseline as a directly typed message: a queued turn
    /// whose diff baseline was never taken shows the previous turn's changes as its own.
    func flushOutboxIfReady() {
        guard isViewLoaded, stream.canSend, !isPreparingTurn else { return }
        guard let item = outbox.handOverNext() else { return }

        refreshOutboxRail()

        isPreparingTurn = true
        refreshInputControl()

        NativeGitTurnAdmission.admit(
            sessionID: sessionID,
            userTurnID: item.id.wireValue,
            transport: { [weak self] _ in
                self?.stream.send(item.prompt, identifiedBy: item.id) ?? false
            }
        ) { [weak self] admitted, _ in
            guard let self else { return }
            self.isPreparingTurn = false

            guard admitted else {
                // The transport refused after all — it exited between the settle and here. The
                // message goes back to the front of the queue rather than being lost.
                self.outbox.reclaim(item.id)
                self.refreshOutboxRail()
                self.refreshComposerMode()
                return
            }

            self.recordSentTurn(item.prompt)

            // A transport that reports nothing would leave this row saying "Sending…" forever.
            // Its message is in the transcript from here on, which is a truer record than a
            // queue row could be.
            if !self.stream.reportsMessageLifecycle {
                self.outbox.mark(item.id, as: .completed)
            }

            self.refreshOutboxRail()
            self.refreshComposerMode()
        }
    }

    // MARK: - Steering

    /// Adds a message to the turn already running.
    ///
    /// It goes into the transcript immediately as an ordinary user message, because that is where
    /// it went: it joins the running turn, shares its context and settles under the same terminal
    /// event. It is deliberately *not* a queue row — there is nothing left to reorder, and drawing
    /// it under the composer would imply it was still waiting.
    func steer(_ prompt: ConversationPrompt) {
        let id = ConversationMessageID()
        guard stream.steer(prompt, identifiedBy: id) else {
            // The turn ended, or turned out not to be steerable, between the chord and the wire.
            // Codex's `expectedTurnId` precondition exists to make exactly this catchable. The
            // answer is not to retry against a turn that is gone: it is to queue the message,
            // which is what the user would have got a keystroke later anyway.
            enqueue(prompt)
            return
        }

        apply(timeline.appendUserMessage(prompt.userMessage))
        recordSentTurn(prompt)
        promptView.clear()
        SessionContinuityStore.shared.setConversationDraft("", for: sessionID)
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
    }

    // MARK: - Stopping

    /// Ends the turn in flight, leaving the conversation open.
    ///
    /// The queue is deliberately untouched by default. Somebody who stops a turn has said
    /// something about *that turn*, not about the three messages they lined up behind it — and
    /// where the provider cancels its own copies, `still_queued` is how we learn which of ours
    /// survived so they can be put back rather than silently lost.
    func stopCurrentTurn() {
        guard stream.canInterrupt else { return }

        isStoppingTurn = true
        refreshComposerMode()

        stream.interrupt { [weak self] receipt in
            guard let self else { return }
            self.isStoppingTurn = false

            switch receipt {
            case .reported(let stillQueued):
                self.reclaimMessagesNotQueued(besides: stillQueued)
            case .acknowledged:
                break
            case .failed(let reason):
                self.apply(self.timeline.appendNotice(reason, kind: .error))
            }

            self.refreshComposerMode()
        }
    }

    /// Puts back anything the provider's own queue dropped when it was interrupted.
    ///
    /// Only meaningful where the provider both holds a queue and names what survived. Threading's
    /// own outbox is the surviving copy either way, so this restores rows to the user's control
    /// rather than resending anything.
    private func reclaimMessagesNotQueued(besides stillQueued: [ConversationMessageID]) {
        let surviving = Set(stillQueued)
        for item in outbox.items where !item.state.isPending && !surviving.contains(item.id) {
            outbox.reclaim(item.id)
        }
        refreshOutboxRail()
    }

    // MARK: - Rail

    /// Restates the rail from the outbox.
    ///
    /// One direction only: the model is the truth and the view is drawn from it. The rail reports
    /// gestures back as intentions — move this, remove this, edit this — and never mutates.
    func refreshOutboxRail() {
        guard isViewLoaded else { return }
        outboxRail.setRows(outbox.items.map {
            ConversationOutboxRailView.Row(id: $0.id, summary: $0.summary, state: $0.state)
        })
    }

    func wireOutboxRail() {
        outboxRail.onMove = { [weak self] from, to in
            guard let self, self.outbox.movePending(from: from, to: to) else { return }
            self.refreshOutboxRail()
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(self.sessionID)
        }

        outboxRail.onRemove = { [weak self] id in
            guard let self, self.outbox.remove(id) else { return }
            self.refreshOutboxRail()
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(self.sessionID)
        }

        outboxRail.onEdit = { [weak self] id in
            self?.editQueuedMessage(id)
        }
    }

    /// Opens a queued message for editing, by putting it back in the box it came from.
    ///
    /// Rather than an inline editor: the composer already knows how to hold prose, staged context
    /// and images, and a second editing surface would be a second set of rules for the same
    /// content. Anything already being typed is queued first, so opening a row never costs
    /// somebody the sentence they were part-way through.
    func editQueuedMessage(_ id: ConversationMessageID) {
        guard let item = outbox[id], item.state.isPending else { return }

        let draft = ConversationPrompt(
            text: promptView.stringValue,
            context: promptView.contextAttachments
        )
        if !draft.isEmpty { outbox.append(draft) }

        outbox.remove(id)
        promptView.stringValue = item.prompt.text
        promptView.clearContextAttachments()
        for attachment in item.prompt.context {
            promptView.addContextAttachment(attachment)
        }
        SessionContinuityStore.shared.setConversationDraft(item.prompt.text, for: sessionID)
        view.window?.makeFirstResponder(promptView)
        refreshOutboxRail()
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
    }

    /// ↑ in an empty composer opens the last queued message, which is the Claude Code TUI's own
    /// affordance ("Press up to edit queued messages") and costs nothing to match.
    func editLastQueuedMessage() -> Bool {
        guard promptView.stringValue.isEmpty,
              let last = outbox.pending.last else { return false }
        editQueuedMessage(last.id)
        return true
    }

    // MARK: - Lifecycle Reports

    /// Records what the transport says became of a message we handed it.
    func applyMessageLifecycle(_ id: ConversationMessageID, _ state: MessageLifecycleState) {
        outbox.mark(id, as: state)
        refreshOutboxRail()
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
    }
}
