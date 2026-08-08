import Foundation

/// The one aggregate the composer's activity beam draws: how many sessions are
/// working right now, and whether any of them runs at the top of its
/// provider's reasoning ladder.
///
/// "Working" is `SessionActivity.working` alone. A session waiting on the user
/// (`awaitingUser`, `needsAttention`) is not work in progress — counting it
/// would hold the beam lit for exactly the sessions where the user is the
/// reason nothing is happening.
struct AgentWorkload: Equatable, Sendable {
    var workingCount: Int
    var anyAtTopEffort: Bool

    static let none = AgentWorkload(workingCount: 0, anyAtTopEffort: false)
}

/// Posted by `AgentWorkloadMonitor` when the aggregate actually changes.
struct AgentWorkloadDidChange: AppEvent {
    static let name = Notification.Name("agentWorkloadDidChange")
    let workload: AgentWorkload
}

extension AgentWorkload {
    /// Measures the aggregate over the sessions currently in `.working`.
    ///
    /// "Top effort" is judged against the ladder the session's own runtime
    /// announced (`reasoningLevels`, ordered lowest to highest), never against
    /// a list of provider level names — the same reasoning as
    /// `AgentKind.capabilities`: a renamed or newly added level must degrade
    /// to "not top", not to a provider comparison somewhere new.
    static func measure(
        workingSessions: [AgentSession],
        account: (AgentKind, AccountHandle) -> AgentAccount?
    ) -> AgentWorkload {
        AgentWorkload(
            workingCount: workingSessions.count,
            anyAtTopEffort: workingSessions.contains { session in
                runsTopEffort(session, account: account(session.kind, session.accountHandle))
            }
        )
    }

    private static func runsTopEffort(_ session: AgentSession, account: AgentAccount?) -> Bool {
        guard
            let option = AgentModels.option(
                identifier: session.model, for: session.kind, account: account
            ),
            let top = option.reasoningLevels.last?.effort
        else { return false }
        return AgentModels.effectiveEffort(
            for: session, model: session.model, account: account
        ) == top
    }
}

/// Watches every session's activity and keeps the one aggregate current,
/// posting `AgentWorkloadDidChange` on a real change.
///
/// Started from the real app startup beside the other observers, so the test
/// host never observes anything.
@MainActor
final class AgentWorkloadMonitor {
    static let shared = AgentWorkloadMonitor()

    private(set) var workload: AgentWorkload = .none
    private let appEvents = AppEventObservations()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        appEvents.observe(SessionActivityDidChange.self) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    /// Recomputes from the runtime and the store; posts only on change.
    func refresh() {
        let runtime = AgentRuntime.shared
        let workingSessions = runtime.runningSessionIDs
            .filter { runtime.activity(sessionID: $0) == .working }
            .compactMap { ProjectStore.shared.session(withID: $0) }
        let measured = AgentWorkload.measure(workingSessions: workingSessions) {
            AgentAccountDiscovery.account(for: $0, handle: $1)
        }
        guard measured != workload else { return }
        workload = measured
        NotificationCenter.default.post(AgentWorkloadDidChange(workload: measured))
    }
}
