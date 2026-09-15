import AppKit
import ThreadingPTYHostKit
import XCTest
@testable import Threading

@MainActor
final class SessionTerminalRestartTests: HostedStoreTestCase {
    func testDormantTerminalOffersRestartButNativeChatDoesNot() {
        let sidebar = ProjectSidebarViewController()
        let terminal = AgentSession(kind: .codex, title: "Dormant")
        XCTAssertTrue(sidebar.sessionActionEntries(for: terminal).contains { $0.item?.title == "Restart Terminal" })
        let native = AgentSession(kind: .codex, title: "Native", usesNativeUI: true)
        XCTAssertFalse(sidebar.sessionActionEntries(for: native).contains { $0.item?.title == "Restart Terminal" })
    }

    func testDuplicateRequestsAreFencedAndStopFailureDoesNotReportSuccess() async {
        let restart = SessionTerminalRestart()
        let id = SessionID()
        let summary = PTYHostSessionSummary(
            id: .agentSession(id), pid: 4242, startedAt: Date(), executable: "/fixture",
            grid: PTYHostGrid(cols: 80, rows: 24), isAttached: false, exit: nil
        )
        let finished = expectation(description: "stop returned")
        var discards = 0
        let holdings = PTYHostHoldings(socketPath: decision.socketPath!, sessions: [summary])
        restart.run(sessionID: id, localPID: nil, decision: decision,
                    survey: .answering(holdings), stopper: { identity, _, _ in
            XCTAssertEqual(identity, .agentSession(id))
            return false
        }, discard: {
            XCTAssertTrue(restart.contains(id))
            discards += 1
        }, completion: { success in
            XCTAssertFalse(success)
            XCTAssertFalse(restart.contains(id))
            finished.fulfill()
        })
        restart.run(sessionID: id, localPID: nil, decision: decision,
                    survey: .answering(nil), discard: { XCTFail("duplicate discard") },
                    completion: { _ in XCTFail("duplicate completion") })
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(discards, 1)
    }

    func testUnrelatedHostedChildIsNotStopped() async {
        let id = SessionID()
        let other = PTYHostSessionSummary(
            id: .agentSession(SessionID()), pid: 4242, startedAt: Date(), executable: "/fixture",
            grid: PTYHostGrid(cols: 80, rows: 24), isAttached: false, exit: nil
        )
        let finished = expectation(description: "absent target")
        SessionTerminalRestart().run(
            sessionID: id, localPID: nil, decision: decision,
            survey: .answering(PTYHostHoldings(socketPath: decision.socketPath!, sessions: [other])),
            stopper: { _, _, _ in XCTFail("stopped another session"); return false },
            discard: {}, completion: { success in XCTAssertTrue(success); finished.fulfill() }
        )
        await fulfillment(of: [finished], timeout: 3)
    }

    func testDiscardCancelsALaunchThatHasNotReachedThePTY() throws {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: FileManager.default.temporaryDirectory))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude, usesNativeUI: false))
        let controller = AgentSessionViewController(agentSession: session, launchPlanProvider: { _, _, _ in
            AgentLaunchPlan(executable: "/bin/cat", arguments: [], resumeState: .unavailable)
        })
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        controller.launch()
        controller.terminate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(controller.isRunning)
        defer { controller.terminate() }
    }

    func testUnaddressableHostSocketAllowsLocalRecovery() {
        let unavailable = PTYHostDecision(
            isEnabled: false, helperURL: URL(fileURLWithPath: "/unused"),
            socketPath: nil, socketPathBytes: 200, build: "test"
        )
        XCTAssertTrue(SessionTerminalRestart.stopHosted(
            sessionID: SessionID(), decision: unavailable, survey: .answering(nil),
            stopper: { _, _, _ in XCTFail("unaddressable host cannot have a child"); return false }
        ))
    }

    private var decision: PTYHostDecision {
        let path = "/tmp/threading-restart-\(UUID().uuidString).sock"
        return PTYHostDecision(isEnabled: false, helperURL: URL(fileURLWithPath: "/unused"),
                              socketPath: path, socketPathBytes: path.utf8.count, build: "test")
    }
}
