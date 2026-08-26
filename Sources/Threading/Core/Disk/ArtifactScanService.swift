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
///
/// **There is a second scope beside the projects.** The scratch locations agents build in —
/// `/private/tmp` and the per-user temporary directory — belong to no project, so they are kept
/// as one extra reading rather than under a synthetic project id, and persisted in a file of
/// their own: the projects' store holds `[ProjectID: ProjectScan]`, and widening that shape
/// would break the decode of the cache the page draws on first paint, while a second file needs
/// no migration at all. It rides the same passive timer, and its busy rule is the broader one —
/// see `refreshScratch(force:)`.
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

    /// The scratch scope's one reading. Nil until it has ever been taken.
    private var scratchScan: ProjectScan?

    /// Projects being scanned right now, so a passive pass and a Rescan cannot walk the same
    /// tree twice at once.
    private var inFlight: Set<ProjectID> = []

    /// The same guard for the scratch scope, which has no project id to be a member of a set:
    /// walking `/private/tmp` twice at once is the one thing the roots make expensive.
    private var isScratchInFlight = false

    /// Whether anything is being scanned, which the page shows rather than a spinner.
    var isScanning: Bool { !inFlight.isEmpty || isScratchInFlight }

    private let fileManager: FileManager
    private let persistence: RecoverableFileStore<[ProjectID: ProjectScan]>
    private let scratchPersistence: RecoverableFileStore<ProjectScan?>

    /// Where the scratch walk looks. Injected so a test can point it at a fixture directory
    /// instead of the machine's real temporary directories.
    private let scratchRoots: [URL]

    /// The projects the passive pass sweeps, and whose sessions both busy rules ask about.
    private let projectsProvider: @MainActor () -> [Project]

    /// A stated answer for the scratch scope's busy rule, or nil to ask the runtime. Injected
    /// for the same reason as the roots: a test states the answer rather than starting an agent
    /// to produce one.
    private let scratchBusyOverride: (@MainActor () -> Bool)?

    /// The chore's own queue. `.background` rather than `.utility`: the system throttles its
    /// I/O, which is exactly right for work nobody is waiting on.
    ///
    /// Which is also why the QoS is a seam. A test *is* waiting on it, with a timeout, and
    /// `.background` is precisely the promise that the system may defer this work for as long as
    /// it likes — so on a machine that is compiling something else the walk misses a ten-second
    /// wait and the whole suite fails on scheduling rather than on behaviour. The walk's result
    /// does not depend on its priority; only its punctuality does.
    private let queue: DispatchQueue

    private var passiveTimer: Timer?

    // MARK: - Initialization

    /// Everything past `fileManager` is a seam for tests; production constructs this with no
    /// arguments and gets the real roots, the real project list and the real runtime.
    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        scratchRoots: [URL] = ScratchDefaults.roots,
        projects: (@MainActor () -> [Project])? = nil,
        isAnySessionWorking: (@MainActor () -> Bool)? = nil,
        qualityOfService: DispatchQoS = .background
    ) {
        self.queue = DispatchQueue(
            label: "codes.threading.artifact-scan",
            qos: qualityOfService
        )
        self.fileManager = fileManager
        self.scratchRoots = scratchRoots
        self.projectsProvider = projects ?? { ProjectStore.shared.projects }
        self.scratchBusyOverride = isAnySessionWorking

        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)

        self.persistence = RecoverableFileStore(
            url: root.appendingPathComponent(ArtifactScanDefaults.fileName),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        self.scratchPersistence = RecoverableFileStore(
            url: root.appendingPathComponent(ArtifactScanDefaults.scratchFileName),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        self.scans = persistence.load(defaultValue: [:]).value
        self.scratchScan = scratchPersistence.load(defaultValue: nil).value
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

    /// The scratch scope's findings, minus anything that has since vanished from disk.
    ///
    /// The same filter as `artifacts(for:)`, and here it is load-bearing rather than a nicety.
    /// A scratch root is far more volatile than a project: during a five-minute measurement for
    /// this feature one session directory under `/private/tmp` fell from 21 GB to 92 KB with
    /// nobody asking for it, because agents and the OS both clean here. A cached reading of that
    /// goes stale between two glances at the page, not between two builds.
    func scratchArtifacts() -> [ReclaimableArtifact] {
        (scratchScan?.artifacts ?? []).filter {
            fileManager.fileExists(atPath: $0.url.path)
        }
    }

    /// When a project was last measured, or nil if it never has been.
    func scannedAt(for projectID: ProjectID) -> Date? {
        scans[projectID]?.scannedAt
    }

    /// When the scratch scope was last measured, or nil if it never has been.
    func scratchScannedAt() -> Date? {
        scratchScan?.scannedAt
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

        ThreadingLogger.storage.info("Passive artifact scanning scheduled")

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

    /// Rescans every scope whose reading has aged past `staleAfter` and which is not busy.
    ///
    /// The scratch scope is swept here rather than on a timer of its own, which is what gives it
    /// the launch-deferred first pass and the 15-minute cadence without another schedule to keep
    /// true.
    func refreshStaleProjects() {
        let now = Date()
        for project in projectsProvider() {
            let age = scans[project.id].map { now.timeIntervalSince($0.scannedAt) }
            guard age.map({ $0 > ArtifactScanDefaults.staleAfter }) ?? true else { continue }
            refresh(project)
        }

        let scratchAge = scratchScan.map { now.timeIntervalSince($0.scannedAt) }
        if scratchAge.map({ $0 > ArtifactScanDefaults.staleAfter }) ?? true {
            refreshScratch()
        }
    }

    /// Rescans everything on demand, ignoring both staleness and the busy rule — this is the
    /// Rescan button, where the user has asked for the disk to be read *now*.
    func refreshAll() {
        let projects = projectsProvider()
        ThreadingLogger.storage.notice(
            "Artifact rescan requested projects=\(projects.count, privacy: .public)"
        )
        for project in projects {
            refresh(project, force: true)
        }
        refreshScratch(force: true)
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
        let startedAt = Date()
        ThreadingLogger.storage.debug(
            "Artifact scan started project=\(projectID.uuidString, privacy: .public) forced=\(force, privacy: .public)"
        )

        queue.async { [weak self] in
            let artifacts = ArtifactScanner.scan(projectFolder: folderPath)
            let scannedAt = Date()

            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(projectID)
                self.scans[projectID] = ProjectScan(scannedAt: scannedAt, artifacts: artifacts)
                self.save()
                self.notifyChanged()
                let bytes = artifacts.reduce(Int64(0)) { $0 + $1.byteCount }
                let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                ThreadingLogger.storage.debug(
                    "Artifact scan completed project=\(projectID.uuidString, privacy: .public) artifacts=\(artifacts.count, privacy: .public) bytes=\(bytes, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
                )
            }
        }
    }

    /// Rescans the scratch scope: the locations agents build in when they are not building in a
    /// project.
    ///
    /// **Declines while any session in any project is working**, unless forced — a broader rule
    /// than the per-project one, and deliberately so. A scratch root is tied to no project:
    /// `/private/tmp` is where every session's scratchpad lives, so an agent mid-build *anywhere*
    /// may be writing into the very tree this walk is about to measure. Asking "is this
    /// project busy" would answer about the wrong disk.
    func refreshScratch(force: Bool = false) {
        guard !isScratchInFlight else { return }
        guard force || !isAnySessionWorking() else { return }

        isScratchInFlight = true
        notifyChanged()

        let roots = scratchRoots
        // Taken here rather than inside the walk: session state lives on the main actor, and the
        // census is a fact about the moment the scan starts, not something to sample repeatedly
        // from a background queue while directories are being measured.
        let dormantSessionIDs = DormantSessionCensus.dormant(in: projectsProvider())
        let startedAt = Date()
        ThreadingLogger.storage.debug(
            "Scratch scan started roots=\(roots.count, privacy: .public) dormant_sessions=\(dormantSessionIDs.count, privacy: .public) forced=\(force, privacy: .public)"
        )

        queue.async { [weak self] in
            let artifacts = ArtifactScanner.scanScratch(
                roots: roots,
                dormantSessionIDs: dormantSessionIDs
            )
            let scannedAt = Date()

            Task { @MainActor in
                guard let self else { return }
                self.isScratchInFlight = false
                self.scratchScan = ProjectScan(scannedAt: scannedAt, artifacts: artifacts)
                self.saveScratch()
                self.notifyChanged()
                let bytes = artifacts.reduce(Int64(0)) { $0 + $1.byteCount }
                let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                ThreadingLogger.storage.debug(
                    "Scratch scan completed artifacts=\(artifacts.count, privacy: .public) bytes=\(bytes, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
                )
            }
        }
    }

    /// Files one vetted finding into the cache the listing and the proposal gate both read.
    ///
    /// This is what makes an agent's suggestion actionable. `StorageCleanupGate` refuses any path
    /// that is not already in the findings, and that rule is not relaxed — so a nominated
    /// directory becomes proposable by *entering the findings*, through the same gates a walk
    /// applies, rather than by being waved past the one that guards deletion.
    ///
    /// It goes to the scope it belongs to. A finding inside a scratch root joins the scratch
    /// reading; one inside a project joins that project's. A finding in neither is refused: the
    /// page groups by checkout and by scratch root, and a row belonging to nothing would have
    /// nowhere to draw and no heading to sit under.
    @discardableResult
    func adopt(_ artifact: ReclaimableArtifact) -> Bool {
        let path = artifact.url.standardizedFileURL.path

        if ArtifactScanner.isWithinScratchRoots(artifact.url, roots: scratchRoots) {
            var scan = scratchScan ?? ProjectScan(scannedAt: Date(), artifacts: [])
            guard !scan.artifacts.contains(where: { $0.url.standardizedFileURL.path == path }) else {
                return true
            }
            scan.artifacts.append(artifact)
            scratchScan = scan
            saveScratch()
            notifyChanged()
            return true
        }

        let owner = projectsProvider().first {
            path == $0.folderPath || path.hasPrefix($0.folderPath + "/")
        }
        guard let owner else { return false }

        var scan = scans[owner.id] ?? ProjectScan(scannedAt: Date(), artifacts: [])
        guard !scan.artifacts.contains(where: { $0.url.standardizedFileURL.path == path }) else {
            return true
        }
        scan.artifacts.append(artifact)
        scans[owner.id] = scan
        save()
        notifyChanged()
        return true
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

    /// The same, for the scratch scope. Re-walking `/private/tmp` to learn what a delete just
    /// did to it would be the most expensive way to find out.
    func forgetScratch(_ removed: [ReclaimableArtifact]) {
        guard var scan = scratchScan else { return }

        let paths = Set(removed.map(\.url.path))
        scan.artifacts.removeAll { paths.contains($0.url.path) }
        scratchScan = scan

        saveScratch()
        notifyChanged()
    }

    private func isWorking(_ project: Project) -> Bool {
        Self.isWorking(project.sessions)
    }

    /// Whether any session anywhere is working, which is the scratch scope's busy rule — asked
    /// of the same project list the passive sweep walks, so the two cannot disagree about what
    /// exists.
    private func isAnySessionWorking() -> Bool {
        if let scratchBusyOverride { return scratchBusyOverride() }
        return projectsProvider().contains { Self.isWorking($0.sessions) }
    }

    /// The one question both busy rules ask, kept in one place because they differ only in which
    /// sessions they hand it: a project's own, or every session there is.
    private static func isWorking(_ sessions: [AgentSession]) -> Bool {
        sessions.contains { AgentRuntime.shared.activity(sessionID: $0.id) == .working }
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

    /// The scratch reading's own file, for the reason the second store exists at all: the
    /// projects' file is a dictionary keyed by `ProjectID`, and a finding belonging to no
    /// project has no key to be filed under.
    private func saveScratch() {
        _ = scratchPersistence.save(scratchScan)
    }
}

// MARK: - Artifact Scan Defaults

enum ArtifactScanDefaults {
    static let fileName = "storage-scan.json"

    /// The scratch scope's reading, kept beside the projects' rather than inside it: that file's
    /// value is `[ProjectID: ProjectScan]`, and changing its shape would break the decode of the
    /// cache the Storage page draws before it has scanned anything. A second file migrates
    /// nothing.
    static let scratchFileName = "storage-scratch-scan.json"

    /// Long enough that launch is over and the first agent has settled.
    static let firstPassDelay: TimeInterval = 90

    /// How often the passive pass looks for something stale. Build output does not change
    /// quickly enough to be worth chasing, and the page can always be told to rescan.
    static let passiveInterval: TimeInterval = 15 * 60
    static let passiveTolerance: TimeInterval = 60

    /// When a reading stops being worth showing without checking again.
    static let staleAfter: TimeInterval = 60 * 60
}
