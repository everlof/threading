import Foundation

// MARK: - App Message Acceptance

/// How a conversation took a message the app composed on someone's behalf — a cross-session
/// delivery or a scheduled send, not text typed into its composer.
enum AppMessageAcceptance: Equatable, Sendable {
    /// Appended to the visible queue and immediately handed toward the next turn. A handoff
    /// the transport refuses late reclaims into that queue rather than being lost.
    case handedToTurn
    /// Parked behind the turn in flight, visible in the queue rail.
    case queuedBehindTurn
    case refused(AppMessageRefusal)
}

enum AppMessageRefusal: Equatable, Sendable {
    case emptyText
    case queueFull
    /// A remote participant holds this conversation's input authority.
    case inputHeldRemotely
}

/// How a conversation answered an app-composed steer — a message asked to join the turn
/// already running, not to wait behind it.
enum AppMessageSteerResult: Equatable, Sendable {
    case steered
    /// The transport's own reason: no primitive, no active turn, or a turn kind that refuses
    /// additions. Never silently downgraded to a queue — a caller who asked to steer is told
    /// the truth and decides for itself.
    case refused(SteerRefusal)
    case inputHeldRemotely
    case emptyText
}

/// The narrow face delivery needs of a native conversation, a protocol so the rules below are
/// testable against fakes. The first shape reached `AgentRuntime.shared` directly, was
/// untestable, and shipped its first bug untested.
@MainActor
protocol AppMessageReceiving: AnyObject {
    var isRunning: Bool { get }

    /// `origin` is what a held outbox reads back off the row it is about to hand over: a curfew's
    /// wrap-up drains while the session is held and nothing else does. It is a requirement rather
    /// than a defaulted parameter because Swift does not allow default arguments on protocol
    /// requirements; the convenience below is what keeps every ordinary caller unchanged.
    func acceptAppMessage(
        _ prompt: ConversationPrompt,
        origin: ConversationOutbox.Item.Origin
    ) -> AppMessageAcceptance

    func steerAppMessage(_ prompt: ConversationPrompt) -> AppMessageSteerResult
}

extension AppMessageReceiving {
    /// Almost every app-composed message is an ordinary one, delivered on the user's behalf.
    func acceptAppMessage(_ prompt: ConversationPrompt) -> AppMessageAcceptance {
        acceptAppMessage(prompt, origin: .user)
    }
}

// MARK: - Session Message Delivery

/// Hands a whole message to a session's live input surface, whichever surface that is.
///
/// `SessionContextHandoff`'s sibling, for prose instead of staged context: one seam answers for
/// both surfaces so no caller ever switches on how a session happens to be rendered. Resolution
/// is per call for the same reason the handoff's is — a session moves between a native
/// conversation and a terminal across relaunches, and a cached answer would keep offering the
/// door that closed.
///
/// **A conversation that exists is not a conversation that is running.** Both questions below ask
/// `isRunning` as well as existence, and for months neither did. `TerminalContainerViewController`
/// deliberately *keeps* a `ConversationViewController` after its agent exits — the transcript is
/// worth more than a dormant placeholder — so `AgentRuntime.conversation(for:)` goes on answering
/// for a session with no process. Without the check, `submit` fell through its `stream.canSend`
/// guard into `enqueue`, which took the message and answered true, and `hasTurnInFlight` is false
/// for a dead session: `deliver` therefore reported **`.sentNow`** for a message no transport had
/// or would ever have. Its next stop was an in-memory outbox that `resumeCurrentSession` discards
/// through `AgentRuntime.discard`, so the text was destroyed and the caller had been told it
/// arrived. `send_to_session` has been quietly losing cross-session messages that way, and a
/// scheduled send would have deleted its own durable record on the strength of that answer.
/// `.noLiveSurface` is the truth, and it is what lets a caller decide to resume.
///
/// **The outcome is the surface's own answer, never a guess from beside it.** An earlier shape
/// read `activity.hasTurnInFlight` before the send and inferred sent-versus-queued from that —
/// wrong in both directions: `sendAppPrompt` answered true for a real send *and* for an enqueue,
/// and a turn already settled on the wire still reads `.working` while its background work
/// finishes, so a message sent immediately was reported as "queued where the user can remove it"
/// with nothing in the rail to remove. `AppMessageAcceptance` is the conversation reporting what
/// it actually did — and because acceptance routes through the outbox, a transport that refuses
/// after the settle reclaims the message into the visible queue instead of destroying text no
/// composer still holds.
@MainActor
enum SessionMessageDelivery {

