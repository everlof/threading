import XCTest

@testable import Threading

/// An agent asked to configure an automation needs its project's id, and `list_sessions` is
/// the one place it can read it. Before this, no tool printed the id and an unknown one was
/// reported as "The trigger record no longer exists.", so agents could not get started.
@MainActor
final class AutomationProjectDiscoveryTests: XCTestCase {

    func testTheSessionListingNamesTheProjectIdThatAutomationsTake() throws {
        let project = Project(name: "Alpha", folderURL: URL(fileURLWithPath: "/tmp/alpha"))

        let heading = AgentToolCoordinator.sessionListingHeading(project: project, count: 3)

        XCTAssertTrue(heading.hasPrefix("Sessions in “Alpha” (3)"), heading)
        let printed = try XCTUnwrap(heading.components(separatedBy: "project id ").last?
            .trimmingCharacters(in: CharacterSet(charactersIn: ":")))
        XCTAssertEqual(ProjectID(uuidString: printed), project.id)
        XCTAssertNoThrow(try AutomationToolActions.requireKnownProject(
            AutomationConfiguration(projectID: try XCTUnwrap(ProjectID(uuidString: printed))),
            exists: { $0 == project.id }
        ))
    }

    func testAListingWithoutAProjectStaysGeneric() {
        XCTAssertEqual(AgentToolCoordinator.sessionListingHeading(project: nil, count: 1),
                       "Sessions in this project (1):")
    }

    func testAnUnknownProjectIsRefusedWithTheWayToFindTheRightOne() {
        let configuration = AutomationConfiguration(projectID: ProjectID())
        XCTAssertThrowsError(try AutomationToolActions.requireKnownProject(configuration, exists: { _ in false })) { error in
            guard case AutomationToolActions.Refusal.unknownProject = error else {
                return XCTFail("unexpected error \(error)")
            }
            let words = error.localizedDescription
            XCTAssertTrue(words.contains("list_sessions"), words)
            XCTAssertFalse(words.contains("no longer exists"), words)
        }
    }

    func testOperationsWithoutAConfigurationNeedNoProject() {
        XCTAssertNoThrow(try AutomationToolActions.requireKnownProject(nil, exists: { _ in false }))
    }
}
