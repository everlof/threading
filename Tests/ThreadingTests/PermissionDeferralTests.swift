import XCTest
import os
@testable import Threading

/// A permission card belongs where the runtime would have asked a person, and nowhere else.
///
/// Threading's `PreToolUse` hook fires on every tool call in every mode, before the runtime's own
/// permission flow, and it used to answer every one of them as though the chat were in Manual. A
/// natively rendered Codex chat set to Auto (Approve for me) raised a card for each web fetch,
/// edit and compile — the reviewer agent the mode had chosen never saw one of them — and a Claude
/// chat in Auto was asked about everything its own classifier would have decided.
@MainActor
final class PermissionDeferralTests: HostedStoreTestCase {

    private var defaultMode: AgentPermissionMode?
    private var originalGrantStatus: ((SystemPrivacyPermission) -> SystemPrivacyStatus?)!
    private var sessions: [SessionID] = []

    override func setUp() {
        super.setUp()
        // Real user state in a hosted test: an inherited mode would decide these assertions.
        defaultMode = AppSettings.shared.defaultPermissionMode
        AppSettings.shared.defaultPermissionMode = nil
        originalGrantStatus = PermissionBroker.systemGrantStatus
        PermissionBroker.systemGrantStatus = { _ in nil }
        PermissionBroker.discardSystemGrantBriefings()
    }

    override func tearDown() {
        AppSettings.shared.defaultPermissionMode = defaultMode
        PermissionBroker.present = nil
        PermissionBroker.explainSystemGrant = nil
        PermissionBroker.systemGrantStatus = originalGrantStatus
        PermissionBroker.discardSystemGrantBriefings()
        for session in sessions {
            UnattendedRunPermissions.unregister(session)
            PermissionBroker.discard(sessionID: session)
        }
        super.tearDown()
    }

    // MARK: - The policy

    /// Auto is the mode that promises to decide for itself when to ask. Measured on Claude
    /// 2.1.296: with a hook that printed nothing, `--permission-mode auto` ran a `Write` and a
    /// `Bash` with no denials, while `manual` denied both — and each payload said which mode its
    /// process was in, as `permission_mode: "auto"` or `"default"`.
    func testClaudeReportingAutoIsLeftToItsClassifier() {
        guard case .deferToAgent = PermissionPolicy.agentDecision(
            for: .toolHook(reportedMode: "auto"), kind: .claude
        ) else {
            return XCTFail("Claude in Auto was still asked from the hook")
        }
    }

    /// A headless Claude has no prompt of its own, so outside Auto the hook is the only place a
    /// question can be asked — leaving it to the runtime would mean blocked, not decided. A
    /// payload that names no mode, or one this app cannot read, asks too.
    func testClaudeIsStillAskedFromTheHookOutsideAuto() {
        let reported: [String?] = [nil, "default", "manual", "plan", "acceptEdits", "dontAsk",
                                   "bypassPermissions", "somethingNew"]
        for mode in reported {
            XCTAssertNil(
                PermissionPolicy.agentDecision(for: .toolHook(reportedMode: mode), kind: .claude),
                "Claude reporting \(String(describing: mode)) was left to a flow that blocks"
            )
        }
    }

    /// Codex honours only a hook's `deny`, so in every mode its own approval policy decides after
    /// the hook — and asks over app-server when that policy wants a person.
    func testCodexLeavesEveryHookQuestionToItsOwnApprovals() {
        XCTAssertTrue(AgentKind.codex.supports(.runtimeOwnedApprovals))
        XCTAssertFalse(AgentKind.claude.supports(.runtimeOwnedApprovals))

        for mode in [nil, "default", "auto", "plan", "bypassPermissions"] as [String?] {
            guard case .deferToAgent = PermissionPolicy.agentDecision(
                for: .toolHook(reportedMode: mode), kind: .codex
            ) else {
                return XCTFail("Codex reporting \(String(describing: mode)) was asked from the hook")
            }
        }
    }

    /// A runtime that asked for itself has already applied its mode and decided a person should
    /// answer. Handing that back would leave nobody deciding.
    func testARuntimesOwnQuestionIsNeverLeftToTheRuntime() {
        for kind in AgentKind.allCases {
            XCTAssertNil(
                PermissionPolicy.agentDecision(for: .runtimeRequest, kind: kind),
                "\(kind)'s own request was handed back to it"
            )
        }
    }

    /// Nothing on stdout is the one reply both CLIs read as "no decision": a printed `allow`
    /// would skip Claude's classifier, and every terminal Codex already gets silence from the
    /// shared hook.
    func testADeferralPrintsNothingFromTheHook() {
        XCTAssertNil(PermissionDecision.deferToAgent(reason: "r").hookResponse)
        XCTAssertNotNil(PermissionDecision.allow(reason: "r").hookResponse)
        XCTAssertNotNil(PermissionDecision.deny(reason: "r").hookResponse)
    }

