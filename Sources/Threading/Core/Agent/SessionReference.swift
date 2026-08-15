import Foundation

// MARK: - Session Reference

/// One session, as another agent needs it named — what a sidebar row becomes when it is dragged
/// into a session's input.
///
/// The user's habit this replaces was **Copy ▸ Agent Session ID** followed by a sentence typed
/// by hand telling the agent what the id was and what to do with it. Both halves are what a
/// reference carries: the identifiers, and the words that say which tool takes which one. It is
/// deliberately a *name card* rather than a live listing — no `working`/`idle`, no surface —
/// because a reference sits in a composer for as long as the person keeps typing, and the
/// facts that change from one minute to the next are `list_sessions`' to report when asked.
/// Everything here is stable for the life of the session: its ids, its runtime, its project.
///
/// The one seam beneath both surfaces: a terminal is pasted `SessionReferenceBrief.terminalText`
/// (the bracketed line — see there for why brackets), a native composer stages
/// `SessionReferenceBrief.contextAttachment` (a `ConversationContextAttachment` whose source is
/// `.session`, which is what a receipt chip, a draft, a scheduled turn and the transport
/// envelope all already carry). Same words in both, so what the agent is told does not depend
/// on which surface the drop happened to land on.
struct SessionReference: Equatable, Sendable {

    let sessionID: SessionID

    /// The session's sidebar title, already fenced (`WorkspaceControlPlane.safeHeaderTitle`):
    /// a session names itself, and a title holding `]` would close the terminal frame early.
    let title: String

    let kind: AgentKind

    let projectID: ProjectID
    let projectName: String

    /// The checkout the session executes in — a managed worktree's path when it has one,
    /// which is what makes it the path worth telling another agent about.
    let projectPath: String

    /// The id the runtime's own CLI knows the conversation by — the transcript's name, the
    /// `--resume` argument. Nil until the agent has named the conversation.
    let agentSessionID: String?

    /// Where the runtime's transcript is on disk, when Threading knows how to find one.
    let transcriptPath: String?

    init(
        sessionID: SessionID,
        title: String,
        kind: AgentKind,
        projectID: ProjectID,
        projectName: String,
        projectPath: String,
        agentSessionID: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.sessionID = sessionID
        self.title = WorkspaceControlPlane.safeHeaderTitle(title)
        self.kind = kind
        self.projectID = projectID
        self.projectName = projectName
        self.projectPath = projectPath
        self.agentSessionID = agentSessionID
        self.transcriptPath = transcriptPath
    }

    /// The id every Threading tool takes, spelt the way `list_sessions` prints it.
    var threadingID: String { sessionID.uuidString.lowercased() }
}

// MARK: - Session Reference Reader

/// The session a reference is being handed to, reduced to the facts that change what it can
/// do with one.
///
/// A reference is only useful if it says how to *act*, and what a receiver can do depends on
/// where it stands: `send_to_session` reaches only the receiver's own project, and only a
/// runtime surface that receives Threading's MCP bridge has the tools at all. Resolved by the
/// drop site rather than carried in the drag, because the same dragged row means different
/// things dropped on different sessions.
struct SessionReferenceReader: Equatable, Sendable {

    /// The receiving session, so a row dragged onto its own session can be told so instead of
    /// being told to message itself.
    let sessionID: SessionID?

    let projectID: ProjectID?

    /// Whether the receiver has `list_sessions`, `send_to_session` and `watch_session`: its
    /// surface receives the bridge, and the user has the "Other sessions" tool group on.
    let hasSessionTools: Bool

    init(sessionID: SessionID?, projectID: ProjectID?, hasSessionTools: Bool) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.hasSessionTools = hasSessionTools
    }
}

// MARK: - Session Reference Brief

/// The words a reference is delivered as, for either surface.
///
/// Every sentence is one of three: *what it is* (title, runtime, ids, where it lives), *how to
/// reach it* (which tools, with which id, or why not), and *what it is called elsewhere* (the
/// runtime's own id and its transcript). The middle one is the whole reason the reference exists
/// — the agent has to know, without asking, that the Threading id goes to `send_to_session` and
/// the runtime's own id goes nowhere near it, and that a session in another project cannot be
/// reached at all.
enum SessionReferenceBrief {

