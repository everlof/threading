import Foundation
import XCTest
@testable import Threading

final class ExecutionAuditTests: XCTestCase {
    func testAppendProducesOrderedVerifiedHashChain() throws {
        let fixture = try makeStore()
        let sessionID = SessionID()

        fixture.store.recordToolRequest(
            sessionID: sessionID,
            source: .providerStream,
            provider: "codex",
            operation: "exec_command",
            callID: "call-1",
            input: .object(["cmd": .string("git status --short")]),
            fidelity: .exact
        )
        fixture.store.recordToolResult(
            sessionID: sessionID,
            source: .providerStream,
            provider: "codex",
            operation: nil,
            callID: "call-1",
            output: .object(["exitCode": .integer(0), "output": .string("clean")]),
            isError: false,
            fidelity: .exact
        )

        let result = fixture.store.read(sessionID: sessionID)
        XCTAssertEqual(result.integrity, .verified)
        XCTAssertEqual(result.malformedLineCount, 0)
        XCTAssertEqual(result.records.map(\.sequence), [1, 2])
        XCTAssertNil(result.records[0].previousDigest)
        XCTAssertEqual(result.records[1].previousDigest, result.records[0].digest)
        XCTAssertEqual(result.records[0].phase, .requested)
        XCTAssertEqual(result.records[1].phase, .completed)
        XCTAssertEqual(result.records[1].operation, "exec_command")
        XCTAssertNotNil(result.records[1].durationMilliseconds)
    }