    // MARK: - Through the broker

    /// The session that started this: Codex, Auto (Approve for me), a compile from the hook.
    func testANativeCodexChatInAutoIsNotAskedFromTheHook() throws {
        let session = try makeSession(kind: .codex, mode: .auto)

        let (decision, asked) = decide(hook(
            session, reporting: "auto", tool: "Bash",
            ["command": "android/gradlew --offline -p android :app:compileDebugKotlin"]
        ))

        XCTAssertFalse(asked, "the card overruled Codex's reviewer agent")
        guard case .deferToAgent = decision else {
            return XCTFail("expected the call left to Codex, got \(String(describing: decision))")
        }
    }

    /// An app-server approval is Codex itself asking, so it still reaches the person.
    func testAnApprovalCodexRaisesItselfIsStillPutToThePerson() throws {
        let session = try makeSession(kind: .codex, mode: .auto)

        let (_, asked) = decide(PermissionRequest(
            sessionID: session,
            tool: .bash,
            input: ["command": "curl https://example.com", "cwd": "/tmp", "reason": "network"]
        ))

        XCTAssertTrue(asked, "Codex asked for a person and nobody was shown the question")
    }

    func testAClaudeChatInAutoLeavesTheHookToItsClassifier() throws {
        let session = try makeSession(kind: .claude, mode: .auto)

        let (decision, asked) = decide(hook(
            session, reporting: "auto", tool: "Write",
            ["file_path": "/tmp/notes.txt", "content": "hello"]
        ))

        XCTAssertFalse(asked)
        guard case .deferToAgent = decision else {
            return XCTFail("expected the call left to Claude, got \(String(describing: decision))")
        }
    }

    func testAClaudeChatInManualIsStillAsked() throws {
        let session = try makeSession(kind: .claude, mode: .manual)

        let (_, asked) = decide(hook(
            session, reporting: "default", tool: "Write",
            ["file_path": "/tmp/notes.txt", "content": "hello"]
        ))

        XCTAssertTrue(asked, "a headless Claude in Manual would have blocked a call nobody saw")
    }

    /// The chip moved to Auto from the sidebar, which applies at the next launch: the process is
    /// still in Manual and says so. Falling silent would have its call blocked, not decided.
    func testAClaudeChatRecordedAsAutoButRunningManualIsStillAsked() throws {
        let session = try makeSession(kind: .claude, mode: .auto)

        let (_, asked) = decide(hook(
            session, reporting: "default", tool: "Bash", ["command": "make test"]
        ))

        XCTAssertTrue(asked, "the record's Auto silenced a hook whose process was in Manual")
    }

    /// An unattended run's approved revision is Threading's own authority, and it answers before
    /// anything is left to the runtime — a refusal there must still refuse.
    func testAnAutomationRunStillRefusesBeforeTheRuntimeDecides() throws {
        let session = try makeSession(kind: .codex, mode: .auto)
        UnattendedRunPermissions.register(
            .init(policy: try .allowList(parsing: ["Bash(make test)"]), revisionSequence: 7),
            for: session
        )

        let (decision, asked) = decide(hook(
            session, reporting: "auto", tool: "Bash", ["command": "npm publish"]
        ))

        XCTAssertFalse(asked)
        guard case .deny = decision else {
            return XCTFail("the automation's allow-list was bypassed: \(String(describing: decision))")
        }
    }

    /// The macOS dialog is not the runtime's to explain, so Auto still gets the briefing first.
    func testAutoStillBriefsAMacOSPromptBeforeLeavingTheCall() throws {
        let session = try makeSession(kind: .claude, mode: .auto)
        PermissionBroker.systemGrantStatus = { _ in .notAllowed }
        var briefed = false
        PermissionBroker.explainSystemGrant = { _, _, proceed in
            briefed = true
            proceed(true)
        }

        let (decision, _) = decide(hook(
            session, reporting: "auto", tool: "Bash", ["command": "screencapture -x /tmp/a.png"]
        ))

        XCTAssertTrue(briefed, "a macOS permission dialog arrived unexplained under Auto")
        guard case .allow = decision else {
            return XCTFail("the briefed call was not let through: \(String(describing: decision))")
        }
    }

    // MARK: - End to end

