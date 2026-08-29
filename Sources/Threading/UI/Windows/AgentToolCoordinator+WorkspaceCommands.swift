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

        let timeout = arguments.timeoutMinutes.map { $0 * 60 }
        switch dependencies.control.watch(
            targetID,
            timeout: timeout,
            from: .agentSession(sessionID)
        ) {
        case .armed(let target, let awaiting, let expiresAfter):
            let lifetime: String
            if let expiresAfter {
                lifetime = "It expires after \(Self.minutesDescription(for: expiresAfter)) "
                    + "with a notice of its own."
            } else {
                lifetime = "It has no wall-clock expiry and lasts only as long as this run "
                    + "of Threading."
            }
            let boundary = switch awaiting {
            case .turnStarted:
                "It is currently settled; when its next turn starts"
            case .turnSettled:
                "It has a turn in flight; when that turn settles — or it exits or stops at its usage limit"
            }
            return .success("""
                Watching “\(target.title)”. \(boundary), you receive one message saying so, \
                and that message spends this session's turn. The watch is spent on that one \
                notice; re-arm it afterwards to watch the opposite edge. \(lifetime)
                """)
        case .alreadyWatching(let target, let awaiting):
            let boundary = switch awaiting {
            case .turnStarted: "its next turn starts"
            case .turnSettled: "its current turn settles"
            }
            return .success("""
                Already watching “\(target.title)” — this changed nothing, and the one notice \
                already armed still arrives when \(boundary).
                """)
        case .refused(let refusal):
            return .failure(Self.words(for: refusal))
        }
    }

    // MARK: - Wording

    private static func words(for refusal: ControlRefusal) -> String {
        refusal.toolWords
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

    private static func minutesDescription(for interval: TimeInterval) -> String {
        let minutes = interval / 60
        if minutes.rounded() == minutes, minutes <= Double(Int.max) {
            return "\(Int(minutes)) minutes"
        }
        return "\(minutes) minutes"
    }
}