    /// What the target's surface did with the message.
    enum Outcome: Equatable, Sendable {
        /// Chat: appended to the visible queue and handed toward the next turn — a late
        /// transport refusal reclaims it there, visibly. Terminal: typed, with the Return
        /// submitted in its own write a beat later.
        case sentNow
        /// Parked in the native conversation's visible queue, behind the turn in flight. The
        /// queue lives with the running conversation; it is not durable.
        case queuedBehindTurn
        /// No live conversation and no running PTY.
        case noLiveSurface
        /// A terminal whose agent is mid-turn — or still booting, which its own lifecycle
        /// report is the only proof against. Typing into either window misdelivers: text
        /// lands in whatever is on screen, which pre-boot is a login shell, not a composer.
        case busyTerminal
        /// Typed and submitted, and the session never confirmed a turn began. "We pressed
        /// Return" is a fact about our keystrokes, not about their arrival: the first live
        /// delivery was typed into a session mid-`/compact` — a turn the tracker cannot see,
        /// because compaction reports no hooks and paints almost nothing — and the redraw
        /// discarded the paste while the caller was told it was sent. Only the receipt path
        /// (`deliver(_:to:completion:)`) can answer this; the synchronous form never does.
        case typedUnconfirmed
        /// The surface exists and still refused — empty text, a full queue, or a remote
        /// participant holding input authority.
        case notTaken
    }

    /// What the delivery rules need to know about a terminal target — facts gathered by the
    /// live wrapper, handed in as values so the rules stay testable.
    struct TerminalTarget {
        let isMidTurn: Bool
        /// This process has been heard from (`hasHeardFromProcess`) — its SessionStart hook
        /// or any later report, the proof the CLI is actually up. `isRunning` alone flips at
        /// PTY spawn, seconds before the CLI's composer exists. Deliberately not
        /// `reportsOwnTurns`: that latches only on turn reports, so it left every session
        /// idle since an app relaunch reading as still-booting, refused while listed as idle.
        let hasVerifiedBoot: Bool
        /// Whether this runtime will ever verify (`.terminalThreadingBridge`). One that
        /// cannot is taken at `isMidTurn`'s word rather than refused forever.
        let requiresVerifiedBoot: Bool
        /// Whether a delivery to this terminal is already typed and still waiting for its
        /// receipt. A PTY takes one message at a time: the text is pasted immediately and the
        /// Return follows a beat later, so a second delivery inside that window pastes onto
        /// the same composer line and the CLI receives both as one prompt — while the second
        /// caller is told its own message was sent. Two watches settling on one edge is
        /// enough to hit it. Refused as busy, which is what a terminal mid-delivery is.
        let hasDeliveryInFlight: Bool
        let type: (String) -> Void
        /// Waits for the session's own turn-started report and answers whether one arrived —
        /// the receipt a typed delivery needs before claiming the message was accepted.
        let awaitAcceptance: (@escaping @MainActor (Bool) -> Void) -> Void
    }

    /// Terminals with a delivery typed and not yet receipted. Static because the rules are, and
    /// because the window it guards is per-PTY rather than per-caller.
    private static var terminalsMidDelivery: Set<SessionID> = []

    /// Which input surface is live for a session right now, for describing it to a caller.
    ///
    /// `isRunning` on both branches, symmetrically: a kept-but-exited conversation is as dormant
    /// as a torn-down terminal, and `list_sessions` calling it `chat` invited exactly the send
    /// `deliver` could not honour.
    static func surface(for sessionID: SessionID) -> ControlSessionOverview.Surface {
        if let conversation = AgentRuntime.shared.conversation(for: sessionID),
           conversation.isRunning {
            return .chat
        }
        if AgentRuntime.shared.runningTerminalInputSurface(for: sessionID) != nil {
            return .terminal
        }
        return .dormant
    }

