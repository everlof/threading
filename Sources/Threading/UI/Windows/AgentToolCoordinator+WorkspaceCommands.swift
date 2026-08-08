import AppKit

// MARK: - Workspace Commands

/// The "Other sessions" tools: the first commands that see past the calling session.
///
/// Every rule — who is in scope, who may be messaged, what a refusal is — lives in
/// `WorkspaceControlPlane`; this file owns only the words. A CLI or remote binding added later
/// calls the same plane and cannot come away with looser answers.
@MainActor
extension AgentToolCoordinator {

    // MARK: Listing

    func listProjectSessions(for sessionID: SessionID) -> MCPToolResult {
        switch dependencies.control.sessions(for: .agentSession(sessionID)) {
        case .failure(let refusal):
            return .failure(Self.words(for: refusal))
        case .success(let rows):
            let project = dependencies.projects.project(forSessionID: sessionID)
            let heading = project.map { "Sessions in “\($0.name)” (\(rows.count)):" }
                ?? "Sessions in this project (\(rows.count)):"

            let lines = rows.map { row in
                var line = "• “\(row.title)” — \(row.kind.displayName), \(Self.words(for: row))"
                line += " — id \(row.id.uuidString.lowercased())"
                if row.isCaller { line += " (this session — you)" }
                if let parent = row.forkedFrom {
                    line += " (side chat of \(parent.uuidString.lowercased()))"
                }
                return line
            }

            let footer = rows.count > 1
                ? "send_to_session delivers a message to one of the others by its id."
                : "This session is the only one here; there is no one to message yet."
            return .success(([heading] + lines + [footer]).joined(separator: "\n"))
        }
    }

    // MARK: Sending

