import Foundation

// MARK: - Turn Blocking Tools

/// The tools whose call parks a turn on the user.
///
/// A runtime asks for two different things and only one of them stops it. Permission to run a
/// command is asked *around* work it is already doing, and the CLI raises its own prompt for it;
/// a question is the work — the model called a tool whose entire result is the user's answer, and
/// nothing else happens until it comes back. The sidebar has no way to tell those apart from
/// output, and neither runtime says which it is: Claude reports both through one `Notification`,
/// six seconds after the *keyboard* goes quiet.
///
/// Naming the tools is what separates them. A call to one of these is, on its own, the whole
/// fact — the turn is stopped and the user is what it is stopped on — and it arrives before the
/// question is drawn rather than six seconds after the user stops touching it.
///
/// **This is the list to extend when another runtime grows one.** Everything downstream —
/// the hook registrations in `HookLifecycleEvent`, the settings each installer writes, the
/// `openAsks` fact in `SessionActivityTracker` — is already provider-neutral and reads the
/// answer from here. A runtime that names no tool registers no hook, which is the correct
/// behaviour rather than a gap: `HookRegistration.matched` refuses to write an unmatched hook,
/// since one would report every `Read` and every `Bash` as a question.
enum TurnBlockingTools {

    // MARK: - Public Methods

    /// The tool names this runtime stops on, exactly as its hooks spell them.
    ///
    /// A `switch` rather than a capability flag: this is vocabulary, like a launch line or a
    /// transcript layout, and the value differs per runtime rather than being present or absent.
    /// The compiler makes a sixth runtime a build error here, which is the reminder that a new
    /// CLI's question tool has to be looked up rather than assumed empty.
    static func names(for kind: AgentKind) -> [String] {
        switch kind {
        case .claude:
            // `AskUserQuestion` is the multiple-choice question; `ExitPlanMode` is the plan
            // waiting to be approved. Both are tool calls that return the user's answer, and
            // both were showing a spinner because the turn they sit in is genuinely still open.
            // Measured against CLI 2.1.222, whose dialog kinds are `permission_ask_user_question`
            // and `permission_exit_plan_mode_v2`.
            return ["AskUserQuestion", "ExitPlanMode"]
        case .codex, .grok, .openCode, .cursor:
            // None as of Codex 0.144.6, Grok, OpenCode and Cursor: each approves a *command*
            // mid-work, which is the other kind of ask, and none exposes a tool whose result is
            // the user's answer. Cursor's `cursor/ask_question` would be one — but it never
            // fired in any measured turn, and Threading registers no handler for it, so no
            // Cursor turn can be waiting on one. Their sessions keep the behaviour they have.
            return []
        }
    }
}
