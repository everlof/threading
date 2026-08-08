import XCTest
@testable import Threading

@MainActor
final class StreamSessionLifecycleTests: XCTestCase {

    func testClaudeSpawnFailureArrivesAsynchronouslyOnMain() {
        let exited = expectation(description: "spawn failure callback")
        var startReturned = false

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            AgentLaunchPlan(
                executable: "/path/that/does/not/exist/claude",
                arguments: [],
                resumeState: .unavailable
            )
        }
        session.onExit = { status in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(startReturned)
            XCTAssertEqual(status, -1)
            exited.fulfill()
        }

        session.start()
        startReturned = true

        wait(for: [exited], timeout: 1)
    }

    func testClaudeSurfacesCappedStderrBeforeFailedExit() {
        let diagnosticReceived = expectation(description: "stderr diagnostic")
        let exited = expectation(description: "failed child exit")
        var receivedDiagnostic = false

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "/bin/cat >/dev/null; "
                    + "printf 'claude exploded' >&2; /bin/sleep 0.05; exit 7"
            )
        }
        session.onEvent = { event in
            guard case .turnFinished(let text, let outcome, _) = event else { return }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(text, "claude exploded")
            XCTAssertEqual(outcome, .failed)
            receivedDiagnostic = true
            diagnosticReceived.fulfill()
        }
        session.onExit = { status in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(receivedDiagnostic)
            XCTAssertEqual(status, 7)
            exited.fulfill()
        }

        session.start()
        session.finish()

        wait(for: [diagnosticReceived, exited], timeout: 2)
    }

    func testCodexTerminalEventIsDeliveredOnceOnMain() {
        let finished = expectation(description: "terminal event")
        let rootPlan = expectation(description: "root plan")
        let childPlan = expectation(description: "child plan")
        let duplicate = expectation(description: "duplicate terminal event")
        duplicate.isInverted = true
        var finishCount = 0
        var rootPlanCount = 0

        let session = CodexStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r initialize; "
                    + "printf '%s\\n' '{\"id\":1,\"result\":{}}'; "
                    + "read -r initialized; "
                    + "read -r open_thread; "
                    + "printf '%s\\n' "
                    + "'{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\","
                    + "\"model\":\"gpt-test\"}}}'; "
                    + "read -r start_turn; "
                    + "printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'; "
                    + "printf '%s\\n' 'not-json'; "
                    + "printf '%s\\n' "
                    + "'{\"method\":\"thread/tokenUsage/updated\",\"params\":{"
                    + "\"threadId\":\"thread-1\",\"turnId\":\"turn-1\","
                    + "\"tokenUsage\":{\"last\":{\"outputTokens\":17},\"total\":{}}}}'; "
                    + "printf '%s\\n' "
                    + "'{\"method\":\"turn/plan/updated\",\"params\":{"
                    + "\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"plan\":["
                    + "{\"step\":\"Inspect\",\"status\":\"completed\"},"
                    + "{\"step\":\"Verify\",\"status\":\"inProgress\"}]}}'; "
                    + "printf '%s\\n' "
                    + "'{\"method\":\"turn/plan/updated\",\"params\":{"
                    + "\"threadId\":\"child-1\",\"turnId\":\"child-turn\",\"plan\":["
                    + "{\"step\":\"Audit child\",\"status\":\"inProgress\"}]}}'; "
                    + "printf '%s\\n' "
                    + "'{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-1\","
                    + "\"turn\":{\"id\":\"turn-1\",\"items\":[],\"status\":\"completed\","
                    + "\"durationMs\":50}}}'; "
                    + "cat >/dev/null"
            )
        }
        session.onEvent = { event in
            switch event {
            case .runPlanUpdated(let steps):
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(steps.map(\.title), ["Inspect", "Verify"])
                rootPlanCount += 1
                rootPlan.fulfill()
            case .turnFinished:
                XCTAssertTrue(Thread.isMainThread)
                finishCount += 1
                if finishCount == 1 {
                    finished.fulfill()
                } else {
                    duplicate.fulfill()
                }
            default:
                break
            }
        }
        session.onSubagentEvent = { event in
            guard case .conversation(let threadID, .runPlanUpdated(let steps)) = event else {
                return
            }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(threadID, "child-1")
            XCTAssertEqual(steps.map(\.title), ["Audit child"])
            childPlan.fulfill()
        }

        session.start()
        XCTAssertTrue(session.send("test prompt"))

        wait(for: [rootPlan, childPlan, finished, duplicate], timeout: 1)
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(rootPlanCount, 1, "A child plan must not leak into the parent timeline")
        XCTAssertEqual(session.malformedLineCount, 1)
        XCTAssertTrue(session.canSend)
        session.terminate()
    }

    func testCodexReportsTheOpenedAndRenamedThreadTitlesAsProviderMetadata() {
        let reported = expectation(description: "Codex thread titles reported")
        reported.expectedFulfillmentCount = 2
        var titles: [String] = []

        let session = CodexStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r initialize; "
                    + "printf '%s\\n' '{\"id\":1,\"result\":{}}'; "
                    + "read -r initialized; "
                    + "read -r open_thread; "
                    + "printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{"
                    + "\"id\":\"thread-1\",\"model\":\"gpt-test\","
                    + "\"name\":\"Opening Name\"}}}'; "
                    + "printf '%s\\n' '{\"method\":\"thread/name/updated\",\"params\":{"
                    + "\"threadId\":\"thread-1\",\"threadName\":\"WINAMP\"}}'; "
                    + "cat >/dev/null"
            )
        }
        XCTAssertEqual(session.sessionTitleSource, .provider)
        session.onSessionTitleChange = { title in
            XCTAssertTrue(Thread.isMainThread)
            titles.append(title)
            reported.fulfill()
        }

        session.start()

        wait(for: [reported], timeout: 2)
        XCTAssertEqual(titles, ["Opening Name", "WINAMP"])
        session.terminate()
    }

    func testSetModelSendsControlRequestAndResolvesOnSuccessResponse() {
        let resolved = expectation(description: "control response resolved")

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            // Consume the one control request, answer it (the first id is deterministic), then idle
            // so the child stays alive until the test tears it down.
            self.shellPlan(
                "read -r line; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"threading-ctrl-1\"}}'; "
                    + "cat >/dev/null"
            )
        }

        session.start()
        session.setModel("claude-sonnet-5") { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .failure(let error) = result {
                XCTFail("Expected success, got \(error)")
            }
            resolved.fulfill()
        }

        wait(for: [resolved], timeout: 2)
        session.terminate()
    }

    func testSetModelSurfacesRejectionFromErrorResponse() {
        let resolved = expectation(description: "control rejection resolved")

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r line; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\","
                    + "\"request_id\":\"threading-ctrl-1\",\"error\":\"unrecognized model\"}}'; "
                    + "cat >/dev/null"
            )
        }

        session.start()
        session.setModel("bogus-model") { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected a rejection")
            }
            XCTAssertEqual(error.localizedDescription, "unrecognized model")
            resolved.fulfill()
        }

        wait(for: [resolved], timeout: 2)
        session.terminate()
    }

    /// The permission posture moves on the same channel the model does, and the CLI's own
    /// verdict is what the caller hears: `set_permission_mode` is in the accepted subtype list
    /// beside `set_model` (CLI 2.1.221), and a mode it will not take comes back as a
    /// `control_response` of subtype `error` carrying a sentence — `bypassPermissions` on a
    /// session not launched with `--dangerously-skip-permissions` is the one to expect.
    func testSetPermissionModeResolvesOnSuccessAndSurfacesTheCLIsRefusal() {
        let accepted = expectation(description: "permission mode accepted")

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r line; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"threading-ctrl-1\"}}'; "
                    + "cat >/dev/null"
            )
        }
        session.start()
        session.setPermissionMode(.plan) { result in
            if case .failure(let error) = result {
                XCTFail("Expected success, got \(error)")
            }
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 2)
        session.terminate()

        let refused = expectation(description: "permission mode refused")
        let strict = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r line; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\","
                    + "\"request_id\":\"threading-ctrl-1\","
                    + "\"error\":\"Cannot set permission mode to bypassPermissions because it is "
                    + "disabled by settings or configuration\"}}'; "
                    + "cat >/dev/null"
            )
        }
        strict.start()
        strict.setPermissionMode(.bypassPermissions) { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected a rejection")
            }
            XCTAssertTrue(
                error.localizedDescription.contains("disabled by settings"),
                "the CLI's own sentence has to reach the caller, got \(error)"
            )
            refused.fulfill()
        }
        wait(for: [refused], timeout: 2)
        strict.terminate()
    }

    func testPendingControlRequestFailsWhenProcessExits() {
        let resolved = expectation(description: "pending control request failed on exit")

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            // Take the request but never answer, then exit — the pending completion must fail
            // rather than sit on its timeout.
            self.shellPlan("read -r line; exit 0")
        }

        session.start()
        session.setModel("claude-sonnet-5") { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected failure when the process exits")
            }
            guard case ClaudeControlError.notRunning = error else {
                return XCTFail("Expected notRunning, got \(error)")
            }
            resolved.fulfill()
        }

        wait(for: [resolved], timeout: 2)
    }

    func testControlRequestBeforeStartFailsImmediately() {
        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan("cat >/dev/null")
        }

        var received: Result<Void, Error>?
        session.setModel("claude-sonnet-5") { received = $0 }

        // No process, so the failure is synchronous.
        guard case .failure(let error)? = received, case ClaudeControlError.notRunning = error else {
            return XCTFail("Expected an immediate notRunning failure, got \(String(describing: received))")
        }
    }

    func testClaudeInitializeAndSystemInitExposeRichCommandsAndSkills() throws {
        let discovered = expectation(description: "Claude catalog discovered")
        var didFulfill = false
        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r initialize; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"control_response\",\"response\":{"
                    + "\"subtype\":\"success\",\"request_id\":\"threading-ctrl-1\","
                    + "\"response\":{\"commands\":["
                    + "{\"name\":\"context\",\"description\":\"Show context usage\","
                    + "\"argumentHint\":\"\",\"aliases\":[\"ctx\"]},"
                    + "{\"name\":\"release\",\"description\":\"Prepare release\","
                    + "\"argumentHint\":\"[version]\",\"aliases\":[]}]}}}'; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"system\",\"subtype\":\"init\","
                    + "\"session_id\":\"claude-thread\",\"model\":\"claude-test\","
                    + "\"slash_commands\":[\"context\",\"release\"],"
                    + "\"skills\":[\"release\"]}'; "
                    + "cat >/dev/null"
            )
        }
        session.onComposerCapabilitiesChange = {
            guard !didFulfill,
                  session.composerCapabilities.contains(where: {
                      $0.name == "release" && $0.kind == .skill
                  }) else { return }
            didFulfill = true
            discovered.fulfill()
        }

        session.start()
        wait(for: [discovered], timeout: 2)

        let context = try XCTUnwrap(session.composerCapabilities.first { $0.name == "context" })
        XCTAssertEqual(context.description, "Show context usage")
        XCTAssertEqual(context.aliases, ["ctx"])
        XCTAssertEqual(context.presentation, .command)
        XCTAssertFalse(context.isAvailableInSkillCatalog)
        let release = try XCTUnwrap(session.composerCapabilities.first { $0.name == "release" })
        XCTAssertEqual(release.argumentHint, "[version]")
        XCTAssertEqual(release.kind, .skill)
        XCTAssertTrue(release.isAvailableInSkillCatalog)
        XCTAssertEqual(release.presentation, .turn)
        session.terminate()
    }

    func testClaudeInitializeDeduplicatesCollidingCommandNames() throws {
        let discovered = expectation(description: "Claude duplicate catalog normalized")
        var didFulfill = false
        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r initialize; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"control_response\",\"response\":{"
                    + "\"subtype\":\"success\",\"request_id\":\"threading-ctrl-1\","
                    + "\"response\":{\"commands\":["
                    + "{\"name\":\"run\",\"description\":\"Built-in run\"},"
                    + "{\"name\":\"context\",\"description\":\"Show context\"},"
                    + "{\"name\":\"run\",\"description\":\"Project run\"}"
                    + "]}}}'; cat >/dev/null"
            )
        }
        session.onComposerCapabilitiesChange = {
            guard !didFulfill,
                  session.composerCapabilities.contains(where: { $0.name == "run" })
            else { return }
            didFulfill = true
            discovered.fulfill()
        }

        session.start()
        wait(for: [discovered], timeout: 2)

        XCTAssertEqual(session.composerCapabilities.map(\.name), ["run", "context"])
        XCTAssertEqual(
            session.composerCapabilities.first { $0.name == "run" }?.description,
            "Project run",
            "The existing last-metadata-wins rule must survive order deduplication"
        )
        session.terminate()
    }

    func testClaudeLiveCatalogAppliesNativeSafetyAndPresentationOverrides() throws {
        let discovered = expectation(description: "Claude safe catalog discovered")
        var didFulfill = false
        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r initialize; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"control_response\",\"response\":{"
                    + "\"subtype\":\"success\",\"request_id\":\"threading-ctrl-1\","
                    + "\"response\":{\"commands\":["
                    + "{\"name\":\"clear\",\"description\":\"Start over\"},"
                    + "{\"name\":\"review\",\"description\":\"Review work\"},"
                    + "{\"name\":\"build\",\"description\":\"Legacy project command\"},"
                    + "{\"name\":\"__remote-workflow\",\"description\":\"Internal\"}"
                    + "]}}}'; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"system\",\"subtype\":\"init\","
                    + "\"slash_commands\":[\"clear\",\"review\",\"build\"],"
                    + "\"skills\":[\"clear\"]}'; cat >/dev/null"
            )
        }
        session.onComposerCapabilitiesChange = {
            guard !didFulfill,
                  session.composerCapabilities.contains(where: { $0.name == "review" }),
                  session.composerCapabilities.first(where: { $0.name == "clear" })?.kind == .skill,
                  session.composerCapabilities.contains(where: { $0.name == "build" })
            else { return }
            didFulfill = true
            discovered.fulfill()
        }

        session.start()
        wait(for: [discovered], timeout: 2)

        let clear = try XCTUnwrap(
            session.composerCapabilities.first { $0.name == "clear" }
        )
        XCTAssertFalse(clear.isEnabled)
        XCTAssertFalse(clear.unavailableReason?.isEmpty ?? true)
        XCTAssertEqual(
            session.composerCapabilities.first { $0.name == "review" }?.presentation,
            .turn
        )
        XCTAssertEqual(
            session.composerCapabilities.first { $0.name == "build" }?.presentation,
            .turn,
            "Unknown and legacy project commands are prompt workflows unless proven otherwise"
        )
        XCTAssertEqual(clear.kind, .skill, "The provider's membership is still represented")
        XCTAssertFalse(clear.isEnabled, "Unsafe command names must win over skill membership")
        XCTAssertFalse(
            session.composerCapabilities.contains { $0.name == "__remote-workflow" }
        )
        session.terminate()
    }

    func testClaudeInitializeKeepsUnclassifiedRowsBrowsableAsSkills() throws {
        let discovered = expectation(description: "Claude provisional catalog discovered")
        var didFulfill = false
        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r initialize; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"control_response\",\"response\":{"
                    + "\"subtype\":\"success\",\"request_id\":\"threading-ctrl-1\","
                    + "\"response\":{\"commands\":["
                    + "{\"name\":\"release\",\"description\":\"Prepare release\","
                    + "\"argumentHint\":\"[version]\",\"aliases\":[]}]}}}'; "
                    + "cat >/dev/null"
            )
        }
        session.onComposerCapabilitiesChange = {
            guard !didFulfill,
                  session.composerCapabilities.first(where: {
                      $0.name == "release"
                  })?.isAvailableInSkillCatalog == true
            else { return }
            didFulfill = true
            discovered.fulfill()
        }

        session.start()
        wait(for: [discovered], timeout: 2)

        let release = try XCTUnwrap(session.composerCapabilities.first { $0.name == "release" })
        XCTAssertEqual(release.kind, .command, "The provider has not classified this row yet")
        XCTAssertTrue(release.isAvailableInSkillCatalog)
        session.terminate()
    }

    func testClaudeCommandsChangedPreservesKnownSkillsAndClassifiesNewDiscoveries() throws {
        let discovered = expectation(description: "Claude discovered a nested skill")
        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r initialize; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"control_response\",\"response\":{"
                    + "\"subtype\":\"success\",\"request_id\":\"threading-ctrl-1\","
                    + "\"response\":{\"commands\":["
                    + "{\"name\":\"context\",\"description\":\"Show context\","
                    + "\"argumentHint\":\"\"},"
                    + "{\"name\":\"release\",\"description\":\"Release\","
                    + "\"argumentHint\":\"\"}]}}}'; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"system\",\"subtype\":\"init\","
                    + "\"slash_commands\":[\"context\",\"release\"],"
                    + "\"skills\":[\"release\"]}'; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"system\",\"subtype\":\"commands_changed\","
                    + "\"commands\":["
                    + "{\"name\":\"context\",\"description\":\"Show context\","
                    + "\"argumentHint\":\"\"},"
                    + "{\"name\":\"release\",\"description\":\"Release\","
                    + "\"argumentHint\":\"\"},"
                    + "{\"name\":\"nested-audit\",\"description\":\"Audit this folder\","
                    + "\"argumentHint\":\"[target]\"}]}'; cat >/dev/null"
            )
        }
        session.onComposerCapabilitiesChange = {
            guard session.composerCapabilities.contains(where: {
                $0.name == "nested-audit" && $0.kind == .skill
            }) else { return }
            discovered.fulfill()
        }

        session.start()
        wait(for: [discovered], timeout: 2)

        XCTAssertEqual(
            session.composerCapabilities.first { $0.name == "context" }?.kind,
            .command
        )
        XCTAssertEqual(
            session.composerCapabilities.first { $0.name == "release" }?.kind,
            .skill
        )
        XCTAssertEqual(
            session.composerCapabilities.first { $0.name == "nested-audit" }?.presentation,
            .turn
        )
        session.terminate()
    }

    func testClaudeQueuesOpeningPromptBehindCapabilityInitialization() {
        let finished = expectation(description: "queued prompt delivered")
        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r initialize; /bin/sleep 0.05; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"control_response\",\"response\":{"
                    + "\"subtype\":\"success\",\"request_id\":\"threading-ctrl-1\","
                    + "\"response\":{\"commands\":[]}}}'; "
                    + "read -r prompt; case \"$prompt\" in "
                    + "*'opening task'*) printf '%s\\n' "
                    + "'{\"type\":\"result\",\"subtype\":\"success\","
                    + "\"result\":\"queued prompt arrived\",\"is_error\":false}' ;; "
                    + "*) exit 9 ;; esac; cat >/dev/null"
            )
        }
        session.onComposerCapabilitiesChange = {}
        session.onEvent = { event in
            guard case .turnFinished(let text, let outcome, _) = event else { return }
            XCTAssertEqual(outcome, .completed)
            XCTAssertEqual(text, "queued prompt arrived")
            finished.fulfill()
        }

        session.start()
        XCTAssertTrue(session.send("opening task"))
        wait(for: [finished], timeout: 2)
        session.terminate()
    }

    func testCodexDiscoversSkillsAndSendsStructuredSkillInput() throws {
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: capture) }
        let discovered = expectation(description: "Codex skill discovered")
        let finished = expectation(description: "Codex skill turn finished")
        var didDiscover = false
        let session = CodexStreamSession(
            sessionID: SessionID(),
            workingDirectory: "/repo"
        ) {
            self.shellPlan(
                "read -r initialize; printf '%s\\n' '{\"id\":1,\"result\":{}}'; "
                    + "read -r initialized; read -r open_thread; "
                    + "printf '%s\\n' "
                    + "'{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\","
                    + "\"model\":\"gpt-test\"}}}'; "
                    + "read -r skills; printf '%s\\n' "
                    + "'{\"method\":\"skills/changed\",\"params\":{}}'; "
                    + "printf '%s\\n' "
                    + "'{\"id\":3,\"result\":{\"data\":[{\"cwd\":\"/repo\","
                    + "\"errors\":[],"
                    + "\"skills\":[{\"name\":\"release\","
                    + "\"path\":\"/repo/.codex/skills/release/SKILL.md\","
                    + "\"description\":\"Prepare a release\",\"enabled\":true,"
                    + "\"scope\":\"repo\","
                    + "\"interface\":{\"displayName\":\"Release\","
                    + "\"shortDescription\":\"Ship safely\"}},"
                    + "{\"name\":\"blocked\",\"path\":\"/repo/blocked/SKILL.md\","
                    + "\"description\":\"Disabled skill\",\"enabled\":false,"
                    + "\"scope\":\"repo\"}]}]}}'; "
                    + "read -r reloaded_skills; case \"$reloaded_skills\" in "
                    + "*'\"forceReload\":true'*) ;; *) exit 8 ;; esac; "
                    + "printf '%s\\n' "
                    + "'{\"id\":4,\"result\":{\"data\":[{\"cwd\":\"/repo\","
                    + "\"errors\":[],"
                    + "\"skills\":[{\"name\":\"release\","
                    + "\"path\":\"/repo/.codex/skills/release/SKILL.md\","
                    + "\"description\":\"Prepare a release\",\"enabled\":true,"
                    + "\"scope\":\"repo\","
                    + "\"interface\":{\"displayName\":\"Release\","
                    + "\"shortDescription\":\"Ship reloaded\"}},"
                    + "{\"name\":\"blocked\",\"path\":\"/repo/blocked/SKILL.md\","
                    + "\"description\":\"Disabled skill\",\"enabled\":false,"
                    + "\"scope\":\"repo\"}]}]}}'; "
                    + "read -r start_turn; printf '%s' \"$start_turn\" > '\(capture.path)'; "
                    + "printf '%s\\n' '{\"id\":5,\"result\":{\"turn\":{"
                    + "\"id\":\"skill-turn\"}}}'; "
                    + "printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{"
                    + "\"threadId\":\"thread-1\",\"turn\":{\"id\":\"skill-turn\","
                    + "\"items\":[],\"status\":\"completed\"}}}'; cat >/dev/null"
            )
        }
        session.onComposerCapabilitiesChange = {
            guard !didDiscover,
                  session.composerCapabilities.contains(where: {
                      $0.name == "release" && $0.description == "Ship reloaded"
                  })
            else { return }
            didDiscover = true
            discovered.fulfill()
        }
        session.onEvent = { event in
            guard case .turnFinished(_, let outcome, _) = event else { return }
            XCTAssertEqual(outcome, .completed)
            finished.fulfill()
        }

        session.start()
        wait(for: [discovered], timeout: 2)
        let disabled = try XCTUnwrap(ComposerCapabilityResolver.invocation(
            in: "$blocked do not run",
            capabilities: session.composerCapabilities
        ))
        XCTAssertFalse(session.send(disabled), "Disabled skills must be rejected at dispatch")
        let invocation = try XCTUnwrap(ComposerCapabilityResolver.invocation(
            in: "$release 1.2.3",
            capabilities: session.composerCapabilities
        ))
        XCTAssertTrue(session.send(invocation))
        wait(for: [finished], timeout: 2)

        let data = try Data(contentsOf: capture)
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "turn/start")
        let parameters = try XCTUnwrap(request["params"] as? [String: Any])
        let input = try XCTUnwrap(parameters["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["text"] as? String, "$release 1.2.3")
        XCTAssertEqual(input.last?["type"] as? String, "skill")
        XCTAssertEqual(input.last?["name"] as? String, "release")
        XCTAssertEqual(
            input.last?["path"] as? String,
            "/repo/.codex/skills/release/SKILL.md"
        )
        session.terminate()
    }

    func testCodexKeepsLastGoodSkillsAcrossWrongScopeAndIncompleteReloads() {
        let discovered = expectation(description: "initial Codex skill discovered")
        let exited = expectation(description: "invalid reload fixtures consumed")
        let session = CodexStreamSession(
            sessionID: SessionID(),
            workingDirectory: "/repo/../repo/"
        ) {
            self.shellPlan(
                "read -r initialize; printf '%s\\n' '{\"id\":1,\"result\":{}}'; "
                    + "read -r initialized; read -r open_thread; "
                    + "printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{"
                    + "\"id\":\"thread-1\",\"model\":\"gpt-test\"}}}'; "
                    + "read -r skills; printf '%s\\n' '{\"id\":3,\"result\":{"
                    + "\"data\":[{\"cwd\":\"/repo\",\"errors\":[],\"skills\":[{"
                    + "\"name\":\"release\",\"path\":\"/repo/release/SKILL.md\","
                    + "\"description\":\"Ship safely\",\"enabled\":true,"
                    + "\"scope\":\"repo\"}]}]}}'; "
                    + "printf '%s\\n' '{\"method\":\"skills/changed\",\"params\":{}}'; "
                    + "read -r wrong_cwd; printf '%s\\n' '{\"id\":4,\"result\":{"
                    + "\"data\":[{\"cwd\":\"/other\",\"errors\":[],\"skills\":[{"
                    + "\"name\":\"foreign\",\"path\":\"/other/foreign/SKILL.md\","
                    + "\"description\":\"Wrong checkout\",\"enabled\":true,"
                    + "\"scope\":\"repo\"}]}]}}'; "
                    + "printf '%s\\n' '{\"method\":\"skills/changed\",\"params\":{}}'; "
                    + "read -r empty_data; printf '%s\\n' "
                    + "'{\"id\":5,\"result\":{\"data\":[]}}'; "
                    + "printf '%s\\n' '{\"method\":\"skills/changed\",\"params\":{}}'; "
                    + "read -r scan_error; printf '%s\\n' '{\"id\":6,\"result\":{"
                    + "\"data\":[{\"cwd\":\"/repo\",\"errors\":[{"
                    + "\"message\":\"broken metadata\",\"path\":\"/repo/bad/SKILL.md\"}],"
                    + "\"skills\":[]}]}}'; /bin/sleep 0.1"
            )
        }
        session.onComposerCapabilitiesChange = {
            guard session.composerCapabilities.contains(where: { $0.name == "release" }) else {
                return
            }
            discovered.fulfill()
        }
        session.onExit = { status in
            XCTAssertEqual(status, 0)
            exited.fulfill()
        }

        session.start()
        wait(for: [discovered, exited], timeout: 3)

        XCTAssertTrue(session.composerCapabilities.contains { $0.name == "release" })
        XCTAssertFalse(session.composerCapabilities.contains { $0.name == "foreign" })
    }

    func testClaudeAndCodexApplyTheSharedLocalCatalogBudget() throws {
        func writeJSONLine(_ object: [String: Any], to url: URL) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try data.write(to: url, options: .atomic)
        }

        let claudeFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let codexFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: claudeFixture)
            try? FileManager.default.removeItem(at: codexFixture)
        }
        let oversizedDescription = String(repeating: "metadata", count: 500)
        let commandRows: [[String: Any]] = (0..<400).map { index in
            [
                "name": "command-\(index)",
                "description": oversizedDescription,
                "argumentHint": "[target]"
            ]
        }
        try writeJSONLine([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": "threading-ctrl-1",
                "response": ["commands": commandRows]
            ]
        ], to: claudeFixture)

        let claudeDiscovered = expectation(description: "bounded Claude catalog")
        let claude = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r initialize; /bin/cat '\(claudeFixture.path)'; cat >/dev/null"
            )
        }
        claude.onComposerCapabilitiesChange = {
            guard !claude.composerCapabilities.isEmpty else { return }
            claudeDiscovered.fulfill()
        }
        claude.start()
        wait(for: [claudeDiscovered], timeout: 3)
        XCTAssertLessThanOrEqual(
            claude.composerCapabilities.count,
            ComposerCapabilityCatalogPolicy.maximumCapabilities
        )
        XCTAssertTrue(claude.composerCapabilities.allSatisfy {
            $0.description.utf8.count
                <= ComposerCapabilityCatalogPolicy.maximumDescriptionUTF8Bytes
        })
        claude.terminate()

        let skillRows: [[String: Any]] = (0..<400).map { index in
            [
                "name": "skill-\(index)",
                "path": "/repo/.codex/skills/skill-\(index)/SKILL.md",
                "description": oversizedDescription,
                "enabled": true,
                "scope": "repo"
            ]
        }
        try writeJSONLine([
            "id": 3,
            "result": [
                "data": [["cwd": "/repo", "errors": [], "skills": skillRows]]
            ]
        ], to: codexFixture)

        let codexDiscovered = expectation(description: "bounded Codex catalog")
        let codex = CodexStreamSession(
            sessionID: SessionID(),
            workingDirectory: "/repo"
        ) {
            self.shellPlan(
                "read -r initialize; printf '%s\\n' '{\"id\":1,\"result\":{}}'; "
                    + "read -r initialized; read -r open_thread; "
                    + "printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{"
                    + "\"id\":\"thread-1\",\"model\":\"gpt-test\"}}}'; "
                    + "read -r skills; /bin/cat '\(codexFixture.path)'; cat >/dev/null"
            )
        }
        codex.onComposerCapabilitiesChange = {
            guard codex.composerCapabilities.contains(where: { $0.kind == .skill }) else {
                return
            }
            codexDiscovered.fulfill()
        }
        codex.start()
        wait(for: [codexDiscovered], timeout: 3)
        XCTAssertLessThanOrEqual(
            codex.composerCapabilities.count,
            ComposerCapabilityCatalogPolicy.maximumCapabilities
        )
        XCTAssertTrue(codex.composerCapabilities.allSatisfy {
            $0.description.utf8.count
                <= ComposerCapabilityCatalogPolicy.maximumDescriptionUTF8Bytes
        })
        codex.terminate()
    }

    func testCodexCompactAndReviewUseNativeAppServerMethods() throws {
        let compactCapture = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let reviewCapture = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: compactCapture)
            try? FileManager.default.removeItem(at: reviewCapture)
        }
        let initialized = expectation(description: "Codex thread initialized")
        let compacted = expectation(description: "Codex compacted")
        let reviewed = expectation(description: "Codex review finished")
        var finishCount = 0
        let session = CodexStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r initialize; printf '%s\\n' '{\"id\":1,\"result\":{}}'; "
                    + "read -r initialized; read -r open_thread; "
                    + "printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{"
                    + "\"id\":\"thread-1\",\"model\":\"gpt-test\"}}}'; "
                    + "read -r compact; printf '%s' \"$compact\" > '\(compactCapture.path)'; "
                    + "printf '%s\\n' '{\"id\":3,\"result\":{}}'; "
                    + "printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{"
                    + "\"threadId\":\"thread-1\",\"turn\":{\"id\":\"compact-turn\","
                    + "\"items\":[],\"status\":\"completed\"}}}'; "
                    + "read -r review; printf '%s' \"$review\" > '\(reviewCapture.path)'; "
                    + "printf '%s\\n' '{\"id\":4,\"result\":{\"turn\":{"
                    + "\"id\":\"review-turn\"}}}'; "
                    + "printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{"
                    + "\"threadId\":\"thread-1\",\"turn\":{\"id\":\"review-turn\","
                    + "\"items\":[],\"status\":\"completed\"}}}'; cat >/dev/null"
            )
        }
        session.onEvent = { event in
            switch event {
            case .initialised:
                initialized.fulfill()
            case .turnFinished(_, let outcome, _):
                XCTAssertEqual(outcome, .completed)
                finishCount += 1
                if finishCount == 1 { compacted.fulfill() }
                if finishCount == 2 { reviewed.fulfill() }
            default:
                break
            }
        }

        session.start()
        wait(for: [initialized], timeout: 2)
        let compact = try XCTUnwrap(ComposerCapabilityResolver.invocation(
            in: "/compact",
            capabilities: session.composerCapabilities
        ))
        XCTAssertTrue(session.send(compact))
        wait(for: [compacted], timeout: 2)
        let review = try XCTUnwrap(ComposerCapabilityResolver.invocation(
            in: "/review focus on authentication",
            capabilities: session.composerCapabilities
        ))
        XCTAssertTrue(session.send(review))
        wait(for: [reviewed], timeout: 2)

        let compactRequest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: compactCapture)
        ) as? [String: Any]
        XCTAssertEqual(compactRequest?["method"] as? String, "thread/compact/start")
        let reviewRequest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: reviewCapture)
        ) as? [String: Any])
        XCTAssertEqual(reviewRequest["method"] as? String, "review/start")
        let parameters = try XCTUnwrap(reviewRequest["params"] as? [String: Any])
        XCTAssertEqual(parameters["delivery"] as? String, "inline")
        let target = try XCTUnwrap(parameters["target"] as? [String: Any])
        XCTAssertEqual(target["type"] as? String, "custom")
        XCTAssertEqual(target["instructions"] as? String, "focus on authentication")
        session.terminate()
    }

    func testClaudeRoutesForwardedChildOutputAwayFromParentOnMain() {
        let parentReceived = expectation(description: "parent task call")
        let childReceived = expectation(description: "forwarded child output")
        var parentMessageCount = 0

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "printf '%s\\n' "
                    + "'{\"type\":\"assistant\",\"parent_tool_use_id\":null,"
                    + "\"session_id\":\"root\",\"message\":{\"content\":[{"
                    + "\"type\":\"tool_use\",\"id\":\"task-1\",\"name\":\"Task\","
                    + "\"input\":{\"description\":\"Audit parser\","
                    + "\"prompt\":\"Find the routing bug\",\"subagent_type\":\"Explore\"}}]}}'; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"assistant\",\"parent_tool_use_id\":\"task-1\","
                    + "\"session_id\":\"root\",\"subagent_type\":\"Explore\","
                    + "\"task_description\":\"Audit parser\",\"message\":{"
                    + "\"model\":\"claude-sonnet-4-5\",\"content\":[{"
                    + "\"type\":\"text\",\"text\":\"Found the child-only bug.\"}]}}'; "
                    + "cat >/dev/null"
            )
        }

        session.onEvent = { event in
            guard case .assistantMessage = event else { return }
            XCTAssertTrue(Thread.isMainThread)
            parentMessageCount += 1
            parentReceived.fulfill()
        }
        session.onSubagentEvent = { event in
            guard case .conversation(let threadID, let childEvent) = event,
                  case .assistantMessage(let blocks) = childEvent,
                  case .text(let text) = blocks.first
            else { return }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(threadID, "task-1")
            XCTAssertEqual(text, "Found the child-only bug.")
            childReceived.fulfill()
        }

        session.start()

        wait(for: [parentReceived, childReceived], timeout: 2)
        XCTAssertEqual(parentMessageCount, 1, "Child text must not enter the parent transcript")
        session.terminate()
    }

    private func shellPlan(_ script: String) -> AgentLaunchPlan {
        AgentLaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", script],
            resumeState: .unavailable
        )
    }
}

