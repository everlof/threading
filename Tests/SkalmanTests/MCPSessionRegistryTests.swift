import XCTest
@testable import Skalman

final class MCPSessionRegistryTests: XCTestCase {

    // MARK: - HTTP Framing

    private func outcome(_ raw: String) -> MCPConnection.ParseOutcome {
        MCPConnection.parseRequest(from: Data(raw.utf8))
    }

    private func request(_ raw: String) throws -> HTTPRequest {
        guard case .request(let request, _) = outcome(raw) else {
            throw XCTSkip("expected a parsed request")
        }
        return request
    }

    private func malformedStatus(_ raw: String) -> Int? {
        guard case .malformed(let status, _) = outcome(raw) else { return nil }
        return status
    }

    /// The ordinary POST every client actually sends still parses, body and all.
    func testAWellFormedPostParsesWithItsBody() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        let parsed = try request(
            "POST /mcp HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        )

        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/mcp")
        XCTAssertEqual(String(data: parsed.body, encoding: .utf8), body)
    }

    /// A body that has not all arrived is *incomplete*, not malformed — the normal case for the
    /// first reads of a large request, and the one thing that must keep waiting.
    func testAPartialBodyKeepsWaiting() {
        guard case .incomplete = outcome("POST /mcp HTTP/1.1\r\nContent-Length: 40\r\n\r\n{\"a\":1}") else {
            return XCTFail("a half-arrived body was not treated as incomplete")
        }
    }

    /// Framing the parser cannot trust ends the connection instead of being defaulted away.
    ///
    /// Every one of these used to become "a body of zero bytes", which leaves the real body at
    /// the head of the buffer to be read as the *next* request's start line — a client's payload
    /// promoted to a request. The negative length additionally crashed the body slice, since a
    /// range whose end precedes its start traps.
    func testUnreadableFramingIsRefusedRatherThanDefaulted() {
        XCTAssertEqual(
            malformedStatus("POST /mcp HTTP/1.1\r\nContent-Length: banana\r\n\r\nxx"),
            400,
            "an unreadable Content-Length was accepted"
        )
        XCTAssertEqual(
            malformedStatus("POST /mcp HTTP/1.1\r\nContent-Length: -5\r\n\r\nxx"),
            400,
            "a negative Content-Length was accepted, which traps on the body slice"
        )
        XCTAssertEqual(
            malformedStatus("POST /mcp HTTP/1.1\r\n\r\n{\"method\":\"x\"}"),
            411,
            "a POST with no declared length was accepted as an empty body"
        )
        XCTAssertEqual(
            malformedStatus("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n"),
            501,
            "chunked framing was accepted by a parser that does not implement it"
        )
        XCTAssertEqual(
            malformedStatus(
                "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 10\r\n\r\n{}"
            ),
            400,
            "duplicate Content-Length headers left the request boundary ambiguous"
        )
        XCTAssertEqual(
            malformedStatus("GARBAGE\r\n\r\n"),
            400,
            "a request line with no path was waited on forever"
        )
    }

    /// A declared length past the buffer cap is refused at the header rather than after the
    /// bytes have been accepted — the point of a cap is to not read them.
    func testADeclaredLengthPastTheCapIsRefusedUpFront() {
        XCTAssertEqual(
            malformedStatus(
                "POST /mcp HTTP/1.1\r\nContent-Length: \(MCPDefaults.maximumRequestBytes + 1)\r\n\r\n"
            ),
            413
        )
    }

    /// A method that carries no body needs no length: the SSE `GET` this server refuses is
    /// exactly that shape, and rejecting it would refuse a well-formed client.
    func testABodylessMethodNeedsNoDeclaredLength() throws {
        let parsed = try request("GET /mcp HTTP/1.1\r\nAccept: text/event-stream\r\n\r\n")
        XCTAssertEqual(parsed.method, "GET")
        XCTAssertTrue(parsed.body.isEmpty)
        XCTAssertEqual(parsed.header("Accept"), "text/event-stream")
    }

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

    func testNotifyUserCallIsTypedAndSessionScopedByTheServer() throws {
        let data = Data(
            #"{"name":"notify_user","arguments":{"title":"Ready","message":"The review is complete.","recipient":"Kalle’s iPhone"}}"#
                .utf8
        )
        let decoded = try JSONDecoder().decode(MCPToolCallParameters.self, from: data)
        guard case .notifyUser(let arguments) = decoded.call else {
            return XCTFail("Expected typed notify_user arguments")
        }
        XCTAssertEqual(arguments.title, "Ready")
        XCTAssertEqual(arguments.message, "The review is complete.")
        XCTAssertEqual(arguments.recipient, "Kalle’s iPhone")
        XCTAssertTrue(MCPTools.notificationTools.contains(decoded.call.name))
        XCTAssertTrue(
            MCPTools.definitions.contains { $0.name == MCPTools.notifyUser }
        )
    }

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

