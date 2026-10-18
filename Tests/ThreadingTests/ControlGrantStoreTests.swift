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

    // MARK: - Archive closes tenures

    func testAChildArchivedByAnyoneButItsManagerIsReleased() throws {
        let fixture = try makeFixture()
        let supervision = try fixture.adopt()

        fixture.notifications.post(SessionArchivedStateDidChange(
            sessionID: fixture.child.id,
            isArchived: true
        ))

        XCTAssertTrue(fixture.store.activeChildren(of: fixture.manager.id).isEmpty)
        let closed = try XCTUnwrap(stateManager.supervisions(childID: fixture.child.id)?.last)
        XCTAssertEqual(closed.id, supervision.id)
        XCTAssertEqual(closed.state, .released, "Archived must stay the manager's own act.")
        XCTAssertEqual(
            try XCTUnwrap(stateManager.supervisionEvents(for: supervision.id)).map(\.kind),
            [.assigned, .archived]
        )
    }

    func testTheManagersOwnArchiveClosesAsArchived() throws {
        let fixture = try makeFixture()
        _ = try fixture.adopt()

        fixture.store.expectArchive(of: fixture.child.id, by: fixture.manager.id)
        fixture.notifications.post(SessionArchivedStateDidChange(
            sessionID: fixture.child.id,
            isArchived: true
        ))

        let closed = try XCTUnwrap(stateManager.supervisions(childID: fixture.child.id)?.last)
        XCTAssertEqual(closed.state, .archived)
        XCTAssertEqual(closed.outcome, "Archived by manager")
    }

    func testAnArchivedManagerReleasesItsChildren() throws {
        let fixture = try makeFixture()
        _ = try fixture.adopt()

        fixture.notifications.post(SessionArchivedStateDidChange(
            sessionID: fixture.manager.id,
            isArchived: true
        ))

        XCTAssertNil(fixture.store.activeManager(of: fixture.child.id))
        let closed = try XCTUnwrap(stateManager.supervisions(childID: fixture.child.id)?.last)
        XCTAssertEqual(closed.state, .released)
        XCTAssertEqual(closed.outcome, "Manager archived")
    }

    func testTheSubscriberIsToldBeforeTheTenureCloses() throws {
        var activeWhenTold: Bool?
        let fixture = try makeFixture { store, supervision in
            activeWhenTold = store?.activeManager(of: supervision.childID) != nil
        }
        _ = try fixture.adopt()

        fixture.notifications.post(SessionArchivedStateDidChange(
            sessionID: fixture.child.id,
            isArchived: true
        ))

        XCTAssertEqual(activeWhenTold, true)
    }

    // MARK: - Private Methods

    @MainActor
    private struct Fixture {
        let manager: AgentSession
        let child: AgentSession
        let notifications: NotificationCenter
        let store: ControlGrantStore

        func adopt() throws -> Supervision {
            guard case .adopted(let supervision) = store.adopt(
                childID: child.id,
                by: manager.id,
                brief: "Brief"
            ) else { throw XCTSkip("Adoption failed; the fixture is broken.") }
            return supervision
        }
    }

    private func makeFixture(
        childArchived: @escaping (ControlGrantStore?, Supervision) -> Void = { _, _ in }
    ) throws -> Fixture {
        let manager = AgentSession(kind: .codex, title: "Manager")
        let child = AgentSession(kind: .claude, title: "Child")
        var project = Project(
            name: "Project",
            folderURL: URL(fileURLWithPath: "/tmp/control-grant-store")
        )
        project.sessions = [manager, child]
        XCTAssertTrue(stateManager.saveProjectsState(ProjectsState(projects: [project])))

        let notifications = NotificationCenter()
        weak var weakStore: ControlGrantStore?
        let store = ControlGrantStore(dependencies: .init(
            state: stateManager,
            projects: ProjectStore(stateManager: stateManager),
            events: notifications,
            now: Date.init,
            childArchived: { childArchived(weakStore, $0) }
        ))
        weakStore = store
        return Fixture(manager: manager, child: child, notifications: notifications, store: store)
    }
}
