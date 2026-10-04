import Foundation
import CControllerSQLite

/// Owned by ControllerStore's actor. Each operation uses a bounded prepared statement; separate
/// CLI processes coordinate through SQLite BEGIN IMMEDIATE, not a read/modify/write snapshot.
final class ControllerDatabase {
    /// The schema this build reads and writes. Every write transaction re-reads `user_version`
    /// under its write lock and refuses unless it is exactly this, so an older process that
    /// stays open while a newer one migrates the file stops writing instead of writing rows the
    /// new schema's invariants do not expect. The integrator sets this to the final step.
    static let schemaVersion: Int64 = 10
    /// How long a write waits for another process's write lock before SQLITE_BUSY.
    private static let busyTimeoutMilliseconds: Int32 = 3_000
    private var handle: OpaquePointer?
    private var transactionDepth = 0
    /// Set once this connection finished opening/migrating; from then on writes are fenced.
    private var fenced = false
    init(path: String) throws {
        // macOS /var and /tmp are symlinks. Resolve the containing directory, but preserve the
        // database leaf so SQLITE_OPEN_NOFOLLOW still refuses a substituted database symlink.
        let url = URL(fileURLWithPath: path)
        // Foundation may shorten /private/var back to /var on macOS. Keep POSIX realpath's
        // spelling through sqlite3_open instead of putting it back through a URL normalizer.
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
            throw ControllerError.invalidInput("database_parent")
        }
        let resolved = String(cString: parent) + "/" + url.lastPathComponent
        free(parent)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let result = sqlite3_open_v2(resolved, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let code = sqlite3_extended_errcode(handle)
            sqlite3_close(handle)
            handle = nil
            throw ControllerError.storage(code)
        }
        do {
            sqlite3_extended_result_codes(handle, 1)
            sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 1_048_576)
            sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
            // Each step reads the version inside its own write transaction, applies only when the
            // file is still below it, and never writes a lower version: two processes opening an
            // old store at once serialize on the write lock, and the second sees the first's
            // result instead of re-running (or rolling back the version of) an earlier step.
            try migrate(to: 3) { version in
                if version == 0 {
                    try run("""
                        CREATE TABLE record (
                            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                            kind TEXT NOT NULL, id TEXT NOT NULL, parent TEXT,
                            key TEXT, state TEXT, payload TEXT NOT NULL,
                            UNIQUE(kind, id)
                        )
                        """)
                    try run("CREATE UNIQUE INDEX record_key ON record(kind,parent,key) WHERE key IS NOT NULL")
                    try run("CREATE INDEX record_page ON record(kind,sequence)")
                    try run("CREATE INDEX record_parent ON record(kind,parent,sequence)")
                    try run("CREATE INDEX record_ready ON record(kind,parent,state,sequence)")
                    try run("CREATE TABLE event (sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, subject TEXT NOT NULL, at TEXT NOT NULL)")
                }
                try run("ALTER TABLE record ADD COLUMN scope TEXT")
                try run("""
                    UPDATE record SET scope=(SELECT parent FROM record AS work
                        WHERE work.kind='work' AND work.id=record.parent)
                    WHERE kind='launch'
                    """)
                guard try rows("SELECT id FROM record WHERE kind='launch' AND scope IS NULL LIMIT 1").isEmpty else {
                    throw ControllerError.storage(SQLITE_CORRUPT)
                }
                try run("CREATE INDEX record_scope_state ON record(kind,scope,state,sequence)")
                try run("CREATE INDEX unresolved_launch ON record(sequence) WHERE kind='launch' AND state IN ('prepared','dispatching','running')")
            }
            try migrate(to: 4) { _ in
                try run("""
                    UPDATE record SET scope=(SELECT parent FROM record AS work
                        WHERE work.kind='work' AND work.id=record.parent)
                    WHERE kind='question'
                    """)
                guard try rows("SELECT id FROM record WHERE kind='question' AND scope IS NULL LIMIT 1").isEmpty else {
                    throw ControllerError.storage(SQLITE_CORRUPT)
                }
                try run("CREATE INDEX unresolved_delivery ON record(sequence) WHERE kind='delivery' AND state IN ('pending','sending','uncertain')")
            }
            try migrate(to: 5) { _ in
                try run("CREATE TABLE automation_due (id TEXT PRIMARY KEY, due INTEGER NOT NULL)")
                try run("CREATE INDEX automation_due_time ON automation_due(due,id)")
            }
            try migrate(to: 6) { _ in
                try run("CREATE INDEX IF NOT EXISTS automation_worker_active ON record(json_extract(payload,'$.spec.workerID')) WHERE kind='automation' AND json_extract(payload,'$.enabled')=1")
            }
            // Agent mail. Open mail is read by recipient through a partial index, so an inbox
            // never walks acknowledged history; the outbound queue is per destination host.
            try migrate(to: 7) { _ in
                try run("CREATE INDEX IF NOT EXISTS mail_open ON record(parent,sequence) WHERE kind='mail' AND state IN ('inbox','noticed')")
                try run("CREATE INDEX IF NOT EXISTS mail_wake ON record(sequence) WHERE kind='mail' AND state IN ('inbox','noticed') AND json_extract(payload,'$.wake')=1")
                try run("CREATE TABLE IF NOT EXISTS mail_outbound (sequence INTEGER PRIMARY KEY AUTOINCREMENT, host TEXT NOT NULL, message TEXT NOT NULL UNIQUE)")
                try run("CREATE INDEX IF NOT EXISTS mail_outbound_host ON mail_outbound(host,sequence)")
            }
            // Trigger sources: when each enabled source next polls, read by due time only.
            try migrate(to: 8) { _ in
                try run("CREATE TABLE IF NOT EXISTS source_due (id TEXT PRIMARY KEY, due INTEGER NOT NULL)")
                try run("CREATE INDEX IF NOT EXISTS source_due_time ON source_due(due,id)")
                try run("CREATE INDEX IF NOT EXISTS trigger_source ON record(parent,sequence) WHERE kind='trigger'")
            }
            // Usage receipts: executions owed a receipt, and per-day cells a range reads.
            try migrate(to: 9) { _ in
                try run("CREATE TABLE IF NOT EXISTS usage_pending (execution TEXT PRIMARY KEY)")
                try run("""
                    CREATE TABLE IF NOT EXISTS usage_daily (day TEXT NOT NULL, worker TEXT NOT NULL, account TEXT NOT NULL,
                    model TEXT NOT NULL, uncached INTEGER NOT NULL, cached INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                    output INTEGER NOT NULL, reasoning INTEGER NOT NULL, cost REAL NOT NULL, requests INTEGER NOT NULL,
                    executions INTEGER NOT NULL, PRIMARY KEY(day,worker,account,model))
                    """)
                try run("CREATE INDEX IF NOT EXISTS usage_daily_worker ON usage_daily(worker,day)")
            }
            // The backfills below run once: the step is skipped by any process that sees 10.
            try migrate(to: 10) { _ in
                try run("CREATE INDEX IF NOT EXISTS trigger_active_source ON record(parent,sequence) WHERE kind='trigger' AND json_extract(payload,'$.enabled')=1 AND json_extract(payload,'$.deleted')=0")
                try run("CREATE INDEX IF NOT EXISTS usage_receipt_coverage ON record(scope,state,sequence) WHERE kind='usageReceipt'")
                try run("CREATE TABLE IF NOT EXISTS usage_unsettled (execution TEXT PRIMARY KEY, worker TEXT NOT NULL, stopped_day TEXT)")
                try run("CREATE INDEX IF NOT EXISTS usage_unsettled_worker ON usage_unsettled(worker,stopped_day)")
                try run("""
                    INSERT OR IGNORE INTO usage_unsettled(execution,worker)
                    SELECT l.id,l.scope FROM record l WHERE l.kind='launch'
                    AND NOT EXISTS (SELECT 1 FROM record r WHERE r.kind='usageReceipt' AND r.id=l.id AND r.state='complete')
                    """)
                try run("CREATE INDEX IF NOT EXISTS event_subject_kind ON event(subject,kind,sequence)")
                // Existing stop events are authoritative; never substitute migration time.
                try run("""
                    UPDATE record SET payload=json_set(payload,'$.stoppedAt',
                        (SELECT at FROM event WHERE kind='launch.stopped' AND subject=record.id ORDER BY sequence DESC LIMIT 1))
                    WHERE kind='launch' AND state='stopped' AND json_extract(payload,'$.stoppedAt') IS NULL
                    """)
                try run("""
                    UPDATE usage_unsettled SET stopped_day=(SELECT substr(json_extract(payload,'$.stoppedAt'),1,10)
                    FROM record WHERE kind='launch' AND id=usage_unsettled.execution)
                    """)
            }
            guard try currentVersion() == Self.schemaVersion else { throw ControllerError.unsupportedSchema }
            try run("PRAGMA journal_mode=WAL")
            try run("PRAGMA synchronous=FULL")
            // Overwritten and deleted cells are zeroed inside the page being written anyway (no
            // extra I/O), so a replaced memory body leaves no residue for a later forget to miss.
            try run("PRAGMA secure_delete=FAST")
            fenced = true
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }
    deinit { sqlite3_close(handle) }

    private func currentVersion() throws -> Int64 {
        guard let version = try rows("PRAGMA user_version").first?.integers[0] else {
            throw ControllerError.storage(SQLITE_CORRUPT)
        }
        return version
    }

    /// One migration step in its own write transaction. A future schema is refused before any
    /// step runs; a store already at or past `target` is left untouched.
    private func migrate(to target: Int64, _ body: (Int64) throws -> Void) throws {
        try transaction {
            let version = try currentVersion()
            guard (0...Self.schemaVersion).contains(version) else { throw ControllerError.unsupportedSchema }
            guard version < target else { return }
            if version == 0 {
                guard try rows("SELECT name FROM sqlite_master WHERE type='table' LIMIT 1").isEmpty else {
                    throw ControllerError.unsupportedSchema
                }
            }
            try body(version)
            try run("PRAGMA user_version=\(target)")
        }
    }

    struct Row {
        let strings: [String?]
        let integers: [Int64]
        func text(_ column: Int) throws -> String {
            guard let text = strings[column] else { throw ControllerError.storage(SQLITE_CORRUPT) }
            return text
        }
    }
    enum Value {
        case text(String), integer(Int64), null
    }
    func rows(_ sql: String, _ values: [Value] = [], pageByteLimit: Int? = nil) throws -> [Row] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK, let statement else { throw ControllerError.storage(prepared) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let position = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString { sqlite3_bind_text(statement, position, $0, -1, transient) }
            case .integer(let integer): result = sqlite3_bind_int64(statement, position, integer)
            case .null: result = sqlite3_bind_null(statement, position)
            }
            guard result == SQLITE_OK else { throw ControllerError.storage(result) }
        }
        var output: [Row] = []
        var retainedBytes = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw ControllerError.storage(result) }
            // Every caller's SELECT has a LIMIT; this also bounds accidental future queries.
            guard output.count < 101 else { throw ControllerError.invalidInput("query_limit") }
            let count = Int(sqlite3_column_count(statement))
            let rowBytes = (0..<count).reduce(0) { $0 + Int(sqlite3_column_bytes(statement, Int32($1))) }
            if let pageByteLimit, retainedBytes + rowBytes > pageByteLimit {
                guard !output.isEmpty else { throw ControllerError.invalidInput("record_too_large") }
                return output
            }
            guard retainedBytes + rowBytes <= 4_194_304 else { throw ControllerError.invalidInput("query_byte_limit") }
            retainedBytes += rowBytes
            let strings: [String?] = (0..<count).map { index in
                guard let value = sqlite3_column_text(statement, Int32(index)) else { return nil }
                return String(cString: value)
            }
            output.append(Row(strings: strings, integers: (0..<count).map {
                sqlite3_column_int64(statement, Int32($0))
            }))
        }
    }
    func run(_ sql: String, _ values: [Value] = []) throws { _ = try rows(sql, values) }
    /// Rows the most recent INSERT/UPDATE/DELETE changed.
    func changes() -> Int { Int(sqlite3_changes(handle)) }
    struct Statistics: Sendable {
        var commits = 0
        var longestNanoseconds: UInt64 = 0
    }
    /// Write transactions committed and the longest one, since the last reset.
    var statistics = Statistics()
    func transaction<T>(_ body: () throws -> T) throws -> T {
        // Actor-isolated synchronous composition: admission and the existing mutation share
        // one write transaction. Savepoints also roll back a caught inner failure correctly.
        let savepoint = "controller_\(transactionDepth)"
        let outer = transactionDepth == 0
        try run(outer ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        let began = outer ? DispatchTime.now().uptimeNanoseconds : 0
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            // The schema fence, read under the write lock this transaction now holds.
            if outer, fenced, try currentVersion() != Self.schemaVersion { throw ControllerError.unsupportedSchema }
            let result = try body()
            try run(outer ? "COMMIT" : "RELEASE \(savepoint)")
            if outer {
                // How long this connection held the write lock: two integers per commit.
                statistics.commits += 1
                statistics.longestNanoseconds = max(statistics.longestNanoseconds, DispatchTime.now().uptimeNanoseconds - began)
            }
            return result
        } catch {
            // Preserve the originating error; SQLite closes/rolls back an abandoned transaction.
            _ = try? run(outer ? "ROLLBACK" : "ROLLBACK TO \(savepoint)")
            if !outer { _ = try? run("RELEASE \(savepoint)") }
            throw error
        }
    }
}

extension ControllerError {
    /// Another process held the write lock past the busy timeout. The operation changed nothing
    /// and is correct to repeat later; it says nothing about the item being worked on.
    public var isTransientStorage: Bool {
        guard case .storage(let code) = self else { return false }
        let primary = code & ControllerSQLiteCodes.primaryMask
        return primary == SQLITE_BUSY || primary == SQLITE_LOCKED
    }

    /// This process can no longer trust or write the store: it is corrupt, not a database,
    /// read-only, full or failing I/O, or a newer build migrated it underneath. A resident loop
    /// stops on these rather than report supervision it is not doing.
    public var isFatalStorage: Bool {
        if self == .unsupportedSchema { return true }
        guard case .storage(let code) = self else { return false }
        let primary = code & ControllerSQLiteCodes.primaryMask
        return [SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_READONLY, SQLITE_FULL, SQLITE_IOERR,
                SQLITE_CANTOPEN, SQLITE_PERM].contains(primary)
    }
}

enum ControllerSQLiteCodes {
    /// Extended result codes carry the primary code in their low byte.
    static let primaryMask: Int32 = 0xFF
}
