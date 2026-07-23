import XCTest
@testable import Skalman

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
            guard case .turnFinished(let text, let isError, _) = event else { return }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(text, "claude exploded")
            XCTAssertTrue(isError)
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
        let duplicate = expectation(description: "duplicate terminal event")
        duplicate.isInverted = true
        var finishCount = 0

        let session = CodexStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "/bin/cat >/dev/null; "
                    + "printf '%s\\n' 'not-json'; "
                    + "printf '%s\\n' '{\"type\":\"turn.completed\"}'; "
                    + "printf 'unused diagnostic' >&2; exit 1"
            )
        }
        session.onEvent = { event in
            guard case .turnFinished = event else { return }
            XCTAssertTrue(Thread.isMainThread)
            finishCount += 1
            if finishCount == 1 {
                finished.fulfill()
            } else {
                duplicate.fulfill()
            }
        }

        session.start()
        XCTAssertTrue(session.send("test prompt"))

        wait(for: [finished, duplicate], timeout: 1)
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(session.malformedLineCount, 1)
        XCTAssertTrue(session.canSend)
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
                    + "'{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"skalman-ctrl-1\"}}'; "
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
                    + "\"request_id\":\"skalman-ctrl-1\",\"error\":\"unrecognized model\"}}'; "
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

    private func shellPlan(_ script: String) -> AgentLaunchPlan {
        AgentLaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", script],
            resumeState: .unavailable
        )
    }
}

final class ClaudeControlRequestTests: XCTestCase {

    func testSetModelProducesControlRequestEnvelope() throws {
        let data = try XCTUnwrap(ClaudeControlRequest.line(
            subtype: ClaudeControlRequest.setModel,
            requestID: "skalman-ctrl-3",
            body: ["model": "claude-sonnet-5"]
        ))
        XCTAssertEqual(data.last, 0x0A, "The line must be newline-terminated like a turn")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "control_request")
        XCTAssertEqual(object["request_id"] as? String, "skalman-ctrl-3")

        let request = try XCTUnwrap(object["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "set_model")
        XCTAssertEqual(request["model"] as? String, "claude-sonnet-5")
    }

    func testFastModeProducesApplyFlagSettingsEnvelope() throws {
        let data = try XCTUnwrap(ClaudeControlRequest.line(
            subtype: ClaudeControlRequest.applyFlagSettings,
            requestID: "skalman-ctrl-4",
            body: ["settings": ["fastMode": true]]
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try XCTUnwrap(object["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "apply_flag_settings")
        let settings = try XCTUnwrap(request["settings"] as? [String: Any])
        XCTAssertEqual(settings["fastMode"] as? Bool, true)
    }

    func testNilModelSerializesAsJSONNullToResetToDefault() throws {
        let data = try XCTUnwrap(ClaudeControlRequest.line(
            subtype: ClaudeControlRequest.setModel,
            requestID: "skalman-ctrl-5",
            body: ["model": NSNull()]
        ))
        // The CLI resets to the default on null; the key must be present as null, not omitted.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"model\":null"), "Expected a null model, got: \(text)")
    }

    func testControlResponseParsesSuccess() throws {
        let response = try XCTUnwrap(ControlResponse.parse(
            #"{"type":"control_response","response":{"subtype":"success","request_id":"skalman-ctrl-1"}}"#))
        XCTAssertEqual(response.requestID, "skalman-ctrl-1")
        XCTAssertFalse(response.isError)
    }

    func testControlResponseParsesErrorWithMessage() throws {
        let response = try XCTUnwrap(ControlResponse.parse(
            #"{"type":"control_response","response":{"subtype":"error","request_id":"skalman-ctrl-1","error":"unrecognized model"}}"#))
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
        XCTAssertEqual(input["command"] as? String, "echo hi")
        XCTAssertEqual((input["options"] as? [String: Any])?["quiet"] as? Bool, true)
        XCTAssertEqual(input["retries"] as? Int, 2)

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
        XCTAssertEqual(input["selector"] as? String, "#main")

        let failed = try onlyEvent(CodexStreamEvent.parse("""
            {"type":"turn.failed","error":{"message":"sandbox denied","code":17}}
            """))
        guard case .turnFinished(let text, let isError, _) = failed else {
            return XCTFail("Expected failed Codex turn")
        }
        XCTAssertEqual(text, "sandbox denied")
        XCTAssertTrue(isError)
    }

    func testBothProvidersDecodeExactTurnReceipts() throws {
        let claude = try onlyEvent(StreamEvent.parse("""
            {"type":"result","is_error":false,"duration_ms":89432,
             "usage":{"input_tokens":12000,"output_tokens":3149}}
            """))
        guard case .turnFinished(_, false, let claudeMetrics) = claude else {
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
        guard case .turnFinished(_, false, let codexMetrics) = codex else {
            return XCTFail("Expected Codex result")
        }
        XCTAssertNil(codexMetrics.duration, "Codex duration comes from the wrapper's local clock")
        XCTAssertEqual(codexMetrics.outputTokens, 3_149)
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
