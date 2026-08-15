import XCTest
@testable import Threading

@MainActor
final class ScheduledSessionReservationTests: XCTestCase {

    func testReservationCreatesTheExactUnlaunchedConversationNamedByThePlan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-scheduled-reservation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = StateManager(appSupportDirectory: directory)
        defer { manager.closeDatabase() }
        let projectStore = ProjectStore(stateManager: manager)
        let project = try XCTUnwrap(projectStore.addProject(folderURL: directory))
        let sessionID = SessionID()
        let message = ScheduledMessage(
            dueAt: Date().addingTimeInterval(3_600),
            target: .newSession(ScheduledSessionPlan(
                reservedSessionID: sessionID,
                projectID: project.id,
                kind: .claude,
                accountHandle: .standard,
                model: "claude-sonnet",
                reasoningEffort: nil,
                fastMode: true,
                branch: nil,
                usesNativeUI: true,
                permissionMode: nil
            )),
            text: "Audit the release checklist before shipping"
        )

        let reserved = try XCTUnwrap(ScheduledSessionReservation.reserve(message, in: projectStore))

        XCTAssertEqual(reserved.id, sessionID)
        XCTAssertEqual(reserved.title, "Audit the release checklist before shipping")
        XCTAssertFalse(reserved.hasLaunched)
        XCTAssertFalse(AgentRuntime.shared.hasTerminal(sessionID: sessionID))
        XCTAssertEqual(projectStore.project(forSessionID: sessionID)?.id, project.id)
    }
}