    func testCompareFilesArgumentsDecodeTheirSnakeCaseKeys() throws {
        let compareRequest = try request("""
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
              "name":"display_compare_files","arguments":{
                "old_path":"/tmp/a.png","new_path":"/tmp/b.png",
                "old_title":"Baseline","new_title":"Current"
              }
            }}
            """)
        guard case .toolCall(.displayCompareFiles(let compare)) = compareRequest.parameters else {
            return XCTFail("Expected typed display_compare_files arguments")
        }
        XCTAssertEqual(compare.oldPath, "/tmp/a.png")
        XCTAssertEqual(compare.newPath, "/tmp/b.png")
        XCTAssertEqual(compare.oldTitle, "Baseline")
        XCTAssertEqual(compare.newTitle, "Current")

        // The tool is advertised with the display group, with both paths required.
        XCTAssertTrue(MCPTools.displayTools.contains(MCPTools.displayCompareFiles))
        let definition = try XCTUnwrap(
            MCPTools.definitions.first { $0.name == MCPTools.displayCompareFiles }
        )
        XCTAssertEqual(definition.inputSchema.required, ["old_path", "new_path"])
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

    func testUnknownToolPreservesArbitraryArgumentsForExtensionRouting() throws {
        let extensionRequest = try request("""
            {"jsonrpc":"2.0","id":"extension","method":"tools/call","params":{
              "name":"ext__com__example__cache__lookup",
              "arguments":{"key":"answer","options":{"fresh":true,"limit":3}}
            }}
            """)

        guard case .toolCall(.unknown(let name, let arguments)) =
                extensionRequest.parameters else {
            return XCTFail("Expected an extension-routable unknown tool")
        }
        XCTAssertEqual(name, "ext__com__example__cache__lookup")
        XCTAssertEqual(arguments, .object([
            "key": .string("answer"),
            "options": .object([
                "fresh": .bool(true),
                "limit": .integer(3)
            ])
        ]))
    }

    func testExtensionAuthoringToolArgumentsDecodeByName() throws {
        let description = try request("""
            {"jsonrpc":"2.0","id":"describe","method":"tools/call","params":{
              "name":"extension_describe_component",
              "arguments":{"component":"sidebar.session-row","version":1}
            }}
            """)
        guard case .toolCall(.extensionDescribeComponent(let arguments)) =
                description.parameters else {
            return XCTFail("Expected typed extension component description arguments")
        }
        XCTAssertEqual(arguments.component, "sidebar.session-row")
        XCTAssertEqual(arguments.version, 1)

        let validation = try request("""
            {"jsonrpc":"2.0","id":"validate","method":"tools/call","params":{
              "name":"extension_validate_component_patch",
              "arguments":{"patch":"{\\"id\\":\\"example\\"}"}
            }}
            """)
        guard case .toolCall(.extensionValidateComponentPatch(let arguments)) =
                validation.parameters else {
            return XCTFail("Expected typed extension component patch arguments")
        }
        XCTAssertEqual(arguments.patch, #"{"id":"example"}"#)
    }

    @MainActor
    func testExtensionAuthoringToolsAppearAsOneBuiltInSettingsGroup() {
        let group = MCPToolCatalog.extensionAuthoring
        XCTAssertEqual(group.id, "extension-authoring")
        XCTAssertEqual(
            group.tools.map(\.name),
            MCPTools.extensionAuthoringTools
        )
        XCTAssertTrue(
            Set(MCPTools.definitions.map(\.name))
                .isSuperset(of: Set(MCPTools.extensionAuthoringTools))
        )
    }

    @MainActor
    func testExtensionAuthoringCallsReachTheCoordinatorAdapter() {
        let coordinator = AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
        var result: MCPToolResult?
        coordinator.handle(
            .extensionDescribeComponent(
                ExtensionComponentReferenceArguments(
                    component: "sidebar.project-row",
                    version: 1
                )
            ),
            for: SessionID()
        ) {
            result = $0
        }

        XCTAssertEqual(result?.isError, false)
        XCTAssertTrue(result?.text.contains(#""project.image""#) == true)
        XCTAssertTrue(result?.text.contains(#""patchSchema""#) == true)
    }

    func testExternalToolDefinitionPreservesItsDeclaredJSONSchema() throws {
        let schema: MCPJSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "key": .object(["type": .string("string")])
            ]),
            "required": .array([.string("key")])
        ])
        let definition = MCPToolDefinition(
            name: "ext__com__example__cache__lookup",
            description: "Look up a cached value.",
            externalSchema: schema
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(definition)
            ) as? [String: Any]
        )
        let encodedSchema = try XCTUnwrap(object["inputSchema"] as? [String: Any])
        XCTAssertEqual(encodedSchema["type"] as? String, "object")
        XCTAssertEqual(encodedSchema["required"] as? [String], ["key"])
    }

    @MainActor
    func testExternalToolRegistryRoutesWithoutKnowingTheProviderImplementation() {
        let registry = MCPExternalToolRegistry.shared
        let previous = registry.provider
        let provider = StubExternalToolProvider()
        registry.provider = provider
        defer { registry.provider = previous }

        var response: MCPExternalToolResponse?
        let routed = registry.invokeTool(
            named: "optional_lookup",
            arguments: .object(["key": .string("answer")]),
            for: SessionID()
        ) {
            response = $0
        }

        XCTAssertTrue(routed)
        XCTAssertEqual(provider.receivedName, "optional_lookup")
        XCTAssertEqual(provider.receivedArguments, .object(["key": .string("answer")]))
        XCTAssertEqual(response?.text, "42")
        XCTAssertEqual(response?.isError, false)
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

    @MainActor
    private final class StubExternalToolProvider: MCPExternalToolProvider {
        var receivedName: String?
        var receivedArguments: MCPJSONValue?

        var groups: [MCPExternalToolGroup] { [] }

        func invokeTool(
            named name: String,
            arguments: MCPJSONValue,
            for sessionID: SessionID,
            completion: @escaping (MCPExternalToolResponse) -> Void
        ) -> Bool {
            receivedName = name
            receivedArguments = arguments
            completion(MCPExternalToolResponse(text: "42", isError: false))
            return true
        }
    }
}
