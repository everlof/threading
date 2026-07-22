import Foundation

// MARK: - Hook Lifecycle Event

/// The turn boundaries an agent reports through its own hooks.
///
/// These exist because the alternative is inference. `SessionActivityTracker` derives the same
/// states from PTY output volume, which works for any program but is a proxy: it cannot tell
/// the agent thinking from the agent redrawing, and it needs a byte threshold and three quiet
/// periods to stay honest. A hook says so directly.
///
/// Only the events Skalman acts on are registered. Every hook is a process spawned on the
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

    /// The name Claude's settings file knows this event by.
    var claudeEventName: String {
        switch self {
        case .turnStarted: return "UserPromptSubmit"
        case .turnFinished: return "Stop"
        case .awaitingUser: return "Notification"
        case .sessionStarted: return "SessionStart"
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
    /// For Claude this is the id Skalman minted and already knows. For Codex it is the id the
    /// CLI assigns itself, which is otherwise only recoverable by scanning rollout files.
    let agentSessionID: String?

    /// The prompt text, on `turnStarted` only.
    let prompt: String?

    /// Builds a report from a hook's JSON payload, or nil if it names no event.
    init?(sessionID: SessionID, event: HookLifecycleEvent?, payload: [String: Any]) {
        guard let event else { return nil }

        self.sessionID = sessionID
        self.event = event
        self.agentSessionID = payload["session_id"] as? String
        self.prompt = payload["prompt"] as? String
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
        if report.event == .turnStarted, let prompt = report.prompt, !prompt.isEmpty {
            EventLog.shared.record(.session, "Prompt submitted", [
                "session": report.sessionID.uuidString,
                "prompt": prompt
            ])
        }

        observe?(report)
    }
}
