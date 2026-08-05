import Foundation

// MARK: - Hook Lifecycle Event

/// The turn boundaries an agent reports through its own hooks.
///
/// These exist because the alternative is inference. `SessionActivityTracker` derives the same
/// states from PTY output volume, which works for any program but is a proxy: it cannot tell
/// the agent thinking from the agent redrawing, and it needs a byte threshold and three quiet
/// periods to stay honest. A hook says so directly.
///
/// Only the events Threading acts on are registered. Every hook is a process spawned on the
/// agent's own turn boundary, so registering one that nothing consumes spends the user's
/// latency to learn nothing.
enum HookLifecycleEvent: String, CaseIterable {
    /// A prompt was submitted — the turn is starting.
    case turnStarted

    /// The agent finished its turn and is waiting.
    case turnFinished

    /// The agent is asking for something and cannot continue until it is answered.
    case awaitingUser

    /// A session began, which is where an agent-assigned identifier first becomes known.
    case sessionStarted

    /// A delegated child began running.
    case subagentStarted

    /// A delegated child stopped and may now name its durable transcript.
    case subagentStopped

    /// The name Claude's settings file knows this event by.
    var claudeEventName: String {
        switch self {
        case .turnStarted: return "UserPromptSubmit"
        case .turnFinished: return "Stop"
        case .awaitingUser: return "Notification"
        case .sessionStarted: return "SessionStart"
        case .subagentStarted: return "SubagentStart"
        case .subagentStopped: return "SubagentStop"
        }
    }

    /// The name Codex's `hooks.json` knows this event by, or nil where it has no equivalent.
    ///
    /// Codex 0.144.6 carries the same event vocabulary as Claude apart from `Notification`,
    /// which it does not emit — so a Codex session can report its turn boundaries but never
    /// that it is waiting on the user.
    var codexEventName: String? {
        switch self {
        case .turnStarted: return "UserPromptSubmit"
        case .turnFinished: return "Stop"
        case .sessionStarted: return "SessionStart"
        case .awaitingUser: return nil
        case .subagentStarted: return "SubagentStart"
        case .subagentStopped: return "SubagentStop"
        }
    }
}

// MARK: - Hook Lifecycle Report

/// One lifecycle event, as it arrived from a hook.
struct HookLifecycleReport {
    let sessionID: SessionID
    let event: HookLifecycleEvent

    /// The agent's own identifier for the conversation, when it named one.
    ///
    /// For Claude this is the id Threading minted and already knows. For Codex it is the id the
    /// CLI assigns itself, which is otherwise only recoverable by scanning rollout files.
    ///
    /// Typed at the boundary rather than downstream: this is `TranscriptID`'s domain exactly —
    /// a runtime's own name for a conversation — and `AgentRuntime` used to re-wrap the raw
    /// string *and* re-check it for emptiness before storing it. An id present but empty is a
    /// payload that named nothing, so it is dropped here and the read site keeps one question
    /// instead of two.
    let agentSessionID: TranscriptID?

    /// The prompt text, on `turnStarted` only.
    let prompt: String?

    /// Provider-issued child identity and metadata on subagent events.
    let subagentID: String?
    let subagentType: String?
    let subagentTranscriptPath: String?
    let lastAssistantMessage: String?
    let turnID: String?

    /// The agent's own work still in flight as its turn ends, by the identifier it gave each.
    ///
    /// Claude states this on `Stop` as `background_tasks`, and its own description of the field
    /// is the reason this is read at all: it exists to let a hook tell "session is done" from
    /// "session is paused waiting for background work to wake it". A backgrounded shell, a
    /// detached subagent or an MCP monitor will re-enter the conversation on its own, without
    /// the user, so the `Stop` that precedes it is not the end of anything.
    ///
    /// Identities rather than a count, because `BackgroundWorkLedger` has to tell work this
    /// turn started from work carried over from an earlier one — a count cannot.
    ///
    /// Empty where the key is absent, which is every event but `Stop`/`SubagentStop`, and every
    /// Codex report — 0.144.6 has no equivalent, so those sessions keep the old behaviour.
    let backgroundTaskIDs: [String]

