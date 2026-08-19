import Foundation

/// A row exists, but it cannot be trusted as an authoritative model record.
///
/// Loading the project graph is deliberately all-or-nothing. Returning a partial graph would
/// make the next whole-state save delete every row that was skipped while decoding it.
///
/// The auxiliary tables are *not* part of that contract — see `UnreadableRows`.
enum ProjectDatabaseLoadError: LocalizedError {
    case corruptRow(table: String, id: String?, reason: String)

    var errorDescription: String? {
        switch self {
        case .corruptRow(let table, let id, let reason):
            let identity = id.map { " '\($0)'" } ?? ""
            return "Corrupt \(table) row\(identity): \(reason)"
        }
    }
}

/// A whole-graph write was refused because the store changed underneath the writer.
///
/// `save(_:)` reconciles: it deletes every project and session the state it was handed does not
/// mention. That is correct for the single writer `SingleInstanceLock` promises, and catastrophic
/// for a second one — its stale snapshot deletes rows it never knew existed, and `ON DELETE
/// CASCADE` takes each project's chats with it. A hosted XCTest bundle was exactly that second
/// writer, because it runs inside the shipping app and never reaches the lock.
///
/// The redirect in `StateManager` removes that writer. This is the backstop for the next one:
/// reconciliation now proves it is working from the generation it last read, and refuses rather
/// than prunes when it is not. Refusing costs one unsaved edit; pruning costs projects.
enum ProjectDatabaseWriteError: LocalizedError {
    case staleGeneration(observed: Int, found: Int)

    var errorDescription: String? {
        switch self {
        case .staleGeneration(let observed, let found):
            return "Refused a whole-graph write: the store moved from generation "
                + "\(observed) to \(found) beneath this writer"
        }
    }
}

/// The rows of one auxiliary table this build could not read.
///
/// A panel layout or attachment list that does not decode is not the same failure as a session
/// row that does not decode, and treating it as one cost a user every project and chat they had:
/// one `panel_layout` row written by a build one format version ahead failed the authoritative
/// load, and a failed load quarantines the database. The panel is a pane that rebuilds itself
/// from nothing; the session is a chat with no other copy.
///
/// So an unreadable auxiliary row is reported rather than thrown, and what the all-or-nothing
/// rule was protecting is protected one row at a time instead: `StateManager` validates a row
/// when its feature first asks for it, tells the feature it is absent on failure, and refuses to
/// write over it for the rest of the launch. A newer build, or a build with the fix for whatever
/// produced it, still reads it. Startup still records structurally unkeyed rows eagerly because
/// no feature can ever ask for one of those by id and only skipping prune can preserve it.
struct UnreadableRows {

    /// Sessions whose stored payload did not decode.
    var sessions: Set<SessionID> = []

    /// Whether a row's `session_id` is not a session identifier at all.
    ///
    /// Tracked separately because no feature can ask for such a row by id, so refusing writes to
    /// it protects nothing — only leaving the table unpruned does.
    var containsUnkeyedRows = false

    var isEmpty: Bool { sessions.isEmpty && !containsUnkeyedRows }
}

/// Every auxiliary row a load could not read, by the table it came from.
struct UnreadableAuxiliaryRows {
    var panelLayouts = UnreadableRows()
    var sessionAttachments = UnreadableRows()

    var isEmpty: Bool { panelLayouts.isEmpty && sessionAttachments.isEmpty }
}

/// A successful load: the authoritative project graph, plus auxiliary rows startup must protect.
///
/// Payload decoding is deliberately lazy: panels and attachments are not launch-critical, and
/// decoding all of them delayed every launch even when no pane asked for them. Structurally
/// unkeyed rows are returned with the state because no later feature read can discover them.
struct ProjectsStateLoad {
    let state: ProjectsState
    let unreadable: UnreadableAuxiliaryRows
}

/// The projects and sessions store, in SQLite.
///
/// **Thin rows, JSON payloads** — opencode's own shape, and taken for a practical reason as
/// much as a principled one: the columns are what needs ordering, filtering or a foreign key,
/// while everything else rides in `data` as the model's own `Codable` encoding. A field added
/// to `AgentSession` therefore costs no migration, which matters in a model that is still
/// growing side chats, archiving and typed identifiers.
///
/// A project's payload is stored with its `sessions` **emptied**, because sessions are rows;
/// `load` fills them back in. Encoding the model rather than a parallel DTO is what keeps the
/// two from drifting.
///
/// Writes are per row and transactional. That is the actual gain over `projects.json`: the
/// store stops being rewritten in full every time an agent renames a terminal tab, and a write
/// interrupted halfway leaves the previous state rather than a truncated document.
final class ProjectDatabase {

    // MARK: - Properties

    private let database: SQLiteDatabase

    /// The store generation this connection last read or wrote.
    ///
    /// `nil` until the graph has been read once. A connection that has never loaded cannot have a
    /// stale picture of the graph, so it adopts whatever it finds rather than refusing — that is
    /// the legacy-import and first-write path, not the hazard.
    private var observedGeneration: Int?

    // MARK: - Initialization

    init(url: URL) throws {
        database = try SQLiteDatabase(
            path: url.path,
            maximumSchemaVersion: ProjectDatabaseSchema.version
        )
        try migrate()
    }

    /// Ends this owner's native connection deterministically. The process store normally keeps
    /// it for the launch; app-data moves and temporary stores must close it before moving or
    /// unlinking the database and its WAL sidecars.
    func close() {
        database.close()
    }

    /// Checkpoints WAL and obtains SQLite's own journal-mode transition before a filesystem move.
    /// A false result means another connection still owns part of the database bundle.
    func prepareForFileMove() -> Bool {
        database.prepareForFileMove()
    }

    // MARK: - Schema

