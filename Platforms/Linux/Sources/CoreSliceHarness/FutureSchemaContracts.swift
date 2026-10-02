@testable import CoreSlice
import Foundation

private func refuseFutureProjectStore(at url: URL, version: Int) throws {
    var attemptedCommit = false
    do {
        let unexpected = try ProjectDatabase(url: url, transactionCommitPreflight: {
            attemptedCommit = true
        })
        unexpected.close()
        throw ContractFailure.failed("future project schema was accepted")
    } catch SQLiteDatabase.Failure.newerSchema(let found, let supported) {
        try require(found == version && supported == ProjectDatabaseSchema.version,
                    "future refusal reports exact found/supported versions")
    }
    try require(!attemptedCommit, "future schema reached a migration commit")
}

/// A downgrade must refuse the actual project-store constructor before configuring or migrating it.
func runFutureSchemaContracts() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-linux-future-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let futureVersion = ProjectDatabaseSchema.version + 1
    for liveWAL in [false, true] {
        let directory = root.appendingPathComponent(liveWAL ? "wal" : "checkpointed", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("projects.db")
        let project = Project(name: "Newer build", folderURL: directory)
        let seed = try ProjectDatabase(url: url)
        defer { seed.close() }
        try seed.save(ProjectsState(projects: [project]))
        seed.close()
        let newerWriter = try SQLiteDatabase(path: url.path)
        defer { newerWriter.close() }
        try newerWriter.execute("PRAGMA wal_autocheckpoint = 0")
        try newerWriter.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try newerWriter.transaction {
            try newerWriter.execute("CREATE TABLE future_only (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
            try newerWriter.execute("INSERT INTO future_only VALUES (1, 'keep this unknown data')")
            try newerWriter.execute("PRAGMA user_version = \(futureVersion)")
        }
        if !liveWAL {
            try require(newerWriter.prepareForFileMove(), "checkpoint future fixture")
            newerWriter.close()
        }
        let original = try Data(contentsOf: url)
        // SQLite stores user_version in bytes 60–63, big-endian. Prove the WAL case cannot be
        // detected from the main file alone, rather than merely testing a WAL-named database.
        let mainVersion = original[60..<64].reduce(0) { ($0 << 8) | Int($1) }
        try require(mainVersion == (liveWAL ? ProjectDatabaseSchema.version : futureVersion),
                    "future fixture uses the intended journal layout")
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let originalWAL = liveWAL ? try Data(contentsOf: walURL) : nil
        if let originalWAL { try require(!originalWAL.isEmpty, "future schema has live WAL frames") }
        let originalNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        for _ in 0..<3 {
            try refuseFutureProjectStore(at: url, version: futureVersion)
            try require(try Data(contentsOf: url) == original, "downgrade changed main database bytes")
            if let originalWAL {
                try require(try Data(contentsOf: walURL) == originalWAL, "downgrade changed committed WAL bytes")
            }
            try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == originalNames,
                        "downgrade created, moved or removed database artifacts")
        }
        if liveWAL {
            try newerWriter.execute("UPDATE future_only SET value = 'writer still usable' WHERE id = 1")
            newerWriter.close()
        }
        let inspection = try SQLiteDatabase(path: url.path)
        defer { inspection.close() }
        try require(try inspection.scalar("PRAGMA user_version") == futureVersion, "future version retained")
        try require(try inspection.scalar("SELECT COUNT(*) FROM project") == 1, "future project retained")
        let value = try inspection.prepare("SELECT value FROM future_only WHERE id = 1")
        defer { value.finalize() }
        try require(try value.step(), "unknown future record retained")
        try require(value.text(0) == (liveWAL ? "writer still usable" : "keep this unknown data"),
                    "unknown future payload retained and newer writer remains usable")
        print("PASS future project schema refused without data loss (\(liveWAL ? "live WAL" : "checkpointed"))")
    }
    print("2 future-schema contracts passed")
}