    func sendToSession(
        _ arguments: SendToSessionArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let raw = (arguments.sessionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetID = SessionID(uuidString: raw) else {
            return completion(.failure("""
                “\(raw)” is not a Threading session id. Call list_sessions and use an id \
                exactly as it prints one — a UUID, not a session's name or a provider's \
                transcript id.
                """))
        }

        let disposition: ControlSendDisposition
        switch (arguments.disposition ?? "queue").lowercased() {
        case "queue": disposition = .queue
        case "steer": disposition = .steer
        default:
            return completion(.failure("""
                “\(arguments.disposition ?? "")” is not a disposition. Use "queue" (the \
                default — its own turn, behind any running one) or "steer" (join the turn \
                already running).
                """))
        }

        dependencies.control.send(
            arguments.message ?? "",
            to: targetID,
            disposition: disposition,
            from: .agentSession(sessionID)
        ) { outcome in
            switch outcome {
            case .sent(let target) where target.surface == .terminal:
                completion(.success("""
                    Delivered to “\(target.title)”: typed into its terminal, and the \
                    session's own turn report confirms it was accepted. It runs on that \
                    session's usage; whether and when it answers is that conversation's \
                    business — there is no reply channel back.
                    """))
            case .sent(let target):
                completion(.success("""
                    Handed to “\(target.title)” as its next turn, prefixed with this \
                    session's name — if the handoff fails at the last moment it returns to \
                    that session's visible message queue rather than being lost. It runs on \
                    that session's own usage; whether and when it answers is that \
                    conversation's business — there is no reply channel back.
                    """))
            case .queued(let target):
                completion(.success("""
                    “\(target.title)” is busy, so the message joined its visible message \
                    queue — where the user can edit or remove it — and is sent under this \
                    session's name when the turn in flight settles. The queue lives with \
                    the running session: if it exits or is closed first, the queue goes \
                    with it and this message is not delivered.
                    """))
            case .steered(let target):
                completion(.success("""
                    Added to the turn “\(target.title)” is already running — it shares that \
                    turn's context and settles with it, and the message appears in that \
                    transcript under this session's name. Steered text arrives beside tool \
                    results, so keep it additive; anything override-shaped gets discarded \
                    as injection by the model reading it.
                    """))
            case .typedUnconfirmed(let target):
                completion(.failure("""
                    Typed into “\(target.title)”'s terminal, but the session never \
                    confirmed a turn began — its screen may have been mid-compaction or \
                    holding a menu, and the text may sit unsent or have been discarded. Do \
                    not blindly resend: call list_sessions first, and if the session is now \
                    working it likely accepted after all. Resend only if it stays idle.
                    """))
            case .refused(let refusal):
                completion(.failure(Self.words(for: refusal)))
            }
        }
    }

    // MARK: Watching

    func watchSession(
        _ arguments: WatchSessionArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        let raw = (arguments.sessionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetID = SessionID(uuidString: raw) else {
            return .failure("""
                “\(raw)” is not a Threading session id. Call list_sessions and use an id \
                exactly as it prints one — a UUID, not a session's name or a provider's \
                transcript id.
                """)
        }

        switch dependencies.control.watch(targetID, from: .agentSession(sessionID)) {
        case .armed(let target, let expiresAfter):
            let minutes = Int((expiresAfter / 60).rounded())
            return .success("""
                Watching “\(target.title)”. When its current turn settles — or it exits, or \
                stops at its usage limit — you receive one message saying so, and that message \
                spends this session's turn. The watch says nothing before then and is spent on \
                that one notice. It expires after \(minutes) minutes with a notice of its own, \
                and it lives only as long as this run of Threading.
                """)
        case .alreadyWatching(let target):
            return .success("""
                Already watching “\(target.title)” — this changed nothing, and the one notice \
                already armed still arrives when that session settles.
                """)
        case .targetAlreadySettled(let target):
            return .failure("""
                “\(target.title)” has already settled — there is no turn in flight to be told \
                about. Read list_sessions, or just look: the answer you are waiting on is \
                already there. Arm a watch only while a session is working.
                """)
        case .refused(let refusal):
            return .failure(Self.words(for: refusal))
        }
    }

    // MARK: - Wording

    private static func words(for refusal: ControlRefusal) -> String {
        switch refusal {
        case .callerUnknown:
            return "This session is no longer in the sidebar, so it has no project to act in."
        case .targetUnknown:
            return """
                No session with that id is in this project. list_sessions names every one \
                this session can reach — sessions in other projects are out of reach by design.
                """
        case .targetArchived:
            return """
                That session has been archived. The user restores it from \
                Settings ▸ Archived; until then it cannot receive messages.
                """
        case .targetIsCaller:
            return """
                That id is this session's own. Say it in your reply instead — a session \
                does not message itself.
                """
        case .targetNotRunning:
            return """
                That session is dormant — no agent is running to receive a message. \
                Resuming it is the user's decision, made by selecting its row.
                """
        case .targetBusy:
            return """
                That session runs in a terminal whose agent is mid-turn or still starting \
                up, so typed input would land inside whatever its screen is showing. Try \
                again shortly — list_sessions shows who is working.
                """
        case .messageEmpty:
            return "Provide a message: whole sentences, as the receiving conversation will read them."
        case .messageTooLong(let limit):
            return """
                The message is over the \(limit)-character limit. Send the conclusion, not \
                the transcript — the receiving session can ask for detail if it needs it.
                """
        case .deliveryFailed:
            return """
                The session did not take the message — it may be mid-launch, or a remote \
                participant currently holds its input. Try again shortly.
                """
        case .steerNeedsLiveChat:
            return """
                Steering joins a running native chat turn, and that session has none — it \
                runs in a terminal or is dormant. Send with the default disposition \
                instead, which delivers as the session's own next turn.
                """
        case .watcherAtCapacity(let limit):
            return """
                This session already holds \(limit) watches; they fire or expire before more \
                fit. Wait for one of them, or read list_sessions instead of watching another.
                """
        case .steerUnavailable(let refusal):
            switch refusal {
            case .unsupported:
                return """
                    That session's provider has no steering primitive. Send with the \
                    default disposition instead.
                    """
            case .noActiveTurn:
                return """
                    Nothing is running to steer — the turn ended. Send with the default \
                    disposition and it arrives as the session's own next turn.
                    """
            case .turnKindRefusesSteering:
                return """
                    The turn in flight does not accept additions — a review or compaction. \
                    Send with the default disposition to queue behind it instead.
                    """
            }
        }
    }

    private static func words(for row: ControlSessionOverview) -> String {
        // The two answers come from different owners and can disagree for a beat — a live
        // surface whose tracker still reads dormant. The surface is the one that decides
        // whether a message can land, so it wins, and the state falls back to the quietest
        // word that is not a lie.
        let activity = row.activity == .dormant ? "idle" : words(for: row.activity)
        switch row.surface {
        case .dormant:
            return "dormant"
        case .chat:
            return "chat, \(activity)"
        case .terminal:
            return "terminal, \(activity)"
        }
    }

    private static func words(for activity: SessionActivity) -> String {
        switch activity {
        case .dormant: return "dormant"
        case .idle: return "idle"
        case .working: return "working"
        case .awaitingUser: return "waiting on input"
        case .needsAttention: return "needs attention"
        // Spelt out rather than folded into "needs attention": an agent reading this listing to
        // decide where to send work must be able to tell a session that will answer when poked
        // from one whose account cannot answer at all until its window resets.
        case .limitReached: return "stopped at its usage limit"
        }
    }
}
