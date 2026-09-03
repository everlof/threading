import SQLite3
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

    private func storedSessionPayload(
        id: SessionID,
        from database: SQLiteDatabase
    ) throws -> Data {
        let statement = try database.prepare("SELECT data FROM session WHERE id = ?")
        defer { statement.finalize() }
        statement.bind(1, id.uuidString)
        guard try statement.step() else {
            throw ProjectDatabaseLoadError.corruptRow(
                table: "session",
                id: id.uuidString,
                reason: "missing test row"
            )
        }
        return try XCTUnwrap(statement.data(0))
    }

    private func storedSession(
        id: SessionID,
        from database: SQLiteDatabase
    ) throws -> AgentSession {
        try JSONDecoder().decode(
            AgentSession.self,
            from: storedSessionPayload(id: id, from: database)
        )
    }

    // MARK: - Native Resource Ownership

    func testAStatementFinalizesWhenBindingThrowsBeforeRun() throws {
        enum Expected: Error { case stop }

        func valueThatThrows() throws -> String { throw Expected.stop }

        let database = try SQLiteDatabase(
            path: directory.appendingPathComponent("ownership.db").path
        )
        try database.execute("CREATE TABLE sample (value TEXT)")

        do {
            try database.prepare("INSERT INTO sample (value) VALUES (?)")
                .bind(1, try valueThatThrows())
                .run()
            XCTFail("the bound value should have thrown")
        } catch Expected.stop {
            // The temporary Statement must unwind its native sqlite3_stmt with it. Before the
            // RAII boundary this left a statement attached to a zombie close_v2 connection.
        }

        XCTAssertFalse(database.hasOpenStatements)

        // Explicit cleanup and deinit may meet on different paths; both must remain harmless.
        let statement = try database.prepare("SELECT value FROM sample")
        XCTAssertTrue(database.hasOpenStatements)
        statement.finalize()
        statement.finalize()
        XCTAssertFalse(database.hasOpenStatements)
    }

    func testStatementReadsTextPayloadBytesWithoutLosingNullOrEmptyValues() throws {
        let database = try SQLiteDatabase(
            path: directory.appendingPathComponent("payload-bytes.db").path
        )
        try database.execute("CREATE TABLE sample (position INTEGER, value TEXT)")
        try database.prepare("INSERT INTO sample (position, value) VALUES (?, ?)")
            .bind(1, 0)
            .bind(2, Optional<String>.none)
            .run()
        try database.prepare("INSERT INTO sample (position, value) VALUES (?, ?)")
            .bind(1, 1)
            .bind(2, "")
            .run()
        let unicodePayload = #"{"title":"Räksmörgås 🦐"}"#
        try database.prepare("INSERT INTO sample (position, value) VALUES (?, ?)")
            .bind(1, 2)
            .bind(2, unicodePayload)
            .run()

        let statement = try database.prepare("SELECT value FROM sample ORDER BY position")
        defer { statement.finalize() }
        XCTAssertTrue(try statement.step())
        XCTAssertNil(statement.data(0))
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.data(0), Data())
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.data(0), Data(unicodePayload.utf8))
        XCTAssertFalse(try statement.step())
    }

    // MARK: - Column Lists

    /// Every statement whose parameters or results are read by number is built from the same
    /// declaration that supplies those numbers, so the two cannot be reordered apart. That is
    /// only worth anything while the declaration still says what the stored rows are — so the
    /// statements are pinned here as text, written out by hand rather than rebuilt from the
    /// enums under test, which would agree with any reordering and prove nothing.
    ///
    /// A failure here is not a style complaint. Reordering a `SELECT` list moves every read
    /// after the change onto the neighbouring column, and SQLite reports nothing: a wrong
    /// `TEXT` arrives as a plausible value. This is the assertion that turns that into a
    /// failing test.
    func testTheStatementsSpellTheirColumnsInTheStoredOrder() {
        XCTAssertEqual(
            ProjectDatabaseSchema.selectSessions,
            """
            SELECT id, project_id, kind, last_active_at, data
            FROM session
            ORDER BY project_id, position
            """
        )
        XCTAssertEqual(
            ProjectDatabaseSchema.selectProjects,
            "SELECT id, name, folder_path, data FROM project ORDER BY position"
        )
        XCTAssertEqual(
            ProjectDatabaseSchema.selectReceiptStates,
            """
            SELECT attention.session_id, attention.generation, receipt.participant_id, \
            receipt.generation
            FROM session_attention AS attention
            LEFT JOIN session_read_receipt AS receipt
              ON receipt.session_id = attention.session_id
            ORDER BY attention.session_id
            """
        )
        XCTAssertEqual(
            ProjectDatabaseSchema.upsertProject,
            """
            INSERT INTO project (id, position, name, folder_path, data)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                position = excluded.position,
                name = excluded.name,
                folder_path = excluded.folder_path,
                data = excluded.data
            """
        )
        XCTAssertEqual(
            ProjectDatabaseSchema.upsertSession,
            """
            INSERT INTO session (id, project_id, position, kind, last_active_at, data)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                project_id = excluded.project_id,
                position = excluded.position,
                kind = excluded.kind,
                last_active_at = excluded.last_active_at,
                data = excluded.data
            """
        )
        XCTAssertEqual(
            ProjectDatabaseSchema.upsertControlGrant,
            """
            INSERT INTO control_grant (id, actor_session_id, conferred_at, revoked_at, data)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                actor_session_id = excluded.actor_session_id,
                conferred_at = excluded.conferred_at,
                revoked_at = excluded.revoked_at,
                data = excluded.data
            """
        )
        XCTAssertEqual(
            ProjectDatabaseSchema.upsertSupervision,
            """
            INSERT INTO supervision (
                id, manager_session_id, child_session_id, assigned_at, state, data
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                manager_session_id = excluded.manager_session_id,
                child_session_id = excluded.child_session_id,
                assigned_at = excluded.assigned_at,
                state = excluded.state,
                data = excluded.data
            """
        )
        XCTAssertEqual(
            ProjectDatabaseSchema.insertSupervisionEvent,
            """
            INSERT INTO supervision_event (id, supervision_id, at, kind, data)
            VALUES (?, ?, ?, ?, ?)
            """
        )
        XCTAssertEqual(
            ProjectDatabaseSchema.upsertSessionReadReceipt,
            """
            INSERT INTO session_read_receipt (session_id, participant_id, generation)
            VALUES (?, ?, ?)
            ON CONFLICT(session_id, participant_id) DO UPDATE SET generation = excluded.generation
            """
        )
    }

    /// The two index spaces are off by one — SQLite numbers result columns from zero and bind
    /// parameters from one — which is the mistake the declarations exist to stop anyone making
    /// by hand. Switched rather than iterated, so adding a column is a compilation failure here
    /// instead of an untested position.
    func testResultColumnsAreZeroBasedAndBoundParametersAreOneBased() {
        for column in ProjectDatabaseSchema.SessionLoadColumn.allCases {
            switch column {
            case .id: XCTAssertEqual(column.read, 0)
            case .projectID: XCTAssertEqual(column.read, 1)
            case .kind: XCTAssertEqual(column.read, 2)
            case .lastActiveAt: XCTAssertEqual(column.read, 3)
            case .data: XCTAssertEqual(column.read, 4)
            }
        }
        for column in ProjectDatabaseSchema.ProjectLoadColumn.allCases {
            switch column {
            case .id: XCTAssertEqual(column.read, 0)
            case .name: XCTAssertEqual(column.read, 1)
            case .folderPath: XCTAssertEqual(column.read, 2)
            case .data: XCTAssertEqual(column.read, 3)
            }
        }
        for column in ProjectDatabaseSchema.ReceiptStateColumn.allCases {
            switch column {
            case .attentionSessionID: XCTAssertEqual(column.read, 0)
            case .attentionGeneration: XCTAssertEqual(column.read, 1)
            case .receiptParticipantID: XCTAssertEqual(column.read, 2)
            case .receiptGeneration: XCTAssertEqual(column.read, 3)
            }
        }
        for column in ProjectDatabaseSchema.ProjectParameter.allCases {
            switch column {
            case .id: XCTAssertEqual(column.binding, 1)
            case .position: XCTAssertEqual(column.binding, 2)
            case .name: XCTAssertEqual(column.binding, 3)
            case .folderPath: XCTAssertEqual(column.binding, 4)
            case .data: XCTAssertEqual(column.binding, 5)
            }
        }
        for column in ProjectDatabaseSchema.SessionParameter.allCases {
            switch column {
            case .id: XCTAssertEqual(column.binding, 1)
            case .projectID: XCTAssertEqual(column.binding, 2)
            case .position: XCTAssertEqual(column.binding, 3)
            case .kind: XCTAssertEqual(column.binding, 4)
            case .lastActiveAt: XCTAssertEqual(column.binding, 5)
            case .data: XCTAssertEqual(column.binding, 6)
            }
        }
        for column in ProjectDatabaseSchema.ControlGrantParameter.allCases {
            switch column {
            case .id: XCTAssertEqual(column.binding, 1)
            case .actorSessionID: XCTAssertEqual(column.binding, 2)
            case .conferredAt: XCTAssertEqual(column.binding, 3)
            case .revokedAt: XCTAssertEqual(column.binding, 4)
            case .data: XCTAssertEqual(column.binding, 5)
            }
        }
        for column in ProjectDatabaseSchema.SupervisionParameter.allCases {
            switch column {
            case .id: XCTAssertEqual(column.binding, 1)
            case .managerSessionID: XCTAssertEqual(column.binding, 2)
            case .childSessionID: XCTAssertEqual(column.binding, 3)
            case .assignedAt: XCTAssertEqual(column.binding, 4)
            case .state: XCTAssertEqual(column.binding, 5)
            case .data: XCTAssertEqual(column.binding, 6)
            }
        }
        for column in ProjectDatabaseSchema.SupervisionEventParameter.allCases {
            switch column {
            case .id: XCTAssertEqual(column.binding, 1)
            case .supervisionID: XCTAssertEqual(column.binding, 2)
            case .at: XCTAssertEqual(column.binding, 3)
            case .kind: XCTAssertEqual(column.binding, 4)
            case .data: XCTAssertEqual(column.binding, 5)
            }
        }
        for column in ProjectDatabaseSchema.SessionReadReceiptParameter.allCases {
            switch column {
            case .sessionID: XCTAssertEqual(column.binding, 1)
            case .participantID: XCTAssertEqual(column.binding, 2)
            case .generation: XCTAssertEqual(column.binding, 3)
            }
        }
    }

    /// Reads the written row back by column *name*, which the round-trip tests cannot do: they
    /// go out through the bind list and back in through the select list, so a pair of columns
    /// swapped in both directions round-trips perfectly while the store holds a project path
    /// under `name`. This is the assertion that the columns hold what they are called.
    func testStoredColumnsHoldWhatTheirNamesSay() throws {
        let database = try makeDatabase()
        var session = AgentSession(kind: .codex, title: "Chat")
        session.lastActiveAt = Date(timeIntervalSince1970: 1_700_000_000)
        let project = makeProject("alpha", sessions: [session])
        try database.save(ProjectsState(projects: [project]))

        let raw = try SQLiteDatabase(path: directory.appendingPathComponent("test.db").path)

        let sessionRow = try raw.prepare(
            "SELECT project_id, position, kind, last_active_at FROM session WHERE id = ?"
        )
        defer { sessionRow.finalize() }
        sessionRow.bind(1, session.id.uuidString)
        XCTAssertTrue(try sessionRow.step())
        XCTAssertEqual(sessionRow.text(0), project.id.uuidString)
        XCTAssertEqual(sessionRow.int(1), 0)
        XCTAssertEqual(sessionRow.text(2), "codex")
        XCTAssertEqual(sessionRow.double(3), 1_700_000_000, accuracy: 0.000_001)

        let projectRow = try raw.prepare(
            "SELECT position, name, folder_path FROM project WHERE id = ?"
        )
        defer { projectRow.finalize() }
        projectRow.bind(1, project.id.uuidString)
        XCTAssertTrue(try projectRow.step())
        XCTAssertEqual(projectRow.int(0), 0)
        XCTAssertEqual(projectRow.text(1), "alpha")
        XCTAssertEqual(projectRow.text(2), "/tmp/alpha")
    }

    // MARK: - Round Trip

    func testEmptyDatabaseIsEmpty() throws {
        let database = try makeDatabase()
        XCTAssertTrue(try database.isEmpty())
        XCTAssertTrue(try database.load().state.projects.isEmpty)
    }

    func testFailedGraphCommitKeepsTheConnectionGenerationAligned() throws {
        enum Expected: Error { case commitRefused }

        var refuseNextCommit = false
        let database = try ProjectDatabase(
            url: directory.appendingPathComponent("failed-generation-commit.db"),
            transactionCommitPreflight: {
                guard refuseNextCommit else { return }
                refuseNextCommit = false
                throw Expected.commitRefused
            }
        )
        defer { database.close() }
        _ = try database.load()

        refuseNextCommit = true
        XCTAssertThrowsError(
            try database.save(ProjectsState(projects: [makeProject("Rejected")]))
        ) { error in
            guard case Expected.commitRefused = error else {
                return XCTFail("expected the injected commit refusal, got \(error)")
            }
        }

        let accepted = makeProject("Accepted")
        try database.save(ProjectsState(projects: [accepted]))
        XCTAssertEqual(try database.load().state.projects.map(\.id), [accepted.id])
    }

    /// SQLite's *extended* result codes are defined as expressions over the primary ones —
    /// `#define SQLITE_IOERR_WRITE (SQLITE_IOERR | (3<<8))` — and Swift's clang importer brings in
    /// plain integer macros only. `SQLITE_FULL` is `13` and arrives; `SQLITE_IOERR_WRITE` does not
    /// exist in Swift at all, so naming it fails to compile rather than reading wrong. Spelled out
    /// here, once, with the header's own arithmetic.
    private enum SQLiteExtended {
        static let ioErrorWrite = SQLITE_IOERR | (3 << 8)
        static let constraintUnique = SQLITE_CONSTRAINT | (8 << 8)
    }

    func testSQLiteFullKeepsItsTypedRecoverySignal() {
        let full = SQLiteDatabase.Failure.step(.init(
            code: SQLITE_FULL,
            extendedCode: SQLITE_FULL,
            message: "database or disk is full"
        ))
        let other = SQLiteDatabase.Failure.step(.init(
            code: SQLITE_IOERR,
            extendedCode: SQLiteExtended.ioErrorWrite,
            message: "I/O error"
        ))

        XCTAssertTrue(full.isStorageExhausted)
        XCTAssertFalse(other.isStorageExhausted)
    }

    func testSQLiteConstraintKeepsItsTypedOperationRefusalSignal() {
        let constraint = SQLiteDatabase.Failure.step(.init(
            code: SQLITE_CONSTRAINT,
            extendedCode: SQLiteExtended.constraintUnique,
            message: "unique constraint failed"
        ))
        let other = SQLiteDatabase.Failure.step(.init(
            code: SQLITE_IOERR,
            extendedCode: SQLiteExtended.ioErrorWrite,
            message: "I/O error"
        ))

        XCTAssertTrue(constraint.isConstraintViolation)
        XCTAssertFalse(constraint.isStorageExhausted)
        XCTAssertFalse(other.isConstraintViolation)
    }

    func testRecoveryProbePreservesTheAuthoritativeGraphAndLeavesNoRow() throws {
        let url = directory.appendingPathComponent("recovery-probe.db")
        let database = try ProjectDatabase(url: url)
        let state = ProjectsState(
            projects: [makeProject("Kept")],
            selectedSessionID: nil
        )
        try database.save(state)

        try database.verifyIntegrityAndWritability()
        XCTAssertEqual(try database.load().state.projects.map(\.name), ["Kept"])
        database.close()

        let inspection = try SQLiteDatabase(path: url.path)
        XCTAssertEqual(
            try inspection.scalar(
                "SELECT COUNT(*) FROM app_state WHERE key = 'storageRecoveryProbe'"
            ),
            0
        )
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

    func testSingleSessionWritesDoNotRewriteStandingRows() throws {
        let url = directory.appendingPathComponent("single-session-writes.db")
        let database = try ProjectDatabase(url: url)
        let standing = AgentSession(kind: .claude, title: "Standing")
        let project = makeProject("alpha", sessions: [standing])
        try database.save(ProjectsState(projects: [project]))

        let inspection = try SQLiteDatabase(path: url.path)
        let sentinel = #"{"futureSessionFormat":true}"#
        try inspection.prepare("UPDATE session SET data = ? WHERE id = ?")
            .bind(1, sentinel)
            .bind(2, standing.id.uuidString)
            .run()

        let added = AgentSession(kind: .codex, title: "Added")
        try database.addSession(added, to: project.id, position: 1)
        var renamed = added
        renamed.title = "Renamed"
        try database.saveSession(renamed, in: project.id, position: 1)

        let standingPayload = try inspection.prepare(
            "SELECT data FROM session WHERE id = ?"
        )
        standingPayload.bind(1, standing.id.uuidString)
        defer { standingPayload.finalize() }
        XCTAssertTrue(try standingPayload.step())
        XCTAssertEqual(standingPayload.text(0), sentinel)

        let addedPayload = try inspection.prepare(
            "SELECT data FROM session WHERE id = ?"
        )
        addedPayload.bind(1, added.id.uuidString)
        defer { addedPayload.finalize() }
        XCTAssertTrue(try addedPayload.step())
        let restored = try JSONDecoder().decode(
            AgentSession.self,
            from: try XCTUnwrap(addedPayload.data(0))
        )
        XCTAssertEqual(restored.title, "Renamed")
    }

    func testBatchSessionWritesAreAtomicAndDoNotRewriteStandingRows() throws {
        enum Expected: Error { case commitRefused }

        let url = directory.appendingPathComponent("batch-session-writes.db")
        var refuseNextCommit = false
        let database = try ProjectDatabase(
            url: url,
            transactionCommitPreflight: {
                guard refuseNextCommit else { return }
                refuseNextCommit = false
                throw Expected.commitRefused
            }
        )
        let untouched = AgentSession(kind: .claude, title: "Untouched")
        var first = AgentSession(kind: .codex, title: "First")
        var second = AgentSession(kind: .claude, title: "Second")
        let project = makeProject("alpha", sessions: [untouched, first, second])
        try database.save(ProjectsState(projects: [project]))

        let inspection = try SQLiteDatabase(path: url.path)
        let sentinel = #"{"futureSessionFormat":true}"#
        try inspection.prepare("UPDATE session SET data = ? WHERE id = ?")
            .bind(1, sentinel)
            .bind(2, untouched.id.uuidString)
            .run()

        first.title = "First accepted"
        second.title = "Second accepted"
        let accepted = [
            ProjectDatabase.SessionWrite(session: first, projectID: project.id, position: 1),
            ProjectDatabase.SessionWrite(session: second, projectID: project.id, position: 2)
        ]
        try database.saveSessions(accepted)

        XCTAssertEqual(
            String(decoding: try storedSessionPayload(id: untouched.id, from: inspection), as: UTF8.self),
            sentinel
        )
        XCTAssertEqual(
            try storedSession(id: first.id, from: inspection).title,
            "First accepted"
        )
        XCTAssertEqual(
            try storedSession(id: second.id, from: inspection).title,
            "Second accepted"
        )

        first.title = "First rejected"
        second.title = "Second rejected"
        refuseNextCommit = true
        XCTAssertThrowsError(try database.saveSessions([
            ProjectDatabase.SessionWrite(session: first, projectID: project.id, position: 1),
            ProjectDatabase.SessionWrite(session: second, projectID: project.id, position: 2)
        ])) { error in
            guard case Expected.commitRefused = error else {
                return XCTFail("expected the injected commit refusal, got \(error)")
            }
        }
        XCTAssertEqual(
            try storedSession(id: first.id, from: inspection).title,
            "First accepted"
        )
        XCTAssertEqual(
            try storedSession(id: second.id, from: inspection).title,
            "Second accepted"
        )
    }

    func testSessionReadReceiptsRoundTripAndCascadeWithTheirSession() throws {
        let database = try makeDatabase()
        let session = AgentSession(kind: .claude, title: "Unread")
        let project = makeProject("alpha", sessions: [session])
        try database.save(ProjectsState(projects: [project]))

        let receipt = SessionReadReceiptState(
            sessionID: session.id,
            completionGeneration: 4,
            seenGenerationByParticipant: ["owner": 4, "anna": 2]
        )
        try database.saveSessionReadReceiptState(receipt)
        XCTAssertEqual(try database.sessionReadReceiptStates()[session.id], receipt)

        try database.save(ProjectsState(projects: [makeProject("alpha")]))
        XCTAssertTrue(try database.sessionReadReceiptStates().isEmpty)
    }

    func testTransientSessionReceiptIsAnInMemoryOnlyNoOp() throws {
        let database = try makeDatabase()
        let receipt = SessionReadReceiptState(
            sessionID: SessionID(),
            completionGeneration: 1,
            seenGenerationByParticipant: [SessionReadReceiptStore.ownerParticipantID: 1]
        )

        XCTAssertFalse(try database.saveSessionReadReceiptState(receipt))
        XCTAssertTrue(try database.sessionReadReceiptStates().isEmpty)
    }

    func testAuthorityAndSupervisionRoundTripAndCascadeWithSessions() throws {
        let database = try makeDatabase()
        let manager = AgentSession(kind: .claude, title: "Manager")
        let child = AgentSession(kind: .codex, title: "Child")
        let project = makeProject("alpha", sessions: [manager, child])
        try database.save(ProjectsState(projects: [project]))

        let grant = ControlGrant.manager(
            sessionID: manager.id,
            projectID: project.id,
            maximumPermissionMode: .manual,
            origin: .newManagerTemplate,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let supervision = Supervision(
            managerID: manager.id,
            childID: child.id,
            brief: "Run the focused tests",
            assignedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let event = SupervisionEvent(
            supervisionID: supervision.id,
            at: Date(timeIntervalSince1970: 1_700_000_200),
            kind: .settled,
            detail: "idle"
        )
        try database.saveControlGrant(grant)
        try database.saveSupervision(supervision)
        try database.saveSupervisionEvent(event)

        XCTAssertEqual(try database.controlGrants(for: manager.id), [grant])
        XCTAssertEqual(try database.supervisions(managerID: manager.id), [supervision])
        XCTAssertEqual(try database.supervisions(childID: child.id), [supervision])
        XCTAssertEqual(try database.supervisionEvents(for: supervision.id), [event])
        XCTAssertEqual(try database.allActiveManagerSessionIDs(), Set([manager.id]))

        try database.save(ProjectsState(projects: [makeProject("alpha", sessions: [child])]))
        XCTAssertEqual(try rowCount(ProjectDatabaseSchema.controlGrantTable), 0)
        XCTAssertEqual(try rowCount(ProjectDatabaseSchema.supervisionTable), 0)
        XCTAssertEqual(try rowCount(ProjectDatabaseSchema.supervisionEventTable), 0)
    }

    func testReleasedChildCanBeAdoptedAgainWithoutReplacingItsHistory() throws {
        let database = try makeDatabase()
        let manager = AgentSession(kind: .claude, title: "Manager")
        let child = AgentSession(kind: .codex, title: "Child")
        try database.save(ProjectsState(projects: [
            makeProject("alpha", sessions: [manager, child])
        ]))

        var first = Supervision(
            managerID: manager.id,
            childID: child.id,
            brief: "First tenure",
            assignedAt: Date(timeIntervalSince1970: 100)
        )
        try database.saveSupervision(first)
        let firstEvent = SupervisionEvent(
            supervisionID: first.id,
            at: Date(timeIntervalSince1970: 110),
            kind: .assigned,
            detail: first.brief
        )
        try database.saveSupervisionEvent(firstEvent)

        first.state = .released
        first.closedAt = Date(timeIntervalSince1970: 120)
        first.outcome = "First tenure complete"
        try database.saveSupervision(first)

        let second = Supervision(
            managerID: manager.id,
            childID: child.id,
            brief: "Second tenure",
            assignedAt: Date(timeIntervalSince1970: 130)
        )
        try database.saveSupervision(second)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try database.supervisions(childID: child.id), [first, second])
        XCTAssertEqual(try database.supervisionEvents(for: first.id), [firstEvent])
        XCTAssertTrue(try database.supervisionEvents(for: second.id).isEmpty)
    }

    func testOnlyOneManagerCanActivelySuperviseAChild() throws {
        let database = try makeDatabase()
        let firstManager = AgentSession(kind: .claude, title: "First manager")
        let secondManager = AgentSession(kind: .codex, title: "Second manager")
        let child = AgentSession(kind: .codex, title: "Child")
        try database.save(ProjectsState(projects: [
            makeProject("alpha", sessions: [firstManager, secondManager, child])
        ]))

        var first = Supervision(
            managerID: firstManager.id,
            childID: child.id,
            brief: "First"
        )
        let second = Supervision(
            managerID: secondManager.id,
            childID: child.id,
            brief: "Second"
        )
        try database.saveSupervision(first)

        XCTAssertThrowsError(try database.saveSupervision(second)) { error in
            guard let failure = error as? SQLiteDatabase.Failure else {
                return XCTFail("Expected a SQLite constraint refusal, got \(error)")
            }
            XCTAssertTrue(failure.isConstraintViolation)
        }

        first.state = .released
        first.closedAt = Date()
        try database.saveSupervision(first)
        XCTAssertNoThrow(try database.saveSupervision(second))
        XCTAssertEqual(try database.supervisions(childID: child.id), [first, second])
    }

    func testVersionFiveMigrationPreservesSupervisionHistoryAndEvents() throws {
        let url = directory.appendingPathComponent("version-four.db")
        let manager = AgentSession(kind: .claude, title: "Manager")
        let child = AgentSession(kind: .codex, title: "Child")
        let project = makeProject("alpha", sessions: [manager, child])
        var closed = Supervision(
            managerID: manager.id,
            childID: child.id,
            brief: "Migrated tenure",
            assignedAt: Date(timeIntervalSince1970: 100)
        )
        closed.state = .released
        closed.closedAt = Date(timeIntervalSince1970: 120)
        closed.outcome = "Done"
        let event = SupervisionEvent(
            supervisionID: closed.id,
            at: Date(timeIntervalSince1970: 120),
            kind: .released,
            detail: closed.outcome
        )

        let versionFour = try makeVersionFourDatabase(at: url)
        try insert(project: project, into: versionFour)
        try insert(supervision: closed, into: versionFour)
        try insert(event: event, into: versionFour)
        versionFour.close()

        let migrated = try ProjectDatabase(url: url)
        XCTAssertEqual(try migrated.supervisions(childID: child.id), [closed])
        XCTAssertEqual(try migrated.supervisionEvents(for: closed.id), [event])

        let readopted = Supervision(
            managerID: manager.id,
            childID: child.id,
            brief: "New tenure",
            assignedAt: Date(timeIntervalSince1970: 130)
        )
        try migrated.saveSupervision(readopted)
        XCTAssertEqual(try migrated.supervisions(childID: child.id), [closed, readopted])
        migrated.close()

        let inspection = try SQLiteDatabase(path: url.path)
        XCTAssertEqual(try inspection.scalar("PRAGMA user_version"), ProjectDatabaseSchema.version)
        XCTAssertNil(try inspection.scalar("PRAGMA foreign_key_check"))
    }

    func testConstraintRefusalDoesNotDisableUnrelatedPersistence() throws {
        let manager = StateManager(appSupportDirectory: directory)
        defer { manager.closeDatabase() }
        let firstManager = AgentSession(kind: .claude, title: "First manager")
        let secondManager = AgentSession(kind: .codex, title: "Second manager")
        let child = AgentSession(kind: .codex, title: "Child")
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [
            makeProject("alpha", sessions: [firstManager, secondManager, child])
        ])))

        XCTAssertTrue(manager.saveSupervision(Supervision(
            managerID: firstManager.id,
            childID: child.id,
            brief: "First"
        )))
        XCTAssertFalse(manager.saveSupervision(Supervision(
            managerID: secondManager.id,
            childID: child.id,
            brief: "Second"
        )))

        XCTAssertEqual(manager.persistenceHealth, .healthy)
        XCTAssertTrue(manager.saveSelectedSessionID(child.id))
        guard case .loaded(let state) = manager.loadProjectsState() else {
            return XCTFail("A constraint refusal should leave the store readable")
        }
        XCTAssertEqual(state.selectedSessionID, child.id)
    }

    func testSupervisionEventRetentionIsBoundedAndSchemaVersionIsCurrent() throws {
        let database = try makeDatabase()
        let manager = AgentSession(kind: .claude, title: "Manager")
        let child = AgentSession(kind: .codex, title: "Child")
        let project = makeProject("alpha", sessions: [manager, child])
        try database.save(ProjectsState(projects: [project]))
        let supervision = Supervision(managerID: manager.id, childID: child.id, brief: "Brief")
        try database.saveSupervision(supervision)

        for index in 0..<(SupervisionDefaults.maximumEvents + 12) {
            try database.saveSupervisionEvent(SupervisionEvent(
                supervisionID: supervision.id,
                at: Date(timeIntervalSince1970: TimeInterval(index)),
                kind: .reportReceived,
                detail: "event \(index)"
            ))
        }
        let retained = try database.supervisionEvents(for: supervision.id)
        XCTAssertEqual(retained.count, SupervisionDefaults.maximumEvents)
        XCTAssertEqual(retained.first?.detail, "event 12")
        XCTAssertEqual(retained.last?.detail, "event \(SupervisionDefaults.maximumEvents + 11)")

        database.close()
        let sqlite = try SQLiteDatabase(path: directory.appendingPathComponent("test.db").path)
        XCTAssertEqual(try sqlite.scalar("PRAGMA user_version"), ProjectDatabaseSchema.version)
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

    func testOneSessionCanBeRemovedWithoutRewritingTheGraph() throws {
        let database = try makeDatabase()
        let first = AgentSession(kind: .claude, title: "First")
        let removed = AgentSession(kind: .codex, title: "Removed")
        let last = AgentSession(kind: .claude, title: "Last")
        let untouched = AgentSession(kind: .codex, title: "Untouched")
        let firstProject = makeProject("alpha", sessions: [first, removed, last])
        let secondProject = makeProject("beta", sessions: [untouched])
        try database.save(ProjectsState(
            projects: [firstProject, secondProject],
            selectedSessionID: removed.id
        ))

        try database.removeSession(
            id: removed.id,
            from: firstProject.id,
            at: 1,
            selectedSessionID: nil
        )

        let restored = try database.load().state
        XCTAssertEqual(restored.projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(restored.projects[0].sessions.map(\.id), [first.id, last.id])
        XCTAssertEqual(restored.projects[1].sessions.map(\.id), [untouched.id])
        XCTAssertNil(restored.selectedSessionID)
    }

    func testOneSessionsAuxiliaryRowsCanBeDeletedWithoutPruningTheTables() throws {
        let database = try makeDatabase()
        let removed = SessionID()
        let kept = SessionID()
        for sessionID in [removed, kept] {
            try database.savePanelPayload("panel-\(sessionID.uuidString)", for: sessionID)
            try database.saveAttachmentsPayload(
                "attachments-\(sessionID.uuidString)",
                for: sessionID
            )
        }

        try database.deletePanel(for: removed)
        try database.deleteAttachments(for: removed)

        XCTAssertNil(try database.panelPayload(for: removed))
        XCTAssertNil(try database.attachmentsPayload(for: removed))
        XCTAssertNotNil(try database.panelPayload(for: kept))
        XCTAssertNotNil(try database.attachmentsPayload(for: kept))
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

    func testValidJSONSessionDecodeFailureStillNamesTheExactRow() throws {
        let database = try makeDatabase()
        let first = AgentSession(kind: .claude, title: "First")
        let malformed = AgentSession(kind: .codex, title: "Malformed")
        try database.save(ProjectsState(projects: [
            makeProject("alpha", sessions: [first, malformed])
        ]))

        let payload = try XCTUnwrap(rawSessionPayload(id: malformed.id))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        object["title"] = 17
        try updatePayload(
            table: "session",
            id: malformed.id.uuidString,
            payload: String(
                decoding: try JSONSerialization.data(withJSONObject: object),
                as: UTF8.self
            )
        )

        XCTAssertThrowsError(try database.load().state) { error in
            guard let loadError = error as? ProjectDatabaseLoadError,
                  case .corruptRow(let table, let id, _) = loadError else {
                return XCTFail("Expected a corrupt-row error, got \(error)")
            }
            XCTAssertEqual(table, "session")
            XCTAssertEqual(id, malformed.id.uuidString)
        }
    }

    func testSessionOrderSurvivesDecodeBatchAndWaveBoundaries() throws {
        let database = try makeDatabase()
        let sessions = (0..<1_100).map {
            AgentSession(kind: .claude, title: "Session \($0)")
        }
        try database.save(ProjectsState(projects: [
            makeProject("alpha", sessions: sessions)
        ]))

        let restored = try XCTUnwrap(try database.load().state.projects.first)
        XCTAssertEqual(restored.sessions.map(\.id), sessions.map(\.id))
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
    func testMalformedPanelDoesNotEnterTheAuthoritativeStartupDecode() throws {
        let database = try makeDatabase()
        let sessionID = SessionID()
        try database.save(ProjectsState(projects: [makeProject("alpha")]))
        try database.savePanelPayload("{", for: sessionID)

        let load = try database.load()

        XCTAssertEqual(load.state.projects.map(\.name), ["alpha"])
        XCTAssertTrue(
            load.unreadable.panelLayouts.sessions.isEmpty,
            "payload validity belongs to the first feature access, not project-graph startup"
        )
        XCTAssertFalse(load.unreadable.panelLayouts.containsUnkeyedRows)
        XCTAssertTrue(load.unreadable.sessionAttachments.isEmpty)
        XCTAssertEqual(
            try rowCount("panel_layout"),
            1,
            "naming a row unreadable must not be a way of deleting it"
        )
    }

    /// The real shape of the failure: not damage, but a document from a build that knows more.
    func testFutureAttachmentDocumentDoesNotEnterTheAuthoritativeStartupDecode() throws {
        let database = try makeDatabase()
        let sessionID = SessionID()
        try database.save(ProjectsState(projects: [makeProject("alpha")]))
        try database.saveAttachmentsPayload(
            #"{"formatVersion":99,"entries":[]}"#,
            for: sessionID
        )

        let load = try database.load()

        XCTAssertEqual(load.state.projects.map(\.name), ["alpha"])
        XCTAssertTrue(
            load.unreadable.sessionAttachments.sessions.isEmpty,
            "payload validity belongs to the first feature access, not project-graph startup"
        )
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
        var session = AgentSession(kind: .claude, title: "Chat", accountHandle: .named("claudenh"), model: "opus")
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

    /// Sound overrides on all three record kinds, including a key naming an event this build
    /// has never heard of.
    ///
    /// That last part is the point. The field is `[String: String]` rather than a typed
    /// dictionary precisely so a record written by a **later** build survives being read and
    /// written by this one; a round trip through `[SoundEvent: SoundChoice]` would delete
    /// exactly the entries the constraint exists to keep, and it would do it silently.
    func testSoundOverridesSurviveThePayloadIncludingUnknownEvents() throws {
        let database = try makeDatabase()
        var session = AgentSession(kind: .claude, title: "Chat")
        session.soundOverrides = [
            "all": "file:Purr.aiff",
            "bell": "silent",
            "bell.launch": "file:Tink.aiff",
            "alert.somethingLater": "file:Hero.aiff"
        ]
        var terminal = ProjectTerminal(currentDirectory: "/tmp/alpha")
        terminal.soundOverrides = ["all": "system"]

        var project = makeProject("alpha", sessions: [session])
        project.terminals = [terminal]
        project.soundOverrides = ["alert": "file:Submarine.aiff", "all": "silent"]

        try database.save(ProjectsState(projects: [project]))
        let restoredProject = try XCTUnwrap(try database.load().state.projects.first)

        XCTAssertEqual(restoredProject.soundOverrides, project.soundOverrides)
        XCTAssertEqual(restoredProject.sessions.first?.soundOverrides, session.soundOverrides)
        XCTAssertEqual(restoredProject.terminals.first?.soundOverrides, terminal.soundOverrides)
    }

    /// Absent is the common case and stays absent: nothing seeds an empty map, so a record that
    /// has never chosen a sound is indistinguishable from one written before the field existed.
    func testAbsentSoundOverridesStayAbsent() throws {
        let database = try makeDatabase()
        var project = makeProject("alpha", sessions: [AgentSession(kind: .codex, title: "Chat")])
        project.terminals = [ProjectTerminal(currentDirectory: "/tmp/alpha")]

        try database.save(ProjectsState(projects: [project]))
        let restored = try XCTUnwrap(try database.load().state.projects.first)

        XCTAssertNil(restored.soundOverrides)
        XCTAssertNil(restored.sessions.first?.soundOverrides)
        XCTAssertNil(restored.terminals.first?.soundOverrides)
        XCTAssertFalse(
            try XCTUnwrap(rawProjectPayload(id: project.id)).contains("soundOverrides"),
            "an absent field is absent from the payload, not an empty object in it"
        )
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

    private func makeVersionFourDatabase(at url: URL) throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: url.path)
        try database.migrate(to: 4) { version in
            switch version {
            case 1: try database.execute(ProjectDatabaseSchema.version1)
            case 2: try database.execute(ProjectDatabaseSchema.version2)
            case 3: try database.execute(ProjectDatabaseSchema.version3)
            case 4: try database.execute(ProjectDatabaseSchema.version4)
            default:
                throw SQLiteDatabase.Failure.syntheticStep(
                    "Unexpected historical schema version \(version)"
                )
            }
        }
        return database
    }

    private func insert(project: Project, into database: SQLiteDatabase) throws {
        var payload = project
        payload.sessions = []
        typealias Column = ProjectDatabaseSchema.ProjectParameter
        try database.prepare(ProjectDatabaseSchema.upsertProject)
            .bind(Column.id.binding, project.id.uuidString)
            .bind(Column.position.binding, 0)
            .bind(Column.name.binding, project.name)
            .bind(Column.folderPath.binding, project.folderPath)
            .bind(Column.data.binding, try encoded(payload))
            .run()

        for (position, session) in project.sessions.enumerated() {
            typealias Column = ProjectDatabaseSchema.SessionParameter
            try database.prepare(ProjectDatabaseSchema.upsertSession)
                .bind(Column.id.binding, session.id.uuidString)
                .bind(Column.projectID.binding, project.id.uuidString)
                .bind(Column.position.binding, position)
                .bind(Column.kind.binding, session.kind.rawValue)
                .bind(Column.lastActiveAt.binding, session.lastActiveAt.timeIntervalSince1970)
                .bind(Column.data.binding, try encoded(session))
                .run()
        }
    }

    private func insert(supervision: Supervision, into database: SQLiteDatabase) throws {
        typealias Column = ProjectDatabaseSchema.SupervisionParameter
        try database.prepare(ProjectDatabaseSchema.upsertSupervision)
            .bind(Column.id.binding, supervision.id.uuidString)
            .bind(Column.managerSessionID.binding, supervision.managerID.uuidString)
            .bind(Column.childSessionID.binding, supervision.childID.uuidString)
            .bind(Column.assignedAt.binding, supervision.assignedAt.timeIntervalSince1970)
            .bind(Column.state.binding, supervision.state.rawValue)
            .bind(Column.data.binding, try encoded(supervision))
            .run()
    }

    private func insert(event: SupervisionEvent, into database: SQLiteDatabase) throws {
        typealias Column = ProjectDatabaseSchema.SupervisionEventParameter
        try database.prepare(ProjectDatabaseSchema.insertSupervisionEvent)
            .bind(Column.id.binding, event.id.uuidString.lowercased())
            .bind(Column.supervisionID.binding, event.supervisionID.uuidString)
            .bind(Column.at.binding, event.at.timeIntervalSince1970)
            .bind(Column.kind.binding, event.kind.rawValue)
            .bind(Column.data.binding, try encoded(event))
            .run()
    }

    private func encoded<Value: Encodable>(_ value: Value) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

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

    private func rawSessionPayload(id: SessionID) throws -> String? {
        let database = try SQLiteDatabase(path: directory.appendingPathComponent("test.db").path)
        let statement = try database.prepare("SELECT data FROM session WHERE id = ?")
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
