import Foundation
import XCTest
@testable import Threading

final class ProjectTerminalStartPlanTests: XCTestCase {
    func testAvailableRecordedDirectoryPreservesOwningProjectAndTerminalIdentity() {
        let project = Project(name: "Owner", folderURL: URL(fileURLWithPath: "/work/owner"))
        let terminal = makeTerminal(directory: "/work/another checkout/日本語 👩🏽‍💻")

        let plan = ProjectTerminalStartPlan(terminal: terminal, project: project,
                                            preferredDirectoryIsAvailable: true)

        XCTAssertEqual(plan.terminalID, terminal.id)
        XCTAssertEqual(plan.projectID, project.id)
        XCTAssertEqual(plan.directory.path, terminal.currentDirectory)
        XCTAssertNotEqual(plan.directory, project.folderURL)
        XCTAssertEqual(project.folderPath, "/work/owner")
    }

    func testUnavailableRecordedDirectoryFallsBackToOwningProjectWithUnicodePath() {
        let project = Project(name: "Owner", folderURL:
            URL(fileURLWithPath: "/work/ägare 日本語/space & percent %", isDirectory: true))
        let terminal = makeTerminal(directory: "/work/removed-checkout")

        let plan = ProjectTerminalStartPlan(terminal: terminal, project: project,
                                            preferredDirectoryIsAvailable: false)

        XCTAssertEqual(plan.terminalID, terminal.id)
        XCTAssertEqual(plan.projectID, project.id)
        XCTAssertEqual(plan.directory, project.folderURL)
        XCTAssertEqual(plan.directory.path, project.folderPath)
        XCTAssertEqual(terminal.currentDirectory, "/work/removed-checkout")
    }

    func testHostAvailabilityIsAuthoritativeWithoutFilesystemDiscovery() {
        let project = Project(name: "Owner", folderURL: URL(fileURLWithPath: "/host-owned/project"))
        // Even a universally present directory can be refused by the host's admission policy.
        let refused = makeTerminal(directory: "/")
        XCTAssertEqual(ProjectTerminalStartPlan(terminal: refused, project: project,
            preferredDirectoryIsAvailable: false).directory, project.folderURL)

        let suppliedPath = "/host-owned/\(UUID().uuidString)/recorded directory"
        let admitted = makeTerminal(directory: suppliedPath)
        XCTAssertEqual(ProjectTerminalStartPlan(terminal: admitted, project: project,
            preferredDirectoryIsAvailable: true).directory.path, suppliedPath)
    }

    private func makeTerminal(directory: String) -> ProjectTerminal {
        ProjectTerminal(id: TerminalID(), title: "Shell", customTitle: nil,
            currentDirectory: directory, branch: nil, themeID: nil, soundOverrides: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
