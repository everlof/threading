import Foundation
import SQLite3

// Real SQLiteDatabase and ThreadingLogger sources are symlinked from the verified core slice.
// These are storage-engine contracts, not a substitute for the still-blocked ProjectDatabase test.
// Every case owns a disposable directory. No production path or shared preferences are opened.
enum ContractFailure: Error, CustomStringConvertible {
    case expectation(String)
    case injectedCommitFailure

    var description: String {
        switch self {
        case .expectation(let message): return message
        case .injectedCommitFailure: return "injected commit failure"
        }
    }
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ContractFailure.expectation(message) }
}

func fixture(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-sqlite-contract-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory.appendingPathComponent("fixture.db"))
}

func textScalar(_ database: SQLiteDatabase, _ sql: String) throws -> String? {
    let query = try database.prepare(sql)
    defer { query.finalize() }
    return try query.step() ? query.text(0) : nil
}

func expectConstraint(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as SQLiteDatabase.Failure {
        try require(error.isConstraintViolation, "constraint error lost its native classification")
        try require(!error.isStorageExhausted, "constraint error misclassified as full disk")
        return
    }
    throw ContractFailure.expectation("invalid write unexpectedly succeeded")
}

let contracts: [(String, (URL) throws -> Void)] = [
    ("save, close and reopen preserves bound values", { url in
        let text = "Threading — café 日本語 🧵"
        let bytes = Data([0, 255, 128, 1, 0])
        let largeInteger = Int64.max - 1
        let database = try SQLiteDatabase(path: url.path)
        defer { database.close() }
        try require(try textScalar(database, "PRAGMA journal_mode") == "wal", "WAL was not enabled")
        try database.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY, text TEXT, blob BLOB, number INTEGER, fraction REAL, absent TEXT)")
        try database.transaction {
            try database.prepare("INSERT INTO sample VALUES (?, ?, ?, ?, ?, ?)")
                .bind(1, 1).bind(2, text).bind(3, bytes).bind(4, largeInteger)
                .bind(5, 1.25).bind(6, nil as String?).run()
        }
        database.close()
        let reopened = try SQLiteDatabase(path: url.path)
        defer { reopened.close() }
        let query = try reopened.prepare("SELECT text, blob, number, fraction, absent FROM sample WHERE id = 1")
        defer { query.finalize() }
        try require(try query.step(), "committed row disappeared on reopen")
        try require(query.text(0) == text, "Unicode text changed")
        try require(query.data(0) == Data(text.utf8), "TEXT-to-Data bytes changed")
        try require(query.data(1) == bytes, "binary payload changed")
        try require(query.int(2) == Int(largeInteger), "64-bit integer narrowed")
        try require(query.double(3) == 1.25, "floating-point binding changed")
        try require(query.text(4) == nil && query.data(4) == nil, "NULL became an empty value")
        try require(try !query.step(), "unexpected duplicate row")
    }),
    ("statement reset clears bindings and owners finalize", { url in
        let database = try SQLiteDatabase(path: url.path)
        defer { database.close() }
        try database.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY, value TEXT)")
        do {
            let insert = try database.prepare("INSERT INTO sample VALUES (?, ?)")
            try insert.bind(1, 1).bind(2, "previous").step()
            try insert.reset()
            try insert.bind(1, 2).step()
        }
        try require(!database.hasOpenStatements, "statement outlived its Swift owner")
        try require(try database.scalar("SELECT count(*) FROM sample WHERE id = 2 AND value IS NULL") == 1,
                    "reset retained the previous row's binding")
        let query = try database.prepare("SELECT '' AS empty_text, NULL AS absent")
        try require(try query.step(), "literal query returned no row")
        try require(query.data(0) == Data() && query.data(1) == nil, "empty TEXT and NULL were conflated")
        query.finalize()
        query.finalize()
        try require(!database.hasOpenStatements, "explicit finalization leaked a statement")
        database.close()
        database.close()
    }),
    ("constraint refusal rolls back the entire transaction", { url in
        let database = try SQLiteDatabase(path: url.path)
        defer { database.close() }
        try database.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY)")
        try database.execute("INSERT INTO sample VALUES (1)")
        try expectConstraint {
            try database.transaction {
                try database.execute("INSERT INTO sample VALUES (2)")
                try database.execute("INSERT INTO sample VALUES (1)")
            }
        }
        try require(try database.scalar("SELECT count(*) FROM sample") == 1, "partial transaction persisted")
        try database.transaction { try database.execute("INSERT INTO sample VALUES (3)") }
        try require(try database.scalar("SELECT count(*) FROM sample") == 2, "refusal poisoned later writes")
    }),
    ("commit failure rolls back before publication", { url in
        let database = try SQLiteDatabase(path: url.path, transactionCommitPreflight: {
            throw ContractFailure.injectedCommitFailure
        })
        defer { database.close() }
        try database.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY)")
        do {
            try database.transaction { try database.execute("INSERT INTO sample VALUES (1)") }
            throw ContractFailure.expectation("commit preflight did not refuse")
        } catch ContractFailure.injectedCommitFailure {}
        database.close()
        let reopened = try SQLiteDatabase(path: url.path)
        defer { reopened.close() }
        try require(try reopened.scalar("SELECT count(*) FROM sample") == 0, "failed commit survived reopen")
    }),
    ("foreign keys refuse orphans and cascade deletes", { url in
        let database = try SQLiteDatabase(path: url.path)
        defer { database.close() }
        try database.execute("CREATE TABLE parent (id INTEGER PRIMARY KEY)")
        try database.execute("CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id) ON DELETE CASCADE)")
        try expectConstraint { try database.execute("INSERT INTO child VALUES (1, 99)") }
        try database.transaction {
            try database.execute("INSERT INTO parent VALUES (1)")
            try database.execute("INSERT INTO child VALUES (1, 1)")
        }
        try database.execute("DELETE FROM parent WHERE id = 1")
        try require(try database.scalar("SELECT count(*) FROM child") == 0, "cascade left an orphan")
    }),
    ("migration steps and version roll back together", { url in
        let database = try SQLiteDatabase(path: url.path)
        defer { database.close() }
        do {
            try database.migrate(to: 2) { version in
                if version == 1 { try database.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY)") }
                else { throw ContractFailure.injectedCommitFailure }
            }
            throw ContractFailure.expectation("failed migration succeeded")
        } catch ContractFailure.injectedCommitFailure {}
        try require(try database.scalar("PRAGMA user_version") == 0, "failed migration advanced the version")
        try require(try database.scalar("SELECT count(*) FROM sqlite_master WHERE name = 'sample'") == 0,
                    "failed migration left schema changes behind")
        var steps: [Int] = []
        try database.migrate(to: 2) { version in
            steps.append(version)
            if version == 1 { try database.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY)") }
            else { try database.execute("ALTER TABLE sample ADD COLUMN value TEXT") }
        }
        try require(steps == [1, 2], "migration order changed")
        try database.migrate(to: 2) { _ in throw ContractFailure.expectation("migration ran twice") }
        database.close()
        let reopened = try SQLiteDatabase(path: url.path, maximumSchemaVersion: 2)
        defer { reopened.close() }
        try require(try reopened.scalar("PRAGMA user_version") == 2, "migration version did not persist")
    }),
    ("future schema is refused without modifying the file", { url in
        let database = try SQLiteDatabase(path: url.path)
        try database.execute("PRAGMA user_version = 9")
        try require(database.prepareForFileMove(), "could not checkpoint fixture")
        database.close()
        let original = try Data(contentsOf: url)
        do {
            let future = try SQLiteDatabase(path: url.path, maximumSchemaVersion: 2)
            future.close()
            throw ContractFailure.expectation("future schema was accepted")
        } catch SQLiteDatabase.Failure.newerSchema(let found, let supported) {
            try require(found == 9 && supported == 2, "wrong schema refusal")
        }
        try require(try Data(contentsOf: url) == original, "future database bytes changed")
        for suffix in ["-wal", "-shm"] {
            try require(!FileManager.default.fileExists(atPath: url.path + suffix), "future open created a sidecar")
        }
    }),
    ("pinned WAL refuses a file move until the reader closes", { url in
        let writer = try SQLiteDatabase(path: url.path)
        defer { writer.close() }
        try writer.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY)")
        try writer.execute("INSERT INTO sample VALUES (1)")
        let reader = try SQLiteDatabase(path: url.path)
        defer { reader.close() }
        try reader.execute("BEGIN")
        try require(try reader.scalar("SELECT count(*) FROM sample") == 1, "reader snapshot missing")
        try writer.execute("INSERT INTO sample VALUES (2)")
        try require(!writer.prepareForFileMove(), "move allowed while another connection pinned the WAL")
        try reader.execute("ROLLBACK")
        reader.close()
        try require(writer.prepareForFileMove(), "move stayed refused after reader closed")
        writer.close()
        let movedURL = url.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: url, to: movedURL)
        let reopened = try SQLiteDatabase(path: movedURL.path)
        defer { reopened.close() }
        try require(try reopened.scalar("SELECT count(*) FROM sample") == 2, "file move lost committed WAL rows")
    }),
    ("SQLITE_FULL is typed and leaves committed rows readable", { url in
        // Bound SQLite's page allocation, not the host disk: a 64 KiB write reliably exceeds
        // this two-page fixture without exhausting storage belonging to any other process.
        let database = try SQLiteDatabase(path: url.path)
        defer { database.close() }
        try database.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY, payload BLOB)")
        try database.execute("INSERT INTO sample VALUES (1, X'01')")
        let pages = try database.scalar("PRAGMA page_count")!
        try database.execute("PRAGMA max_page_count = \(pages)")
        do {
            try database.transaction { try database.execute("INSERT INTO sample VALUES (2, zeroblob(65536))") }
            throw ContractFailure.expectation("page limit did not produce SQLITE_FULL")
        } catch let error as SQLiteDatabase.Failure {
            try require(error.isStorageExhausted, "SQLITE_FULL lost its native classification")
            try require(!error.isConstraintViolation, "full disk misclassified as a constraint")
        }
        try require(try database.scalar("SELECT count(*) FROM sample") == 1, "full-disk write changed committed rows")
        try database.execute("PRAGMA max_page_count = \(pages + 32)")
        try database.transaction { try database.execute("INSERT INTO sample VALUES (2, zeroblob(65536))") }
        try require(try database.scalar("SELECT count(*) FROM sample") == 2, "writes did not recover after lifting limit")
    }),
]

print("SQLite \(String(cString: sqlite3_libversion())) — production wrapper contracts")
for (name, body) in contracts {
    try fixture(body)
    print("PASS: \(name)")
}
print("\(contracts.count) storage contracts passed; run CoreSliceHarness separately for project graph contracts")
