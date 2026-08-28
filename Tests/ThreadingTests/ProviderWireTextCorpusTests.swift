import XCTest
@testable import Threading

/// Pushes realistic payloads **as JSON text** through the five provider adapters that were not
/// converted to typed values, and renders what comes back.
///
/// The point is the medium, not the coverage. Every other test of these readers builds its
/// payload from Swift dictionary literals, where `1` is an `Int` and `true` is a `Bool`; on the
/// wire both are `NSNumber`, and several of the casts under test answer differently for the two.
/// `JSONValue` reading every JSON `0` as `false` and every `1` as `true` reached the
/// execution-audit ledger and was invisible to every literal-built test in the suite. This file
/// exists so the next one is not.
///
/// The corpus is written to `provider-wire-text-corpus.txt` under `THREADING_RENDER_OUT` (the
/// same evidence root the rendered-state tests use) and printed to the test log, so two builds
/// can be diffed line by line.
final class ProviderWireTextCorpusTests: XCTestCase {

    // MARK: - Corpus

    func testRendersTheProviderWireTextCorpus() {
        let text = ProviderWireTextCorpus.render()
        XCTAssertFalse(text.isEmpty)
        print("PROVIDER-WIRE-CORPUS-BEGIN")
        print(text)
        print("PROVIDER-WIRE-CORPUS-END")

        // Best effort: the printed corpus above is the evidence. The render root is not
        // always writable from the test host, and a corpus that rendered is not a failure.
        guard let root = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] else { return }
        let url = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("provider-wire-text-corpus.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - The findings this corpus produced

    /// A JSON `0` in `willRetry` reads as `false`, so a retry notification settles the turn.
    ///
    /// Written as a Swift literal, `["willRetry": 0]` casts to `nil` and the same line produces
    /// no event at all — which is why no existing test sees this.
    func testCodexRetryNotificationSettlesTheTurnWhenWillRetryIsZero() {
        let fromText = ProviderWireTextCorpus.codexStreamEvents(
            method: "error",
            #"{"threadId":"t1","willRetry":0,"error":{"message":"rate limited, retrying"}}"#
        )
        XCTAssertEqual(fromText.count, 1)
        guard case .turnFinished(_, let outcome, _)? = fromText.first else {
            return XCTFail("expected a terminal event, got \(fromText)")
        }
        XCTAssertEqual(outcome, .failed)

        let fromLiteral = CodexAppServerEvent.streamEvents(
            method: "error",
            parameters: ["threadId": "t1", "willRetry": 0, "error": ["message": "x"]]
        )
        XCTAssertEqual(fromLiteral.count, 0, "the literal path cannot observe this")
    }

    /// A boolean tool payload renders as `"1"`, not `"true"`.
    func testCodexBooleanToolOutputRendersAsOne() {
        let events = ProviderWireTextCorpus.codexStreamEvents(
            method: "item/completed",
            #"{"threadId":"t1","item":{"id":"d1","type":"dynamicToolCall","status":"completed","success":true}}"#
        )
        guard case .toolResults(let results)? = events.first, let result = results.first else {
            return XCTFail("expected a tool result, got \(events)")
        }
        XCTAssertEqual(result.text, "1")
    }

    /// A token count of `true` is counted as one token, and a count past `Int64` wraps negative.
    func testCodexTokenCountsAcceptABooleanAndWrapALargeInteger() {
        let events = ProviderWireTextCorpus.codexStreamEvents(
            method: "turn/completed",
            #"{"threadId":"t1","turn":{"id":"x","status":"completed","durationMs":true}}"#
        )
        guard case .turnFinished(_, _, let metrics)? = events.first else {
            return XCTFail("expected a terminal event, got \(events)")
        }
        XCTAssertNil(metrics.duration, "the guarded reader refuses a boolean duration")

        let wrapped = ProviderWireTextCorpus.codexStreamEvents(
            method: "turn/completed",
            #"{"threadId":"t1","turn":{"id":"x","status":"completed","durationMs":12345678901234567890}}"#
        )
        guard case .turnFinished(_, _, let wrappedMetrics)? = wrapped.first else {
            return XCTFail("expected a terminal event, got \(wrapped)")
        }
        XCTAssertNotNil(wrappedMetrics.duration)
        XCTAssertLessThan(
            wrappedMetrics.duration ?? 0, 0,
            "an integer past Int64 wraps to a negative duration rather than being refused"
        )
    }

    /// A JSON `null` beside a tool result is a present value, so a successful call reads as
    /// failed. A Swift dictionary literal cannot express this at all.
    func testTranscriptReplayReadsAnExplicitNullErrorAsAFailure() {
        let record = ProviderWireTextCorpus.object("""
        {"type":"response_item","payload":{"type":"function_call_output",
         "call_id":"c1","output":"done","error":null}}
        """)
        guard case .toolResults(let results)? = TranscriptReplay.codexEvent(from: record),
              let result = results.first else {
            return XCTFail("expected a tool result")
        }
        XCTAssertEqual(result.toolUseID, "c1")
        XCTAssertTrue(result.isError, "an explicit JSON null marks a successful call as failed")
    }

    /// `isSidechain: 1` hides an assistant turn that `isSidechain: true` would also hide — but
    /// a literal `1` does not, so the literal-built tests never see the record being dropped.
    func testTranscriptReplayTreatsANumericSidechainFlagAsTrue() throws {
        let directory = try ProviderWireTextCorpus.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("numeric-flag.jsonl")
        try #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","isSidechain":1,"message":{"content":[{"type":"text","text":"hidden"}]}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:01Z","isSidechain":2,"message":{"content":[{"type":"text","text":"shown"}]}}
        """#.write(to: url, atomically: true, encoding: .utf8)

        let (events, _) = TranscriptReplay.read(at: url, kind: .claude)
        let texts = events.flatMap { event -> [String] in
            guard case .assistantMessage(let blocks) = event else { return [] }
            return blocks.compactMap { block in
                guard case .text(let value) = block else { return nil }
                return value
            }
        }
        XCTAssertEqual(texts, ["shown"], "1 bridges to true and is dropped; 2 does not bridge")
    }

    /// A token count of `true` is counted as one context token where there should be none.
    ///
    /// A replayed turn only reports metrics once a user record has opened it, so the fixture
    /// carries the opening record: without it there is no `.turnFinished` to read at all and
    /// the reading is invisible rather than wrong.
    func testTranscriptReplayCountsABooleanAsOneContextToken() throws {
        let directory = try ProviderWireTextCorpus.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(ProviderWireTextCorpus.write(#"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","message":{"usage":{"input_tokens":true,"output_tokens":false},"content":[{"type":"text","text":"hi"}]}}
        """#, to: directory, named: "boolean-usage.jsonl"))

        let (events, _) = TranscriptReplay.read(at: url, kind: .claude)
        let readings = events.compactMap { event -> Int? in
            guard case .turnFinished(_, _, let metrics) = event else { return nil }
            return metrics.contextTokens
        }
        XCTAssertEqual(readings, [1], "a boolean input_tokens is counted as one token")
    }

    /// A reported cost of `false` prices a real response at zero and stops the catalogue from
    /// ever pricing it.
    func testClaudeUsageReadsABooleanCostAsAReportedZero() throws {
        let directory = try ProviderWireTextCorpus.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boolean-cost.jsonl")
        try #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r1","costUSD":false,"cwd":"/tmp","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":200}}}
        """#.write(to: url, atomically: true, encoding: .utf8)

        let records = ClaudeUsageAdapter.records(
            inTranscriptAt: url, accountID: "a", accountName: "A"
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.reportedCostUSD, 0)
        XCTAssertEqual(records.first?.tokens.output, 200)
    }

    /// A quoted token count is read as zero while a quoted cost parses, so a provider that
    /// quotes its numbers loses every token and keeps its money.
    func testOpenCodeUsageDisagreesWithItselfAboutQuotedNumbers() throws {
        let data = Data(#"""
        {"info":{"id":"s1","directory":"/tmp"},"messages":[{"info":{
          "id":"m1","role":"assistant","providerID":"anthropic","modelID":"claude-sonnet-4-5",
          "cost":"1.50","tokens":{"input":"12500.0","output":"600","reasoning":0,
          "cache":{"read":0,"write":0}},"time":{"created":1754654400}}}]}
        """#.utf8)

        let records = try OpenCodeUsageAdapter.records(fromExport: data)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.reportedCostUSD, 1.5)
        XCTAssertEqual(records.first?.tokens.uncachedInput, 0, "\"12500.0\" is not an Int64")
        XCTAssertEqual(records.first?.tokens.output, 600, "\"600\" is")
    }

    /// One `null` in the message array throws away the whole export.
    func testOpenCodeUsageThrowsAwayTheWholeExportForOneNullMessage() {
        let data = Data(#"""
        {"info":{"id":"s1","directory":"/tmp"},"messages":[{"info":{
          "id":"m1","role":"assistant","providerID":"anthropic","modelID":"m",
          "tokens":{"input":1000,"output":50},"time":{"created":1754654400}}}, null]}
        """#.utf8)

        XCTAssertThrowsError(try OpenCodeUsageAdapter.records(fromExport: data))
    }

    /// A response id of `1.5` resolves the pending request numbered `1`.
    func testEnvelopeTruncatesAFractionalRequestIdentifier() {
        guard case .response(let id, _, _)? =
                JSONRPCLineEnvelope.parse(#"{"id":1.5,"result":{"ok":true}}"#) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(id, .integer(1))
    }

    /// A capability list with one non-string element is discarded whole.
    func testClaudeCapabilityListIsAllOrNothing() {
        let update = ClaudeCapabilityWire.update(
            from: #"{"type":"system","subtype":"init","slash_commands":["a","b"],"skills":["b",7]}"#
        )
        XCTAssertEqual(update?.commandNames, ["a", "b"])
        XCTAssertNil(update?.skillNames, "one number removes every skill name, not just itself")
    }
}

// MARK: - Corpus

enum ProviderWireTextCorpus {

    // MARK: - Rendering

    static func render() -> String {
        var lines: [String] = ["# Provider wire corpus, built from JSON text"]
        lines.append(contentsOf: envelopeSection())
        lines.append(contentsOf: codexAppServerSection())
        lines.append(contentsOf: codexSubagentSection())
        lines.append(contentsOf: claudeStreamSection())
        lines.append(contentsOf: transcriptReplaySection())
        lines.append(contentsOf: usageSection())
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - JSON-RPC envelope (the Codex session's line reader)

    private static let envelopeLines: [(String, String)] = [
        ("not-json", "hello"),
        ("array-root", "[1,2]"),
        ("notification", #"{"method":"turn/started","params":{"threadId":"t1"}}"#),
        ("positional-params", #"{"method":"turn/completed","params":[{"id":"t1"}]}"#),
        ("null-params", #"{"method":"turn/completed","params":null}"#),
        ("id-string", #"{"id":"a","result":{}}"#),
        ("id-integer", #"{"id":1,"result":{}}"#),
        ("id-fraction", #"{"id":1.5,"result":{}}"#),
        ("id-huge", #"{"id":9223372036854775808,"result":{}}"#),
        ("id-true", #"{"id":true,"result":{}}"#),
        ("id-null", #"{"id":null,"result":{}}"#),
        ("error-string", #"{"id":1,"error":"nope"}"#),
        ("error-object", #"{"id":1,"error":{"message":"nope","code":-32000}}"#),
        ("error-no-message", #"{"id":1,"error":{"code":-32000}}"#)
    ]

    private static let encodedScalars: [(String, String)] = [
        ("true", "true"),
        ("false", "false"),
        ("zero", "0"),
        ("one", "1"),
        ("float", "1.0"),
        ("string", #""text""#),
        ("null", "null"),
        ("object", #"{"a":1}"#),
        ("array", "[1,true]")
    ]

    private static func envelopeSection() -> [String] {
        var lines = ["", "## JSONRPCLineEnvelope.parse"]
        for (name, text) in envelopeLines {
            lines.append("\(name) -> \(describe(JSONRPCLineEnvelope.parse(text)))")
        }
        lines.append("")
        lines.append("## JSONRPCLineEnvelope.encodedText (what a tool payload renders as)")
        for (name, text) in encodedScalars {
            let value = try? JSONSerialization.jsonObject(
                with: Data(text.utf8), options: [.fragmentsAllowed]
            )
            lines.append("\(name) -> \(quoted(JSONRPCLineEnvelope.encodedText(value)))")
        }
        return lines
    }

    // MARK: - Codex app-server notifications

    private static let codexNotifications: [(String, String, String)] = [
        ("delta-text", "item/agentMessage/delta", #"{"threadId":"t1","delta":"hello"}"#),
        ("delta-number", "item/agentMessage/delta", #"{"threadId":"t1","delta":7}"#),

        ("plan-standard", "turn/plan/updated", """
        {"threadId":"t1","plan":[{"step":"Read","status":"pending"},
                                 {"step":"Edit","status":"in_progress"}]}
        """),
        ("plan-unknown-status", "turn/plan/updated", """
        {"threadId":"t1","plan":[{"step":"Read","status":"pending"},
                                 {"step":"Blocked","status":"blocked"}]}
        """),
        ("plan-numeric-status", "turn/plan/updated",
         #"{"threadId":"t1","plan":[{"step":"Read","status":0}]}"#),
        ("plan-null-element", "turn/plan/updated",
         #"{"threadId":"t1","plan":[{"step":"Read","status":"pending"},null]}"#),

        ("turn-completed", "turn/completed",
         #"{"threadId":"t1","turn":{"id":"x","status":"completed","durationMs":1500}}"#),
        ("turn-duration-float", "turn/completed",
         #"{"threadId":"t1","turn":{"id":"x","status":"completed","durationMs":1500.9}}"#),
        ("turn-duration-true", "turn/completed",
         #"{"threadId":"t1","turn":{"id":"x","status":"completed","durationMs":true}}"#),
        ("turn-duration-huge", "turn/completed",
         #"{"threadId":"t1","turn":{"id":"x","status":"completed","durationMs":12345678901234567890}}"#),
        ("turn-duration-string", "turn/completed",
         #"{"threadId":"t1","turn":{"id":"x","status":"completed","durationMs":"1500"}}"#),
        ("turn-status-unknown", "turn/completed",
         #"{"threadId":"t1","turn":{"id":"x","status":"exploded"}}"#),
        ("turn-status-missing", "turn/completed", #"{"threadId":"t1","turn":{"id":"x"}}"#),

        ("error-will-retry-true", "error",
         #"{"threadId":"t1","willRetry":true,"error":{"message":"retrying"}}"#),
        ("error-will-retry-false", "error",
         #"{"threadId":"t1","willRetry":false,"error":{"message":"gave up"}}"#),
        ("error-will-retry-zero", "error",
         #"{"threadId":"t1","willRetry":0,"error":{"message":"retrying"}}"#),
        ("error-will-retry-one", "error",
         #"{"threadId":"t1","willRetry":1,"error":{"message":"retrying"}}"#),
        ("error-will-retry-string", "error",
         #"{"threadId":"t1","willRetry":"false","error":{"message":"gave up"}}"#),
        ("error-will-retry-missing", "error",
         #"{"threadId":"t1","error":{"message":"gave up"}}"#),

        ("reasoning-strings", "item/completed",
         #"{"threadId":"t1","item":{"id":"r1","type":"reasoning","summary":["a","b"]}}"#),
        ("reasoning-mixed", "item/completed",
         #"{"threadId":"t1","item":{"id":"r1","type":"reasoning","summary":["a",1]}}"#),
        ("reasoning-objects", "item/completed",
         #"{"threadId":"t1","item":{"id":"r1","type":"reasoning","summary":[{"text":"a"}]}}"#),

        ("tool-numeric-id", "item/started",
         #"{"threadId":"t1","item":{"id":12,"type":"commandExecution","command":"ls"}}"#),
        ("tool-command-array", "item/started",
         #"{"threadId":"t1","item":{"id":"c1","type":"commandExecution","command":["bash","-lc","ls"]}}"#),
        ("tool-arguments-object", "item/started",
         #"{"threadId":"t1","item":{"id":"m1","type":"mcpToolCall","server":"s","tool":"t","arguments":{"n":1,"flag":true,"f":2.0}}}"#),
        ("tool-arguments-string", "item/started",
         #"{"threadId":"t1","item":{"id":"m2","type":"mcpToolCall","server":"s","tool":"t","arguments":"{\"n\":1}"}}"#),
        ("tool-arguments-broken-string", "item/started",
         #"{"threadId":"t1","item":{"id":"m3","type":"mcpToolCall","server":"s","tool":"t","arguments":"not json"}}"#),
        ("tool-arguments-big-integer", "item/started",
         #"{"threadId":"t1","item":{"id":"m4","type":"mcpToolCall","server":"s","tool":"t","arguments":{"n":9223372036854775808}}}"#),

        ("result-exit-zero", "item/completed",
         #"{"threadId":"t1","item":{"id":"c1","type":"commandExecution","status":"completed","exitCode":0,"aggregatedOutput":"ok"}}"#),
        ("result-exit-one", "item/completed",
         #"{"threadId":"t1","item":{"id":"c1","type":"commandExecution","status":"completed","exitCode":1,"aggregatedOutput":"bad"}}"#),
        ("result-exit-true", "item/completed",
         #"{"threadId":"t1","item":{"id":"c1","type":"commandExecution","status":"completed","exitCode":true,"aggregatedOutput":"bad"}}"#),
        ("result-exit-float", "item/completed",
         #"{"threadId":"t1","item":{"id":"c1","type":"commandExecution","status":"completed","exitCode":0.4,"aggregatedOutput":"bad"}}"#),
        ("result-exit-string", "item/completed",
         #"{"threadId":"t1","item":{"id":"c1","type":"commandExecution","status":"completed","exitCode":"1","aggregatedOutput":"bad"}}"#),
        ("result-success-true", "item/completed",
         #"{"threadId":"t1","item":{"id":"d1","type":"dynamicToolCall","status":"completed","success":true}}"#),
        ("result-success-zero", "item/completed",
         #"{"threadId":"t1","item":{"id":"d1","type":"dynamicToolCall","status":"completed","success":0}}"#),
        ("result-output-number", "item/completed",
         #"{"threadId":"t1","item":{"id":"d2","type":"dynamicToolCall","status":"completed","aggregatedOutput":1.0}}"#),
        ("result-status-true", "item/completed",
         #"{"threadId":"t1","item":{"id":"d3","type":"dynamicToolCall","status":true}}"#)
    ]

    private static func codexAppServerSection() -> [String] {
        var lines = ["", "## CodexAppServerEvent.streamEvents"]
        for (name, method, text) in codexNotifications {
            let events = codexStreamEvents(method: method, text)
            lines.append("\(name) -> [\(events.map(describe).joined(separator: ", "))]")
        }
        lines.append("")
        lines.append("## CodexProviderExecutionAdapter.events (the audit ledger's copy)")
        for (name, method, text) in codexNotifications where method == "item/completed" {
            let events = CodexProviderExecutionAdapter.events(
                method: method, parameters: object(text)
            )
            lines.append("\(name) -> [\(events.map(describe).joined(separator: ", "))]")
        }
        return lines
    }

    static func codexStreamEvents(method: String, _ text: String) -> [StreamEvent] {
        CodexAppServerEvent.streamEvents(method: method, parameters: object(text))
    }

    // MARK: - Codex subagent notifications

    private static let codexSubagentNotifications: [(String, String, String)] = [
        ("thread-started", "thread/started",
         #"{"thread":{"id":"c1","parentThreadId":"t1","agentNickname":"Scout","agentRole":"reader"}}"#),
        ("thread-numeric-parent", "thread/started",
         #"{"thread":{"id":"c1","parentThreadId":5,"agentNickname":"Scout"}}"#),
        ("collab-receivers", "item/started", """
        {"threadId":"t1","item":{"type":"collabAgentToolCall","senderThreadId":"t1",
         "receiverThreadIds":["c1","c2"],"prompt":"go","model":"m",
         "agentsStates":{"c1":{"status":"running"},"c2":{"status":"completed"}}}}
        """),
        ("collab-receivers-null", "item/started", """
        {"threadId":"t1","item":{"type":"collabAgentToolCall","senderThreadId":"t1",
         "receiverThreadIds":["c1",null],"prompt":"go"}}
        """),
        ("collab-states-null", "item/started", """
        {"threadId":"t1","item":{"type":"collabAgentToolCall","senderThreadId":"t1",
         "receiverThreadIds":["c1","c2"],"prompt":"go",
         "agentsStates":{"c1":{"status":"running"},"c2":null}}}
        """),
        ("child-turn-failed", "turn/completed",
         #"{"threadId":"c1","turn":{"id":"x","status":"failed","error":{"message":"boom"}}}"#)
    ]

    private static func codexSubagentSection() -> [String] {
        var lines = ["", "## CodexSubagentEvent.events (rootThreadID = t1)"]
        for (name, method, text) in codexSubagentNotifications {
            let events = CodexSubagentEvent.events(
                method: method, parameters: object(text), rootThreadID: "t1"
            )
            lines.append("\(name) -> [\(events.map { String(describing: $0) }.joined(separator: ", "))]")
        }
        return lines
    }

    // MARK: - Claude stream session line readers

    private static let claudeControlResponses: [(String, String)] = [
        ("success", #"{"type":"control_response","response":{"subtype":"success","request_id":"r1"}}"#),
        ("numeric-request-id", #"{"type":"control_response","response":{"subtype":"success","request_id":3}}"#),
        ("error-string", #"{"type":"control_response","response":{"subtype":"error","request_id":"r1","error":"no"}}"#),
        ("error-object", #"{"type":"control_response","response":{"subtype":"error","request_id":"r1","error":{"message":"no"}}}"#),
        ("cancelled-true", #"{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"cancelled":true}}}"#),
        ("cancelled-one", #"{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"cancelled":1}}}"#),
        ("cancelled-zero", #"{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"cancelled":0}}}"#),
        ("cancelled-two", #"{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"cancelled":2}}}"#),
        ("cancelled-string", #"{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"cancelled":"true"}}}"#)
    ]

    private static let claudeLifecycleLines: [(String, String)] = [
        ("started", #"{"type":"command_lifecycle","command_uuid":"6C2E4A18-0000-4000-8000-000000000001","state":"started"}"#),
        ("numeric-uuid", #"{"type":"command_lifecycle","command_uuid":1,"state":"started"}"#),
        ("unknown-state", #"{"type":"command_lifecycle","command_uuid":"6C2E4A18-0000-4000-8000-000000000001","state":"paused"}"#),
        ("null-state", #"{"type":"command_lifecycle","command_uuid":"6C2E4A18-0000-4000-8000-000000000001","state":null}"#)
    ]

    private static let claudeCapabilityLines: [(String, String)] = [
        ("init-standard", #"{"type":"system","subtype":"init","slash_commands":["a","b"],"skills":["b"]}"#),
        ("init-skill-number", #"{"type":"system","subtype":"init","slash_commands":["a","b"],"skills":["b",7]}"#),
        ("init-skill-null", #"{"type":"system","subtype":"init","slash_commands":["a"],"skills":["b",null]}"#),
        ("init-commands-number", #"{"type":"system","subtype":"init","slash_commands":["a",2]}"#),
        ("init-capabilities-number", #"{"type":"system","subtype":"init","capabilities":["interrupt_receipt_v1",1]}"#),
        ("changed-standard", #"{"type":"system","subtype":"commands_changed","commands":[{"name":"ctx","description":"Context","aliases":["c"]}]}"#),
        ("changed-numeric-description", #"{"type":"system","subtype":"commands_changed","commands":[{"name":"ctx","description":42,"argumentHint":7}]}"#),
        ("changed-alias-number", #"{"type":"system","subtype":"commands_changed","commands":[{"name":"ctx","aliases":["c",7]}]}"#),
        ("changed-scalar-array", #"{"type":"system","subtype":"commands_changed","commands":["ctx"]}"#)
    ]

    private static func claudeStreamSection() -> [String] {
        var lines = ["", "## ControlResponse.parse"]
        for (name, text) in claudeControlResponses {
            let response = ControlResponse.parse(text)
            let cancelled = response?.payload?["cancelled"] as? Bool
            lines.append(
                "\(name) -> id=\(optional(response?.requestID)) isError=\(response.map { String($0.isError) } ?? "nil") "
                + "error=\(optional(response?.error)) cancelled=\(cancelled.map(String.init) ?? "nil")"
            )
        }

        lines.append("")
        lines.append("## ClaudeMessageLifecycleRecord.parse")
        for (name, text) in claudeLifecycleLines {
            let record = ClaudeMessageLifecycleRecord.parse(text)
            lines.append("\(name) -> \(record.map { "\($0.id.wireValue) \($0.state)" } ?? "nil")")
        }

        lines.append("")
        lines.append("## ClaudeCapabilityWire.update")
        for (name, text) in claudeCapabilityLines {
            guard let update = ClaudeCapabilityWire.update(from: text) else {
                lines.append("\(name) -> nil")
                continue
            }
            let commands = update.commands?.map {
                "(\($0.name), \(quoted($0.description)), \(quoted($0.argumentHint)), \($0.aliases))"
            }
            lines.append(
                "\(name) -> names=\(update.commandNames.map { String(describing: $0) } ?? "nil") "
                + "skills=\(update.skillNames.map { String(describing: $0) } ?? "nil") "
                + "commands=\(commands.map { "[\($0.joined(separator: ", "))]" } ?? "nil")"
            )
        }

        lines.append("")
        lines.append("## ClaudeProviderExecutionAdapter.events (the audit ledger's copy)")
        for (name, text) in claudeExecutionLines {
            let events = ClaudeProviderExecutionAdapter.events(line: text)
            lines.append("\(name) -> [\(events.map(describe).joined(separator: ", "))]")
        }
        return lines
    }

    private static let claudeExecutionLines: [(String, String)] = [
        ("tool-use", #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls","timeout":2.0}}]}}"#),
        ("tool-use-big", #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"n":9223372036854775808}}]}}"#),
        ("result-error-true", #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"x"}]}}"#),
        ("result-error-one", #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":1,"content":"x"}]}}"#),
        ("result-error-zero", #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":0,"content":"x"}]}}"#),
        ("result-error-two", #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":2,"content":"x"}]}}"#)
    ]

    // MARK: - Transcript replay

    private static let claudeTranscripts: [(String, String)] = [
        ("plain", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","message":{"usage":{"input_tokens":100,"output_tokens":20},"content":[{"type":"text","text":"hello"}]}}
        """#),
        ("usage-boolean", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","message":{"usage":{"input_tokens":true,"output_tokens":false},"content":[{"type":"text","text":"hello"}]}}
        """#),
        ("usage-float", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","message":{"usage":{"input_tokens":1200.9,"output_tokens":10},"content":[{"type":"text","text":"hello"}]}}
        """#),
        ("usage-huge", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","message":{"usage":{"input_tokens":12345678901234567890,"output_tokens":10},"content":[{"type":"text","text":"hello"}]}}
        """#),
        ("sidechain-one", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","isSidechain":1,"message":{"content":[{"type":"text","text":"hidden"}]}}
        """#),
        ("sidechain-two", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","isSidechain":2,"message":{"content":[{"type":"text","text":"shown"}]}}
        """#),
        ("meta-one", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","isMeta":1,"message":{"content":[{"type":"text","text":"hidden"}]}}
        """#),
        ("content-null-element", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","message":{"content":[{"type":"text","text":"kept?"},null]}}
        """#),
        ("content-string-element", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","message":{"content":["plain"]}}
        """#),
        ("text-number", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","message":{"content":[{"type":"text","text":123}]}}
        """#),
        ("tool-result-error-one", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"user","timestamp":"2026-08-27T10:00:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok","is_error":1}]}}
        """#),
        ("timestamp-number", #"""
        {"type":"user","timestamp":"2026-08-27T09:59:59Z","message":{"content":"go"}}
        {"type":"assistant","timestamp":1712345678,"message":{"usage":{"input_tokens":5},"content":[{"type":"text","text":"hello"}]}}
        """#)
    ]

    private static let codexTranscripts: [(String, String)] = [
        ("message", #"""
        {"type":"event_msg","timestamp":"2026-08-27T09:59:59Z","payload":{"type":"user_message","message":"go"}}
        {"type":"event_msg","timestamp":"2026-08-27T10:00:00Z","payload":{"type":"agent_message","message":"hi"}}
        """#),
        ("message-number", #"""
        {"type":"event_msg","timestamp":"2026-08-27T09:59:59Z","payload":{"type":"user_message","message":"go"}}
        {"type":"event_msg","timestamp":"2026-08-27T10:00:00Z","payload":{"type":"agent_message","message":42}}
        """#),
        ("call-output-null-error", #"""
        {"type":"response_item","timestamp":"2026-08-27T10:00:00Z","payload":{"type":"function_call_output","call_id":"c1","output":"done","error":null}}
        """#),
        ("call-output-error", #"""
        {"type":"response_item","timestamp":"2026-08-27T10:00:00Z","payload":{"type":"function_call_output","call_id":"c1","output":"","error":"boom"}}
        """#),
        ("call-input-null", #"""
        {"type":"response_item","timestamp":"2026-08-27T10:00:00Z","payload":{"type":"function_call","call_id":"c2","name":"exec","input":null,"arguments":"{\"cmd\":\"ls -la\"}"}}
        """#),
        ("call-arguments", #"""
        {"type":"response_item","timestamp":"2026-08-27T10:00:00Z","payload":{"type":"function_call","call_id":"c3","name":"exec","arguments":"{\"cmd\":\"ls\",\"path\":null,\"file_path\":\"/tmp/a.txt\"}"}}
        """#),
        ("token-count-boolean", #"""
        {"type":"event_msg","timestamp":"2026-08-27T09:59:59Z","payload":{"type":"user_message","message":"go"}}
        {"type":"turn_context","timestamp":"2026-08-27T10:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":true},"model_context_window":true}}}
        """#),
        ("token-count-real", #"""
        {"type":"event_msg","timestamp":"2026-08-27T09:59:59Z","payload":{"type":"user_message","message":"go"}}
        {"type":"turn_context","timestamp":"2026-08-27T10:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":40000},"model_context_window":200000}}}
        """#)
    ]

    private static func transcriptReplaySection() -> [String] {
        var lines = ["", "## TranscriptReplay.read (claude)"]
        guard let directory = try? temporaryDirectory() else {
            return lines + ["(could not make a temporary directory)"]
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        for (name, text) in claudeTranscripts {
            lines.append("\(name) -> \(replay(text, kind: .claude, in: directory, named: name))")
        }
        lines.append("")
        lines.append("## TranscriptReplay.read (codex)")
        for (name, text) in codexTranscripts {
            lines.append("\(name) -> \(replay(text, kind: .codex, in: directory, named: name))")
        }
        lines.append("")
        lines.append("## TranscriptReplay.toolCalls (codex)")
        for (name, text) in codexTranscripts {
            guard let url = write(text, to: directory, named: "calls-\(name).jsonl") else {
                continue
            }
            let scan = TranscriptReplay.toolCalls(at: url, kind: .codex, from: 0)
            let calls = scan.calls.map { "(\($0.callID), \($0.tool.rawName), \(canon($0.input)))" }
            lines.append("\(name) -> [\(calls.joined(separator: ", "))]")
        }
        return lines
    }

    private static func replay(
        _ text: String, kind: AgentKind, in directory: URL, named name: String
    ) -> String {
        guard let url = write(text, to: directory, named: "\(kind.rawValue)-\(name).jsonl") else {
            return "(could not write)"
        }
        let (events, truncated) = TranscriptReplay.read(at: url, kind: kind)
        return "[\(events.map(describe).joined(separator: ", "))] truncated=\(truncated)"
    }

    // MARK: - Usage adapters

    private static let claudeUsageLines: [(String, String)] = [
        ("plain", #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r1","cwd":"/tmp","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"cache_read_input_tokens":10,"cache_creation_input_tokens":5,"output_tokens":200}}}
        """#),
        ("cost-false", #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r1","costUSD":false,"cwd":"/tmp","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":200}}}
        """#),
        ("cost-true", #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r2","costUSD":true,"cwd":"/tmp","message":{"id":"m2","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":200}}}
        """#),
        ("cost-string", #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r3","costUSD":"0.25","cwd":"/tmp","message":{"id":"m3","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":200}}}
        """#),
        ("tokens-boolean", #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r4","cwd":"/tmp","message":{"id":"m4","model":"claude-sonnet-4-5","usage":{"input_tokens":true,"output_tokens":false}}}
        """#),
        ("tokens-float", #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r5","cwd":"/tmp","message":{"id":"m5","model":"claude-sonnet-4-5","usage":{"input_tokens":4096.9,"output_tokens":10}}}
        """#),
        ("tokens-quoted", #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r6","cwd":"/tmp","message":{"id":"m6","model":"claude-sonnet-4-5","usage":{"input_tokens":"12500","output_tokens":"12500.0"}}}
        """#),
        ("tokens-huge", #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r7","cwd":"/tmp","message":{"id":"m7","model":"claude-sonnet-4-5","usage":{"input_tokens":12345678901234567890,"output_tokens":10}}}
        """#),
        ("model-null", #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r8","cwd":"/tmp","message":{"id":"m8","model":null,"usage":{"input_tokens":10,"output_tokens":10}}}
        """#),
        ("timestamp-null", #"""
        {"type":"assistant","timestamp":null,"requestId":"r9","cwd":"/tmp","message":{"id":"m9","model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":10}}}
        """#),
        ("cache-1h-without-write", #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r10","cwd":"/tmp","message":{"id":"m10","model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":10,"cache_creation":{"ephemeral_1h_input_tokens":5000}}}}
        """#),
        ("duplicate-key", #"""
        {"type":"assistant","timestamp":"2026-08-27T10:00:00Z","requestId":"r11","cwd":"/tmp","message":{"id":"m11","model":"claude-sonnet-4-5","usage":{"output_tokens":10,"output_tokens":9999999}}}
        """#)
    ]

    private static let codexUsageLines: [(String, String)] = [
        ("plain", #"""
        {"type":"session_meta","timestamp":"2026-08-27T10:00:00Z","payload":{"id":"s1","cwd":"/tmp","model":"gpt-5"}}
        {"type":"event_msg","timestamp":"2026-08-27T10:00:01Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":50,"reasoning_output_tokens":10}}}}
        """#),
        ("tokens-boolean", #"""
        {"type":"session_meta","timestamp":"2026-08-27T10:00:00Z","payload":{"id":"s2","cwd":"/tmp","model":"gpt-5"}}
        {"type":"event_msg","timestamp":"2026-08-27T10:00:01Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":true,"cached_input_tokens":false,"output_tokens":true}}}}
        """#),
        ("tokens-float-subtraction", #"""
        {"type":"session_meta","timestamp":"2026-08-27T10:00:00Z","payload":{"id":"s3","cwd":"/tmp","model":"gpt-5"}}
        {"type":"event_msg","timestamp":"2026-08-27T10:00:01Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100.4,"cached_input_tokens":100.6,"output_tokens":10}}}}
        """#),
        ("dedup-saturating-signature", #"""
        {"type":"session_meta","timestamp":"2026-08-27T10:00:00Z","payload":{"id":"s4","cwd":"/tmp","model":"gpt-5"}}
        {"type":"event_msg","timestamp":"2026-08-27T10:00:01Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":5},"total_token_usage":{"input_tokens":12345678901234567890,"output_tokens":1}}}}
        {"type":"event_msg","timestamp":"2026-08-27T10:00:02Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"output_tokens":7},"total_token_usage":{"input_tokens":22345678901234567890,"output_tokens":1}}}}
        """#)
    ]

    private static let openCodeExports: [(String, String)] = [
        ("plain", #"""
        {"info":{"id":"s1","directory":"/tmp"},"messages":[{"info":{"id":"m1","role":"assistant","providerID":"anthropic","modelID":"claude-sonnet-4-5","cost":0.25,"tokens":{"input":1000,"output":200,"reasoning":0,"cache":{"read":10,"write":5}},"time":{"created":1754654400}}}]}
        """#),
        ("cost-zero", #"""
        {"info":{"id":"s2","directory":"/tmp"},"messages":[{"info":{"id":"m1","role":"assistant","providerID":"anthropic","modelID":"m","cost":0,"tokens":{"input":1000,"output":200},"time":{"created":1754654400}}}]}
        """#),
        ("cost-true", #"""
        {"info":{"id":"s3","directory":"/tmp"},"messages":[{"info":{"id":"m1","role":"assistant","providerID":"anthropic","modelID":"m","cost":true,"tokens":{"input":1000,"output":200},"time":{"created":1754654400}}}]}
        """#),
        ("quoted-numbers", #"""
        {"info":{"id":"s4","directory":"/tmp"},"messages":[{"info":{"id":"m1","role":"assistant","providerID":"anthropic","modelID":"m","cost":"1.50","tokens":{"input":"12500.0","output":"600"},"time":{"created":1754654400}}}]}
        """#),
        ("created-nan", #"""
        {"info":{"id":"s5","directory":"/tmp"},"messages":[{"info":{"id":"m1","role":"assistant","providerID":"anthropic","modelID":"m","tokens":{"input":10,"output":10},"time":{"created":"NaN"}}}]}
        """#),
        ("created-microseconds", #"""
        {"info":{"id":"s6","directory":"/tmp"},"messages":[{"info":{"id":"m1","role":"assistant","providerID":"anthropic","modelID":"m","tokens":{"input":10,"output":10},"time":{"created":1754654400000000}}}]}
        """#),
        ("messages-null-element", #"""
        {"info":{"id":"s7","directory":"/tmp"},"messages":[{"info":{"id":"m1","role":"assistant","providerID":"anthropic","modelID":"m","tokens":{"input":1000,"output":50},"time":{"created":1754654400}}}, null]}
        """#)
    ]

    private static func usageSection() -> [String] {
        var lines = ["", "## ClaudeUsageAdapter.records"]
        guard let directory = try? temporaryDirectory() else {
            return lines + ["(could not make a temporary directory)"]
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        for (name, text) in claudeUsageLines {
            guard let url = write(text, to: directory, named: "claude-\(name).jsonl") else {
                continue
            }
            let records = ClaudeUsageAdapter.records(
                inTranscriptAt: url, accountID: "a", accountName: "A"
            )
            lines.append("\(name) -> [\(records.map(describe).joined(separator: ", "))]")
        }

        lines.append("")
        lines.append("## CodexUsageAdapter.records")
        for (name, text) in codexUsageLines {
            guard let url = write(text, to: directory, named: "codex-\(name).jsonl") else {
                continue
            }
            let records = CodexUsageAdapter.records(
                inRolloutAt: url, accountID: "a", accountName: "A"
            )
            lines.append("\(name) -> [\(records.map(describe).joined(separator: ", "))]")
        }

        lines.append("")
        lines.append("## OpenCodeUsageAdapter.records")
        for (name, text) in openCodeExports {
            do {
                let records = try OpenCodeUsageAdapter.records(fromExport: Data(text.utf8))
                lines.append("\(name) -> [\(records.map(describe).joined(separator: ", "))]")
            } catch {
                lines.append("\(name) -> threw \(error)")
            }
        }
        return lines
    }

    // MARK: - Describing

    static func describe(_ event: StreamEvent) -> String {
        switch event {
        case .initialised(let sessionID, let model):
            return "initialised(\(optional(sessionID.map { String(describing: $0) })), "
                + "\(optional(model)))"
        case .textDelta(let text):
            return "textDelta(\(quoted(text)))"
        case .thinkingDelta(let text):
            return "thinkingDelta(\(quoted(text)))"
        case .assistantMessage(let blocks):
            return "assistant[\(blocks.map(describe).joined(separator: ", "))]"
        case .userMessage(let text):
            return "user(\(quoted(text)))"
        case .transcriptNotice(let text):
            return "notice(\(quoted(text)))"
        case .toolResults(let results):
            let described = results.map {
                "(\($0.toolUseID), \(quoted($0.text)), isError=\($0.isError))"
            }
            return "results[\(described.joined(separator: ", "))]"
        case .runPlanUpdated(let steps):
            let described = steps.map { "(\(optional($0.id)), \($0.title), \($0.status))" }
            return "plan[\(described.joined(separator: ", "))]"
        case .backgroundWork(let tasks):
            return "background[\(tasks.map { "\($0.id):\($0.kind)" }.joined(separator: ", "))]"
        case .turnFinished(let text, let outcome, let metrics):
            return "turnFinished(text: \(optional(text)), outcome: \(outcome.auditName)"
                + ", duration: \(optional(metrics.duration.map { String($0) }))"
                + ", out: \(optional(metrics.outputTokens.map(String.init)))"
                + ", ctx: \(optional(metrics.contextTokens.map(String.init)))"
                + ", window: \(optional(metrics.contextWindow.map(String.init)))"
                + ", effort: \(optional(metrics.effort)))"
        case .unknown(let type):
            return "unknown(\(type))"
        }
    }

    static func describe(_ block: ContentBlock) -> String {
        switch block {
        case .text(let text): return "text(\(quoted(text)))"
        case .thinking(let text): return "thinking(\(quoted(text)))"
        case .toolUse(let id, let tool, let input):
            return "toolUse(\(id), \(tool.rawName), \(canon(input)))"
        }
    }

    static func describe(_ event: ProviderExecutionEvent) -> String {
        "(\(event.category), \(event.phase), \(optional(event.operation)), \(event.callID), "
        + "in=\(event.input.map(canon) ?? "nil"), out=\(event.output.map(canon) ?? "nil"), "
        + "\(event.fidelity))"
    }

    static func describe(_ record: UsageLedgerRecord) -> String {
        let tokens = record.tokens
        return "(\(record.identity), at=\(optional(record.at.map { String($0.timeIntervalSince1970) })), "
            + "model=\(record.model), series=\(record.origin.seriesID), "
            + "in=\(tokens.uncachedInput), cached=\(tokens.cachedInput), "
            + "write=\(tokens.cacheWrite), write1h=\(tokens.cacheWrite1h), "
            + "out=\(tokens.output), reasoning=\(tokens.reasoning), "
            + "reported=\(optional(record.reportedCostUSD.map { String($0) })))"
    }

    static func describe(_ envelope: JSONRPCLineEnvelope?) -> String {
        switch envelope {
        case .none:
            return "nil"
        case .notification(let method, let parameters):
            return "notification(\(method), \(canon(parameters)))"
        case .request(let id, let method, let parameters):
            return "request(\(id), \(method), \(canon(parameters)))"
        case .response(let id, let result, let error):
            return "response(\(id), \(result.map(canon) ?? "nil"), \(optional(error)))"
        }
    }

    // MARK: - Canonical values

    static func canon(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return "bool(\(flag))"
        case .integer(let number): return "int(\(number))"
        case .number(let number): return "num(\(number))"
        case .string(let text): return "str(\(text))"
        case .array(let list): return "[\(list.map(canon).joined(separator: ", "))]"
        case .object(let object): return canon(object)
        case .unconvertible(let describedType): return "unconvertible(\(describedType))"
        }
    }

    static func canon(_ payload: [String: JSONValue]) -> String {
        let body = payload.keys.sorted()
            .map { "\($0): \(canon(payload[$0]!))" }
            .joined(separator: ", ")
        return "{\(body)}"
    }

    static func canon(_ value: Any?) -> String {
        guard let value else { return "absent" }
        switch value {
        case is NSNull:
            return "null"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "bool(\(number.boolValue))" }
            if number.doubleValue.rounded(.towardZero) == number.doubleValue {
                return "int(\(number.int64Value))"
            }
            return "num(\(number.doubleValue))"
        case let text as String:
            return "str(\(text))"
        case let list as [Any]:
            return "[\(list.map { canon($0) }.joined(separator: ", "))]"
        case let object as [String: Any]:
            return canon(object)
        default:
            return "foreign(\(String(describing: value)))"
        }
    }

    static func canon(_ payload: [String: Any]) -> String {
        let body = payload.keys.sorted()
            .map { "\($0): \(canon(payload[$0]))" }
            .joined(separator: ", ")
        return "{\(body)}"
    }

    // MARK: - Helpers

    static func object(_ text: String) -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let object = value as? [String: Any] else { return [:] }
        return object
    }

    /// Writes one JSONL fixture, always newline-terminated.
    ///
    /// `JSONLReader.forEachRecord(at:from:limit:)` deliberately withholds a final record with no
    /// newline, because a resumable reader cannot tell the end of a file from the middle of a
    /// line an agent is still writing. A fixture without the newline therefore reads as empty
    /// through `toolCalls` while reading fine through `read`, which is a property of the
    /// fixture rather than of the adapter.
    static func write(_ text: String, to directory: URL, named name: String) -> URL? {
        let url = directory.appendingPathComponent(name)
        let terminated = text.hasSuffix("\n") ? text : text + "\n"
        guard (try? terminated.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return url
    }

    static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("provider-wire-corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func optional(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "nil"
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
