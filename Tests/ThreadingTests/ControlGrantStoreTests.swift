import XCTest
@testable import Threading

/// Durable manager/child lifecycle behavior across more than one supervision tenure.
///
/// The database tests pin the relational invariant and migration. This test drives the owner that
/// actually creates, closes and recreates those rows so a future cache or lifecycle refactor cannot
/// reintroduce the release-then-adopt failure above the SQL boundary.
@MainActor
final class ControlGrantStoreTests: XCTestCase {

    private nonisolated(unsafe) var directory: URL!
    private var stateManager: StateManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "threading-control-grant-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        stateManager = StateManager(appSupportDirectory: directory)
    }

    override func tearDownWithError() throws {
        stateManager?.closeDatabase()
        stateManager = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    func testReleaseThenReadoptCreatesANewTenureAndKeepsTheFirstAuditStream() throws {
        let manager = AgentSession(kind: .codex, title: "Manager")
        let child = AgentSession(kind: .claude, title: "Child")
        var project = Project(
            name: "Project",
            folderURL: URL(fileURLWithPath: "/tmp/control-grant-store")
        )
        project.sessions = [manager, child]
        XCTAssertTrue(stateManager.saveProjectsState(ProjectsState(projects: [project])))

        let projects = ProjectStore(stateManager: stateManager)
        let notifications = NotificationCenter()
        var now = Date(timeIntervalSince1970: 100)
        let store = ControlGrantStore(dependencies: .init(
            state: stateManager,
            projects: projects,
            events: notifications,
            now: { now }
        ))

        let first: Supervision
        switch store.adopt(childID: child.id, by: manager.id, brief: "First tenure") {
        case .adopted(let supervision): first = supervision
        default: return XCTFail("The first adoption should succeed")
        }

        now = Date(timeIntervalSince1970: 120)
        let released: Supervision
        switch store.release(childID: child.id, by: manager.id, outcome: "First complete") {
        case .released(let supervision): released = supervision
        default: return XCTFail("The first tenure should release")
        }

        now = Date(timeIntervalSince1970: 130)
        let second: Supervision
        switch store.adopt(childID: child.id, by: manager.id, brief: "Second tenure") {
        case .adopted(let supervision): second = supervision
        default: return XCTFail("A released child should be adoptable again")
        }

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(released.id, first.id)
        XCTAssertEqual(released.state, .released)
        XCTAssertEqual(store.activeManager(of: child.id)?.id, second.id)
        XCTAssertEqual(store.activeChildren(of: manager.id).map(\.id), [second.id])

        let history = try XCTUnwrap(stateManager.supervisions(childID: child.id))
        XCTAssertEqual(history, [released, second])
        XCTAssertEqual(
            try XCTUnwrap(stateManager.supervisionEvents(for: first.id)).map(\.kind),
            [.assigned, .released]
        )
        XCTAssertEqual(
            try XCTUnwrap(stateManager.supervisionEvents(for: second.id)).map(\.kind),
            [.assigned]
        )
        XCTAssertEqual(stateManager.persistenceHealth, .healthy)
    }
}
