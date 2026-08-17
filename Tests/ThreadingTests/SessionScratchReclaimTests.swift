import XCTest
@testable import Threading

/// The session-scratch gate: what `scanScratch` offers once it is told which sessions are
/// finished, and what it still refuses.
///
/// The measurement behind it, on 2026-08-17: `/private/tmp/claude-501` held 97 GB across 3,873
/// session directories, 3,861 of them belonging to sessions that no longer existed. The scan
/// reported only the Xcode caches *inside* them, which was a fraction of the space.
final class SessionScratchReclaimTests: XCTestCase {

    private var scratch: URL!
    private var sessionID: SessionID!
    private var sessionDirectory: URL!

    private enum Fixture {
        static let namespace = "claude-501"
        static let slug = "-Users-david-repo-AnotherTerminal"
        static let derivedDataName = "dd"
        static let requiredDirectories = ["Build", "ModuleCache.noindex"]
        static let payloadBytes = 4096
    }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-session-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        sessionID = SessionID()
        sessionDirectory = scratch
            .appendingPathComponent(Fixture.namespace, isDirectory: true)
            .appendingPathComponent(Fixture.slug, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)

        // A build cache inside it, so every test can say whether the session directory is being
        // offered as one answer or being walked for the things within it.
        try makeDerivedData(in: sessionDirectory.appendingPathComponent(Fixture.derivedDataName))
    }

    override func tearDownWithError() throws {
        if let scratch, FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
    }

    // MARK: - Fixtures

    private func makeDerivedData(in url: URL) throws {
        for name in Fixture.requiredDirectories {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }

        let manifest: [String: Any] = ["WorkspacePath": "/repo/App.xcodeproj"]
        try PropertyListSerialization
            .data(fromPropertyList: manifest, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("info.plist"))

        try Data(repeating: 0x41, count: Fixture.payloadBytes)
            .write(to: url.appendingPathComponent("Build/payload.bin"))
    }

    private func artifact() throws -> ReclaimableArtifact {
        ReclaimableArtifact(
            url: sessionDirectory,
            kind: .agentSessionScratch,
            byteCount: 1,
            modifiedAt: Date(),
            checkoutPath: scratch.path
        )
    }

    // MARK: - What the census unlocks

    /// The whole directory is one answer, and the walk stops at the top of it: the build cache
    /// inside is not a second finding when the tree containing it is going.
    func testOffersADormantSessionsDirectoryAsOneFinding() throws {
        let found = ArtifactScanner.scanScratch(
            roots: [scratch],
            dormantSessionIDs: [sessionID]
        )

        XCTAssertEqual(found.count, 1)
        let only = try XCTUnwrap(found.first)
        XCTAssertEqual(only.kind, .agentSessionScratch)
        XCTAssertEqual(only.url.lastPathComponent, sessionID.uuidString.lowercased())
        XCTAssertGreaterThan(only.byteCount, 0)
        XCTAssertEqual(only.checkoutPath, scratch.path)
    }

    // MARK: - What it refuses

    /// **The default, and the direction the whole gate leans.** A caller that names no dormant
    /// session has not proved any session is finished, so nothing is offered — the behaviour
    /// before this feature existed. The build cache inside is still found, because a session
    /// directory this code cannot vouch for is walked exactly as it always was.
    func testOffersNoSessionDirectoryWhenTheCensusIsEmpty() throws {
        let found = ArtifactScanner.scanScratch(roots: [scratch])

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.kind, .xcodeDerivedData)
        XCTAssertEqual(found.first?.url.lastPathComponent, Fixture.derivedDataName)
    }

    /// A running session keeps its directory and still gets its build cache offered. Withholding
    /// both would make a busy machine's largest reclaimable trees invisible; offering the
    /// directory would delete the work in progress.
    func testALiveSessionKeepsItsDirectoryButStillOffersItsBuildCache() throws {
        let somebodyElse = SessionID()

        let found = ArtifactScanner.scanScratch(
            roots: [scratch],
            dormantSessionIDs: [somebodyElse]
        )

        XCTAssertEqual(found.map(\.kind), [.xcodeDerivedData])
    }

    /// `/tmp/claude-501/…` is minted by Claude Code, not by Threading, so a `claude` started by
    /// hand in a terminal leaves a directory of exactly this shape belonging to a session this app
    /// has never heard of. Absent from the census means refused, never assumed dead.
    func testASessionThreadingHasNeverHeardOfIsRefused() throws {
        let unknown = ArtifactScanner.scanScratch(
            roots: [scratch],
            dormantSessionIDs: [SessionID(), SessionID()]
        )

        XCTAssertFalse(unknown.contains { $0.kind == .agentSessionScratch })
    }

    // MARK: - The delete gate

    func testRefusesToRemoveASessionDirectoryWithoutACensus() throws {
        let artifact = try artifact()

        XCTAssertFalse(ArtifactScanner.isSafeToRemove(artifact, roots: [scratch]))
        XCTAssertFalse(ArtifactScanner.remove(artifact, roots: [scratch]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    func testRemovesASessionDirectoryTheCensusNamesDormant() throws {
        let artifact = try artifact()

        XCTAssertTrue(ArtifactScanner.isSafeToRemove(
            artifact,
            dormantSessionIDs: [sessionID],
            roots: [scratch]
        ))
        XCTAssertTrue(ArtifactScanner.remove(
            artifact,
            dormantSessionIDs: [sessionID],
            roots: [scratch]
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    /// **What the first run of this class caught.** The fixture nests its `claude-501` under a
    /// per-test directory, so against the *real* scratch roots the session directory sits four
    /// components deep, not three — and the gate refused it. That is the rule working: depth is
    /// exact, so a `claude-501/<slug>/<id>` buried somewhere inside a scratch root is not a
    /// session directory this tool will touch. The tests inject their root; production does not.
    func testDepthIsExactAgainstTheRealScratchRoots() throws {
        let artifact = try artifact()

        XCTAssertTrue(ArtifactScanner.isSafeToRemove(
            artifact,
            dormantSessionIDs: [sessionID],
            roots: [scratch]
        ))
        XCTAssertFalse(
            ArtifactScanner.isSafeToRemove(artifact, dormantSessionIDs: [sessionID]),
            "one component deeper than the layout allows must not be reclaimable"
        )
    }

    /// **The staleness case this gate exists for.** A listing being read is a listing going
    /// stale, and the specific failure is deleting the working directory of an agent that woke
    /// up while the sheet was on screen. The census is asked again at the moment of removal, so
    /// a session that came back refuses the delete it was already approved for.
    func testRefusesADirectoryWhoseSessionWokeUpAfterTheListing() throws {
        let artifact = try artifact()
        XCTAssertTrue(ArtifactScanner.isSafeToRemove(
            artifact,
            dormantSessionIDs: [sessionID],
            roots: [scratch]
        ))

        // The session resumed: it is no longer in the census.
        XCTAssertEqual(
            ArtifactScanner.removeWithOutcome(
                artifact,
                dormantSessionIDs: [],
                roots: [scratch]
            ),
            .refused
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    /// Containment is `SessionScratchLayout.read`'s own precondition, so a correctly shaped path
    /// somewhere else never reaches the census at all.
    func testRefusesACorrectlyShapedPathOutsideAnyScratchRoot() throws {
        XCTAssertFalse(ArtifactScanner.isDisposableSessionScratch(
            sessionDirectory,
            dormantSessionIDs: [sessionID],
            roots: [FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere")]
        ))
    }

    /// The kind routes to its own gate and to no other. A session directory must never be waved
    /// through on a manifest, and the tree here carries one at its own top level only.
    func testASessionDirectoryIsNotAcceptedByTheManifestGate() throws {
        XCTAssertEqual(ArtifactKind.agentSessionScratch.gating, .session)
        XCTAssertFalse(ArtifactScanner.isDisposableScratch(
            sessionDirectory,
            kind: .agentSessionScratch,
            roots: [scratch]
        ))
    }

    /// It is recognised by shape, so the name-first recognizer must stay blind to it — the same
    /// contract `kind(for:)` keeps for DerivedData.
    func testNameFirstRecognitionNeverAnswersASessionDirectory() {
        XCTAssertNil(ArtifactKind.kind(for: sessionDirectory))
        XCTAssertFalse(ArtifactKind.nameGated.contains(.agentSessionScratch))
    }
}
