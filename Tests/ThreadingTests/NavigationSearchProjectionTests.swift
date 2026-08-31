import XCTest

@testable import Threading

@MainActor
final class NavigationSearchProjectionTests: XCTestCase {
    func testProjectionEmitsOneTypedDestinationForEveryProjectChild() throws {
        var project = Project(name: "Search", folderURL: URL(fileURLWithPath: "/tmp/search"))
        let session = AgentSession(kind: .codex, title: "Session")
        let terminal = ProjectTerminal(currentDirectory: project.folderPath)
        project.sessions = [session]
        project.terminals = [terminal]

        let records = NavigationSearchProjection.records(projects: [project])

        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records.contains { $0.destination == .project(project.id) })
        XCTAssertTrue(records.contains {
            $0.destination == .session(projectID: project.id, sessionID: session.id)
        })
        XCTAssertTrue(records.contains {
            $0.destination == .terminal(projectID: project.id, terminalID: terminal.id)
        })
    }
}