    private func migrate() throws {
        try database.migrate(to: ProjectDatabaseSchema.version) { version in
            switch version {
            case 1:
                try database.execute(ProjectDatabaseSchema.version1)
            case 2:
                try database.execute(ProjectDatabaseSchema.version2)
            case 3:
                try database.execute(ProjectDatabaseSchema.version3)
            case 4:
                try database.execute(ProjectDatabaseSchema.version4)
            case 5:
                try database.execute(ProjectDatabaseSchema.version5)
            case 6:
                try database.execute(ProjectDatabaseSchema.version6)
            default:
                // Unreachable while `version` and the cases here are edited together, which is
                // the point of failing loudly rather than silently skipping a step.
                throw SQLiteDatabase.Failure.syntheticStep(
                    "No migration to schema version \(version)"
                )
            }
        }
    }

    // MARK: - Public Methods

    /// Whether anything has been stored yet — the question that decides whether a legacy
    /// `projects.json` should be imported.
    func isEmpty() throws -> Bool {
        try database.scalar("SELECT COUNT(*) FROM project") == 0
    }

    /// Proves that the store is both readable and writable after a recoverable storage failure.
    ///
    /// Reopening alone is not proof: SQLite can open a database while the volume is still full,
    /// and clearing the in-process refusal on that evidence would merely make the next user
    /// action fail again. `quick_check` validates the pages we are about to trust; the
    /// insert-and-delete transaction makes SQLite create and commit real WAL frames without
    /// leaving recovery data behind.
    func verifyIntegrityAndWritability() throws {
        do {
            let check = try database.prepare("PRAGMA quick_check")
            defer { check.finalize() }
            guard try check.step(), check.text(0)?.lowercased() == "ok" else {
                throw SQLiteDatabase.Failure.syntheticStep(
                    "SQLite quick_check did not report a healthy store"
                )
            }
        }

        let probeKey = ProjectDatabaseSchema.storageRecoveryProbeKey
        try database.transaction {
            let write = try database.prepare(ProjectDatabaseSchema.upsertAppState)
            try write
                .bind(1, probeKey)
                .bind(2, UUID().uuidString)
                .run()

            let remove = try database.prepare("DELETE FROM app_state WHERE key = ?")
            try remove.bind(1, probeKey).run()
        }
    }

    func load() throws -> ProjectsStateLoad {
        var projects: [Project] = []
        var sessionsByProject: [ProjectID: [AgentSession]] = [:]
        var pendingSessionRows: [StoredSessionRow] = []
        pendingSessionRows.reserveCapacity(Self.sessionDecodeWaveSize)

        let sessions = try database.prepare(
            """
            SELECT id, project_id, kind, last_active_at, data
            FROM session
            ORDER BY project_id, position
            """
        )
        defer { sessions.finalize() }
        while try sessions.step() {
            let rawID = sessions.text(0)
            guard let rawID, let rowID = SessionID(uuidString: rawID) else {
                throw corruptRow("session", id: rawID, reason: "invalid row identifier")
            }
            guard let rawProjectID = sessions.text(1),
                  let projectID = ProjectID(uuidString: rawProjectID) else {
                throw corruptRow(
                    "session",
                    id: rawID,
                    reason: "invalid project identifier '\(sessions.text(1) ?? "NULL")'"
                )
            }
            guard let storedKind = sessions.text(2) else {
                throw corruptRow("session", id: rawID, reason: "missing indexed provider kind")
            }
            let storedLastActiveAt = sessions.double(3)
            guard let payload = sessions.data(4) else {
                throw corruptRow("session", id: rawID, reason: "missing JSON payload")
            }

            pendingSessionRows.append(StoredSessionRow(
                rawID: rawID,
                rowID: rowID,
                projectID: projectID,
                storedKind: storedKind,
                storedLastActiveAt: storedLastActiveAt,
                payload: payload
            ))
            if pendingSessionRows.count == Self.sessionDecodeWaveSize {
                try appendDecodedSessions(
                    pendingSessionRows,
                    to: &sessionsByProject
                )
                pendingSessionRows.removeAll(keepingCapacity: true)
            }
        }
        try appendDecodedSessions(pendingSessionRows, to: &sessionsByProject)

        let rows = try database.prepare(
            "SELECT id, name, folder_path, data FROM project ORDER BY position"
        )
        defer { rows.finalize() }
        var loadedProjectIDs: Set<ProjectID> = []
        while try rows.step() {
            let rawID = rows.text(0)
            guard let rawID, let id = ProjectID(uuidString: rawID) else {
                throw corruptRow("project", id: rawID, reason: "invalid row identifier")
            }
            guard let storedName = rows.text(1) else {
                throw corruptRow("project", id: rawID, reason: "missing indexed name")
            }
            guard let storedPath = rows.text(2) else {
                throw corruptRow("project", id: rawID, reason: "missing indexed path")
            }
            guard let payload = rows.data(3) else {
                throw corruptRow("project", id: rawID, reason: "missing JSON payload")
            }

            var project: Project
            do {
                project = try Self.decoder.decode(Project.self, from: payload)
            } catch {
                throw corruptRow(
                    "project",
                    id: rawID,
                    reason: "invalid JSON payload: \(error.localizedDescription)"
                )
            }
            guard project.id == id else {
                throw corruptRow(
                    "project",
                    id: rawID,
                    reason: "payload identifier is '\(project.id.uuidString)'"
                )
            }
            guard project.name == storedName else {
                throw corruptRow(
                    "project",
                    id: rawID,
                    reason: "indexed name disagrees with payload"
                )
            }
            guard project.folderPath == storedPath else {
                throw corruptRow(
                    "project",
                    id: rawID,
                    reason: "indexed path disagrees with payload"
                )
            }
            guard project.sessions.isEmpty else {
                throw corruptRow(
                    "project",
                    id: rawID,
                    reason: "payload duplicates session rows"
                )
            }
            project.sessions = sessionsByProject[id] ?? []
            projects.append(project)
            loadedProjectIDs.insert(id)
        }

        if let orphanedProjectID = sessionsByProject.keys.first(where: {
            !loadedProjectIDs.contains($0)
        }) {
            throw corruptRow(
                "session",
                id: nil,
                reason: "references missing project '\(orphanedProjectID.uuidString)'"
            )
        }

        // Read *after* the rows, so the generation this connection claims to hold can never be
        // newer than the graph it actually read.
        observedGeneration = try storeGeneration()

        return ProjectsStateLoad(
            state: ProjectsState(
                projects: projects,
                selectedSessionID: try selectedSessionID(),
                savedAt: Date()
            ),
            unreadable: UnreadableAuxiliaryRows(
                panelLayouts: try structurallyUnreadableRows(
                    in: ProjectDatabaseSchema.panelTable
                ),
                sessionAttachments: try structurallyUnreadableRows(
                    in: ProjectDatabaseSchema.attachmentsTable
                )
            )
        )
    }

