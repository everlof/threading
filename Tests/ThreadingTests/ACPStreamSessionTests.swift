import XCTest
@testable import Threading

/// Drives the ACP runtime against deterministic `/bin/sh` agents.
///
/// The profile here is a fixture rather than `.grok`, so anything these tests pin is a property
/// of the protocol runtime: a claim that only holds for one vendor cannot pass by accident.
/// Every fake answers on a real pipe, so framing, ordering and process death are exercised
/// rather than simulated, and a fake that is handed the wrong line exits with a distinctive
/// status — a mismatch fails a turn instead of hanging the suite.
@MainActor
final class ACPStreamSessionTests: XCTestCase {

    // MARK: - Handshake

    func testInitializeCarriesHostCapabilitiesAndTheProfileMetaExtension() throws {
        let agent = makeAgent([.awaitClientLine, .exit(0)])
        let session = makeSession(agent)
        defer { session.terminate() }
        let exited = expectation(description: "transport exited")
        session.onExit = { _ in exited.fulfill() }

        session.start()
        wait(for: [exited], timeout: ACPTestDefaults.timeout)

        let initialize = try XCTUnwrap(agent.clientLines().first)
        XCTAssertEqual(initialize["method"] as? String, "initialize")
        let parameters = try XCTUnwrap(initialize["params"] as? [String: Any])
        XCTAssertEqual(
            (parameters["clientInfo"] as? [String: Any])?["name"] as? String,
            "threading"
        )

        let capabilities = try XCTUnwrap(parameters["clientCapabilities"] as? [String: Any])
        let filesystem = try XCTUnwrap(capabilities["fs"] as? [String: Any])
        XCTAssertEqual(filesystem["readTextFile"] as? Bool, false)
        XCTAssertEqual(filesystem["writeTextFile"] as? Bool, false)
        XCTAssertEqual(capabilities["terminal"] as? Bool, false)
        XCTAssertNotNil((capabilities["session"] as? [String: Any])?["configOptions"])
        let meta = try XCTUnwrap(capabilities["_meta"] as? [String: Any])
        XCTAssertEqual(meta[FixtureACP.metaKey] as? String, FixtureACP.metaValue)

        // A profile with nothing to add omits the member rather than sending an empty object.
        let plainAgent = makeAgent([.awaitClientLine, .exit(0)])
        let plain = makeSession(plainAgent, profile: FixtureACP.profile(meta: [:]))
        defer { plain.terminate() }
        let plainExited = expectation(description: "plain transport exited")
        plain.onExit = { _ in plainExited.fulfill() }

        plain.start()
        wait(for: [plainExited], timeout: ACPTestDefaults.timeout)

        let plainInitialize = try XCTUnwrap(plainAgent.clientLines().first)
        let plainCapabilities = try XCTUnwrap(
            (plainInitialize["params"] as? [String: Any])?["clientCapabilities"]
                as? [String: Any]
        )
        XCTAssertNil(plainCapabilities["_meta"])
    }

    func testInitializeErrorFailsTheTurnAndEndsTheTransport() {
        let agent = makeAgent([
            .awaitClientLine,
            .emit(FakeACPAgent.errorResponse(
                id: ACPTestDefaults.initializeRequestID,
                message: FixtureACP.refusalText
            )),
            .idle
        ])
        let session = makeSession(agent)
        defer { session.terminate() }

        let finished = expectation(description: "turn failed")
        let exited = expectation(description: "transport exited")
        var exitCount = 0
        session.onEvent = { event in
            guard case .turnFinished(let text, let outcome, _) = event else { return }
            XCTAssertEqual(text, FixtureACP.refusalText)
            XCTAssertEqual(outcome, .failed)
            finished.fulfill()
        }
        session.onExit = { _ in
            exitCount += 1
            exited.fulfill()
        }

        session.start()
        XCTAssertTrue(session.send("anything"))
        wait(for: [finished, exited], timeout: ACPTestDefaults.timeout)

        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(exitCount, 1)
    }

    /// A plan's own environment entries reach the child, on top of the shared launch
    /// environment rather than instead of it.
    ///
    /// The mechanism is provider-neutral and the first caller is not: Cursor's CLI opens a
    /// browser to authenticate, and a native launch has no shell words to say otherwise in.
    func testPlanEnvironmentOverridesReachTheChild() throws {
        let agent = makeAgent([
            .recordEnvironment(ACPTestDefaults.overriddenEnvironmentName),
            // Reported as a word rather than as its value: a `PATH` is long, and quoting it into
            // the fake's JSON would make this test depend on the developer's own directories.
            .recordEnvironmentPresence(EnvironmentKeys.path),
            .exit(0)
        ])
        let session = makeSession(
            agent,
            environmentOverrides: [
                ACPTestDefaults.overriddenEnvironmentName: ACPTestDefaults.overriddenEnvironmentValue
            ]
        )
        defer { session.terminate() }
        let exited = expectation(description: "transport exited")
        session.onExit = { _ in exited.fulfill() }

        session.start()
        wait(for: [exited], timeout: ACPTestDefaults.timeout)

        let reported = agent.clientLines().compactMap { $0["env"] as? String }
        XCTAssertEqual(reported.first, ACPTestDefaults.overriddenEnvironmentValue)
        // The shared environment is still underneath: an override adds, it does not replace.
        XCTAssertEqual(reported.last, ACPTestDefaults.presentEnvironmentValue)
    }

    /// An agent that never answers `initialize` is the failure the deadline exists for: ACP
    /// permits an agent to say nothing at all about input it did not like, so silence is
    /// indistinguishable from work until a client stops waiting.
    func testAnUnansweredHandshakeFailsTheTurnAndEndsTheTransportOnce() {
        let agent = makeAgent([.idle])
        let session = makeSession(agent, handshakeTimeout: ACPTestDefaults.shortHandshakeTimeout)
        defer { session.terminate() }

        let finished = expectation(description: "turn failed")
        let exited = expectation(description: "transport exited")
        var exitCount = 0
        session.onEvent = { event in
            guard case .turnFinished(let text, let outcome, _) = event else { return }
            XCTAssertEqual(
                text,
                ACPTransportMessage.handshakeTimedOut(FixtureACP.displayName)
            )
            XCTAssertEqual(outcome, .failed)
            finished.fulfill()
        }
        session.onExit = { _ in
            exitCount += 1
            exited.fulfill()
        }

        session.start()
        XCTAssertTrue(session.send("anything"))
        wait(for: [finished, exited], timeout: ACPTestDefaults.timeout)

        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(exitCount, 1)
    }