    func testOrdinaryBrowserTypedAndFormValuesRemainExact() throws {
        let fixture = try makeStore()
        let sessionID = SessionID()

        fixture.store.recordToolRequest(
            sessionID: sessionID,
            source: .threadingMCP,
            provider: nil,
            operation: "browser_type",
            callID: "type-1",
            input: .object([
                "ref": .string("e12"),
                "text": .string("private@example.com")
            ]),
            fidelity: .exact
        )
        fixture.store.recordToolRequest(
            sessionID: sessionID,
            source: .threadingMCP,
            provider: nil,
            operation: "browser_fill_form",
            callID: "form-1",
            input: .object([
                "fields": .array([
                    .object(["ref": .string("e4"), "value": .string("Ada")]),
                    .object(["ref": .string("e8"), "label": .string("Sweden")])
                ])
            ]),
            fidelity: .exact
        )

        let records = fixture.store.read(sessionID: sessionID).records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.fidelity), [.exact, .exact])
        XCTAssertTrue(records.allSatisfy(\.redactions.isEmpty))
        XCTAssertEqual(
            records[0].input?.objectValue?["text"],
            .string("private@example.com")
        )
        guard case .array(let fields)? = records[1].input?.objectValue?["fields"] else {
            return XCTFail("Expected exact browser_fill_form fields")
        }
        XCTAssertEqual(fields.first?.objectValue?["value"], .string("Ada"))
    }

    func testCredentialAndImagePathsAreExplicitlyRedacted() throws {
        let fixture = try makeStore()
        let sessionID = SessionID()

        fixture.store.recordToolRequest(
            sessionID: sessionID,
            source: .threadingMCP,
            provider: nil,
            operation: "browser_type",
            callID: "7",
            input: .object([
                "ref": .string("e12"),
                "text": .string("correct horse battery staple"),
                "token": .string("browser-session-token")
            ]),
            fidelity: .exact
        )
        fixture.store.recordToolResult(
            sessionID: sessionID,
            source: .threadingMCP,
            provider: nil,
            operation: "browser_type",
            callID: "7",
            output: .object([
                "arguments": .object([
                    "ref": .string("e12"),
                    "text": .string("correct horse battery staple")
                ]),
                "content": .array([
                    .object([
                        "type": .string("image"),
                        "mimeType": .string("image/png"),
                        "data": .string("iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB")
                    ])
                ]),
                "isError": .bool(false)
            ]),
            isError: false,
            fidelity: .exact
        )

        let records = fixture.store.read(sessionID: sessionID).records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].fidelity, .exactWithRedactions)
        XCTAssertEqual(
            records[0].redactions,
            [
                .init(path: "input.token", reason: .credential)
            ]
        )
        XCTAssertEqual(
            records[0].input?.objectValue?["text"],
            .string("correct horse battery staple")
        )
        XCTAssertEqual(records[1].fidelity, .exactWithRedactions)
        XCTAssertEqual(
            records[1].redactions,
            [
                .init(path: "output.content[0].data", reason: .imageBytes)
            ]
        )
        XCTAssertEqual(
            records[1].output?.objectValue?["arguments"]?.objectValue?["text"],
            .string("correct horse battery staple")
        )
    }

    func testStreamCaptureNeverStoresPromptReasoningOrAssistantProse() throws {
        let fixture = try makeStore()
        let sessionID = SessionID()
        let metrics = TurnMetrics(
            duration: 0.5,
            outputTokens: 12,
            effort: "high",
            contextTokens: nil,
            contextWindow: nil
        )

        fixture.store.record(
            streamEvent: .userMessage("private user prompt"),
            sessionID: sessionID,
            provider: .claude
        )
        fixture.store.record(
            streamEvent: .thinkingDelta("private reasoning"),
            sessionID: sessionID,
            provider: .claude
        )
        fixture.store.record(
            streamEvent: .assistantMessage(blocks: [
                .text("assistant prose"),
                .toolUse(
                    id: "toolu_1",
                    tool: .read,
                    input: ["file_path": .string("README.md")]
                )
            ]),
            sessionID: sessionID,
            provider: .claude
        )
        fixture.store.record(
            streamEvent: .turnFinished(text: "assistant prose", outcome: .completed, metrics: metrics),
            sessionID: sessionID,
            provider: .claude
        )

        let records = fixture.store.read(sessionID: sessionID).records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.map(\.operation), ["turn.finished"])
        let encoded = records.map { record in
            [record.input?.encodedText(), record.output?.encodedText()].compactMap { $0 }.joined()
        }.joined()
        XCTAssertFalse(encoded.contains("private user prompt"))
        XCTAssertFalse(encoded.contains("private reasoning"))
        XCTAssertFalse(encoded.contains("assistant prose"))
    }

    func testClaudeProviderAdapterKeepsExactToolPayloadsWithoutMessageProse() throws {
        let request = #"{"type":"assistant","message":{"content":[{"type":"text","text":"do not audit me"},{"type":"tool_use","id":"toolu_9","name":"Read","input":{"file_path":"README.md","limit":40}}]}}"#
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_9","content":[{"type":"text","text":"exact output"}],"is_error":false}]}}"#

        let requestEvents = ClaudeProviderExecutionAdapter.events(line: request)
        let resultEvents = ClaudeProviderExecutionAdapter.events(line: result)
        XCTAssertEqual(requestEvents.count, 1)
        XCTAssertEqual(requestEvents[0].operation, "Read")
        XCTAssertEqual(requestEvents[0].fidelity, .exact)
        XCTAssertEqual(
            requestEvents[0].input,
            .object(["file_path": .string("README.md"), "limit": .integer(40)])
        )
        XCTAssertEqual(resultEvents.count, 1)
        XCTAssertEqual(
            resultEvents[0].output,
            .array([.object(["type": .string("text"), "text": .string("exact output")])])
        )
        XCTAssertFalse(requestEvents.description.contains("do not audit me"))
    }

    func testCodexProviderAdapterKeepsCompleteNativeItemEnvelope() throws {
        let parameters: [String: Any] = [
            "threadId": "thread-1",
            "turnId": "turn-1",
            "item": [
                "id": "item-7",
                "type": "mcpToolCall",
                "server": "threading",
                "tool": "browser_click",
                "arguments": ["ref": "e12", "button": "left"],
                "status": "inProgress"
            ] as [String: Any]
        ]
        let events = CodexProviderExecutionAdapter.events(
            method: "item/started",
            parameters: parameters
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].category, .browser)
        XCTAssertEqual(events[0].operation, "browser_click")
        XCTAssertEqual(events[0].phase, .requested)
        XCTAssertEqual(events[0].fidelity, .exact)
        XCTAssertEqual(
            events[0].input?.objectValue?["item"]?.objectValue?["arguments"],
            .object(["ref": .string("e12"), "button": .string("left")])
        )
        XCTAssertEqual(events[0].input?.objectValue?["threadId"], .string("thread-1"))
    }

    func testGrokProviderAdapterKeepsCompleteACPUpdate() throws {
        let update: [String: Any] = [
            "sessionUpdate": "tool_call_update",
            "toolCallId": "tool-1",
            "title": "Run checks",
            "kind": "execute",
            "status": "in_progress",
            "rawOutput": ["line": "Compiling", "percent": 42] as [String: Any]
        ]

        let event = try XCTUnwrap(GrokProviderExecutionAdapter.event(
            update: update,
            operation: "Run checks",
            kind: "execute",
            phase: .progressed,
            asInput: false
        ))

        XCTAssertEqual(event.category, .shell)
        XCTAssertEqual(event.operation, "Run checks")
        XCTAssertEqual(event.phase, .progressed)
        XCTAssertEqual(event.fidelity, .exact)
        XCTAssertEqual(event.output?.objectValue?["toolCallId"], .string("tool-1"))
        XCTAssertEqual(
            event.output?.objectValue?["rawOutput"]?.objectValue?["percent"],
            .integer(42)
        )
    }

    func testRotationReportsVerifiedRetainedSuffix() throws {
        let fixture = try makeStore(maximumSegmentBytes: 1_024, retainedRotatedSegments: 1)
        let sessionID = SessionID()
        for index in 0..<12 {
            fixture.store.append(
                sessionID: sessionID,
                source: .providerStream,
                provider: "grok",
                category: .tool,
                phase: .completed,
                operation: "fixture_\(index)",
                output: .string(String(repeating: "x", count: 420)),
                fidelity: .exact
            )
        }

        let result = fixture.store.read(sessionID: sessionID)
        XCTAssertEqual(result.integrity, .partial)
        XCTAssertLessThan(result.records.count, 12)
        XCTAssertEqual(result.records.last?.sequence, 12)
    }

    func testTamperedRecordBreaksIntegrity() throws {
        let fixture = try makeStore()
        let sessionID = SessionID()
        fixture.store.append(
            sessionID: sessionID,
            source: .providerStream,
            provider: "codex",
            category: .shell,
            phase: .requested,
            operation: "exec_command",
            input: .object(["cmd": .string("pwd")]),
            fidelity: .exact
        )

        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.directory,
                includingPropertiesForKeys: nil
            ).first
        )
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "exec_command", with: "altered_command")
        try text.write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(fixture.store.read(sessionID: sessionID).integrity, .broken)
    }

    func testRemovingSessionDeletesCurrentAndRotatedLedger() throws {
        let fixture = try makeStore(maximumSegmentBytes: 1_024, retainedRotatedSegments: 2)
        let sessionID = SessionID()
        for index in 0..<8 {
            fixture.store.append(
                sessionID: sessionID,
                source: .providerStream,
                provider: "codex",
                category: .shell,
                phase: .completed,
                operation: "fixture_\(index)",
                output: .string(String(repeating: "x", count: 420)),
                fidelity: .exact
            )
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        ).isEmpty)

        fixture.store.remove(sessionID: sessionID)

        XCTAssertTrue(fixture.store.read(sessionID: sessionID).records.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    func testJSONRPCRequestRetainsExactToolArgumentsBesideTypedCommand() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"browser_click","arguments":{"ref":"e9","button":"left"}}}"#.utf8)
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)

        guard case .toolCall(let command) = request.parameters else {
            return XCTFail("Expected typed tool call")
        }
        XCTAssertEqual(command.name, "browser_click")
        XCTAssertEqual(
            request.rawParameters?.objectValue?["arguments"],
            .object(["ref": .string("e9"), "button": .string("left")])
        )
    }

    private func makeStore(
        maximumSegmentBytes: Int = 1024 * 1024,
        retainedRotatedSegments: Int = 2
    ) throws -> (store: ExecutionAuditStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("execution-audit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (
            ExecutionAuditStore(
                directory: directory,
                maximumSegmentBytes: maximumSegmentBytes,
                retainedRotatedSegments: retainedRotatedSegments
            ),
            directory
        )
    }
}