    /// Brings the stored rows in line with the state, in one transaction: upsert what is there,
    /// delete what has gone. Not a truncate-and-rewrite — that would be the JSON document with
    /// extra steps, and would churn the write-ahead log for a renamed tab.
    func save(_ state: ProjectsState) throws {
        try database.transaction {
            // Inside the transaction, so the check and the reconcile it authorises cannot be
            // separated by another writer's commit.
            let found = try storeGeneration()
            if let observedGeneration, observedGeneration != found {
                throw ProjectDatabaseWriteError.staleGeneration(
                    observed: observedGeneration,
                    found: found
                )
            }

            var liveProjects: Set<String> = []
            var liveSessions: Set<String> = []

            for (index, project) in state.projects.enumerated() {
                liveProjects.insert(project.id.uuidString)
                try upsert(project, position: index)

                for (order, session) in project.sessions.enumerated() {
                    liveSessions.insert(session.id.uuidString)
                    try upsert(session, in: project.id, position: order)
                }
            }

            try deleteRows(in: "session", keeping: liveSessions)
            try deleteRows(in: "project", keeping: liveProjects)
            try setSelectedSessionID(state.selectedSessionID)
            try advanceGeneration(from: found)
        }
    }

    /// Persists one project row without walking the sessions beneath it.
    ///
    /// Expansion is project-owned UI state. Re-encoding and upserting every session merely
    /// because one disclosure triangle moved made the gesture scale with the complete sidebar.
    func saveProject(_ project: Project, position: Int) throws {
        try upsert(project, position: position)
    }

    /// Persists only window navigation state.
    ///
    /// A sidebar selection changes one value, not the project graph. Routing it through
    /// `save(_:)` needlessly re-encoded and upserted every project and session on the main
    /// thread, making a click cost grow with the size of the sidebar.
    func saveSelectedSessionID(_ id: SessionID?) throws {
        try setSelectedSessionID(id)
    }

    /// Deletes one session without re-encoding every other row in the project graph.
    ///
    /// The row order and selected id are part of the same transaction as the deletion. A
    /// selected session therefore cannot reappear after relaunch because its scalar selection
    /// cleared while its graph row did not (or the reverse), and later siblings retain the
    /// contiguous positions produced by a complete `save(_:)`.
    func removeSession(
        id sessionID: SessionID,
        from projectID: ProjectID,
        at position: Int,
        selectedSessionID: SessionID?
    ) throws {
        try database.transaction {
            try database.prepare("DELETE FROM session WHERE id = ? AND project_id = ?")
                .bind(1, sessionID.uuidString)
                .bind(2, projectID.uuidString)
                .run()
            try database.prepare(
                "UPDATE session SET position = position - 1 "
                    + "WHERE project_id = ? AND position > ?"
            )
                .bind(1, projectID.uuidString)
                .bind(2, position)
                .run()
            try setSelectedSessionID(selectedSessionID)
            // Membership changed, so a whole-graph writer holding the older picture must be
            // refused rather than allowed to resurrect this row.
            try advanceGeneration(from: try storeGeneration())
        }
    }

    /// The sessions that held a live agent when the app last quit, for startup to relaunch.
    ///
    /// Read leniently rather than through `corruptRow`: this is derived navigation state whose
    /// worst failure is a session not coming back, and quarantining the whole store over it
    /// would trade every project for a convenience.
    func runningSessionIDs() throws -> [SessionID] {
        let statement = try database.prepare("SELECT value FROM app_state WHERE key = ?")
        defer { statement.finalize() }
        statement.bind(1, ProjectDatabaseSchema.runningSessionsKey)

        guard try statement.step(), let raw = statement.text(0) else { return [] }
        return raw.split(separator: " ").compactMap { SessionID(uuidString: String($0)) }
    }

    func saveRunningSessionIDs(_ ids: [SessionID]) throws {
        guard !ids.isEmpty else {
            let statement = try database.prepare("DELETE FROM app_state WHERE key = ?")
            statement.bind(1, ProjectDatabaseSchema.runningSessionsKey)
            try statement.run()
            return
        }

        try database.prepare(ProjectDatabaseSchema.upsertAppState)
            .bind(1, ProjectDatabaseSchema.runningSessionsKey)
            .bind(2, ids.map(\.uuidString).joined(separator: " "))
            .run()
    }

    // MARK: - Public Methods — Panel Layouts

    /// The display panel's tabs for a session, as its own `Codable` payload.
    ///
    /// Deliberately *not* foreign-keyed to `session`: a panel is written by the pane and the
    /// session by the store, on their own schedules, and a constraint between them would make
    /// whichever wrote first fail. `retainPanels` prunes instead, which is what the file layout
    /// did too.
    func panelPayload(for sessionID: SessionID) throws -> String? {
        let statement = try database.prepare("SELECT data FROM \(ProjectDatabaseSchema.panelTable) WHERE session_id = ?")
        defer { statement.finalize() }
        statement.bind(1, sessionID.uuidString)
        return try statement.step() ? statement.text(0) : nil
    }

    func savePanelPayload(_ payload: String, for sessionID: SessionID) throws {
        try database.prepare(ProjectDatabaseSchema.upsertPanel)
            .bind(1, sessionID.uuidString)
            .bind(2, payload)
            .run()
    }

    func deletePanel(for sessionID: SessionID) throws {
        let statement = try database.prepare("DELETE FROM \(ProjectDatabaseSchema.panelTable) WHERE session_id = ?")
        statement.bind(1, sessionID.uuidString)
        try statement.run()
    }

    func retainPanels(sessionIDs: Set<SessionID>) throws {
        try deleteRows(
            in: ProjectDatabaseSchema.panelTable,
            column: "session_id",
            keeping: Set(sessionIDs.map(\.uuidString))
        )
    }

