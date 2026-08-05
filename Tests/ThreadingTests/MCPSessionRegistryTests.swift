import XCTest

@testable import Threading

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
    guard case .incomplete = outcome("POST /mcp HTTP/1.1\r\nContent-Length: 40\r\n\r\n{\"a\":1}")
    else {
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

  /// An ad-hoc endpoint is not `ProjectStore`'s to revoke: the retain sweep runs because some
  /// unrelated session was deleted, and a helper mid-run must keep its endpoint through it.
  /// Only its own explicit end revokes it — and does, in both directions, scope included.
  @MainActor
  func testAnAdHocEndpointSurvivesTheRetainSweepUntilEndedExplicitly() {
    let scope = [MCPBuiltInTool.listSettings.rawValue]
    let adHocSessionID = MCPSessionRegistry.beginAdHoc(allowedTools: scope)
    let token = MCPSessionRegistry.token(for: adHocSessionID)

    XCTAssertEqual(MCPSessionRegistry.session(forToken: token), adHocSessionID)
    XCTAssertEqual(MCPSessionRegistry.adHocScope(for: adHocSessionID), scope)

    MCPSessionRegistry.retainOnly(sessionIDs: [])
    XCTAssertEqual(
      MCPSessionRegistry.session(forToken: token),
      adHocSessionID,
      "deleting an unrelated session revoked a helper's endpoint mid-run"
    )

    MCPSessionRegistry.endAdHoc(adHocSessionID)
    XCTAssertNil(MCPSessionRegistry.session(forToken: token))
    XCTAssertNil(MCPSessionRegistry.adHocScope(for: adHocSessionID))
  }

  /// Inside a scope, `tools/list`, admission and instructions must agree exactly as the
  /// enabled catalogue does globally — all three derive from the scope, so a scoped helper is
  /// advertised one tool, admitted for that tool, and told about nothing else.
  func testAScopedEndpointAdvertisesAdmitsAndDescribesExactlyItsScope() throws {
    let scope = [MCPBuiltInTool.listSettings.rawValue]

    XCTAssertEqual(
      MCPToolCatalog.scopedDefinitions(scope).map(\.name),
      scope
    )

    let scopedCall = try JSONDecoder().decode(
      MCPToolCallParameters.self,
      from: Data(#"{"name":"list_settings"}"#.utf8)
    ).call
    guard case .listSettings = scopedCall else {
      return XCTFail("Expected a typed list_settings command")
    }
    let unscopedCall = try JSONDecoder().decode(
      MCPToolCallParameters.self,
      from: Data(#"{"name":"list_themes"}"#.utf8)
    ).call

    XCTAssertTrue(MCPToolCatalog.scopedAdmits(scopedCall, allowedTools: scope))
    XCTAssertFalse(MCPToolCatalog.scopedAdmits(unscopedCall, allowedTools: scope))

    let instructions = MCPToolCatalog.scopedInstructions(scope)
    XCTAssertTrue(instructions.contains("list_settings"))
    XCTAssertFalse(
      instructions.contains("display panel"),
      "a scoped helper was told about a session surface it cannot reach"
    )
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
    let imageRequest = try request(
      """
      {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
        "name":"display_image","arguments":{"path":"chart.png","title":"Build"}
      }}
      """)
    guard case .toolCall(.displayImage(let image)) = imageRequest.parameters else {
      return XCTFail("Expected typed display_image arguments")
    }
    XCTAssertEqual(image.path, "chart.png")
    XCTAssertEqual(image.title, "Build")

    let tabRequest = try request(
      """
      {"jsonrpc":"2.0","id":"tabs","method":"tools/call","params":{
        "name":"panel_activate_tab","arguments":{"tab":3}
      }}
      """)
    guard case .toolCall(.panelActivateTab(let tab)) = tabRequest.parameters else {
      return XCTFail("Expected typed panel_activate_tab arguments")
    }
    XCTAssertEqual(tab.tab, .index(3))

    let tabID = UUID().uuidString
    let tabIDRequest = try request(
      """
      {"jsonrpc":"2.0","id":"tabs","method":"tools/call","params":{
        "name":"panel_activate_tab","arguments":{"tab":"\(tabID)"}
      }}
      """)
    guard case .toolCall(.panelActivateTab(let identifiedTab)) = tabIDRequest.parameters else {
      return XCTFail("Expected string tab identifier")
    }
    XCTAssertEqual(identifiedTab.tab, .identifier(tabID))
  }

  func testDisplaySceneDecodesTheSharedNativeSceneContract() throws {
    let data = Data(
      """
      {"name":"display_scene","arguments":{
        "title":"iOS 26.5 vs 26.4",
        "subtitle":"+326 MB installed",
        "scene":{
          "accessibilityLabel":"iOS release comparison map",
          "preferredAspectRatio":1.55,
          "items":[{
            "id":"dyld-cache",
            "frame":{"x":0,"y":0,"width":0.7,"height":1},
            "shape":"roundedRectangle",
            "color":"warning",
            "label":"dyld cache",
            "detail":"+121 MB",
            "accessibilityLabel":"dyld cache",
            "accessibilityValue":"increased by 121 MB",
            "actionID":"artifact.explain",
            "isEnabled":true,
            "isSelected":false
          }]
        }
      }}
      """.utf8
    )
    let decoded = try JSONDecoder().decode(MCPToolCallParameters.self, from: data)
    guard case .displayScene(let arguments) = decoded.call else {
      return XCTFail("Expected typed display_scene arguments")
    }

    XCTAssertEqual(arguments.title, "iOS 26.5 vs 26.4")
    XCTAssertEqual(arguments.subtitle, "+326 MB installed")
    let scene = try XCTUnwrap(arguments.scene)
    XCTAssertEqual(scene.accessibilityLabel, "iOS release comparison map")
    XCTAssertEqual(scene.preferredAspectRatio, 1.55)
    XCTAssertEqual(scene.items.first?.id, "dyld-cache")
    XCTAssertEqual(scene.items.first?.color, .warning)
    XCTAssertEqual(scene.items.first?.actionID, "artifact.explain")

    XCTAssertTrue(MCPTools.displayTools.contains(MCPTools.displayScene))
    let definition = try XCTUnwrap(MCPTools.definition(for: .displayScene))
    XCTAssertEqual(definition.inputSchema.required, ["scene"])
    let sceneSchema = try XCTUnwrap(definition.inputSchema.properties["scene"])
    XCTAssertEqual(
      sceneSchema.required,
      ["accessibilityLabel", "preferredAspectRatio", "items"]
    )
    let itemSchema = try XCTUnwrap(sceneSchema.properties?["items"]?.items)
    XCTAssertEqual(
      itemSchema.required,
      ["id", "frame", "shape", "color", "isEnabled", "isSelected"]
    )
    XCTAssertEqual(
      itemSchema.properties?["frame"]?.required,
      ["x", "y", "width", "height"]
    )
  }

  func testCompareFilesArgumentsDecodeTheirSnakeCaseKeys() throws {
    let compareRequest = try request(
      """
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
    let missing = try request(
      """
      {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser_query"}}
      """)
    guard case .toolCall(.browserQuery(let query)) = missing.parameters else {
      return XCTFail("Expected browser_query call")
    }
    XCTAssertNil(query.selector)

    let wrongType = try request(
      """
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
    XCTAssertEqual(
      decoded.result.content,
      [
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

  @MainActor
  func testBuiltInRegistryHasOneSchemaAndOneCatalogEntryPerTypedCommand() {
    XCTAssertEqual(MCPTools.definitionIssues, [])
    XCTAssertEqual(MCPToolCatalog.catalogIssues, [])
    XCTAssertEqual(
      Set(MCPTools.definitions.map(\.name)),
      Set(MCPBuiltInTool.allCases.map(\.rawValue))
    )
    XCTAssertEqual(
      Set(MCPToolCatalog.groups.flatMap { $0.tools.map(\.name) }),
      Set(MCPBuiltInTool.allCases.map(\.rawValue))
    )
    XCTAssertTrue(
      MCPToolCatalog.browser.tools.contains {
        $0.builtInTool == .browserAnnotations
      },
      "browser_annotations had a schema and handler but used to be absent from its group"
    )
  }

  func testBuiltInDefinitionsAdvertiseConservativeBehaviorHints() throws {
    let snapshot = try XCTUnwrap(MCPTools.definition(for: .browserSnapshot))
    XCTAssertEqual(
      snapshot.annotations,
      MCPToolAnnotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
      )
    )

    let storage = try XCTUnwrap(MCPTools.definition(for: .browserStorage))
    XCTAssertEqual(storage.annotations?.readOnlyHint, false)
    XCTAssertEqual(storage.annotations?.destructiveHint, true)

    let encoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(storage))
        as? [String: Any]
    )
    let annotations = try XCTUnwrap(encoded["annotations"] as? [String: Any])
    XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false)
    XCTAssertEqual(annotations["destructiveHint"] as? Bool, true)
    XCTAssertEqual(annotations["openWorldHint"] as? Bool, true)
  }

  @MainActor
  func testDisabledGroupCannotBeCalledEvenWhenItsCommandStillDecodes() throws {
    let group = MCPToolCatalog.display
    let wasEnabled = MCPToolCatalog.isEnabled(group)
    AppSettings.shared.setToolGroup(group.id, enabled: false)
    defer { AppSettings.shared.setToolGroup(group.id, enabled: wasEnabled) }

    let decoded = try JSONDecoder().decode(
      MCPToolCallParameters.self,
      from: Data(
        #"{"name":"display_image","arguments":{"path":"chart.png"}}"#.utf8
      )
    )
    XCTAssertEqual(decoded.call.builtInTool, .displayImage)
    XCTAssertFalse(MCPToolCatalog.admits(decoded.call))
    XCTAssertFalse(MCPToolCatalog.enabledToolNames.contains(MCPTools.displayImage))
    XCTAssertFalse(
      MCPToolCatalog.enabledDefinitions.contains { $0.name == MCPTools.displayImage }
    )
  }

  func testUnknownToolPreservesArbitraryArgumentsForExtensionRouting() throws {
    let extensionRequest = try request(
      """
      {"jsonrpc":"2.0","id":"extension","method":"tools/call","params":{
        "name":"ext__com__example__cache__lookup",
        "arguments":{"key":"answer","options":{"fresh":true,"limit":3}}
      }}
      """)

    guard
      case .toolCall(.unknown(let name, let arguments)) =
        extensionRequest.parameters
    else {
      return XCTFail("Expected an extension-routable unknown tool")
    }
    XCTAssertEqual(name, "ext__com__example__cache__lookup")
    XCTAssertEqual(
      arguments,
      .object([
        "key": .string("answer"),
        "options": .object([
          "fresh": .bool(true),
          "limit": .integer(3),
        ]),
      ]))
  }

  func testConversationHistoryCursorDecodesByName() throws {
    let first = try request(
      """
      {"jsonrpc":"2.0","id":"history","method":"tools/call","params":{
        "name":"conversation_history","arguments":{}
      }}
      """)
    guard
      case .toolCall(.conversationHistory(let firstArguments)) =
        first.parameters
    else {
      return XCTFail("Expected typed conversation history arguments")
    }
    XCTAssertNil(firstArguments.cursor)

    let next = try request(
      """
      {"jsonrpc":"2.0","id":"history-next","method":"tools/call","params":{
        "name":"conversation_history","arguments":{"cursor":"7"}
      }}
      """)
    guard
      case .toolCall(.conversationHistory(let nextArguments)) =
        next.parameters
    else {
      return XCTFail("Expected paginated conversation history arguments")
    }
    XCTAssertEqual(nextArguments.cursor, "7")
  }

  @MainActor
  func testConversationHistoryIsDefinedAndCataloguedAsOneScopedTool() {
    XCTAssertTrue(
      MCPTools.definitions.contains { $0.name == MCPTools.conversationHistory }
    )
    XCTAssertEqual(
      MCPToolCatalog.continuation.tools.map(\.name),
      [MCPTools.conversationHistory]
    )
  }

  /// The session the archive acts on is the one the call arrived on: the URL carries the
  /// identity, so there is no argument for naming another conversation and an agent cannot file
  /// away one that is not its own.
  func testArchiveToolsDecodeIntoASessionScopedCommand() throws {
    let archive = try request(
      """
      {"jsonrpc":"2.0","id":"archive","method":"tools/call","params":{
        "name":"archive_session",
        "arguments":{"reason":"committed and pushed"}
      }}
      """)
    guard case .toolCall(.archiveSession(let arguments)) = archive.parameters else {
      return XCTFail("Expected typed archive arguments")
    }
    XCTAssertEqual(arguments.reason, "committed and pushed")

    let bare = try request(
      """
      {"jsonrpc":"2.0","id":"bare","method":"tools/call","params":{"name":"archive_session"}}
      """)
    guard case .toolCall(.archiveSession(let empty)) = bare.parameters else {
      return XCTFail("Expected an archive call with no reason to decode")
    }
    XCTAssertNil(empty.reason)

    let cancel = try request(
      """
      {"jsonrpc":"2.0","id":"cancel","method":"tools/call","params":{
        "name":"cancel_session_archive"
      }}
      """)
    guard case .toolCall(.cancelSessionArchive) = cancel.parameters else {
      return XCTFail("Expected a typed cancellation")
    }
  }

  /// Archiving stops the agent and takes the row off screen, so it is advertised as the
  /// state-changing tool it is; cancelling a request that is already cancelled changes nothing,
  /// which is what idempotent means.
  @MainActor
  func testArchiveToolsAdvertiseTheirConsequencesAndSitInOneGroup() throws {
    let archive = try XCTUnwrap(MCPTools.definition(for: .archiveSession))
    XCTAssertEqual(archive.annotations?.readOnlyHint, false)
    XCTAssertEqual(archive.annotations?.destructiveHint, true)
    XCTAssertEqual(archive.annotations?.openWorldHint, false)

    let cancel = try XCTUnwrap(MCPTools.definition(for: .cancelSessionArchive))
    XCTAssertEqual(cancel.annotations?.destructiveHint, false)
    XCTAssertEqual(cancel.annotations?.idempotentHint, true)

    XCTAssertEqual(MCPToolCatalog.session.id, "session-lifecycle")
    XCTAssertEqual(MCPToolCatalog.session.tools.map(\.name), MCPTools.sessionTools)
    XCTAssertTrue(
      MCPToolCatalog.session.instruction.contains("after your current turn ends"),
      "the agent is told the archive waits for the turn, or it will report it as done"
    )
  }

  /// Switching the group off has to take the capability with it, not merely hide the row: an
  /// agent that could still archive through a disabled group would be closing sessions the user
  /// has said it may not.
  @MainActor
  func testTurningTheSessionGroupOffRefusesTheArchiveCall() throws {
    let group = MCPToolCatalog.session
    let wasEnabled = MCPToolCatalog.isEnabled(group)
    AppSettings.shared.setToolGroup(group.id, enabled: false)
    defer { AppSettings.shared.setToolGroup(group.id, enabled: wasEnabled) }

    XCTAssertFalse(MCPToolCatalog.admits(.archiveSession(ArchiveSessionArguments(reason: nil))))
    XCTAssertFalse(MCPToolCatalog.enabledToolNames.contains(MCPTools.archiveSession))
  }

  func testExtensionAuthoringToolArgumentsDecodeByName() throws {
    let description = try request(
      """
      {"jsonrpc":"2.0","id":"describe","method":"tools/call","params":{
        "name":"extension_describe_component",
        "arguments":{"component":"sidebar.session-row","version":1}
      }}
      """)
    guard
      case .toolCall(.extensionDescribeComponent(let arguments)) =
        description.parameters
    else {
      return XCTFail("Expected typed extension component description arguments")
    }
    XCTAssertEqual(arguments.component, "sidebar.session-row")
    XCTAssertEqual(arguments.version, 1)

    let validation = try request(
      """
      {"jsonrpc":"2.0","id":"validate","method":"tools/call","params":{
        "name":"extension_validate_component_patch",
        "arguments":{"patch":"{\\"id\\":\\"example\\"}"}
      }}
      """)
    guard
      case .toolCall(.extensionValidateComponentPatch(let arguments)) =
        validation.parameters
    else {
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
      "required": .array([.string("key")]),
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
