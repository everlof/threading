import XCTest
@testable import Threading

/// The SQLite store, and the import that gets a `projects.json` into it.
///
/// The import is the part worth pinning hardest: it runs exactly once per user, on state they
/// cannot get back if it goes wrong, and the neighbouring project that made this same move
/// lost sessions doing it.
@MainActor
final class ProjectDatabaseTests: XCTestCase {

    private nonisolated(unsafe) var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-db-tests-\(UUID().uuidString)", isDirectory: true)
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
        XCTAssertTrue(try database.isEmpty())
        XCTAssertTrue(try database.load().state.projects.isEmpty)
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

        let restored = try database.load().state
        XCTAssertEqual(restored.projects.map(\.name), ["alpha", "beta"], "order is a column, not luck")
        XCTAssertEqual(restored.projects[0].sessions.map(\.id), [session.id])
        XCTAssertEqual(restored.projects[0].sessions[0].title, "Chat")
        XCTAssertEqual(restored.selectedSessionID, selected)
        XCTAssertFalse(try database.isEmpty())
    }

    func testStandaloneTerminalsRoundTripInsideTheirProject() throws {
        let database = try makeDatabase()
        var terminal = ProjectTerminal(currentDirectory: "/tmp/alpha/Sources")
        terminal.title = "zsh"
        terminal.customTitle = "Server"
        terminal.branch = "feature/terminal"
        terminal.themeID = .ocean
        var project = makeProject("alpha")
        project.terminals = [terminal]

        try database.save(ProjectsState(projects: [project]))
        let restored = try XCTUnwrap(try database.load().state.projects.first?.terminals.first)

        XCTAssertEqual(restored.id, terminal.id)
        XCTAssertEqual(restored.displayTitle, "Server")
        XCTAssertEqual(restored.currentDirectory, "/tmp/alpha/Sources")
        XCTAssertEqual(restored.branch, "feature/terminal")
        XCTAssertEqual(restored.themeID, .ocean)
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
        XCTAssertEqual(try database.load().state.projects[0].sessions.count, 1)
    }

    func testOrderSurvivesReordering() throws {
        let database = try makeDatabase()
        let first = makeProject("first")
        let second = makeProject("second")
        try database.save(ProjectsState(projects: [first, second]))
        try database.save(ProjectsState(projects: [second, first]))

        XCTAssertEqual(try database.load().state.projects.map(\.name), ["second", "first"])
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

        let restored = try database.load().state
        XCTAssertEqual(restored.projects.map(\.name), ["alpha"])
        XCTAssertEqual(restored.projects[0].sessions.map(\.title), ["Kept"])
    }

    func testDeletingEveryProjectLeavesNothingBehind() throws {
        let database = try makeDatabase()
        try database.save(ProjectsState(projects: [
            makeProject("alpha", sessions: [AgentSession(kind: .claude, title: "Chat")])
        ]))
        try database.save(ProjectsState(projects: []))

        XCTAssertTrue(try database.isEmpty())
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

        let restored = try database.load().state
        XCTAssertTrue(restored.projects[0].sessions.isEmpty)
        XCTAssertEqual(restored.projects[1].sessions.map(\.id), [session.id])
    }

    func testSelectedSessionCanBeCleared() throws {
        let database = try makeDatabase()
        try database.save(ProjectsState(projects: [makeProject("alpha")], selectedSessionID: SessionID()))
        try database.save(ProjectsState(projects: [makeProject("alpha")], selectedSessionID: nil))

        XCTAssertNil(try database.load().state.selectedSessionID)
    }

    func testSelectionCanBeSavedWithoutRewritingProjectRows() throws {
        let database = try makeDatabase()
        var project = makeProject("Persisted")
        try database.save(ProjectsState(projects: [project]))

        // This mutation deliberately stays in memory. A selection-only write must not smuggle
        // it into the database by routing through the full-state save path.
        project.name = "Unsaved"
        let selected = SessionID()
        try database.saveSelectedSessionID(selected)

        let restored = try database.load().state
        XCTAssertEqual(restored.selectedSessionID, selected)
        XCTAssertEqual(restored.projects.map(\.name), ["Persisted"])
    }

    // MARK: - Running Sessions at Quit

    func testRunningSessionsRoundTripInOrder() throws {
        let database = try makeDatabase()
        let ids = [SessionID(), SessionID(), SessionID()]

        try database.saveRunningSessionIDs(ids)

        XCTAssertEqual(try database.runningSessionIDs(), ids)
        XCTAssertNil(
            try database.load().state.selectedSessionID,
            "the record rides app_state without becoming part of the projects load"
        )
    }

    func testAnEmptyRunningSessionsListClearsTheRecord() throws {
        let database = try makeDatabase()
        try database.saveRunningSessionIDs([SessionID()])
        try database.saveRunningSessionIDs([])

        XCTAssertTrue(try database.runningSessionIDs().isEmpty)
    }

    /// Consumed on read, the way `EventLog`'s launch marker is: only a clean quit rewrites the
    /// record, so one that survived the launch that read it would relaunch sessions the user
    /// has since closed the first time that launch crashes.
    func testConsumingTheRunningSessionsClearsThem() throws {
        let manager = StateManager(appSupportDirectory: directory)
        let ids = [SessionID(), SessionID()]

        XCTAssertTrue(manager.saveRunningSessionIDs(ids))

        XCTAssertEqual(manager.consumeRunningSessionIDs(), ids)
        XCTAssertTrue(manager.consumeRunningSessionIDs().isEmpty, "the first read spends it")
    }

    // MARK: - Fail-Closed Loading

    func testMalformedSessionPayloadFailsTheWholeLoadWithoutDeletingRows() throws {
        let database = try makeDatabase()
        let first = AgentSession(kind: .claude, title: "First")
        let second = AgentSession(kind: .codex, title: "Second")
        try database.save(ProjectsState(projects: [
            makeProject("alpha", sessions: [first, second])
        ]))

        try updatePayload(
            table: "session",
            id: second.id.uuidString,
            payload: "{ not-json"
        )

        XCTAssertThrowsError(try database.load().state) { error in
            guard let loadError = error as? ProjectDatabaseLoadError,
                  case .corruptRow(let table, let id, _) = loadError else {
                return XCTFail("Expected a corrupt-row error, got \(error)")
            }
            XCTAssertEqual(table, "session")
            XCTAssertEqual(id, second.id.uuidString)
        }
        XCTAssertEqual(try rowCount("project"), 1)
        XCTAssertEqual(
            try rowCount("session"),
            2,
            "a failed load must not turn an undecodable row into an implicit deletion"
        )
    }

    func testPayloadIdentityMustMatchItsAuthoritativeRow() throws {
        let database = try makeDatabase()
        let project = makeProject("alpha")
        try database.save(ProjectsState(projects: [project]))

        let payload = try XCTUnwrap(rawProjectPayload(id: project.id))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        object["id"] = ProjectID().uuidString
        let mismatched = String(
            decoding: try JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
        try updatePayload(
            table: "project",
            id: project.id.uuidString,
            payload: mismatched
        )

        XCTAssertThrowsError(try database.load().state) { error in
            guard let loadError = error as? ProjectDatabaseLoadError,
                  case .corruptRow(let table, let id, let reason) = loadError else {
                return XCTFail("Expected a corrupt-row error, got \(error)")
            }
            XCTAssertEqual(table, "project")
            XCTAssertEqual(id, project.id.uuidString)
            XCTAssertTrue(reason.contains("payload identifier"))
        }
        XCTAssertEqual(try rowCount("project"), 1)
    }

    func testIndexedMetadataMustMatchThePayload() throws {
        let database = try makeDatabase()
        let project = makeProject("alpha")
        try database.save(ProjectsState(projects: [project]))

        let raw = try SQLiteDatabase(path: directory.appendingPathComponent("test.db").path)
        try raw.prepare("UPDATE project SET name = ? WHERE id = ?")
            .bind(1, "different")
            .bind(2, project.id.uuidString)
            .run()

        XCTAssertThrowsError(try database.load().state) { error in
            guard let loadError = error as? ProjectDatabaseLoadError,
                  case .corruptRow(_, _, let reason) = loadError else {
                return XCTFail("Expected a corrupt-row error, got \(error)")
            }
            XCTAssertTrue(reason.contains("indexed name"))
        }
    }

    func testInvalidSelectedSessionIdentifierFailsRatherThanBecomingNoSelection() throws {
        let database = try makeDatabase()
        try database.save(ProjectsState(projects: [makeProject("alpha")]))

        let raw = try SQLiteDatabase(path: directory.appendingPathComponent("test.db").path)
        try raw.prepare(ProjectDatabaseSchema.upsertAppState)
            .bind(1, ProjectDatabaseSchema.selectedSessionKey)
            .bind(2, "not-a-session-id")
            .run()

        XCTAssertThrowsError(try database.load().state) { error in
            guard let loadError = error as? ProjectDatabaseLoadError,
                  case .corruptRow(let table, _, _) = loadError else {
                return XCTFail("Expected a corrupt-row error, got \(error)")
            }
            XCTAssertEqual(table, "app_state")
        }
    }

    /// The row this asserts on is the one that cost a user four projects and 138 chats.
    ///
    /// An unreadable panel used to fail the authoritative load, and a failed load quarantines the
    /// database — so one display panel written by a build a format version ahead took the whole
    /// store with it. The panel is a pane that rebuilds itself from nothing; the sessions beside
    /// it are the only copy of anything.
    func testMalformedPanelIsReportedRatherThanFailingTheLoad() throws {
        let database = try makeDatabase()
        let sessionID = SessionID()
        try database.save(ProjectsState(projects: [makeProject("alpha")]))
        try database.savePanelPayload("{", for: sessionID)

        let load = try database.load()

        XCTAssertEqual(load.state.projects.map(\.name), ["alpha"])
        XCTAssertEqual(load.unreadable.panelLayouts.sessions, [sessionID])
        XCTAssertFalse(load.unreadable.panelLayouts.containsUnkeyedRows)
        XCTAssertTrue(load.unreadable.sessionAttachments.isEmpty)
        XCTAssertEqual(
            try rowCount("panel_layout"),
            1,
            "naming a row unreadable must not be a way of deleting it"
        )
    }

    /// The real shape of the failure: not damage, but a document from a build that knows more.
    func testFutureAttachmentDocumentIsReportedWithoutDeletingIt() throws {
        let database = try makeDatabase()
        let sessionID = SessionID()
        try database.save(ProjectsState(projects: [makeProject("alpha")]))
        try database.saveAttachmentsPayload(
            #"{"formatVersion":99,"entries":[]}"#,
            for: sessionID
        )

        let load = try database.load()

        XCTAssertEqual(load.state.projects.map(\.name), ["alpha"])
        XCTAssertEqual(load.unreadable.sessionAttachments.sessions, [sessionID])
        XCTAssertTrue(load.unreadable.panelLayouts.isEmpty)
        XCTAssertEqual(try rowCount("session_attachments"), 1)
    }

    /// A row no feature can ever ask for by id, which is why it is tracked apart: refusing writes
    /// to it protects nothing, and only leaving the table unpruned keeps it.
    func testAuxiliaryRowWithoutASessionIdentifierIsReportedAsUnkeyed() throws {
        let database = try makeDatabase()
        try database.save(ProjectsState(projects: [makeProject("alpha")]))

        let raw = try SQLiteDatabase(path: directory.appendingPathComponent("test.db").path)
        try raw.prepare(ProjectDatabaseSchema.upsertPanel)
            .bind(1, "not-a-session-identifier")
            .bind(2, "{}")
            .run()

        let load = try database.load()

        XCTAssertEqual(load.state.projects.map(\.name), ["alpha"])
        XCTAssertTrue(load.unreadable.panelLayouts.containsUnkeyedRows)
        XCTAssertTrue(
            load.unreadable.panelLayouts.sessions.isEmpty,
            "there is no session to name, which is the whole difference"
        )
        XCTAssertEqual(try rowCount("panel_layout"), 1)
    }

    func testProviderSpecificMutationCannotCreateAnImpossibleWrite() throws {
        let database = try makeDatabase()
        var session = AgentSession(kind: .grok, title: "Invalid")
        XCTAssertFalse(session.setReasoningEffort("high"))

        try database.save(
            ProjectsState(projects: [makeProject("alpha", sessions: [session])])
        )
        XCTAssertNil(try database.load().state.projects[0].sessions[0].reasoningEffort)
    }

    func testClaudeReasoningEffortSurvivesThePayload() throws {
        let database = try makeDatabase()
        var session = AgentSession(kind: .claude, title: "Deliberate", model: "opus")
        XCTAssertTrue(session.setReasoningEffort("xhigh"))

        try database.save(
            ProjectsState(projects: [makeProject("alpha", sessions: [session])])
        )

        let restored = try database.load().state.projects[0].sessions[0]
        XCTAssertEqual(restored.kind, .claude)
        XCTAssertEqual(restored.reasoningEffort, "xhigh")
    }

    // MARK: - Model Fidelity

    func testRichSessionFieldsSurviveThePayload() throws {
        // The payload is the model's own encoding precisely so fields added to `AgentSession`
        // need no schema change; this is the assertion that keeps that claim honest.
        let database = try makeDatabase()
        var session = AgentSession(kind: .claude, title: "Chat", accountHandle: .named("claudedb"), model: "opus")
        session.customTitle = "Renamed"
        session.agentTitle = "working"
        session.branch = "feature/x"
        session.hasLaunched = true
        session.lastExitCode = 3
        session.usesNativeUI = true
        session.isPinned = true
        session.isArchived = true
        session.themeID = .ocean

        var project = makeProject("alpha", sessions: [session])
        project.themeID = .homebrew
        try database.save(ProjectsState(projects: [project]))
        let restoredProject = try XCTUnwrap(try database.load().state.projects.first)
        let restored = try XCTUnwrap(restoredProject.sessions.first)

        XCTAssertEqual(restored.customTitle, "Renamed")
        XCTAssertEqual(restored.agentTitle, "working")
        XCTAssertEqual(restored.branch, "feature/x")
        XCTAssertEqual(restored.model, "opus")
        XCTAssertEqual(restored.accountHandle, session.accountHandle)
        XCTAssertEqual(restored.lastExitCode, 3)
        XCTAssertTrue(restored.hasLaunched)
        XCTAssertTrue(restored.usesNativeUI)
        XCTAssertTrue(restored.isPinned)
        XCTAssertTrue(restored.isArchived)
        XCTAssertEqual(restored.themeID, .ocean)
        XCTAssertEqual(restoredProject.themeID, .homebrew)
    }

    // MARK: - The Real Document

    /// Imports the machine's own `projects.json` into a throwaway database.
    ///
    /// A fixture proves the code path; this proves the *file this user will actually migrate*.
    /// The source is only ever read — the copy is what gets imported — and the test skips where
    /// there is nothing to read, so it is evidence here and silent everywhere else.
    func testRealProjectsDocumentImportsWithoutLoss() throws {
        let live = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Threading/projects.json")
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
        XCTAssertEqual(
            importedSessions.map { $0.displayTitle },
            expectedSessions.map { $0.displayTitle }
        )
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

    private func updatePayload(table: String, id: String, payload: String) throws {
        let database = try SQLiteDatabase(path: directory.appendingPathComponent("test.db").path)
        try database.prepare("UPDATE \(table) SET data = ? WHERE id = ?")
            .bind(1, payload)
            .bind(2, id)
            .run()
    }
}
