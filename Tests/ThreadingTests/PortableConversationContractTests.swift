import XCTest
@testable import Threading

final class PortableConversationContractTests: XCTestCase {
    func testSharedLinuxAndMacConversationContracts() throws {
        try runConversationContracts()
    }

    func testAppTimelineKeepsItsRegistryChartProjection() throws {
        for name in [MCPBuiltInTool.displayChart.rawValue,
                     MCPDefaults.allowedToolName(MCPBuiltInTool.displayChart.rawValue)] {
            var timeline = ConversationTimeline(sessionID: SessionID())
            _ = timeline.apply(.assistantMessage(blocks: [.toolUse(id: "chart", tool: ToolIdentity(name), input: [
                "title": .string("Tokens"), "kind": .string("bar"),
                "categories": .array([.string("One"), .string("Two")]),
                "series": .array([.object(["name": .string("Usage"), "values": .array([.integer(2), .integer(3)])])
                ])
            ])]))
            guard case .toolCall(let call) = try XCTUnwrap(timeline.rows.first) else {
                return XCTFail("Chart lost its tool-row identity")
            }
            XCTAssertEqual(try XCTUnwrap(call.chart).categories, ["One", "Two"])
            XCTAssertEqual(call.chart?.series.first?.values, [2, 3])
        }
    }
}
