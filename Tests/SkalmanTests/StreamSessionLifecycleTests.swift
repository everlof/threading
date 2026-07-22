import XCTest
@testable import Skalman

final class StreamSessionLifecycleTests: XCTestCase {

    func testClaudeSpawnFailureArrivesAsynchronouslyOnMain() {
        let exited = expectation(description: "spawn failure callback")
        var startReturned = false

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            AgentLaunchPlan(
                executable: "/path/that/does/not/exist/claude",
                arguments: [],
                resumeState: .unavailable
            )
        }
        session.onExit = { status in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(startReturned)
            XCTAssertEqual(status, -1)
            exited.fulfill()
        }

        session.start()
        startReturned = true

        wait(for: [exited], timeout: 1)
    }

    func testClaudeSurfacesCappedStderrBeforeFailedExit() {
        let diagnosticReceived = expectation(description: "stderr diagnostic")
        let exited = expectation(description: "failed child exit")
        var receivedDiagnostic = false

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "/bin/cat >/dev/null; "
                    + "printf 'claude exploded' >&2; /bin/sleep 0.05; exit 7"
            )
        }
        session.onEvent = { event in
            guard case .turnFinished(let text, let isError) = event else { return }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(text, "claude exploded")
            XCTAssertTrue(isError)
            receivedDiagnostic = true
            diagnosticReceived.fulfill()
        }
        session.onExit = { status in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(receivedDiagnostic)
            XCTAssertEqual(status, 7)
            exited.fulfill()
        }

        session.start()
        session.finish()

        wait(for: [diagnosticReceived, exited], timeout: 2)
    }

    func testCodexTerminalEventIsDeliveredOnceOnMain() {
        let finished = expectation(description: "terminal event")
        let duplicate = expectation(description: "duplicate terminal event")
        duplicate.isInverted = true
        var finishCount = 0

        let session = CodexStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "/bin/cat >/dev/null; "
                    + "printf '%s\\n' '{\"type\":\"turn.completed\"}'; "
                    + "printf 'unused diagnostic' >&2; exit 1"
            )
        }
        session.onEvent = { event in
            guard case .turnFinished = event else { return }
            XCTAssertTrue(Thread.isMainThread)
            finishCount += 1
            if finishCount == 1 {
                finished.fulfill()
            } else {
                duplicate.fulfill()
            }
        }

        session.start()
        XCTAssertTrue(session.send("test prompt"))

        wait(for: [finished, duplicate], timeout: 1)
        XCTAssertEqual(finishCount, 1)
        XCTAssertTrue(session.canSend)
        session.terminate()
    }

    private func shellPlan(_ script: String) -> AgentLaunchPlan {
        AgentLaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", script],
            resumeState: .unavailable
        )
    }
}