    /// Whether a delivery attempted now would land — the menu's question, answered with the
    /// same facts `deliver` decides by, so an affordance gated on this cannot offer a send the
    /// delivery then refuses.
    static func isReadyForDelivery(_ sessionID: SessionID) -> Bool {
        switch surface(for: sessionID) {
        case .chat:
            return true
        case .terminal:
            let kind = ProjectStore.shared.session(withID: sessionID)?.kind
            return !AgentRuntime.shared.activity(sessionID: sessionID).hasTurnInFlight
                && (AgentRuntime.shared.hasHeardFromProcess(sessionID: sessionID)
                    || !(kind?.supports(.terminalThreadingBridge) ?? true))
        case .dormant:
            return false
        }
    }

    static func deliver(_ text: String, to sessionID: SessionID) -> Outcome {
        deliver(ConversationPrompt(text: text), to: sessionID)
    }

    /// Delivery with a receipt: a terminal send completes only once the target's own
    /// turn-started report confirms the message was accepted — or the timeout says it was
    /// not, which comes back as `.typedUnconfirmed` instead of a claim of success. Chat
    /// sends and refusals complete immediately; their outcomes were never guesses.
    static func deliver(
        _ text: String,
        to sessionID: SessionID,
        completion: @escaping @MainActor (Outcome) -> Void
    ) {
        deliver(ConversationPrompt(text: text), to: sessionID, completion: completion)
    }

    /// The receipt form for a message carrying staged context as well as prose — what a
    /// scheduled send uses, since it is the delivery with nobody watching and therefore the one
    /// that can least afford to report success on a keystroke.
    static func deliver(
        _ prompt: ConversationPrompt,
        to sessionID: SessionID,
        origin: ConversationOutbox.Item.Origin = .user,
        completion: @escaping @MainActor (Outcome) -> Void
    ) {
        deliver(
            prompt,
            chat: AgentRuntime.shared.conversation(for: sessionID),
            terminal: liveTerminalTarget(for: sessionID),
            origin: origin,
            completion: completion
        )
    }

    /// The receipt rules, apart from the lookups — `SessionMessageDeliveryTests` drives this.
    static func deliver(
        _ prompt: ConversationPrompt,
        chat: AppMessageReceiving?,
        terminal: TerminalTarget?,
        origin: ConversationOutbox.Item.Origin = .user,
        completion: @escaping @MainActor (Outcome) -> Void
    ) {
        let outcome = deliver(prompt, chat: chat, terminal: terminal, origin: origin)
        let viaTerminal = !(chat?.isRunning ?? false)
        guard outcome == .sentNow, viaTerminal, let terminal else {
            completion(outcome)
            return
        }
        terminal.awaitAcceptance { accepted in
            completion(accepted ? .sentNow : .typedUnconfirmed)
        }
    }

    /// The same delivery, for a message that carries staged context as well as prose.
    ///
    /// A native conversation takes both, so the references arrive as references. A terminal has
    /// no context rail to put them in, so it is handed `transportText` — the provider-neutral
    /// envelope this repository already uses whenever context has to cross as text.
    static func deliver(
        _ prompt: ConversationPrompt,
        to sessionID: SessionID,
        origin: ConversationOutbox.Item.Origin = .user
    ) -> Outcome {
        deliver(
            prompt,
            chat: AgentRuntime.shared.conversation(for: sessionID),
            terminal: liveTerminalTarget(for: sessionID),
            origin: origin
        )
    }

