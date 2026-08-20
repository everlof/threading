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

// MARK: - Agent intensity

/// The theme-independent activity envelope behind ambient workload presentations.
///
/// The exact facts remain `AgentWorkload`: how many sessions are working and whether one is at
/// the top of its own model's effort ladder. `recentActivity` is deliberately only a visual
/// intensity signal. It rises from meaningful output/tool events and decays with time; it is not
/// token throughput, CPU load, or a claim that providers expose comparable compute telemetry.
struct AgentIntensity: Equatable, Sendable {
    var workload: AgentWorkload
    private(set) var recentActivity: Double
    private(set) var measuredAt: TimeInterval

    static let none = AgentIntensity(workload: .none, recentActivity: 0, measuredAt: 0)

    init(workload: AgentWorkload, recentActivity: Double, measuredAt: TimeInterval) {
        self.workload = workload
        self.recentActivity = min(max(recentActivity, 0), 1)
        self.measuredAt = measuredAt
    }

    /// One working session keeps a quiet floor while the model is thinking. More concurrent
    /// sessions raise that floor in bounded steps; output pulses occupy the remaining headroom.
    static func workloadFloor(for workingCount: Int) -> Double {
        guard workingCount > 0 else { return 0 }
        return min(
            AgentIntensityDefaults.baseWorkload
                + AgentIntensityDefaults.perAdditionalSession * Double(workingCount - 1),
            1
        )
    }

    /// The complete visual intensity at one monotonic instant.
    func level(at now: TimeInterval) -> Double {
        let floor = Self.workloadFloor(for: workload.workingCount)
        guard floor > 0 else { return 0 }
        let activity = decayedActivity(at: now)
        return min(1, floor + (1 - floor) * activity)
    }

    /// Restates an exact workload change without inventing activity. A fleet settling to zero
    /// clears the envelope immediately; nothing should keep dancing after the last turn ends.
    func updating(workload: AgentWorkload, at now: TimeInterval) -> AgentIntensity {
        guard workload.workingCount > 0 else {
            return AgentIntensity(workload: workload, recentActivity: 0, measuredAt: now)
        }
        return AgentIntensity(
            workload: workload,
            recentActivity: decayedActivity(at: now),
            measuredAt: now
        )
    }

    /// Adds one bounded semantic pulse after first bringing the prior envelope forward to now.
    func addingPulse(_ magnitude: Double, at now: TimeInterval) -> AgentIntensity {
        guard workload.workingCount > 0 else { return updating(workload: workload, at: now) }
        let current = decayedActivity(at: now)
        let admitted = min(max(magnitude, 0), 1)
        // Saturating addition: repeated small deltas approach full scale without one verbose
        // provider being able to grow the value past the shared range.
        let combined = current + admitted * (1 - current)
        return AgentIntensity(
            workload: workload,
            recentActivity: min(max(combined, 0), 1),
            measuredAt: now
        )
    }

    private func decayedActivity(at now: TimeInterval) -> Double {
        guard recentActivity > 0 else { return 0 }
        let elapsed = max(0, now - measuredAt)
        return recentActivity * exp(-elapsed / AgentIntensityDefaults.decayDuration)
    }
}

enum AgentIntensityDefaults {
    static let baseWorkload = 0.30
    static let perAdditionalSession = 0.10
    static let decayDuration: TimeInterval = 1.35
}

/// Provider-neutral pulse weights. Byte counts are compressed logarithmically so a terminal
/// printing a large table cannot drown out a native chat delivering smaller semantic deltas.
enum AgentActivityPulse {
    static func output(byteCount: Int) -> Double {
        guard byteCount > 0 else { return 0 }
        let units = log2(1 + Double(byteCount) / 64)
        return min(max(units / 6, 0.12), 0.72)
    }

    static func thinking(byteCount: Int) -> Double {
        output(byteCount: byteCount) * 0.55
    }

    static let assistantMessage = 0.48
    static let toolTransition = 0.62
    static let planOrBackgroundChange = 0.36
}

/// Posted by `AgentWorkloadMonitor` when the aggregate actually changes.
struct AgentWorkloadDidChange: AppEvent {
    static let name = Notification.Name("agentWorkloadDidChange")
    let workload: AgentWorkload
}

/// Posted when either an exact workload fact or the event-driven activity envelope changes.
struct AgentIntensityDidChange: AppEvent {
    static let name = Notification.Name("agentIntensityDidChange")
    let intensity: AgentIntensity
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
    private(set) var intensity: AgentIntensity = .none
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
        refresh(at: ProcessInfo.processInfo.systemUptime)
    }

    /// Records one meaningful provider-neutral activity pulse. The session must still be in
    /// `.working`; late terminal redraws and completion receipts therefore cannot revive a
    /// settled display.
    func recordActivity(sessionID: SessionID, magnitude: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        refresh(at: now)
        guard magnitude > 0,
              AgentRuntime.shared.activity(sessionID: sessionID) == .working else { return }
        let measured = intensity.addingPulse(magnitude, at: now)
        guard measured != intensity else { return }
        intensity = measured
        NotificationCenter.default.post(AgentIntensityDidChange(intensity: measured))
    }

    private func refresh(at now: TimeInterval) {
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

        let measuredIntensity = intensity.updating(workload: measured, at: now)
        guard measuredIntensity != intensity else { return }
        intensity = measuredIntensity
        NotificationCenter.default.post(AgentIntensityDidChange(intensity: measuredIntensity))
    }
}