    /// The line a terminal is pasted.
    ///
    /// Bracketed because a TUI's composer has no sidecar: whatever the person types after the
    /// drop shares the input line with the reference, and the frame is what says where the
    /// reference stops and their sentence starts — the same convention as the `[Image #1]` and
    /// `[Pasted text]` tokens both CLIs draw. One line, because a multi-line paste is folded
    /// into a placeholder the person can no longer read. The trailing space is `TerminalDrop`'s:
    /// a second drop or a typed word must not run into the bracket.
    static func terminalText(
        for reference: SessionReference,
        reader: SessionReferenceReader
    ) -> String {
        "[" + sentences(for: reference, reader: reader).joined(separator: " ") + "] "
    }

    /// The receipt a native composer stages, and the transport carries.
    ///
    /// The brief travels in `excerpt`, which is the one field of the envelope the provider is
    /// handed verbatim; the Threading id sits in `locator` on its own so a client that draws
    /// the receipt has the identifier without parsing prose. The reference stays a `.reference`,
    /// never a `.comment`: nothing is being asked yet, the person is still typing.
    static func contextAttachment(
        for reference: SessionReference,
        reader: SessionReferenceReader
    ) -> ConversationContextAttachment {
        ConversationContextAttachment(
            kind: .reference,
            source: .session,
            title: reference.title,
            excerpt: sentences(for: reference, reader: reader).joined(separator: " "),
            locator: reference.threadingID
        )
    }

    /// The brief as sentences, so both surfaces say the same thing.
    static func sentences(
        for reference: SessionReference,
        reader: SessionReferenceReader
    ) -> [String] {
        let isSelf = reader.sessionID == reference.sessionID
        let isSameProject = reader.projectID == reference.projectID
        var lines: [String] = []

        // What it is.
        if isSelf {
            lines.append(
                "This is your own Threading session, “\(reference.title)” — Threading id "
                    + "\(reference.threadingID)."
            )
        } else {
            let location = isSameProject
                ? "in this project"
                : "in the project “\(reference.projectName)” at \(reference.projectPath)"
            lines.append(
                "Threading session “\(reference.title)” — \(reference.kind.displayName), "
                    + "Threading id \(reference.threadingID), \(location)."
            )
        }

        // How to reach it.
        if isSelf {
            lines.append(
                "It cannot be messaged — it is you: whatever is asked of it is being asked of you."
            )
        } else if !isSameProject {
            lines.append(
                "It is in another project, so list_sessions, send_to_session and watch_session "
                    + "cannot reach it from here."
            )
        } else if reader.hasSessionTools {
            lines.append(
                "Reach it with the Threading MCP tools: list_sessions reports whether it is "
                    + "working, idle or dormant right now; send_to_session with session_id "
                    + "\"\(reference.threadingID)\" hands it a message as its next turn; "
                    + "watch_session waits for its current turn to settle."
            )
        } else {
            lines.append(
                "This session has no Threading session tools, so it cannot list, message or "
                    + "wait for it — tell the user what to pass on."
            )
        }

        // What it is called elsewhere. Claude and Grok are handed Threading's id at launch, so
        // for them the runtime's own id *is* the Threading id — said plainly, because "not a
        // Threading id" beside the identical string would be the one lie in the brief.
        let runtime = reference.kind.displayName
        let transcript = reference.transcriptPath.map { "; its transcript is \($0)" } ?? ""
        switch reference.agentSessionID {
        case let agentSessionID? where agentSessionID == reference.threadingID:
            lines.append(
                "Its own \(runtime) session id is that same string, minted by Threading"
                    + "\(transcript)."
            )
        case let agentSessionID?:
            lines.append(
                "Its own \(runtime) session id is \(agentSessionID) — not a Threading id"
                    + "\(transcript)."
            )
        case nil:
            lines.append("Its \(runtime) conversation has no id of its own yet.")
        }

        return lines
    }
}

