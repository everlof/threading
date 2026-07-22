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
            guard case .turnFinished(let text, let isError) = event else { return }
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

    private func shellPlan(_ script: String) -> AgentLaunchPlan {
        AgentLaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", script],
            resumeState: .unavailable
        )
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
              case .toolUse(let id, let name, let input) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected Claude tool call")
        }
        XCTAssertEqual(id, "call-1")
        XCTAssertEqual(name, "Bash")
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
              case .toolUse(let id, let name, let input) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected Codex MCP tool call")
        }
        XCTAssertEqual(id, "call-2")
        XCTAssertEqual(name, "mcp__web__query")
        XCTAssertEqual(input["selector"] as? String, "#main")

        let failed = try onlyEvent(CodexStreamEvent.parse("""
            {"type":"turn.failed","error":{"message":"sandbox denied","code":17}}
            """))
        guard case .turnFinished(let text, let isError) = failed else {
            return XCTFail("Expected failed Codex turn")
        }
        XCTAssertEqual(text, "sandbox denied")
        XCTAssertTrue(isError)
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