    // MARK: - Public Methods — Session Attachments

    /// The attachment references a session has surfaced, as one `Codable` payload per session —
    /// the same shape as the panel's row, and unconstrained against `session` for the same
    /// reason: the two are written on their own schedules, and `retainAttachments` prunes.
    func attachmentsPayload(for sessionID: SessionID) throws -> String? {
        let statement = try database.prepare(
            "SELECT data FROM \(ProjectDatabaseSchema.attachmentsTable) WHERE session_id = ?"
        )
        defer { statement.finalize() }
        statement.bind(1, sessionID.uuidString)
        return try statement.step() ? statement.text(0) : nil
    }

    func saveAttachmentsPayload(_ payload: String, for sessionID: SessionID) throws {
        try database.prepare(ProjectDatabaseSchema.upsertAttachments)
            .bind(1, sessionID.uuidString)
            .bind(2, payload)
            .run()
    }

    func deleteAttachments(for sessionID: SessionID) throws {
        let statement = try database.prepare(
            "DELETE FROM \(ProjectDatabaseSchema.attachmentsTable) WHERE session_id = ?"
        )
        statement.bind(1, sessionID.uuidString)
        try statement.run()
    }

    func retainAttachments(sessionIDs: Set<SessionID>) throws {
        try deleteRows(
            in: ProjectDatabaseSchema.attachmentsTable,
            column: "session_id",
            keeping: Set(sessionIDs.map(\.uuidString))
        )
    }

    // MARK: - Public Methods — Control Authority

    /// Every durable grant for an actor, including revoked rows so the audit trail survives.
    func controlGrants(for sessionID: SessionID) throws -> [ControlGrant] {
        let statement = try database.prepare(
            "SELECT data FROM \(ProjectDatabaseSchema.controlGrantTable) "
                + "WHERE actor_session_id = ? ORDER BY conferred_at"
        )
        defer { statement.finalize() }
        statement.bind(1, sessionID.uuidString)

        var grants: [ControlGrant] = []
        while try statement.step() {
            guard let payload = statement.text(0) else {
                throw corruptRow(
                    ProjectDatabaseSchema.controlGrantTable,
                    id: sessionID.uuidString,
                    reason: "missing grant payload"
                )
            }
            do {
                grants.append(try Self.decoder.decode(ControlGrant.self, from: Data(payload.utf8)))
            } catch {
                throw corruptRow(
                    ProjectDatabaseSchema.controlGrantTable,
                    id: sessionID.uuidString,
                    reason: "invalid JSON payload: \(error.localizedDescription)"
                )
            }
        }
        return grants
    }

    func saveControlGrant(_ grant: ControlGrant) throws {
        guard case .agentSession(let actorSessionID) = grant.actor else {
            throw SQLiteDatabase.Failure.syntheticStep(
                "Only session actors can be stored by this schema version"
            )
        }
        try database.prepare(ProjectDatabaseSchema.upsertControlGrant)
            .bind(1, grant.id.uuidString)
            .bind(2, actorSessionID.uuidString)
            .bind(3, grant.conferredAt.timeIntervalSince1970)
            .bind(4, grant.revokedAt?.timeIntervalSince1970)
            .bind(5, try Self.encodeValidated(grant))
            .run()
    }

    func allActiveManagerSessionIDs() throws -> Set<SessionID> {
        let statement = try database.prepare(
            "SELECT DISTINCT actor_session_id FROM \(ProjectDatabaseSchema.controlGrantTable) "
                + "WHERE revoked_at IS NULL"
        )
        defer { statement.finalize() }
        var result: Set<SessionID> = []
        while try statement.step() {
            if let raw = statement.text(0), let id = SessionID(uuidString: raw) {
                result.insert(id)
            }
        }
        return result
    }

    // MARK: - Public Methods — Supervision

    func supervisions(managerID: SessionID? = nil, childID: SessionID? = nil) throws -> [Supervision] {
        var clauses: [String] = []
        if managerID != nil { clauses.append("manager_session_id = ?") }
        if childID != nil { clauses.append("child_session_id = ?") }
        let suffix = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let statement = try database.prepare(
            "SELECT data FROM \(ProjectDatabaseSchema.supervisionTable)"
                + suffix + " ORDER BY assigned_at"
        )
        defer { statement.finalize() }
        var binding: Int32 = 1
        if let managerID {
            statement.bind(binding, managerID.uuidString)
            binding += 1
        }
        if let childID {
            statement.bind(binding, childID.uuidString)
        }

        var result: [Supervision] = []
        while try statement.step() {
            guard let payload = statement.text(0) else { continue }
            do {
                result.append(try Self.decoder.decode(Supervision.self, from: Data(payload.utf8)))
            } catch {
                throw corruptRow(
                    ProjectDatabaseSchema.supervisionTable,
                    id: nil,
                    reason: "invalid JSON payload: \(error.localizedDescription)"
                )
            }
        }
        return result
    }

    func saveSupervision(_ supervision: Supervision) throws {
        try database.prepare(ProjectDatabaseSchema.upsertSupervision)
            .bind(1, supervision.id.uuidString)
            .bind(2, supervision.managerID.uuidString)
            .bind(3, supervision.childID.uuidString)
            .bind(4, supervision.assignedAt.timeIntervalSince1970)
            .bind(5, supervision.state.rawValue)
            .bind(6, try Self.encodeValidated(supervision))
            .run()
    }

    func supervisionEvents(for supervisionID: SupervisionID) throws -> [SupervisionEvent] {
        let statement = try database.prepare(
            "SELECT data FROM \(ProjectDatabaseSchema.supervisionEventTable) "
                + "WHERE supervision_id = ? ORDER BY at"
        )
        defer { statement.finalize() }
        statement.bind(1, supervisionID.uuidString)
        var result: [SupervisionEvent] = []
        while try statement.step() {
            guard let payload = statement.text(0) else { continue }
            do {
                result.append(try Self.decoder.decode(SupervisionEvent.self, from: Data(payload.utf8)))
            } catch {
                throw corruptRow(
                    ProjectDatabaseSchema.supervisionEventTable,
                    id: nil,
                    reason: "invalid JSON payload: \(error.localizedDescription)"
                )
            }
        }
        return result
    }