// MARK: - Live Resolution

extension SessionReference {

    /// The reference for a session in the store, or nil once the row is gone.
    ///
    /// Read at the drop, not at the drag: the pasteboard carries only the id, and the title,
    /// project and transcript are whatever is true when the reference lands. The transcript
    /// and the path come from the *execution* project — the same answer the sidebar's Copy
    /// submenu gives for "Worktree Path" and "Transcript Path", so a reference names the
    /// files an agent would actually find.
    @MainActor
    static func live(for sessionID: SessionID, in store: ProjectStore = .shared) -> SessionReference? {
        guard let session = store.session(withID: sessionID),
              let project = store.project(forSessionID: sessionID),
              let execution = store.executionProject(forSessionID: sessionID) else { return nil }

        return SessionReference(
            sessionID: sessionID,
            title: session.displayTitle,
            kind: session.kind,
            projectID: project.id,
            projectName: project.name,
            projectPath: execution.folderPath,
            agentSessionID: session.resumeState.transcriptID?.rawValue,
            transcriptPath: SessionTranscript.url(for: session, in: execution)?.path
        )
    }
}

extension SessionReferenceReader {

    /// Which surface the receiving session reads the reference on. Named by the drop site,
    /// which knows for certain, rather than inferred from the record: the bridge is granted per
    /// surface (`.terminalThreadingBridge` against `.threadingBridge`), and a session's stored
    /// preference can differ from the surface actually in front of the user.
    enum Surface: Equatable, Sendable {
        case terminal
        case conversation
    }

    /// The reader for a live session, or a reader with no session for a receiver the store
    /// does not know — which is told the plain facts and no tools.
    @MainActor
    static func live(
        for sessionID: SessionID,
        on surface: Surface,
        in store: ProjectStore = .shared
    ) -> SessionReferenceReader {
        guard let session = store.session(withID: sessionID) else {
            return SessionReferenceReader(sessionID: sessionID, projectID: nil, hasSessionTools: false)
        }
        let receivesBridge: Bool
        switch surface {
        case .terminal: receivesBridge = session.kind.supports(.terminalThreadingBridge)
        case .conversation: receivesBridge = session.kind.supports(.threadingBridge)
        }
        return SessionReferenceReader(
            sessionID: sessionID,
            projectID: store.project(forSessionID: sessionID)?.id,
            hasSessionTools: receivesBridge && MCPToolCatalog.isEnabled(MCPToolCatalog.workspace)
        )
    }
}

// MARK: - Session Reference Handoff

/// What a drop site calls: the ids off the pasteboard in, the words for its surface out.
///
/// Rows the store no longer has are dropped silently — a session deleted between pick-up and
/// release is not a reference to anything — and the rest are briefed for the receiver in the
/// order they were dragged.
@MainActor
enum SessionReferenceHandoff {

    /// One bracketed reference per session, run together the way `TerminalDrop.text` runs
    /// paths together: each ends in its own trailing space.
    static func terminalText(
        referencing sessionIDs: [SessionID],
        readBy receiver: SessionID?
    ) -> String {
        let reader = receiver.map { SessionReferenceReader.live(for: $0, on: .terminal) }
            ?? SessionReferenceReader(sessionID: nil, projectID: nil, hasSessionTools: false)
        return sessionIDs
            .compactMap { SessionReference.live(for: $0) }
            .map { SessionReferenceBrief.terminalText(for: $0, reader: reader) }
            .joined()
    }

    /// One receipt per session, for a native composer to stage.
    static func contextAttachments(
        referencing sessionIDs: [SessionID],
        readBy receiver: SessionID
    ) -> [ConversationContextAttachment] {
        let reader = SessionReferenceReader.live(for: receiver, on: .conversation)
        return sessionIDs
            .compactMap { SessionReference.live(for: $0) }
            .map { SessionReferenceBrief.contextAttachment(for: $0, reader: reader) }
    }
}
