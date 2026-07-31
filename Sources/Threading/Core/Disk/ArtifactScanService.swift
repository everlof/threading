import Foundation

// MARK: - Artifact Scan Service

/// Keeps the answer to "what can be reclaimed" ready before anyone asks.
///
/// A scan is expensive in a way the *size* of its result does not suggest: finding 45
/// directories means walking every other directory in four projects first, which took a bit
/// over a minute here. Doing that when the Storage page opens means the page opens empty and
/// stays empty, every time, for a set of numbers that barely move between builds.
///
/// So the findings are **cached on disk** and the page draws them immediately, and a scan runs
/// **passively in the background** to keep them true. What the page triggers is a refresh of
/// something already shown, not the first sight of it.
///
/// Two rules keep the passive scan from being a nuisance:
///
/// - It runs at `.background` QoS, which the system throttles for I/O — this is a chore, and it
///   should lose every race against the thing the user is actually doing.
/// - It **skips a project whose sessions are working**. An agent mid-build is both the worst
///   time to compete for the disk and the worst time to measure, since the directory is
///   changing underneath the walk.
@MainActor
final class ArtifactScanService {

    // MARK: - Singleton

    static let shared = ArtifactScanService()

    // MARK: - Types

    /// One project's findings, and when they were true.
    struct ProjectScan: Codable {
        var scannedAt: Date
        var artifacts: [ReclaimableArtifact]

        var byteCount: Int64 { artifacts.reduce(0) { $0 + $1.byteCount } }
    }

    // MARK: - Properties

    private var scans: [ProjectID: ProjectScan] = [:]

    /// Projects being scanned right now, so a passive pass and a Rescan cannot walk the same
    /// tree twice at once.
    private var inFlight: Set<ProjectID> = []

    /// Whether anything is being scanned, which the page shows rather than a spinner.
    var isScanning: Bool { !inFlight.isEmpty }

    private let fileManager: FileManager
    private let persistence: RecoverableFileStore<[ProjectID: ProjectScan]>

    /// The chore's own queue. `.background` rather than `.utility`: the system throttles its
    /// I/O, which is exactly right for work nobody is waiting on.
    private let queue = DispatchQueue(label: "codes.threading.artifact-scan", qos: .background)

    private var passiveTimer: Timer?

    // MARK: - Initialization

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)

        self.persistence = RecoverableFileStore(
            url: root.appendingPathComponent(ArtifactScanDefaults.fileName),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        self.scans = persistence.load(defaultValue: [:]).value
    }

    // MARK: - Reading

    /// A project's findings, minus anything that has since vanished from disk.
    ///
    /// The existence check is a stat per directory — tens of them, against a walk of hundreds
    /// of thousands of files — so a directory removed by hand (or by `cargo clean`) drops out
    /// of the page at once rather than at the next full scan.
    func artifacts(for projectID: ProjectID) -> [ReclaimableArtifact] {
        (scans[projectID]?.artifacts ?? []).filter {
            fileManager.fileExists(atPath: $0.url.path)
        }
    }

    /// When a project was last measured, or nil if it never has been.
    func scannedAt(for projectID: ProjectID) -> Date? {
        scans[projectID]?.scannedAt
    }

    /// The oldest reading on show, which is what the page's freshness line can honestly claim.
    func oldestScan(among projectIDs: [ProjectID]) -> Date? {
        projectIDs.compactMap { scans[$0]?.scannedAt }.min()
    }

    // MARK: - Scanning

    /// Starts the passive scan, once, at launch.
    ///
    /// The first pass is deferred rather than immediate: launch is already busy restoring a
    /// session and starting an agent, and this is the least urgent thing the app does.
    func startPassiveScanning() {
        guard passiveTimer == nil else { return }

        let timer = Timer.scheduledTimer(
            withTimeInterval: ArtifactScanDefaults.passiveInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshStaleProjects() }
        }
        timer.tolerance = ArtifactScanDefaults.passiveTolerance
        passiveTimer = timer

        DispatchQueue.main.asyncAfter(deadline: .now() + ArtifactScanDefaults.firstPassDelay) {
            [weak self] in
            self?.refreshStaleProjects()
        }
    }

    /// Rescans every project whose reading has aged past `staleAfter` and which is not busy.
    func refreshStaleProjects() {
        let now = Date()
        for project in ProjectStore.shared.projects {
            let age = scans[project.id].map { now.timeIntervalSince($0.scannedAt) }
            guard age.map({ $0 > ArtifactScanDefaults.staleAfter }) ?? true else { continue }
            refresh(project)
        }
    }

    /// Rescans everything on demand, ignoring both staleness and the busy rule — this is the
    /// Rescan button, where the user has asked for the disk to be read *now*.
    func refreshAll() {
        for project in ProjectStore.shared.projects {
            refresh(project, force: true)
        }
    }

    /// Rescans one project.
    ///
    /// Declines while a session in it is working, unless forced: an agent mid-build is both the
    /// worst moment to compete for the disk and the worst moment to measure a directory it is
    /// still writing.
    func refresh(_ project: Project, force: Bool = false) {
        guard !inFlight.contains(project.id) else { return }
        guard force || !isWorking(project) else { return }

        inFlight.insert(project.id)
        notifyChanged()

        let projectID = project.id
        let folderPath = project.folderPath

        queue.async { [weak self] in
            let artifacts = ArtifactScanner.scan(projectFolder: folderPath)
            let scannedAt = Date()

            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(projectID)
                self.scans[projectID] = ProjectScan(scannedAt: scannedAt, artifacts: artifacts)
                self.save()
                self.notifyChanged()
            }
        }
    }

    /// Drops what was removed from the cached reading without re-walking anything, so the page
    /// reflects a deletion the moment it happens.
    func forget(_ removed: [ReclaimableArtifact], in projectID: ProjectID) {
        guard var scan = scans[projectID] else { return }

        let paths = Set(removed.map(\.url.path))
        scan.artifacts.removeAll { paths.contains($0.url.path) }
        scans[projectID] = scan

        save()
        notifyChanged()
    }

    private func isWorking(_ project: Project) -> Bool {
        project.sessions.contains { AgentRuntime.shared.activity(sessionID: $0.id) == .working }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(ArtifactScanDidChange())
    }

    // MARK: - Persistence

    /// Written whole, on every change. The file is a few kilobytes — one line per reclaimable
    /// directory — so there is nothing here worth coalescing.
    private func save() {
        _ = persistence.save(scans)
    }
}

// MARK: - Artifact Scan Defaults

enum ArtifactScanDefaults {
    static let fileName = "storage-scan.json"

    /// Long enough that launch is over and the first agent has settled.
    static let firstPassDelay: TimeInterval = 90

    /// How often the passive pass looks for something stale. Build output does not change
    /// quickly enough to be worth chasing, and the page can always be told to rescan.
    static let passiveInterval: TimeInterval = 15 * 60
    static let passiveTolerance: TimeInterval = 60

    /// When a reading stops being worth showing without checking again.
    static let staleAfter: TimeInterval = 60 * 60
}
