import Foundation

// MARK: - Session Snooze Center

/// Owns the persisted visibility overlay and its important-activity wake rules.
///
/// There is one deadline timer for the process, never one timer or view per session. The timer
/// is only an invalidation aid: every read derives `isSnoozed` from the persisted deadline, and
/// startup plus significant wall-clock changes materialize missed deadlines into durable wake
/// receipts. Expected scale is 50 active sessions and 5,000 historical sessions; startup makes
/// one pass through the already-loaded records, while activity callbacks are O(1).
@MainActor
final class SessionSnoozeCenter {

    static let shared = SessionSnoozeCenter()

    typealias Clock = @MainActor () -> Date
    typealias Activity = @MainActor (SessionID) -> SessionActivity

    private let projectStore: ProjectStore
    private let now: Clock
    private let activity: Activity
    private let observations: AppEventObservations
    private var deadlines: [SessionID: Date] = [:]
    private var deadlineTimer: Timer?
    private(set) var isStarted = false

    init(
        projectStore: ProjectStore = .shared,
        now: @escaping Clock = { Date() },
        activity: @escaping Activity = { AgentRuntime.shared.activity(sessionID: $0) },
        notificationCenter: NotificationCenter = .default
    ) {
        self.projectStore = projectStore
        self.now = now
        self.activity = activity
        self.observations = AppEventObservations(center: notificationCenter)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        rebuildDeadlinesAndMaterializeExpiry()
        observations.observe(NSNotification.Name.NSSystemClockDidChange) { [weak self] in
            self?.refreshAfterClockChange()
        }
        observations.observe(NSNotification.Name.NSSystemTimeZoneDidChange) { [weak self] in
            self?.refreshAfterClockChange()
        }
        // Providers with exact hooks wake at the event boundary below. This shared activity
        // edge is the provider-neutral fallback for a surface that can only report state.
        observations.observe(SessionActivityDidChange.self) { [weak self] event in
            self?.activityChanged(for: event.sessionID)
        }
    }

    func isSnoozed(_ sessionID: SessionID) -> Bool {
        guard let session = projectStore.session(withID: sessionID) else { return false }
        return session.isSnoozed(at: now())
    }

    func snooze(_ sessionID: SessionID, until deadline: Date) {
        let date = now()
        guard deadline > date else { return }
        projectStore.setSnoozed(
            until: deadline,
            at: date,
            hadTurnInFlight: activity(sessionID).hasTurnInFlight,
            for: sessionID
        )
        guard projectStore.session(withID: sessionID)?.isSnoozed(at: date) == true else { return }
        deadlines[sessionID] = deadline
        scheduleDeadlineTimer()
        AttentionAlertCenter.shared.preferencesChanged()
    }

    func unsnooze(_ sessionID: SessionID) {
        projectStore.clearSnooze(for: sessionID)
        deadlines[sessionID] = nil
        scheduleDeadlineTimer()
        AttentionAlertCenter.shared.preferencesChanged()
    }

    /// Records a new important edge. Merely reading old state never calls this method, which is
    /// what prevents a failure or request that predates Snooze from waking it on relaunch.
    func record(_ reason: SessionWakeReason, for sessionID: SessionID) {
        let date = now()
        guard let session = projectStore.session(withID: sessionID),
              session.isSnoozed(at: date),
              let snoozedAt = session.snoozedAt,
              date >= snoozedAt else { return }
        if reason == .turnCompleted, !session.hadTurnInFlightWhenSnoozed { return }

        projectStore.wakeSnoozedSession(sessionID, reason: reason, at: date)
        deadlines[sessionID] = nil
        scheduleDeadlineTimer()
    }

    func acknowledge(_ sessionID: SessionID) {
        guard projectStore.session(withID: sessionID)?.wake != nil else { return }
        projectStore.acknowledgeWake(for: sessionID)
    }

    private func activityChanged(for sessionID: SessionID) {
        guard let session = projectStore.session(withID: sessionID),
              session.isSnoozed(at: now()) else { return }
        let current = activity(sessionID)
        if current == .awaitingUser {
            record(.inputRequested, for: sessionID)
        } else if session.hadTurnInFlightWhenSnoozed, !current.hasTurnInFlight {
            record(.turnCompleted, for: sessionID)
        }
    }

    /// Public for deterministic tests and for system-clock/calendar notifications. Correctness
    /// comes from the stored dates; it does not matter whether the previous timer fired.
    func refreshAfterClockChange() {
        let date = now()
        for (sessionID, deadline) in Array(deadlines) where deadline <= date {
            guard projectStore.session(withID: sessionID)?.isSnoozed(at: date) == false else {
                continue
            }
            projectStore.wakeSnoozedSession(sessionID, reason: .timeReached, at: deadline)
            deadlines[sessionID] = nil
        }
        scheduleDeadlineTimer()
    }

    private func rebuildDeadlinesAndMaterializeExpiry() {
        let date = now()
        deadlines.removeAll(keepingCapacity: true)
        for project in projectStore.projects {
            for session in project.sessions where !session.isArchived {
                guard let deadline = session.snoozedUntil,
                      session.snoozedAt != nil else { continue }
                if session.isSnoozed(at: date) {
                    deadlines[session.id] = deadline
                } else {
                    projectStore.wakeSnoozedSession(
                        session.id,
                        reason: .timeReached,
                        at: deadline
                    )
                }
            }
        }
        scheduleDeadlineTimer()
    }

    private func scheduleDeadlineTimer() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard isStarted, let deadline = deadlines.values.min() else { return }
        let interval = max(0.05, deadline.timeIntervalSince(now()))
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
            [weak self] _ in
            Task { @MainActor in self?.refreshAfterClockChange() }
        }
    }
}
