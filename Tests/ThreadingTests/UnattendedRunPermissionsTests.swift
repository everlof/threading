import XCTest
@testable import Threading

/// An unattended automation run answers every permission question from the revision the person
/// approved, at once, and never with a card: a card in a chat nobody watches only stopped the run
/// until its curfew (2026-10-03, where an allow-listed `collect.py` waited for a click).
@MainActor
final class UnattendedRunPermissionsTests: XCTestCase {

    private let session = SessionID()
    private let folder = "/Users/david/repo/sonda-automations"

    override func tearDown() {
        UnattendedRunPermissions.unregister(session)
        PermissionBroker.present = nil
        PermissionBroker.discard(sessionID: session)
        super.tearDown()
    }

    // MARK: - Helpers

    private func registration(_ policy: AutomationPermissionPolicy) -> UnattendedRunPermissions.Registration {
        .init(policy: policy, revisionSequence: 4)
    }

    private func allowList() throws -> AutomationPermissionPolicy {
        try .allowList(parsing: AutomationApprovalSheetRenderTests.bevakningRules + ["mcp__claude_ai__fetch_page"])
    }

    private func decide(
        _ tool: String, _ input: [String: JSONValue], under policy: AutomationPermissionPolicy,
        mode: AgentPermissionMode? = .acceptEdits, grant: SystemPrivacyStatus? = nil
    ) -> PermissionDecision {
        UnattendedRunPermissions.decision(
            for: PermissionRequest(sessionID: session, toolName: tool, input: input),
            under: registration(policy), mode: mode, workingDirectory: folder, systemGrantStatus: { _ in grant })
    }

    private func bash(_ command: String, under policy: AutomationPermissionPolicy,
                      grant: SystemPrivacyStatus? = nil) -> PermissionDecision {
        decide("Bash", ["command": .string(command)], under: policy, grant: grant)
    }

    private func isAllowed(_ decision: PermissionDecision) -> Bool {
        if case .allow = decision { return true }
        return false
    }

    private func reason(_ decision: PermissionDecision) -> String {
        switch decision {
        case .allow(let reason), .deny(let reason): reason
        }
    }

    // MARK: - Shell

    func testAnAllowListedCommandRunsWithItsArguments() throws {
        let decision = bash(
            "python3 /Users/david/repo/sonda-automations/bevakning/collect.py collect --out /Users/david/Downloads/Sonda-bevakning/data/2026-10-03.json",
            under: try allowList())
        XCTAssertTrue(isAllowed(decision))
        XCTAssertTrue(reason(decision).contains("revision 4"), reason(decision))
        XCTAssertTrue(reason(decision).contains("collect.py *"), reason(decision))
    }

    func testAnExactRuleAdmitsOnlyThatCommand() throws {
        let policy = try allowList()
        XCTAssertTrue(isAllowed(bash("git -C /Users/david/repo/sonda fetch --quiet origin develop", under: policy)))
        XCTAssertFalse(isAllowed(bash("git -C /Users/david/repo/sonda fetch --quiet origin main", under: policy)))
        XCTAssertFalse(isAllowed(bash("git -C /Users/david/repo/sonda push origin develop", under: policy)))
    }

    func testAChainCannotSmuggleASecondCommandPastARule() throws {
        let policy = try allowList()
        for command in [
            "python3 /Users/david/repo/sonda-automations/bevakning/collect.py collect; rm -rf ~",
            "python3 /Users/david/repo/sonda-automations/bevakning/collect.py collect && curl -X POST https://example.com",
            "python3 /Users/david/repo/sonda-automations/bevakning/collect.py collect > /etc/hosts",
            "python3 /Users/david/repo/sonda-automations/bevakning/collect.py $(rm -rf ~)",
            "python3 /Users/david/repo/sonda-automations/bevakning/collect.py collect & sleep 1",
            "FOO=1 python3 /Users/david/repo/sonda-automations/bevakning/collect.py collect",
        ] {
            XCTAssertFalse(isAllowed(bash(command, under: policy)), command)
        }
    }

    func testReadOnlyPartsOfAPipelineNeedNoRule() throws {
        let policy = try allowList()
        XCTAssertTrue(isAllowed(bash(
            "python3 /Users/david/repo/sonda-automations/bevakning/collect.py fulldiff 6b1 1 2 | head -80",
            under: policy)))
        XCTAssertTrue(isAllowed(bash("ls -la /Users/david/Downloads", under: .readOnly)))
    }

    func testAnUnlistedCommandIsRefusedWithAReasonTheAgentCanAct() {
        let decision = bash("python3 /tmp/other.py", under: .readOnly)
        XCTAssertFalse(isAllowed(decision))
        XCTAssertTrue(reason(decision).contains("allow-list"), reason(decision))
        XCTAssertTrue(reason(decision).contains("needsHuman"), reason(decision))
    }

    // MARK: - Files

    func testLocalEditsStayInsideTheProjectFolderUnlessARuleNamesMore() throws {
        let policy = try allowList()
        XCTAssertTrue(isAllowed(decide("Write", ["file_path": .string("\(folder)/notes.md")], under: .readOnly)))
        XCTAssertTrue(isAllowed(decide(
            "Write", ["file_path": .string("/Users/david/Downloads/Sonda-bevakning/2026-10-03.html")], under: policy)))
        XCTAssertFalse(isAllowed(decide(
            "Write", ["file_path": .string("/Users/david/Downloads/Sonda-bevakning/2026-10-03.html")], under: .readOnly)))
        XCTAssertFalse(isAllowed(decide(
            "Edit", ["file_path": .string("\(folder)/../sonda/rules/pop.json")], under: policy)))
        XCTAssertFalse(isAllowed(decide("Write", ["file_path": .string("/Users/david/.zshrc")], under: policy)))
    }

