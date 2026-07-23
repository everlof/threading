import Foundation

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

    // MARK: - Initialization

    init(url: URL) throws {
        database = try SQLiteDatabase(path: url.path)
        try migrate()
    }

    // MARK: - Schema

    private func migrate() throws {
        try database.migrate(to: ProjectDatabaseSchema.version) { version in
            switch version {
            case 1:
                try database.execute(ProjectDatabaseSchema.version1)
            case 2:
                try database.execute(ProjectDatabaseSchema.version2)
            default:
                // Unreachable while `version` and the cases here are edited together, which is
                // the point of failing loudly rather than silently skipping a step.
                throw SQLiteDatabase.Failure.step("No migration to schema version \(version)")
            }
        }
    }

    // MARK: - Public Methods

    /// Whether anything has been stored yet — the question that decides whether a legacy
    /// `projects.json` should be imported.
    var isEmpty: Bool {
        ((try? database.scalar("SELECT COUNT(*) FROM project")) ?? 0) == 0
    }

    func load() throws -> ProjectsState {
        var projects: [Project] = []
        var sessionsByProject: [ProjectID: [AgentSession]] = [:]

        let sessions = try database.prepare(
            "SELECT project_id, data FROM session ORDER BY project_id, position"
        )
        defer { sessions.finalize() }
        while try sessions.step() {
            guard let rawProjectID = sessions.text(0),
                  let projectID = ProjectID(uuidString: rawProjectID),
                  let payload = sessions.text(1),
                  let session = try? Self.decoder.decode(AgentSession.self, from: Data(payload.utf8))
            else { continue }
            sessionsByProject[projectID, default: []].append(session)
        }

        let rows = try database.prepare("SELECT id, data FROM project ORDER BY position")
        defer { rows.finalize() }
        while try rows.step() {
            guard let rawID = rows.text(0),
                  let id = ProjectID(uuidString: rawID),
                  let payload = rows.text(1),
                  var project = try? Self.decoder.decode(Project.self, from: Data(payload.utf8))
            else { continue }
            project.sessions = sessionsByProject[id] ?? []
            projects.append(project)
        }

        return ProjectsState(
            projects: projects,
            selectedSessionID: try selectedSessionID(),
            savedAt: Date()
        )
    }

    /// Brings the stored rows in line with the state, in one transaction: upsert what is there,
    /// delete what has gone. Not a truncate-and-rewrite — that would be the JSON document with
    /// extra steps, and would churn the write-ahead log for a renamed tab.
    func save(_ state: ProjectsState) throws {
        try database.transaction {
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
        }
    }

    /// Persists only window navigation state.
    ///
    /// A sidebar selection changes one value, not the project graph. Routing it through
    /// `save(_:)` needlessly re-encoded and upserted every project and session on the main
    /// thread, making a click cost grow with the size of the sidebar.
    func saveSelectedSessionID(_ id: SessionID?) throws {
        try setSelectedSessionID(id)
    }

    // MARK: - Public Methods — Panel Layouts

    /// The display panel's tabs for a session, as its own `Codable` payload.
    ///
    /// Deliberately *not* foreign-keyed to `session`: a panel is written by the pane and the
    /// session by the store, on their own schedules, and a constraint between them would make
    /// whichever wrote first fail. `retainPanels` prunes instead, which is what the file layout
    /// did too.
    func panelPayload(for sessionID: SessionID) throws -> String? {
        let statement = try database.prepare("SELECT data FROM panel_layout WHERE session_id = ?")
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
        let statement = try database.prepare("DELETE FROM panel_layout WHERE session_id = ?")
        statement.bind(1, sessionID.uuidString)
        try statement.run()
    }

    func retainPanels(sessionIDs: Set<SessionID>) throws {
        try deleteRows(in: "panel_layout", column: "session_id", keeping: Set(sessionIDs.map(\.uuidString)))
    }

    var hasPanelLayouts: Bool {
        ((try? database.scalar("SELECT COUNT(*) FROM panel_layout")) ?? 0) > 0
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
            .bind(5, try Self.encode(payload))
            .run()
    }

    private func upsert(_ session: AgentSession, in projectID: ProjectID, position: Int) throws {
        try database.prepare(ProjectDatabaseSchema.upsertSession)
            .bind(1, session.id.uuidString)
            .bind(2, projectID.uuidString)
            .bind(3, position)
            .bind(4, session.kind.rawValue)
            .bind(5, session.lastActiveAt.timeIntervalSince1970)
            .bind(6, try Self.encode(session))
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

    private func selectedSessionID() throws -> SessionID? {
        let statement = try database.prepare("SELECT value FROM app_state WHERE key = ?")
        defer { statement.finalize() }
        statement.bind(1, ProjectDatabaseSchema.selectedSessionKey)

        guard try statement.step(), let raw = statement.text(0) else { return nil }
        return SessionID(uuidString: raw)
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

    /// The payload encoding is the model's own, with dates as the same `timeIntervalSince1970`
    /// doubles `JSONEncoder` has always written here — so a record imported from
    /// `projects.json` and one written today decode identically.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static func encode<Value: Encodable>(_ value: Value) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

// MARK: - Schema

enum ProjectDatabaseSchema {

    static let version = 2

    static let selectedSessionKey = "selectedSessionID"

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

    static let upsertAppState = """
        INSERT INTO app_state (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """
}
