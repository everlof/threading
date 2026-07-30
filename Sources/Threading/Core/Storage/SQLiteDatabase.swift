import Foundation
import SQLite3

/// A thin wrapper over the system SQLite, which is the whole of the dependency story: macOS
/// ships 3.51 with FTS5 compiled in, so `import SQLite3` costs nothing and the project's
/// "only SwiftTerm" rule stands. No ORM, no schema DSL — the queries are written out, because
/// there are a dozen of them and a query builder would be more code than the queries.
///
/// Opened in **WAL**, which is the reason for moving here at all: a reader never blocks the
/// writer, and a second process can be told to wait rather than corrupting anything. The
/// single-instance lock stays for now — this makes multiple writers *possible*, not permitted.
final class SQLiteDatabase {

    // MARK: - Types

    enum Failure: LocalizedError {
        case open(String)
        case statement(String)
        case step(String)

        var errorDescription: String? {
            switch self {
            case .open(let message): return "Could not open the database: \(message)"
            case .statement(let message): return "Could not prepare a statement: \(message)"
            case .step(let message): return "Database error: \(message)"
            }
        }
    }

    // MARK: - Properties

    private var handle: OpaquePointer?

    /// SQLite must copy a bound string: Swift's buffer is gone by the time the statement runs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Initialization

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            throw Failure.open(message)
        }
        self.handle = handle

        // Ordered deliberately: WAL first so everything after it is journalled the new way.
        // `busy_timeout` is what turns "another writer has it" from an error into a wait —
        // the whole point of coming here.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA busy_timeout = \(SQLiteDefaults.busyTimeoutMilliseconds)")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    // MARK: - Public Methods

    /// Runs statements that return nothing.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw Failure.step(message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.statement(lastErrorMessage)
        }
        return Statement(statement, transient: Self.transient)
    }

    /// All or nothing. A throwing body rolls back, which is what makes a whole-state write
    /// safe to interrupt — the failure mode the JSON document could only answer with a `.bak`.
    func transaction<Value>(_ body: () throws -> Value) throws -> Value {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// The schema version, migrated forward by running each step in order inside one
    /// transaction. `user_version` is SQLite's own integer for exactly this.
    func migrate(to target: Int, step: (Int) throws -> Void) throws {
        var version = try scalar("PRAGMA user_version") ?? 0
        guard version < target else { return }

        try transaction {
            while version < target {
                version += 1
                try step(version)
                // Interpolated because PRAGMA takes no bound parameters; the value is an Int.
                try execute("PRAGMA user_version = \(version)")
            }
        }
        ThreadingLogger.agent.info("Database migrated to schema version \(target, privacy: .public)")
    }

    /// The first column of the first row, for the one-value queries.
    func scalar(_ sql: String) throws -> Int? {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        return try statement.step() ? statement.int(0) : nil
    }

    var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    // MARK: - Statement

    /// One prepared statement. Deliberately not `Sendable` and deliberately manual: a statement
    /// belongs to the queue that prepared it, and its lifetime is a few lines long.
    final class Statement {

        private let handle: OpaquePointer
        private let transient: sqlite3_destructor_type

        fileprivate init(_ handle: OpaquePointer, transient: @escaping sqlite3_destructor_type) {
            self.handle = handle
            self.transient = transient
        }

        // MARK: Binding — 1-based, as SQLite counts them

        @discardableResult
        func bind(_ index: Int32, _ value: String) -> Statement {
            sqlite3_bind_text(handle, index, value, -1, transient)
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: String?) -> Statement {
            if let value { return bind(index, value) }
            sqlite3_bind_null(handle, index)
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: Int) -> Statement {
            sqlite3_bind_int64(handle, index, Int64(value))
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: Double) -> Statement {
            sqlite3_bind_double(handle, index, value)
            return self
        }

        // MARK: Reading — 0-based, as SQLite counts them

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(handle, column) else { return nil }
            return String(cString: pointer)
        }

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(handle, column))
        }

        func double(_ column: Int32) -> Double {
            sqlite3_column_double(handle, column)
        }

        /// True while rows remain. A statement that returns nothing steps once and is done.
        @discardableResult
        func step() throws -> Bool {
            switch sqlite3_step(handle) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw Failure.step(String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
            }
        }

        /// Steps a statement that returns nothing, then finalizes it.
        func run() throws {
            defer { finalize() }
            _ = try step()
        }

        func finalize() {
            sqlite3_finalize(handle)
        }
    }
}

// MARK: - Defaults

enum SQLiteDefaults {
    /// How long a write waits for another writer before giving up. Long enough to cover a
    /// checkpoint, short enough that a wedged process cannot hang the UI.
    static let busyTimeoutMilliseconds = 5_000

    static let databaseName = "threading.db"

    /// What the migrated JSON document is renamed to. Kept rather than deleted: opencode's own
    /// storage migration is the cautionary tale, and a file that is still there is a rollback.
    static let migratedSuffix = "migrated"
}
