import Foundation

/// What this launch decided about each session, kept for as long as the answer is still true.
///
/// In memory only, and deliberately: it describes one launch, and a stale answer read from disk
/// after two days of use would explain a decision nobody is looking at any more.
@MainActor
final class SessionRestorationLedger {

    static let shared = SessionRestorationLedger()

    private var outcomes: [SessionID: SessionRestorationOutcome] = [:]

    func record(_ plan: StartupSessionRelaunch.Plan) {
        outcomes = plan.outcomes
    }

    /// Forgotten the moment the session runs. From then on, dormancy is its own agent having
    /// exited, not a decision this launch made, and the launch's reason would be a lie.
    func forget(sessionID: SessionID) {
        outcomes.removeValue(forKey: sessionID)
    }

    func outcome(for sessionID: SessionID) -> SessionRestorationOutcome? {
        outcomes[sessionID]
    }

    /// For tests, and for a reset that must not leave one launch's answers behind.
    func removeAll() {
        outcomes.removeAll()
    }
}