    /// Builds a report from a hook's JSON payload, or nil if it names no event.
    init?(sessionID: SessionID, event: HookLifecycleEvent?, payload: [String: Any]) {
        guard let event else { return nil }

        self.sessionID = sessionID
        self.event = event
        self.agentSessionID = (payload["session_id"] as? String)
            .flatMap { $0.isEmpty ? nil : TranscriptID($0) }
        self.prompt = payload["prompt"] as? String
        self.subagentID = payload["agent_id"] as? String
        self.subagentType = payload["agent_type"] as? String
        self.subagentTranscriptPath = payload["agent_transcript_path"] as? String
        self.lastAssistantMessage = payload["last_assistant_message"] as? String
        self.turnID = payload["turn_id"] as? String
        // Only the identity is taken: the rest of each entry describes work this side never
        // renders. An entry whose id is missing falls back to its position, which is stable
        // across boundaries for as long as the entry is — so unreadable work still reads as
        // carried over rather than as new on every turn.
        let tasks = payload["background_tasks"] as? [[String: Any]] ?? []
        self.backgroundTaskIDs = tasks.enumerated().map { index, task in
            task["id"] as? String ?? "#\(index)"
        }
    }

    // MARK: - Child Admission

    /// Whether a `SubagentStart`/`SubagentStop` report describes a real delegated child, rather
    /// than the parent reporting its own turn — see `SubagentChildAdmission` for that shape and
    /// the measurements behind the rule.
    ///
    /// A child already tracked is always admitted, so one accepted at Start still receives its
    /// Stop even if that report carries less than the first did.
    func describesChildAgent(
        isAlreadyTracked: Bool,
        transcriptExists: (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) -> Bool {
        isAlreadyTracked || SubagentChildAdmission.namesAChild(
            role: subagentType,
            path: subagentTranscriptPath,
            transcriptExists: transcriptExists
        )
    }
}

// MARK: - Hook Lifecycle Relay

/// Delivers lifecycle reports from the listener to whatever is tracking the session.
///
/// A relay rather than a direct call because the reports arrive off the network, in a type that
/// knows nothing about AppKit, while every consumer of them is main-actor state. This is the
/// same shape `PermissionBroker.present` uses, and for the same reason.
@MainActor
enum HookLifecycleRelay {

    // MARK: - Properties

    /// Set by whatever owns the running sessions. Nil means the reports are dropped, which is
    /// correct: a report about a session nothing is showing changes nothing.
    static var observe: ((HookLifecycleReport) -> Void)?

    // MARK: - Public Methods

    /// Records one report and passes it on.
    ///
    /// Journalling happens here rather than in the observer so it survives a session that has
    /// no live controller — the prompt is the one thing a terminal session holds nowhere else
    /// until the CLI writes its transcript, which is exactly the window a crash lands in.
    static func deliver(_ report: HookLifecycleReport) {
        // Live view only. These arrive on every turn boundary of every session, so they belong
        // in the ring buffer `log stream` reads, not in a journal kept for two weeks.
        ThreadingLogger.agent.debug(
            """
            Lifecycle \(report.event.rawValue, privacy: .public) \
            for \(report.sessionID.uuidString, privacy: .public)
            """
        )

        if report.event == .turnStarted, let prompt = report.prompt, !prompt.isEmpty {
            EventLog.shared.record(.session, "Prompt submitted", [
                "session": report.sessionID.uuidString,
                "prompt": prompt
            ])
        }

        guard let observe else {
            // Before the relay is installed, or after it is torn down. Worth a record: it means
            // reports are arriving and being discarded, which from the sidebar is
            // indistinguishable from an agent that never reported at all.
            ThreadingLogger.agent.warning("Lifecycle report with no observer installed")
            EventLog.shared.record(.hooks, "Lifecycle report dropped, no observer", [
                "session": report.sessionID.uuidString,
                "event": report.event.rawValue
            ])
            return
        }

        observe(report)
    }
}