    /// Appends one event and prunes older rows in the same transaction. The durable drop marker
    /// is inserted by `ControlGrantStore` before this call when the cap is crossed.
    func saveSupervisionEvent(_ event: SupervisionEvent) throws {
        try database.transaction {
            try database.prepare(ProjectDatabaseSchema.insertSupervisionEvent)
                .bind(1, event.id.uuidString.lowercased())
                .bind(2, event.supervisionID.uuidString)
                .bind(3, event.at.timeIntervalSince1970)
                .bind(4, event.kind.rawValue)
                .bind(5, try Self.encodeValidated(event))
                .run()
            try database.prepare(ProjectDatabaseSchema.pruneSupervisionEvents)
                .bind(1, event.supervisionID.uuidString)
                .bind(2, event.supervisionID.uuidString)
                .bind(3, SupervisionDefaults.maximumEvents)
                .run()
        }
    }

    // MARK: - Public Methods — Session Read Receipts

    /// Loads the complete auxiliary receipt ledger in one pass. This is lazy at the feature
    /// boundary (`SessionReadReceiptStore`), so launch does not pay for it unless activity is
    /// projected, and subsequent list rows are dictionary lookups rather than one query each.
    func sessionReadReceiptStates() throws -> [SessionID: SessionReadReceiptState] {
        let statement = try database.prepare(
            """
            SELECT attention.session_id, attention.generation,
                   receipt.participant_id, receipt.generation
            FROM \(ProjectDatabaseSchema.sessionAttentionTable) AS attention
            LEFT JOIN \(ProjectDatabaseSchema.sessionReadReceiptTable) AS receipt
              ON receipt.session_id = attention.session_id
            ORDER BY attention.session_id
            """
        )
        defer { statement.finalize() }

        var result: [SessionID: SessionReadReceiptState] = [:]
        while try statement.step() {
            guard let rawSessionID = statement.text(0),
                  let sessionID = SessionID(uuidString: rawSessionID) else {
                // Presentation metadata is not authoritative project data. A malformed row may
                // lose a dot; it may not quarantine the conversations it sits beside.
                continue
            }
            let completionGeneration = statement.int(1)
            guard completionGeneration >= 0 else { continue }
            var state = result[sessionID] ?? SessionReadReceiptState(
                sessionID: sessionID,
                completionGeneration: completionGeneration
            )
            if let participantID = statement.text(2), !participantID.isEmpty {
                let seenGeneration = statement.int(3)
                if seenGeneration >= 0, seenGeneration <= completionGeneration {
                    state.seenGenerationByParticipant[participantID] = seenGeneration
                }
            }
            result[sessionID] = state
        }
        return result
    }

    /// Persists the completion and every receipt advancement in one transaction. Upserts are
    /// monotonic at the store owner; retaining untouched receipt rows preserves collaborators
    /// whose devices are offline while another participant reads the result.
    ///
    /// A transient runtime (for example a component-gallery fixture) has no durable session row.
    /// Its live in-memory projection still works, but it cannot own a durable receipt. Checking
    /// inside the write transaction distinguishes that valid case from an actual storage failure
    /// without weakening the foreign key that cleans receipts up with their conversation.
    @discardableResult
    func saveSessionReadReceiptState(_ state: SessionReadReceiptState) throws -> Bool {
        try database.transaction {
            let session = try database.prepare(
                "SELECT 1 FROM session WHERE id = ? LIMIT 1"
            )
            defer { session.finalize() }
            session.bind(1, state.sessionID.uuidString)
            guard try session.step() else { return false }

            try database.prepare(ProjectDatabaseSchema.upsertSessionAttention)
                .bind(1, state.sessionID.uuidString)
                .bind(2, state.completionGeneration)
                .run()
            for (participantID, generation) in state.seenGenerationByParticipant {
                try database.prepare(ProjectDatabaseSchema.upsertSessionReadReceipt)
                    .bind(1, state.sessionID.uuidString)
                    .bind(2, participantID)
                    .bind(3, generation)
                    .run()
            }
            return true
        }
    }

    // MARK: - Private Methods — Rows

    private func upsert(_ project: Project, position: Int) throws {
        // Sessions are rows of their own; carrying them in the payload as well would give the
        // same fact two homes, and one of them would eventually be stale.
        var payload = project
        payload.sessions = []

        try database.prepare(ProjectDatabaseSchema.upsertProject)
            .bind(1, project.id.uuidString)
            .bind(2, position)
            .bind(3, project.name)
            .bind(4, project.folderPath)
            .bind(5, try Self.encodeValidated(payload))
            .run()
    }

    private func upsert(_ session: AgentSession, in projectID: ProjectID, position: Int) throws {
        try database.prepare(ProjectDatabaseSchema.upsertSession)
            .bind(1, session.id.uuidString)
            .bind(2, projectID.uuidString)
            .bind(3, position)
            .bind(4, session.kind.rawValue)
            .bind(5, session.lastActiveAt.timeIntervalSince1970)
            .bind(6, try Self.encodeValidated(session))
            .run()
    }

    /// Removes the rows a save no longer mentions. The ids are UUID strings straight from the
    /// model, never user text, so interpolating them into the `IN` list cannot carry a quote.
    private func deleteRows(in table: String, column: String = "id", keeping ids: Set<String>) throws {
        guard !ids.isEmpty else {
            try database.execute("DELETE FROM \(table)")
            return
        }
        let list = ids.map { "'\($0)'" }.joined(separator: ",")
        try database.execute("DELETE FROM \(table) WHERE \(column) NOT IN (\(list))")
    }

    // MARK: - Private Methods — App State

