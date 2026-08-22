import XCTest

@testable import Threading

/// The durable half of the session registry: a token that is a property of the session rather
/// than of the launch that minted it.
///
/// Every test here points the registry at a file of its own and puts it back afterwards. The
/// registry is a global by construction — a hook resolves its token from the MCP queue with no
/// session object in hand — so a synthetic restart is exactly "new file, empty map".
final class MCPSessionTokenStoreTests: XCTestCase {

    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-tokens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent(MCPBridgeDefaults.tokenFileName)
        MCPSessionRegistry.reload(from: file)
    }

    override func tearDownWithError() throws {
        // Back to the process-wide file first, so nothing this test minted outlives it in a map
        // another class will read.
        MCPSessionRegistry.reload()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        file = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// The tokens as they stand on disk, read the way a fresh launch would read them.
    private func storedTokens() throws -> [String: String] {
        MCPSessionRegistry.waitForPendingTokenWrites()
        let data = try Data(contentsOf: file)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(document["version"] as? Int, MCPBridgeDefaults.tokenFileVersion)
        return try XCTUnwrap(document["tokens"] as? [String: String])
    }

    /// Everything a restart takes with it: the in-memory maps go, the file stays.
    private func restart() {
        MCPSessionRegistry.waitForPendingTokenWrites()
        MCPSessionRegistry.reload(from: file)
    }

    // MARK: - Durability

    /// The claim the whole feature rests on. A hook that arrives after a restart — or during
    /// one, before the listener is up — routes to the session it came from, where before the
    /// token was a fresh UUID per launch and the report was dropped as unknown.
    func testATokenSurvivesARestartAndStillRoutesItsHook() throws {
        let sessionID = SessionID()
        let token = MCPSessionRegistry.token(for: sessionID)

        restart()

        XCTAssertEqual(
            MCPSessionRegistry.session(forToken: token),
            sessionID,
            "a hook posted after a restart no longer reaches its session"
        )
        XCTAssertEqual(
            MCPSessionRegistry.token(for: sessionID),
            token,
            "the session was re-minted rather than recognised"
        )
    }

    /// Resolution is the side a hook arrives on, so it has to load the file too — a report can
    /// reach the listener before anything in this launch has asked for a token.
    func testAHookResolvesBeforeAnythingInTheLaunchHasMintedAToken() throws {
        let sessionID = SessionID()
        let token = MCPSessionRegistry.token(for: sessionID)
        restart()

        // Deliberately the *first* registry call after the restart.
        XCTAssertEqual(MCPSessionRegistry.session(forToken: token), sessionID)
    }

    /// A token is rotated only by deletion, and deletion has to reach the file — otherwise a
    /// revoked endpoint comes back to life on the next launch.
    @MainActor
    func testADeletedSessionsTokenLeavesTheFile() throws {
        let retained = SessionID()
        let removed = SessionID()
        let retainedToken = MCPSessionRegistry.token(for: retained)
        let removedToken = MCPSessionRegistry.token(for: removed)

        MCPSessionRegistry.retainOnly(sessionIDs: [retained])

        let stored = try storedTokens()
        XCTAssertEqual(stored[retained.uuidString], retainedToken)
        XCTAssertNil(stored[removed.uuidString])

        restart()
        XCTAssertEqual(MCPSessionRegistry.session(forToken: retainedToken), retained)
        XCTAssertNil(
            MCPSessionRegistry.session(forToken: removedToken),
            "a deleted session came back addressable after a restart"
        )
    }

    /// `remove` is the single-session path and must prune the file the same way.
    @MainActor
    func testRemovingOneSessionPrunesTheFileWithoutTouchingTheOthers() throws {
        let kept = SessionID()
        let deleted = SessionID()
        let keptToken = MCPSessionRegistry.token(for: kept)
        _ = MCPSessionRegistry.token(for: deleted)

        MCPSessionRegistry.remove(sessionID: deleted)

        let stored = try storedTokens()
        XCTAssertEqual(stored[kept.uuidString], keptToken)
        XCTAssertNil(stored[deleted.uuidString])
    }

    /// An ad-hoc endpoint exists for the length of one helper run. Writing its token down would
    /// leave an endpoint outliving everything that could honour it.
    @MainActor
    func testAnAdHocTokenIsNeverWrittenDown() throws {
        let adHoc = MCPSessionRegistry.beginAdHoc(
            allowedTools: [MCPBuiltInTool.listSettings.rawValue]
        )
        let adHocToken = MCPSessionRegistry.token(for: adHoc)
        let ordinary = SessionID()
        let ordinaryToken = MCPSessionRegistry.token(for: ordinary)

        defer { MCPSessionRegistry.endAdHoc(adHoc) }

        let stored = try storedTokens()
        XCTAssertEqual(stored[ordinary.uuidString], ordinaryToken)
        XCTAssertNil(stored[adHoc.uuidString], "a helper run's token reached the file")
        XCTAssertFalse(stored.values.contains(adHocToken))

        restart()
        XCTAssertNil(
            MCPSessionRegistry.session(forToken: adHocToken),
            "a helper run's endpoint survived a restart"
        )
    }

    // MARK: - Unreadable State

    /// A file this build cannot read yields an empty map and fresh mints, so the launch works.
    /// It is moved aside rather than overwritten, because corrupt bytes are the only copy of
    /// whatever they were.
    func testAnUnreadableFileYieldsAnEmptyMapAndIsQuarantined() throws {
        try Data("not json\n".utf8).write(to: file)
        MCPSessionRegistry.reload(from: file)

        let sessionID = SessionID()
        let token = MCPSessionRegistry.token(for: sessionID)
        XCTAssertFalse(token.isEmpty)

        let stored = try storedTokens()
        XCTAssertEqual(stored, [sessionID.uuidString: token])

        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".unreadable-") }
        XCTAssertEqual(quarantined.count, 1, "the unreadable bytes were not preserved")
    }

    /// A version this build does not know is not corruption to interpret — it is a file to leave
    /// alone and mint past.
    func testAFileFromAnUnknownVersionIsQuarantinedRatherThanRead() throws {
        let document: [String: Any] = [
            "version": MCPBridgeDefaults.tokenFileVersion + 1,
            "tokens": [SessionID().uuidString: "from-the-future"]
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        MCPSessionRegistry.reload(from: file)

        XCTAssertNil(MCPSessionRegistry.session(forToken: "from-the-future"))
        XCTAssertTrue(
            try FileManager.default
                .contentsOfDirectory(atPath: directory.path)
                .contains { $0.contains(".unreadable-") }
        )
    }

    /// One row that cannot be parsed must not cost every other session its routing.
    func testAnUnparsableRowIsSkippedWhileTheRestStillLoad() throws {
        let sessionID = SessionID()
        let document: [String: Any] = [
            "version": MCPBridgeDefaults.tokenFileVersion,
            "tokens": [
                sessionID.uuidString: "good-token",
                "not-a-uuid": "orphan-token",
                SessionID().uuidString: ""
            ]
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        MCPSessionRegistry.reload(from: file)

        XCTAssertEqual(MCPSessionRegistry.session(forToken: "good-token"), sessionID)
        XCTAssertNil(MCPSessionRegistry.session(forToken: "orphan-token"))
    }

    // MARK: - Secrecy

    /// A persisted secret in a shared home directory. The `0700` directory is the boundary; the
    /// `0600` file is the second lock on the same door.
    func testTheFileAndItsDirectoryAreOwnerOnly() throws {
        let owned = directory.appendingPathComponent("owned", isDirectory: true)
        MCPSessionRegistry.reload(
            from: owned.appendingPathComponent(MCPBridgeDefaults.tokenFileName)
        )
        _ = MCPSessionRegistry.token(for: SessionID())
        MCPSessionRegistry.waitForPendingTokenWrites()

        let fileManager = FileManager.default
        let directoryMode = try XCTUnwrap(
            fileManager.attributesOfItem(atPath: owned.path)[.posixPermissions] as? NSNumber
        )
        let fileMode = try XCTUnwrap(
            fileManager.attributesOfItem(
                atPath: owned.appendingPathComponent(MCPBridgeDefaults.tokenFileName).path
            )[.posixPermissions] as? NSNumber
        )

        XCTAssertEqual(directoryMode.intValue, MCPBridgeDefaults.directoryPermissions)
        XCTAssertEqual(fileMode.intValue, MCPBridgeDefaults.filePermissions)
    }

    /// The redirect that keeps a hosted test out of the developer's own state. Without it, a
    /// fixture sweep here would rewrite the token file the app the developer is running reads.
    func testAHostedTestNeverAddressesTheDevelopersOwnBridgeDirectory() {
        XCTAssertTrue(StateManager.isHostedTest)
        XCTAssertEqual(
            MCPBridgeLocation.supportRoot,
            StateManager.hostedTestDirectory(),
            "the MCP bridge stopped following the hosted-test redirect"
        )
        XCTAssertFalse(
            MCPBridgeLocation.socketPath.contains(AppDataLocations.supportDirectory.path)
        )
    }
}
