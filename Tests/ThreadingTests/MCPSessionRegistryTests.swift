import XCTest
import os

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

  func testEventStreamHandshakeAndGrantNotificationAreValidSSE() throws {
    let serialized = String(
      decoding: HTTPResponse.eventStream.serialized,
      as: UTF8.self
    )
    XCTAssertTrue(serialized.contains("Content-Type: text/event-stream\r\n"))
    XCTAssertTrue(serialized.contains("Cache-Control: no-cache\r\n"))
    XCTAssertFalse(serialized.contains("Content-Length:"))

    let event = String(decoding: MCPServer.toolsListChangedEvent, as: UTF8.self)
    XCTAssertTrue(event.hasPrefix("event: message\n"))
    let dataLine = try XCTUnwrap(event.split(separator: "\n").first {
      $0.hasPrefix("data: ")
    })
    let json = Data(dataLine.dropFirst("data: ".count).utf8)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: String])
    XCTAssertEqual(object["jsonrpc"], "2.0")
    XCTAssertEqual(object["method"], "notifications/tools/list_changed")
    XCTAssertTrue(event.hasSuffix("\n\n"), "an SSE event ends with one empty line")
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

  @MainActor
  func testRemovingOneSessionDoesNotFilterTheRegistry() {
    let retainedSessionID = SessionID()
    let removedSessionID = SessionID()
    let retainedToken = MCPSessionRegistry.token(for: retainedSessionID)
    let removedToken = MCPSessionRegistry.token(for: removedSessionID)
    defer { MCPSessionRegistry.remove(sessionID: retainedSessionID) }

    MCPSessionRegistry.remove(sessionID: removedSessionID)

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
    _ = try requireToolCommand(scopedCall, tool: .listSettings)
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

  @MainActor
  func testDurableAuthorityProjectsExactlyIntoListingAdmissionAndInstructions() throws {
    let wasEnabled = AppSettings.shared.isToolGroupEnabled(MCPToolCatalog.supervision.id)
    AppSettings.shared.setToolGroup(MCPToolCatalog.supervision.id, enabled: true)
    defer {
      AppSettings.shared.setToolGroup(MCPToolCatalog.supervision.id, enabled: wasEnabled)
    }

    let regular = ControlOperation.regularProjectOperations
      .union(ControlOperation.regularSelfOperations)
    let regularNames = Set(MCPToolCatalog.definitions(forOperations: regular).map(\.name))
    XCTAssertTrue(regularNames.isDisjoint(with: MCPTools.supervisionTools))
    XCTAssertFalse(MCPToolCatalog.instructions(forOperations: regular).contains("You are a manager"))

    let managerNames = Set(
      MCPToolCatalog.definitions(forOperations: ControlOperation.managerOperations).map(\.name)
    )
    XCTAssertEqual(managerNames.intersection(MCPTools.supervisionTools), Set(MCPTools.supervisionTools))
    XCTAssertTrue(
      MCPToolCatalog.instructions(forOperations: ControlOperation.managerOperations)
        .contains("You are a manager")
    )

    let id = UUID().uuidString.lowercased()
    let call = try JSONDecoder().decode(
      MCPToolCallParameters.self,
      from: Data(#"{"name":"resume_session","arguments":{"session_id":"\#(id)"}}"#.utf8)
    ).call
    XCTAssertFalse(MCPToolCatalog.admits(call, forOperations: regular))
    XCTAssertTrue(MCPToolCatalog.admits(call, forOperations: ControlOperation.managerOperations))
  }

  // MARK: - The Broker Hook With No App To Ask

  /// The case this exists for: the agent is running and Threading is not.
  ///
  /// The hook used to print nothing and exit with curl's status, which leaves the CLI applying
  /// its own headless behaviour — blocked, with the model told nothing and the turn stalled on
  /// a tool it cannot explain. Now it answers in the app's own words, and the words are the
  /// *same* object a running app would have sent, which is why this compares against
  /// `PermissionDecision.hookResponse` rather than against a transcription of it.
  @MainActor
  func testAnUnreachableAppTurnsTheBrokerHookIntoATypedDeny() throws {
    let sessionID = SessionID()
    defer { MCPSessionRegistry.remove(sessionID: sessionID) }

    let command = try brokerCommand(for: sessionID)
    let run = runHook(command, payload: Self.preToolUsePayload, environment: [
      "PATH": Self.hookPath,
      MCPDefaults.socketEnvironmentKey: "/nonexistent/threading-slice2.sock",
      MCPDefaults.portEnvironmentKey: "",
      MCPDefaults.sessionTokenEnvironmentKey: MCPSessionRegistry.token(for: sessionID)
    ])

    XCTAssertEqual(run.status, 0, "a hook that exits non-zero is read as a failure, not a deny")

    let answer = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(run.output.utf8)) as? [String: Any],
      "the hook printed something the CLI cannot parse: \(run.output)"
    )
    let output = try XCTUnwrap(answer["hookSpecificOutput"] as? [String: Any])

    // Spelled out rather than compared to our constants: these three keys are Claude's, and a
    // rename on our side would silently stop reaching the CLI.
    XCTAssertEqual(output["hookEventName"] as? String, "PreToolUse")
    XCTAssertEqual(output["permissionDecision"] as? String, "deny")
    XCTAssertFalse(
      (output["permissionDecisionReason"] as? String ?? "").isEmpty,
      "a deny with no reason is as mute as no answer at all"
    )

    let expected = PermissionDecision.deny(reason: MCPDefaults.hookDenyReason).hookResponse
    XCTAssertEqual(
      answer as NSDictionary,
      expected as NSDictionary,
      "the fallback drifted from what a running app answers with"
    )
  }

  /// The `||` is the whole contract: an app that answered is never followed by a second object.
  ///
  /// Driven through a stand-in `curl` rather than a listener, because the property under test is
  /// the shell's, not the server's — a successful POST must leave the hook's stdout untouched.
  @MainActor
  func testABrokerAnswerIsNeverFollowedByTheFallback() throws {
    let sessionID = SessionID()
    defer { MCPSessionRegistry.remove(sessionID: sessionID) }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("thr-broker-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let allowed = #"{"hookSpecificOutput":{"permissionDecision":"allow"}}"#
    let curl = directory.appendingPathComponent("curl")
    try Data("#!/bin/sh\nprintf '%s' '\(allowed)'\n".utf8).write(to: curl)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: curl.path)

    let command = try brokerCommand(for: sessionID)
    let run = runHook(command, payload: Self.preToolUsePayload, environment: [
      "PATH": "\(directory.path):\(Self.hookPath)",
      MCPDefaults.socketEnvironmentKey: "/nonexistent/threading-slice2.sock",
      MCPDefaults.portEnvironmentKey: "",
      MCPDefaults.sessionTokenEnvironmentKey: MCPSessionRegistry.token(for: sessionID)
    ])

    XCTAssertEqual(run.status, 0)
    XCTAssertEqual(
      run.output,
      allowed,
      "the app's answer was followed by a second decision on the same stdout"
    )
  }

  /// The lifecycle commands are **byte-identical** to what they were before the broker gained a
  /// fallback, asserted against frozen text rather than against the builder that produces them.
  ///
  /// Their silence is load-bearing in three separate ways: Claude feeds a `UserPromptSubmit`
  /// hook's stdout back to the model as context, reads a non-zero `Stop` as a reason to keep
  /// going, and reads a `PreToolUse` hook's own exit status as a decision. A deny printed by an
  /// observational hook would answer a question nobody asked it.
  @MainActor
  func testTheFallbackReachesTheBrokerHookAndNoOtherCommand() throws {
    let sessionID = SessionID()
    defer { MCPSessionRegistry.remove(sessionID: sessionID) }
    let token = MCPSessionRegistry.token(for: sessionID)

    let groups = try hookGroups(
      for: sessionID,
      brokersPermissions: true,
      reportsLifecycle: true
    )
    var lifecycleCommands: [String] = []

    for event in HookLifecycleEvent.allCases {
      let registration = event.claudeRegistration
      guard registration.isSupported else { continue }

      let expected = Self.frozenLifecycleCommand(
        token: token,
        event: event,
        timeout: Int(MCPDefaults.lifecycleTimeout(for: event))
      )
      for name in registration.eventNames {
        let commands = try XCTUnwrap(groups[name], "\(name) carried no hooks")
        XCTAssertTrue(
          commands.contains(expected),
          "the \(name) command for \(event.rawValue) is no longer byte-identical"
        )
        lifecycleCommands.append(expected)
      }
    }

    XCTAssertFalse(lifecycleCommands.isEmpty, "the fixture registered no lifecycle hooks")
    for command in lifecycleCommands {
      XCTAssertFalse(
        command.contains(MCPDefaults.hookDenyResponseJSON),
        "an observational hook can now speak: \(command)"
      )
    }

    let allCommands = groups.values.flatMap { $0 }
    XCTAssertEqual(
      allCommands.filter { $0.contains(MCPDefaults.hookDenyResponseJSON) }.count,
      1,
      "exactly one command — the broker's — may answer for an absent app"
    )
  }

  // MARK: - Broker Hook Helpers

  /// A minimal `PreToolUse` event, in the shape both CLIs write to the hook's stdin.
  private static let preToolUsePayload = #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#

  /// Spelled out so a hook runs against the system's own tools and nothing the developer's
  /// shell happens to put earlier on the path.
  private static let hookPath = "/usr/bin:/bin"

  /// The `PreToolUse` command out of the settings file a brokered launch is given.
  @MainActor
  private func brokerCommand(for sessionID: SessionID) throws -> String {
    let groups = try hookGroups(
      for: sessionID,
      brokersPermissions: true,
      reportsLifecycle: false
    )
    return try XCTUnwrap(groups["PreToolUse"]?.first, "no broker hook was written")
  }

  /// Every hook command in a written settings file, by hook name.
  @MainActor
  private func hookGroups(
    for sessionID: SessionID,
    brokersPermissions: Bool,
    reportsLifecycle: Bool
  ) throws -> [String: [String]] {
    let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
      for: sessionID,
      brokersPermissions: brokersPermissions,
      reportsLifecycle: reportsLifecycle
    ))
    addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])

    return hooks.compactMapValues { value in
      (value as? [[String: Any]])?.flatMap { group in
        (group["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
      }
    }
  }

  /// The lifecycle command exactly as it read before the broker's fallback existed.
  ///
  /// Frozen as text rather than built from `MCPDefaults.hookPostCommand`, because the property
  /// is that this builder's output still reaches these hooks unchanged — comparing a generator
  /// against itself would pass through any change to it.
  private static func frozenLifecycleCommand(
    token: String,
    event: HookLifecycleEvent,
    timeout: Int
  ) -> String {
    let suffix = "/lifecycle/\(token)?event=\(event.rawValue)"
    let common = "-s --max-time \(timeout)"
      + " -H 'Content-Type: application/json' --data-binary @-"

    return "threading_hook_payload=$(cat); "
      + "( { [ -n \"$THREADING_MCP_SOCKET\" ] &&"
      + " printf '%s' \"$threading_hook_payload\" |"
      + " curl \(common) --unix-socket \"$THREADING_MCP_SOCKET\""
      + " \"http://localhost\(suffix)\"; }"
      + " || { [ -n \"$THREADING_MCP_PORT\" ] &&"
      + " printf '%s' \"$threading_hook_payload\" |"
      + " curl \(common) \"http://127.0.0.1:$THREADING_MCP_PORT\(suffix)\"; } )"
      + " >/dev/null 2>&1 || true"
  }

  /// Runs a generated hook the way a CLI does: `/bin/sh -c`, the event on stdin, stdout read
  /// back as the answer.
  ///
  /// Off the main queue and joined through an expectation, because a hook that does reach a
  /// listener is answered by code hopping to main — blocking there would deadlock against the
  /// thing under test.
  private func runHook(
    _ command: String,
    payload: String,
    environment: [String: String]
  ) -> (output: String, status: Int32) {
    let finished = expectation(description: "the generated hook finished")
    let result = OSAllocatedUnfairLock<(output: String, status: Int32)>(
      initialState: (output: "", status: -1)
    )

    DispatchQueue.global(qos: .userInitiated).async {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", command]
      process.environment = environment

      let input = Pipe()
      let output = Pipe()
      process.standardInput = input
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice

      do {
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        result.withLock {
          $0 = (String(decoding: data, as: UTF8.self), process.terminationStatus)
        }
      } catch {
        result.withLock { $0 = ("\(error)", -1) }
      }
      finished.fulfill()
    }

    wait(for: [finished], timeout: 30)
    return result.withLock { $0 }
  }
}

