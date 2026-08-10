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
        case newerSchema(found: Int, supported: Int)

        var errorDescription: String? {
            switch self {
            case .open(let message): return "Could not open the database: \(message)"
            case .statement(let message): return "Could not prepare a statement: \(message)"
            case .step(let message): return "Database error: \(message)"
            case .newerSchema(let found, let supported):
                return "Database schema \(found) is newer than supported schema \(supported)"
            }
        }
    }

    // MARK: - Properties

    private var handle: OpaquePointer?

    /// SQLite must copy a bound string: Swift's buffer is gone by the time the statement runs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Initialization

    init(path: String, maximumSchemaVersion: Int? = nil) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            throw Failure.open(message)
        }
        self.handle = handle

        // Check before journal-mode configuration: opening a future database is a read, while
        // changing its journal mode is a write. A downgraded build must leave bytes it does not
        // understand exactly where the newer build put them.
        if let maximumSchemaVersion {
            do {
                let found = try scalar("PRAGMA user_version") ?? 0
                guard found <= maximumSchemaVersion else {
                    close()
                    throw Failure.newerSchema(
                        found: found,
                        supported: maximumSchemaVersion
                    )
                }
            } catch {
                close()
                throw error
            }
        }

        // Ordered deliberately: WAL first so everything after it is journalled the new way.
        // `busy_timeout` is what turns "another writer has it" from an error into a wait —
        // the whole point of coming here.
        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA busy_timeout = \(SQLiteDefaults.busyTimeoutMilliseconds)")
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA synchronous = NORMAL")
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
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
        guard version <= target else {
            throw Failure.newerSchema(found: version, supported: target)
        }
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

    /// Releases the native connection exactly once. The app normally keeps one connection for
    /// the process, but initialization failure and test-owned stores both need deterministic
    /// teardown. `sqlite3_close_v2` safely completes after any still-owned statement finalizes;
    /// `Statement` now owns that finalization rather than relying on every call path to remember.
    func close() {
        guard let handle else { return }
        self.handle = nil
        sqlite3_close_v2(handle)
    }

    /// Makes the database a single-file artifact before its owner moves it.
    ///
    /// Merely closing this connection is not enough in WAL mode: another reader can pin committed
    /// frames in `-wal`, and renaming the main file underneath that reader is an SQLite API
    /// violation. Switching back to the delete journal requires SQLite's own exclusive transition;
    /// if another connection prevents it, the refusal is evidence that no file move is safe yet.
    func prepareForFileMove() -> Bool {
        do {
            // Quarantine is a recovery path. It must refuse promptly rather than stall the main
            // actor for the ordinary five-second writer timeout while another build is open.
            try execute("PRAGMA busy_timeout = 0")
            let statement = try prepare("PRAGMA journal_mode = DELETE")
            defer { statement.finalize() }
            guard try statement.step(), statement.text(0)?.lowercased() == "delete" else {
                return false
            }
            return true
        } catch {
            ThreadingLogger.agent.error(
                "Could not make the SQLite store safe to move: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Diagnostic seam for the ownership test. A native statement surviving after its Swift
    /// owner leaves scope is a leaked SQLite resource and can keep a closed WAL connection alive.
    var hasOpenStatements: Bool {
        guard let handle else { return false }
        return sqlite3_next_stmt(handle, nil) != nil
    }

    // MARK: - Statement

    /// One prepared statement. Deliberately not `Sendable` and deliberately manual: a statement
    /// belongs to the queue that prepared it, and its lifetime is a few lines long.
    final class Statement {

        private var handle: OpaquePointer?
        private let transient: sqlite3_destructor_type

        fileprivate init(_ handle: OpaquePointer, transient: @escaping sqlite3_destructor_type) {
            self.handle = handle
            self.transient = transient
        }

        deinit {
            finalize()
        }

        // MARK: Binding — 1-based, as SQLite counts them

        @discardableResult
        func bind(_ index: Int32, _ value: String) -> Statement {
            sqlite3_bind_text(activeHandle, index, value, -1, transient)
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: String?) -> Statement {
            if let value { return bind(index, value) }
            sqlite3_bind_null(activeHandle, index)
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: Int) -> Statement {
            sqlite3_bind_int64(activeHandle, index, Int64(value))
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: Double) -> Statement {
            sqlite3_bind_double(activeHandle, index, value)
            return self
        }

        // MARK: Reading — 0-based, as SQLite counts them

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(activeHandle, column) else { return nil }
            return String(cString: pointer)
        }

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(activeHandle, column))
        }

        func double(_ column: Int32) -> Double {
            sqlite3_column_double(activeHandle, column)
        }

        /// True while rows remain. A statement that returns nothing steps once and is done.
        @discardableResult
        func step() throws -> Bool {
            let handle = activeHandle
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
            guard let handle else { return }
            self.handle = nil
            sqlite3_finalize(handle)
        }

        /// A finalized statement is a programmer error, but it must not become a use-after-free
        /// in SQLite. The optional native handle makes teardown idempotent; this guard turns any
        /// later misuse into a deterministic failure at the ownership boundary.
        private var activeHandle: OpaquePointer {
            guard let handle else {
                preconditionFailure("Attempted to use a finalized SQLite statement")
            }
            return handle
        }
    }
}

// MARK: - Defaults

enum SQLiteDefaults {
    /// How long a write waits for another writer before giving up. Long enough to cover a
    /// checkpoint, short enough that a wedged process cannot hang the UI.
    static let busyTimeoutMilliseconds = 5_000

    static let databaseName = "threading.db"

    /// The write-ahead log. SQLite finds it by name, so anything that moves the database has to
    /// move this with it or the committed rows still sitting in it are gone.
    static let walSuffix = "-wal"

    /// The shared-memory index over the log. Rebuilt on demand, so it is never worth keeping —
    /// and beside a database that has been moved away it is actively dangerous.
    static let sharedMemorySuffix = "-shm"

    /// What the migrated JSON document is renamed to. Kept rather than deleted: opencode's own
    /// storage migration is the cautionary tale, and a file that is still there is a rollback.
    static let migratedSuffix = "migrated"
}