    /// The real generated hook against a live listener: under Auto it prints nothing and exits 0,
    /// which both CLIs read as "no decision"; under Manual it still carries the card's answer.
    /// Asserted through `curl` and `/bin/sh` because an empty body that a hook turned into a
    /// non-zero exit, or into the absent-app deny, would be a refusal nobody chose.
    func testTheHookPrintsNothingUnderAutoAndTheAnswerOtherwise() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("thr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent(MCPBridgeDefaults.socketFileName).path

        let server = MCPServer(socketPath: socketPath)
        let started = expectation(description: "the listener settled")
        server.start { started.fulfill() }
        wait(for: [started], timeout: 10)
        defer { server.stop() }
        waitForRendezvous(server)
        XCTAssertEqual(server.socketPath, socketPath, "the rendezvous never bound")

        let session = try makeSession(kind: .claude, mode: .auto)
        let token = MCPSessionRegistry.token(for: session)
        defer { MCPSessionRegistry.remove(sessionID: session) }
        var asked = 0
        PermissionBroker.present = { _, completion in
            asked += 1
            completion(.allow(reason: "Approved by the fixture."))
        }

        let settingsPath = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: session, brokersPermissions: true, reportsLifecycle: false
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: settingsPath) }
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: settingsPath))
        ) as? [String: Any])
        let groups = try XCTUnwrap((settings["hooks"] as? [String: Any])?["PreToolUse"]
            as? [[String: Any]])
        let command = try XCTUnwrap(
            (groups.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        )
        let environment = [
            MCPDefaults.socketEnvironmentKey: socketPath,
            MCPDefaults.portEnvironmentKey: "",
            MCPDefaults.sessionTokenEnvironmentKey: token
        ]

        let auto = hookAnswer(command, payload: Self.payload(mode: "auto"), environment: environment)
        XCTAssertEqual(auto.status, 0)
        XCTAssertEqual(auto.output, "", "a deferral printed a decision of its own")
        XCTAssertEqual(asked, 0)

        let manual = hookAnswer(
            command, payload: Self.payload(mode: "default"), environment: environment
        )
        XCTAssertEqual(manual.status, 0)
        XCTAssertEqual(asked, 1, "a process in Manual was not asked about")
        let decision = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(manual.output.utf8)) as? [String: Any],
            "the answered hook printed something unparseable: \(manual.output)"
        )
        XCTAssertEqual(
            (decision["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String,
            "allow"
        )
    }

    // MARK: - Helpers

    private func makeSession(kind: AgentKind, mode: AgentPermissionMode?) throws -> SessionID {
        let store = ProjectStore.shared
        // A folder of its own: `addProject` returns the existing project for a known folder.
        let project = try XCTUnwrap(store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-permission-deferral-\(UUID().uuidString)")
        ))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: kind))
        store.setPermissionMode(mode, for: session.id)
        sessions.append(session.id)
        return session.id
    }

    private func hook(
        _ session: SessionID, reporting mode: String?, tool: String, _ input: [String: JSONValue]
    ) -> PermissionRequest {
        PermissionRequest(
            sessionID: session, toolName: tool, input: input,
            origin: .toolHook(reportedMode: mode)
        )
    }

    /// A `PreToolUse` payload in Claude's own shape, `permission_mode` included.
    private static func payload(mode: String) -> String {
        #"{"hook_event_name":"PreToolUse","permission_mode":""# + mode
            + #"","tool_name":"Bash","tool_input":{"command":"make test"}}"#
    }

    /// Waits for the rendezvous to bind, or gives up and lets the assertion say so.
    private func waitForRendezvous(_ server: MCPServer) {
        let ready = expectation(description: "the rendezvous settled")
        DispatchQueue.global().async {
            for _ in 0..<500 {
                if server.socketPath != nil { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 15)
    }

    /// Runs the hook off the main queue, which the server hops to while it answers.
    private func hookAnswer(
        _ command: String, payload: String, environment: [String: String]
    ) -> (output: String, status: Int32) {
        let finished = expectation(description: "generated hook finished")
        let result = OSAllocatedUnfairLock<(output: String, status: Int32)>(
            initialState: (output: "", status: -1)
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                _, replacement in replacement
            }
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(payload.utf8))
                try? input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                result.withLock {
                    $0 = (String(decoding: data, as: UTF8.self), process.terminationStatus)
                }
            } catch {
                result.withLock { $0 = ("\(error)", -1) }
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        return result.withLock { $0 }
    }

    /// The broker's answer, and whether it reached the card.
    private func decide(_ request: PermissionRequest) -> (PermissionDecision?, asked: Bool) {
        var asked = false
        PermissionBroker.present = { _, completion in
            asked = true
            completion(.deny(reason: "test"))
        }
        var result: PermissionDecision?
        PermissionBroker.decide(request) { result = $0 }
        return (result, asked)
    }
}
