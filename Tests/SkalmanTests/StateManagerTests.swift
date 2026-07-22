import XCTest
@testable import Skalman

final class StateManagerTests: XCTestCase {

    private var testDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("skalman-state-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let testDirectory {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        testDirectory = nil
        try super.tearDownWithError()
    }

    func testVersionOneStateRoundTrips() throws {
        let manager = makeManager()
        let project = Project(name: "Fixture", folderURL: URL(fileURLWithPath: "/tmp/fixture"))
        let selectedSessionID = SessionID()
        let state = ProjectsState(
            projects: [project],
            selectedSessionID: selectedSessionID
        )

        XCTAssertTrue(manager.saveProjectsState(state))

        guard case .loaded(let restored) = manager.loadProjectsState() else {
            return XCTFail("Expected the version-one state to load")
        }
        XCTAssertEqual(restored.version, ProjectsStateVersion.current)
        XCTAssertEqual(restored.projects.map(\.id), [project.id])
        XCTAssertEqual(restored.projects.map(\.name), ["Fixture"])
        XCTAssertEqual(restored.selectedSessionID, selectedSessionID)
    }

    func testMissingKeyFixtureDecodesWithModelDefaults() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Projects/missing-fields-v1.json")
        let data = try Data(contentsOf: fixtureURL)
        let state = try JSONDecoder().decode(ProjectsState.self, from: data)

