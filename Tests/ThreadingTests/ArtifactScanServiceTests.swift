import XCTest
@testable import Threading

/// The scratch scope beside the per-project scans.
///
/// It is a second reading in a second file with a broader busy rule, and each of those three is
/// here because getting it wrong is invisible: a shared file breaks the decode of the cache the
/// page draws before it has scanned anything, a per-project busy rule asks about the wrong disk,
/// and a cached `/tmp` reading is stale in a way a project's is not.
@MainActor
final class ArtifactScanServiceTests: XCTestCase {

    // MARK: - Fixtures

    /// Where the two store files land. Never the real Application Support directory: these tests
    /// are hosted in the app, and a reading written here would be one the app read back.
    ///
    /// `nonisolated(unsafe)` because `setUpWithError` overrides a nonisolated hook while the case
    /// itself is main-actor: XCTest calls both on the main thread for a synchronous case, and the
    /// annotation says so rather than leaving the compiler to assume otherwise.
    private nonisolated(unsafe) var directory: URL!

    /// A stand-in scratch root, handed to the service instead of `/private/tmp`.
    private nonisolated(unsafe) var scratch: URL!

    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    private enum Fixture {
        /// Generous: the walk is a handful of fixture directories, and the wait exists to catch a
        /// publication that never comes rather than to time one.
        static let scanTimeout: TimeInterval = 10
        static let payloadBytes = 4096
    }

    /// Xcode's contract, spelled out here rather than read from `ScratchDefaults`: a test that
    /// took these names from the code under test would agree with any change to it.
    private enum Manifest {
        static let fileName = "info.plist"
        static let workspaceKey = "WorkspacePath"
        static let requiredDirectories = ["Build", "ModuleCache.noindex"]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-scan-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-scan-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    /// A service with every outside answer stated: the fixture root instead of the machine's
    /// temporary directories, no projects instead of the developer's own, and a busy answer
    /// instead of an agent.
    private func makeService(busy: Bool = false) -> ArtifactScanService {
        ArtifactScanService(
            directory: directory,
            fileManager: .default,
            scratchRoots: [scratch],
            projects: { [] },
            isAnySessionWorking: { busy }
        )
    }

    /// A directory shaped the way Xcode writes DerivedData: `info.plist` naming a workspace, with
    /// `Build/` and `ModuleCache.noindex/` beside it. That shape is the whole reason a tree
    /// outside any repository can be offered at all.
    @discardableResult
    private func derivedData(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        for directoryName in Manifest.requiredDirectories {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(directoryName),
                withIntermediateDirectories: true
            )
        }
        try String(repeating: "x", count: Fixture.payloadBytes).write(
            to: url.appendingPathComponent("Build/Products.o"),
            atomically: true,
            encoding: .utf8
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: [Manifest.workspaceKey: "\(url.path)/App.xcodeproj"],
            format: .xml,
            options: 0
        )
        try data.write(to: url.appendingPathComponent(Manifest.fileName))
        return url
    }

    /// One spelling for the two names of a directory.
    ///
    /// The per-user temporary directory is `/var/folders/…`, and `/var` is a symlink to
    /// `/private/var`: a fixture URL says the short spelling while the walk hands back the long
    /// one, and the two must not read as two places — the same normalisation the scanner's own
    /// containment gate applies.
    private func normalized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// The publication the Storage page listens to, as something a test can wait on.
    ///
    /// The service hands its walk to a background queue and publishes back on the main actor, so
    /// this notification — with the scan no longer in flight — is the only honest signal that the
    /// reading has landed. A start is announced through the same event, which is why the guard
    /// asks `isScanning` rather than counting.
    private func publication(from service: ArtifactScanService) -> XCTestExpectation {
        let published = expectation(description: "scratch scan published")
        published.assertForOverFulfill = false
        observers.append(NotificationCenter.default.observe(ArtifactScanDidChange.self) { _ in
            guard !service.isScanning else { return }
            published.fulfill()
        })
        return published
    }

