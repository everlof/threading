import Foundation

struct SupervisionActionFailure: Error, Equatable, Sendable {
    let words: String

    init(_ words: String) {
        self.words = words
    }
}

/// Window-owned lifecycle capabilities used by manager tools.
///
/// The control plane decides whether an action is allowed. This registry only finds the
/// window that owns the session surfaces and asks its `SessionCoordinator` to perform the
/// already-authorized lifecycle change. Keeping the closures weak prevents the process-wide
/// MCP server from retaining a closed workspace window.
@MainActor
final class SupervisionActionRegistry {
    struct Actions {
        let spawn: (
            ScheduledSessionPlan, String, SessionID?, SessionID
        ) -> Result<AgentSession, SupervisionActionFailure>
        let resume: (SessionID) -> Bool
        let move: (SessionID, AgentAccount, SessionID) -> Result<String, SupervisionActionFailure>
        let finish: (SessionID, SessionID) -> Bool
    }

    static let shared = SupervisionActionRegistry()

    private var actions: Actions?

    func register(_ actions: Actions) {
        self.actions = actions
    }

    func current() -> Actions? { actions }
}
