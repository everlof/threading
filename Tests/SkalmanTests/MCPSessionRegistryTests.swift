import XCTest
@testable import Skalman

final class MCPSessionRegistryTests: XCTestCase {

    func testConcurrentMintAndLookupPreservesBidirectionalMapping() {
        let sessionIDs = (0..<128).map { _ in SessionID() }
        let resultLock = NSLock()
        var mismatches: [(expected: SessionID, actual: SessionID?)] = []

        DispatchQueue.concurrentPerform(iterations: 4_096) { index in
            let expected = sessionIDs[index % sessionIDs.count]
            let token = MCPSessionRegistry.token(for: expected)
            let actual = MCPSessionRegistry.session(forToken: token)

            if actual != expected {
                resultLock.lock()
                mismatches.append((expected, actual))
                resultLock.unlock()
            }
        }

        XCTAssertTrue(mismatches.isEmpty)

        // Concurrent first use of one session must mint exactly one stable token.
        let sharedSessionID = SessionID()
        var sharedTokens: [String] = []
        DispatchQueue.concurrentPerform(iterations: 1_024) { _ in
            let token = MCPSessionRegistry.token(for: sharedSessionID)
            resultLock.lock()
            sharedTokens.append(token)
            resultLock.unlock()
        }

        XCTAssertEqual(Set(sharedTokens).count, 1)
        XCTAssertEqual(
            sharedTokens.first.flatMap(MCPSessionRegistry.session(forToken:)),
            sharedSessionID
        )
    }

    @MainActor
    func testRetainOnlyRevokesBothDirections() {
        let retainedSessionID = SessionID()
        let removedSessionID = SessionID()
        let retainedToken = MCPSessionRegistry.token(for: retainedSessionID)
        let removedToken = MCPSessionRegistry.token(for: removedSessionID)

        MCPSessionRegistry.retainOnly(sessionIDs: [retainedSessionID])

        XCTAssertEqual(MCPSessionRegistry.session(forToken: retainedToken), retainedSessionID)
        XCTAssertNil(MCPSessionRegistry.session(forToken: removedToken))
        XCTAssertEqual(MCPSessionRegistry.token(for: retainedSessionID), retainedToken)
    }
}

final class MCPWireTests: XCTestCase {

    func testRequestIDPreservesIntegerStringNullAndMissing() throws {
        XCTAssertEqual(try request(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#).id, .integer(7))
        XCTAssertEqual(
            try request(#"{"jsonrpc":"2.0","id":"call-7","method":"ping"}"#).id,
            .string("call-7")
        )
        XCTAssertEqual(try request(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#).id, .null)
        XCTAssertNil(try request(#"{"jsonrpc":"2.0","method":"ping"}"#).id)
    }

    func testToolArgumentsDecodeByToolName() throws {
        let imageRequest = try request("""
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
              "name":"display_image","arguments":{"path":"chart.png","title":"Build"}
            }}
            """)
        guard case .toolCall(.displayImage(let image)) = imageRequest.parameters else {
            return XCTFail("Expected typed display_image arguments")
        }
        XCTAssertEqual(image.path, "chart.png")
        XCTAssertEqual(image.title, "Build")

        let tabRequest = try request("""
            {"jsonrpc":"2.0","id":"tabs","method":"tools/call","params":{
              "name":"panel_activate_tab","arguments":{"tab":3}
            }}
            """)
        guard case .toolCall(.panelActivateTab(let tab)) = tabRequest.parameters else {
            return XCTFail("Expected typed panel_activate_tab arguments")
        }
        XCTAssertEqual(tab.tab, .index(3))

        let tabID = UUID().uuidString
        let tabIDRequest = try request("""
            {"jsonrpc":"2.0","id":"tabs","method":"tools/call","params":{
              "name":"panel_activate_tab","arguments":{"tab":"\(tabID)"}
            }}
            """)
        guard case .toolCall(.panelActivateTab(let identifiedTab)) = tabIDRequest.parameters else {
            return XCTFail("Expected string tab identifier")
        }
        XCTAssertEqual(identifiedTab.tab, .identifier(tabID))
    }

    func testMissingArgumentsRemainToolLevelValidationButWrongTypesAreInvalidParams() throws {
        let missing = try request("""
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser_query"}}
            """)
        guard case .toolCall(.browserQuery(let query)) = missing.parameters else {
            return XCTFail("Expected browser_query call")
        }
        XCTAssertNil(query.selector)

        let wrongType = try request("""
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
              "name":"browser_query","arguments":{"selector":42}
            }}
            """)
        guard case .invalid = wrongType.parameters else {
            return XCTFail("Wrongly typed arguments must produce invalid params")
        }
    }

    func testToolResultResponseEncodesWithoutDictionaryBridging() throws {
        let response = JSONRPCResponse.success(
            id: .string("request-a"),
            result: .tool(.failure("Could not display the image."))
        )
        let decoded = try JSONDecoder().decode(
            ToolResponse.self,
            from: JSONEncoder().encode(response)
        )

        XCTAssertEqual(decoded.jsonrpc, "2.0")
        XCTAssertEqual(decoded.id, .string("request-a"))
        XCTAssertTrue(decoded.result.isError)
        XCTAssertEqual(decoded.result.content, [
            ToolResponse.Result.Content(type: "text", text: "Could not display the image.")
        ])
    }

    func testToolDefinitionEncodesItsJSONSchema() throws {
        let payload = ToolsListResult(tools: [MCPTools.definitions[0]])
        let decoded = try JSONDecoder().decode(
            ToolList.self,
            from: JSONEncoder().encode(payload)
        )

        let definition = try XCTUnwrap(decoded.tools.first)
        XCTAssertEqual(definition.name, MCPTools.displayImage)
        XCTAssertEqual(definition.inputSchema.type, "object")
        XCTAssertEqual(definition.inputSchema.properties["path"]?.type, "string")
        XCTAssertEqual(definition.inputSchema.required, ["path"])
    }

    private func request(_ json: String) throws -> JSONRPCRequest {
        try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
    }

    private struct ToolResponse: Decodable {
        struct Result: Decodable {
            struct Content: Decodable, Equatable {
                let type: String
                let text: String
            }

            let content: [Content]
            let isError: Bool
        }

        let jsonrpc: String
        let id: RequestID
        let result: Result
    }

    private struct ToolList: Decodable {
        struct Definition: Decodable {
            struct InputSchema: Decodable {
                struct Property: Decodable {
                    let type: String
                }

                let type: String
                let properties: [String: Property]
                let required: [String]
            }

            let name: String
            let inputSchema: InputSchema
        }

        let tools: [Definition]
    }
}
