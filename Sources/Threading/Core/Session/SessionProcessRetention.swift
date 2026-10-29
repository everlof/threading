import Foundation

// MARK: - Runtime coordinator

/// Applies `SessionProcessRetentionPolicy` while the app is alive and prepares the same decision
/// for a quit handoff.
///
/// Runtime edges, relevant durable-row changes, and settings changes are the wakeups. One timer is
/// pointed at the next age deadline; there is no per-session timer and no periodic polling.
@MainActor
final class SessionProcessRetentionCoordinator {
    struct Configuration: Equatable {
        let windowDays: Int
        let limit: Int
    }

    struct QuitDisposition: Equatable {
        /// Host-backed idle sessions intentionally omitted from the relaunch record. If still
        /// alive, the next app attaches to them; if their host deadline passed, they stay dormant.
        let warmHostSessionIDs: Set<SessionID>
        let hostIdleExpirations: [SessionID: Date]

        static let empty = QuitDisposition(warmHostSessionIDs: [], hostIdleExpirations: [:])
    }

    private let observations: AppEventObservations
    private let candidates: @MainActor () -> [SessionProcessRetentionCandidate]
    private let configuration: @MainActor () -> Configuration
    private let retire: @MainActor (SessionID) -> Void
    private let hasRemoteViewers: @MainActor (SessionID) -> Bool
    private let now: @MainActor () -> Date
    private let didRetire: @MainActor (Int) -> Void

    private var timer: Timer?
    private var remoteViewerPresence: [SessionID: Bool] = [:]
    private var isStarted = false
    private var isReconciling = false

    init(
        center: NotificationCenter = .default,
        candidates: @escaping @MainActor () -> [SessionProcessRetentionCandidate],
        configuration: @escaping @MainActor () -> Configuration,
        retire: @escaping @MainActor (SessionID) -> Void,
        hasRemoteViewers: @escaping @MainActor (SessionID) -> Bool,
        now: @escaping @MainActor () -> Date = Date.init,
        didRetire: @escaping @MainActor (Int) -> Void = { _ in }
    ) {
        observations = AppEventObservations(center: center)
        self.candidates = candidates
        self.configuration = configuration
        self.retire = retire
        self.hasRemoteViewers = hasRemoteViewers
        self.now = now
        self.didRetire = didRetire
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        observations.observe(SessionRuntimeDidChange.self) { [weak self] _ in
            self?.reconcile()
        }
        observations.observe(TerminalSessionDidEnd.self) { [weak self] _ in
            self?.reconcile()
        }
        observations.observe(SessionVisibilityDidChange.self) { [weak self] _ in
            self?.reconcile()
        }
        observations.observe(SessionFollowersDidChange.self) { [weak self] event in
            self?.followersChanged(for: event.sessionID)
        }
        observations.observe(ProjectsDidChange.self) { [weak self] event in
            self?.projectsChanged(event)
        }
        observations.observe(AppSettingsDidChange.self) { [weak self] event in
            guard event.affects(
                AppSettingIdentity.sessionRestoreWindowDays.rawValue,
                AppSettingIdentity.sessionRestoreLimit.rawValue
            ) else { return }
            self?.reconcile()
        }

        reconcile()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        observations.removeAll()
        timer?.invalidate()
        timer = nil
        remoteViewerPresence.removeAll()
    }

    /// Retires stale/over-cap settled processes before the app records and detaches what remains.
    /// Local visibility is ignored because the window is going away. A current remote watcher is
    /// still protected: quitting must not turn a viewer's live conversation into a stop.
    func prepareForQuit() -> QuitDisposition {
        stop()
        let current = candidates()
        let plan = makePlan(from: current, protectsLocalVisibility: false)
        applyRetirements(plan.retire)

        let hosted = Set(current.lazy.filter(\.isHostBacked).map(\.sessionID))
        let hostExpirations = plan.warmIdleExpirations.filter { hosted.contains($0.key) }
        return QuitDisposition(
            warmHostSessionIDs: Set(hostExpirations.keys),
            hostIdleExpirations: hostExpirations
        )
    }

    private func reconcile() {
        guard isStarted, !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        let current = candidates()
        remoteViewerPresence = Dictionary(
            uniqueKeysWithValues: current.map { ($0.sessionID, $0.hasRemoteViewers) }
        )
        let plan = makePlan(from: current, protectsLocalVisibility: true)
        applyRetirements(plan.retire)
        rearm(at: plan.nextEvaluationAt)
    }

    private func makePlan(
        from candidates: [SessionProcessRetentionCandidate],
        protectsLocalVisibility: Bool
    ) -> SessionProcessRetentionPlan {
        let configuration = configuration()
        return SessionProcessRetentionPolicy.plan(
            candidates: candidates,
            windowDays: configuration.windowDays,
            limit: configuration.limit,
            now: now(),
            protectsLocalVisibility: protectsLocalVisibility
        )
    }

    private func applyRetirements(_ sessionIDs: Set<SessionID>) {
        guard !sessionIDs.isEmpty else { return }
        for sessionID in sessionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            retire(sessionID)
        }
        didRetire(sessionIDs.count)
    }

    private func rearm(at date: Date?) {
        timer?.invalidate()
        timer = nil
        guard let date else { return }

        let interval = max(
            SessionProcessRetentionDefaults.minimumTimerInterval,
            date.timeIntervalSince(now())
        )
        let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        next.tolerance = min(
            SessionProcessRetentionDefaults.maximumTimerTolerance,
            interval * SessionProcessRetentionDefaults.timerToleranceFraction
        )
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    /// The followers event also reports resize/composer changes. Reconcile only when the Boolean
    /// protection fact changed, keeping those high-frequency presentation events O(1).
    private func followersChanged(for sessionID: SessionID) {
        let current = hasRemoteViewers(sessionID)
        guard remoteViewerPresence[sessionID] != current else { return }
        remoteViewerPresence[sessionID] = current
        reconcile()
    }

    private func projectsChanged(_ event: ProjectsDidChange) {
        switch event.sidebarImpact {
        case .sessionAdded, .sessionRemoved, .sessionStructure, .sessionRow,
             .projectRemoved, .projectStructure, .structure:
            reconcile()
        case .projectRow, .sessionTitle, .terminalAdded, .terminalRow:
            break
        }
    }
}

enum SessionProcessRetentionDefaults {
    static let minimumTimerInterval: TimeInterval = 1
    static let timerToleranceFraction = 0.05
    static let maximumTimerTolerance: TimeInterval = 5 * 60
}