    /// Writes a reading straight into the scratch store so the staleness rule can be asked about
    /// an hour-old one without waiting an hour for it.
    private func seedScratchScan(scannedAt: Date) {
        let store = RecoverableFileStore<ArtifactScanService.ProjectScan?>(
            url: directory.appendingPathComponent(ArtifactScanDefaults.scratchFileName),
            fileManager: .default,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        _ = store.save(ArtifactScanService.ProjectScan(scannedAt: scannedAt, artifacts: []))
    }

    // MARK: - Persistence

    /// The reading survives the process, which is the entire point of caching it: finding these
    /// directories means walking every other one first, and a page that opens empty every launch
    /// is a page nobody reads.
    func testAScratchReadingIsReadBackByTheNextInstance() throws {
        let tree = try derivedData("dd")

        let service = makeService()
        let published = publication(from: service)
        service.refreshScratch(force: true)
        wait(for: [published], timeout: Fixture.scanTimeout)

        let scannedAt = try XCTUnwrap(service.scratchScannedAt())
        XCTAssertEqual(service.scratchArtifacts().map { normalized($0.url) }, [normalized(tree)])

        let reopened = makeService()
        XCTAssertEqual(reopened.scratchArtifacts().map { normalized($0.url) }, [normalized(tree)])
        XCTAssertEqual(
            try XCTUnwrap(reopened.scratchScannedAt()).timeIntervalSince1970,
            scannedAt.timeIntervalSince1970,
            accuracy: 1
        )
    }

    /// And it lands in a file of its own. The projects' store is keyed by `ProjectID`; a finding
    /// belonging to no project has no key to be filed under, and widening that value's shape
    /// would break the decode of the cache the page draws on first paint.
    func testTheScratchReadingIsKeptOutsideTheProjectsFile() throws {
        try derivedData("dd")

        let service = makeService()
        let published = publication(from: service)
        service.refreshScratch(force: true)
        wait(for: [published], timeout: Fixture.scanTimeout)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(ArtifactScanDefaults.scratchFileName).path
        ))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(ArtifactScanDefaults.fileName).path
            ),
            "no project was scanned, so the keyed file has nothing to say"
        )
        XCTAssertNotEqual(ArtifactScanDefaults.scratchFileName, ArtifactScanDefaults.fileName)
    }

    // MARK: - Volatility

    /// A scratch root is far more volatile than a project: during the measurement behind this
    /// feature one directory under `/private/tmp` fell from 21 GB to 92 KB with nobody asking.
    /// So a finding whose directory has gone stops being listed at once, and learning that costs
    /// a stat rather than another walk of `/tmp`.
    func testAVanishedDirectoryDropsOutWithoutARescan() throws {
        let tree = try derivedData("dd")

        let service = makeService()
        let published = publication(from: service)
        service.refreshScratch(force: true)
        wait(for: [published], timeout: Fixture.scanTimeout)

        let scannedAt = try XCTUnwrap(service.scratchScannedAt())
        XCTAssertEqual(service.scratchArtifacts().count, 1)

        try FileManager.default.removeItem(at: tree)

        XCTAssertTrue(service.scratchArtifacts().isEmpty)
        XCTAssertEqual(service.scratchScannedAt(), scannedAt, "nothing was re-walked to find that out")
        XCTAssertFalse(service.isScanning)
    }

    // MARK: - The Busy Rule

    /// The busy rule for the scratch scope is the broad one, and deliberately: `/private/tmp` is
    /// where every session's scratchpad lives, so an agent building anywhere may be building
    /// right inside the tree this walk is about to measure.
    func testABusySessionAnywhereDefersTheScratchWalk() throws {
        try derivedData("dd")

        let service = makeService(busy: true)
        service.refreshScratch()

        XCTAssertFalse(service.isScanning, "a working session anywhere is enough to wait")
        XCTAssertNil(service.scratchScannedAt())
    }

    /// Forcing is the Rescan button: the user asked for the disk to be read now, and the busy
    /// rule is a courtesy rather than a gate.
    func testForcingWalksThroughTheBusyRule() throws {
        try derivedData("dd")

        let service = makeService(busy: true)
        let published = publication(from: service)
        service.refreshScratch(force: true)

        XCTAssertTrue(service.isScanning)
        wait(for: [published], timeout: Fixture.scanTimeout)
        XCTAssertEqual(service.scratchArtifacts().count, 1)
    }

    func testAnUnforcedWalkRunsWhenNothingIsWorking() throws {
        try derivedData("dd")

        let service = makeService(busy: false)
        let published = publication(from: service)
        service.refreshScratch()

        XCTAssertTrue(service.isScanning)
        wait(for: [published], timeout: Fixture.scanTimeout)
        XCTAssertEqual(service.scratchArtifacts().count, 1)
    }

    /// One walk of the roots at a time. A passive pass and a Rescan arriving together is the
    /// ordinary case, and the roots are the one place where doing it twice is expensive.
    func testASecondRequestDoesNotStartASecondWalk() throws {
        try derivedData("dd")

        let service = makeService()
        let published = publication(from: service)
        service.refreshScratch(force: true)
        XCTAssertTrue(service.isScanning)

        service.refreshScratch(force: true)

        wait(for: [published], timeout: Fixture.scanTimeout)
        XCTAssertEqual(service.scratchArtifacts().count, 1)
    }

    // MARK: - The Passive Sweep

    /// The scratch scope rides the projects' timer rather than one of its own, which is what
    /// gives it the launch-deferred first pass for free.
    func testThePassiveSweepMeasuresAScopeItHasNeverMeasured() throws {
        try derivedData("dd")

        let service = makeService()
        let published = publication(from: service)
        service.refreshStaleProjects()

        XCTAssertTrue(service.isScanning, "a scope never measured is stale by definition")
        wait(for: [published], timeout: Fixture.scanTimeout)
        XCTAssertEqual(service.scratchArtifacts().count, 1)
    }

    func testThePassiveSweepRetakesAStaleScratchReading() throws {
        try derivedData("dd")
        seedScratchScan(scannedAt: Date().addingTimeInterval(-ArtifactScanDefaults.staleAfter - 60))

        let service = makeService()
        XCTAssertNotNil(service.scratchScannedAt(), "the seeded reading was read back")

        let published = publication(from: service)
        service.refreshStaleProjects()

        XCTAssertTrue(service.isScanning)
        wait(for: [published], timeout: Fixture.scanTimeout)
        XCTAssertEqual(service.scratchArtifacts().count, 1)
    }

    /// And leaves a fresh one alone. The timer fires every fifteen minutes; walking the roots on
    /// each of those would be a chore competing with the work the user cares about.
    func testThePassiveSweepLeavesAFreshScratchReadingAlone() throws {
        try derivedData("dd")
        let seeded = Date()
        seedScratchScan(scannedAt: seeded)

        let service = makeService()
        service.refreshStaleProjects()

        XCTAssertFalse(service.isScanning)
        XCTAssertEqual(
            try XCTUnwrap(service.scratchScannedAt()).timeIntervalSince1970,
            seeded.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertTrue(service.scratchArtifacts().isEmpty, "the fresh reading stands as it was")
    }

    // MARK: - Forgetting

    /// A delete changes the page immediately, and re-walking `/private/tmp` to learn what it did
    /// would be the most expensive way to find out.
    func testForgettingDropsExactlyWhatWasNamedAndKeepsIt() throws {
        let kept = try derivedData("keep-dd")
        let dropped = try derivedData("gone-dd")

        let service = makeService()
        let published = publication(from: service)
        service.refreshScratch(force: true)
        wait(for: [published], timeout: Fixture.scanTimeout)

        XCTAssertEqual(
            Set(service.scratchArtifacts().map { normalized($0.url) }),
            [normalized(kept), normalized(dropped)]
        )

        let doomed = try XCTUnwrap(
            service.scratchArtifacts().first { normalized($0.url) == normalized(dropped) }
        )
        service.forgetScratch([doomed])

        XCTAssertEqual(service.scratchArtifacts().map { normalized($0.url) }, [normalized(kept)])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dropped.path),
            "forgetting is about the reading, not the disk"
        )

        let reopened = makeService()
        XCTAssertEqual(reopened.scratchArtifacts().map { normalized($0.url) }, [normalized(kept)])
    }
}
