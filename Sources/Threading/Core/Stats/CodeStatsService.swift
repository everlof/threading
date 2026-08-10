import Foundation
import os

// MARK: - Code Stats Service

/// Keeps each project's code composition ready before anyone hovers.
///
/// The shape is `ArtifactScanService`'s — cached findings drawn immediately, refreshed
/// passively — but the economics are inverted: scc answers a whole repository in tens of
/// milliseconds, so the cache exists for the *first* glance after launch and for machines
/// with no scc at all, not to amortise an expensive walk.
///
/// The freshest trigger is the same moment the branch is re-read: a session that just
/// stopped working is a project whose code most likely just changed.
@MainActor
final class CodeStatsService {

    // MARK: - Singleton

    static let shared = CodeStatsService()

    // MARK: - Types

    /// One project's count, and when it was true.
    struct ProjectReading: Codable {
        var measuredAt: Date
        var stats: CodeStats
    }

    /// Whether scc exists on this machine.
    ///
    /// A miss carries when it was measured, because it is the one answer that goes stale by
    /// the user's own hand: the popover names the install command, and a `brew install scc`
    /// should start counting without a relaunch. `resolveTool` re-probes a stale miss.
    private enum Tool {
        case unresolved
        case missing(lastChecked: Date)
        case found(path: String)
    }

    // MARK: - Properties

    private var readings: [ProjectID: ProjectReading] = [:]
    private var inFlight: Set<ProjectID> = []

    private let persistence: RecoverableFileStore<[ProjectID: ProjectReading]>

    /// `.utility`, not `.background`: a count finishes in the time a hover dwell takes, so
    /// it is allowed to be prompt — it is just never allowed to be waited on.
    private let queue = DispatchQueue(label: "codes.threading.code-stats", qos: .utility)

    private var passiveTimer: Timer?

    // MARK: - Initialization

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)

        self.persistence = RecoverableFileStore(
            url: root.appendingPathComponent(CodeStatsDefaults.fileName),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        self.readings = persistence.load(defaultValue: [:]).value
    }

    // MARK: - Reading

    /// A project's last count, or nil if it never had one (or scc is not installed).
    func stats(for projectID: ProjectID) -> CodeStats? {
        readings[projectID]?.stats
    }

    /// Whether the machine is known to have no scc — what turns the popover into the
    /// install hint rather than silence. False while unresolved: "not looked yet" must not
    /// read as "not installed".
    var toolIsMissing: Bool {
        toolCache.withLock { if case .missing = $0 { return true }; return false }
    }

    /// When a project was last counted — the reading's age is part of the reading.
    func measuredAt(for projectID: ProjectID) -> Date? {
        readings[projectID]?.measuredAt
    }

    // MARK: - Refreshing

    /// Starts the passive refresh, once, at launch.
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

    /// Recounts every project whose reading has aged past `staleAfter` and which is not busy.
    func refreshStaleProjects() {
        let now = Date()
        for project in ProjectStore.shared.projects {
            let age = readings[project.id].map { now.timeIntervalSince($0.measuredAt) }
            guard age.map({ $0 > CodeStatsDefaults.staleAfter }) ?? true else { continue }
            refresh(project)
        }
    }

    /// Recounts when the reading is missing or has aged past `hoverRefreshAfter` — the hover
    /// entry point, which must not launch a process per pointer crossing.
    func refreshIfAged(_ project: Project) {
        let age = readings[project.id].map { Date().timeIntervalSince($0.measuredAt) }
        guard age.map({ $0 > CodeStatsDefaults.hoverRefreshAfter }) ?? true else { return }
        refresh(project)
    }

    /// Recounts the project a session belongs to — called on the stopped-working edge,
    /// which is when the code most recently changed.
    func refreshProject(forSessionID sessionID: SessionID) {
        guard let project = ProjectStore.shared.project(forSessionID: sessionID) else { return }
        refresh(project)
    }

    /// Recounts one project.
    ///
    /// Declines while a session in it is working: not for the disk's sake — a count is
    /// cheap — but because a tree mid-edit measures as neither the before nor the after.
    func refresh(_ project: Project, force: Bool = false) {
        guard !inFlight.contains(project.id) else { return }
        guard force || !isWorking(project) else { return }

        inFlight.insert(project.id)

        let projectID = project.id
        let folderPath = project.folderPath
        let shell = AgentLauncher.loginShellPath

        queue.async { [weak self] in
            let executable = self?.resolveTool(shell: shell)

            guard let executable else {
                Task { @MainActor in self?.inFlight.remove(projectID) }
                return
            }

            let stats = CodeStatsRunner.measure(folder: folderPath, executable: executable)
            let measuredAt = Date()

            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(projectID)
                guard let stats else { return }
                self.readings[projectID] = ProjectReading(measuredAt: measuredAt, stats: stats)
                self.save()
                NotificationCenter.default.post(CodeStatsDidChange(projectID: projectID))
            }
        }
    }

    // MARK: - Private Methods

    private func isWorking(_ project: Project) -> Bool {
        project.sessions.contains { AgentRuntime.shared.activity(sessionID: $0.id) == .working }
    }

    /// Resolves the binary on the scan queue — the login-shell probe is a subprocess, which
    /// is nothing the main actor should sit behind. Serialised by the queue itself. A find
    /// is kept for the app's run; a miss is re-probed once it ages past `missingReprobeAfter`,
    /// which is how installing scc heals the feature without a relaunch.
    private nonisolated func resolveTool(shell: String) -> String? {
        let cached = toolCache.withLock { $0 }
        switch cached {
        case .found(let path):
            return path
        case .missing(let lastChecked)
            where Date().timeIntervalSince(lastChecked) < CodeStatsDefaults.missingReprobeAfter:
            return nil
        case .missing, .unresolved:
            let wasUnresolved = { if case .unresolved = cached { return true }; return false }()
            let path = CodeStatsRunner.locate(shell: shell)
            toolCache.withLock {
                $0 = path.map { .found(path: $0) } ?? .missing(lastChecked: Date())
            }

            // The first miss is worth a line; the periodic re-probes repeating it are not.
            if path == nil, wasUnresolved {
                ThreadingLogger.agent.info("scc not found; code stats offer the install hint")
            }
            return path
        }
    }

    /// The resolved location, readable off the main actor. Only the scan queue writes it.
    private let toolCache = OSAllocatedUnfairLock(initialState: Tool.unresolved)

    // MARK: - Persistence

    /// Written whole, on every change — one summary line per language per project.
    private func save() {
        _ = persistence.save(readings)
    }
}
