import Foundation

// MARK: - Background Work Kind

/// What kind of work an agent left running, on the one axis that decides whether its turn is
/// waiting on it: whether the work ends on its own and hands a result back.
///
/// Read from the payload rather than guessed. Both surfaces already name the kind beside the
/// identity, which is the same reason `BackgroundWorkLedger` keeps identities instead of
/// classifying a command by its name.
enum BackgroundWorkKind: Equatable, Sendable {

    /// Work handed to another agent: a subagent or a workflow.
    ///
    /// Bounded by construction, and its result re-enters this conversation without the user.
    /// A turn that ends on top of one has not finished, however many turns ago it was started.
    case delegated

    /// Work the agent parked: a shell, a monitor, a teammate, or a kind this build has never
    /// heard of.
    ///
    /// A backgrounded `npm test` and an `npm run dev` that outlives the day are both this, and
    /// nothing in the payload separates them — so these are the ones the ledger judges by age.
    case standing

    /// Reads the kind out of the type a provider reported.
    ///
    /// **Both vocabularies, because the two surfaces spell it differently.** Claude's `Stop`
    /// hook sends the friendly label its own schema documents (`subagent`, `workflow`, `shell`,
    /// `monitor`), while `background_tasks_changed` on the stream sends the raw discriminant
    /// (`local_agent`, `local_workflow`, `local_bash`, `monitor_mcp`). Measured against CLI
    /// 2.1.224, where the hook's builder maps through a label table and the stream's does not.
    /// One type reading both spellings is the choice `ToolIdentity` already makes for tools: the
    /// behaviour is ours, the spelling is the provider's.
    ///
    /// Anything unrecognised is `.standing`, and that is the safe direction. A kind wrongly
    /// called delegated holds `working` on the sidebar for as long as it runs, while one wrongly
    /// left standing is judged by age — which is what every kind was judged by before this
    /// existed. A new task type should therefore behave no worse than it does today.
    init(reportedType: String?) {
        switch reportedType {
        case "subagent", "local_agent", "workflow", "local_workflow":
            self = .delegated
        default:
            self = .standing
        }
    }
}

// MARK: - Background Task

/// One piece of work an agent reported still running as its turn ended.
///
/// The identity is what the ledger tells boundaries apart by; the kind is what decides whether
/// it needs to. Nothing else about the entry is kept: the rest describes a shell, child or
/// monitor this side never renders.
struct BackgroundTask: Equatable, Sendable {

    // MARK: - Properties

    let id: String
    let kind: BackgroundWorkKind

    // MARK: - Initialization

    init(id: String, kind: BackgroundWorkKind) {
        self.id = id
        self.kind = kind
    }
}

// MARK: - Background Work Ledger

/// Decides whether the work an agent left running is work its turn is *waiting* on.
///
/// Both CLIs wake a session when a background task finishes, so "will this speak again" is true
/// of every entry and cannot separate them. Two facts do, and the kind is asked first:
///
/// - **Delegated work always pauses.** A subagent or a workflow is bounded and reports back into
///   the conversation, so a turn that ends while one runs has handed nothing to the user.
/// - **Standing work pauses only when it is new.** A task the agent started **in the turn that
///   just ended** is the reason that turn ended early: "test run queued; will report when it
///   lands" is a turn that is not over, and calling it finished is what posted a notification a
///   minute before the agent spoke again. One **carried over** from an earlier turn is parked —
///   a dev server started three turns ago is not what this turn is waiting for, and holding
///   every later turn open behind it would silence the session for as long as it ran.
///
/// **Age alone was the first rule, and it went blind on exactly the work it most needed to see.**
/// A background subagent is in flight at every boundary until it finishes, so it is new once and
/// carried over thereafter: the session showed `working` for the first turn after it was spawned
/// and `idle` for every turn after that, while the child worked on. Measured on CLI 2.1.224 in a
/// session that spent 13 minutes this way — four consecutive turns each ended with the same one
/// pending background agent, and only the first of them raised the mark. Worse off screen, where
/// the same boundary hands the session an unread mark and a "finished its turn" notification for
/// a turn whose child has not reported yet.
///
/// The kind is what fixes it, and it is an exact fact rather than a better guess: the CLI names
/// the task type in the same payload as the id. Classifying the *command* instead (`npm run dev`
/// is long-lived, `npm test` is not) was the alternative and is worse — a name-matching guess
/// where the payload already answers, covering only shells, and re-opening the bug above
/// whenever it guesses long-lived.
///
/// The one case still held open indefinitely is a turn that starts standing work and is never
/// followed by another turn. Nothing further happens in that session to notify about, so what
/// remains is a working mark beside a session that does, in fact, still have something running —
/// which is what the CLI's own footer says for exactly as long.
struct BackgroundWorkLedger {

    // MARK: - Properties

    /// What standing work was already in flight when the previous turn ended.
    ///
    /// Delegated work is deliberately absent: it never needs telling apart across boundaries,
    /// and keeping it here would only invite a later reader to judge it by age again.
    ///
    /// Replaced rather than accumulated: a task that finishes and a task that never started are
    /// the same thing to the next boundary, and keeping ids forever would make a reused one look
    /// carried over.
    private var carriedOver: Set<String> = []

    // MARK: - Initialization

    init() {}

    // MARK: - Public Methods

    /// Records a turn boundary, answering whether the turn is paused on what it left running.
    mutating func turnEnded(leaving inFlight: [BackgroundTask]) -> Bool {
        let standing = Set(inFlight.lazy.filter { $0.kind == .standing }.map(\.id))
        defer { carriedOver = standing }

        if inFlight.contains(where: { $0.kind == .delegated }) { return true }
        return !standing.subtracting(carriedOver).isEmpty
    }

    /// Forgets everything, for a process that no longer owns any of it.
    ///
    /// A relaunched agent inherits none of the old tasks and nothing will report them ending,
    /// so carrying the ids across would make the first genuinely new task look familiar.
    mutating func forget() {
        carriedOver = []
    }
}
