import Foundation

// MARK: - Background Work Ledger

/// Decides whether the work an agent left running is work its turn is *waiting* on.
///
/// Both CLIs wake a session when a background task finishes, so "will this speak again" is true
/// of every entry and cannot separate them. What separates them is when the work appeared:
///
/// - A task the agent **started in the turn that just ended** is the reason that turn ended
///   early. "Test run queued; will report when it lands" is a turn that is not over, and
///   calling it finished is what posted a notification a minute before the agent spoke again.
/// - A task **carried over** from an earlier turn is parked. A dev server the agent started
///   three turns ago is not what this turn is waiting for, and holding every later turn open
///   behind it would silence the session's notifications for as long as the server runs.
///
/// So the ledger keeps the ids that were already in flight at the previous turn boundary, and
/// a boundary pauses the session only if it brought something new. That is an exact reading of
/// what the agent did rather than a guess about what a command is: classifying `npm run dev`
/// as long-lived and `npm test` as not would be a name-matching heuristic, and being wrong in
/// the long-lived direction re-opens the bug this exists to close.
///
/// The one case it still holds open indefinitely is a turn that starts long-lived work and is
/// never followed by another turn. Nothing further happens in that session to notify about, so
/// what remains is a working mark beside a session that does, in fact, still have something
/// running — which is what the CLI's own footer says for exactly as long.
struct BackgroundWorkLedger {

    // MARK: - Properties

    /// What was already in flight when the previous turn ended.
    ///
    /// Replaced rather than accumulated: a task that finishes and a task that never started
    /// are the same thing to the next boundary, and keeping ids forever would make a reused
    /// one look carried over.
    private var carriedOver: Set<String> = []

    // MARK: - Initialization

    init() {}

    // MARK: - Public Methods

    /// Records a turn boundary, answering whether the turn is paused on what it left running.
    mutating func turnEnded(leaving inFlight: [String]) -> Bool {
        let current = Set(inFlight)
        defer { carriedOver = current }
        return !current.subtracting(carriedOver).isEmpty
    }

    /// Forgets everything, for a process that no longer owns any of it.
    ///
    /// A relaunched agent inherits none of the old tasks and nothing will report them ending,
    /// so carrying the ids across would make the first genuinely new task look familiar.
    mutating func forget() {
        carriedOver = []
    }
}
