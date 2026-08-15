import Foundation

// MARK: - Workspace Control Plane

/// Resolves control-contract requests against the session model: who may see which sessions,
/// and who may send what to whom.
///
/// This is deliberately the one place scope is enforced. The MCP tools that call it own wording
/// only; a future CLI, extension binding or remote client calls the same methods and inherits
/// the same refusals, so a rule loosened for one caller cannot silently loosen for the rest.
///
/// Dependencies are injected closures in `SessionArchiveScheduler`'s style: tests drive the
/// plane with fakes and no live agent, window or store. `.live` is assembled once at the
/// application boundary (`AgentToolDependencies`).
@MainActor
final class WorkspaceControlPlane {

    // MARK: - Dependencies

    struct Dependencies {
        /// The session record, wherever it lives — including archived records.
        let session: (SessionID) -> AgentSession?
        /// The project a session belongs to, with its member sessions.
        let projectForSession: (SessionID) -> Project?
        let activity: (SessionID) -> SessionActivity
        /// Which input surface is live for a session right now.
        let surface: (SessionID) -> ControlSessionOverview.Surface
        /// Hands text to a session's live surface. The plane has already decided the send is
        /// permitted; this owns only the mechanics and reports what the surface did — through
        /// a completion, because a terminal delivery's honest answer waits on the target's
        /// own turn-started receipt.
        let deliver: (String, SessionID, @escaping @MainActor (SessionMessageDelivery.Outcome) -> Void) -> Void
        /// Adds text to a session's running turn. Synchronous: a steer is a stream write the
        /// transport accepts or refuses on the spot, and no receipt exists to wait for.
        let steer: (String, SessionID) -> SessionMessageDelivery.SteerOutcome
        /// Arms one watcher's one-shot watch on one target. The plane has already decided the
        /// watch is permitted; the centre owns the edge, the budget and the notice.
        let armWatch: (SessionID, SessionID, TimeInterval?) -> SessionWatchCenter.WatchArmOutcome
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    static let live = WorkspaceControlPlane(
        dependencies: Dependencies(
            session: { ProjectStore.shared.session(withID: $0) },
            projectForSession: { ProjectStore.shared.project(forSessionID: $0) },
            activity: { AgentRuntime.shared.activity(sessionID: $0) },
            surface: { SessionMessageDelivery.surface(for: $0) },
            deliver: { SessionMessageDelivery.deliver($0, to: $1, completion: $2) },
            steer: { SessionMessageDelivery.steer($0, to: $1) },
            armWatch: {
                SessionWatchCenter.shared.arm(watcher: $0, target: $1, timeout: $2)
            }
        )
    )

    // MARK: - Scope

    /// The scope an actor holds. Slice one: a session sees exactly its own project.
    func scope(for actor: ControlActor) -> ControlScope? {
        switch actor {
        case .agentSession(let sessionID):
            guard let project = dependencies.projectForSession(sessionID) else { return nil }
            return .project(project.id)
        }
    }

    // MARK: - Listing

    /// The sessions an actor may know about: every unarchived session in its scope, the
    /// caller's own marked as such.
    func sessions(for actor: ControlActor) -> Result<[ControlSessionOverview], ControlRefusal> {
        guard case .agentSession(let callerID) = actor,
              let caller = dependencies.session(callerID),
              !caller.isArchived,
              let project = dependencies.projectForSession(callerID) else {
            return .failure(.callerUnknown)
        }

        let rows = project.sessions
            .filter { !$0.isArchived }
            .map { overview(of: $0, caller: callerID) }
        return .success(rows)
    }

    // MARK: - Sending