final class MCPWireTests: XCTestCase {

  func testPermissionResponseCallCarriesTheExactOneShotDecision() throws {
    let sessionID = UUID().uuidString.lowercased()
    let requestID = UUID().uuidString.lowercased()
    let data = Data(
      #"{"name":"respond_to_permission","arguments":{"session_id":"\#(sessionID)","request_id":"\#(requestID)","decision":"allow"}}"#.utf8
    )
    let decoded = try JSONDecoder().decode(MCPToolCallParameters.self, from: data)
    let arguments: RespondToPermissionArguments = try requireToolArguments(
      decoded.call,
      tool: .respondToPermission
    )

    XCTAssertEqual(arguments.sessionID, sessionID)
    XCTAssertEqual(arguments.requestID, requestID)
    XCTAssertEqual(arguments.decision, "allow")
    XCTAssertTrue(MCPTools.supervisionTools.contains(decoded.call.name))
    XCTAssertEqual(ControlOperation.respondToPermission.supervisionToolName, decoded.call.name)
    let definition = try XCTUnwrap(MCPTools.definition(for: .respondToPermission))
    XCTAssertEqual(definition.annotations?.readOnlyHint, false)
    XCTAssertEqual(definition.annotations?.destructiveHint, true)
    XCTAssertEqual(definition.annotations?.idempotentHint, false)
  }