@MainActor
final class SubagentSessionStateTests: XCTestCase {

    func testDescriptorNeverUsesATranscriptPathAsItsDisplayName() {
        let descriptor = SubagentDescriptor(
            threadID: "af90bc36f7d81e85c",
            nickname: "  ",
            role: "",
            path: "/Users/example/.claude/projects/session/subagents/agent-af90bc36.jsonl"
        )

        XCTAssertEqual(descriptor.displayName, "Agent af90bc36")
    }

    func testOnlyObservedProviderAnalysisEnvelopeBecomesPresentationText() {
        XCTAssertEqual(
            SubagentDefaults.compactActivity(
                "<analysis>\nChronology: inspected the renderer.\n</analysis>"
            ),
            "Reasoning: Chronology: inspected the renderer."
        )
        XCTAssertEqual(
            SubagentDefaults.compactActivity(
                "<analysis> Chronology: the stop report was truncated before its closing tag…"
            ),
            "Reasoning: Chronology: the stop report was truncated before its closing tag…"
        )
        XCTAssertEqual(
            SubagentDefaults.compactActivity("<thinking>Keep this literal.</thinking>"),
            "<thinking>Keep this literal.</thinking>"
        )
        XCTAssertEqual(
            SubagentDefaults.compactActivity("<final>Keep this literal.</final>"),
            "<final>Keep this literal.</final>"
        )
        XCTAssertEqual(
            SubagentDefaults.compactActivity("<Analysis>Keep this literal.</Analysis>"),
            "<Analysis>Keep this literal.</Analysis>"
        )
        XCTAssertEqual(
            SubagentDefaults.compactActivity("<code>analysis is a valid element</code>"),
            "<code>analysis is a valid element</code>"
        )

        var timeline = SubagentTimeline(sessionID: SessionID())
        timeline.apply(.state(
            threadID: "child-1",
            status: .completed,
            message: "<analysis>Chronology: live lifecycle message"
        ))
        XCTAssertEqual(
            timeline.agents.first?.message,
            "Reasoning: Chronology: live lifecycle message"
        )
        XCTAssertEqual(
            timeline.agents.first?.activity,
            ["Reasoning: Chronology: live lifecycle message"]
        )
    }

