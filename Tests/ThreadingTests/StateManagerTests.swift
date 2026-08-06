import XCTest
@testable import Threading

@MainActor
final class StateManagerTests: XCTestCase {

    private nonisolated(unsafe) var testDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-state-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testProjectStoreLookupIndexesFollowStructuralEdits() throws {
        let store = ProjectStore(stateManager: makeManager())
        let firstProject = store.addProject(
            folderURL: testDirectory.appendingPathComponent("first", isDirectory: true)
        )
        let secondProject = store.addProject(
            folderURL: testDirectory.appendingPathComponent("second", isDirectory: true)
        )
        let removedSession = try XCTUnwrap(
            store.addSession(to: firstProject.id, kind: .claude, title: "removed")
        )
        let retainedSession = try XCTUnwrap(
            store.addSession(to: firstProject.id, kind: .codex, title: "retained")
        )
        let shiftedProjectSession = try XCTUnwrap(
            store.addSession(to: secondProject.id, kind: .claude, title: "shifted")
        )

        XCTAssertEqual(store.session(withID: retainedSession.id)?.title, "retained")
        XCTAssertEqual(store.project(forSessionID: retainedSession.id)?.id, firstProject.id)

        store.setProject(id: secondProject.id, expanded: false)
        let reopened = ProjectStore(stateManager: makeManager())
        XCTAssertEqual(reopened.project(withID: secondProject.id)?.isExpanded, false)
        XCTAssertEqual(
            reopened.project(withID: secondProject.id)?.sessions.map(\.id),
            [shiftedProjectSession.id],
            "saving disclosure state must not replace the project's session rows"
        )

        store.removeSession(id: removedSession.id)
        XCTAssertNil(store.session(withID: removedSession.id))
        XCTAssertEqual(store.session(withID: retainedSession.id)?.id, retainedSession.id)

        store.removeProject(id: firstProject.id)
        XCTAssertNil(store.project(withID: firstProject.id))
        XCTAssertNil(store.session(withID: retainedSession.id))
        XCTAssertEqual(store.project(withID: secondProject.id)?.id, secondProject.id)
        XCTAssertEqual(
            store.project(forSessionID: shiftedProjectSession.id)?.id,
            secondProject.id
        )
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
        XCTAssertNil(session.reasoningEffort)
        XCTAssertNil(session.fastMode)
        XCTAssertNil(session.branch)
    }

    func testLegacyResumeIdentifierDecodesIntoExplicitStates() throws {
        let decoder = JSONDecoder()
        let pendingID = SessionID()
        let resumableID = SessionID()
        let pending = try decoder.decode(
            AgentSession.self,
            from: Data(
                #"{"id":"\#(pendingID.uuidString)","kind":"codex","title":"Pending"}"#.utf8
            )
        )
        let resumable = try decoder.decode(
            AgentSession.self,
            from: Data(
                """
                {"id":"\(resumableID.uuidString)","kind":"claude","title":"Ready",\
                "agentSessionID":"legacy-thread"}
                """.utf8
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
                from: Data(
                    #"{"id":"\#(SessionID().uuidString)","kind":"shell","title":"Shell"}"#.utf8
                )
            )
        )
    }