  func testNotifyUserCallIsTypedAndSessionScopedByTheServer() throws {
    let data = Data(
      #"{"name":"notify_user","arguments":{"title":"Ready","message":"The review is complete.","recipient":"Kalle’s iPhone","delivery":"ios","target_ref":"opaque-target"}}"#
        .utf8
    )
    let decoded = try JSONDecoder().decode(MCPToolCallParameters.self, from: data)
    let arguments: NotifyUserArguments = try requireToolArguments(
      decoded.call,
      tool: .notifyUser
    )
    XCTAssertEqual(arguments.title, "Ready")
    XCTAssertEqual(arguments.message, "The review is complete.")
    XCTAssertEqual(arguments.recipient, "Kalle’s iPhone")
    XCTAssertEqual(arguments.delivery, "ios")
    XCTAssertEqual(arguments.targetRef, "opaque-target")
    XCTAssertTrue(MCPTools.notificationTools.contains(decoded.call.name))
    XCTAssertTrue(
      MCPTools.definitions.contains { $0.name == MCPTools.notifyUser }
    )
  }

  func testTargetedResultCarriesAnOpaqueStructuredReference() throws {
    let encoded = try JSONEncoder().encode(
      MCPToolResult.targeted(
        "Showing the captured document.",
        reference: "opaque-target",
        kind: "attachment"
      )
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let structured = try XCTUnwrap(object["structuredContent"] as? [String: String])
    XCTAssertEqual(structured["target_ref"], "opaque-target")
    XCTAssertEqual(structured["target_kind"], "attachment")
    XCTAssertEqual(object["isError"] as? Bool, false)
  }

  func testWorkspaceControlCallsAreTypedAndAdvertised() throws {
    let target = UUID().uuidString.lowercased()
    let data = Data(
      #"{"name":"send_to_session","arguments":{"session_id":"\#(target)","message":"The importer bug is in the byte cap."}}"#
        .utf8
    )
    let decoded = try JSONDecoder().decode(MCPToolCallParameters.self, from: data)
    let arguments: SendToSessionArguments = try requireToolArguments(
      decoded.call,
      tool: .sendToSession
    )
    XCTAssertEqual(arguments.sessionID, target)
    XCTAssertEqual(arguments.message, "The importer bug is in the byte cap.")
    XCTAssertNil(arguments.disposition, "Absent means queue; the default is decided in one place")

    let steered = try JSONDecoder().decode(
      MCPToolCallParameters.self,
      from: Data(
        #"{"name":"send_to_session","arguments":{"session_id":"\#(target)","message":"Also check the tests.","disposition":"steer"}}"#
          .utf8
      )
    )
    let steerArguments: SendToSessionArguments = try requireToolArguments(
      steered.call,
      tool: .sendToSession
    )
    XCTAssertEqual(steerArguments.disposition, "steer")

    let listed = try JSONDecoder().decode(
      MCPToolCallParameters.self,
      from: Data(#"{"name":"list_sessions"}"#.utf8)
    )
    _ = try requireToolCommand(listed.call, tool: .listSessions)

    let watched = try JSONDecoder().decode(
      MCPToolCallParameters.self,
      from: Data(
        #"{"name":"watch_session","arguments":{"session_id":"\#(target)","timeout_minutes":120}}"#.utf8
      )
    )
    let watchArguments: WatchSessionArguments = try requireToolArguments(
      watched.call,
      tool: .watchSession
    )
    XCTAssertEqual(watchArguments.sessionID, target)
    XCTAssertEqual(watchArguments.timeoutMinutes, 120)

    XCTAssertEqual(
      MCPTools.workspaceTools, ["list_sessions", "send_to_session", "watch_session"])
    XCTAssertTrue(MCPTools.definitions.contains { $0.name == "list_sessions" })
    let send = try XCTUnwrap(MCPTools.definitions.first { $0.name == "send_to_session" })
    XCTAssertEqual(send.inputSchema.required, ["session_id", "message"])
    let watch = try XCTUnwrap(MCPTools.definitions.first { $0.name == "watch_session" })
    XCTAssertEqual(watch.inputSchema.required, ["session_id"])
    XCTAssertEqual(watch.inputSchema.properties["timeout_minutes"]?.type, .number)
    XCTAssertTrue(
      MCPBuiltInToolRegistry.issues.isEmpty,
      "Every workspace tool needs one complete descriptor: \(MCPBuiltInToolRegistry.issues)"
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
    let image: DisplayImageArguments = try requireToolArguments(
      imageRequest.parameters.toolCall,
      tool: .displayImage
    )
    XCTAssertEqual(image.path, "chart.png")
    XCTAssertEqual(image.title, "Build")

    let tabRequest = try request(
      """
      {"jsonrpc":"2.0","id":"tabs","method":"tools/call","params":{
        "name":"panel_activate_tab","arguments":{"tab":3}
      }}
      """)
    let tab: PanelActivateTabArguments = try requireToolArguments(
      tabRequest.parameters.toolCall,
      tool: .panelActivateTab
    )
    XCTAssertEqual(tab.tab, .index(3))

    let tabID = UUID().uuidString
    let tabIDRequest = try request(
      """
      {"jsonrpc":"2.0","id":"tabs","method":"tools/call","params":{
        "name":"panel_activate_tab","arguments":{"tab":"\(tabID)"}
      }}
      """)
    let identifiedTab: PanelActivateTabArguments = try requireToolArguments(
      tabIDRequest.parameters.toolCall,
      tool: .panelActivateTab
    )
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
    let arguments: DisplaySceneArguments = try requireToolArguments(
      decoded.call,
      tool: .displayScene
    )

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
    let compare: DisplayCompareFilesArguments = try requireToolArguments(
      compareRequest.parameters.toolCall,
      tool: .displayCompareFiles
    )
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
    let query: BrowserSelectorArguments = try requireToolArguments(
      missing.parameters.toolCall,
      tool: .browserQuery
    )
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
  func testBuiltInRegistryHasOneCompleteDescriptorPerTypedCommand() throws {
    XCTAssertEqual(MCPBuiltInToolRegistry.issues, [])
    XCTAssertEqual(
      MCPBuiltInToolRegistry.descriptors.map(\.tool),
      MCPBuiltInTool.allCases
    )
    XCTAssertEqual(
      MCPTools.definitions.map(\.name),
      MCPBuiltInTool.allCases.map(\.rawValue)
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

    let handler = RecordingCommandHandler()
    for descriptor in MCPBuiltInToolRegistry.descriptors {
      let payload = try JSONSerialization.data(
        withJSONObject: ["name": descriptor.tool.rawValue, "arguments": [:]]
      )
      let command = try JSONDecoder().decode(MCPToolCallParameters.self, from: payload).call
      XCTAssertEqual(command.builtInTool, descriptor.tool)
      XCTAssertEqual(descriptor.definition.name, descriptor.tool.rawValue)
      XCTAssertEqual(descriptor.annotations, descriptor.definition.annotations)
      XCTAssertEqual(descriptor.presentation.builtInTool, descriptor.tool)
      XCTAssertEqual(descriptor.family, descriptor.tool.family)

      var result: MCPToolResult?
      let sessionID = SessionID()
      descriptor.execution.execute(
        command,
        with: handler,
        for: sessionID
      ) { result = $0 }
      XCTAssertEqual(handler.receivedTool, descriptor.tool)
      XCTAssertEqual(handler.receivedSessionID, sessionID)
      XCTAssertEqual(result?.isError, false)
    }
  }

  func testIncompleteOrDuplicateDeclarationCannotAdvertiseDecodeOrExecute() throws {
    let withoutNavigate = MCPTools.authoredDeclarations.filter {
      $0.tool != .browserNavigate
    }
    let incomplete = MCPBuiltInToolRegistrySnapshot(declarations: withoutNavigate)

    XCTAssertNil(incomplete.descriptor(for: .browserNavigate))
    XCTAssertNil(incomplete.descriptor(named: MCPTools.browserNavigate))
    XCTAssertFalse(
      incomplete.descriptors.map(\.definition.name).contains(MCPTools.browserNavigate)
    )
    XCTAssertTrue(
      incomplete.issues.contains { $0.contains("browserNavigate has 0 declarations") }
    )

    let navigate = try XCTUnwrap(
      MCPTools.authoredDeclarations.first { $0.tool == .browserNavigate }
    )
    let duplicate = MCPBuiltInToolRegistrySnapshot(
      declarations: MCPTools.authoredDeclarations + [navigate]
    )
    XCTAssertNil(duplicate.descriptor(for: .browserNavigate))
    XCTAssertTrue(
      duplicate.issues.contains { $0.contains("browserNavigate has 2 declarations") }
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

    let external = try XCTUnwrap(extensionRequest.parameters.toolCall)
    XCTAssertNil(external.builtInTool)
    XCTAssertEqual(external.name, "ext__com__example__cache__lookup")
    let arguments = try XCTUnwrap(external.externalArguments)
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
    let firstArguments: ConversationHistoryArguments = try requireToolArguments(
      first.parameters.toolCall,
      tool: .conversationHistory
    )
    XCTAssertNil(firstArguments.cursor)

    let next = try request(
      """
      {"jsonrpc":"2.0","id":"history-next","method":"tools/call","params":{
        "name":"conversation_history","arguments":{"cursor":"7"}
      }}
      """)
    let nextArguments: ConversationHistoryArguments = try requireToolArguments(
      next.parameters.toolCall,
      tool: .conversationHistory
    )
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

  func testServerDecisionPrefixFitsTheLazyDiscoveryBudget() {
    let prefix = MCPToolCatalog.decisionPrefix(for: MCPToolCatalog.groups)

    XCTAssertLessThanOrEqual(
      prefix.count,
      MCPInstructionDefaults.decisionPrefixCharacterLimit,
      "the server's most important routing guidance must fit in Codex's leading instruction slice"
    )
    XCTAssertTrue(prefix.contains("may load lazily"))
    XCTAssertTrue(prefix.contains("discover a matching tool"))
    XCTAssertTrue(prefix.contains("Threading's Browser"))
    XCTAssertTrue(prefix.contains("browser_navigate"))
    XCTAssertTrue(prefix.contains("browser_snapshot"))
    XCTAssertTrue(prefix.contains("another chat/session"))
    XCTAssertTrue(prefix.contains("list_sessions"))
    XCTAssertTrue(prefix.contains("send_to_session"))
    XCTAssertTrue(prefix.contains("watch_session"))
    XCTAssertTrue(prefix.contains("display panel"))
    XCTAssertTrue(prefix.contains("archive_session"))
    XCTAssertTrue(prefix.contains("rename/re-title"))
    XCTAssertTrue(prefix.contains("set_session_name"))
    XCTAssertTrue(prefix.contains("list_reclaimable_storage"))
    XCTAssertTrue(prefix.hasSuffix("."), "the bounded prefix must stand on its own")
  }

  func testServerDecisionPrefixOnlyNamesEnabledExceptionalCapabilities() {
    let ordinaryPrefix = MCPToolCatalog.decisionPrefix(for: [MCPToolCatalog.notifications])
    XCTAssertTrue(ordinaryPrefix.contains("discover a matching tool"))
    XCTAssertFalse(ordinaryPrefix.contains("browser_navigate"))
    XCTAssertFalse(ordinaryPrefix.contains("display panel"))
    XCTAssertFalse(ordinaryPrefix.contains("archive_session"))
    XCTAssertFalse(ordinaryPrefix.contains("set_session_name"))
    XCTAssertFalse(ordinaryPrefix.contains("list_reclaimable_storage"))
    XCTAssertFalse(ordinaryPrefix.contains("watch_session"))

    let browserPrefix = MCPToolCatalog.decisionPrefix(for: [MCPToolCatalog.browser])
    XCTAssertTrue(browserPrefix.contains("Threading's Browser"))
    XCTAssertTrue(browserPrefix.contains("browser_navigate"))
    XCTAssertTrue(browserPrefix.contains("browser_snapshot"))
    XCTAssertFalse(browserPrefix.contains("watch_session"))

    let sessionPrefix = MCPToolCatalog.decisionPrefix(for: [MCPToolCatalog.session])
    XCTAssertTrue(sessionPrefix.contains("close/archive/finish"))
    XCTAssertTrue(sessionPrefix.contains("after your reply"))
    XCTAssertTrue(sessionPrefix.contains("rename/re-title"))
    XCTAssertTrue(sessionPrefix.contains("set_session_name"))
    XCTAssertFalse(sessionPrefix.contains("list_reclaimable_storage"))

    let workspacePrefix = MCPToolCatalog.decisionPrefix(for: [MCPToolCatalog.workspace])
    XCTAssertTrue(workspacePrefix.contains("another chat/session"))
    XCTAssertTrue(workspacePrefix.contains("list_sessions"))
    XCTAssertTrue(workspacePrefix.contains("send_to_session"))
    XCTAssertTrue(workspacePrefix.contains("watch_session"))
    XCTAssertFalse(workspacePrefix.contains("archive_session"))
  }

  func testBrowserNavigationExplainsThatItBootstrapsTheSessionTab() throws {
    let definition = try XCTUnwrap(MCPTools.definition(for: .browserNavigate))
    XCTAssertTrue(definition.description.contains("creates this session's browser tab"))
    XCTAssertTrue(definition.description.contains("empty panel"))
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
    let arguments: ArchiveSessionArguments = try requireToolArguments(
      archive.parameters.toolCall,
      tool: .archiveSession
    )
    XCTAssertEqual(arguments.reason, "committed and pushed")

    let bare = try request(
      """
      {"jsonrpc":"2.0","id":"bare","method":"tools/call","params":{"name":"archive_session"}}
      """)
    let empty: ArchiveSessionArguments = try requireToolArguments(
      bare.parameters.toolCall,
      tool: .archiveSession
    )
    XCTAssertNil(empty.reason)

    let cancel = try request(
      """
      {"jsonrpc":"2.0","id":"cancel","method":"tools/call","params":{
        "name":"cancel_session_archive"
      }}
      """)
    _ = try requireToolCommand(cancel.parameters.toolCall, tool: .cancelSessionArchive)
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
    let arguments: ExtensionComponentReferenceArguments = try requireToolArguments(
      description.parameters.toolCall,
      tool: .extensionDescribeComponent
    )
    XCTAssertEqual(arguments.component, "sidebar.session-row")
    XCTAssertEqual(arguments.version, 1)

    let validation = try request(
      """
      {"jsonrpc":"2.0","id":"validate","method":"tools/call","params":{
        "name":"extension_validate_component_patch",
        "arguments":{"patch":"{\\"id\\":\\"example\\"}"}
      }}
      """)
    let validationArguments: ExtensionComponentPatchArguments = try requireToolArguments(
      validation.parameters.toolCall,
      tool: .extensionValidateComponentPatch
    )
    XCTAssertEqual(validationArguments.patch, #"{"id":"example"}"#)
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

  @MainActor
  private final class RecordingCommandHandler: AgentCommandHandling {
    var receivedTool: MCPBuiltInTool?
    var receivedSessionID: SessionID?

    func executeBuiltIn(
      _ command: AgentCommand,
      for sessionID: SessionID,
      completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
      receivedTool = command.builtInTool
      receivedSessionID = sessionID
      completion(.success("executed"))
    }

    func handleExternalTool(
      named name: String,
      arguments: MCPJSONValue,
      for sessionID: SessionID,
      completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
      completion(.failure("unexpected external tool \(name)"))
    }
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