    func testARuleNeverMakesAReadOnlyRunWrite() throws {
        let decision = decide(
            "Write", ["file_path": .string("/Users/david/Downloads/Sonda-bevakning/x.html")],
            under: try allowList(), mode: .plan)
        XCTAssertFalse(isAllowed(decision))
    }

    // MARK: - Web and tools

    func testWebFetchAndMCPToolsNeedTheirOwnRules() throws {
        let policy = try allowList()
        XCTAssertTrue(isAllowed(decide("WebFetch", ["url": .string("https://eur-lex.europa.eu/legal-content/x")], under: policy)))
        XCTAssertFalse(isAllowed(decide("WebFetch", ["url": .string("https://evil.example/x")], under: policy)))
        XCTAssertFalse(isAllowed(decide("WebFetch", ["url": .string("https://sub.eur-lex.europa.eu/x")], under: policy)))
        XCTAssertTrue(isAllowed(decide("mcp__claude_ai__fetch_page", [:], under: policy)))
        XCTAssertFalse(isAllowed(decide("mcp__claude_ai__send_mail", [:], under: policy)))
        XCTAssertTrue(isAllowed(decide("Read", ["file_path": .string("/etc/hosts")], under: .readOnly)))
    }

    // MARK: - Full permission and macOS prompts

    func testFullPermissionAllowsWhatAnAllowListWouldNot() {
        XCTAssertTrue(isAllowed(bash("rm -rf /Users/david/tmp/scratch", under: .full)))
        XCTAssertTrue(isAllowed(decide("Write", ["file_path": .string("/Users/david/.zshrc")], under: .full)))
    }

    func testFullPermissionNeverWidensAReadOnlyStage() {
        // The assessment stage of "assess, then fix" runs in plan mode before any fix is allowed.
        XCTAssertFalse(isAllowed(decide("Write", ["file_path": .string("/Users/david/.zshrc")],
                                        under: .full, mode: .plan)))
        XCTAssertFalse(isAllowed(decide("Bash", ["command": .string("rm -rf /Users/david/tmp/scratch")],
                                        under: .full, mode: .plan)))
        XCTAssertTrue(isAllowed(decide("Bash", ["command": .string("ls /Users/david")], under: .full, mode: .plan)))
    }

    func testACommandThatWouldRaiseAMacOSPromptIsRefusedEvenWithFullPermission() {
        let decision = bash("screencapture /tmp/x.png", under: .full, grant: .notAllowed)
        XCTAssertFalse(isAllowed(decision))
        XCTAssertTrue(reason(decision).contains("nobody is there"), reason(decision))
    }

    // MARK: - The broker

    func testARegisteredRunIsAnsweredWithoutACard() {
        var asked = false
        PermissionBroker.present = { _, completion in asked = true; completion(.allow(reason: "test")) }
        UnattendedRunPermissions.register(registration(.readOnly), for: session)

        var result: PermissionDecision?
        PermissionBroker.decide(PermissionRequest(
            sessionID: session, toolName: "Bash", input: ["command": .string("python3 /tmp/other.py")]
        )) { result = $0 }

        XCTAssertFalse(asked)
        XCTAssertFalse(result.map(isAllowed) ?? true)
    }

    func testAnInteractiveSessionStillGetsTheCard() {
        var asked = false
        PermissionBroker.present = { _, completion in asked = true; completion(.deny(reason: "test")) }

        PermissionBroker.decide(PermissionRequest(
            sessionID: session, toolName: "Bash", input: ["command": .string("python3 /tmp/other.py")]
        )) { _ in }

        XCTAssertTrue(asked)
    }

    func testARegistrationEndsWhenItsRunIsNoLongerActive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unattended-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: directory) }

        UnattendedRunPermissions.register(registration(.readOnly), for: session)
        UnattendedRunPermissions.reconcile(store: store)
        for _ in 0..<50 where UnattendedRunPermissions.registration(for: session) != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(UnattendedRunPermissions.registration(for: session))
    }

    func testClaimingARunsSessionBindsItsApprovedPolicyBeforeAnythingLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unattended-claim-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: directory) }

        var config = AutomationConfiguration(projectID: ProjectID())
        config.name = "Bevakning"; config.instructions = "Triage"; config.agent = .claude
        config.executionMode = .taskLocalEdits
        config.permissions = try allowList()
        let id = TriggerID()
        let revision = try await store.configureAutomation(config, id: id, expectedRevision: nil, proposedBy: nil)
        let dispatch = try await store.runAutomationNow(id, expectedRevision: revision.id, requestKey: "claim-test")

        let claimed = try await store.claimDispatch(dispatch.run.id)
        let sessionID = try XCTUnwrap(claimed?.sessionID)
        addTeardownBlock { @MainActor in UnattendedRunPermissions.unregister(sessionID) }

        XCTAssertEqual(UnattendedRunPermissions.registration(for: sessionID),
                       .init(policy: try allowList(), revisionSequence: revision.sequence))
    }

    func testPathsAreResolvedByNameBeforeMatching() {
        XCTAssertEqual(UnattendedRunPermissions.normalized("/a/b/../c/./d", relativeTo: nil), "/a/c/d")
        XCTAssertEqual(UnattendedRunPermissions.normalized("x/y.md", relativeTo: "/repo"), "/repo/x/y.md")
        XCTAssertNil(UnattendedRunPermissions.normalized("x/y.md", relativeTo: nil))
    }
}