    /// Finds auxiliary rows no later feature read can identify, without decoding their payloads.
    ///
    /// Payload validity is checked lazily by `StateManager` on the first read or write for that
    /// session. That preserves unreadable and future-format documents without charging startup for
    /// panels and attachments it will not open. A malformed `session_id` is the exception: no
    /// feature can request it later, so startup must notice it and prevent a table-wide prune.
    ///
    /// Still throwing on a SQL failure is deliberate: a table that cannot be read at all is a
    /// database that cannot be trusted, which is the case quarantine exists for.
    private func structurallyUnreadableRows(in table: String) throws -> UnreadableRows {
        var unreadable = UnreadableRows()

        let statement = try database.prepare("SELECT session_id FROM \(table)")
        defer { statement.finalize() }
        while try statement.step() {
            guard let rawID = statement.text(0), SessionID(uuidString: rawID) != nil else {
                unreadable.containsUnkeyedRows = true
                continue
            }
        }

        return unreadable
    }

    /// The store's current generation, or 0 for a database written before it had one.
    ///
    /// Absent and unparsable are the same answer on purpose: this counter authorises nothing on
    /// its own, it only has to change when the graph does, and a store that has never counted is
    /// indistinguishable from one at zero.
    private func storeGeneration() throws -> Int {
        let statement = try database.prepare("SELECT value FROM app_state WHERE key = ?")
        defer { statement.finalize() }
        statement.bind(1, ProjectDatabaseSchema.storeGenerationKey)

        guard try statement.step(), let raw = statement.text(0) else { return 0 }
        return Int(raw) ?? 0
    }

    /// Records that this writer changed which rows exist, and that it is now up to date.
    private func advanceGeneration(from current: Int) throws {
        let next = current &+ 1
        try database.prepare(ProjectDatabaseSchema.upsertAppState)
            .bind(1, ProjectDatabaseSchema.storeGenerationKey)
            .bind(2, String(next))
            .run()
        observedGeneration = next
    }

    private func selectedSessionID() throws -> SessionID? {
        let statement = try database.prepare("SELECT value FROM app_state WHERE key = ?")
        defer { statement.finalize() }
        statement.bind(1, ProjectDatabaseSchema.selectedSessionKey)

        guard try statement.step(), let raw = statement.text(0) else { return nil }
        guard let id = SessionID(uuidString: raw) else {
            throw corruptRow(
                "app_state",
                id: ProjectDatabaseSchema.selectedSessionKey,
                reason: "invalid session identifier '\(raw)'"
            )
        }
        return id
    }

    private func setSelectedSessionID(_ id: SessionID?) throws {
        guard let id else {
            let statement = try database.prepare("DELETE FROM app_state WHERE key = ?")
            statement.bind(1, ProjectDatabaseSchema.selectedSessionKey)
            try statement.run()
            return
        }

        try database.prepare(ProjectDatabaseSchema.upsertAppState)
            .bind(1, ProjectDatabaseSchema.selectedSessionKey)
            .bind(2, id.uuidString)
            .run()
    }

    // MARK: - Private Methods — Coding

    /// Indexed columns stay beside the JSON payload while a bounded group is decoded.
    ///
    /// `JSONDecoder.decode` creates a complete top-level parser for every invocation. Calling it
    /// once per session made startup pay that fixed cost 5,000 times even though the rows were
    /// already ordered and all had the same schema. A bounded array amortizes the parser without
    /// turning the complete store into one large temporary allocation.
    private struct StoredSessionRow {
        let rawID: String
        let rowID: SessionID
        let projectID: ProjectID
        let storedKind: String
        let storedLastActiveAt: Double
        let payload: Data
    }

    private static let sessionDecodeBatchSize = 256

    /// A short startup CPU burst is cheaper than serially decoding thousands of independent
    /// records, but it must not monopolize every core or retain the complete database as one
    /// temporary document. Four batches gives the measured Apple Silicon hosts useful parallelism
    /// while the 1,024-row wave keeps memory and corruption fallback bounded.
    private static let sessionDecodeBatchCount = max(
        1,
        min(4, ProcessInfo.processInfo.activeProcessorCount / 2)
    )
    private static let sessionDecodeWaveSize = sessionDecodeBatchSize * sessionDecodeBatchCount

    private struct SessionPayloadDecodeFailure: LocalizedError {
        let rowID: String
        let reason: String

        var errorDescription: String? { reason }
    }

