import Foundation

// MARK: - Cache Persistence

/// Applies exact reading updates on a utility queue and rewrites the rebuildable cache at most
/// once per coalescing window.
///
/// The main actor deliberately hands over only one small reading. Handing over its complete
/// dictionary on every completion would keep the JSON work off-main, but retain each dictionary
/// snapshot long enough to turn the next main-actor mutation into an O(projects) copy. The writer
/// instead loads its own dictionary lazily on its queue, merges exact identities, and owns every
/// later encode, atomic write, and read-back verification.
final class ProjectStatsCacheWriter<Key, Value>: @unchecked Sendable
where Key: Hashable & Codable & Sendable, Value: Codable & Sendable {

    private let store: RecoverableFileStore<[Key: Value]>
    private let cacheKind: String
    private let coalescingInterval: TimeInterval
    private let queue: DispatchQueue

    /// Queue-confined state. The dictionary starts nil so the service's main-actor cache and this
    /// writer never share copy-on-write storage after launch.
    private var persistedValues: [Key: Value]?
    private var pendingValues: [Key: Value] = [:]
    private var pendingUpdateCount = 0
    private var flushIsScheduled = false
    private var completedWriteCount = 0
    private var lastBatchSize = 0

    init(
        store: RecoverableFileStore<[Key: Value]>,
        cacheKind: String,
        coalescingInterval: TimeInterval,
        queue: DispatchQueue? = nil
    ) {
        self.store = store
        self.cacheKind = cacheKind
        self.coalescingInterval = max(coalescingInterval, 0)
        self.queue = queue ?? DispatchQueue(
            label: "codes.threading.project-stats.cache.\(cacheKind)",
            qos: .utility
        )
    }

    /// O(1) at the caller: only the changed identity and its compact value cross the queue.
    func schedule(_ value: Value, for key: Key) {
        queue.async { [self] in
            pendingValues[key] = value
            pendingUpdateCount += 1
            scheduleFlushIfNeeded()
        }
    }

    private func scheduleFlushIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !flushIsScheduled else { return }
        flushIsScheduled = true
        queue.asyncAfter(deadline: .now() + coalescingInterval) { [self] in
            flushPendingValues()
        }
    }

    private func flushPendingValues() {
        dispatchPrecondition(condition: .onQueue(queue))
        flushIsScheduled = false
        guard !pendingValues.isEmpty else { return }

        var values = persistedValues ?? store.load(defaultValue: [:]).value
        let updates = pendingValues
        let updateCount = pendingUpdateCount
        pendingValues.removeAll(keepingCapacity: true)
        pendingUpdateCount = 0
        for (key, value) in updates { values[key] = value }

        let span = PerformanceRecorder.shared.begin(
            "project-stats.cache-write",
            category: "persistence",
            metadata: [
                "cache": cacheKind,
                "entries": String(values.count),
                "updates": String(updateCount)
            ]
        )
        let saved = store.save(values)
        persistedValues = values
        completedWriteCount += 1
        lastBatchSize = updateCount
        span.end(metadata: ["result": saved ? "saved" : "failed"])
    }

    /// Deterministic seam for correctness and opt-in stress tests. Production relies on the
    /// ordinary delayed flush because these files are fully rebuildable caches.
    func flushForTesting(timeout: TimeInterval = 10) -> Bool {
        let completed = DispatchSemaphore(value: 0)
        queue.async { [self] in
            flushPendingValues()
            completed.signal()
        }
        return completed.wait(timeout: .now() + timeout) == .success
    }

    var completedWriteCountForTesting: Int { queue.sync { completedWriteCount } }
    var lastBatchSizeForTesting: Int { queue.sync { lastBatchSize } }
}

// MARK: - Project Stats Service

/// Keeps the cheap, glanceable facts for every project ready before anyone hovers.
///
/// Code composition and Git activity have separate caches, queues, and freshness clocks. A slow
/// history read therefore cannot delay scc, and adding another bounded metric does not require a
/// monolithic cache migration. Both refresh passively, on hover when aged, and when a session
/// stops working — the point at which project facts most likely changed.
@MainActor
final class ProjectStatsService {

    // MARK: - Singleton

    static let shared = ProjectStatsService()

    // MARK: - Types

    struct CodeReading: Codable, Sendable {
        var measuredAt: Date
        var stats: CodeStats
    }

    /// `activity == nil` is a cached, successful "not a Git repository" result. A process
    /// failure is not persisted, so a transient error can heal on the next refresh.
    struct ActivityReading: Codable, Sendable {
        var measuredAt: Date
        var activity: ProjectActivity?
    }

    // MARK: - Properties

    private var codeReadings: [ProjectID: CodeReading]
    private var activityReadings: [ProjectID: ActivityReading]
    private var codeInFlight: Set<ProjectID> = []
    private var activityInFlight: Set<ProjectID> = []

    private let codePersistence: ProjectStatsCacheWriter<ProjectID, CodeReading>
    private let activityPersistence: ProjectStatsCacheWriter<ProjectID, ActivityReading>

    /// Independent utility queues preserve prompt code counts without serializing them behind a
    /// large repository's bounded Git history query. Neither is ever waited on by the main actor.
    private let codeQueue = DispatchQueue(label: "codes.threading.project-stats.code", qos: .utility)
    private let activityQueue = DispatchQueue(
        label: "codes.threading.project-stats.activity",
        qos: .utility
    )

    private var passiveTimer: Timer?

