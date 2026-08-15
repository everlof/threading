import XCTest
@testable import Threading

@MainActor
final class AgentSessionCommandServiceTests: XCTestCase {
    private var testDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentSessionCommandServiceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    func testNamingWritesChosenTitleWithoutConstructingCoordinatorOrWindow() throws {
        let fixture = try makeFixture(usesAgentTitle: true)

        let result = fixture.service.setSessionName(
            SetSessionNameArguments(name: "download lifecycle ownership"),
            for: fixture.session.id
        )

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, "This session is now called “download lifecycle ownership”.")
        XCTAssertEqual(
            fixture.store.session(withID: fixture.session.id)?.agentTitle,
            "download lifecycle ownership"
        )
        XCTAssertEqual(
            fixture.store.session(withID: fixture.session.id)?.agentTitleSource,
            .chosen
        )
    }

    func testNamingExplainsWhenSidebarProjectionHidesAgentTitles() throws {
        let fixture = try makeFixture(usesAgentTitle: false)

        let result = fixture.service.setSessionName(
            SetSessionNameArguments(name: "download lifecycle ownership"),
            for: fixture.session.id
        )

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("set to ignore agent titles"), result.text)
        XCTAssertEqual(
            fixture.store.session(withID: fixture.session.id)?.agentTitle,
            "download lifecycle ownership"
        )
    }

    func testNamingNeverOverridesUsersCustomTitle() throws {
        let fixture = try makeFixture(usesAgentTitle: true)
        fixture.store.renameSession(id: fixture.session.id, to: "My settled name")

        let result = fixture.service.setSessionName(
            SetSessionNameArguments(name: "agent suggestion"),
            for: fixture.session.id
        )

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("their name outranks yours"), result.text)
        let stored = try XCTUnwrap(fixture.store.session(withID: fixture.session.id))
        XCTAssertEqual(stored.customTitle, "My settled name")
        XCTAssertEqual(stored.agentTitle, "agent suggestion")
    }

    func testArchiveAndCancellationUseDeferredScheduler() throws {
        let fixture = try makeFixture(usesAgentTitle: true)

        let archived = fixture.service.archiveSession(
            ArchiveSessionArguments(reason: "architecture slice complete"),
            for: fixture.session.id
        )
        XCTAssertFalse(archived.isError, archived.text)
        XCTAssertTrue(archived.text.contains("when this turn ends"), archived.text)
        XCTAssertTrue(fixture.scheduler.isPending(sessionID: fixture.session.id))

        let cancelled = fixture.service.cancelSessionArchive(for: fixture.session.id)
        XCTAssertFalse(cancelled.isError, cancelled.text)
        XCTAssertFalse(fixture.scheduler.isPending(sessionID: fixture.session.id))
    }

    func testMissingSessionIsRefusedByBothCommands() throws {
        let fixture = try makeFixture(usesAgentTitle: true)
        let missing = SessionID()

        let named = fixture.service.setSessionName(
            SetSessionNameArguments(name: "missing conversation"),
            for: missing
        )
        XCTAssertTrue(named.isError)
        XCTAssertTrue(named.text.contains("no longer in the sidebar"), named.text)

        let archived = fixture.service.archiveSession(
            ArchiveSessionArguments(reason: nil),
            for: missing
        )
        XCTAssertTrue(archived.isError)
        XCTAssertTrue(archived.text.contains("not in Threading's sidebar"), archived.text)
    }

    private func makeFixture(usesAgentTitle: Bool) throws -> Fixture {
        let store = ProjectStore(stateManager: StateManager(
            appSupportDirectory: testDirectory.appendingPathComponent("state", isDirectory: true)
        ))
        let projectDirectory = testDirectory.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let project = try XCTUnwrap(store.addProject(folderURL: projectDirectory))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let scheduler = SessionArchiveScheduler(
            center: NotificationCenter(),
            activity: { _ in .dormant },
            session: { store.session(withID: $0) }
        )
        let service = AgentSessionCommandService(
            projects: store,
            archiveScheduler: scheduler,
            usesAgentTitleInSidebar: { usesAgentTitle }
        )
        return Fixture(
            store: store,
            session: session,
            scheduler: scheduler,
            service: service
        )
    }
}

@MainActor
private struct Fixture {
    let store: ProjectStore
    let session: AgentSession
    let scheduler: SessionArchiveScheduler
    let service: AgentSessionCommandService
}
