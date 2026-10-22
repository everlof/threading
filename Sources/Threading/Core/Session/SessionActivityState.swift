import Foundation

// MARK: - Session Activity

/// What a session is currently doing, as shown in the sidebar.
enum SessionActivity: Equatable, Sendable {
    /// No terminal allocated; the session can be resumed.
    case dormant

    /// Running but producing no output — an agent waiting at its prompt.
    case idle

    /// Producing output, i.e. the agent has an open turn.
    case working

    /// The prompt can accept another message, while work left by an earlier turn can still
    /// re-enter the conversation without anybody typing.
    case readyWithBackgroundWork

    /// Asked something mid-turn and cannot go on until it is answered.
    ///
    /// Separate from `needsAttention` because the two cost the user different things: this one
    /// is a turn stopped dead waiting on them, where a finished turn is only unread. They are
    /// the same fact — the session wants you — at opposite ends of urgency, and a sidebar that
    /// drew them alike could not say which of ten sessions was actually blocked.
    case awaitingUser

    /// Finished working while the session was not on screen.
    case needsAttention

    /// The provider refused the turn because the account's usage limit is spent, and nothing
    /// will happen here until the window resets or the conversation moves to another login.
    ///
    /// Its own state rather than a shade of `needsAttention`, because the two answer different
    /// questions. Every other state here says what the session is doing; this one says why it is
    /// doing nothing, and it is the only one the user cannot resolve by looking. It was found by
    /// wearing the alternative: a session refused at 10:45 went on drawing a spinner until the
    /// user noticed at 11:04 and asked what had happened.
    case limitReached

    /// The name this state is written under in the log.
    ///
    /// Stated rather than reflected: a diagnostic trail is read months later beside the code
    /// that wrote it, and `String(describing:)` would silently rename every past line the day
    /// a case is renamed.
    var logName: String {
        switch self {
        case .dormant: return "dormant"
        case .idle: return "idle"
        case .working: return "working"
        case .readyWithBackgroundWork: return "readyWithBackgroundWork"
        case .awaitingUser: return "awaitingUser"
        case .needsAttention: return "needsAttention"
        case .limitReached: return "limitReached"
        }
    }
}