    // MARK: - Initialization

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)

        let codeStore = RecoverableFileStore<[ProjectID: CodeReading]>(
            url: root.appendingPathComponent(CodeStatsDefaults.fileName),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        let activityStore = RecoverableFileStore<[ProjectID: ActivityReading]>(
            url: root.appendingPathComponent(ProjectActivityDefaults.fileName),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        codeReadings = codeStore.load(defaultValue: [:]).value
        activityReadings = activityStore.load(defaultValue: [:]).value
        codePersistence = ProjectStatsCacheWriter(
            store: codeStore,
            cacheKind: "code",
            coalescingInterval: CodeStatsDefaults.persistenceCoalescingInterval
        )
        activityPersistence = ProjectStatsCacheWriter(
            store: activityStore,
            cacheKind: "activity",
            coalescingInterval: CodeStatsDefaults.persistenceCoalescingInterval
        )
    }

    // MARK: - Reading

    func stats(for projectID: ProjectID) -> CodeStats? {
        codeReadings[projectID]?.stats
    }

    func codeMeasuredAt(for projectID: ProjectID) -> Date? {
        codeReadings[projectID]?.measuredAt
    }

    func activity(for projectID: ProjectID) -> ProjectActivity? {
        activityReadings[projectID]?.activity
    }

    func activityMeasuredAt(for projectID: ProjectID) -> Date? {
        activityReadings[projectID]?.measuredAt
    }

    // MARK: - Refreshing

    func startPassiveScanning() {
        guard passiveTimer == nil else { return }

        let timer = Timer.scheduledTimer(
            withTimeInterval: CodeStatsDefaults.passiveInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshStaleProjects() }
        }
        timer.tolerance = CodeStatsDefaults.passiveTolerance
        passiveTimer = timer

        DispatchQueue.main.asyncAfter(deadline: .now() + CodeStatsDefaults.firstPassDelay) {
            [weak self] in
            self?.refreshStaleProjects()
        }
    }

    func refreshStaleProjects() {
        let now = Date()
        for project in ProjectStore.shared.projects {
            let codeIsStale = isAged(
                codeReadings[project.id]?.measuredAt,
                past: CodeStatsDefaults.staleAfter,
                now: now
            )
            let activityIsStale = isAged(
                activityReadings[project.id]?.measuredAt,
                past: CodeStatsDefaults.staleAfter,
                now: now
            )
            refresh(project, code: codeIsStale, activity: activityIsStale)
        }
    }

    /// Refreshes only readings missing or older than the hover threshold. Repeated pointer
    /// crossings therefore never become repeated process launches.
    func refreshIfAged(_ project: Project) {
        let now = Date()
        refresh(
            project,
            code: isAged(
                codeReadings[project.id]?.measuredAt,
                past: CodeStatsDefaults.hoverRefreshAfter,
                now: now
            ),
            activity: isAged(
                activityReadings[project.id]?.measuredAt,
                past: CodeStatsDefaults.hoverRefreshAfter,
                now: now
            )
        )
    }

    func refreshProject(forSessionID sessionID: SessionID) {
        guard let project = ProjectStore.shared.project(forSessionID: sessionID) else { return }
        refresh(project)
    }

    func refresh(_ project: Project, force: Bool = false) {
        refresh(project, code: true, activity: true, force: force)
    }

    private func refresh(
        _ project: Project,
        code: Bool,
        activity: Bool,
        force: Bool = false
    ) {
        guard code || activity else { return }
        guard force || !isWorking(project) else { return }
        if code { refreshCode(project) }
        if activity { refreshActivity(project) }
    }

    private func refreshCode(_ project: Project) {
        guard !codeInFlight.contains(project.id) else { return }
        codeInFlight.insert(project.id)

        let projectID = project.id
        let folderPath = project.folderPath
        codeQueue.async { [weak self] in
            let stats = CodeStatsRunner.measure(folder: folderPath)
            let measuredAt = Date()

            Task { @MainActor in
                guard let self else { return }
                self.codeInFlight.remove(projectID)
                guard let stats else { return }
                let reading = CodeReading(measuredAt: measuredAt, stats: stats)
                self.codeReadings[projectID] = reading
                self.codePersistence.schedule(reading, for: projectID)
                NotificationCenter.default.post(ProjectStatsDidChange(projectID: projectID))
            }
        }
    }

    private func refreshActivity(_ project: Project) {
        guard !activityInFlight.contains(project.id) else { return }
        activityInFlight.insert(project.id)

        let projectID = project.id
        let folderPath = project.folderPath
        activityQueue.async { [weak self] in
            let measurement = ProjectActivityRunner.measure(folder: folderPath)
            let measuredAt = Date()

            Task { @MainActor in
                guard let self else { return }
                self.activityInFlight.remove(projectID)
                guard let measurement else { return }

                let value: ProjectActivity?
                switch measurement {
                case .notRepository: value = nil
                case .activity(let activity): value = activity
                }
                let reading = ActivityReading(
                    measuredAt: measuredAt,
                    activity: value
                )
                self.activityReadings[projectID] = reading
                self.activityPersistence.schedule(reading, for: projectID)
                NotificationCenter.default.post(ProjectStatsDidChange(projectID: projectID))
            }
        }
    }

    // MARK: - Private Methods

    private func isWorking(_ project: Project) -> Bool {
        project.sessions.contains { AgentRuntime.shared.activity(sessionID: $0.id) == .working }
    }

    private func isAged(_ date: Date?, past threshold: TimeInterval, now: Date) -> Bool {
        date.map { now.timeIntervalSince($0) > threshold } ?? true
    }
}
