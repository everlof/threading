import XCTest
@testable import Threading

final class ClaudeStreamContentTests: XCTestCase {
    func testAssistantKeepsReadableSiblingsInOrder() throws {
        let line = #"{"type":"assistant","message":{"content":[null,17,{"type":"text","text":"Kept é 👩🏽‍🚀"},[],false,{"type":"tool_use","id":"read-1","name":"Read","input":{"file_path":"/tmp/file.swift"}},"invalid"]}}"#
        guard case .events(let events) = StreamEvent.parse(line),
              case .assistantMessage(let blocks) = try XCTUnwrap(events.first), blocks.count == 2 else {
            return XCTFail("Readable assistant content was discarded")
        }
        guard case .text(let text) = blocks[0],
              case .toolUse(let id, let tool, let input) = blocks[1] else {
            return XCTFail("Assistant block ordering changed")
        }
        XCTAssertEqual(text, "Kept é 👩🏽‍🚀")
        XCTAssertEqual(id, "read-1")
        XCTAssertEqual(tool, .read)
        XCTAssertEqual(input["file_path"], .string("/tmp/file.swift"))
    }

    func testToolResultsKeepReadableSiblings() throws {
        let line = #"{"type":"user","message":{"content":[null,{"type":"tool_result","tool_use_id":"one","content":"first"},42,{"type":"tool_result","tool_use_id":"two","content":[null,{"type":"text","text":"second"}],"is_error":true}]}}"#
        guard case .events(let events) = StreamEvent.parse(line),
              case .toolResults(let results) = try XCTUnwrap(events.first) else {
            return XCTFail("Readable tool results were discarded")
        }
        XCTAssertEqual(results.map(\.toolUseID), ["one", "two"])
        XCTAssertEqual(results.map(\.text), ["first", "second"])
        XCTAssertEqual(results.map(\.isError), [false, true])
    }

    func testUnreadableListAndMalformedEnvelopeStayDistinct() throws {
        for content in ["[]", "[null,17,false,[],\"invalid\"]", "null", "\"invalid\""] {
            let line = "{\"type\":\"assistant\",\"message\":{\"content\":\(content)}}"
            guard case .events(let events) = StreamEvent.parse(line),
                  case .assistantMessage(let blocks) = try XCTUnwrap(events.first) else {
                return XCTFail("A valid envelope was classified as malformed")
            }
            XCTAssertTrue(blocks.isEmpty)
        }
        guard case .malformed = StreamEvent.parse("{broken") else {
            return XCTFail("Malformed JSON was admitted")
        }
    }
}