    func testSnapshotRestoreNormalizesLegacyProviderEnvelopes() throws {
        let descriptor = SubagentDescriptor(threadID: "child-1")
        let snapshot = SubagentTimeline.Snapshot(agents: [
            SubagentTimeline.AgentSnapshot(
                descriptor: descriptor,
                status: .completed,
                message: "<analysis>Chronology: legacy message",
                progress: nil,
                activity: [
                    "<analysis>Chronology: legacy message",
                    "<analysis>Chronology: legacy message"
                ]
            )
        ])

        let restored = SubagentTimeline(sessionID: SessionID(), snapshot: snapshot)
        let agent = try XCTUnwrap(restored.agents.first)

        XCTAssertEqual(agent.message, "Reasoning: Chronology: legacy message")
        XCTAssertEqual(agent.activity, ["Reasoning: Chronology: legacy message"])
    }

    /// Refusing the parent's own turn at the hook stops new rows, but a navigator persisted
    /// before that keeps its rows across every relaunch. The store sweeps them on read, or the
    /// sessions that already have them never get better.
    func testLoadingDropsStoredRowsThatNameNoChild() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let transcript = directory.appendingPathComponent("agent-real.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let sessionID = SessionID()
        let store = SubagentStateStore(directory: directory)
        let seeded = SubagentSessionState(sessionID: sessionID, store: store)

        // The measured shape: an empty role and a transcript path the CLI never wrote.
        seeded.apply(.discovered(SubagentDescriptor(
            threadID: "aeeaf42678b4c16f7",
            parentThreadID: sessionID.uuidString.lowercased(),
            role: "",
            path: directory.appendingPathComponent("agent-phantom.jsonl").path
        )))
        seeded.apply(.state(threadID: "aeeaf42678b4c16f7", status: .completed, message: nil))
        seeded.apply(.discovered(SubagentDescriptor(
            threadID: "a3575fa54125f456c",
            role: "Explore",
            path: transcript.path
        )))
        seeded.apply(.state(threadID: "a3575fa54125f456c", status: .completed, message: nil))
        seeded.flushPersistence()
        XCTAssertEqual(seeded.timeline.agents.count, 2)

        let restored = SubagentSessionState(sessionID: sessionID, store: store)
        XCTAssertEqual(
            restored.timeline.agents.map(\.descriptor.threadID),
            ["a3575fa54125f456c"],
            "Only the child that names a role or has a transcript survives the sweep"
        )
    }

