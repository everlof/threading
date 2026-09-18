// Debug-only integration harness: access the exact production records without widening their API.
@testable import CoreSlice
import Foundation

enum ContractFailure: Error { case failed(String) }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ContractFailure.failed(message) }
}

func runContracts() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-linux-projects-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("projects.db")
    let original = try ProjectDatabase(url: url)
    defer { original.close() }
    try require(try original.isEmpty(), "new database must be empty")
    let first = AgentSession(kind: .claude, title: "First — 日本語")
    let second = AgentSession(kind: .codex, title: "Second")
    var alpha = Project(name: "alpha", folderURL: directory)
    alpha.sessions = [first, second]
    alpha.executionHost = ProjectExecutionHost(destination: "builder", remoteDirectory: "/srv/project")
    let beta = Project(name: "beta", folderURL: directory)
    try original.save(ProjectsState(projects: [alpha, beta], selectedSessionID: second.id))
    original.close()

    let database = try ProjectDatabase(url: url)
    defer { database.close() }
    let restored = try database.load().state
    try require(restored.projects.map(\.id) == [alpha.id, beta.id], "project order after reopen")
    try require(restored.projects[0].sessions.map(\.id) == [first.id, second.id], "session order after reopen")
    try require(restored.projects[0].sessions[0].title == first.title, "Unicode payload after reopen")
    try require(restored.projects[0].executionHost == alpha.executionHost, "remote execution record after reopen")
    try require(restored.selectedSessionID == second.id, "selection after reopen")
    print("PASS project graph save/close/reopen")

    var renamed = second
    renamed.title = "Renamed"
    try database.saveSession(renamed, in: alpha.id, position: 1)
    let changed = try database.load().state
    try require(changed.projects[0].sessions.map(\.title) == [first.title, renamed.title], "single-session update")
    try require(changed.projects[1].id == beta.id, "unrelated project retained")
    print("PASS incremental session update")

    let stale = try ProjectDatabase(url: url)
    defer { stale.close() }
    let staleState = try stale.load().state
    let gamma = Project(name: "gamma", folderURL: directory)
    try database.save(ProjectsState(projects: changed.projects + [gamma], selectedSessionID: first.id))
    do {
        try stale.save(staleState)
        throw ContractFailure.failed("stale graph writer was accepted")
    } catch ProjectDatabaseWriteError.staleGeneration { }
    try require(try database.load().state.projects.map(\.id) == [alpha.id, beta.id, gamma.id],
                "stale refusal preserves newly added project")
    print("PASS stale graph writer refused")

    let receipt = SessionReadReceiptState(sessionID: first.id, completionGeneration: 4,
                                         seenGenerationByParticipant: ["owner": 4, "guest": 2])
    try require(try database.saveSessionReadReceiptState(receipt), "receipt committed")
    let observer = try ProjectDatabase(url: url)
    defer { observer.close() }
    try require(try observer.sessionReadReceiptStates()[first.id] == receipt, "receipt visible on separate connection")
    alpha.sessions = [renamed]
    try database.save(ProjectsState(projects: [alpha, beta], selectedSessionID: second.id))
    try require(try observer.sessionReadReceiptStates().isEmpty, "receipt cascades with deleted session")
    print("PASS participant receipts persist and cascade")

    let raw = try SQLiteDatabase(path: url.path)
    defer { raw.close() }
    try raw.prepare("UPDATE session SET data = ? WHERE id = ?")
        .bind(1, "{ not-json").bind(2, second.id.uuidString).run()
    do {
        _ = try database.load()
        throw ContractFailure.failed("corrupt graph was accepted")
    } catch ProjectDatabaseLoadError.corruptRow(let table, let id, _) {
        try require(table == "session" && id == second.id.uuidString, "corrupt row identity")
    }
    let count = try raw.prepare("SELECT COUNT(*) FROM session")
    defer { count.finalize() }
    try require(try count.step() && count.int(0) == 1, "failed load preserves corrupt row")
    print("PASS corrupt graph refused without deleting rows")
    print("5 project persistence contracts passed")
}

do {
    try runContracts()
    try runRecoveryContracts()
    try runMigrationContracts()
    try runFutureSchemaContracts()
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
