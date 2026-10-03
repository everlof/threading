import XCTest
@testable import Threading

/// A native conversation reports why the provider refused its turn from Claude's typed fields,
/// through the shipping transport. The unattended automation that failed on 2026-10-03 needed
/// exactly this fact to say "your login stopped signing in" instead of "ended without a result".
@MainActor
final class ConversationTurnFailureTests: HostedStoreTestCase {

    /// The first turn is refused the way CLI 2.1.288 refuses an invalid login (measured
    /// 2026-10-03); the second is answered normally.
    private static let fakeClaude = """
    import json, sys
    def out(o):
        sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
    sid = "fixture-session"
    turn = 0
    for line in sys.stdin:
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if m.get("type") == "control_request":
            out({"type": "control_response", "response": {"subtype": "success",
                 "request_id": m.get("request_id"), "response": {}}})
        elif m.get("type") == "user":
            turn += 1
            out({"type": "system", "subtype": "init", "session_id": sid,
                 "model": "claude-opus-5-5", "tools": [], "slash_commands": []})
            if turn == 1:
                out({"type": "system", "subtype": "api_retry", "attempt": 1, "max_retries": 10,
                     "error": "authentication_failed", "error_status": 401, "session_id": sid})
                out({"type": "assistant", "error": "authentication_failed",
                     "is_api_error_message": True, "parent_tool_use_id": None,
                     "session_id": sid, "message": {"model": "<synthetic>", "content": [
                         {"type": "text",
                          "text": "Failed to authenticate. API Error: 401 OAuth access token is invalid."}]}})
                out({"type": "result", "subtype": "success", "is_error": True,
                     "api_error_status": 401, "terminal_reason": "api_error",
                     "result": "Failed to authenticate. API Error: 401 OAuth access token is invalid.",
                     "duration_ms": 10, "num_turns": 1, "session_id": sid})
            else:
                out({"type": "assistant", "session_id": sid, "message": {"id": "m2",
                     "role": "assistant", "model": "claude-opus-5-5",
                     "content": [{"type": "text", "text": "Signed in again"}]}})
                out({"type": "result", "subtype": "success", "is_error": False,
                     "result": "Signed in again", "duration_ms": 10, "num_turns": 1,
                     "session_id": sid})
    """

    func testAnAuthenticationRefusalIsReportedAndClearedByTheNextTurn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-turn-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let session = try XCTUnwrap(store.addSession(
            to: project.id, kind: .claude, usesNativeUI: true, title: "Automation"
        ))
        XCTAssertTrue(store.update(sessionID: session.id) { $0.backgroundHost = false }.succeeded)

        let controller = try XCTUnwrap(ConversationViewController(
            agentSession: session,
            project: project,
            currentSessionProjection: CurrentSessionProjection { sessionID in
                store.project(withID: project.id)?.sessions.first { $0.id == sessionID }
            },
            launchPlanProvider: { _, _, _ in
                AgentLaunchPlan(
                    executable: "/usr/bin/python3",
                    arguments: ["-u", "-c", Self.fakeClaude],
                    resumeState: .unavailable
                )
            },
            customizationLookup: { _ in .empty }
        ))
        _ = controller.view
        defer { controller.terminate(preservingViewport: false) }

        controller.launch()
        controller.sendInitialPrompt("Run the saved automation")
        XCTAssertTrue(waitUntil { controller.stream.canSend && controller.lastTurnFailure != nil },
                      "the refused turn never settled")
        XCTAssertEqual(controller.lastTurnFailure, .authenticationFailed)

        // The composer's own submit path, the one a person typing would take.
        controller.sendInitialPrompt("Try again")
        XCTAssertTrue(waitUntil {
            controller.timeline.rows.contains { row in
                if case .assistant(let text) = row { return text.contains("Signed in again") }
                return false
            } && controller.stream.canSend
        }, "the second turn never finished")
        XCTAssertNil(controller.lastTurnFailure, "a later turn must not inherit an older refusal")
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
