import Foundation

// MARK: - Session Context Handoff

/// Where a reference or a comment goes when the user stages one, whatever surface the session
/// happens to be running on.
///
/// The staging vocabulary — `ConversationContextAttachment`, the composer's receipt rail, the
/// typed envelope every native transport carries — was built for a native conversation surface,
/// which exists only for a session rendered natively. That is three of the four runtimes, and
/// only when the user has native Chat turned on for that session; everything else runs the
/// agent's own TUI in a PTY. So the Attachments pane's chat actions, the Git Review row's
/// reference actions and every sibling site were quietly absent for a terminal session, and the
/// one thing the feature exists to save — copy the path, switch panes, paste it, then type the
/// sentence — was still being done by hand exactly where it costs the most.
///
/// This is the seam that answers for both. A native conversation stages into its composer, which
/// keeps the receipt chip, the removal menu and the typed envelope. A terminal is *pasted into*,
/// because a terminal carries text and that is the whole of its input surface —
/// see `ConversationContextAttachment.plainText(omittingAnchor:)` for why it is prose rather than
/// the JSON envelope, and `TerminalDrop` for why an attachment's real path goes over first, alone,
/// in its own bracketed paste.
@MainActor
protocol SessionContextReceiving: AnyObject {
    func stageContextAttachment(_ attachment: ConversationContextAttachment)
    func sendContextAttachment(_ attachment: ConversationContextAttachment)
    @discardableResult
    func removeContextAttachment(id: UUID) -> Bool
}

extension SessionContextReceiving {
    @discardableResult
    func removeContextAttachment(id: UUID) -> Bool { false }
}

/// The smallest live-session projection the handoff policy needs. Keeping lookup behind this
/// boundary makes the routing independently testable and keeps Core unaware of the UI controller
/// that happens to render a native conversation.
@MainActor
protocol SessionContextDestinationQuerying {
    func contextReceiver(for sessionID: SessionID) -> (any SessionContextReceiving)?
    func runningTerminalInputSurface(
        for sessionID: SessionID
    ) -> (any AgentTerminalInputSurface)?
}

extension AgentRuntime: SessionContextDestinationQuerying {
    func contextReceiver(for sessionID: SessionID) -> (any SessionContextReceiving)? {
        conversationRuntimeSurface(for: sessionID)
    }

}

@MainActor
enum SessionContextHandoff {

    private static var liveDestinations: any SessionContextDestinationQuerying {
        AgentRuntime.shared
    }

    /// Which surface is holding this session's input right now.
    ///
    /// Resolved per call rather than cached: the same session moves between a native
    /// conversation and a terminal across relaunches, and a pane that remembered the answer
    /// would keep offering the door that closed.
    enum Destination {
        case conversation(any SessionContextReceiving)
        case terminal(any AgentTerminalInputSurface)
    }

    // MARK: - Routing

    static func destination(for sessionID: SessionID) -> Destination? {
        destination(for: sessionID, querying: liveDestinations)
    }

    static func destination(
        for sessionID: SessionID,
        querying destinations: any SessionContextDestinationQuerying
    ) -> Destination? {
        if let receiver = destinations.contextReceiver(for: sessionID) {
            return .conversation(receiver)
        }
        // A dead PTY swallows a paste without a trace, so a terminal is a destination only
        // while its agent is actually there to read one.
        guard let terminal = destinations.runningTerminalInputSurface(for: sessionID) else {
            return nil
        }
        return .terminal(terminal)
    }

    /// Whether this session can be handed context at all — the one question a pane asks before
    /// drawing the affordance.
    static func canReceiveContext(for sessionID: SessionID) -> Bool {
        destination(for: sessionID) != nil
    }

    // MARK: - Handing Over

    /// Holds the context beside the input without sending it, so the person can keep typing.
    ///
    /// `fileURL` is the attachment's real file on disk, which the terminal path needs and the
    /// native path already carries in the locator. Passing it is what turns a pasted path into
    /// an attached image instead of a line of text.
    static func stage(
        _ attachment: ConversationContextAttachment,
        fileURL: URL? = nil,
        for sessionID: SessionID
    ) {
        stage(
            attachment,
            fileURL: fileURL,
            for: sessionID,
            querying: liveDestinations
        )
    }

    static func stage(
        _ attachment: ConversationContextAttachment,
        fileURL: URL? = nil,
        for sessionID: SessionID,
        querying destinations: any SessionContextDestinationQuerying
    ) {
        switch destination(for: sessionID, querying: destinations) {
        case .conversation(let conversation):
            conversation.stageContextAttachment(attachment)
        case .terminal(let session):
            paste(attachment, fileURL: fileURL, into: session, submitting: false)
        case nil:
            break
        }
    }

    /// Hands the context over now, as its own turn.
    static func send(
        _ attachment: ConversationContextAttachment,
        fileURL: URL? = nil,
        for sessionID: SessionID
    ) {
        send(
            attachment,
            fileURL: fileURL,
            for: sessionID,
            querying: liveDestinations
        )
    }

    /// Removes a staged receipt from a native composer. A terminal paste has already crossed
    /// the transport boundary and is intentionally not presented as removable.
    @discardableResult
    static func remove(_ attachmentID: UUID, for sessionID: SessionID) -> Bool {
        guard case .conversation(let conversation) = destination(for: sessionID) else {
            return false
        }
        return conversation.removeContextAttachment(id: attachmentID)
    }

    static func send(
        _ attachment: ConversationContextAttachment,
        fileURL: URL? = nil,
        for sessionID: SessionID,
        querying destinations: any SessionContextDestinationQuerying
    ) {
        switch destination(for: sessionID, querying: destinations) {
        case .conversation(let conversation):
            conversation.sendContextAttachment(attachment)
        case .terminal(let session):
            paste(attachment, fileURL: fileURL, into: session, submitting: true)
        case nil:
            break
        }
    }

    // MARK: - Private

    private static func paste(
        _ attachment: ConversationContextAttachment,
        fileURL: URL?,
        into terminal: any AgentTerminalInputSurface,
        submitting: Bool
    ) {
        // The path goes over first and **alone**. Both CLIs read one arriving paste as a unit
        // and attach it as an image when the whole of it is a path with an image extension; a
        // path with a sentence after it is a sentence. See `TerminalDrop`.
        var anchorPasted = false
        if let fileURL {
            terminal.pasteTerminalText(TerminalDrop.text(for: [fileURL.path]))
            anchorPasted = true
        }

        let body = attachment.plainText(omittingAnchor: anchorPasted)
        if !body.isEmpty {
            terminal.pasteTerminalText(body)
        }
        guard submitting else { return }

        // **The Return is late on purpose.** Both CLIs resolve a pasted image path off the main
        // input path — reading the file, minting an `[Image #1]` — and a Return that arrives
        // mid-resolution submits the turn without the attachment the person just commented on.
        // The delay is short enough to read as immediate and is the whole cost of getting the
        // picture there; see `TerminalDefaults.pastedTurnSubmitDelay`.
        let delay = anchorPasted ? TerminalDefaults.pastedTurnSubmitDelay : 0
        guard delay > 0 else {
            terminal.insertTerminalText(TerminalDefaults.submitSequence)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak terminal] in
            terminal?.insertTerminalText(TerminalDefaults.submitSequence)
        }
    }
}
