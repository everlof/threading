import AppKit

// MARK: - App-Composed Messages

/// The door for messages the app composed on someone's behalf — a cross-session delivery, a
/// scheduled send — as opposed to text typed into this composer.
extension ConversationViewController: AppMessageReceiving {

    /// Takes an app-composed message, and answers with what actually happened to it.
    ///
    /// **Always through the outbox, never a direct transport write.** `flushOutboxIfReady` is
    /// the one send path that reclaims a message whose transport refused it after the settle —
    /// a direct send that failed late dropped the text with no notice, which for a message no
    /// composer still holds is destruction, a beat after the caller was told "delivered". The
    /// outbox also keeps the delivery honest on screen: a queued cross-session message is a
    /// row the user can edit or remove, exactly like one they queued themselves.
    ///
    /// Deliberately not `enqueue(_:)`, which is the composer's own door: that one clears the
    /// prompt box and the session's draft, and an app message must not cost the user the
    /// sentence they were part-way through.
    ///
    /// `.handedToTurn` needs every condition `flushOutboxIfReady` checks *and* an empty queue
    /// ahead of the message — with rows already waiting, ours joins the line and the honest
    /// answer is `.queuedBehindTurn`, whatever the transport's readiness.
    ///
    /// `origin` rides onto the row rather than being decided at the drain, because the drain
    /// looks at one item and this is the only place that knows where it came from: a curfew's
    /// wrap-up is the single message a held session still hands over.
    func acceptAppMessage(
        _ prompt: ConversationPrompt,
        origin: ConversationOutbox.Item.Origin,
        attachmentIDs: [String]
    ) -> AppMessageAcceptance {
        guard !prompt.isEmpty else { return .refused(.emptyText) }
        guard RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID) else {
            return .refused(.inputHeldRemotely)
        }
        guard outbox.acceptsMore else { return .refused(.queueFull) }

        let readyToHandOver = isViewLoaded && stream.canSend && !isPreparingTurn
            && outbox.pending.isEmpty
        guard let id = outbox.append(prompt, origin: origin) else { return .refused(.queueFull) }
        SessionAttachmentStore.shared.associate(
            attachmentIDs: attachmentIDs,
            withTurnID: id.wireValue,
            for: sessionID
        )

        refreshOutboxRail()
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)

        guard readyToHandOver else { return .queuedBehindTurn }
        flushOutboxIfReady()
        return .handedToTurn
    }

    /// Adds an app-composed message to the turn already running — `steer(_:)`'s twin, minus
    /// the two things that belong to the composer alone: it never clears the prompt box or
    /// the draft, and it never falls back to the queue. The composer's fallback is right for
    /// a person whose keystroke raced the settle; a control-plane caller asked specifically
    /// to join the running turn, and being quietly queued instead is the "silently degraded"
    /// answer the steer availability contract exists to prevent.
    func steerAppMessage(_ prompt: ConversationPrompt) -> AppMessageSteerResult {
        guard !prompt.isEmpty else { return .emptyText }
        guard RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID) else {
            return .inputHeldRemotely
        }
        if case .unavailable(let refusal) = stream.steerAvailability {
            return .refused(refusal)
        }

        let id = ConversationMessageID()
        guard stream.steer(prompt, identifiedBy: id) else {
            // The turn ended between the availability read and the wire.
            return .refused(.noActiveTurn)
        }

        apply(timeline.appendUserMessage(prompt.userMessage))
        recordSentTurn(prompt)
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
        return .steered
    }
}