    /// `DispatchQueue.concurrentPerform` requires one Sendable synchronization owner. The decoded
    /// values themselves remain ordinary launch-local model values and cross the worker boundary
    /// only while this lock holds; callers receive them after every worker has joined.
    private final class SessionBatchResults: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Result<[AgentSession], Error>?]

        init(count: Int) {
            storage = Array(repeating: nil, count: count)
        }

        func store(_ result: Result<[AgentSession], Error>, at index: Int) {
            lock.lock()
            storage[index] = result
            lock.unlock()
        }

        func values() -> [Result<[AgentSession], Error>] {
            lock.lock()
            defer { lock.unlock() }
            return storage.enumerated().map { index, result in
                result ?? .failure(SQLiteDatabase.Failure.syntheticStep(
                    "Session decode batch \(index) did not complete"
                ))
            }
        }
    }

    private func appendDecodedSessions(
        _ rows: [StoredSessionRow],
        to sessionsByProject: inout [ProjectID: [AgentSession]]
    ) throws {
        guard !rows.isEmpty else { return }

        let batches = stride(from: 0, to: rows.count, by: Self.sessionDecodeBatchSize).map {
            Array(rows[$0..<min($0 + Self.sessionDecodeBatchSize, rows.count)])
        }
        let decodedBatches: [Result<[AgentSession], Error>]
        if batches.count == 1 {
            decodedBatches = [Result { try Self.decodeSessionBatch(batches[0]) }]
        } else {
            let results = SessionBatchResults(count: batches.count)
            DispatchQueue.concurrentPerform(iterations: batches.count) { index in
                results.store(
                    Result { try Self.decodeSessionBatch(batches[index]) },
                    at: index
                )
            }
            decodedBatches = results.values()
        }

        for (batchRows, result) in zip(batches, decodedBatches) {
            let decoded: [AgentSession]
            do {
                decoded = try result.get()
            } catch let failure as SessionPayloadDecodeFailure {
                throw corruptRow(
                    "session",
                    id: failure.rowID,
                    reason: failure.reason
                )
            } catch {
                throw corruptRow(
                    "session",
                    id: batchRows.first?.rawID,
                    reason: "invalid JSON payload batch: \(error.localizedDescription)"
                )
            }

            guard decoded.count == batchRows.count else {
                throw corruptRow(
                    "session",
                    id: batchRows.first?.rawID,
                    reason: "decoded \(decoded.count) payloads for \(batchRows.count) rows"
                )
            }

            for (row, session) in zip(batchRows, decoded) {
                try validateAndAppend(
                    session,
                    for: row,
                    to: &sessionsByProject
                )
            }
        }
    }

    private static func decodeSessionBatch(
        _ rows: [StoredSessionRow]
    ) throws -> [AgentSession] {
        var payload = Data()
        payload.reserveCapacity(rows.reduce(2) { $0 + $1.payload.count + 1 })
        payload.append(0x5B) // [
        for (index, row) in rows.enumerated() {
            if index > 0 { payload.append(0x2C) } // ,
            payload.append(row.payload)
        }
        payload.append(0x5D) // ]

        let decoder = JSONDecoder()
        do {
            return try decoder.decode([AgentSession].self, from: payload)
        } catch {
            // A corrupt authoritative row must still name the exact record and fail the whole
            // load. Individual decoding is deliberately the exceptional recovery path: healthy
            // startup stays batched, while corruption reporting preserves its existing contract.
            for row in rows {
                do {
                    _ = try decoder.decode(AgentSession.self, from: row.payload)
                } catch {
                    throw SessionPayloadDecodeFailure(
                        rowID: row.rawID,
                        reason: "invalid JSON payload: \(error.localizedDescription)"
                    )
                }
            }
            throw SessionPayloadDecodeFailure(
                rowID: rows[0].rawID,
                reason: "invalid JSON payload batch: \(error.localizedDescription)"
            )
        }
    }

    private func validateAndAppend(
        _ session: AgentSession,
        for row: StoredSessionRow,
        to sessionsByProject: inout [ProjectID: [AgentSession]]
    ) throws {
        guard session.id == row.rowID else {
            throw corruptRow(
                "session",
                id: row.rawID,
                reason: "payload identifier is '\(session.id.uuidString)'"
            )
        }
        guard session.kind.rawValue == row.storedKind else {
            throw corruptRow(
                "session",
                id: row.rawID,
                reason: "indexed provider '\(row.storedKind)' disagrees with payload '\(session.kind.rawValue)'"
            )
        }
        guard abs(
            session.lastActiveAt.timeIntervalSince1970 - row.storedLastActiveAt
        ) < 0.000_001 else {
            throw corruptRow(
                "session",
                id: row.rawID,
                reason: "indexed last-active time disagrees with payload"
            )
        }
        sessionsByProject[row.projectID, default: []].append(session)
    }

    /// The payload encoding is the model's own, with dates as the same `timeIntervalSince1970`
    /// doubles `JSONEncoder` has always written here — so a record imported from
    /// `projects.json` and one written today decode identically.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Runs the persisted representation back through its decoder before it reaches SQLite.
    /// The decoder owns schema invariants (provider-specific options, absolute project paths,
    /// identity presence), so the write boundary enforces the same rules as the read boundary.
    private static func encodeValidated<Value: Codable>(_ value: Value) throws -> String {
        let data = try encoder.encode(value)
        _ = try decoder.decode(Value.self, from: data)
        return String(decoding: data, as: UTF8.self)
    }

    private func corruptRow(
        _ table: String,
        id: String?,
        reason: String
    ) -> ProjectDatabaseLoadError {
        .corruptRow(table: table, id: id, reason: reason)
    }
}

// MARK: - Schema

enum ProjectDatabaseSchema {

    static let version = 6

    static let selectedSessionKey = "selectedSessionID"

    static let runningSessionsKey = "runningSessionIDs"

    /// Temporary row used only inside the recovery probe transaction.
    static let storageRecoveryProbeKey = "storageRecoveryProbe"

    /// Counts changes to *which* rows exist, so a reconciling write can prove it is not working
    /// from a snapshot another writer has already moved past. Lives in `app_state` rather than a
    /// column, so it needs no migration and an older build simply ignores it.
    static let storeGenerationKey = "storeGeneration"

    /// The auxiliary tables are named outside their own statements — a load reports what it could
    /// not read per table — so the name is a constant rather than a literal per call site.
    static let panelTable = "panel_layout"

    static let attachmentsTable = "session_attachments"
    static let controlGrantTable = "control_grant"
    static let supervisionTable = "supervision"
    static let supervisionEventTable = "supervision_event"
    static let sessionAttentionTable = "session_attention"
    static let sessionReadReceiptTable = "session_read_receipt"

    /// Columns exist to be ordered by, filtered on, or joined; everything else is in `data`.
    /// `kind` and `last_active_at` are duplicated out of the payload on purpose — they are what
    /// a sidebar query would ask about, and they are written from the model in exactly one
    /// place, so they cannot drift from it.
    static let version1 = """
        CREATE TABLE project (
            id          TEXT PRIMARY KEY,
            position    INTEGER NOT NULL,
            name        TEXT NOT NULL,
            folder_path TEXT NOT NULL,
            data        TEXT NOT NULL
        );

        CREATE TABLE session (
            id             TEXT PRIMARY KEY,
            project_id     TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
            position       INTEGER NOT NULL,
            kind           TEXT NOT NULL,
            last_active_at REAL NOT NULL,
            data           TEXT NOT NULL
        );

        CREATE INDEX session_project_position ON session (project_id, position);

        CREATE TABLE app_state (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """

    static let upsertProject = """
        INSERT INTO project (id, position, name, folder_path, data)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            position = excluded.position,
            name = excluded.name,
            folder_path = excluded.folder_path,
            data = excluded.data
        """

    static let upsertSession = """
        INSERT INTO session (id, project_id, position, kind, last_active_at, data)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id,
            position = excluded.position,
            kind = excluded.kind,
            last_active_at = excluded.last_active_at,
            data = excluded.data
        """

    /// One row per session, holding the panel's own `Codable` record — the same payload the
    /// per-session `panels/<uuid>.json` files held, in the store that already owns the session.
    static let version2 = """
        CREATE TABLE panel_layout (
            session_id TEXT PRIMARY KEY,
            data       TEXT NOT NULL
        );
        """

