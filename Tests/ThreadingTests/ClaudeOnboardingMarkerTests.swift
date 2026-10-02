import XCTest
@testable import Threading

/// The one write Threading makes into a provider-owned file. Each test is a home shaped like the
/// one `claude auth login` leaves behind (measured: `oauthAccount` present, no
/// `hasCompletedOnboarding`), so the fix is checked against what the CLI actually writes.
final class ClaudeOnboardingMarkerTests: XCTestCase {

    private var home: URL!

    private var stateFile: URL { home.appendingPathComponent(AgentDefaults.claudeStateFile) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testMarksAFreshLoginCompleteAndKeepsEverythingTheCLIWrote() throws {
        try writeState("""
        {
          "firstStartTime": "2026-10-01T19:11:52.847Z",
          "oauthAccount": {"emailAddress": "nova@example.com", "organizationUuid": "org-1"},
          "migrationVersion": 11,
          "cachedUsageUtilization": 0.37,
          "url": "https://claude.ai/settings"
        }
        """, permissions: 0o600)

        XCTAssertEqual(ClaudeOnboardingMarker.markComplete(inConfigDirectory: home.path), .marked)

        let object = try readState()
        XCTAssertEqual(object["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertEqual(object["firstStartTime"] as? String, "2026-10-01T19:11:52.847Z")
        XCTAssertEqual(object["migrationVersion"] as? Int, 11)
        XCTAssertEqual(object["cachedUsageUtilization"] as? Double, 0.37)
        XCTAssertEqual(object["url"] as? String, "https://claude.ai/settings")
        let account = try XCTUnwrap(object["oauthAccount"] as? [String: Any])
        XCTAssertEqual(account["emailAddress"] as? String, "nova@example.com")
        XCTAssertEqual(account["organizationUuid"] as? String, "org-1")
        XCTAssertEqual(object.count, 6, "Exactly one key is added")
    }

    func testKeepsTheOriginalModeRatherThanTheUmask() throws {
        try writeState(#"{"oauthAccount": {}}"#, permissions: 0o600)

        XCTAssertEqual(ClaudeOnboardingMarker.markComplete(inConfigDirectory: home.path), .marked)

        let attributes = try FileManager.default.attributesOfItem(atPath: stateFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLeavesAnAlreadyOnboardedHomeByteForByte() throws {
        let original = #"{"hasCompletedOnboarding":true,"numStartups":4}"#
        try writeState(original, permissions: 0o600)

        XCTAssertEqual(
            ClaudeOnboardingMarker.markComplete(inConfigDirectory: home.path),
            .alreadyComplete
        )
        XCTAssertEqual(try String(contentsOf: stateFile, encoding: .utf8), original)
    }

    func testSetsAFalseFlagToo() throws {
        // A reconnect after an interrupted first run, or after `/logout`, which clears the flag.
        try writeState(#"{"hasCompletedOnboarding": false}"#, permissions: 0o600)

        XCTAssertEqual(ClaudeOnboardingMarker.markComplete(inConfigDirectory: home.path), .marked)
        XCTAssertEqual(try readState()["hasCompletedOnboarding"] as? Bool, true)
    }

    func testNeverCreatesAStateFileTheLoginDidNotLeave() {
        XCTAssertEqual(
            ClaudeOnboardingMarker.markComplete(inConfigDirectory: home.path),
            .skipped(.missing)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path))
    }

    func testRefusesWhatItCannotRewriteFaithfully() throws {
        try writeState("{ not json", permissions: 0o600)
        XCTAssertEqual(
            ClaudeOnboardingMarker.markComplete(inConfigDirectory: home.path),
            .skipped(.unreadable)
        )
        XCTAssertEqual(try String(contentsOf: stateFile, encoding: .utf8), "{ not json")

        try writeState("[1, 2]", permissions: 0o600)
        XCTAssertEqual(
            ClaudeOnboardingMarker.markComplete(inConfigDirectory: home.path),
            .skipped(.notAnObject)
        )
        XCTAssertEqual(try String(contentsOf: stateFile, encoding: .utf8), "[1, 2]")
    }

    func testRefusesAnOversizedFileBeforeReadingIt() throws {
        let padding = String(repeating: " ", count: ClaudeOnboardingMarker.Defaults.maximumBytes)
        try writeState("{\"oauthAccount\": {}}" + padding, permissions: 0o600)

        XCTAssertEqual(
            ClaudeOnboardingMarker.markComplete(inConfigDirectory: home.path),
            .skipped(.tooLarge)
        )
    }

    func testDoesNotFollowASymlinkedStateFile() throws {
        let elsewhere = home.appendingPathComponent("elsewhere.json")
        try Data(#"{"oauthAccount": {}}"#.utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: stateFile, withDestinationURL: elsewhere)

        XCTAssertEqual(
            ClaudeOnboardingMarker.markComplete(inConfigDirectory: home.path),
            .skipped(.unreadable)
        )
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), #"{"oauthAccount": {}}"#)
    }

    func testStaysOutOfASaveTheCLIHasInFlight() throws {
        let original = #"{"oauthAccount": {}}"#
        try writeState(original, permissions: 0o600)
        let lock = URL(fileURLWithPath: stateFile.path + ClaudeOnboardingMarker.Defaults.lockSuffix)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)

        XCTAssertEqual(
            ClaudeOnboardingMarker.markComplete(inConfigDirectory: home.path),
            .skipped(.busy)
        )
        XCTAssertEqual(try String(contentsOf: stateFile, encoding: .utf8), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), "The CLI's lock is not ours")
    }

    func testWritesPastALockAbandonedByAnExitedCLIWithoutRemovingIt() throws {
        try writeState(#"{"oauthAccount": {}}"#, permissions: 0o600)
        let lock = URL(fileURLWithPath: stateFile.path + ClaudeOnboardingMarker.Defaults.lockSuffix)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let abandoned = Date(
            timeIntervalSinceNow: -(ClaudeOnboardingMarker.Defaults.lockStaleness * 6)
        )
        try FileManager.default.setAttributes([.modificationDate: abandoned], ofItemAtPath: lock.path)

        XCTAssertEqual(ClaudeOnboardingMarker.markComplete(inConfigDirectory: home.path), .marked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }

    func testLeavesNoTemporaryFileOrLockBehind() throws {
        try writeState(#"{"oauthAccount": {}}"#, permissions: 0o600)

        _ = ClaudeOnboardingMarker.markComplete(inConfigDirectory: home.path)

        let names = try FileManager.default.contentsOfDirectory(atPath: home.path)
        XCTAssertEqual(names, [AgentDefaults.claudeStateFile])
    }

    func testOnlyTheClaudeAdapterSettlesFirstRunState() throws {
        try writeState(#"{"oauthAccount": {}}"#, permissions: 0o600)

        AgentAccountSetupProvider.codex.settleFirstRun(inConfigDirectory: home.path)
        XCTAssertNil(try readState()["hasCompletedOnboarding"])

        AgentAccountSetupProvider.claude.settleFirstRun(inConfigDirectory: home.path)
        XCTAssertEqual(try readState()["hasCompletedOnboarding"] as? Bool, true)
    }

    // MARK: - Helpers

    private func writeState(_ text: String, permissions: Int) throws {
        try? FileManager.default.removeItem(at: stateFile)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: stateFile.path,
            contents: Data(text.utf8),
            attributes: [.posixPermissions: permissions]
        ))
    }

    private func readState() throws -> [String: Any] {
        let data = try Data(contentsOf: stateFile)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
