import AppKit
import XCTest
@testable import Threading

@MainActor
final class TerminalLaunchPersistenceTests: HostedStoreTestCase {
    func testRefusedLaunchWriteReturnsWithoutAModalEvenWhenFailureCannotBeSaved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-persistence-\(UUID().uuidString)", isDirectory: true)
        let stateManager = StateManager(appSupportDirectory: directory)
        let store = ProjectStore(stateManager: stateManager, refusesWrites: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try XCTUnwrap(store.addProject(
            folderURL: FileManager.default.temporaryDirectory
        ))
        let session = try XCTUnwrap(store.addSession(
            to: project.id, kind: .claude, usesNativeUI: false
        ))
        XCTAssertTrue(store.update(sessionID: session.id) {
            $0.backgroundHost = false
        }.succeeded)
        let database = try SQLiteDatabase(path: directory
            .appendingPathComponent(SQLiteDefaults.databaseName).path)
        // Refuse both the launch bookkeeping and its failure record without exhausting the
        // machine's actual volume or poisoning the shared store for subsequent test cases.
        try database.execute("""
            CREATE TRIGGER refused_launch_write BEFORE UPDATE ON session
            BEGIN SELECT RAISE(ABORT, 'fixture write refusal'); END
            """)
        defer {
            try? database.execute("DROP TRIGGER refused_launch_write")
            database.close()
        }
        let controller = AgentSessionViewController(agentSession: session, launchPlanProvider: { _, _, _ in
            AgentLaunchPlan(executable: "/bin/cat", arguments: [], resumeState: .unavailable)
        }, projectStore: store)
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        let delegate = LaunchRefusalObserver()
        controller.delegate = delegate
        // If the blocking alert returns, end its nested loop so this regression fails rather
        // than hanging the test runner awaiting a person at the Mac.
        let escape = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                if NSApp.modalWindow != nil {
                    XCTFail("A launch write refusal opened an application-modal alert")
                    NSApp.abortModal()
                }
            }
        }
        RunLoop.main.add(escape, forMode: .common)
        RunLoop.main.add(escape, forMode: .modalPanel)
        defer { escape.invalidate(); controller.terminate() }
        controller.launch()
        let deadline = Date().addingTimeInterval(3)
        while !delegate.didRefuse, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(delegate.didRefuse)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertEqual(controller.launchRefusal?.knownCause, "persistence-unavailable")
        XCTAssertNil(store.session(withID: session.id)?.lastLaunchFailure,
                     "The current attempt must remain explainable even when its record cannot save")
    }
}

@MainActor
private final class LaunchRefusalObserver: AgentSessionViewControllerDelegate {
    var didRefuse = false
    func agentSession(_ controller: AgentSessionViewController, didExitWithCode exitCode: Int32?) {
        didRefuse = true
    }
    func agentSession(_ controller: AgentSessionViewController, titleChangedTo title: String) {}
    func agentSessionDidChangeState(_ controller: AgentSessionViewController) {}
    func agentSessionSubagentsDidChange(_ controller: AgentSessionViewController) {}
    func agentSession(_ controller: AgentSessionViewController, didSelectSubagent agent: SubagentTimeline.Agent) {}
    func agentSession(_ controller: AgentSessionViewController, didUpdateSelectedSubagent agent: SubagentTimeline.Agent) {}
}