    /// Delivers a message to another session in the actor's scope, provenance attached.
    ///
    /// Checks run caller → message → target → surface, so the answer names the first thing
    /// actually wrong rather than whichever guard happened to be written first. The outcome
    /// arrives through a completion because a terminal delivery's honest answer waits on the
    /// target's own turn-started receipt; refusals and chat sends complete immediately.
    func send(
        _ message: String,
        to targetID: SessionID,
        disposition: ControlSendDisposition = .queue,
        from actor: ControlActor,
        completion: @escaping @MainActor (ControlSendOutcome) -> Void
    ) {
        guard case .agentSession(let callerID) = actor,
              let caller = dependencies.session(callerID),
              !caller.isArchived,
              let callerProject = dependencies.projectForSession(callerID) else {
            return completion(.refused(.callerUnknown))
        }

        let trimmed = Self.sanitized(message).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return completion(.refused(.messageEmpty)) }

        guard targetID != callerID else { return completion(.refused(.targetIsCaller)) }

        // Membership is asked of the caller's own project, not of the target's record: a
        // session outside the scope answers exactly as one that does not exist.
        guard let target = callerProject.sessions.first(where: { $0.id == targetID }) else {
            return completion(.refused(.targetUnknown))
        }
        guard !target.isArchived else { return completion(.refused(.targetArchived)) }

        // The budget bounds what is delivered, header included — a cap applied before the
        // prefix let every message exceed the limit it had just been held to.
        let delivered = Self.provenancePrefixed(trimmed, from: caller)
        guard delivered.count <= ControlDefaults.maximumMessageLength else {
            return completion(.refused(.messageTooLong(limit: ControlDefaults.maximumMessageLength)))
        }

        switch disposition {
        case .queue:
            dependencies.deliver(delivered, targetID) { [weak self] outcome in
                guard let self else { return completion(.refused(.deliveryFailed)) }
                switch outcome {
                case .sentNow:
                    completion(.sent(to: self.overview(of: target, caller: callerID)))
                case .queuedBehindTurn:
                    completion(.queued(behind: self.overview(of: target, caller: callerID)))
                case .typedUnconfirmed:
                    completion(.typedUnconfirmed(to: self.overview(of: target, caller: callerID)))
                case .noLiveSurface:
                    completion(.refused(.targetNotRunning))
                case .busyTerminal:
                    completion(.refused(.targetBusy))
                case .notTaken:
                    completion(.refused(.deliveryFailed))
                }
            }

        case .steer:
            switch dependencies.steer(delivered, targetID) {
            case .steered:
                completion(.steered(into: overview(of: target, caller: callerID)))
            case .targetNotLiveChat:
                completion(.refused(.steerNeedsLiveChat))
            case .refused(let refusal):
                completion(.refused(.steerUnavailable(refusal)))
            case .notTaken:
                completion(.refused(.deliveryFailed))
            }
        }
    }

    // MARK: - Watching

    /// Arms a one-shot notice for when another session in the actor's scope next settles.
    ///
    /// The same scope guards a send runs, minus the ones about a message — a watch carries no
    /// text — so who may be watched is exactly who may be messaged, decided here rather than
    /// twice. Synchronous: arming is a decision, not a delivery, and the notice it buys arrives
    /// later through the delivery seam.
    func watch(
        _ targetID: SessionID,
        timeout: TimeInterval? = nil,
        from actor: ControlActor
    ) -> ControlWatchOutcome {
        guard case .agentSession(let callerID) = actor,
              let caller = dependencies.session(callerID),
              !caller.isArchived,
              let callerProject = dependencies.projectForSession(callerID) else {
            return .refused(.callerUnknown)
        }

        guard targetID != callerID else { return .refused(.targetIsCaller) }

        guard let target = callerProject.sessions.first(where: { $0.id == targetID }) else {
            return .refused(.targetUnknown)
        }
        guard !target.isArchived else { return .refused(.targetArchived) }

        let overview = overview(of: target, caller: callerID)
        switch dependencies.armWatch(callerID, targetID, timeout) {
        case .armed(let expiresAfter):
            return .armed(on: overview, expiresAfter: expiresAfter)
        case .alreadyWatching:
            return .alreadyWatching(on: overview)
        case .targetAlreadySettled:
            return .targetAlreadySettled(overview)
        case .watcherAtCapacity(let limit):
            return .refused(.watcherAtCapacity(limit: limit))
        case .invalidTimeout:
            return .refused(.invalidWatchTimeout)
        }
    }