        let project = try XCTUnwrap(state.projects.first)
        XCTAssertEqual(project.id, ProjectID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!))
        XCTAssertEqual(project.name, "Legacy Project")
        XCTAssertTrue(project.isExpanded)
        XCTAssertNil(project.icon)

        let session = try XCTUnwrap(project.sessions.first)
        XCTAssertEqual(session.id, SessionID(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!))
        XCTAssertEqual(session.kind, .claude)
        XCTAssertEqual(session.title, "Legacy Conversation")
        XCTAssertEqual(session.lastActiveAt, session.createdAt)
        XCTAssertFalse(session.hasLaunched)
        XCTAssertEqual(session.accountHandle, .standard)
        XCTAssertFalse(session.isArchived)
        XCTAssertFalse(session.usesNativeUI)
        XCTAssertNil(session.forkedFrom)
        XCTAssertEqual(session.resumeState, .awaitingIdentifier)
        XCTAssertNil(session.model)
        XCTAssertNil(session.branch)
    }

    func testLegacyResumeIdentifierDecodesIntoExplicitStates() throws {
        let decoder = JSONDecoder()
        let pending = try decoder.decode(
            AgentSession.self,
            from: Data(#"{"kind":"codex","title":"Pending"}"#.utf8)
        )
        let resumable = try decoder.decode(
            AgentSession.self,
            from: Data(
                #"{"kind":"claude","title":"Ready","agentSessionID":"legacy-thread"}"#.utf8
            )
        )
        XCTAssertEqual(pending.resumeState, .awaitingIdentifier)
        XCTAssertEqual(resumable.resumeState, .resumable(TranscriptID("legacy-thread")))

        // A shell is no longer a kind, so a record naming one does not decode at all. That is
        // the reason the version-1 migration strips them before the document is read, rather
        // than the model quietly tolerating a kind it no longer has.
        XCTAssertThrowsError(
            try decoder.decode(
                AgentSession.self,
                from: Data(#"{"kind":"shell","title":"Shell"}"#.utf8)
            )
        )
    }

    func testExplicitModelEncodingPreservesNonDefaultFields() throws {
        let parentID = SessionID()
        var session = AgentSession(
            kind: .codex,
            title: "Original",
            accountHandle: .named("codex-work"),
            model: "gpt-test",
            usesNativeUI: true,
            forkedFrom: parentID
        )
        session.customTitle = "Renamed"
        session.terminalTitle = "Terminal title"
        session.resumeState = .resumable(TranscriptID("thread-test"))
        session.hasLaunched = true
        session.lastExitCode = 7
        session.branch = "feature/test"
        session.isArchived = true

        var project = Project(
            name: "Round Trip",
            folderURL: URL(fileURLWithPath: "/tmp/round-trip")
        )
        project.sessions = [session]
        project.isExpanded = false
        project.icon = ProjectIcon(source: .custom, fileName: "icon.png")

        let data = try JSONEncoder().encode(project)
        let encodedProject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encodedSessions = try XCTUnwrap(encodedProject["sessions"] as? [[String: Any]])
        let encodedSession = try XCTUnwrap(encodedSessions.first)
        XCTAssertEqual(encodedSession["agentSessionID"] as? String, "thread-test")
        XCTAssertNil(encodedSession["resumeState"])

        let restored = try JSONDecoder().decode(Project.self, from: data)
        let restoredSession = try XCTUnwrap(restored.sessions.first)

        XCTAssertEqual(restored.id, project.id)
        XCTAssertFalse(restored.isExpanded)
        XCTAssertEqual(restored.icon, project.icon)
        XCTAssertEqual(restoredSession.id, session.id)
        XCTAssertEqual(restoredSession.customTitle, "Renamed")
        XCTAssertEqual(restoredSession.terminalTitle, "Terminal title")
        XCTAssertEqual(restoredSession.resumeState, .resumable(TranscriptID("thread-test")))
        XCTAssertEqual(restoredSession.accountHandle, .named("codex-work"))
        XCTAssertEqual(restoredSession.model, "gpt-test")
        XCTAssertEqual(restoredSession.branch, "feature/test")
        XCTAssertEqual(restoredSession.lastExitCode, 7)
        XCTAssertEqual(restoredSession.forkedFrom, parentID)
        XCTAssertTrue(restoredSession.hasLaunched)
        XCTAssertTrue(restoredSession.isArchived)
        XCTAssertTrue(restoredSession.usesNativeUI)
    }

    func testTypedIdentifiersPreserveLegacyEncoding() throws {
        let rawProjectID = UUID()
        let rawSessionID = UUID()
        let rawTranscriptID = "provider-issued-resume-id"
        let accountID = AccountID(provider: .claude, handle: .named("claude-work"))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(
            try encoder.encode(ProjectID(rawProjectID)),
            try encoder.encode(rawProjectID)
        )
        XCTAssertEqual(
            try encoder.encode(SessionID(rawSessionID)),
            try encoder.encode(rawSessionID)
        )
        XCTAssertEqual(
            try encoder.encode(TranscriptID(rawTranscriptID)),
            try encoder.encode(rawTranscriptID)
        )
        XCTAssertEqual(
            try encoder.encode(accountID),
            try encoder.encode("claude:claude-work")
        )
        XCTAssertEqual(
            try decoder.decode(ProjectID.self, from: encoder.encode(rawProjectID)),
            ProjectID(rawProjectID)
        )
        XCTAssertEqual(
            try decoder.decode(SessionID.self, from: encoder.encode(rawSessionID)),
            SessionID(rawSessionID)
        )
        XCTAssertEqual(
            try decoder.decode(TranscriptID.self, from: encoder.encode(rawTranscriptID)),
            TranscriptID(rawTranscriptID)
        )
        XCTAssertEqual(
            try decoder.decode(AccountID.self, from: encoder.encode("claude:claude-work")),
            accountID
        )
        XCTAssertEqual(AccountID(rawValue: "codex:default")?.handle, .standard)
    }

    func testAccountHandlePreservesLegacySessionJSON() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let standard = AgentSession(kind: .claude, title: "Standard")
        let standardData = try encoder.encode(standard)
        let standardObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: standardData) as? [String: Any]
        )
        XCTAssertNil(standardObject["accountHandle"])
        XCTAssertEqual(
            try decoder.decode(AgentSession.self, from: standardData).accountHandle,
            .standard
        )

        let named = AgentSession(
            kind: .claude,
            title: "Named",
            accountHandle: .named("claude-work")
        )
        let namedData = try encoder.encode(named)
        let namedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: namedData) as? [String: Any]
        )
        XCTAssertEqual(namedObject["accountHandle"] as? String, "claude-work")
        XCTAssertEqual(
            try decoder.decode(AgentSession.self, from: namedData).accountHandle,
            .named("claude-work")
        )
    }

    func testMissingStateStartsFresh() {
        guard case .missing = makeManager().loadProjectsState() else {
            return XCTFail("Expected a missing state file to be distinct from a failed load")
        }
    }

    /// The rolling `projects.json.bak` is gone, and this is what replaced it: a save is one
    /// transaction, so the previous state survives anything that interrupts the next one.
    /// There is no window in which the store is half-written, which is the whole reason a
    /// backup copy existed.
    func testSaveReplacesTheWholeStateAtomically() throws {
        let manager = makeManager()
        let first = ProjectsState(projects: [
            Project(name: "First", folderURL: URL(fileURLWithPath: "/tmp/first"))
        ])
        let second = ProjectsState(projects: [
            Project(name: "Second", folderURL: URL(fileURLWithPath: "/tmp/second"))
        ])

        XCTAssertTrue(manager.saveProjectsState(first))
        XCTAssertTrue(manager.saveProjectsState(second))

        guard case .loaded(let current) = manager.loadProjectsState() else {
            return XCTFail("Expected the replacement state to load")
        }
        XCTAssertEqual(current.projects.map(\.name), ["Second"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: testDirectory.appendingPathComponent("projects.json").path),
            "the database is the store now; nothing should write the document back"
        )
    }

    /// The imported document is kept, not deleted — the rollback that opencode's own move off
    /// per-file JSON did not leave itself.
    func testImportedDocumentIsRetainedForRollback() throws {
        let liveURL = testDirectory.appendingPathComponent("projects.json")
        let state = ProjectsState(projects: [
            Project(name: "Imported", folderURL: URL(fileURLWithPath: "/tmp/imported"))
        ])
        try JSONEncoder().encode(state).write(to: liveURL)

        let manager = makeManager()
        guard case .loaded(let restored) = manager.loadProjectsState() else {
            return XCTFail("Expected the legacy document to be imported")
        }
        XCTAssertEqual(restored.projects.map(\.name), ["Imported"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: liveURL.path), "the document is retired")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: liveURL.appendingPathExtension("migrated").path),
            "…but kept beside the database"
        )

        // And it is imported exactly once: a second load reads the database, not the file.
        guard case .loaded(let second) = manager.loadProjectsState() else {
            return XCTFail("Expected the database to load on the second pass")
        }
        XCTAssertEqual(second.projects.map(\.name), ["Imported"])
    }

    @MainActor
    func testCorruptStateIsQuarantinedAndFreshStateDoesNotOverwriteIt() throws {
        let corruptData = Data("{ definitely-not-json".utf8)
        let liveURL = testDirectory.appendingPathComponent("projects.json")
        try corruptData.write(to: liveURL)

        let manager = makeManager()
        let store = ProjectStore(stateManager: manager)

        XCTAssertFalse(store.didLoadStateSuccessfully)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveURL.path))

        let quarantineURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: testDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("projects.json.corrupt-") }
        )
        XCTAssertEqual(try Data(contentsOf: quarantineURL), corruptData)

        let projectDirectory = testDirectory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        store.addProject(folderURL: projectDirectory)

        // The quarantined document is never touched again — the new state went to the database,
        // and the unreadable file stays exactly as it was for whoever wants to look at it.
        XCTAssertEqual(try Data(contentsOf: quarantineURL), corruptData)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: liveURL.path),
            "a fresh save must not resurrect the document that was moved aside"
        )
        guard case .loaded(let freshState) = manager.loadProjectsState() else {
            return XCTFail("Expected a fresh state after an explicit structural change")
        }
        XCTAssertEqual(freshState.projects.count, 1)
    }

    /// Version 2 removed `AgentKind.shell`. A version-1 document naming that kind must still
    /// import — one session that no longer decodes would otherwise fail the whole document,
    /// which for this user is every project they have.
    func testVersionOneShellSessionsAreDroppedOnImport() throws {
        let projectID = ProjectID()
        let keptID = SessionID()
        let document: [String: Any] = [
            "version": 1,
            "savedAt": 0,
            "projects": [[
                "id": projectID.uuidString,
                "name": "stegvis",
                "folderPath": "/tmp/stegvis",
                "isExpanded": true,
                "createdAt": 0,
                "sessions": [
                    ["id": keptID.uuidString, "kind": "claude", "title": "Claude Code",
                     "createdAt": 0, "lastActiveAt": 0, "hasLaunched": true],
                    ["id": SessionID().uuidString, "kind": "shell", "title": "stegvis",
                     "createdAt": 0, "lastActiveAt": 0, "hasLaunched": true],
                    ["id": SessionID().uuidString, "kind": "shell", "title": "stegvis",
                     "createdAt": 0, "lastActiveAt": 0, "hasLaunched": true]
                ]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: document)
            .write(to: testDirectory.appendingPathComponent("projects.json"))

        guard case .loaded(let state) = makeManager().loadProjectsState() else {
            return XCTFail("a document with shell sessions should still import")
        }

        XCTAssertEqual(state.projects.map(\.name), ["stegvis"], "the project survives")
        XCTAssertEqual(
            state.projects[0].sessions.map(\.id), [keptID],
            "the agent session survives and both shells are gone"
        )
    }

    func testNewerStateVersionIsQuarantined() throws {
        let futureState = ProjectsState(version: ProjectsStateVersion.current + 1)
        let data = try JSONEncoder().encode(futureState)
        let liveURL = testDirectory.appendingPathComponent("projects.json")
        try data.write(to: liveURL)

        guard case .failed(let quarantineURL) = makeManager().loadProjectsState() else {
            return XCTFail("Expected newer state to be refused")
        }
        XCTAssertNotNil(quarantineURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveURL.path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantineURL)), data)
    }

    private func makeManager() -> StateManager {
        StateManager(
            appSupportDirectory: testDirectory,
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
    }
}
