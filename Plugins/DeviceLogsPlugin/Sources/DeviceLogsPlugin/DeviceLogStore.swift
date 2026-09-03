import Foundation
import SQLite3

/// Tells SQLite to copy a bound string, the same spelling the app's own store uses.
private let transientText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Every row a session has seen, on disk and searchable.
///
/// The pane keeps a bounded ring so a firehose cannot grow memory; that ring is why "what happened
/// at 14:02" had no answer once 50,000 rows had gone by. This is the other half: rows land here as
/// well, so search, a time range, and hiding rows that can come back are queries rather than scans
/// of whatever is still in memory.
///
/// Modelled on Timber's `LogDatabase` — the schema, the trigram tokenizer, the pragmas and the
/// batched transaction are its design, arrived at against real files. Two things differ. The RAG
/// half (chunks, embeddings) is not here because nothing asks for it yet. And the instant is stored
/// in **milliseconds**: Timber stores `Int64(timeIntervalSince1970)`, whole seconds, which throws
/// away exactly the sub-second ordering the relay's six fractional digits provide.
public final class DeviceLogStore {

    public enum StoreError: Error {
        case open(String)
        case prepare(String)
        case step(String)
    }

    private var handle: OpaquePointer?
    private var insert: OpaquePointer?
    /// Row ids are ours rather than SQLite's, so a caller can name a row before it is written.
    private var nextID: Int64 = 1

    public let url: URL

    public init(url: URL) throws {
        self.url = url
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw StoreError.open(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
        }
        handle = db
        try configure()
        try createSchema()
        try prepareInsert()
    }

    deinit {
        sqlite3_finalize(insert)
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: - Setup

    private func configure() throws {
        // WAL so a reader never blocks the writer: the agent searches while the stream is still
        // arriving. NORMAL rather than FULL because a log is evidence, not a ledger — losing the
        // last few rows to a power cut costs nothing worth an fsync per transaction.
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA cache_size=-64000")
        try execute("PRAGMA temp_store=MEMORY")
    }

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS rows (
                id INTEGER PRIMARY KEY,
                instant_ms INTEGER,
                clock TEXT NOT NULL,
                level TEXT NOT NULL,
                severity INTEGER NOT NULL,
                process TEXT NOT NULL,
                subsystem TEXT,
                message TEXT NOT NULL
            )
        """)
        // A range query filters on the instant, and a level filter on severity. Neither is an FTS
        // column, and an FTS5 table indexes nothing but its own text — so these are stated here or
        // every filtered query is a table scan.
        try execute("CREATE INDEX IF NOT EXISTS idx_rows_instant ON rows(instant_ms)")
        try execute("CREATE INDEX IF NOT EXISTS idx_rows_severity ON rows(severity)")

        // Trigram, not the default tokenizer. A log is searched for `fCli`, `0x16f95` and
        // `com.apple.xpc` — substrings inside identifiers — and a word tokenizer finds none of them.
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS rows_fts USING fts5(
                message,
                content='rows',
                content_rowid='id',
                tokenize='trigram'
            )
        """)
        for trigger in [
            """
            CREATE TRIGGER IF NOT EXISTS rows_ai AFTER INSERT ON rows BEGIN
                INSERT INTO rows_fts(rowid, message) VALUES (new.id, new.message);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS rows_ad AFTER DELETE ON rows BEGIN
                INSERT INTO rows_fts(rows_fts, rowid, message) VALUES('delete', old.id, old.message);
            END
            """,
        ] {
            try execute(trigger)
        }
    }

    private func prepareInsert() throws {
        let sql = """
            INSERT INTO rows (id, instant_ms, clock, level, severity, process, subsystem, message)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &insert, nil) == SQLITE_OK else {
            throw StoreError.prepare(lastMessage)
        }
    }

    // MARK: - Writing

    /// Writes a batch inside one transaction.
    ///
    /// One transaction per batch rather than per row is the whole difference: the pane already
    /// drains on a timer, so batches arrive naturally and this is the shape the stream produces.
    @discardableResult
    public func append(_ batch: [DeviceLogRow]) throws -> Int64 {
        guard !batch.isEmpty, let insert else { return nextID }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for row in batch {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                sqlite3_bind_int64(insert, 1, nextID)
                if let instant = row.timestamp {
                    sqlite3_bind_int64(insert, 2, Int64((instant.timeIntervalSince1970 * 1000).rounded()))
                } else {
                    sqlite3_bind_null(insert, 2)
                }
                sqlite3_bind_text(insert, 3, row.time, -1, transientText)
                sqlite3_bind_text(insert, 4, row.level, -1, transientText)
                sqlite3_bind_int64(insert, 5, Int64(row.severity))
                sqlite3_bind_text(insert, 6, row.process, -1, transientText)
                if let subsystem = row.subsystem {
                    sqlite3_bind_text(insert, 7, subsystem, -1, transientText)
                } else {
                    sqlite3_bind_null(insert, 7)
                }
                sqlite3_bind_text(insert, 8, row.message, -1, transientText)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw StoreError.step(lastMessage) }
                nextID += 1
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return nextID
    }

    /// Drops the oldest rows beyond `limit`. The FTS index follows through the delete trigger.
    public func trim(to limit: Int) throws {
        try execute("""
            DELETE FROM rows WHERE id <= (SELECT MAX(id) FROM rows) - \(limit)
        """)
    }

    // MARK: - Reading

    public func count() throws -> Int {
        try scalar("SELECT COUNT(*) FROM rows").map(Int.init) ?? 0
    }

    /// Row ids whose message contains `text`.
    public func search(_ text: String, limit: Int = 1_000) throws -> [Int64] {
        let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        return try ids(
            "SELECT rowid FROM rows_fts WHERE rows_fts MATCH '\"\(escaped)\"' ORDER BY rowid LIMIT \(limit)"
        )
    }

    /// Row ids written between two instants, inclusive. Rows with no instant are not in a range.
    public func ids(from start: Date, to end: Date, limit: Int = 10_000) throws -> [Int64] {
        let lower = Int64((start.timeIntervalSince1970 * 1000).rounded())
        let upper = Int64((end.timeIntervalSince1970 * 1000).rounded())
        return try ids("""
            SELECT id FROM rows WHERE instant_ms BETWEEN \(lower) AND \(upper)
            ORDER BY id LIMIT \(limit)
        """)
    }

    /// Row ids at or above a severity, for "errors only".
    public func ids(atLeast severity: Int, limit: Int = 10_000) throws -> [Int64] {
        try ids("SELECT id FROM rows WHERE severity >= \(severity) ORDER BY id LIMIT \(limit)")
    }

    public func row(_ id: Int64) throws -> DeviceLogRow? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT clock, level, process, subsystem, message, instant_ms FROM rows WHERE id = \(id)"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepare(lastMessage)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        let instant = sqlite3_column_type(statement, 5) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 5)) / 1000)
        return DeviceLogRow(
            time: text(0) ?? "",
            level: text(1) ?? "",
            process: text(2) ?? "",
            subsystem: text(3),
            message: text(4) ?? "",
            timestamp: instant
        )
    }

    // MARK: - Plumbing

    private var lastMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.step(lastMessage)
        }
    }

    private func scalar(_ sql: String) throws -> Int64? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepare(lastMessage)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func ids(_ sql: String) throws -> [Int64] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepare(lastMessage)
        }
        var found: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            found.append(sqlite3_column_int64(statement, 0))
        }
        return found
    }
}