    func testSnapshotRestoresNavigatorMetadataAndSettlesLiveChildren() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = SessionID()
        let store = SubagentStateStore(directory: directory)
        let nativeState = SubagentSessionState(sessionID: sessionID, store: store)
        nativeState.apply(.discovered(SubagentDescriptor(
            threadID: "child-1",
            parentThreadID: "parent",
            nickname: "Researcher",
            role: "explorer",
            path: "/tmp/child.jsonl",
            prompt: "Find the parser"
        )))
        nativeState.apply(.state(
            threadID: "child-1",
            status: .working,
            message: nil
        ))
        nativeState.apply(.progress(
            threadID: "child-1",
            progress: SubagentProgress(totalTokens: 1_234, toolUses: 5)
        ))
        nativeState.select(threadID: "child-1")
        nativeState.flushPersistence()

        // A renderer switch reads the same object and therefore keeps the live status.
        let terminalState = nativeState
        XCTAssertEqual(terminalState.timeline.agents.first?.status, .working)
        XCTAssertEqual(terminalState.timeline.agents.first?.descriptor.nickname, "Researcher")
        XCTAssertEqual(terminalState.selectedThreadID, "child-1")

        // A full app restart restores the durable summary, but cannot claim the old process is
        // still alive.
        let restored = SubagentSessionState(sessionID: sessionID, store: store)
        let agent = try XCTUnwrap(restored.timeline.agents.first)
        XCTAssertEqual(agent.status, .stopped)
        XCTAssertEqual(agent.descriptor.path, "/tmp/child.jsonl")
        XCTAssertEqual(agent.progress?.totalTokens, 1_234)
        XCTAssertEqual(agent.progress?.toolUses, 5)
    }

    func testStoreRetainOnlyRemovesDeletedSessions() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let kept = SessionID()
        let removed = SessionID()
        let store = SubagentStateStore(directory: directory)
        let snapshot = SubagentTimeline.Snapshot(agents: [])
        store.save(snapshot, sessionID: kept)
        store.save(snapshot, sessionID: removed)

        store.retainOnly(sessionIDs: [kept])

        XCTAssertNotNil(store.load(sessionID: kept))
        XCTAssertNil(store.load(sessionID: removed))
    }

    func testInvalidatedStateIgnoresLateProviderUpdates() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = SessionID()
        let store = SubagentStateStore(directory: directory)
        let state = SubagentSessionState(sessionID: sessionID, store: store)

        // `retainOnly` invalidates the state while transcript usage may still be loading on a
        // background queue. That late result must not recreate the deleted session's file.
        state.invalidate()
        state.apply(.progress(
            threadID: "late-child",
            progress: SubagentProgress(totalTokens: 42)
        ))
        state.flushPersistence()

        XCTAssertTrue(state.timeline.agents.isEmpty)
        XCTAssertNil(store.load(sessionID: sessionID))
    }

    func testTranscriptReplacementPublishesOneAtomicWorkerReduction() {
        let state = SubagentSessionState(sessionID: SessionID())
        let threadID = "worker-child"
        state.apply(.discovered(SubagentDescriptor(threadID: threadID, role: "Explore")))
        state.apply(.state(threadID: threadID, status: .completed, message: nil))

        var observedRowCounts: [Int] = []
        state.onChange = {
            observedRowCounts.append(
                state.timeline.agents.first?.conversation.rows.count ?? -1
            )
        }
        let loaded = expectation(description: "worker reduction installed")
        state.replaceTranscriptConversation(
            threadID: threadID,
            events: [
                .userMessage("Inspect the renderer."),
                .assistantMessage(blocks: [
                    .toolUse(
                        id: "read-1",
                        tool: .read,
                        input: ["path": .string("Renderer.swift")]
                    ),
                    .text("The renderer is virtualized.")
                ]),
                .toolResults([ToolResult(
                    toolUseID: "read-1",
                    text: "source",
                    isError: false
                )])
            ]
        ) {
            loaded.fulfill()
        }

        // The method returns before reducing. The main actor sees either the old conversation
        // or the complete replacement, never event-by-event prefixes.
        XCTAssertEqual(state.timeline.agents.first?.conversation.rows.count, 0)
        wait(for: [loaded], timeout: 2)
        XCTAssertEqual(state.timeline.agents.first?.conversation.rows.count, 3)
        XCTAssertEqual(observedRowCounts, [3])
    }

    func testClaudeAgentAndToolUseIDsReconcileToOneDurableChild() throws {
        var timeline = SubagentTimeline(sessionID: SessionID())
        timeline.apply(.discovered(SubagentDescriptor(
            threadID: "agent-789",
            role: "Explore"
        )))
        timeline.apply(.state(
            threadID: "agent-789",
            status: .stopped,
            message: nil
        ))

        // Native history learns the spawning tool-use id and carries the terminal hook id as
        // its provider alias.
        timeline.apply(.discovered(SubagentDescriptor(
            threadID: "tool-use-123",
            alternateThreadIDs: ["agent-789"],
            path: "/tmp/agent-789.jsonl",
            prompt: "Audit the parser"
        )))
        timeline.apply(.state(
            threadID: "tool-use-123",
            status: .completed,
            message: "Done"
        ))

        let child = try XCTUnwrap(timeline.agents.first)
        XCTAssertEqual(timeline.agents.count, 1)
        XCTAssertEqual(child.descriptor.path, "/tmp/agent-789.jsonl")
        XCTAssertEqual(child.status, .completed)
        XCTAssertEqual(child.message, "Done")

        var restored = SubagentTimeline(
            sessionID: SessionID(),
            snapshot: timeline.snapshot
        )
        restored.apply(.state(
            threadID: "tool-use-123",
            status: .failed,
            message: "Late update"
        ))
        XCTAssertEqual(restored.agents.count, 1)
        XCTAssertEqual(restored.agents.first?.status, .failed)
    }

    /// The hook adapter admits a later event for a child it already accepted, so the lookup has
    /// to answer for a provider's *other* identity too — Claude's terminal hook reports the
    /// agent id where native history has already stored the tool-use id.
    func testAlreadyTrackedAnswersForEveryIdentityAChildIsKnownBy() {
        var timeline = SubagentTimeline(sessionID: SessionID())
        timeline.apply(.discovered(SubagentDescriptor(
            threadID: "tool-use-123",
            alternateThreadIDs: ["agent-789"],
            role: "Explore"
        )))

        XCTAssertTrue(timeline.contains(threadID: "tool-use-123"))
        XCTAssertTrue(timeline.contains(threadID: "agent-789"))
        XCTAssertFalse(timeline.contains(threadID: "agent-000"))
    }

    func testTranscriptLoaderRejectsLogicalPathsAndAcceptsRegularFiles() throws {
        let logical = SubagentDescriptor(
            threadID: "child",
            path: "/root/review_pr612_codex"
        )
        XCTAssertFalse(SubagentTranscriptLoader.isLoadable(logical))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)

        XCTAssertTrue(SubagentTranscriptLoader.isLoadable(SubagentDescriptor(
            threadID: "child",
            path: url.path
        )))
        XCTAssertEqual(
            SubagentTranscriptLoader.transcriptURL(for: SubagentDescriptor(
                threadID: "child",
                path: url.path
            )),
            url
        )
    }

    func testEmptyTranscriptReplayIsRetriableAndSignatureChangesReload() {
        var cache = SubagentTranscriptLoadCache()
        let empty = SubagentTranscriptSignature(byteCount: 0, modifiedAt: nil)
        let filled = SubagentTranscriptSignature(byteCount: 128, modifiedAt: Date())

        XCTAssertTrue(cache.begin(threadID: "child", signature: empty))
        guard case .retryAfter = cache.finish(
            threadID: "child",
            signature: empty,
            eventCount: 0
        ) else {
            return XCTFail("An empty replay should be retried, not cached")
        }
        XCTAssertTrue(cache.begin(threadID: "child", signature: empty))

        guard case .loaded = cache.finish(
            threadID: "child",
            signature: empty,
            eventCount: 1
        ) else {
            return XCTFail("A parsed replay should be cached")
        }
        XCTAssertFalse(cache.begin(threadID: "child", signature: empty))
        XCTAssertTrue(cache.begin(threadID: "child", signature: filled))
    }

    func testUnreadableSnapshotIsQuarantinedBeforeNewStateIsSaved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = SessionID()
        let stateDirectory = directory.appendingPathComponent(
            SubagentDefaults.snapshotDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        let file = stateDirectory
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension(SubagentDefaults.snapshotExtension)
        try Data("not-json".utf8).write(to: file)

        let store = SubagentStateStore(directory: directory)
        XCTAssertNil(store.load(sessionID: sessionID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let quarantined = try FileManager.default.contentsOfDirectory(
            at: stateDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(quarantined.contains {
            $0.lastPathComponent.hasPrefix(file.lastPathComponent + ".unreadable-")
        })

        store.save(SubagentTimeline.Snapshot(agents: []), sessionID: sessionID)
        XCTAssertNotNil(store.load(sessionID: sessionID))
    }

    func testClaudeChildUsageIncludesCachedAndUncachedTokens() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let line = """
        {"type":"assistant","requestId":"request-1","message":{"id":"message-1","usage":\
        {"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":3,\
        "cache_read_input_tokens":4}}}
        """
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(SubagentUsageReader.read(at: url, kind: .claude), 19)
    }

    func testCodexChildUsageCountsOnlyRequestsAfterChildBoundary() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let lines = [
            codexTokenCount(last: 999, total: 10_000),
            #"{"type":"inter_agent_communication_metadata","payload":{"trigger_turn":true}}"#,
            codexTokenCount(last: 30, total: 10_030),
            codexTokenCount(last: 40, total: 10_070)
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(SubagentUsageReader.read(at: url, kind: .codex), 70)
    }

    private func codexTokenCount(last: Int, total: Int) -> String {
        """
        {"type":"event_msg","payload":{"type":"token_count","info":{\
        "last_token_usage":{"total_tokens":\(last)},\
        "total_token_usage":{"total_tokens":\(total)}}}}
        """
    }
}

final class ClaudeSubagentEventTests: XCTestCase {

    func testTaskLaunchAndForwardedOutputBuildOneChildTimeline() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())

        let launch = try XCTUnwrap(adapter.route("""
            {"type":"assistant","parent_tool_use_id":null,"session_id":"root",
             "message":{"content":[{"type":"tool_use","id":"task-1","name":"Task",
             "input":{"description":"Audit parser","prompt":"Find the routing bug",
             "subagent_type":"Explore","model":"sonnet"}}]}}
            """))
        XCTAssertTrue(launch.belongsToParent)
        for event in launch.events { timeline.apply(event) }

        var child = try XCTUnwrap(timeline.agents.first)
        XCTAssertEqual(timeline.workingCount, 1)
        XCTAssertEqual(child.descriptor.threadID, "task-1")
        XCTAssertEqual(child.descriptor.parentThreadID, "root")
        XCTAssertEqual(child.descriptor.nickname, "Audit parser")
        XCTAssertEqual(child.descriptor.role, "Explore")
        XCTAssertEqual(child.descriptor.prompt, "Find the routing bug")

        let forwarded = try XCTUnwrap(adapter.route("""
            {"type":"assistant","parent_tool_use_id":"task-1","session_id":"root",
             "subagent_type":"Explore","task_description":"Audit parser",
             "message":{"model":"claude-sonnet-4-5","content":[
               {"type":"thinking","thinking":"Inspect routing."},
               {"type":"text","text":"Found the bug."}
             ]}}
            """))
        XCTAssertFalse(forwarded.belongsToParent)
        for event in forwarded.events { timeline.apply(event) }

        child = try XCTUnwrap(timeline.agents.first)
        XCTAssertEqual(child.descriptor.model, "claude-sonnet-4-5")
        XCTAssertEqual(
            child.conversation.rows,
            [.thinking("Inspect routing."), .assistant(markdown: "Found the bug.")]
        )
    }

    func testForwardedToolCallsResultsAndNestedAgentsStayInChildTimeline() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-parent", adapter: &adapter, timeline: &timeline)

        let toolCalls = try XCTUnwrap(adapter.route("""
            {"type":"assistant","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[
               {"type":"tool_use","id":"bash-1","name":"Bash",
                "input":{"command":"swift test"}},
               {"type":"tool_use","id":"task-child","name":"Agent",
                "input":{"description":"Inspect failure","prompt":"Read the failing test",
                         "subagent_type":"Explore"}}
             ]}}
            """))
        XCTAssertFalse(toolCalls.belongsToParent)
        for event in toolCalls.events { timeline.apply(event) }

        let result = try XCTUnwrap(adapter.route("""
            {"type":"user","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_result","tool_use_id":"bash-1",
             "is_error":false,"content":"All tests passed"}]}}
            """))
        for event in result.events { timeline.apply(event) }

        XCTAssertEqual(timeline.agents.count, 2)
        let parent = try XCTUnwrap(timeline.agents.first {
            $0.descriptor.threadID == "task-parent"
        })
        let nested = try XCTUnwrap(timeline.agents.first {
            $0.descriptor.threadID == "task-child"
        })
        XCTAssertEqual(nested.descriptor.parentThreadID, "task-parent")
        XCTAssertEqual(nested.descriptor.nickname, "Inspect failure")

        guard parent.conversation.rows.count == 2,
              case .toolCall(let bash) = parent.conversation.rows[0],
              case .toolCall(let agentCall) = parent.conversation.rows[1] else {
            return XCTFail("Expected the child transcript to retain both tool calls")
        }
        XCTAssertEqual(bash.tool, .bash)
        XCTAssertEqual(bash.result?.text, "All tests passed")
        XCTAssertEqual(agentCall.tool, .task)
    }

    func testForwardedClaudeTasksSurfaceChildRunProgressUntilCompletion() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-parent", adapter: &adapter, timeline: &timeline)

        let lines = [
            """
            {"type":"assistant","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_use","id":"create-1","name":"TaskCreate",
             "input":{"subject":"Verify child","activeForm":"Verifying child"}}]}}
            """,
            """
            {"type":"user","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_result","tool_use_id":"create-1",
             "is_error":false,"content":"Task #1 created successfully"}]}}
            """,
            """
            {"type":"assistant","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_use","id":"update-1","name":"TaskUpdate",
             "input":{"taskId":"1","status":"in_progress",
             "activeForm":"Verifying child"}}]}}
            """
        ]

        for line in lines {
            let route = try XCTUnwrap(adapter.route(line))
            for event in route.events { timeline.apply(event) }
        }

        XCTAssertEqual(timeline.agents.first?.runProgress?.label, "Step 1 / 1")
        XCTAssertEqual(timeline.agents.first?.statusDetail, "Step 1 / 1")

        timeline.apply(.state(
            threadID: "task-parent",
            status: .completed,
            message: "Finished"
        ))
        XCTAssertNil(timeline.agents.first?.runProgress)
        XCTAssertNil(timeline.agents.first?.statusDetail)
    }

    func testCompletedClaudeChildIgnoresTaskProgressFromHistoricalReplay() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-parent", adapter: &adapter, timeline: &timeline)
        timeline.apply(.state(
            threadID: "task-parent",
            status: .completed,
            message: "Finished"
        ))

        let historicalLines = [
            """
            {"type":"assistant","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_use","id":"create-1","name":"TaskCreate",
             "input":{"subject":"Verify child","activeForm":"Verifying child"}}]}}
            """,
            """
            {"type":"user","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_result","tool_use_id":"create-1",
             "is_error":false,"content":"Task #1 created successfully"}]}}
            """,
            """
            {"type":"assistant","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_use","id":"update-1","name":"TaskUpdate",
             "input":{"taskId":"1","status":"in_progress",
             "activeForm":"Verifying child"}}]}}
            """
        ]

        for line in historicalLines {
            let route = try XCTUnwrap(adapter.route(line))
            // Lazy history supplies only the selected child's StreamEvents. The adapter's
            // synthetic live `.working` observation is deliberately not part of replay.
            for event in route.events {
                guard case .conversation = event else { continue }
                timeline.apply(event)
            }
        }

        XCTAssertEqual(timeline.agents.first?.status, .completed)
        XCTAssertNil(timeline.agents.first?.runProgress)
        XCTAssertNil(timeline.agents.first?.statusDetail)
    }

    func testStructuredTaskLifecycleMergesTypedProgress() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-background", adapter: &adapter, timeline: &timeline)

        let lines = [
            """
            {"type":"system","subtype":"task_started","task_id":"runtime-7",
             "tool_use_id":"task-background","task_type":"local_agent",
             "description":"Audit parser","subagent_type":"Explore"}
            """,
            """
            {"type":"system","subtype":"task_progress","task_id":"runtime-7",
             "summary":"Checking the event adapter","last_tool_name":"Grep",
             "usage":{"total_tokens":12450,"tool_uses":7,"duration_ms":32000}}
            """,
            """
            {"type":"tool_progress","parent_tool_use_id":"task-background",
             "task_id":"runtime-7","tool_name":"Read","elapsed_time_seconds":34}
            """,
            """
            {"type":"system","subtype":"task_updated","task_id":"runtime-7",
             "patch":{"status":"running","is_backgrounded":true}}
            """,
            """
            {"type":"system","subtype":"task_notification","task_id":"runtime-7",
             "status":"completed","summary":"Parser audit complete",
             "usage":{"total_tokens":13700,"tool_uses":9,"duration_ms":41000}}
            """
        ]

        for line in lines {
            let route = try XCTUnwrap(adapter.route(line))
            for event in route.events { timeline.apply(event) }
        }

        let agent = try XCTUnwrap(timeline.agents.first)
        let progress = try XCTUnwrap(agent.progress)
        XCTAssertEqual(agent.status, .completed)
        XCTAssertEqual(progress.taskID, "runtime-7")
        XCTAssertEqual(progress.summary, "Parser audit complete")
        XCTAssertEqual(progress.currentTool, "Read")
        XCTAssertEqual(progress.totalTokens, 13_700)
        XCTAssertEqual(progress.toolUses, 9)
        XCTAssertEqual(progress.duration, 41)
        XCTAssertEqual(progress.elapsed, 34)
        XCTAssertEqual(progress.isBackgrounded, true)
        XCTAssertEqual(
            progress.displayText,
            "Parser audit complete · 41s · 9 tools · 13.7k tokens"
        )
        XCTAssertEqual(agent.activity.last, "Parser audit complete")
    }

    func testStructuredBackgroundBashDoesNotCreateSubagent() throws {
        var adapter = ClaudeSubagentEventAdapter()
        let route = try XCTUnwrap(adapter.route("""
            {"type":"system","subtype":"task_started","task_id":"bash-runtime",
             "tool_use_id":"bash-tool","task_type":"local_bash",
             "description":"Run the test suite"}
            """))

        XCTAssertTrue(route.belongsToParent)
        XCTAssertTrue(route.events.isEmpty)
    }

    func testForwardedResumePreservesRecoveredNestedParent() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        timeline.apply(.discovered(SubagentDescriptor(
            threadID: "task-child",
            parentThreadID: "task-parent",
            nickname: "Recovered child"
        )))

        let route = try XCTUnwrap(adapter.route("""
            {"type":"assistant","parent_tool_use_id":"task-child","session_id":"root",
             "message":{"content":[{"type":"text","text":"Resumed output"}]}}
            """))
        for event in route.events { timeline.apply(event) }

        XCTAssertEqual(timeline.agents.first?.descriptor.parentThreadID, "task-parent")
        XCTAssertEqual(
            timeline.agents.first?.conversation.rows,
            [.assistant(markdown: "Resumed output")]
        )
    }

    func testForegroundResultCompletesTask() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-foreground", adapter: &adapter, timeline: &timeline)

        let result = try XCTUnwrap(adapter.route("""
            {"type":"user","parent_tool_use_id":null,"message":{"content":[{
              "type":"tool_result","tool_use_id":"task-foreground",
              "is_error":false,"content":"Done"
            }]}}
            """))
        for event in result.events { timeline.apply(event) }

        XCTAssertEqual(timeline.workingCount, 0)
        XCTAssertEqual(timeline.doneCount, 1)
        XCTAssertEqual(timeline.agents.first?.status, .completed)
    }

    func testAsyncReceiptWaitsForTaskNotificationAndMergesAgentID() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-background", adapter: &adapter, timeline: &timeline)

        let receipt = try XCTUnwrap(adapter.route("""
            {"type":"user","parent_tool_use_id":null,
             "message":{"content":[{"type":"tool_result",
             "tool_use_id":"task-background","is_error":false,
             "content":"Async agent launched"}]},
             "tool_use_result":{"isAsync":true,"status":"async_launched",
             "agentId":"agent-7","description":"Research",
             "resolvedModel":"claude-haiku-4-5"}}
            """))
        for event in receipt.events { timeline.apply(event) }

        XCTAssertEqual(timeline.workingCount, 1)
        XCTAssertEqual(timeline.doneCount, 0)
        XCTAssertEqual(timeline.agents.first?.descriptor.model, "claude-haiku-4-5")

        let notification = try XCTUnwrap(adapter.route("""
            {"type":"user","parent_tool_use_id":null,"message":{"content":
             "<task-notification><task-id>agent-7</task-id><status>completed</status>\
             <summary>Agent finished its audit</summary></task-notification>"}}
            """))
        for event in notification.events { timeline.apply(event) }

        XCTAssertEqual(timeline.workingCount, 0)
        XCTAssertEqual(timeline.doneCount, 1)
        XCTAssertEqual(timeline.agents.count, 1)
        XCTAssertEqual(timeline.agents.first?.descriptor.threadID, "task-background")
        XCTAssertEqual(timeline.agents.first?.status, .completed)
        XCTAssertEqual(timeline.agents.first?.activity.last, "Agent finished its audit")
    }

    func testSessionTerminationClosesOnlyActiveTasks() {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-active", adapter: &adapter, timeline: &timeline)

        for event in adapter.terminationEvents(status: 7) { timeline.apply(event) }

        XCTAssertEqual(timeline.agents.first?.status, .failed)
        XCTAssertEqual(
            timeline.agents.first?.activity.last,
            "Failed when the Claude session exited"
        )
        XCTAssertTrue(adapter.terminationEvents(status: 7).isEmpty)
    }

    private func applyLaunch(
        taskID: String,
        adapter: inout ClaudeSubagentEventAdapter,
        timeline: inout SubagentTimeline
    ) {
        let route = adapter.route("""
            {"type":"assistant","parent_tool_use_id":null,"session_id":"root",
             "message":{"content":[{"type":"tool_use","id":"\(taskID)",
             "name":"Task","input":{"description":"Child"}}]}}
            """)
        for event in route?.events ?? [] { timeline.apply(event) }
    }
}

