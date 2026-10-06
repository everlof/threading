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

    /// A command whose result is still outstanding, across however many intervening replies.
    ///
    /// Test runs and long-lived servers share this provider type. Another turn passing cannot
    /// prove which it is, so both keep completion pending until the provider stops reporting it.
    case shell

    /// A monitor, teammate, or unrecognized kind. These retain the carry-over rule for work
    /// parked by an earlier turn.
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
    /// Unrecognized kinds retain the existing standing-work behavior.
    init(reportedType: String?) {
        switch reportedType {
        case "subagent", "local_agent", "workflow", "local_workflow":
            self = .delegated
        case "shell", "local_bash":
            self = .shell
        default:
            self = .standing
        }
    }

    var awaitsResult: Bool {
        switch self {
        case .delegated, .shell: true
        case .standing: false
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
/// Shells and delegated work keep the outcome pending at every boundary until their results
/// arrive. Treating a shell as parked at its second boundary posted completion alerts when
/// automatic watch messages woke an agent that was still waiting for its tests. The provider
/// reports the running shell explicitly; task age cannot overrule that fact.
///
/// Other standing work pauses only on its first boundary. A monitor may outlive many independent
/// turns, so its carried-over identity keeps those later turns from waiting on it again.
/// See `docs/architecture/session-activity.md` for the measured sequence and provider limitation.
struct BackgroundWorkLedger {

    // MARK: - Properties

    /// What standing work was already in flight when the previous turn ended.
    ///
    /// Shells and delegated work are absent: they never need telling apart across boundaries,
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

        if inFlight.contains(where: { $0.kind.awaitsResult }) { return true }
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