    static let upsertPanel = """
        INSERT INTO panel_layout (session_id, data) VALUES (?, ?)
        ON CONFLICT(session_id) DO UPDATE SET data = excluded.data
        """

    /// One row per session, holding the attachment references the session has surfaced. The
    /// panel's *tab* already survived a relaunch; this is the half of that promise the tab was
    /// reopening onto an empty pane without.
    static let version3 = """
        CREATE TABLE session_attachments (
            session_id TEXT PRIMARY KEY,
            data       TEXT NOT NULL
        );
        """

    /// Control authority is normalized beside the project graph rather than embedded in one
    /// session's payload: grants and manager/child records have their own lifetimes and foreign
    /// keys, and session deletion removes every row that could otherwise retain authority.
    static let version4 = """
        CREATE TABLE control_grant (
            id               TEXT PRIMARY KEY,
            actor_session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
            conferred_at     REAL NOT NULL,
            revoked_at       REAL,
            data             TEXT NOT NULL
        );

        CREATE INDEX control_grant_actor ON control_grant (actor_session_id, revoked_at);

        CREATE TABLE supervision (
            id                 TEXT PRIMARY KEY,
            manager_session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
            child_session_id   TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
            assigned_at        REAL NOT NULL,
            state              TEXT NOT NULL,
            data               TEXT NOT NULL,
            UNIQUE(manager_session_id, child_session_id)
        );

        CREATE INDEX supervision_manager ON supervision (manager_session_id, state, assigned_at);
        CREATE INDEX supervision_child ON supervision (child_session_id, state);

        CREATE TABLE supervision_event (
            id             TEXT PRIMARY KEY,
            supervision_id TEXT NOT NULL REFERENCES supervision(id) ON DELETE CASCADE,
            at             REAL NOT NULL,
            kind           TEXT NOT NULL,
            data           TEXT NOT NULL
        );

        CREATE INDEX supervision_event_order ON supervision_event (supervision_id, at);
        """

    /// A supervision row is one tenure, not the lifetime identity of a manager/child pair.
    ///
    /// Version 4 made that pair unique, so adopting a child after releasing it created the new
    /// historical record the model requires and then failed at the SQL boundary. Rebuild both
    /// related tables together: dropping the old parent while its event table still referenced it
    /// would apply `ON DELETE CASCADE` and erase the audit stream during migration.
    ///
    /// The replacement constraint states the real invariant instead: a child may have at most one
    /// active manager, while any number of closed tenures remain queryable by their own ids.
    static let version5 = """
        CREATE TABLE supervision_v5 (
            id                 TEXT PRIMARY KEY,
            manager_session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
            child_session_id   TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
            assigned_at        REAL NOT NULL,
            state              TEXT NOT NULL,
            data               TEXT NOT NULL
        );

        CREATE TABLE supervision_event_v5 (
            id             TEXT PRIMARY KEY,
            supervision_id TEXT NOT NULL REFERENCES supervision_v5(id) ON DELETE CASCADE,
            at             REAL NOT NULL,
            kind           TEXT NOT NULL,
            data           TEXT NOT NULL
        );

        INSERT INTO supervision_v5 SELECT * FROM supervision;
        INSERT INTO supervision_event_v5 SELECT * FROM supervision_event;

        DROP TABLE supervision_event;
        DROP TABLE supervision;

        ALTER TABLE supervision_v5 RENAME TO supervision;
        ALTER TABLE supervision_event_v5 RENAME TO supervision_event;

        CREATE INDEX supervision_manager ON supervision (manager_session_id, state, assigned_at);
        CREATE INDEX supervision_child ON supervision (child_session_id, state);
        CREATE UNIQUE INDEX supervision_active_child ON supervision (child_session_id)
            WHERE state = '\(SupervisionState.active.rawValue)';
        CREATE INDEX supervision_event_order ON supervision_event (supervision_id, at);
        """

    /// Unread is participant state, not process state. The conversation owns a monotonic result
    /// generation; each stable participant identity owns how far through it they have read.
    /// Both tables cascade with the session so a deleted chat leaves no identity metadata behind.
    static let version6 = """
        CREATE TABLE session_attention (
            session_id TEXT PRIMARY KEY REFERENCES session(id) ON DELETE CASCADE,
            generation INTEGER NOT NULL CHECK(generation >= 0)
        );

        CREATE TABLE session_read_receipt (
            session_id     TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
            participant_id TEXT NOT NULL,
            generation     INTEGER NOT NULL CHECK(generation >= 0),
            PRIMARY KEY(session_id, participant_id)
        );
        """

    static let upsertSessionAttention = """
        INSERT INTO session_attention (session_id, generation) VALUES (?, ?)
        ON CONFLICT(session_id) DO UPDATE SET generation = excluded.generation
        """

    static let upsertSessionReadReceipt = """
        INSERT INTO session_read_receipt (session_id, participant_id, generation)
        VALUES (?, ?, ?)
        ON CONFLICT(session_id, participant_id) DO UPDATE SET generation = excluded.generation
        """

    static let upsertControlGrant = """
        INSERT INTO control_grant (id, actor_session_id, conferred_at, revoked_at, data)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            actor_session_id = excluded.actor_session_id,
            conferred_at = excluded.conferred_at,
            revoked_at = excluded.revoked_at,
            data = excluded.data
        """

    static let upsertSupervision = """
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

    static let insertSupervisionEvent = """
        INSERT INTO supervision_event (id, supervision_id, at, kind, data)
        VALUES (?, ?, ?, ?, ?)
        """

    static let pruneSupervisionEvents = """
        DELETE FROM supervision_event
        WHERE supervision_id = ? AND id NOT IN (
            SELECT id FROM supervision_event
            WHERE supervision_id = ?
            ORDER BY at DESC
            LIMIT ?
        )
        """

    static let upsertAttachments = """
        INSERT INTO session_attachments (session_id, data) VALUES (?, ?)
        ON CONFLICT(session_id) DO UPDATE SET data = excluded.data
        """

    static let upsertAppState = """
        INSERT INTO app_state (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """
}
