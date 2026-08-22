import XCTest
@testable import Threading

/// The boundary that makes handing a broken conversation to an agent safe.
///
/// The agent is given a copy and told the copy is the deliverable. That is a *prompt*, and a
/// prompt is a hope. What makes it true is here: the only file the agent's answer can name is
/// one inside the folder Threading prepared, the swap is Threading's, and the displaced original
/// is kept. These tests are that guarantee, so nobody later relaxes the path check on the
/// grounds that the prompt already asked nicely.
final class LaunchRecoveryWorkspaceTests: XCTestCase {

    // MARK: - Fixtures

    private var root: URL!
    private var provider: URL!
    private var workspace: LaunchRecoveryWorkspace!
    private let sessionID = SessionID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("repairs", isDirectory: true)
        provider = base.appendingPathComponent("provider", isDirectory: true)
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        workspace = LaunchRecoveryWorkspace(root: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try super.tearDownWithError()
    }

    /// A rollout in the shape that fails: numbered, then not.
    @discardableResult
    private func brokenRollout(named name: String = "rollout.jsonl") throws -> URL {
        let url = provider.appendingPathComponent(name)
        try """
        {"timestamp":"t","ordinal":0,"type":"session_meta","payload":{}}
        {"timestamp":"t","ordinal":1,"type":"event_msg","payload":{}}
        {"timestamp":"t","type":"turn_context","payload":{}}
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func repair(_ copy: URL) throws {
        try """
        {"timestamp":"t","ordinal":0,"type":"session_meta","payload":{}}
        {"timestamp":"t","ordinal":1,"type":"event_msg","payload":{}}
        {"timestamp":"t","ordinal":2,"type":"turn_context","payload":{}}
        """.write(to: copy, atomically: true, encoding: .utf8)
    }

    // MARK: - Preparing

    func testTheAgentIsGivenACopyAndTheOriginalIsUntouched() throws {
        let original = try brokenRollout()
        let before = try Data(contentsOf: original)

        let copy = try workspace.prepare(original: original, for: sessionID)

        XCTAssertNotEqual(copy.path, original.path)
        XCTAssertTrue(copy.path.hasPrefix(root.path), "the copy lives in Threading's own folder")
        XCTAssertEqual(try Data(contentsOf: copy), before)
        XCTAssertEqual(try Data(contentsOf: original), before)
    }

    func testASecondAttemptDoesNotInheritTheFirstOnesLeftovers() throws {
        let original = try brokenRollout()
        let first = try workspace.prepare(original: original, for: sessionID)
        let stray = first.deletingLastPathComponent().appendingPathComponent("half-done.jsonl")
        try "leftover".write(to: stray, atomically: true, encoding: .utf8)

        _ = try workspace.prepare(original: original, for: sessionID)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stray.path),
            "a retry must not hand the agent a folder of half-repaired files"
        )
    }

    func testPreparingRefusesWhenTheConversationFileHasGone() throws {
        let absent = provider.appendingPathComponent("not-there.jsonl")

        XCTAssertThrowsError(try workspace.prepare(original: absent, for: sessionID))
    }

    // MARK: - Verifying

    func testAFileOutsideTheWorkingFolderIsRefused() throws {
        // The load-bearing one. An agent naming any other path — however plausible, however
        // confidently — is answered with a refusal rather than a copy.
        let original = try brokenRollout()
        _ = try workspace.prepare(original: original, for: sessionID)

        XCTAssertThrowsError(
            try workspace.verify(repaired: original, for: sessionID, kind: .codex)
        ) { error in
            XCTAssertEqual(
                error as? LaunchRecoveryWorkspace.Failure,
                .repairedFileOutsideWorkspace
            )
        }
    }

    func testAnotherSessionsRepairFolderIsAlsoOutsideThisOne() throws {
        let original = try brokenRollout()
        _ = try workspace.prepare(original: original, for: sessionID)
        let other = SessionID()
        let elsewhere = try workspace.prepare(original: original, for: other)

        XCTAssertThrowsError(
            try workspace.verify(repaired: elsewhere, for: sessionID, kind: .codex)
        )
    }

    func testAClaimedRepairThatIsStillBrokenIsRefused() throws {
        // The agent's own verdict is not taken on trust: the file must now pass the same check
        // that condemned the original.
        let original = try brokenRollout()
        let copy = try workspace.prepare(original: original, for: sessionID)

        XCTAssertThrowsError(
            try workspace.verify(repaired: copy, for: sessionID, kind: .codex)
        ) { error in
            guard case .repairedFileStillUnusable = error as? LaunchRecoveryWorkspace.Failure
            else { return XCTFail("expected the structural check to refuse it") }
        }
    }

    func testARealRepairPassesVerification() throws {
        let original = try brokenRollout()
        let copy = try workspace.prepare(original: original, for: sessionID)
        try repair(copy)

        XCTAssertNoThrow(try workspace.verify(repaired: copy, for: sessionID, kind: .codex))
    }

    // MARK: - Accepting

    func testAcceptingPutsTheRepairInPlaceAndKeepsWhatItDisplaced() throws {
        let original = try brokenRollout()
        let originalBytes = try Data(contentsOf: original)
        let copy = try workspace.prepare(original: original, for: sessionID)
        try repair(copy)
        let repairedBytes = try Data(contentsOf: copy)

        let backup = try workspace.accept(
            repaired: copy,
            replacing: original,
            for: sessionID
        )

        XCTAssertEqual(try Data(contentsOf: original), repairedBytes)
        XCTAssertEqual(try Data(contentsOf: backup), originalBytes)
        XCTAssertEqual(
            TranscriptResumeHealth.verdict(for: original, kind: .codex),
            .usable,
            "the conversation the user came back for now opens"
        )
    }

    func testTheBackupStaysOutOfTheProvidersOwnDirectory() throws {
        // One write into the provider's directory, with one file. A `.backup` sibling left in
        // there is a second write into a directory whose contents are not ours to add to — and
        // one the provider's own session listing would then have to ignore.
        let original = try brokenRollout()
        let copy = try workspace.prepare(original: original, for: sessionID)
        try repair(copy)

        let backup = try workspace.accept(repaired: copy, replacing: original, for: sessionID)

        XCTAssertTrue(backup.path.hasPrefix(root.path))
        let providerFiles = try FileManager.default.contentsOfDirectory(
            atPath: provider.path
        )
        XCTAssertEqual(providerFiles, ["rollout.jsonl"])
    }

    // MARK: - Tickets

    func testTheTicketIsWhatSaysWhichConversationARepairChatMayTouch() throws {
        // The recovery agent never names its target. If this lookup can be confused, an agent
        // could propose a repair for a conversation it was never given.
        let registry = LaunchRecoveryRegistry(workspace: workspace)
        let original = try brokenRollout()
        let copy = try workspace.prepare(original: original, for: sessionID)
        let recoveryID = SessionID()

        try registry.write(LaunchRecoveryTicket(
            targetSessionID: sessionID,
            recoverySessionID: recoveryID,
            originalPath: original.path,
            workingCopyPath: copy.path,
            kind: .codex
        ))

        XCTAssertEqual(
            registry.ticket(forRecoverySession: recoveryID)?.targetSessionID,
            sessionID
        )
        XCTAssertNil(
            registry.ticket(forRecoverySession: SessionID()),
            "an ordinary chat holds no ticket and may propose nothing"
        )
    }

    func testATicketSurvivesBeingReadByAFreshRegistry() throws {
        // A repair takes as long as it takes. A conversation that spans an app restart must not
        // come back with its tool pointing at nothing.
        let original = try brokenRollout()
        let copy = try workspace.prepare(original: original, for: sessionID)
        let recoveryID = SessionID()
        try LaunchRecoveryRegistry(workspace: workspace).write(LaunchRecoveryTicket(
            targetSessionID: sessionID,
            recoverySessionID: recoveryID,
            originalPath: original.path,
            workingCopyPath: copy.path,
            kind: .codex
        ))

        let reopened = LaunchRecoveryRegistry(workspace: LaunchRecoveryWorkspace(root: root))
        XCTAssertEqual(
            reopened.ticket(forRecoverySession: recoveryID)?.workingCopyPath,
            copy.path
        )
    }

    func testTheBriefNamesTheWorkingCopyAsTheOneToEditAndTheOriginalAsReadOnly() {
        let brief = LaunchRecoveryBrief.prompt(
            conversationTitle: "ADOPTION",
            workingCopy: URL(fileURLWithPath: "/repairs/abc/rollout.jsonl"),
            original: URL(fileURLWithPath: "/Users/x/.codex/sessions/rollout.jsonl"),
            failure: SessionLaunchFailure(
                origin: .processExit,
                summary: "refused",
                detail: ["is missing an ordinal"]
            ),
            toolName: "propose_conversation_repair"
        )

        XCTAssertTrue(brief.contains("ADOPTION"))
        XCTAssertTrue(brief.contains("/repairs/abc/rollout.jsonl"))
        XCTAssertTrue(brief.contains("never write to it"))
        XCTAssertTrue(brief.contains("propose_conversation_repair"))
        XCTAssertTrue(
            brief.contains("is missing an ordinal"),
            "the agent is briefed with what the runtime actually said"
        )
    }
}
