import XCTest
@testable import Threading

final class RunPlanProgressTests: XCTestCase {

    func testHookReportNormalizesCodexAndClaudePayloadSpellings() throws {
        let sessionID = SessionID()
        let codex = try XCTUnwrap(HookRunProgressReport(
            sessionID: sessionID,
            phase: .toolUse,
            payload: [
                "tool_call_id": "plan-1",
                "tool_name": "update_plan",
                "tool_input": [
                    "plan": [
                        ["step": "Inspect", "status": "completed"],
                        ["step": "Implement", "status": "in_progress"],
                    ]
                ],
            ]
        ))

        guard case .toolUse(let id, let tool, let input) = codex.mutation else {
            return XCTFail("Expected a plan tool mutation")
        }
        XCTAssertEqual(id, "plan-1")
        XCTAssertEqual(tool, .plan)
        XCTAssertNotNil(input["plan"])

        let claude = try XCTUnwrap(HookRunProgressReport(
            sessionID: sessionID,
            phase: .toolFailure,
            payload: [
                "toolUseID": "create-1",
                "error": ["message": "create failed"],
            ]
        ))
        guard case .result(let result) = claude.mutation else {
            return XCTFail("Expected a task result mutation")
        }
        XCTAssertEqual(result.toolUseID, "create-1")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("create failed"))
    }

    func testRunProgressEndpointOnlyAdmitsKnownPhases() {
        XCTAssertEqual(
            MCPServer.runProgressPhase(inQuery: "phase=toolUse"),
            .toolUse
        )
        XCTAssertEqual(
            MCPServer.runProgressPhase(inQuery: "ignored=x&phase=toolFailure"),
            .toolFailure
        )
        XCTAssertNil(MCPServer.runProgressPhase(inQuery: "phase=unknown"))
        XCTAssertNil(MCPServer.runProgressPhase(inQuery: nil))
    }

    @MainActor
    func testTerminalMonitorWithdrawsAPlanAtItsPerTurnMutationBudget() async throws {
        let monitor = TerminalRunProgressMonitor()
        let callbacks = expectation(description: "bounded mutation callbacks")
        callbacks.expectedFulfillmentCount = RunProgressLimits.maximumObservedMutationsPerTurn + 1
        var nilCallbacks = 0

        for index in 0...RunProgressLimits.maximumObservedMutationsPerTurn {
            let report = try XCTUnwrap(HookRunProgressReport(
                sessionID: SessionID(),
                phase: .toolUse,
                payload: [
                    "tool_call_id": "plan-\(index)",
                    "tool_name": "update_plan",
                    "tool_input": [
                        "plan": [["step": "Bounded", "status": "in_progress"]],
                    ],
                ]
            ))
            monitor.apply(report) { progress in
                if progress == nil { nilCallbacks += 1 }
                callbacks.fulfill()
            }
        }

        await fulfillment(of: [callbacks], timeout: 5)
        XCTAssertEqual(nilCallbacks, 1)

        let began = expectation(description: "next turn begins")
        monitor.beginTurn { progress in
            XCTAssertNil(progress)
            began.fulfill()
        }
        await fulfillment(of: [began], timeout: 2)

        let recovery = try XCTUnwrap(HookRunProgressReport(
            sessionID: SessionID(),
            phase: .toolUse,
            payload: [
                "tool_call_id": "recovered-plan",
                "tool_name": "update_plan",
                "tool_input": [
                    "plan": [["step": "Recovered", "status": "in_progress"]],
                ],
            ]
        ))
        let recovered = expectation(description: "next turn recovers")
        monitor.apply(recovery) { progress in
            XCTAssertEqual(progress?.currentStep?.title, "Recovered")
            recovered.fulfill()
        }
        await fulfillment(of: [recovered], timeout: 2)
    }

    @MainActor
    func testTerminalMonitorKeepsItsTranscriptCursorAcrossTurnClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-run-plan-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        let records = [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"implement"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","call_id":"plan-1","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Inspect\",\"status\":\"completed\"},{\"step\":\"Implement\",\"status\":\"in_progress\"}]}"}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(records.utf8).write(to: transcript)

        let monitor = TerminalRunProgressMonitor()
        let first = expectation(description: "initial scan")
        monitor.scan(at: transcript, kind: .codex) { result in
            XCTAssertEqual(result.progress?.currentStep?.title, "Implement")
            XCTAssertEqual(result.progress?.steps.count, 2)
            XCTAssertFalse(result.hasMore)
            first.fulfill()
        }
        await fulfillment(of: [first], timeout: 2)

        let cleared = expectation(description: "turn cleared")
        monitor.endTurn { progress in
            XCTAssertNil(progress)
            cleared.fulfill()
        }
        await fulfillment(of: [cleared], timeout: 2)

        // With a persistent byte cursor, re-scanning an unchanged rollout reads no records and
        // cannot resurrect the completed turn's plan.
        let second = expectation(description: "rescan")
        monitor.scan(at: transcript, kind: .codex) { result in
            XCTAssertNil(result.progress)
            XCTAssertFalse(result.hasMore)
            second.fulfill()
        }
        await fulfillment(of: [second], timeout: 2)
    }

    @MainActor
    func testFirstTranscriptHydrationCannotReplaceANewerHookPlan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-run-plan-hook-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try Data(([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"old"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","call_id":"old-plan","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Old task\",\"status\":\"in_progress\"}]}"}}"#,
        ].joined(separator: "\n") + "\n").utf8).write(to: transcript)

        let monitor = TerminalRunProgressMonitor()
        let began = expectation(description: "turn began")
        monitor.beginTurn { _ in began.fulfill() }
        await fulfillment(of: [began], timeout: 2)

        let report = try XCTUnwrap(HookRunProgressReport(
            sessionID: SessionID(),
            phase: .toolUse,
            payload: [
                "tool_call_id": "new-plan",
                "tool_name": "update_plan",
                "tool_input": [
                    "plan": [["step": "Current task", "status": "in_progress"]],
                ],
            ]
        ))
        let hooked = expectation(description: "hook applied")
        monitor.apply(report) { progress in
            XCTAssertEqual(progress?.currentStep?.title, "Current task")
            hooked.fulfill()
        }
        await fulfillment(of: [hooked], timeout: 2)

        let scanned = expectation(description: "transcript hydrated")
        monitor.scan(at: transcript, kind: .codex) { result in
            XCTAssertEqual(result.progress?.currentStep?.title, "Current task")
            XCTAssertFalse(result.hasMore)
            scanned.fulfill()
        }
        await fulfillment(of: [scanned], timeout: 2)
    }

    @MainActor
    func testDelayedTurnStartInKnownTranscriptCannotEraseANewerHookPlan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-run-plan-known-hook-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try Data().write(to: transcript)

        let monitor = TerminalRunProgressMonitor()
        let discovered = expectation(description: "transcript discovered")
        monitor.scan(at: transcript, kind: .codex) { _ in discovered.fulfill() }
        await fulfillment(of: [discovered], timeout: 2)

        let began = expectation(description: "turn began")
        monitor.beginTurn { _ in began.fulfill() }
        await fulfillment(of: [began], timeout: 2)

        let report = try XCTUnwrap(HookRunProgressReport(
            sessionID: SessionID(),
            phase: .toolUse,
            payload: [
                "tool_call_id": "live-plan",
                "tool_name": "update_plan",
                "tool_input": [
                    "plan": [["step": "Keep the live plan", "status": "in_progress"]],
                ],
            ]
        ))
        let hooked = expectation(description: "hook applied")
        monitor.apply(report) { _ in hooked.fulfill() }
        await fulfillment(of: [hooked], timeout: 2)

        try Data(
            (#"{"type":"event_msg","payload":{"type":"user_message","message":"go"}}"# + "\n").utf8
        ).write(to: transcript)

        let scanned = expectation(description: "delayed turn start scanned")
        monitor.scan(at: transcript, kind: .codex) { result in
            XCTAssertEqual(result.progress?.currentStep?.title, "Keep the live plan")
            scanned.fulfill()
        }
        await fulfillment(of: [scanned], timeout: 2)
    }
}
