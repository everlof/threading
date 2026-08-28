import Foundation
import XCTest
@testable import Threading

/// What the Foundation→`JSONValue` boundary does with a container it cannot fully read.
///
/// Every fixture starts as **JSON text** parsed by `JSONSerialization`, because that is the
/// representation the wire produces and the one that has already hidden a real defect here: a
/// Swift dictionary literal holds `Bool` and `Int`, not `__NSCFBoolean` and `__NSCFNumber`, and so
/// cannot reproduce it. The member that will not convert is spliced in afterwards, which is the
/// only way a non-JSON value can reach any of these call sites.
final class JSONConversionFallbackTests: XCTestCase {

    // MARK: - Fixtures

    /// A `Date` is the stand-in for "an in-process caller put something here that JSON has no
    /// spelling for". `JSONSerialization` never produces one.
    private static let notJSON = Date(timeIntervalSince1970: 0)

    private func parsed(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    /// A shell call whose `when` member the bridge cannot read.
    private func toolInputWithOneUnreadableMember() throws -> [String: Any] {
        var object = try parsed("""
        {"command":"git status --short","cwd":"/repo","timeout":120,"quiet":false,"retries":1}
        """)
        object["when"] = Self.notJSON
        return object
    }

    // MARK: - The shared bridge

    func testPerMemberConversionKeepsEveryMemberItCanRead() throws {
        let converted = JSONValue.convertingObject(from: try toolInputWithOneUnreadableMember())

        XCTAssertEqual(converted["command"], .string("git status --short"))
        XCTAssertEqual(converted["cwd"], .string("/repo"))
        XCTAssertEqual(converted["timeout"], .integer(120))
        // The 0/1-as-Bool defect this boundary already shipped: `false` and `1` came off the
        // wire as an `NSNumber` and must not swap places.
        XCTAssertEqual(converted["quiet"], .bool(false))
        XCTAssertEqual(converted["retries"], .integer(1))
        XCTAssertEqual(converted["when"], .unconvertible("Date"))
        XCTAssertEqual(converted.count, 6)
    }

    func testStrictConversionStillRefusesTheWholeContainer() throws {
        let object = try toolInputWithOneUnreadableMember()

        XCTAssertNil(JSONValue.object(from: object))
        XCTAssertNil(JSONValue(foundationValue: object))
    }

    func testAnUnreadableMemberInsideANestedContainerKeepsItsSiblings() throws {
        var outer = try parsed("""
        {"outer":{"kept":"yes","dropped":null},"list":["first","second"],"sibling":"intact"}
        """)
        var inner = try XCTUnwrap(outer["outer"] as? [String: Any])
        inner["dropped"] = Self.notJSON
        outer["outer"] = inner
        var list = try XCTUnwrap(outer["list"] as? [Any])
        list[1] = URL(fileURLWithPath: "/tmp/corpus")
        outer["list"] = list

        let converted = JSONValue.convertingObject(from: outer)

        XCTAssertEqual(converted["sibling"], .string("intact"))
        XCTAssertEqual(
            converted["outer"],
            .object(["kept": .string("yes"), "dropped": .unconvertible("Date")])
        )
        XCTAssertEqual(
            converted["list"],
            .array([.string("first"), .unconvertible("URL")])
        )
    }

    func testAContainerThatIsEntirelyUnreadableStillKeepsItsShape() throws {
        var object = try parsed("""
        {"only":null}
        """)
        object["only"] = Self.notJSON

        XCTAssertEqual(
            JSONValue.convertingObject(from: object),
            ["only": .unconvertible("Date")]
        )
        XCTAssertNil(JSONValue.object(from: object))
    }

    func testEmptyAndNullContainersAreUnchanged() throws {
        XCTAssertEqual(JSONValue.convertingObject(from: try parsed("{}")), [:])
        XCTAssertEqual(
            JSONValue.convertingObject(from: try parsed("""
            {"empty_object":{},"empty_array":[],"null":null}
            """)),
            ["empty_object": .object([:]), "empty_array": .array([]), "null": .null]
        )
    }

    /// There is no JSON for "not JSON", so the marker is written and read back as text.
    /// Asserted rather than assumed, because the encode side is what reaches the ledger's digest.
    func testTheMarkerEncodesAsTextAndDecodesBackAsThatText() throws {
        let value = JSONValue.unconvertible("Date")

        XCTAssertEqual(value.encodedText(), "\"<unconvertible:Date>\"")
        XCTAssertEqual(value.foundationValue as? String, "<unconvertible:Date>")

        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: data),
            .string("<unconvertible:Date>")
        )
    }

    // MARK: - The execution-audit ledger

    func testTheLedgerKeepsAReadableInputAndNamesTheMemberItCouldNotRead() throws {
        let fixture = try makeStore()
        let sessionID = SessionID()
        var item = try toolInputWithOneUnreadableMember()
        item["id"] = "call-1"
        item["type"] = "commandExecution"

        let events = CodexProviderExecutionAdapter.events(
            method: "item/started",
            parameters: ["item": item]
        )
        XCTAssertEqual(events.count, 1, "the whole ledger event used to disappear here")
        for event in events {
            fixture.store.record(providerEvent: event, sessionID: sessionID, provider: .codex)
        }

        let result = fixture.store.read(sessionID: sessionID)
        XCTAssertEqual(result.integrity, .verified)
        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(record.operation, "commandExecution")

        let recorded = try XCTUnwrap(record.input?.objectValue?["item"]?.objectValue)
        XCTAssertEqual(recorded["command"], .string("git status --short"))
        XCTAssertEqual(recorded["cwd"], .string("/repo"))
        XCTAssertEqual(recorded["timeout"], .integer(120))
        XCTAssertEqual(recorded["quiet"], .bool(false))
        XCTAssertEqual(recorded["when"], .string("<unconvertible:Date>"))

        XCTAssertEqual(record.redactions.count, 1)
        XCTAssertEqual(record.redactions.first?.path, "input.item.when")
        XCTAssertEqual(record.redactions.first?.reason, .unconvertible)
        XCTAssertEqual(record.redactions.first?.reason.rawValue, "unconvertible")
        XCTAssertEqual(record.fidelity, .exactWithRedactions)
        XCTAssertEqual(record.fidelity.rawValue, "exact_with_redactions")
    }

    func testAnACPToolCallIsStillRecordedWhenOneMemberWillNotConvert() throws {
        let fixture = try makeStore()
        let sessionID = SessionID()
        var update = try parsed("""
        {"toolCallId":"acp-1","title":"Read file","rawInput":{"path":"/repo/README.md"}}
        """)
        update["startedAt"] = Self.notJSON

        let event = try XCTUnwrap(
            ACPProviderExecutionAdapter.event(
                update: update,
                operation: "Read file",
                kind: .read,
                phase: .requested,
                asInput: true
            ),
            "the whole ledger event used to disappear here"
        )
        fixture.store.record(providerEvent: event, sessionID: sessionID, provider: .grok)

        let record = try XCTUnwrap(fixture.store.read(sessionID: sessionID).records.first)
        let input = try XCTUnwrap(record.input?.objectValue)
        XCTAssertEqual(input["toolCallId"], .string("acp-1"))
        XCTAssertEqual(
            input["rawInput"]?.objectValue?["path"],
            .string("/repo/README.md")
        )
        XCTAssertEqual(input["startedAt"], .string("<unconvertible:Date>"))
        XCTAssertEqual(record.redactions.map(\.path), ["input.startedAt"])
        XCTAssertEqual(record.fidelity, .exactWithRedactions)
    }

    func testAClaudeToolResultThatWillNotConvertIsNotRecordedAsANullResult() throws {
        // `block["content"]` absent is a null result; present-but-unreadable is not the same
        // statement, and `?? .null` used to make them identical.
        let events = ClaudeProviderExecutionAdapter.events(
            line: """
            {"type":"user","message":{"content":[\
            {"type":"tool_result","tool_use_id":"tu-1","content":{"text":"ok"}}]}}
            """
        )
        XCTAssertEqual(events.first?.output, .object(["text": .string("ok")]))

        let absent = ClaudeProviderExecutionAdapter.events(
            line: """
            {"type":"user","message":{"content":[\
            {"type":"tool_result","tool_use_id":"tu-1"}]}}
            """
        )
        XCTAssertEqual(absent.first?.output, .null)
    }

    /// The redaction vocabulary is a wire format the ledger stores by raw value, so every case
    /// is spelled out here rather than derived from `rawValue`. A new case is a compile error.
    func testEveryRedactionReasonKeepsItsStoredSpelling() {
        for reason in [
            ExecutionAuditRecord.Redaction.Reason.typedText,
            .formValue,
            .credential,
            .imageBytes,
            .unconvertible
        ] {
            switch reason {
            case .typedText: XCTAssertEqual(reason.rawValue, "typed_text")
            case .formValue: XCTAssertEqual(reason.rawValue, "form_value")
            case .credential: XCTAssertEqual(reason.rawValue, "credential")
            case .imageBytes: XCTAssertEqual(reason.rawValue, "image_bytes")
            case .unconvertible: XCTAssertEqual(reason.rawValue, "unconvertible")
            }
        }
    }

    // MARK: - The conversation timeline

    func testACodexToolRowKeepsTheArgumentsItCanRead() throws {
        var arguments = try parsed("""
        {"path":"/repo/README.md","limit":40}
        """)
        arguments["deadline"] = Self.notJSON

        let events = CodexAppServerEvent.streamEvents(
            method: "item/started",
            parameters: [
                "item": [
                    "id": "mcp-1",
                    "type": "mcpToolCall",
                    "server": "threading",
                    "tool": "read_file",
                    "arguments": arguments
                ]
            ]
        )

        guard case .assistantMessage(let blocks)? = events.first,
              case .toolUse(let id, let tool, let input)? = blocks.first else {
            return XCTFail("Expected one tool row")
        }
        XCTAssertEqual(id, "mcp-1")
        XCTAssertEqual(tool.rawName, "mcp__threading__read_file")
        XCTAssertEqual(input["path"], .string("/repo/README.md"))
        XCTAssertEqual(input["limit"], .integer(40))
        XCTAssertEqual(input["deadline"], .unconvertible("Date"))
    }

    func testAFileChangeRowIsNotDroppedForAnUnreadableMember() throws {
        var item = try parsed("""
        {"id":"fc-1","type":"fileChange","changes":{"/repo/a.swift":"modified"}}
        """)
        item["at"] = Self.notJSON

        let events = CodexAppServerEvent.streamEvents(
            method: "item/started",
            parameters: ["item": item]
        )
        guard case .assistantMessage(let blocks)? = events.first,
              case .toolUse(let id, let tool, let input)? = blocks.first else {
            return XCTFail("Expected the file-change row to survive")
        }
        XCTAssertEqual(id, "fc-1")
        XCTAssertEqual(tool.rawName, "Edit")
        XCTAssertEqual(
            input["changes"],
            .object(["/repo/a.swift": .string("modified")])
        )
        XCTAssertEqual(input["at"], .unconvertible("Date"))
    }

    func testAReplayedCodexToolRowSurvivesAnUnreadableMember() throws {
        var input = try parsed("""
        {"command":"ls -la","workdir":"/repo"}
        """)
        input["startedAt"] = Self.notJSON

        let event = TranscriptReplay.codexEvent(from: [
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call",
                "call_id": "rep-1",
                "name": "shell",
                "input": input
            ]
        ])

        guard case .assistantMessage(let blocks)? = event,
              case .toolUse(let id, let tool, let recorded)? = blocks.first else {
            return XCTFail("Expected the replayed row to survive")
        }
        XCTAssertEqual(id, "rep-1")
        XCTAssertEqual(tool.rawName, "Bash")
        XCTAssertEqual(recorded["command"], .string("ls -la"))
        XCTAssertEqual(recorded["workdir"], .string("/repo"))
        XCTAssertEqual(recorded["startedAt"], .unconvertible("Date"))
    }

    func testAReplayedClaudeToolRowSurvivesAnUnreadableMember() throws {
        var input = try parsed("""
        {"command":"ls -la","description":"list"}
        """)
        input["startedAt"] = Self.notJSON

        let block = StreamEvent.contentBlock([
            "type": "tool_use",
            "id": "blk-1",
            "name": "Bash",
            "input": input
        ])

        guard case .toolUse(let id, let tool, let recorded)? = block else {
            return XCTFail("Expected the replayed row to survive")
        }
        XCTAssertEqual(id, "blk-1")
        XCTAssertEqual(tool.rawName, "Bash")
        XCTAssertEqual(recorded["command"], .string("ls -la"))
        XCTAssertEqual(recorded["startedAt"], .unconvertible("Date"))
    }

    // MARK: - Helpers

    private func makeStore() throws -> (store: ExecutionAuditStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-conversion-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (
            ExecutionAuditStore(
                directory: directory,
                maximumSegmentBytes: 1024 * 1024,
                retainedRotatedSegments: 2
            ),
            directory
        )
    }
}
