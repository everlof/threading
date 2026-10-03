import Foundation

enum ProjectAutoHideDefaults {
    static let days = 30
    static let dayRange = 1...365
    static let secondsPerDay: TimeInterval = 86_400
    static let checkInterval: TimeInterval = 3_600
    static let interactionCoalescingInterval: TimeInterval = 60
    static let recordsPerSlice = 256
}

/// One opt-in maintenance pass at launch, on preference changes, and hourly while enabled.
/// Catalog traversal yields after 256 value records; it never reads files or starts processes.
/// Visibility mutations use the same durable host operation as Hide Project.
@MainActor
final class ProjectAutoHideCoordinator {
    private let store: ProjectStore
    private let settings: AppSettings
    private let currentProjectID: () -> ProjectID?
    private let sessionIsProtected: (SessionID) -> Bool
    private let terminalIsBusy: (TerminalID) -> Bool
    private let now: () -> Date
    private let observations = AppEventObservations()
    private var pass: Task<Void, Never>?
    private var timer: Timer?
    private var isStarted = false

    init(
        store: ProjectStore,
        settings: AppSettings,
        currentProjectID: @escaping () -> ProjectID?,
        sessionIsProtected: @escaping (SessionID) -> Bool,
        terminalIsBusy: @escaping (TerminalID) -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.settings = settings
        self.currentProjectID = currentProjectID
        self.sessionIsProtected = sessionIsProtected
        self.terminalIsBusy = terminalIsBusy
        self.now = now
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observations.observe(AppSettingsDidChange.self) { [weak self] event in
            guard event.affects(AppSettingIdentity.autoHidesInactiveProjects.rawValue,
                                AppSettingIdentity.projectAutoHideDays.rawValue) else { return }
            self?.schedulePass()
        }
        schedulePass()
    }

    func stop() {
        isStarted = false
        observations.removeAll()
        pass?.cancel()
        pass = nil
        timer?.invalidate()
        timer = nil
    }

    /// Also used by deterministic tests with a fixed clock and isolated store.
    @discardableResult
    func reconcile() async -> Int {
        guard settings.autoHidesInactiveProjects, store.persistenceBlockReason == nil else { return 0 }
        let days = settings.projectAutoHideDays
        let cutoff = now().addingTimeInterval(-Double(days) * ProjectAutoHideDefaults.secondsPerDay)
        let projects = store.projects
        let structureRevision = store.structureRevision
        var examined = 0
        var hiddenCount = 0
        defer {
            if hiddenCount > 0 { store.publishProjectVisibilityChanges() }
        }

        for project in projects {
            if Task.isCancelled { return hiddenCount }
            examined += 1
            if examined.isMultiple(of: ProjectAutoHideDefaults.recordsPerSlice) { await Task.yield() }
            guard !project.isHidden, !project.isTheScratchpad,
                  project.id != currentProjectID(),
                  max(project.createdAt, project.lastInteractionAt ?? project.createdAt) <= cutoff else { continue }

            var isInactive = true
            for session in project.sessions {
                examined += 1
                if examined.isMultiple(of: ProjectAutoHideDefaults.recordsPerSlice) { await Task.yield() }
                if Task.isCancelled { return hiddenCount }
                if max(session.createdAt, session.lastUsedAt) > cutoff || sessionIsProtected(session.id) {
                    isInactive = false
                    break
                }
            }
            guard isInactive else { continue }
            for terminal in project.terminals {
                examined += 1
                if examined.isMultiple(of: ProjectAutoHideDefaults.recordsPerSlice) { await Task.yield() }
                if Task.isCancelled { return hiddenCount }
                if terminal.createdAt > cutoff || terminalIsBusy(terminal.id) {
                    isInactive = false
                    break
                }
            }

            // Work/input and explicit Show Project advance the project fence. Revalidate after
            // yielding, so fresh activity, a new child, or a navigation change cannot be hidden.
            guard store.structureRevision == structureRevision else { return hiddenCount }
            guard isInactive, !Task.isCancelled,
                  settings.autoHidesInactiveProjects, settings.projectAutoHideDays == days,
                  project.id != currentProjectID(),
                  let current = store.project(withID: project.id),
                  !current.isHidden, !current.isTheScratchpad,
                  current.lastInteractionAt == project.lastInteractionAt,
                  current.sessions.count == project.sessions.count,
                  current.terminals.count == project.terminals.count else { continue }
            let result = store.setProjectHidden(true, projectID: project.id, publishesChange: false)
            if result == .applied { hiddenCount += 1 }
            if result == .persistenceRefused { return hiddenCount }
            // One durable mutation per cooperative slice; navigation is published once per pass.
            await Task.yield()
        }
        return hiddenCount
    }

    private func schedulePass() {
        pass?.cancel()
        timer?.invalidate()
        timer = nil
        guard isStarted, settings.autoHidesInactiveProjects else { return }
        pass = Task { [weak self] in
            guard let self else { return }
            await self.reconcile()
            guard !Task.isCancelled, self.isStarted else { return }
            self.pass = nil
            let timer = Timer(timeInterval: ProjectAutoHideDefaults.checkInterval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePass() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}