final class ClaudeControlRequestTests: XCTestCase {

    func testSetModelProducesControlRequestEnvelope() throws {
        let data = try XCTUnwrap(ClaudeControlRequest.line(
            subtype: ClaudeControlRequest.setModel,
            requestID: "threading-ctrl-3",
            body: ["model": "claude-sonnet-5"]
        ))
        XCTAssertEqual(data.last, 0x0A, "The line must be newline-terminated like a turn")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "control_request")
        XCTAssertEqual(object["request_id"] as? String, "threading-ctrl-3")

        let request = try XCTUnwrap(object["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "set_model")
        XCTAssertEqual(request["model"] as? String, "claude-sonnet-5")
    }

    func testFastModeProducesApplyFlagSettingsEnvelope() throws {
        let data = try XCTUnwrap(ClaudeControlRequest.line(
            subtype: ClaudeControlRequest.applyFlagSettings,
            requestID: "threading-ctrl-4",
            body: ["settings": ["fastMode": true]]
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try XCTUnwrap(object["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "apply_flag_settings")
        let settings = try XCTUnwrap(request["settings"] as? [String: Any])
        XCTAssertEqual(settings["fastMode"] as? Bool, true)
    }

    /// The mode travels as Claude's **external** flag value, which the CLI normalises to its own
    /// internal name on the way in — `manual` becomes `default` there, and sending `default`
    /// from here would be writing down an internal detail this app has no business knowing.
    func testSetPermissionModeProducesControlRequestEnvelopeWithTheExternalValue() throws {
        for mode in AgentPermissionMode.allCases {
            let data = try XCTUnwrap(ClaudeControlRequest.line(
                subtype: ClaudeControlRequest.setPermissionMode,
                requestID: "threading-ctrl-6",
                body: ["mode": mode.claudeFlagValue]
            ))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let request = try XCTUnwrap(object["request"] as? [String: Any])
            XCTAssertEqual(request["subtype"] as? String, "set_permission_mode")
            XCTAssertEqual(request["mode"] as? String, mode.rawValue)
        }
        XCTAssertEqual(AgentPermissionMode.manual.claudeFlagValue, "manual")
    }

    func testNilModelSerializesAsJSONNullToResetToDefault() throws {
        let data = try XCTUnwrap(ClaudeControlRequest.line(
            subtype: ClaudeControlRequest.setModel,
            requestID: "threading-ctrl-5",
            body: ["model": NSNull()]
        ))
        // The CLI resets to the default on null; the key must be present as null, not omitted.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"model\":null"), "Expected a null model, got: \(text)")
    }

    func testControlResponseParsesSuccess() throws {
        let response = try XCTUnwrap(ControlResponse.parse(
            #"{"type":"control_response","response":{"subtype":"success","request_id":"threading-ctrl-1"}}"#))
        XCTAssertEqual(response.requestID, "threading-ctrl-1")
        XCTAssertFalse(response.isError)
    }

    func testControlResponseParsesErrorWithMessage() throws {
        let response = try XCTUnwrap(ControlResponse.parse(
            #"{"type":"control_response","response":{"subtype":"error","request_id":"threading-ctrl-1","error":"unrecognized model"}}"#))
        XCTAssertTrue(response.isError)
        XCTAssertEqual(response.error, "unrecognized model")
    }

    func testControlResponseIgnoresOrdinaryEvents() {
        XCTAssertNil(ControlResponse.parse(#"{"type":"assistant","message":{"content":[]}}"#))
        XCTAssertNil(ControlResponse.parse(#"{"type":"result","result":"done"}"#))
        XCTAssertNil(ControlResponse.parse("not json at all"))
    }
}

final class StreamEventParserTests: XCTestCase {

    func testClaudeDecodesKnownEventsAndToleratesOptionalFieldDrift() throws {
        let event = try onlyEvent(StreamEvent.parse("""
            {"type":"system","subtype":"init","session_id":"thread-1","model":42,
             "future_field":{"nested":true}}
            """))

        guard case .initialised(let sessionID, let model) = event else {
            return XCTFail("Expected Claude init event")
        }
        XCTAssertEqual(sessionID, TranscriptID("thread-1"))
        XCTAssertNil(model)
    }

    func testClaudeToolArgumentsAndResultsKeepStructuredJSON() throws {
        let call = try onlyEvent(StreamEvent.parse("""
            {"type":"assistant","message":{"content":[{
              "type":"tool_use","id":"call-1","name":"Bash",
              "input":{"command":"echo hi","options":{"quiet":true},"retries":2}
            }]}}
            """))
        guard case .assistantMessage(let blocks) = call,
              case .toolUse(let id, let tool, let input) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected Claude tool call")
        }
        XCTAssertEqual(id, "call-1")
        XCTAssertEqual(tool, .bash)
        XCTAssertEqual(input["command"], .string("echo hi"))
        XCTAssertEqual(input["options"]?.objectValue?["quiet"], .bool(true))
        XCTAssertEqual(input["retries"], .integer(2))

        let result = try onlyEvent(StreamEvent.parse("""
            {"type":"user","message":{"content":[{
              "type":"tool_result","tool_use_id":"call-1","is_error":false,
              "content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]
            }]}}
            """))
        guard case .toolResults(let results) = result else {
            return XCTFail("Expected Claude tool result")
        }
        XCTAssertEqual(try XCTUnwrap(results.first).text, "first\nsecond")
    }

    func testCodexDecodesStringEncodedMCPArgumentsAndErrorObjects() throws {
        let call = try onlyEvent(CodexStreamEvent.parse(##"{"type":"item.started","item":{"id":"call-2","type":"mcp_tool_call","server":"web","tool":"query","arguments":"{\"selector\":\"#main\"}"}}"##))
        guard case .assistantMessage(let blocks) = call,
              case .toolUse(let id, let tool, let input) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected Codex MCP tool call")
        }
        XCTAssertEqual(id, "call-2")
        XCTAssertEqual(tool, .mcp("mcp__web__query"))
        XCTAssertEqual(input["selector"], .string("#main"))

        let failed = try onlyEvent(CodexStreamEvent.parse("""
            {"type":"turn.failed","error":{"message":"sandbox denied","code":17}}
            """))
        guard case .turnFinished(let text, let outcome, _) = failed else {
            return XCTFail("Expected failed Codex turn")
        }
        XCTAssertEqual(text, "sandbox denied")
        XCTAssertEqual(outcome, .failed)
    }

    func testBothProvidersDecodeExactTurnReceipts() throws {
        let claude = try onlyEvent(StreamEvent.parse("""
            {"type":"result","is_error":false,"duration_ms":89432,
             "usage":{"input_tokens":12000,"output_tokens":3149}}
            """))
        guard case .turnFinished(_, .completed, let claudeMetrics) = claude else {
            return XCTFail("Expected Claude result")
        }
        XCTAssertEqual(
            try XCTUnwrap(claudeMetrics.duration),
            89.432,
            accuracy: 0.0001
        )
        XCTAssertEqual(claudeMetrics.outputTokens, 3_149)

        let codex = try onlyEvent(CodexStreamEvent.parse("""
            {"type":"turn.completed",
             "usage":{"input_tokens":12000,"cached_input_tokens":9000,"output_tokens":3149}}
            """))
        guard case .turnFinished(_, .completed, let codexMetrics) = codex else {
            return XCTFail("Expected Codex result")
        }
        XCTAssertNil(codexMetrics.duration, "Codex duration comes from the wrapper's local clock")
        XCTAssertEqual(codexMetrics.outputTokens, 3_149)
    }

    /// Claude restates the whole in-flight list whenever it changes, so the event is a level
    /// and the empty one is as meaningful as the full one — it is what says the session may
    /// finish. Both shapes measured against CLI 2.1.220 running a backgrounded shell.
    func testClaudeReportsBackgroundWorkAsAWholeList() throws {
        let started = try onlyEvent(StreamEvent.parse("""
            {"type":"system","subtype":"background_tasks_changed","tasks":[
              {"task_id":"b4vc22id4","task_type":"local_bash","description":"scripts/test.sh"},
              {"task_id":"b8x1tqpxz","task_type":"local_agent","description":"explore"}
            ],"session_id":"thread-1"}
            """))
        guard case .backgroundWork(let inFlight) = started else {
            return XCTFail("Expected a background-work level")
        }
        // Identities and kinds, not a count: the ledger has to tell these apart across turns
        // and to tell delegated work from standing work. The stream spells the key `task_id`
        // where the hook payload spells it `id`, and the kind as the raw `local_agent` where
        // the hook sends the friendly `subagent`.
        XCTAssertEqual(inFlight, [
            BackgroundTask(id: "b4vc22id4", kind: .standing),
            BackgroundTask(id: "b8x1tqpxz", kind: .delegated)
        ])

        let drained = try onlyEvent(StreamEvent.parse(
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#
        ))
        guard case .backgroundWork(let none) = drained else {
            return XCTFail("An empty list is still a level, not an unknown event")
        }
        XCTAssertTrue(none.isEmpty)
    }

    /// A system subtype nothing consumes stays `unknown`, so a future one is ignored rather
    /// than mistaken for a background-work level.
    func testOtherSystemSubtypesStayUnknown() throws {
        let event = try onlyEvent(StreamEvent.parse(
            #"{"type":"system","subtype":"task_started","task_id":"b4vc22id4"}"#
        ))
        guard case .unknown(let type) = event else {
            return XCTFail("Expected an unknown system event")
        }
        XCTAssertEqual(type, "system")
    }

    func testUnknownKindsAreEventsButMalformedLinesAreCountable() throws {
        let claudeUnknown = try onlyEvent(StreamEvent.parse(#"{"type":"future.event"}"#))
        guard case .unknown(let claudeType) = claudeUnknown else {
            return XCTFail("Expected unknown Claude event")
        }
        XCTAssertEqual(claudeType, "future.event")

        let codexUnknown = try onlyEvent(CodexStreamEvent.parse(#"{"type":"future.event"}"#))
        guard case .unknown(let codexType) = codexUnknown else {
            return XCTFail("Expected unknown Codex event")
        }
        XCTAssertEqual(codexType, "future.event")

        guard case .malformed = StreamEvent.parse("not-json") else {
            return XCTFail("Invalid Claude JSON must be malformed")
        }
        guard case .malformed = CodexStreamEvent.parse(#"{"message":"missing type"}"#) else {
            return XCTFail("A Codex record without a type must be malformed")
        }

        var diagnostics = StreamParseDiagnostics()
        diagnostics.recordMalformedLine(provider: "test")
        diagnostics.recordMalformedLine(provider: "test")
        XCTAssertEqual(diagnostics.malformedLineCount, 2)
        diagnostics.reset()
        XCTAssertEqual(diagnostics.malformedLineCount, 0)
    }

    private func onlyEvent(_ result: StreamLineParseResult) throws -> StreamEvent {
        guard case .events(let events) = result else {
            throw ParserTestError.malformed
        }
        XCTAssertEqual(events.count, 1)
        return try XCTUnwrap(events.first)
    }

    private enum ParserTestError: Error {
        case malformed
    }
}

final class CodexAppServerEventTests: XCTestCase {

    func testEnvelopeDistinguishesResponsesRequestsAndNotifications() throws {
        guard case .response(let responseID, let result, let error)? =
                CodexAppServerEnvelope.parse(
                    #"{"id":4,"result":{"thread":{"id":"root"}}}"#
                ) else {
            return XCTFail("Expected response")
        }
        XCTAssertEqual(responseID, .integer(4))
        XCTAssertEqual(
            (result?["thread"] as? [String: Any])?["id"] as? String,
            "root"
        )
        XCTAssertNil(error)

        guard case .request(let requestID, let method, let parameters)? =
                CodexAppServerEnvelope.parse(
                    #"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"command":"make"}}"#
                ) else {
            return XCTFail("Expected request")
        }
        XCTAssertEqual(requestID, .string("approval-1"))
        XCTAssertEqual(method, "item/commandExecution/requestApproval")
        XCTAssertEqual(parameters["command"] as? String, "make")

        guard case .notification(let notification, let parameters)? =
                CodexAppServerEnvelope.parse(
                    #"{"method":"item/agentMessage/delta","params":{"threadId":"root","delta":"Hi"}}"#
                ) else {
            return XCTFail("Expected notification")
        }
        XCTAssertEqual(notification, "item/agentMessage/delta")
        XCTAssertEqual(parameters["delta"] as? String, "Hi")
    }

    func testAppServerParentItemsReuseConversationEvents() throws {
        let started = CodexAppServerEvent.streamEvents(
            method: "item/started",
            parameters: [
                "threadId": "root",
                "item": [
                    "id": "command-1",
                    "type": "commandExecution",
                    "command": "swift test",
                    "status": "inProgress"
                ]
            ]
        )
        guard case .assistantMessage(let blocks) = try XCTUnwrap(started.first),
              case .toolUse(let id, let tool, let input) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected command tool use")
        }
        XCTAssertEqual(id, "command-1")
        XCTAssertEqual(tool, .bash)
        XCTAssertEqual(input["command"], .string("swift test"))

        let completed = CodexAppServerEvent.streamEvents(
            method: "item/completed",
            parameters: [
                "threadId": "root",
                "item": [
                    "id": "message-1",
                    "type": "agentMessage",
                    "text": "All green."
                ]
            ]
        )
        guard case .assistantMessage(let completedBlocks) = try XCTUnwrap(completed.first),
              case .text(let text) = try XCTUnwrap(completedBlocks.first) else {
            return XCTFail("Expected completed agent message")
        }
        XCTAssertEqual(text, "All green.")
    }

    func testAppServerPlanNotificationCarriesTheAuthoritativeOrderedSnapshot() throws {
        let events = CodexAppServerEvent.streamEvents(
            method: "turn/plan/updated",
            parameters: [
                "threadId": "root",
                "turnId": "turn-1",
                "plan": [
                    ["step": "Inspect", "status": "completed"],
                    ["step": "Implement", "status": "inProgress"],
                    ["step": "Verify", "status": "pending"],
                ]
            ]
        )

        guard case .runPlanUpdated(let steps) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected a provider-neutral plan snapshot")
        }
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[1].title, "Implement")
        XCTAssertEqual(steps[1].status, .inProgress)

        var timeline = ConversationTimeline(sessionID: SessionID())
        XCTAssertEqual(
            timeline.apply(events[0]),
            [.runProgress(RunProgress(step: 2, total: 3))]
        )
    }

    func testAppServerRejectsAPartiallyMalformedPlanSnapshot() {
        let events = CodexAppServerEvent.streamEvents(
            method: "turn/plan/updated",
            parameters: [
                "threadId": "root",
                "turnId": "turn-1",
                "plan": [
                    ["step": "Inspect", "status": "completed"],
                    ["step": "Broken"],
                ]
            ]
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testCodexChildPlanLivesInChildSummaryAndClearsAtCompletion() throws {
        let parameters: [String: Any] = [
            "threadId": "child-1",
            "turnId": "child-turn",
            "plan": [
                ["step": "Inspect", "status": "completed"],
                ["step": "Verify", "status": "inProgress"],
                ["step": "Report", "status": "pending"],
            ]
        ]
        let events = CodexSubagentEvent.events(
            method: "turn/plan/updated",
            parameters: parameters,
            rootThreadID: "root"
        )

        var timeline = SubagentTimeline(sessionID: SessionID())
        for event in events { timeline.apply(event) }

        XCTAssertEqual(timeline.agents.first?.runProgress?.label, "Step 2 / 3")
        XCTAssertEqual(timeline.agents.first?.statusDetail, "Step 2 / 3")
        XCTAssertTrue(CodexSubagentEvent.events(
            method: "turn/plan/updated",
            parameters: parameters.merging(["threadId": "root"]) { _, newer in newer },
            rootThreadID: "root"
        ).isEmpty)

        timeline.apply(.state(threadID: "child-1", status: .completed, message: nil))
        XCTAssertNil(timeline.agents.first?.runProgress)
        XCTAssertNil(timeline.agents.first?.statusDetail)
    }

    func testCodexChildCanResumeAfterIdleAndReportANewPlan() {
        var timeline = SubagentTimeline(sessionID: SessionID())

        func applyStatus(_ type: String) {
            for event in CodexSubagentEvent.events(
                method: "thread/status/changed",
                parameters: [
                    "threadId": "child-1",
                    "status": ["type": type]
                ],
                rootThreadID: "root"
            ) {
                timeline.apply(event)
            }
        }

        func applyPlan(_ steps: [[String: String]]) {
            for event in CodexSubagentEvent.events(
                method: "turn/plan/updated",
                parameters: [
                    "threadId": "child-1",
                    "turnId": "child-turn",
                    "plan": steps
                ],
                rootThreadID: "root"
            ) {
                timeline.apply(event)
            }
        }

        applyStatus("active")
        applyPlan([["step": "First turn", "status": "inProgress"]])
        XCTAssertEqual(timeline.agents.first?.runProgress?.label, "Step 1 / 1")

        applyStatus("idle")
        XCTAssertEqual(timeline.agents.first?.status, .completed)
        XCTAssertNil(timeline.agents.first?.runProgress)

        applyStatus("active")
        applyPlan([
            ["step": "Inspect follow-up", "status": "inProgress"],
            ["step": "Report", "status": "pending"]
        ])

        XCTAssertEqual(timeline.agents.first?.status, .working)
        XCTAssertEqual(timeline.agents.first?.runProgress?.label, "Step 1 / 2")
        XCTAssertEqual(timeline.agents.first?.statusDetail, "Step 1 / 2")
    }

    func testCollaborationEventsBuildAChildTimelineAndCounts() throws {
        let parameters: [String: Any] = [
            "threadId": "root",
            "item": [
                "id": "collab-1",
                "type": "collabAgentToolCall",
                "tool": "spawnAgent",
                "status": "inProgress",
                "senderThreadId": "root",
                "receiverThreadIds": ["child-1"],
                "prompt": "Audit the parser",
                "model": "gpt-5.6-sol",
                "reasoningEffort": "high",
                "agentsStates": [
                    "child-1": ["status": "running"]
                ]
            ]
        ]

        var timeline = SubagentTimeline(sessionID: SessionID())
        for event in CodexSubagentEvent.events(
            method: "item/started",
            parameters: parameters,
            rootThreadID: "root"
        ) {
            timeline.apply(event)
        }

        XCTAssertEqual(timeline.workingCount, 1)
        XCTAssertEqual(timeline.doneCount, 0)
        let child = try XCTUnwrap(timeline.agents.first)
        XCTAssertEqual(child.descriptor.threadID, "child-1")
        XCTAssertEqual(child.descriptor.parentThreadID, "root")
        XCTAssertEqual(child.descriptor.prompt, "Audit the parser")
        XCTAssertEqual(child.descriptor.model, "gpt-5.6-sol")

        for event in CodexSubagentEvent.events(
            method: "turn/completed",
            parameters: [
                "threadId": "child-1",
                "turn": [
                    "id": "child-turn",
                    "items": [],
                    "status": "completed"
                ]
            ],
            rootThreadID: "root"
        ) {
            timeline.apply(event)
        }

        XCTAssertEqual(timeline.workingCount, 0)
        XCTAssertEqual(timeline.doneCount, 1)
        XCTAssertEqual(timeline.agents.first?.status, .completed)
    }

    func testChildAgentMessagesStayOutOfParentAndPopulateDrillIn() throws {
        let parameters: [String: Any] = [
            "threadId": "child-2",
            "turnId": "child-turn",
            "item": [
                "id": "message-2",
                "type": "agentMessage",
                "text": "Found a race in shutdown."
            ]
        ]
        let events = CodexSubagentEvent.events(
            method: "item/completed",
            parameters: parameters,
            rootThreadID: "root"
        )

        var timeline = SubagentTimeline(sessionID: SessionID())
        for event in events { timeline.apply(event) }

        let child = try XCTUnwrap(timeline.agents.first)
        XCTAssertEqual(
            child.conversation.rows,
            [.assistant(markdown: "Found a race in shutdown.")]
        )
    }

    func testLogicalCodexAgentPathIsNotStoredAsATranscriptFile() throws {
        let events = CodexSubagentEvent.events(
            method: "item/started",
            parameters: [
                "threadId": "root",
                "item": [
                    "id": "activity-1",
                    "type": "subAgentActivity",
                    "agentThreadId": "child-3",
                    "agentPath": "/root/review_pr612_codex",
                    "kind": "started"
                ]
            ],
            rootThreadID: "root"
        )

        var timeline = SubagentTimeline(sessionID: SessionID())
        for event in events { timeline.apply(event) }

        let child = try XCTUnwrap(timeline.agents.first)
        XCTAssertNil(child.descriptor.path)
        XCTAssertEqual(child.status, .working)
    }
}

@MainActor
final class AppEventTests: XCTestCase {

    func testTypedEventDeliversItsPayload() {
        let center = NotificationCenter()
        let observations = AppEventObservations(center: center)
        let sessionID = SessionID()
        var receivedSessionID: SessionID?

        observations.observe(TerminalSessionDidEnd.self) { event in
            receivedSessionID = event.sessionID
        }
        center.post(TerminalSessionDidEnd(sessionID: sessionID))

        XCTAssertEqual(receivedSessionID, sessionID)
    }

    func testObservationLifetimeUnregistersItsTokens() {
        let center = NotificationCenter()
        var deliveryCount = 0
        var observations: AppEventObservations? = AppEventObservations(center: center)

        observations?.observe(ProjectsDidChange.self) { _ in deliveryCount += 1 }
        center.post(ProjectsDidChange())
        observations = nil
        center.post(ProjectsDidChange())

        XCTAssertEqual(deliveryCount, 1)
    }
}
