import XCTest
@testable import Skalman

/// The SQLite store, and the import that gets a `projects.json` into it.
///
/// The import is the part worth pinning hardest: it runs exactly once per user, on state they
/// cannot get back if it goes wrong, and the neighbouring project that made this same move
/// lost sessions doing it.
final class ProjectDatabaseTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("skalman-db-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    private func makeDatabase() throws -> ProjectDatabase {
        try ProjectDatabase(url: directory.appendingPathComponent("test.db"))
    }

    private func makeProject(_ name: String, sessions: [AgentSession] = []) -> Project {
        var project = Project(name: name, folderURL: URL(fileURLWithPath: "/tmp/\(name)"))
        project.sessions = sessions
        return project
    }

    // MARK: - Round Trip

    func testEmptyDatabaseIsEmpty() throws {
        let database = try makeDatabase()
        XCTAssertTrue(database.isEmpty)
        XCTAssertTrue(try database.load().projects.isEmpty)
    }

    func testProjectsAndSessionsRoundTrip() throws {
        let database = try makeDatabase()
        let session = AgentSession(kind: .claude, title: "Chat")
        let selected = SessionID()

        let state = ProjectsState(
            projects: [makeProject("alpha", sessions: [session]), makeProject("beta")],
            selectedSessionID: selected
        )
        try database.save(state)

        let restored = try database.load()
        XCTAssertEqual(restored.projects.map(\.name), ["alpha", "beta"], "order is a column, not luck")
        XCTAssertEqual(restored.projects[0].sessions.map(\.id), [session.id])
        XCTAssertEqual(restored.projects[0].sessions[0].title, "Chat")
        XCTAssertEqual(restored.selectedSessionID, selected)
        XCTAssertFalse(database.isEmpty)
    }

    func testSessionsAreRowsAndNotAlsoPayload() throws {
        // A session carried in the project payload *and* in its own row would eventually
        // disagree; the payload is stored with `sessions` emptied for that reason.
        let database = try makeDatabase()
        let project = makeProject("alpha", sessions: [AgentSession(kind: .codex, title: "Chat")])
        try database.save(ProjectsState(projects: [project]))

        let payload = try XCTUnwrap(rawProjectPayload(id: project.id))
        XCTAssertTrue(
            payload.contains("\"sessions\":[]"),
            "the project payload should carry no sessions, got: \(payload.prefix(200))"
        )

        // …and the row still comes back attached.
        XCTAssertEqual(try database.load().projects[0].sessions.count, 1)
    }

    func testOrderSurvivesReordering() throws {
        let database = try makeDatabase()
        let first = makeProject("first")
        let second = makeProject("second")
        try database.save(ProjectsState(projects: [first, second]))
        try database.save(ProjectsState(projects: [second, first]))

        XCTAssertEqual(try database.load().projects.map(\.name), ["second", "first"])
    }

    // MARK: - Incremental Writes

    func testRemovedProjectsAndSessionsAreDeleted() throws {
        let database = try makeDatabase()
        let kept = AgentSession(kind: .claude, title: "Kept")
        let dropped = AgentSession(kind: .claude, title: "Dropped")

        try database.save(ProjectsState(projects: [
            makeProject("alpha", sessions: [kept, dropped]),
            makeProject("beta")
        ]))
        try database.save(ProjectsState(projects: [makeProject("alpha", sessions: [kept])]))

        let restored = try database.load()
        XCTAssertEqual(restored.projects.map(\.name), ["alpha"])
        XCTAssertEqual(restored.projects[0].sessions.map(\.title), ["Kept"])
    }

    func testDeletingEveryProjectLeavesNothingBehind() throws {
        let database = try makeDatabase()
        try database.save(ProjectsState(projects: [
            makeProject("alpha", sessions: [AgentSession(kind: .claude, title: "Chat")])
        ]))
        try database.save(ProjectsState(projects: []))

        XCTAssertTrue(database.isEmpty)
        // The cascade is a foreign key, which only holds because `PRAGMA foreign_keys` is on.
        XCTAssertEqual(try rowCount("session"), 0, "sessions should cascade with their project")
    }

    func testSessionMovedBetweenProjectsFollowsIt() throws {
        let database = try makeDatabase()
        let session = AgentSession(kind: .claude, title: "Chat")
        let alpha = makeProject("alpha", sessions: [session])
        var beta = makeProject("beta")

        try database.save(ProjectsState(projects: [alpha, beta]))

        beta.sessions = [session]
        try database.save(ProjectsState(projects: [makeProject("alpha"), beta]))

        let restored = try database.load()
        XCTAssertTrue(restored.projects[0].sessions.isEmpty)
        XCTAssertEqual(restored.projects[1].sessions.map(\.id), [session.id])
    }

    func testSelectedSessionCanBeCleared() throws {
        let database = try makeDatabase()
        try database.save(ProjectsState(projects: [makeProject("alpha")], selectedSessionID: SessionID()))
        try database.save(ProjectsState(projects: [makeProject("alpha")], selectedSessionID: nil))

        XCTAssertNil(try database.load().selectedSessionID)
    }

    // MARK: - Model Fidelity

    func testRichSessionFieldsSurviveThePayload() throws {
        // The payload is the model's own encoding precisely so fields added to `AgentSession`
        // need no schema change; this is the assertion that keeps that claim honest.
        let database = try makeDatabase()
        var session = AgentSession(kind: .claude, title: "Chat", accountHandle: .named("claudedb"), model: "opus")
        session.customTitle = "Renamed"
        session.terminalTitle = "working"
        session.branch = "feature/x"
        session.hasLaunched = true
        session.lastExitCode = 3
        session.usesNativeUI = true
        session.isArchived = true

        try database.save(ProjectsState(projects: [makeProject("alpha", sessions: [session])]))
        let restored = try XCTUnwrap(try database.load().projects.first?.sessions.first)

        XCTAssertEqual(restored.customTitle, "Renamed")
        XCTAssertEqual(restored.terminalTitle, "working")
        XCTAssertEqual(restored.branch, "feature/x")
        XCTAssertEqual(restored.model, "opus")
        XCTAssertEqual(restored.accountHandle, session.accountHandle)
        XCTAssertEqual(restored.lastExitCode, 3)
        XCTAssertTrue(restored.hasLaunched)
        XCTAssertTrue(restored.usesNativeUI)
        XCTAssertTrue(restored.isArchived)
    }

    // MARK: - The Real Document

    /// Imports the machine's own `projects.json` into a throwaway database.
    ///
    /// A fixture proves the code path; this proves the *file this user will actually migrate*.
    /// The source is only ever read — the copy is what gets imported — and the test skips where
    /// there is nothing to read, so it is evidence here and silent everywhere else.
    func testRealProjectsDocumentImportsWithoutLoss() throws {
        let live = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skalman/projects.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: live.path), "no live projects.json here")

        let copy = directory.appendingPathComponent("projects.json")
        try FileManager.default.copyItem(at: live, to: copy)

        let expected = try JSONDecoder().decode(ProjectsState.self, from: Data(contentsOf: copy))
        let manager = StateManager(appSupportDirectory: directory)

        guard case .loaded(let imported) = manager.loadProjectsState() else {
            return XCTFail("the live document should import")
        }

        XCTAssertEqual(imported.projects.map(\.id), expected.projects.map(\.id))
        XCTAssertEqual(
            imported.projects.map { $0.sessions.map(\.id) },
            expected.projects.map { $0.sessions.map(\.id) },
            "every session, in its project, in order"
        )
        XCTAssertEqual(imported.selectedSessionID, expected.selectedSessionID)

        // Titles, accounts and resume identifiers are what a lost migration would cost.
        let importedSessions = imported.projects.flatMap(\.sessions)
        let expectedSessions = expected.projects.flatMap(\.sessions)
        XCTAssertEqual(importedSessions.map(\.displayTitle), expectedSessions.map(\.displayTitle))
        XCTAssertEqual(importedSessions.map(\.accountHandle), expectedSessions.map(\.accountHandle))
        XCTAssertEqual(
            importedSessions.map { $0.resumeState.transcriptID },
            expectedSessions.map { $0.resumeState.transcriptID }
        )
    }

    // MARK: - Helpers

    private func rowCount(_ table: String) throws -> Int {
        let database = try SQLiteDatabase(path: directory.appendingPathComponent("test.db").path)
        return try database.scalar("SELECT COUNT(*) FROM \(table)") ?? -1
    }

    private func rawProjectPayload(id: ProjectID) throws -> String? {
        let database = try SQLiteDatabase(path: directory.appendingPathComponent("test.db").path)
        let statement = try database.prepare("SELECT data FROM project WHERE id = ?")
        defer { statement.finalize() }
        statement.bind(1, id.uuidString)
        return try statement.step() ? statement.text(0) : nil
    }
}
