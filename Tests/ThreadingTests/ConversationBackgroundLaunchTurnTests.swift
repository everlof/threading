import XCTest
@testable import Threading

/// An unattended automation run is settled by the first runtime edge on which its session stops
/// owing an outcome. On 2026-10-03 a run was still settled about a second after launch while its
/// agent went on working, after `ConversationOpeningTurnTests` had already kept Claude's first
/// `system/init` inside the opening turn. This drives the whole background launch through the
/// shipping transport instead of single events: `launch()` then `sendInitialPrompt` at once, as
/// `TerminalContainerViewController.launchInBackground` does, against a fake Claude that answers
/// the control handshake after a boot delay and only then runs the prompt.
///
/// What it caught: the prompt waits in the outbox until replay ends, `stream.start()` drains it
/// synchronously, and `finishReplayAndStart`'s Ready on the next line ended the turn just
/// admitted, so the run's real end later produced no edge at all.
@MainActor
final class ConversationBackgroundLaunchTurnTests: HostedStoreTestCase {

    @MainActor private final class Recorder: ConversationViewControllerDelegate {
        var ledger = SessionRuntimeTransitionLedger()
        var edges: [(transition: SessionRuntimeTransition, replied: Bool)] = []
        var replied: () -> Bool = { false }

        func conversationDidChangeActivity(_ controller: ConversationViewController) {
            let transition = ledger.observe(controller.runtimeSnapshot, for: controller.sessionID)
            guard transition.previous != transition.current else { return }
            edges.append((transition, replied()))
        }
        func conversation(_ controller: ConversationViewController, didExitWithCode code: Int32) {}
        func conversationSubagentsDidChange(_ controller: ConversationViewController) {}
        func conversation(_ controller: ConversationViewController, didSelectSubagent agent: SubagentTimeline.Agent) {}
        func conversation(_ controller: ConversationViewController, didUpdateSelectedSubagent agent: SubagentTimeline.Agent) {}
        func conversation(_ controller: ConversationViewController, didRequestTurnDiff checkpointID: GitTurnCheckpointID) {}
        func conversation(_ controller: ConversationViewController, didRequestOpenSession sessionID: SessionID) {}
        func conversation(_ controller: ConversationViewController, didRequestUsageFor accountID: AccountID?) {}
    }

    /// A stand-in for the CLI's stream-json side: every control request is answered after a
    /// boot delay, and the user message is run as one ordinary turn ending in a `result`.
    private static let fakeClaude = """
    import json, sys, time
    def out(o):
        sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
    sid = "fixture-session"
    for line in sys.stdin:
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if m.get("type") == "control_request":
            time.sleep(0.4)
            out({"type": "control_response", "response": {"subtype": "success",
                 "request_id": m.get("request_id"), "response": {}}})
        elif m.get("type") == "user":
            out({"type": "system", "subtype": "init", "session_id": sid,
                 "model": "claude-opus-5-5", "tools": [], "slash_commands": []})
            time.sleep(0.4)
            out({"type": "assistant", "session_id": sid, "message": {"id": "m1",
                 "role": "assistant", "model": "claude-opus-5-5",
                 "content": [{"type": "text", "text": "Automation finished"}]}})
            out({"type": "result", "subtype": "success", "is_error": False,
                 "result": "Automation finished", "duration_ms": 400, "num_turns": 1,
                 "session_id": sid})
    """

    func testABackgroundLaunchOwesItsOutcomeUntilThePromptTurnFinishes() throws {
        // Not a git checkout, like the automations folder the failing run used.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-background-launch-\(UUID().uuidString)")
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
        let recorder = Recorder()
        recorder.replied = {
            controller.timeline.rows.contains { row in
                if case .assistant(let text) = row { return text.contains("Automation finished") }
                return false
            }
        }
        controller.delegate = recorder
        _ = controller.view
        defer { controller.terminate(preservingViewport: false) }

        // `launchInBackground`'s order: start the surface, then hand over the opening prompt.
        controller.launch()
        controller.sendInitialPrompt("Run the saved automation")

        XCTAssertTrue(waitUntil(timeout: 10) { recorder.replied() && !controller.isTurnInFlight },
                      "the fixture turn never finished")

        let described = recorder.edges.map { edge in
            "\(edge.transition.previous.hasPendingOutcome)->\(edge.transition.current.hasPendingOutcome)"
                + (edge.replied ? " after reply" : " before reply")
        }
        let premature = recorder.edges.filter { $0.transition.completedPendingOutcome && !$0.replied }
        XCTAssertTrue(premature.isEmpty,
                      "the session stopped owing an outcome before its prompt's turn finished: \(described)")
        XCTAssertEqual(recorder.edges.filter { $0.transition.completedPendingOutcome }.count, 1,
                       "the prompt's turn must end exactly once: \(described)")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