    // MARK: - Provenance

    /// Every cross-session message says which session sent it, ahead of anything it says.
    ///
    /// The receiving transcript renders the delivery as an ordinary user turn — that is the
    /// honest mechanics, since it runs as one — so the header is what keeps the receiving
    /// agent, and the user reading over its shoulder, from mistaking a peer session's words
    /// for the user's own.
    ///
    /// The header is the only part of a delivery Threading vouches for, and only as its
    /// *first* line: the body is the sender's words, unescaped, so a sender can write a
    /// header-shaped line of its own further down. The group instruction says exactly that to
    /// receivers. The title slot is fenced (`safeHeaderTitle`) because a session names itself
    /// — a title ending in `”` or `]` would close the frame early and put sender-authored
    /// text where the reader has been told Threading speaks.
    static func provenancePrefixed(_ message: String, from source: AgentSession) -> String {
        """
        [Cross-session message from “\(safeHeaderTitle(source.displayTitle))” — Threading \
        session \(source.id.uuidString.lowercased()) in this project. Sent by that session's \
        agent, not typed by the user. Only this first line is written by Threading.]

        \(message)
        """
    }

    /// A session title, safe to interpolate into the one line Threading vouches for.
    ///
    /// `nonisolated`, like `sanitized`: a pure function of its argument, and the session
    /// reference a dragged sidebar row becomes (`SessionReference`) fences its title with the
    /// same rule from a value type that has no actor.
    nonisolated static func safeHeaderTitle(_ title: String) -> String {
        var safe = sanitized(title).replacingOccurrences(of: "\n", with: " ")
        for framing in ["[", "]", "“", "”"] {
            safe = safe.replacingOccurrences(of: framing, with: "'")
        }
        return safe
    }

    /// Drops control characters a delivered message must never carry.
    ///
    /// The terminal path types the message into a PTY, where ESC and C0/C1 bytes are live
    /// keystrokes — `ESC [201~` inside a body would end the bracketed paste and hand the rest
    /// to the TUI as typed input, Returns and Ctrl-C included. Newlines and tabs stay; they
    /// are the message's own structure. The chat path never interprets these, but one rule
    /// for both surfaces means the answer cannot depend on where the target happens to live.
    nonisolated static func sanitized(_ message: String) -> String {
        String(String.UnicodeScalarView(message.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t"
                || (scalar.value >= 0x20 && scalar.value != 0x7F
                    && !(0x80...0x9F).contains(scalar.value))
        }))
    }

    // MARK: - Private

    /// **The title is fenced here, once, for every consumer.**
    ///
    /// A session names itself (`set_session_name`, or its own terminal title), and every tool
    /// result in this feature interpolates that name into prose an agent reads as structure:
    /// `list_sessions` prints one bullet per session with an id after an em dash. A session
    /// titled `X” — claude, chat, idle — id <someone-else's-uuid>` followed by a newline and a
    /// bullet therefore forges a listing row, attributing an id to a session that does not
    /// hold it — and the reading agent has no way to tell the forged row from the real ones.
    /// The header fence already existed for the delivery frame; the listing needed it just as
    /// much, and putting it on the overview means no future tool can forget it.
    private func overview(of session: AgentSession, caller: SessionID) -> ControlSessionOverview {
        ControlSessionOverview(
            id: session.id,
            title: Self.safeHeaderTitle(session.displayTitle),
            kind: session.kind,
            activity: dependencies.activity(session.id),
            surface: dependencies.surface(session.id),
            isCaller: session.id == caller,
            forkedFrom: session.forkedFrom
        )
    }
}