    /// The other half of the bound: a slow handshake is still a handshake. Each request is
    /// timed separately, so an agent that takes its time twice is not penalised for the sum.
    func testASlowButAnsweredHandshakeIsUnaffectedByTheDeadline() {
        let agent = makeAgent([
            .awaitClientLine,
            .pause(ACPTestDefaults.slowHandshakePause),
            .emit(FakeACPAgent.response(id: ACPTestDefaults.initializeRequestID, result: [:])),
            .awaitClientLine,
            .pause(ACPTestDefaults.slowHandshakePause),
            .emit(FakeACPAgent.response(
                id: ACPTestDefaults.openSessionRequestID,
                result: ["sessionId": FixtureACP.sessionID]
            )),
            .awaitClientLine,
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(agent, handshakeTimeout: ACPTestDefaults.shortHandshakeTimeout)
        defer { session.terminate() }

        let finished = expectation(description: "turn finished")
        session.onEvent = { event in
            guard case .turnFinished(let text, let outcome, _) = event else { return }
            XCTAssertNil(text)
            XCTAssertEqual(outcome, .completed)
            finished.fulfill()
        }

        session.start()
        XCTAssertTrue(session.send("go"))
        wait(for: [finished], timeout: ACPTestDefaults.timeout)
        XCTAssertTrue(session.isRunning)
    }

    /// A `toolCallId` is opaque. One shipping agent joins two provider ids with a literal
    /// newline, which is legal and which nothing here may assume away — the call and its result
    /// still have to find each other.
    func testAToolCallIdentifierCarryingANewlineStillCorrelatesItsResult() throws {
        let agent = makeAgent(openedAgentSteps() + [
            .awaitClientLine,
            .emit(FakeACPAgent.update([
                "sessionUpdate": "tool_call",
                "toolCallId": FixtureACP.multilineToolCallID,
                "title": "Run checks",
                "kind": "execute",
                "status": "pending",
                "rawInput": ["command": FixtureACP.reviewedCommand]
            ])),
            .emit(FakeACPAgent.update([
                "sessionUpdate": "tool_call_update",
                "toolCallId": FixtureACP.multilineToolCallID,
                "status": "completed",
                "rawOutput": FixtureACP.toolOutputText
            ])),
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(agent)
        defer { session.terminate() }

        var events: [StreamEvent] = []
        let finished = expectation(description: "turn finished")
        session.onEvent = { event in
            events.append(event)
            if case .turnFinished = event { finished.fulfill() }
        }

        session.start()
        XCTAssertTrue(session.send("go"))
        wait(for: [finished], timeout: ACPTestDefaults.timeout)

        let toolUses = events.flatMap { event -> [String] in
            guard case .assistantMessage(let blocks) = event else { return [] }
            return blocks.compactMap { block in
                guard case .toolUse(let id, _, _) = block else { return nil }
                return id
            }
        }
        XCTAssertEqual(toolUses, [FixtureACP.multilineToolCallID])

        let results = events.flatMap { event -> [ToolResult] in
            guard case .toolResults(let results) = event else { return [] }
            return results
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.toolUseID, FixtureACP.multilineToolCallID)
        XCTAssertEqual(results.first?.text, FixtureACP.toolOutputText)
        XCTAssertEqual(results.first?.isError, false)
    }

    /// A call this client refused is shown as refused, whether or not the agent admits it.
    ///
    /// The three cases are the two wire behaviours plus the control: an agent that completes a
    /// rejected call with nothing (measured on a shipping CLI), an agent that reports `failed`
    /// itself, and an ordinary allowed call whose row must be untouched by any of this.
    func testADeniedToolCallIsPresentedAsDeniedHoweverTheAgentReportsIt() throws {
        let silentlyCompleted = try toolResult(
            decision: .deny(reason: "test"),
            completion: ["status": "completed"]
        )
        XCTAssertTrue(silentlyCompleted.isError)
        XCTAssertEqual(silentlyCompleted.text, ACPTransportMessage.deniedToolCall)

        // An agent that says `failed` reaches the same row through the wire, and its own text
        // is kept rather than replaced by ours.
        let reportedFailure = try toolResult(
            decision: .deny(reason: "test"),
            completion: ["status": "failed", "rawOutput": FixtureACP.toolFailureText]
        )
        XCTAssertTrue(reportedFailure.isError)
        XCTAssertEqual(reportedFailure.text, FixtureACP.toolFailureText)

        let allowed = try toolResult(
            decision: .allow(reason: "test"),
            completion: ["status": "completed", "rawOutput": FixtureACP.toolOutputText]
        )
        XCTAssertFalse(allowed.isError)
        XCTAssertEqual(allowed.text, FixtureACP.toolOutputText)
    }

    func testSessionLoadReplaysHistoryBeforeTheLiveTurnBecomesLive() throws {
        let agent = makeAgent([
            .awaitClientLine,
            .emit(FakeACPAgent.response(id: ACPTestDefaults.initializeRequestID, result: [:])),
            .requireClientLine(
                containing: "session/load",
                otherwiseExit: ACPTestDefaults.mismatchStatus
            ),
            .emit(FakeACPAgent.update([
                "sessionUpdate": "user_message_chunk",
                "messageId": "history-1",
                "content": ["type": "text", "text": FixtureACP.replayedUserText]
            ])),
            .emit(FakeACPAgent.update([
                "sessionUpdate": "agent_message_chunk",
                "messageId": "history-2",
                "content": ["type": "text", "text": FixtureACP.replayedAgentText]
            ])),
            .emit(FakeACPAgent.response(
                id: ACPTestDefaults.openSessionRequestID,
                result: ["sessionId": FixtureACP.sessionID]
            )),
            .requireClientLine(
                containing: "session/prompt",
                otherwiseExit: ACPTestDefaults.mismatchStatus
            ),
            .emit(FakeACPAgent.update([
                "sessionUpdate": "user_message_chunk",
                "messageId": "late-1",
                "content": ["type": "text", "text": FixtureACP.droppedUserText]
            ])),
            .emit(FakeACPAgent.update([
                "sessionUpdate": "agent_message_chunk",
                "messageId": "live-1",
                "content": ["type": "text", "text": FixtureACP.liveAgentText]
            ])),
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(
            agent,
            resumeState: .resumable(TranscriptID(FixtureACP.sessionID))
        )
        defer { session.terminate() }

        var events: [StreamEvent] = []
        let finished = expectation(description: "turn finished")
        session.onEvent = { event in
            events.append(event)
            if case .turnFinished = event { finished.fulfill() }
        }

        session.start()
        XCTAssertTrue(session.send("carry on"))
        wait(for: [finished], timeout: ACPTestDefaults.timeout)

        let shapes = ACPEventShape.shapes(of: events)
        let initialised = try XCTUnwrap(shapes.firstIndex(of: .initialised))
        let replayedUser = try XCTUnwrap(
            shapes.firstIndex(of: .userMessage(FixtureACP.replayedUserText))
        )
        let replayedAgent = try XCTUnwrap(
            shapes.firstIndex(of: .assistantText(FixtureACP.replayedAgentText))
        )
        XCTAssertLessThan(replayedUser, initialised)
        XCTAssertLessThan(replayedAgent, initialised)
        XCTAssertFalse(shapes[..<initialised].contains {
            if case .textDelta = $0 { return true }
            if case .thinkingDelta = $0 { return true }
            return false
        })

        XCTAssertTrue(shapes.contains(.textDelta(FixtureACP.liveAgentText)))
        XCTAssertFalse(shapes.contains(.userMessage(FixtureACP.droppedUserText)))

        let load = try XCTUnwrap(agent.clientLines().first {
            $0["method"] as? String == "session/load"
        })
        XCTAssertEqual(
            (load["params"] as? [String: Any])?["sessionId"] as? String,
            FixtureACP.sessionID
        )
    }

    // MARK: - Turn Control

    func testCancelMidTurnSettlesTheTurnAsStopped() {
        let agent = makeAgent(openedAgentSteps() + [
            .requireClientLine(
                containing: "session/prompt",
                otherwiseExit: ACPTestDefaults.mismatchStatus
            ),
            // A cancel is a notification: an `"id"` member would make it a request the agent
            // has to answer.
            .matchClientLine(
                containing: ["session/cancel"],
                notContaining: [ACPTestDefaults.requestIDMember],
                otherwiseExit: ACPTestDefaults.mismatchStatus
            ),
            .emit(FakeACPAgent.promptResponse(stopReason: "cancelled")),
            .idle
        ])
        let session = makeSession(agent)
        defer { session.terminate() }

        let initialised = expectation(description: "session opened")
        let finished = expectation(description: "turn stopped")
        session.onEvent = { event in
            switch event {
            case .initialised:
                initialised.fulfill()
            case .turnFinished(_, let outcome, _):
                XCTAssertEqual(outcome, .stopped)
                finished.fulfill()
            default:
                break
            }
        }

        session.start()
        wait(for: [initialised], timeout: ACPTestDefaults.timeout)
        XCTAssertTrue(session.send("work"))

        let acknowledged = expectation(description: "interrupt acknowledged")
        session.interrupt { receipt in
            XCTAssertEqual(receipt, .acknowledged)
            acknowledged.fulfill()
        }
        wait(for: [acknowledged, finished], timeout: ACPTestDefaults.timeout)

        XCTAssertTrue(session.canSend)
        XCTAssertNotNil(session.rootProcessIdentifier)
    }

    func testPermissionRoundTripSelectsTheStandardOptionKinds() throws {
        let allowFirst = try permissionOutcome(
            options: [
                ["optionId": "no", "kind": "reject_once"],
                ["optionId": "yes", "kind": "allow_once"],
                ["optionId": "always", "kind": "allow_always"]
            ],
            decision: .allow(reason: "test")
        )
        XCTAssertEqual(allowFirst["outcome"] as? String, "selected")
        XCTAssertEqual(allowFirst["optionId"] as? String, "yes")

        let allowAlways = try permissionOutcome(
            options: [["optionId": "always", "kind": "allow_always"]],
            decision: .allow(reason: "test")
        )
        XCTAssertEqual(allowAlways["optionId"] as? String, "always")

        let denied = try permissionOutcome(
            options: [
                ["optionId": "no", "kind": "reject_once"],
                ["optionId": "never", "kind": "reject_always"]
            ],
            decision: .deny(reason: "test")
        )
        XCTAssertEqual(denied["optionId"] as? String, "no")

        let unrecognised = try permissionOutcome(
            options: [["optionId": "maybe", "kind": "allow-once"]],
            decision: .allow(reason: "test")
        )
        XCTAssertEqual(unrecognised["outcome"] as? String, "cancelled")
        XCTAssertNil(unrecognised["optionId"])
    }

    func testUnhandledServerRequestAnswersMethodNotFound() throws {
        let agent = makeAgent(openedAgentSteps() + [
            .awaitClientLine,
            .emit(FakeACPAgent.serverRequest(
                id: FixtureACP.serverRequestID,
                method: "terminal/create",
                parameters: ["sessionId": FixtureACP.sessionID]
            )),
            .awaitClientLine,
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(agent)
        defer { session.terminate() }

        let finished = expectation(description: "turn finished")
        session.onEvent = { event in
            guard case .turnFinished(_, let outcome, _) = event else { return }
            XCTAssertEqual(outcome, .completed)
            finished.fulfill()
        }

        session.start()
        XCTAssertTrue(session.send("go"))
        wait(for: [finished], timeout: ACPTestDefaults.timeout)

        let answer = try XCTUnwrap(agent.clientLines().first {
            $0["id"] as? String == FixtureACP.serverRequestID
        })
        let error = try XCTUnwrap(answer["error"] as? [String: Any])
        XCTAssertEqual(
            (error["code"] as? NSNumber)?.intValue,
            ACPTestDefaults.methodNotFoundCode
        )
    }

    // MARK: - Framing

    func testMalformedLinesDoNotBreakFraming() {
        let agent = makeAgent(openedAgentSteps() + [
            .awaitClientLine,
            .emit("this line is not JSON at all"),
            .emit(ACPTestDefaults.truncatedJSONLine),
            .emit(FakeACPAgent.update([
                "sessionUpdate": "agent_message_chunk",
                "messageId": "live-1",
                "content": ["type": "text", "text": FixtureACP.liveAgentText]
            ])),
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(agent)
        defer { session.terminate() }

        var events: [StreamEvent] = []
        let finished = expectation(description: "turn finished")
        session.onEvent = { event in
            events.append(event)
            if case .turnFinished = event { finished.fulfill() }
        }

        session.start()
        XCTAssertTrue(session.send("go"))
        wait(for: [finished], timeout: ACPTestDefaults.timeout)

        let shapes = ACPEventShape.shapes(of: events)
        XCTAssertTrue(shapes.contains(.textDelta(FixtureACP.liveAgentText)))
        XCTAssertTrue(shapes.contains(.turnFinished(.completed)))
    }

    func testAPartialLineIsHeldUntilItsNewlineArrives() {
        let notification = FakeACPAgent.update([
            "sessionUpdate": "agent_message_chunk",
            "messageId": "live-1",
            "content": ["type": "text", "text": FixtureACP.splitAgentText]
        ])
        let boundary = notification.index(
            notification.startIndex,
            offsetBy: notification.count / 2
        )
        let agent = makeAgent(openedAgentSteps() + [
            .emitFragment(String(notification[..<boundary])),
            // The client's own prompt is what unblocks the fake, so the fragment is guaranteed
            // to have crossed the pipe before its remainder does.
            .awaitClientLine,
            .emit(String(notification[boundary...])),
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(agent)
        defer { session.terminate() }

        var events: [StreamEvent] = []
        let initialised = expectation(description: "session opened")
        let finished = expectation(description: "turn finished")
        session.onEvent = { event in
            events.append(event)
            switch event {
            case .initialised: initialised.fulfill()
            case .turnFinished: finished.fulfill()
            default: break
            }
        }

        session.start()
        wait(for: [initialised], timeout: ACPTestDefaults.timeout)
        XCTAssertTrue(session.send("go"))
        wait(for: [finished], timeout: ACPTestDefaults.timeout)

        let deltas = ACPEventShape.shapes(of: events).filter {
            if case .textDelta = $0 { return true }
            return false
        }
        XCTAssertEqual(deltas, [.textDelta(FixtureACP.splitAgentText)])
    }

    // MARK: - Process Death

    func testProcessDeathMidTurnSynthesizesStderrAsTheTurnFailure() {
        let diagnosed = runToDeath(standardError: FixtureACP.diagnosticText)
        XCTAssertEqual(diagnosed.text, FixtureACP.diagnosticText)
        XCTAssertEqual(diagnosed.outcome, .failed)
        XCTAssertEqual(diagnosed.exitCount, 1)
        XCTAssertEqual(diagnosed.status, ACPTestDefaults.deathStatus)
        XCTAssertNil(diagnosed.rootProcessIdentifier)

        // Nothing on standard error leaves only the status to report.
        let silent = runToDeath(standardError: nil)
        XCTAssertEqual(
            silent.text,
            ACPTransportMessage.exited(
                FixtureACP.diagnosticsLabel,
                status: ACPTestDefaults.deathStatus
            )
        )
        XCTAssertEqual(silent.outcome, .failed)
        XCTAssertEqual(silent.exitCount, 1)

        // A death the host asked for is not a turn failure to report.
        let agent = makeAgent(openedAgentSteps() + [
            .awaitClientLine,
            .emitStandardError(FixtureACP.diagnosticText),
            .idle
        ])
        let session = makeSession(agent)
        var events: [StreamEvent] = []
        let started = expectation(description: "prompt sent")
        let exited = expectation(description: "transport exited")
        session.onEvent = { event in
            events.append(event)
            if case .initialised = event { started.fulfill() }
        }
        session.onExit = { _ in exited.fulfill() }

        session.start()
        wait(for: [started], timeout: ACPTestDefaults.timeout)
        XCTAssertTrue(session.send("go"))
        session.terminate()
        wait(for: [exited], timeout: ACPTestDefaults.timeout)

        XCTAssertFalse(ACPEventShape.shapes(of: events).contains {
            if case .turnFinished = $0 { return true }
            return false
        })
    }

    func testStandardErrorCaptureIsBounded() {
        let flood = String(
            repeating: FixtureACP.floodCharacter,
            count: ACPDefaults.maximumErrorBytes + ACPTestDefaults.floodOverflowBytes
        )
        let death = runToDeath(standardError: flood)
        XCTAssertEqual(death.outcome, .failed)
        XCTAssertLessThanOrEqual(
            (death.text ?? "").utf8.count,
            ACPDefaults.maximumErrorBytes
        )
    }

    // MARK: - Prompts And Updates

    func testPromptBeforeTheSessionOpensIsBufferedAndSentOnce() {
        let agent = makeAgent(openedAgentSteps() + [
            .requireClientLine(
                containing: "session/prompt",
                otherwiseExit: ACPTestDefaults.mismatchStatus
            ),
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(agent)
        defer { session.terminate() }

        let finished = expectation(description: "turn finished")
        finished.assertForOverFulfill = true
        session.onEvent = { event in
            guard case .turnFinished(_, let outcome, _) = event else { return }
            XCTAssertEqual(outcome, .completed)
            finished.fulfill()
        }

        session.start()
        XCTAssertTrue(session.send("first"))
        XCTAssertFalse(session.canSend)
        XCTAssertFalse(session.send("second"))
        wait(for: [finished], timeout: ACPTestDefaults.timeout)

        let prompts = agent.clientLines().filter { $0["method"] as? String == "session/prompt" }
        XCTAssertEqual(prompts.count, 1)
        let content = (prompts.first?["params"] as? [String: Any])?["prompt"]
            as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "first")
    }

    func testUnknownSessionUpdateUsesTheProfilePrefix() {
        let agent = makeAgent(openedAgentSteps() + [
            .awaitClientLine,
            .emit(FakeACPAgent.update(["sessionUpdate": "weather_update"])),
            .emit(FakeACPAgent.update(["temperature": 21])),
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(agent)
        defer { session.terminate() }

        var events: [StreamEvent] = []
        let finished = expectation(description: "turn finished")
        session.onEvent = { event in
            events.append(event)
            if case .turnFinished = event { finished.fulfill() }
        }

        session.start()
        XCTAssertTrue(session.send("go"))
        wait(for: [finished], timeout: ACPTestDefaults.timeout)

        let shapes = ACPEventShape.shapes(of: events)
        XCTAssertTrue(shapes.contains(
            .unknown("\(FixtureACP.unknownEventPrefix)weather_update")
        ))
        XCTAssertTrue(shapes.contains(
            .unknown("\(FixtureACP.unknownEventPrefix)session_update")
        ))
    }

    func testUpdatesForAnotherSessionAreIgnored() {
        let agent = makeAgent(openedAgentSteps() + [
            .awaitClientLine,
            .emit(FakeACPAgent.update(
                [
                    "sessionUpdate": "agent_message_chunk",
                    "messageId": "foreign-1",
                    "content": ["type": "text", "text": FixtureACP.foreignAgentText]
                ],
                sessionID: FixtureACP.otherSessionID
            )),
            .emit(FakeACPAgent.update([
                "sessionUpdate": "agent_message_chunk",
                "messageId": "live-1",
                "content": ["type": "text", "text": FixtureACP.liveAgentText]
            ])),
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(agent)
        defer { session.terminate() }

        var events: [StreamEvent] = []
        let finished = expectation(description: "turn finished")
        session.onEvent = { event in
            events.append(event)
            if case .turnFinished = event { finished.fulfill() }
        }

        session.start()
        XCTAssertTrue(session.send("go"))
        wait(for: [finished], timeout: ACPTestDefaults.timeout)

        let deltas = ACPEventShape.shapes(of: events).filter {
            if case .textDelta = $0 { return true }
            return false
        }
        XCTAssertEqual(deltas, [.textDelta(FixtureACP.liveAgentText)])
    }

    // MARK: - Command Catalog

    func testCommandCatalogAppliesTheProfilePolicyAndItsBounds() throws {
        let oversized = (0..<ACPTestDefaults.oversizedCatalogCount).map { index in
            ["name": "generated-\(index)", "description": "d"] as [String: Any]
        }
        let agent = makeAgent([
            .awaitClientLine,
            .emit(FakeACPAgent.response(
                id: ACPTestDefaults.initializeRequestID,
                result: ["_meta": ["commands": FixtureACP.advertisedCommands]]
            )),
            .awaitClientLine,
            .emit(FakeACPAgent.response(
                id: ACPTestDefaults.openSessionRequestID,
                result: ["sessionId": FixtureACP.sessionID]
            )),
            .awaitClientLine,
            .emit(FakeACPAgent.update([
                "sessionUpdate": "available_commands_update",
                "availableCommands": oversized
            ])),
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(agent)
        defer { session.terminate() }

        var advertised: [ComposerCapability] = []
        var publications = 0
        let catalog = expectation(description: "catalog published")
        let bounded = expectation(description: "oversized catalog published")
        session.onComposerCapabilitiesChange = {
            publications += 1
            if publications == 1 {
                advertised = session.composerCapabilities
                catalog.fulfill()
            } else {
                bounded.fulfill()
            }
        }
        let finished = expectation(description: "turn finished")
        session.onEvent = { event in
            if case .turnFinished = event { finished.fulfill() }
        }

        session.start()
        wait(for: [catalog], timeout: ACPTestDefaults.timeout)
        XCTAssertTrue(session.send("go"))
        wait(for: [bounded, finished], timeout: ACPTestDefaults.timeout)

        let ordinary = try XCTUnwrap(advertised.first { $0.name == FixtureACP.ordinaryCommand })
        XCTAssertEqual(ordinary.id, "\(FixtureACP.commandPrefix)\(FixtureACP.ordinaryCommand)")
        XCTAssertTrue(ordinary.isEnabled)
        XCTAssertEqual(ordinary.presentation, .turn)

        let refused = try XCTUnwrap(advertised.first { $0.name == FixtureACP.refusedCommand })
        XCTAssertFalse(refused.isEnabled)
        XCTAssertEqual(refused.unavailableReason, FixtureACP.refusalReason)

        let owned = try XCTUnwrap(advertised.first { $0.name == FixtureACP.sessionCommand })
        XCTAssertEqual(owned.presentation, .command)

        XCTAssertEqual(
            session.composerCapabilities.count,
            ComposerCapabilityCatalogPolicy.maximumCapabilities
        )
        XCTAssertEqual(publications, ACPTestDefaults.expectedCatalogPublications)
    }

    // MARK: - Ordering

    func testAssistantTextIsFlushedBeforeItsToolRow() throws {
        let agent = makeAgent(openedAgentSteps() + [
            .awaitClientLine,
            .emit(FakeACPAgent.update([
                "sessionUpdate": "agent_message_chunk",
                "messageId": "live-1",
                "content": ["type": "text", "text": FixtureACP.liveAgentText]
            ])),
            .emit(FakeACPAgent.update([
                "sessionUpdate": "tool_call",
                "toolCallId": FixtureACP.toolCallID,
                "title": "Run checks",
                "kind": "execute",
                "status": "completed",
                "rawInput": ["command": "swift build"],
                "rawOutput": FixtureACP.toolOutputText
            ])),
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(agent)
        defer { session.terminate() }

        var events: [StreamEvent] = []
        let finished = expectation(description: "turn finished")
        session.onEvent = { event in
            events.append(event)
            if case .turnFinished = event { finished.fulfill() }
        }

        session.start()
        XCTAssertTrue(session.send("go"))
        wait(for: [finished], timeout: ACPTestDefaults.timeout)

        let shapes = ACPEventShape.shapes(of: events)
        let text = try XCTUnwrap(shapes.firstIndex(of: .assistantText(FixtureACP.liveAgentText)))
        let tool = try XCTUnwrap(shapes.firstIndex(of: .toolUse(FixtureACP.toolCallID)))
        let result = try XCTUnwrap(shapes.firstIndex(of: .toolResult(FixtureACP.toolOutputText)))
        XCTAssertLessThan(text, tool)
        XCTAssertLessThan(tool, result)
    }

    // MARK: - Fixtures

    private func makeAgent(_ steps: [FakeACPStep]) -> FakeACPAgent {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ACPStreamSessionTests-\(UUID().uuidString).jsonl",
                isDirectory: false
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: transcript) }
        return FakeACPAgent(steps: steps, transcript: transcript)
    }

    private func makeSession(
        _ agent: FakeACPAgent,
        profile: ACPProviderProfile = FixtureACP.profile(),
        resumeState: ResumeState = .unavailable,
        handshakeTimeout: TimeInterval = ACPDefaults.handshakeTimeout,
        environmentOverrides: [String: String] = [:]
    ) -> ACPStreamSession {
        ACPStreamSession(
            sessionID: SessionID(),
            workingDirectory: FixtureACP.workingDirectory,
            profile: profile,
            handshakeTimeout: handshakeTimeout
        ) {
            agent.launchPlan(
                resumeState: resumeState,
                environmentOverrides: environmentOverrides
            )
        }
    }

    /// The steps every agent shares: answer `initialize`, then open the session.
    private func openedAgentSteps() -> [FakeACPStep] {
        [
            .awaitClientLine,
            .emit(FakeACPAgent.response(id: ACPTestDefaults.initializeRequestID, result: [:])),
            .awaitClientLine,
            .emit(FakeACPAgent.response(
                id: ACPTestDefaults.openSessionRequestID,
                result: ["sessionId": FixtureACP.sessionID]
            ))
        ]
    }

    private struct ACPDeathReport {
        var text: String?
        var outcome: TurnOutcome?
        var status: Int32?
        var exitCount: Int
        var rootProcessIdentifier: pid_t?
    }

    private func runToDeath(standardError: String?) -> ACPDeathReport {
        var steps = openedAgentSteps() + [FakeACPStep.awaitClientLine]
        if let standardError {
            steps.append(.emitStandardError(standardError))
        }
        steps.append(.exit(ACPTestDefaults.deathStatus))

        let session = makeSession(makeAgent(steps))
        defer { session.terminate() }

        var report = ACPDeathReport(exitCount: 0)
        let finished = expectation(description: "turn failed")
        let exited = expectation(description: "transport exited")
        session.onEvent = { event in
            guard case .turnFinished(let text, let outcome, _) = event else { return }
            report.text = text
            report.outcome = outcome
            finished.fulfill()
        }
        session.onExit = { status in
            report.status = status
            report.exitCount += 1
            exited.fulfill()
        }

        session.start()
        XCTAssertTrue(session.send("go"))
        wait(for: [finished, exited], timeout: ACPTestDefaults.timeout)
        report.rootProcessIdentifier = session.rootProcessIdentifier
        return report
    }

    /// Runs one permission-gated tool call to its end and returns the row the timeline receives.
    ///
    /// `completion` is merged into the closing `tool_call_update`, which is the only thing that
    /// differs between the wire behaviours under test.
    private func toolResult(
        decision: PermissionDecision,
        completion: [String: Any]
    ) throws -> ToolResult {
        var closingUpdate: [String: Any] = [
            "sessionUpdate": "tool_call_update",
            "toolCallId": FixtureACP.toolCallID
        ]
        closingUpdate.merge(completion) { _, new in new }

        let agent = makeAgent(openedAgentSteps() + [
            .awaitClientLine,
            .emit(FakeACPAgent.update([
                "sessionUpdate": "tool_call",
                "toolCallId": FixtureACP.toolCallID,
                "title": "Run checks",
                "kind": "execute",
                "status": "pending",
                "rawInput": ["command": FixtureACP.reviewedCommand]
            ])),
            .emit(FakeACPAgent.serverRequest(
                id: FixtureACP.serverRequestID,
                method: "session/request_permission",
                parameters: [
                    "sessionId": FixtureACP.sessionID,
                    "toolCall": [
                        "toolCallId": FixtureACP.toolCallID,
                        "title": "Run checks",
                        "kind": "execute",
                        "status": "pending"
                    ],
                    "options": FixtureACP.permissionOptions
                ]
            )),
            .awaitClientLine,
            .emit(FakeACPAgent.update(closingUpdate)),
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(agent)
        let previousPresenter = PermissionBroker.present
        PermissionBroker.present = { _, completion in completion(decision) }
        defer {
            session.terminate()
            PermissionBroker.present = previousPresenter
        }

        var results: [ToolResult] = []
        let finished = expectation(description: "turn finished")
        session.onEvent = { event in
            if case .toolResults(let values) = event { results.append(contentsOf: values) }
            if case .turnFinished = event { finished.fulfill() }
        }

        session.start()
        XCTAssertTrue(session.send("go"))
        wait(for: [finished], timeout: ACPTestDefaults.timeout)

        XCTAssertEqual(results.count, 1)
        return try XCTUnwrap(results.first)
    }

    private func permissionOutcome(
        options: [[String: Any]],
        decision: PermissionDecision
    ) throws -> [String: Any] {
        let agent = makeAgent(openedAgentSteps() + [
            .awaitClientLine,
            .emit(FakeACPAgent.serverRequest(
                id: FixtureACP.serverRequestID,
                method: "session/request_permission",
                parameters: [
                    "sessionId": FixtureACP.sessionID,
                    "toolCall": [
                        "toolCallId": FixtureACP.toolCallID,
                        "title": "Run checks",
                        "kind": "execute",
                        "rawInput": ["command": FixtureACP.reviewedCommand]
                    ],
                    "options": options
                ]
            )),
            .awaitClientLine,
            .emit(FakeACPAgent.promptResponse(stopReason: "end_turn")),
            .idle
        ])
        let session = makeSession(agent)
        let previousPresenter = PermissionBroker.present
        PermissionBroker.present = { request, completion in
            XCTAssertEqual(request.tool, .bash)
            completion(decision)
        }
        defer {
            session.terminate()
            PermissionBroker.present = previousPresenter
        }

        let finished = expectation(description: "turn finished")
        session.onEvent = { event in
            if case .turnFinished = event { finished.fulfill() }
        }

        session.start()
        XCTAssertTrue(session.send("go"))
        wait(for: [finished], timeout: ACPTestDefaults.timeout)

        let answer = try XCTUnwrap(agent.clientLines().first {
            $0["id"] as? String == FixtureACP.serverRequestID
        })
        let result = try XCTUnwrap(answer["result"] as? [String: Any])
        return try XCTUnwrap(result["outcome"] as? [String: Any])
    }
}

// MARK: - Event Shapes

/// A flattened event, so ordering can be asserted without matching whole payloads.
private enum ACPEventShape: Equatable {
    case initialised
    case userMessage(String)
    case textDelta(String)
    case thinkingDelta(String)
    case assistantText(String)
    case assistantThinking(String)
    case toolUse(String)
    case toolResult(String)
    case unknown(String)
    case turnFinished(TurnOutcome)
    case other

    static func shapes(of events: [StreamEvent]) -> [ACPEventShape] {
        events.flatMap { event -> [ACPEventShape] in
            switch event {
            case .initialised:
                return [.initialised]
            case .userMessage(let text):
                return [.userMessage(text)]
            case .textDelta(let text):
                return [.textDelta(text)]
            case .thinkingDelta(let text):
                return [.thinkingDelta(text)]
            case .assistantMessage(let blocks):
                return blocks.map { block in
                    switch block {
                    case .text(let text): return .assistantText(text)
                    case .thinking(let text): return .assistantThinking(text)
                    case .toolUse(let id, _, _): return .toolUse(id)
                    }
                }
            case .toolResults(let results):
                return results.map { .toolResult($0.text) }
            case .unknown(let type):
                return [.unknown(type)]
            case .turnFinished(_, let outcome, _):
                return [.turnFinished(outcome)]
            default:
                return [.other]
            }
        }
    }
}

// MARK: - Fake Agent

private enum FakeACPStep {
    case awaitClientLine

    /// Reads one client line and refuses to continue unless it matches.
    ///
    /// The distinctive exit status is the point: a fake that is handed the wrong line dies, the
    /// runtime reports a failed turn, and the test fails on its assertion instead of waiting for
    /// a reply that is never coming.
    case matchClientLine(containing: [String], notContaining: [String], otherwiseExit: Int32)

    case emit(String)

    /// Writes without a trailing newline, so the client holds an incomplete line.
    case emitFragment(String)

    case emitStandardError(String)

    /// Appends the child's own value for one environment variable to the transcript.
    case recordEnvironment(String)

    /// Appends a fixed word to the transcript when one environment variable is set at all.
    case recordEnvironmentPresence(String)

    /// Answers late, but still inside the deadline.
    case pause(TimeInterval)

    case exit(Int32)

    /// Stays alive until the client closes its end.
    case idle

    static func requireClientLine(
        containing text: String,
        otherwiseExit status: Int32
    ) -> FakeACPStep {
        .matchClientLine(containing: [text], notContaining: [], otherwiseExit: status)
    }

    static func requireClientLine(
        notContaining text: String,
        otherwiseExit status: Int32
    ) -> FakeACPStep {
        .matchClientLine(containing: [], notContaining: [text], otherwiseExit: status)
    }
}

/// A scripted ACP agent, rendered as a `/bin/sh` program.
///
/// Every line the client writes is appended to `transcript` before the script answers, so a test
/// asserts against the bytes that actually crossed the pipe rather than against a substring the
/// shell happened to match.
private struct FakeACPAgent {
    let steps: [FakeACPStep]
    let transcript: URL

    func launchPlan(
        resumeState: ResumeState,
        environmentOverrides: [String: String] = [:]
    ) -> AgentLaunchPlan {
        AgentLaunchPlan(
            executable: FakeACPDefaults.shell,
            arguments: [FakeACPDefaults.commandFlag, script],
            resumeState: resumeState,
            environmentOverrides: environmentOverrides
        )
    }

    func clientLines() -> [[String: Any]] {
        guard let text = try? String(contentsOf: transcript, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    // MARK: - Wire Helpers

    static func response(id: Int, result: [String: Any]) -> String {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func errorResponse(id: Int, message: String) -> String {
        line(["jsonrpc": "2.0", "id": id, "error": ["message": message]])
    }

    static func promptResponse(stopReason: String) -> String {
        response(id: ACPTestDefaults.promptRequestID, result: ["stopReason": stopReason])
    }

    static func serverRequest(
        id: String,
        method: String,
        parameters: [String: Any]
    ) -> String {
        line(["jsonrpc": "2.0", "id": id, "method": method, "params": parameters])
    }

    static func update(
        _ update: [String: Any],
        sessionID: String = FixtureACP.sessionID
    ) -> String {
        line([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": ["sessionId": sessionID, "update": update]
        ])
    }

    static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Script

    private var script: String {
        var lines: [String] = []
        for step in steps {
            switch step {
            case .awaitClientLine:
                lines.append(contentsOf: readClientLine())

            case .matchClientLine(let containing, let notContaining, let status):
                lines.append(contentsOf: readClientLine())
                for text in containing {
                    lines.append("case \"$line\" in \(pattern(text))) ;; *) exit \(status) ;; esac")
                }
                for text in notContaining {
                    lines.append("case \"$line\" in \(pattern(text))) exit \(status) ;; *) ;; esac")
                }

            case .emit(let text):
                lines.append("printf '%s\\n' \(quoted(text))")

            case .emitFragment(let text):
                lines.append("printf '%s' \(quoted(text))")

            case .emitStandardError(let text):
                lines.append("printf '%s' \(quoted(text)) >&2")

            case .recordEnvironment(let name):
                lines.append(
                    "printf '{\"env\":\"%s\"}\\n' \"$\(name)\" >> \(quoted(transcript.path))"
                )

            case .recordEnvironmentPresence(let name):
                lines.append(
                    "test -n \"$\(name)\" && printf '{\"env\":\"%s\"}\\n' "
                        + "\(quoted(ACPTestDefaults.presentEnvironmentValue)) "
                        + ">> \(quoted(transcript.path))"
                )

            case .pause(let seconds):
                lines.append("sleep \(seconds)")

            case .exit(let status):
                lines.append("exit \(status)")

            case .idle:
                lines.append("cat >/dev/null")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func readClientLine() -> [String] {
        [
            "read -r line",
            "printf '%s\\n' \"$line\" >> \(quoted(transcript.path))"
        ]
    }

    /// Foundation writes `/` as `\/`, so a pattern naming an ACP method has to match the
    /// bytes the client actually put on the wire rather than the method as it is spelled.
    private func pattern(_ text: String) -> String {
        let escaped = text.replacingOccurrences(
            of: FakeACPDefaults.methodSeparator,
            with: FakeACPDefaults.escapedMethodSeparator
        )
        return "*\(quoted(escaped))*"
    }

    /// Single-quoting is the only escaping this fake does, so a step carrying one would end the
    /// quotation and hand the rest of its own text to the shell.
    private func quoted(_ text: String) -> String {
        precondition(
            !text.contains(FakeACPDefaults.quote),
            "a fake ACP agent step must not contain a single quote"
        )
        return "\(FakeACPDefaults.quote)\(text)\(FakeACPDefaults.quote)"
    }
}

// MARK: - Constants

private enum FakeACPDefaults {
    static let shell = "/bin/sh"
    static let commandFlag = "-c"
    static let quote = "'"
    static let methodSeparator = "/"
    static let escapedMethodSeparator = "\\/"
}

private enum ACPTestDefaults {
    static let timeout: TimeInterval = 10

    /// The request identities the runtime mints, in the order it sends them.
    static let initializeRequestID = 1
    static let openSessionRequestID = 2
    static let promptRequestID = 3

    /// Distinctive so a failed turn names the fake's refusal rather than a plausible CLI status.
    static let mismatchStatus: Int32 = 91
    static let deathStatus: Int32 = 3

    static let methodNotFoundCode = -32601
    static let requestIDMember = "\"id\":"
    static let truncatedJSONLine = "{\"jsonrpc\":\"2.0\",\"method\":"
    static let floodOverflowBytes = 8 * 1_024
    static let oversizedCatalogCount = 300
    static let expectedCatalogPublications = 2

    /// Short enough to expire inside a test, long enough that the slow agent below still beats
    /// it twice on a loaded machine.
    static let shortHandshakeTimeout: TimeInterval = 2
    static let slowHandshakePause: TimeInterval = 0.4

    /// Not a variable any launch of ours sets, so a value here can only have come from the plan.
    static let overriddenEnvironmentName = "THREADING_ACP_FIXTURE_ENV"
    static let overriddenEnvironmentValue = "fixture-value"
    static let presentEnvironmentValue = "present"
}

private enum FixtureACP {
    static let displayName = "Fixture"
    static let diagnosticsLabel = "Fixture ACP"
    static let unknownEventPrefix = "fixture.acp."
    static let commandPrefix = "fixture.command:"
    static let metaKey = "fixtureChannel"
    static let metaValue = "beta"

    static let workingDirectory = "/tmp"
    static let sessionID = "fixture-1"
    static let otherSessionID = "fixture-2"
    static let serverRequestID = "request-1"
    static let toolCallID = "tool-1"

    /// Two provider ids joined by a literal newline, as one shipping agent spells them.
    static let multilineToolCallID = "call-1\nfc_2"

    static let ordinaryCommand = "deep-research"
    static let refusedCommand = "reset-agent"
    static let sessionCommand = "condense"
    static let refusalReason = "Available in the fixture terminal only"

    static let replayedUserText = "what did we decide"
    static let replayedAgentText = "we decided to rewrite it"
    static let droppedUserText = "this arrived too late to be history"
    static let liveAgentText = "still here"
    static let splitAgentText = "held until the newline"
    static let foreignAgentText = "meant for another session"
    static let diagnosticText = "boom"
    static let refusalText = "the fixture refuses to initialize"
    static let toolOutputText = "checks passed"
    static let toolFailureText = "checks failed"
    static let reviewedCommand = "swift test"
    static let floodCharacter = "x"

    /// The three options one measured agent always sends — note there is no `reject_always`.
    static var permissionOptions: [[String: Any]] {
        [
            ["optionId": "allow-once", "name": "Allow once", "kind": "allow_once"],
            ["optionId": "allow-always", "name": "Allow always", "kind": "allow_always"],
            ["optionId": "reject-once", "name": "Reject", "kind": "reject_once"]
        ]
    }

    static var advertisedCommands: [[String: Any]] {
        [
            ["name": ordinaryCommand, "description": "Research", "input": ["hint": "query"]],
            ["name": refusedCommand, "description": "Start over"],
            ["name": sessionCommand, "description": "Condense"]
        ]
    }

    static func profile(meta: [String: Any] = [metaKey: metaValue]) -> ACPProviderProfile {
        ACPProviderProfile(
            displayName: displayName,
            diagnosticsLabel: diagnosticsLabel,
            unknownEventPrefix: unknownEventPrefix,
            clientCapabilitiesMeta: meta,
            extendedModelID: { result in
                (result?["_meta"] as? [String: Any])?["model"] as? String
            },
            initializeCommands: { result in
                (result?["_meta"] as? [String: Any])?["commands"] as? [[String: Any]]
            },
            commandCatalog: ACPCommandCatalogPolicy(
                identifierPrefix: commandPrefix,
                hostOnlyNames: [refusedCommand],
                hostOnlyReason: refusalReason,
                sessionCommandNames: [sessionCommand]
            )
        )
    }
}
