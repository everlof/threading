import XCTest
@testable import Threading

/// `ArtifactScanner.vet` — the gate behind `suggest_reclaimable_location`.
///
/// The property worth defending is that vetting adds **no authority**: it answers exactly what a
/// walk would have answered on reaching the same directory, and the tool built on it widens only
/// *when* a path can be found, never *what* counts as safe. So most of this class is refusals.
final class ArtifactVettingTests: XCTestCase {

    private var scratch: URL!
    private var repository: URL!

    private enum Fixture {
        static let namespace = "claude-501"
        static let slug = "-Users-david-repo-AnotherTerminal"
        static let requiredDirectories = ["Build", "ModuleCache.noindex"]
        static let payloadBytes = 2048
    }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-vet-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-vet-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in [scratch, repository].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Fixtures

    @discardableResult
    private func git(_ arguments: String...) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repository.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func makeDirectory(_ url: URL, withPayload: Bool = true) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if withPayload {
            try Data(repeating: 0x41, count: Fixture.payloadBytes)
                .write(to: url.appendingPathComponent("payload.bin"))
        }
    }

    private func makeDerivedData(at url: URL) throws {
        for name in Fixture.requiredDirectories {
            try makeDirectory(url.appendingPathComponent(name), withPayload: false)
        }
        try PropertyListSerialization
            .data(fromPropertyList: ["WorkspacePath": "/repo/App.xcodeproj"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("info.plist"))
        try Data(repeating: 0x41, count: Fixture.payloadBytes)
            .write(to: url.appendingPathComponent("Build/payload.bin"))
    }

    private func sessionDirectory(for id: SessionID) -> URL {
        scratch
            .appendingPathComponent(Fixture.namespace, isDirectory: true)
            .appendingPathComponent(Fixture.slug, isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    // MARK: - Accepted

    func testVetsADormantSessionsScratchDirectory() throws {
        let id = SessionID()
        try makeDirectory(sessionDirectory(for: id))

        let outcome = ArtifactScanner.vet(
            sessionDirectory(for: id),
            dormantSessionIDs: [id],
            roots: [scratch]
        )

        guard case .vetted(let artifact) = outcome else { return XCTFail("expected a vetting") }
        XCTAssertEqual(artifact.kind, .agentSessionScratch)
        XCTAssertGreaterThan(artifact.byteCount, 0)
    }

    func testVetsADerivedDataTreeAndKeepsItsWorkspace() throws {
        let tree = scratch.appendingPathComponent("dd")
        try makeDerivedData(at: tree)

        let outcome = ArtifactScanner.vet(tree, roots: [scratch])

        guard case .vetted(let artifact) = outcome else { return XCTFail("expected a vetting") }
        XCTAssertEqual(artifact.kind, .xcodeDerivedData)
        XCTAssertEqual(artifact.workspacePath, "/repo/App.xcodeproj")
    }

    func testVetsAnIgnoredBuildDirectoryInsideARepository() throws {
        try git("init")
        try "node_modules/\n".write(
            to: repository.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: repository.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )
        let modules = repository.appendingPathComponent("node_modules")
        try makeDirectory(modules)

        guard case .vetted(let artifact) = ArtifactScanner.vet(modules) else {
            return XCTFail("expected a vetting")
        }
        XCTAssertEqual(artifact.kind, .node)
    }

    // MARK: - Refused

    func testRefusesAPathThatIsNotThere() {
        XCTAssertEqual(
            ArtifactScanner.vet(scratch.appendingPathComponent("absent")),
            .refused(.missing)
        )
    }

    func testRefusesAFileRatherThanADirectory() throws {
        let file = scratch.appendingPathComponent("a-file")
        try Data([0x41]).write(to: file)

        XCTAssertEqual(ArtifactScanner.vet(file), .refused(.missing))
    }

    /// The session gate owns the shape once it matches, so a running session's directory is
    /// refused rather than falling through to be examined as something else.
    func testRefusesALiveSessionsScratchDirectory() throws {
        let id = SessionID()
        try makeDirectory(sessionDirectory(for: id))

        XCTAssertEqual(
            ArtifactScanner.vet(sessionDirectory(for: id), roots: [scratch]),
            .refused(.sessionNotDormant)
        )
    }

    /// **The gate that matters most.** `check-ignore` says yes to `.env.local` too, so a
    /// directory the agent nominates is never reclaimable merely because it is ignored — it must
    /// also be something a known command rebuilds.
    func testRefusesAnOrdinaryDirectoryTheAgentNominates() throws {
        try git("init")
        let secrets = repository.appendingPathComponent("secrets")
        try makeDirectory(secrets)

        XCTAssertEqual(ArtifactScanner.vet(secrets), .refused(.unrecognised))
    }

    /// A build-output name with nothing to prove it. `target` beside no `Cargo.toml` is
    /// somebody's data, and saying so is the point of the marker.
    func testRefusesABuildOutputNameWithoutItsEcosystemMarker() throws {
        let target = repository.appendingPathComponent("target")
        try makeDirectory(target)

        XCTAssertEqual(ArtifactScanner.vet(target), .refused(.unrecognised))
    }

    /// Tracked content refuses the whole directory, however it is named and whatever the agent
    /// claims about it.
    func testRefusesATrackedDirectoryThatLooksLikeBuildOutput() throws {
        try git("init")
        try git("config", "user.email", "t@example.com")
        try git("config", "user.name", "T")
        try "{}".write(
            to: repository.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )
        let modules = repository.appendingPathComponent("node_modules")
        try makeDirectory(modules)
        try git("add", "-f", "node_modules", "package.json")
        try git("commit", "-m", "tracked")

        XCTAssertEqual(ArtifactScanner.vet(modules), .refused(.notIgnoredByGit(.node)))
    }

    /// A DerivedData tree outside every scratch root is refused: the manifest alone would make
    /// this a rule about any directory anywhere holding three names.
    func testRefusesADerivedDataTreeOutsideAnyScratchRoot() throws {
        let tree = repository.appendingPathComponent("dd")
        try makeDerivedData(at: tree)

        XCTAssertEqual(ArtifactScanner.vet(tree, roots: [scratch]), .refused(.unrecognised))
    }
}