    /// The rules, apart from the lookups — what `SessionMessageDeliveryTests` drives.
    ///
    /// `origin` reaches only the native queue. A terminal has no outbox to remember it in: the
    /// wrap-up is typed between turns, and what exempts it there is the scheduled send's own
    /// stand-aside rather than a row's provenance.
    static func deliver(
        _ prompt: ConversationPrompt,
        chat: AppMessageReceiving?,
        terminal: TerminalTarget?,
        origin: ConversationOutbox.Item.Origin = .user
    ) -> Outcome {
        if let chat, chat.isRunning {
            switch chat.acceptAppMessage(prompt, origin: origin) {
            case .handedToTurn: return .sentNow
            case .queuedBehindTurn: return .queuedBehindTurn
            case .refused: return .notTaken
            }
        }

        guard let terminal else { return .noLiveSurface }
        guard !terminal.isMidTurn else { return .busyTerminal }
        guard !terminal.hasDeliveryInFlight else { return .busyTerminal }
        guard terminal.hasVerifiedBoot || !terminal.requiresVerifiedBoot else {
            return .busyTerminal
        }
        terminal.type(prompt.context.isEmpty ? prompt.visibleText : prompt.transportText)
        return .sentNow
    }

    // MARK: - Steering

    /// What became of a steer — joining the turn already running, never a new one.
    enum SteerOutcome: Equatable, Sendable {
        case steered
        /// Steering is a stream operation; a terminal or dormant session has no wire to
        /// steer over, whatever its activity says.
        case targetNotLiveChat
        /// The transport's own refusal, passed through rather than flattened.
        case refused(SteerRefusal)
        /// The conversation exists and still declined — input held remotely, empty text.
        case notTaken
    }

    static func steer(_ text: String, to sessionID: SessionID) -> SteerOutcome {
        steer(
            ConversationPrompt(text: text),
            chat: AgentRuntime.shared.conversation(for: sessionID)
        )
    }

    /// The steering rules, apart from the lookups.
    static func steer(_ prompt: ConversationPrompt, chat: AppMessageReceiving?) -> SteerOutcome {
        guard let chat, chat.isRunning else { return .targetNotLiveChat }
        switch chat.steerAppMessage(prompt) {
        case .steered: return .steered
        case .refused(let refusal): return .refused(refusal)
        case .inputHeldRemotely, .emptyText: return .notTaken
        }
    }

    // MARK: - Private

    private static func liveTerminalTarget(for sessionID: SessionID) -> TerminalTarget? {
        guard let terminal = AgentRuntime.shared.runningTerminalInputSurface(for: sessionID) else {
            return nil
        }

        let kind = ProjectStore.shared.session(withID: sessionID)?.kind
        return TerminalTarget(
            isMidTurn: AgentRuntime.shared.activity(sessionID: sessionID).hasTurnInFlight,
            hasVerifiedBoot: AgentRuntime.shared.hasHeardFromProcess(sessionID: sessionID),
            // A record that has vanished mid-call verifies nothing and requires everything.
            requiresVerifiedBoot: kind?.supports(.terminalThreadingBridge) ?? true,
            hasDeliveryInFlight: terminalsMidDelivery.contains(sessionID),
            type: { [weak terminal] text in
                guard let terminal else { return }
                // Claimed at the paste, released by the receipt or its timeout, so the whole
                // paste-then-Return window is one delivery's own.
                terminalsMidDelivery.insert(sessionID)
                terminal.pasteTerminalText(text)
                // The Return goes in its own write, a beat later — the rename request
                // measured a Return bundled with its text being read as pasted content,
                // left sitting unsent in the TUI's composer.
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + SessionRenameRequest.submitDelay
                ) {
                    terminal.insertTerminalText(TerminalDefaults.submitSequence)
                }
            },
            awaitAcceptance: { completion in
                AgentRuntime.shared.awaitReportedTurnStart(
                    sessionID: sessionID,
                    timeout: SessionMessageDeliveryDefaults.terminalReceiptTimeout
                ) { accepted in
                    terminalsMidDelivery.remove(sessionID)
                    completion(accepted)
                }
            }
        )
    }
}

// MARK: - Defaults

enum SessionMessageDeliveryDefaults {
    /// How long a typed delivery waits for the target's own turn-started report. Covers the
    /// paste settle, the delayed Return, the CLI packaging the turn, and the hook's round
    /// trip back — while staying short enough that an unconfirmed answer arrives while the
    /// caller still remembers what it sent.
    static let terminalReceiptTimeout: TimeInterval = 5
}
