import XCTest
@testable import Threading

@MainActor
final class TerminalLaunchAttentionTests: HostedStoreTestCase {
    func testSelectedPromptLaunchStaysQuietWhenUserSwitchesAwayDuringBoot() throws {
        let controller = try launch(initialPrompt: nil)
        defer { controller.terminate() }
        controller.isVisible = false
        drainBootOutput()
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.activity, .idle)
        XCTAssertEqual(controller.activityTracker.runtimeSnapshot.blocker, .none)

        controller.activityTracker.noteTurnStarted()
        controller.activityTracker.noteTurnFinished()
        XCTAssertEqual(controller.activity, .needsAttention,
                       "the first actual turn must end startup suppression")
    }

    func testLaunchWithNewWorkStillInfersItsActivity() throws {
        let controller = try launch(initialPrompt: "New work")
        defer { controller.terminate() }
        controller.isVisible = false
        drainBootOutput()
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.activity, .needsAttention,
                       "a submitted opening prompt must not lose output inference")
    }

    private func launch(initialPrompt: String?) throws -> AgentSessionViewController {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(
            folderURL: FileManager.default.temporaryDirectory
        ))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude))
        XCTAssertTrue(ProjectStore.shared.update(sessionID: session.id) {
            $0.backgroundHost = false
        }.succeeded)
        let controller = AgentSessionViewController(agentSession: session, launchPlanProvider: { _, _, _ in
            // The real controller and PTY, with deterministic startup paint and no provider.
            let paint = String(repeating: "restored screen ", count: 64)
            return AgentLaunchPlan(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s' '\(paint)'; exec /bin/cat"],
                resumeState: .unavailable
            )
        })
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        controller.isVisible = true
        controller.launch(initialPrompt: initialPrompt)
        return controller
    }

    private func drainBootOutput() {
        RunLoop.main.run(until: Date().addingTimeInterval(2))
    }
}