    func testIdentityProviderAndProjectPathAreRequiredRatherThanInvented() {
        let decoder = JSONDecoder()

        XCTAssertThrowsError(
            try decoder.decode(
                AgentSession.self,
                from: Data(#"{"kind":"claude","title":"No identity"}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try decoder.decode(
                AgentSession.self,
                from: Data(
                    #"{"id":"\#(SessionID().uuidString)","title":"No provider"}"#.utf8
                )
            )
        )
        XCTAssertThrowsError(
            try decoder.decode(
                Project.self,
                from: Data(
                    #"{"id":"\#(ProjectID().uuidString)","name":"No path"}"#.utf8
                )
            )
        )
    }

    func testProviderSpecificSessionStateRejectsImpossibleCombinations() {
        let id = SessionID().uuidString
        let other = SessionID().uuidString
        let impossible = [
            """
            {"id":"\(id)","kind":"grok","title":"Wrong option",\
            "reasoningEffort":"high"}
            """,
            """
            {"id":"\(id)","kind":"opencode","title":"Wrong option",\
            "reasoningEffort":"high"}
            """,
            """
            {"id":"\(id)","kind":"codex","title":"Wrong option",\
            "remoteControl":true}
            """,
            """
            {"id":"\(id)","kind":"codex","title":"Wrong lineage",\
            "forkParent":"\(other)"}
            """,
            """
            {"id":"\(id)","kind":"codex","title":"Unpaired lineage",\
            "continuationSource":"\(other)"}
            """,
            """
            {"id":"\(id)","kind":"codex","title":"Same provider",\
            "continuationSource":"\(other)","continuationSourceKind":"codex"}
            """
        ]

        for json in impossible {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    AgentSession.self,
                    from: Data(json.utf8)
                ),
                json
            )
        }
    }

    func testExplicitModelEncodingPreservesNonDefaultFields() throws {
        let parentID = SessionID()
        let sessionID = SessionID()
        let handoff = try XCTUnwrap(ConversationHandoff(endpoints: [
            ConversationHandoffEndpoint(
                sessionID: parentID,
                kind: .claude,
                model: "claude-sonnet-4-5",
                title: "Original"
            ),
            ConversationHandoffEndpoint(
                sessionID: sessionID,
                kind: .codex,
                model: "gpt-test",
                title: "Original"
            )
        ]))
        var session = AgentSession(
            configuration: .codex(reasoningEffort: "ultra"),
            title: "Original",
            accountHandle: .named("codex-work"),
            model: "gpt-test",
            usesNativeUI: true,
            handoff: handoff,
            id: sessionID
        )
        session.customTitle = "Renamed"
        session.agentTitle = "Terminal title"
        session.resumeState = .resumable(TranscriptID("thread-test"))
        session.hasLaunched = true
        session.lastExitCode = 7
        session.fastMode = true
        session.branch = "feature/test"
        session.isPinned = true
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

        // The agent title still travels under the key it had when the terminal was its only
        // transport, so records written before the rename decode unchanged.
        XCTAssertEqual(encodedSession["terminalTitle"] as? String, "Terminal title")

        let restored = try JSONDecoder().decode(Project.self, from: data)
        let restoredSession = try XCTUnwrap(restored.sessions.first)

        XCTAssertEqual(restored.id, project.id)
        XCTAssertFalse(restored.isExpanded)
        XCTAssertEqual(restored.icon, project.icon)
        XCTAssertEqual(restoredSession.id, session.id)
        XCTAssertEqual(restoredSession.customTitle, "Renamed")
        XCTAssertEqual(restoredSession.agentTitle, "Terminal title")
        XCTAssertEqual(restoredSession.resumeState, .resumable(TranscriptID("thread-test")))
        XCTAssertEqual(restoredSession.accountHandle, .named("codex-work"))
        XCTAssertEqual(restoredSession.model, "gpt-test")
        XCTAssertEqual(restoredSession.reasoningEffort, "ultra")
        XCTAssertEqual(restoredSession.fastMode, true)
        XCTAssertEqual(restoredSession.branch, "feature/test")
        XCTAssertTrue(restoredSession.isPinned)
        XCTAssertEqual(restoredSession.lastExitCode, 7)
        XCTAssertEqual(restoredSession.continuedFrom, parentID)
        XCTAssertEqual(restoredSession.continuationSourceKind, .claude)
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
    func testCorruptLegacyStateIsQuarantinedAndWritesStayDisabledForTheLaunch() throws {
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

        // A successful quarantine preserves the unreadable bytes, but does not make the empty
        // in-memory store authoritative. This launch remains read-only until recovery/restart.
        XCTAssertEqual(store.projects.count, 1, "the attempted edit may remain visible in memory")
        XCTAssertEqual(try Data(contentsOf: quarantineURL), corruptData)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: liveURL.path),
            "a failed load must not resurrect the document that was moved aside"
        )
        guard case .failed(let repeatedQuarantineURL) = manager.loadProjectsState() else {
            return XCTFail("Expected persistence recovery to remain latched")
        }
        XCTAssertEqual(
            repeatedQuarantineURL?.resolvingSymlinksInPath(),
            quarantineURL.resolvingSymlinksInPath()
        )

        let database = try ProjectDatabase(
            url: testDirectory.appendingPathComponent(SQLiteDefaults.databaseName)
        )
        XCTAssertTrue(try database.isEmpty(), "the attempted edit must not become replacement state")
    }

    func testCorruptDatabaseRowIsQuarantinedAndCannotBeOverwrittenInTheSameLaunch() throws {
        let databaseURL = testDirectory.appendingPathComponent(SQLiteDefaults.databaseName)
        let project = Project(
            name: "Preserve me",
            folderURL: URL(fileURLWithPath: "/tmp/preserve-me")
        )

        do {
            let database = try ProjectDatabase(url: databaseURL)
            try database.save(ProjectsState(projects: [project]))
        }
        do {
            let raw = try SQLiteDatabase(path: databaseURL.path)
            try raw.prepare("UPDATE project SET data = ? WHERE id = ?")
                .bind(1, "{ damaged-json")
                .bind(2, project.id.uuidString)
                .run()
        }

        let manager = makeManager()
        guard case .failed(let quarantinedAt) = manager.loadProjectsState() else {
            return XCTFail("Expected an invalid row to fail the authoritative load")
        }
        let quarantineURL = try XCTUnwrap(quarantinedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))

        let replacement = ProjectsState(projects: [
            Project(name: "Replacement", folderURL: URL(fileURLWithPath: "/tmp/replacement"))
        ])
        XCTAssertFalse(manager.saveProjectsState(replacement))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: databaseURL.path),
            "a write after failed load must not create replacement state"
        )

        let preserved = try SQLiteDatabase(path: quarantineURL.path)
        XCTAssertEqual(try preserved.scalar("SELECT COUNT(*) FROM project"), 1)
        let payload = try preserved.prepare("SELECT data FROM project WHERE id = ?")
        defer { payload.finalize() }
        payload.bind(1, project.id.uuidString)
        XCTAssertTrue(try payload.step())
        XCTAssertEqual(payload.text(0), "{ damaged-json")

        guard case .recoveryRequired(let recordedURL) = manager.persistenceHealth else {
            return XCTFail("Expected persistence recovery to remain latched")
        }
        XCTAssertEqual(recordedURL, quarantineURL)
    }

    /// The whole of the 2026-08-06 data loss, end to end.
    ///
    /// A display panel row carrying a format version this build does not know is not damage — it
    /// is a build one step ahead having written it. It used to fail the authoritative load, and a
    /// failed load quarantines the database: four projects and 138 chats, gone, over an empty tab
    /// list. The panel is reported absent so the pane rebuilds, its bytes are refused to the
    /// writer so the newer build still finds them, and everything else loads.
    func testPanelFromANewerBuildCostsThePanelRatherThanTheStore() throws {
        let databaseURL = testDirectory.appendingPathComponent(SQLiteDefaults.databaseName)
        let sessionID = SessionID()
        let futurePanel = #"{"formatVersion":99,"observedSignature":"h:Output·Fixture","tabs":[]}"#
        do {
            let database = try ProjectDatabase(url: databaseURL)
            try database.save(ProjectsState(projects: [
                Project(name: "Keep me", folderURL: URL(fileURLWithPath: "/tmp/keep-me"))
            ]))
            try database.savePanelPayload(futurePanel, for: sessionID)
        }

        let manager = makeManager()
        guard case .loaded(let state) = manager.loadProjectsState() else {
            return XCTFail("One unreadable panel must not fail the load that carries the projects")
        }
        XCTAssertEqual(state.projects.map(\.name), ["Keep me"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: databaseURL.path + ".corrupt"),
            "nothing here warrants moving the store aside"
        )
        guard case .healthy = manager.persistenceHealth else {
            return XCTFail("The store is readable; writes must stay open")
        }

        XCTAssertNil(
            manager.loadPanelPayload(for: sessionID),
            "the pane is told it has nothing, so it rebuilds rather than showing half a layout"
        )

        manager.savePanelPayload(#"{"tabs":[]}"#, for: sessionID)
        let stored = try SQLiteDatabase(path: databaseURL.path)
        let payload = try stored.prepare(
            "SELECT data FROM \(ProjectDatabaseSchema.panelTable) WHERE session_id = ?"
        )
        defer { payload.finalize() }
        payload.bind(1, sessionID.uuidString)
        XCTAssertTrue(try payload.step())
        XCTAssertEqual(
            payload.text(0),
            futurePanel,
            "a row this build could not read must not be replaced by what it would have written"
        )

        XCTAssertTrue(
            manager.saveProjectsState(ProjectsState(projects: [
                Project(name: "Still writable", folderURL: URL(fileURLWithPath: "/tmp/writable"))
            ])),
            "the store itself was never in doubt"
        )
    }

    /// Quarantine has to leave something behind, and for months it did not.
    ///
    /// In WAL mode the committed rows sit in `-wal` until a checkpoint, and a checkpoint happens
    /// when the *last* connection closes — which never happens while a second build or a hosted
    /// test target holds the same store open. Quarantine deleted that file, so the copy it kept
    /// for recovery was an empty shell and the only real copy was unlinked. Measured on the store
    /// that hit it: zero project rows in the database, every project in a 498KB log.
    func testQuarantineKeepsTheWriteAheadLogThatHoldsTheRows() throws {
        let databaseURL = testDirectory.appendingPathComponent(SQLiteDefaults.databaseName)
        let project = Project(name: "In the log", folderURL: URL(fileURLWithPath: "/tmp/in-the-log"))

        // The schema first, on its own, so closing it checkpoints and the file starts clean.
        _ = try ProjectDatabase(url: databaseURL)

        // Then a reader holding an open snapshot from before the rows are written. A checkpoint
        // may only copy frames older than the oldest reader, so this pins every row that follows
        // inside the log — deterministically reproducing the state the running app is in, where
        // the second connection is another build or a hosted test target.
        let concurrentReader = try SQLiteDatabase(path: databaseURL.path)
        try concurrentReader.execute("BEGIN")
        _ = try concurrentReader.scalar("SELECT COUNT(*) FROM project")

        do {
            let database = try ProjectDatabase(url: databaseURL)
            try database.save(ProjectsState(projects: [project]))
        }
        do {
            let raw = try SQLiteDatabase(path: databaseURL.path)
            try raw.prepare("UPDATE project SET data = ? WHERE id = ?")
                .bind(1, "{ damaged-json")
                .bind(2, project.id.uuidString)
                .run()
        }

        let log = URL(fileURLWithPath: databaseURL.path + SQLiteDefaults.walSuffix)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: log.path),
            "the fixture has to reproduce an unchecked-pointed store or it proves nothing"
        )
        let manager = makeManager()
        guard case .failed(let quarantinedAt) = manager.loadProjectsState() else {
            return XCTFail("A damaged project row is still all-or-nothing")
        }
        let quarantineURL = try XCTUnwrap(quarantinedAt)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: quarantineURL.path + SQLiteDefaults.walSuffix
            ),
            "the log moves with the database it belongs to, under the name SQLite will look for"
        )
        // Read through copies rather than in place: the abandoned connection above still holds
        // the original inode, and two connections reaching one inode by different names is a
        // conflict SQLite reports as an I/O error. Recovery copies the files anyway.
        let withoutTheLog = testDirectory.appendingPathComponent("quarantined-alone.db")
        try FileManager.default.copyItem(at: quarantineURL, to: withoutTheLog)
        XCTAssertEqual(
            (try? SQLiteDatabase(path: withoutTheLog.path)
                .scalar("SELECT COUNT(*) FROM project")) ?? 0,
            0,
            "the database file on its own is empty — which is all the old behaviour kept"
        )

        let recovered = testDirectory.appendingPathComponent("recovered.db")
        try FileManager.default.copyItem(at: quarantineURL, to: recovered)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: quarantineURL.path + SQLiteDefaults.walSuffix),
            to: URL(fileURLWithPath: recovered.path + SQLiteDefaults.walSuffix)
        )
        XCTAssertEqual(
            try SQLiteDatabase(path: recovered.path).scalar("SELECT COUNT(*) FROM project"),
            1,
            "with its log the quarantined copy is the state, which is the point of keeping it"
        )

        // Nothing may be left beside the live path: SQLite would read it as the log of whatever
        // database is created there next.
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: databaseURL.path + SQLiteDefaults.sharedMemorySuffix
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))

        // Held to here and then abandoned rather than committed: a connection whose database has
        // been moved out from under it is finished, which is true of the running app too and is
        // not what this test is about.
        withExtendedLifetime(concurrentReader) {}
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

    // MARK: - Display Panel Migration

    func testLegacyPanelsStillImportWhenTheDatabaseAlreadyContainsAnotherPanel() throws {
        let manager = makeManager()
        let existingID = SessionID()
        let legacyID = SessionID()
        manager.savePanelPayload(#"{"source":"database"}"#, for: existingID)

        let panels = testDirectory.appendingPathComponent(
            DisplayPaneStoreDefaults.rootDirectory,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: panels, withIntermediateDirectories: true)
        let legacy = panels
            .appendingPathComponent(legacyID.uuidString)
            .appendingPathExtension(DisplayPaneStoreDefaults.layoutExtension)
        try #"{"source":"legacy"}"#.write(to: legacy, atomically: true, encoding: .utf8)

        XCTAssertEqual(manager.loadPanelPayload(for: legacyID), #"{"source":"legacy"}"#)
        XCTAssertEqual(manager.loadPanelPayload(for: existingID), #"{"source":"database"}"#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacy.appendingPathExtension(SQLiteDefaults.migratedSuffix).path
            )
        )
    }

    func testUnreadableLegacyPanelIsPreservedAndClosesPersistence() throws {
        let manager = makeManager()
        let sessionID = SessionID()
        let panels = testDirectory.appendingPathComponent(
            DisplayPaneStoreDefaults.rootDirectory,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: panels, withIntermediateDirectories: true)
        let legacy = panels
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension(DisplayPaneStoreDefaults.layoutExtension)
        try Data([0xFF, 0xFE]).write(to: legacy)

        XCTAssertNil(manager.loadPanelPayload(for: sessionID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        guard case .recoveryRequired = manager.persistenceHealth else {
            return XCTFail("Unreadable legacy state must disable later persistence writes")
        }
    }

    // MARK: - Session Attachments

    /// The list survives a relaunch: a second store wired to the same state answers with what
    /// the first recorded. Detection only sees live output, so without this the Attachments tab
    /// reopened onto an empty pane after every restart.
    func testSessionAttachmentsSurviveARelaunch() throws {
        let manager = makeManager()
        let sessionID = SessionID()
        let root = testDirectory.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("plan.png")
        try Data([0x89, 0x50]).write(to: image)

        func makeStore() -> SessionAttachmentStore {
            SessionAttachmentStore(
                loadPayload: { manager.loadAttachmentsPayload(for: $0) },
                savePayload: { manager.saveAttachmentsPayload($0, for: $1) },
                retainPersisted: { manager.retainAttachments(sessionIDs: $0) }
            )
        }

        let recorded = makeStore().record(url: image, sessionID: sessionID, projectRoot: root)
        XCTAssertEqual(recorded?.relativePath, "plan.png")

        let relaunched = makeStore()
        XCTAssertEqual(
            relaunched.attachments(for: sessionID).map(\.relativePath),
            ["plan.png"]
        )

        // A file deleted while the app was closed falls out on first read, and the pruned
        // list is written back rather than resurrecting the row on the next launch.
        try FileManager.default.removeItem(at: image)
        XCTAssertEqual(relaunched.attachments(for: sessionID), [])
        XCTAssertEqual(makeStore().attachments(for: sessionID), [])
    }

    func testRetainedSessionAttachmentsDropPrunedSessions() throws {
        let manager = makeManager()
        let kept = SessionID()
        let pruned = SessionID()
        manager.saveAttachmentsPayload("[]", for: kept)
        manager.saveAttachmentsPayload("[]", for: pruned)

        manager.retainAttachments(sessionIDs: [kept])

        XCTAssertNotNil(manager.loadAttachmentsPayload(for: kept))
        XCTAssertNil(manager.loadAttachmentsPayload(for: pruned))
    }

    private func makeManager() -> StateManager {
        StateManager(
            appSupportDirectory: testDirectory,
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
    }

    // MARK: - Pre-Rename Application Support

    /// The whole point: the rename left the user's projects in the old directory and the app came
    /// up on an empty store beside it.
    func testAdoptingThePreRenameDirectoryBringsTheDatabaseAcross() throws {
        let legacy = try makeLegacyDirectory(projectNamed: "Real work")
        let current = testDirectory.appendingPathComponent("Threading", isDirectory: true)

        let outcome = LegacyApplicationSupportMigration.runIfNeeded(
            applicationSupport: testDirectory
        )

        XCTAssertTrue(outcome.adoptedDatabase)
        let adopted = try ProjectDatabase(
            url: current.appendingPathComponent(SQLiteDefaults.databaseName)
        )
        XCTAssertEqual(try adopted.load().state.projects.map(\.name), ["Real work"])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacy.path),
            "The old directory is copied, never moved — a bad adoption must not be the only copy"
        )
    }

    func testAdoptionCarriesTheDirectoriesBesideTheDatabase() throws {
        _ = try makeLegacyDirectory(projectNamed: "Real work", extraFiles: [
            "settings/A1.json": "{}",
            "panels/one.json": "{}",
            "usage-history.json": "[1,2,3]"
        ])
        let current = testDirectory.appendingPathComponent("Threading", isDirectory: true)

        let outcome = LegacyApplicationSupportMigration.runIfNeeded(
            applicationSupport: testDirectory
        )

        XCTAssertEqual(outcome.adoptedFileCount, 3)
        for relative in ["settings/A1.json", "panels/one.json", "usage-history.json"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: current.appendingPathComponent(relative).path
                ),
                "\(relative) should have come across"
            )
        }
    }

    /// A store with work in it is never written over, however much sits in the old directory.
    func testAStoreWithProjectsIsLeftAlone() throws {
        _ = try makeLegacyDirectory(projectNamed: "Old work")
        let current = testDirectory.appendingPathComponent("Threading", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let database = try ProjectDatabase(
            url: current.appendingPathComponent(SQLiteDefaults.databaseName)
        )
        try database.save(ProjectsState(
            projects: [Project(name: "Current work", folderURL: URL(fileURLWithPath: "/tmp/c"))],
            selectedSessionID: nil
        ))

        let outcome = LegacyApplicationSupportMigration.runIfNeeded(
            applicationSupport: testDirectory
        )

        XCTAssertEqual(outcome, .init())
        let reopened = try ProjectDatabase(
            url: current.appendingPathComponent(SQLiteDefaults.databaseName)
        )
        XCTAssertEqual(try reopened.load().state.projects.map(\.name), ["Current work"])
    }

    /// A user who deliberately started over must not be handed the old state back every launch.
    func testAdoptionRunsOnlyOnce() throws {
        _ = try makeLegacyDirectory(projectNamed: "Real work")

        XCTAssertTrue(
            LegacyApplicationSupportMigration.runIfNeeded(applicationSupport: testDirectory)
                .adoptedDatabase
        )

        let current = testDirectory.appendingPathComponent("Threading", isDirectory: true)
        try FileManager.default.removeItem(
            at: current.appendingPathComponent(SQLiteDefaults.databaseName)
        )

        XCTAssertEqual(
            LegacyApplicationSupportMigration.runIfNeeded(applicationSupport: testDirectory),
            .init(),
            "The marker should stop a second adoption even with the store gone again"
        )
    }

    func testNothingHappensWithoutAnOldDirectory() {
        XCTAssertEqual(
            LegacyApplicationSupportMigration.runIfNeeded(applicationSupport: testDirectory),
            .init()
        )
    }

    /// The lock belongs to whichever process holds it, and a `.migrated` file was already retired
    /// by an earlier migration — neither should be re-littered into the new directory.
    func testTheLockAndAlreadyRetiredFilesStayBehind() throws {
        _ = try makeLegacyDirectory(projectNamed: "Real work", extraFiles: [
            LegacyApplicationSupportDefaults.lockFileName: "",
            "projects.json.migrated": "{}",
            "drafts.json": "{}"
        ])
        let current = testDirectory.appendingPathComponent("Threading", isDirectory: true)

        let outcome = LegacyApplicationSupportMigration.runIfNeeded(
            applicationSupport: testDirectory
        )

        XCTAssertEqual(outcome.adoptedFileCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: current.appendingPathComponent("drafts.json").path
        ))
        for skipped in [LegacyApplicationSupportDefaults.lockFileName, "projects.json.migrated"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: current.appendingPathComponent(skipped).path
                ),
                "\(skipped) should not have come across"
            )
        }
    }

    @discardableResult
    private func makeLegacyDirectory(
        projectNamed name: String,
        extraFiles: [String: String] = [:]
    ) throws -> URL {
        let legacy = testDirectory.appendingPathComponent(
            LegacyApplicationSupportDefaults.directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

        let database = try ProjectDatabase(
            url: legacy.appendingPathComponent(LegacyApplicationSupportDefaults.databaseName)
        )
        try database.save(ProjectsState(
            projects: [Project(name: name, folderURL: URL(fileURLWithPath: "/tmp/legacy"))],
            selectedSessionID: nil
        ))

        for (relative, contents) in extraFiles {
            let file = legacy.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
        return legacy
    }
}
