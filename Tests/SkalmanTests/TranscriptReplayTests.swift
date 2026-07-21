import XCTest
@testable import Skalman

final class TranscriptReplayTests: XCTestCase {

    func testCodexCustomToolCallReplaysAsBash() throws {
        let record: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call",
                "id": "tool-record",
                "call_id": "call-1",
                "status": "completed",
                "name": "exec",
                "input": #"const r = await tools.exec_command({cmd:"ls -la",workdir:"/tmp"}); text(r.output);"#
            ]
        ]

        let event = try XCTUnwrap(TranscriptReplay.codexEvent(from: record))
        guard case .assistantMessage(let blocks) = event,
              case .toolUse(let id, let name, let input) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected one replayed tool call")
        }

        XCTAssertEqual(id, "call-1")
        XCTAssertEqual(name, "Bash")
        XCTAssertEqual(input["command"] as? String, "ls -la")
    }

    func testCodexCustomToolOutputAttachesToCall() throws {
        let record: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "custom_tool_call_output",
                "call_id": "call-1",
                "output": [
                    ["type": "input_text", "text": "Script completed\nOutput:\n"],
                    ["type": "input_text", "text": "file.txt\n"]
                ]
            ]
        ]

        let event = try XCTUnwrap(TranscriptReplay.codexEvent(from: record))
        guard case .toolResults(let results) = event else {
            return XCTFail("Expected one replayed tool result")
        }

        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.toolUseID, "call-1")
        XCTAssertEqual(result.text, "file.txt\n")
        XCTAssertFalse(result.isError)
    }

    func testCodexResponseMessagesRemainIgnoredToAvoidDuplicates() {
        let record: [String: Any] = [
            "type": "response_item",
            "payload": ["type": "message", "role": "assistant"]
        ]

        XCTAssertNil(TranscriptReplay.codexEvent(from: record))
    }
}
