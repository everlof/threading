import Foundation

// MARK: - Agent Mood

/// Every live session folded into the one mood a theme's mascot shows, and the two app events a
/// theme's moments answer.
///
/// **The aggregate nobody published.** `AgentWorkloadMonitor` already counts working sessions,
/// but nothing counted the ones waiting on the person — the sidebar derives that per project
/// for its collapsed rows and nothing else asked for it app-wide. This monitor counts both, from
/// the same two sources the workload monitor reads (`AgentRuntime.runningSessionIDs` and each
/// one's projected activity), on the same two events: an activity change and a structural store
/// change. A recount is O(live sessions) and only happens when a session's activity actually
/// moved, never per byte of output.
///
/// **Edges, not states, for moments.** A turn coming back and a session starting to wait are
/// read off `SessionRuntimeDidChange`, which carries the exact before-and-after the runtime
/// committed, so nothing here reconstructs an edge from two states it happened to see. A turn
/// that was interrupted, refused, parked on a limit or ended by the process exiting is not a
/// finish anybody celebrates.
///
/// Started lazily by whoever first needs it — the sidebar mascot or the moment presenter — so
/// a theme without either costs nothing, and the test host observes nothing unless a test
/// starts it.
@MainActor
final class AgentMoodMonitor {

    static let shared = AgentMoodMonitor()

    /// Counts behind the mood — what a test asks without a theme.
    struct Counts: Equatable {
        var live = 0
        var working = 0
        var attention = 0
    }

    private(set) var counts = Counts()
    private(set) var mood: ThemeMascotMood = .resting

    /// The mood without a celebration — what a mascot whose theme draws no celebrating pose
    /// shows while one is under way.
    var baseMood: ThemeMascotMood {
        ThemeMascotMood.resolve(
            live: counts.live,
            working: counts.working,
            attention: counts.attention,
            celebrating: false
        )
    }
    private var celebrating = false
    private var celebrationEnd: DispatchWorkItem?
    private let appEvents = AppEventObservations()
    private var started = false

    /// Replaceable so a test can count a fixture's sessions without a runtime.
    var countsProvider: () -> Counts = {
        let runtime = AgentRuntime.shared
        var counts = Counts()
        for sessionID in runtime.runningSessionIDs {
            counts.live += 1
            switch runtime.activity(sessionID: sessionID) {
            case .working:
                counts.working += 1
            case .awaitingUser, .needsAttention:
                counts.attention += 1
            case .dormant, .idle, .readyWithBackgroundWork, .limitReached:
                break
            }
        }
        return counts
    }

    // MARK: - Public Methods

    func start() {
        guard !started else { return }
        started = true
        appEvents.observe(SessionActivityDidChange.self) { [weak self] _ in
            self?.refresh()
        }
        appEvents.observe(ProjectsDidChange.self) { [weak self] event in
            switch event.sidebarImpact {
            case .projectRow, .sessionTitle, .terminalAdded, .terminalRow:
                break
            default:
                self?.refresh()
            }
        }
        appEvents.observe(SessionRuntimeDidChange.self) { [weak self] event in
            self?.runtimeDidChange(event.transition, cause: event.cause, sessionID: event.sessionID)
        }
        refresh()
    }

    /// Recounts and posts `AgentMoodDidChange` when the mood moved.
    func refresh() {
        counts = countsProvider()
        publishIfChanged()
    }

    /// Reads one runtime edge: a moment when it is one, and a celebration when a turn came
    /// back. Internal so a test can hand it a transition directly.
    func runtimeDidChange(
        _ transition: SessionRuntimeTransition,
        cause: SessionActivityCause?,
        sessionID: SessionID
    ) {
        if Self.startedWaiting(transition) {
            NotificationCenter.default.post(
                AgentMomentDidOccur(event: .needsAttention, sessionID: sessionID)
            )
        } else if Self.finishedTurn(transition, cause: cause) {
            NotificationCenter.default.post(
                AgentMomentDidOccur(event: .turnFinished, sessionID: sessionID)
            )
            celebrate()
        }
    }

    // MARK: - Edges

    /// A session that began waiting on the person — a permission, a question.
    nonisolated static func startedWaiting(_ transition: SessionRuntimeTransition) -> Bool {
        transition.current.activity == .awaitingUser
            && transition.previous.activity != .awaitingUser
    }

    /// A turn that came back with an answer: closed, the process still there, no limit hit,
    /// and not cut short.
    nonisolated static func finishedTurn(
        _ transition: SessionRuntimeTransition,
        cause: SessionActivityCause?
    ) -> Bool {
        guard transition.endedTurn,
              transition.current.process != .dormant,
              transition.current.blocker != .usageLimit else { return false }
        switch cause {
        case .turnInterrupted, .turnRefused, .limitParked:
            return false
        default:
            return true
        }
    }

    // MARK: - Private Methods

    private func celebrate() {
        celebrationEnd?.cancel()
        celebrating = true
        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.celebrating = false
            self.celebrationEnd = nil
            self.publishIfChanged()
        }
        celebrationEnd = end
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ThemeMascotLimits.celebrationDuration,
            execute: end
        )
        publishIfChanged()
    }

    private func publishIfChanged() {
        let resolved = ThemeMascotMood.resolve(
            live: counts.live,
            working: counts.working,
            attention: counts.attention,
            celebrating: celebrating
        )
        guard resolved != mood else { return }
        mood = resolved
        NotificationCenter.default.post(AgentMoodDidChange(mood: resolved))
    }
}

// MARK: - Events

/// The app's aggregate mood moved — what a theme's mascot listens for.
struct AgentMoodDidChange: AppEvent {
    static let name = Notification.Name("agentMoodDidChange")
    let mood: ThemeMascotMood
}

/// Something a theme may answer happened in one session.
struct AgentMomentDidOccur: AppEvent {
    static let name = Notification.Name("agentMomentDidOccur")
    let event: ThemeMomentEvent
    let sessionID: SessionID
}
