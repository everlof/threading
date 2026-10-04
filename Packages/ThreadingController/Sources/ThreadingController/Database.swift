import Foundation
import CControllerSQLite

/// Owned by ControllerStore's actor. Each operation uses a bounded prepared statement; separate
/// CLI processes coordinate through SQLite BEGIN IMMEDIATE, not a read/modify/write snapshot.
final class ControllerDatabase {
    private var handle: OpaquePointer?
    private var transactionDepth = 0
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
            sqlite3_busy_timeout(handle, 3_000)
            try transaction {
                let version = try rows("PRAGMA user_version").first?.integers[0]
                guard let version, (0...10).contains(version) else { throw ControllerError.unsupportedSchema }
                if version == 0 {
                    guard try rows("SELECT name FROM sqlite_master WHERE type='table' LIMIT 1").isEmpty else {
                        throw ControllerError.unsupportedSchema
                    }
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
                if version < 3 {
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
                    try run("PRAGMA user_version=3")
                }
                if version < 4 {
                    try run("""
                        UPDATE record SET scope=(SELECT parent FROM record AS work
                            WHERE work.kind='work' AND work.id=record.parent)
                        WHERE kind='question'
                        """)
                    guard try rows("SELECT id FROM record WHERE kind='question' AND scope IS NULL LIMIT 1").isEmpty else {
                        throw ControllerError.storage(SQLITE_CORRUPT)
                    }
                    try run("CREATE INDEX unresolved_delivery ON record(sequence) WHERE kind='delivery' AND state IN ('pending','sending','uncertain')")
                    try run("PRAGMA user_version=4")
                }
                if version < 5 {
                    try run("CREATE TABLE automation_due (id TEXT PRIMARY KEY, due INTEGER NOT NULL)")
                    try run("CREATE INDEX automation_due_time ON automation_due(due,id)")
                    try run("PRAGMA user_version=5")
                }
            }
            let current = try rows("PRAGMA user_version").first?.integers[0] ?? 0
            if current < 6 {
                try run("CREATE INDEX IF NOT EXISTS automation_worker_active ON record(json_extract(payload,'$.spec.workerID')) WHERE kind='automation' AND json_extract(payload,'$.enabled')=1")
                try run("PRAGMA user_version=6")
            }
            if current < 7 {
                // Agent mail. Open mail is read by recipient through a partial index, so an inbox
                // never walks acknowledged history; the outbound queue is per destination host.
                try transaction {
                    try run("CREATE INDEX IF NOT EXISTS mail_open ON record(parent,sequence) WHERE kind='mail' AND state IN ('inbox','noticed')")
                    try run("CREATE INDEX IF NOT EXISTS mail_wake ON record(sequence) WHERE kind='mail' AND state IN ('inbox','noticed') AND json_extract(payload,'$.wake')=1")
                    try run("CREATE TABLE IF NOT EXISTS mail_outbound (sequence INTEGER PRIMARY KEY AUTOINCREMENT, host TEXT NOT NULL, message TEXT NOT NULL UNIQUE)")
                    try run("CREATE INDEX IF NOT EXISTS mail_outbound_host ON mail_outbound(host,sequence)")
                    try run("PRAGMA user_version=7")
                }
            }
            if current < 8 {
                // Trigger sources: when each enabled source next polls, read by due time only.
                try transaction {
                    try run("CREATE TABLE IF NOT EXISTS source_due (id TEXT PRIMARY KEY, due INTEGER NOT NULL)")
                    try run("CREATE INDEX IF NOT EXISTS source_due_time ON source_due(due,id)")
                    try run("CREATE INDEX IF NOT EXISTS trigger_source ON record(parent,sequence) WHERE kind='trigger'")
                    try run("PRAGMA user_version=8")
                }
            }
            if current < 9 {
                // Usage receipts: executions owed a receipt, and per-day cells a range reads.
                try transaction {
                    try run("CREATE TABLE IF NOT EXISTS usage_pending (execution TEXT PRIMARY KEY)")
                    try run("""
                        CREATE TABLE IF NOT EXISTS usage_daily (day TEXT NOT NULL, worker TEXT NOT NULL, account TEXT NOT NULL,
                        model TEXT NOT NULL, uncached INTEGER NOT NULL, cached INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                        output INTEGER NOT NULL, reasoning INTEGER NOT NULL, cost REAL NOT NULL, requests INTEGER NOT NULL,
                        executions INTEGER NOT NULL, PRIMARY KEY(day,worker,account,model))
                        """)
                    try run("CREATE INDEX IF NOT EXISTS usage_daily_worker ON usage_daily(worker,day)")
                    try run("PRAGMA user_version=9")
                }
            }
            if current < 10 {
                try transaction {
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
                    try run("PRAGMA user_version=10")
                }
            }
            try run("PRAGMA journal_mode=WAL")
            try run("PRAGMA synchronous=FULL")
            // Overwritten and deleted cells are zeroed inside the page being written anyway (no
            // extra I/O), so a replaced memory body leaves no residue for a later forget to miss.
            try run("PRAGMA secure_delete=FAST")
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }
    deinit { sqlite3_close(handle) }

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
