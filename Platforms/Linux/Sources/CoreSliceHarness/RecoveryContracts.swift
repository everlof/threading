@testable import CoreSlice
import Foundation

private enum InjectedFailure: Error { case commitRefused }

/// Exercise the production recovery primitives, not StateManager's platform-specific policy.
func runRecoveryContracts() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-linux-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("recovery.db")
    var refuseNextCommit = false
    let database = try ProjectDatabase(url: url, transactionCommitPreflight: {
        guard refuseNextCommit else { return }
        refuseNextCommit = false
        throw InjectedFailure.commitRefused
    })
    defer { database.close() }
    let session = AgentSession(kind: .claude, title: "Keep this conversation")
    var project = Project(name: "Kept", folderURL: directory)
    project.sessions = [session]
    let state = ProjectsState(projects: [project], selectedSessionID: session.id)
    try database.save(state)
    let receipt = SessionReadReceiptState(sessionID: session.id, completionGeneration: 3,
                                         seenGenerationByParticipant: ["owner": 1])
    try require(try database.saveSessionReadReceiptState(receipt), "seed recovery receipt")
    let observer = try ProjectDatabase(url: url)
    defer { observer.close() }

    // A whole-graph deletion also cascades receipts. A refused commit must undo both.
    refuseNextCommit = true
    do {
        try database.save(ProjectsState(projects: []))
        throw ContractFailure.failed("injected graph commit refusal was ignored")
    } catch InjectedFailure.commitRefused { }
    let retained = try observer.load().state
    try require(retained.projects.map(\.id) == [project.id], "refused deletion retained project")
    try require(retained.projects[0].sessions.map(\.id) == [session.id], "refused deletion retained session")
    try require(retained.selectedSessionID == session.id, "refused deletion retained selection")
    try require(try observer.sessionReadReceiptStates()[session.id] == receipt, "cascade rollback retained receipt")
    // Do not reload the writer before retrying: that would hide an advanced in-memory generation.
    try database.save(state)
    print("PASS graph commit rollback preserves records, receipts and writer generation")

    let inspection = try SQLiteDatabase(path: url.path)
    defer { inspection.close() }
    // Retain a pre-probe graph reader: a probe must not invalidate its graph generation.
    let beforeProbe = try observer.load().state
    refuseNextCommit = true
    do {
        try database.verifyIntegrityAndWritability()
        throw ContractFailure.failed("recovery accepted an uncommitted write probe")
    } catch InjectedFailure.commitRefused { }
    try require(try inspection.scalar("SELECT COUNT(*) FROM app_state WHERE key = 'storageRecoveryProbe'") == 0,
                "refused probe left no temporary row")
    try database.verifyIntegrityAndWritability()
    try require(try inspection.scalar("SELECT COUNT(*) FROM app_state WHERE key = 'storageRecoveryProbe'") == 0,
                "successful probe left no temporary row")
    try observer.save(beforeProbe)
    database.close()
    let reopened = try ProjectDatabase(url: url)
    defer { reopened.close() }
    let recovered = try reopened.load().state
    try require(recovered.projects[0].sessions.map(\.id) == [session.id], "probe retained graph after reopen")
    try require(try reopened.sessionReadReceiptStates()[session.id] == receipt, "probe retained receipt after reopen")
    print("PASS refused recovery probe retries cleanly without changing graph generation")

    // SQLite-valid pages can still carry invalid model JSON. Recovery must reload the graph.
    try inspection.prepare("UPDATE session SET data = ? WHERE id = ?")
        .bind(1, "{ invalid-json").bind(2, session.id.uuidString).run()
    try reopened.verifyIntegrityAndWritability()
    do {
        _ = try reopened.load()
        throw ContractFailure.failed("recovery trusted a corrupt model after a successful SQLite probe")
    } catch ProjectDatabaseLoadError.corruptRow(let table, let id, _) {
        try require(table == "session" && id == session.id.uuidString, "recovery identifies corrupt session")
    }
    try require(try inspection.scalar("SELECT COUNT(*) FROM session") == 1, "recovery refusal preserves corrupt row")
    try require(try reopened.sessionReadReceiptStates()[session.id] == receipt, "recovery refusal preserves receipt")
    print("PASS successful SQLite probe does not substitute for authoritative model reload")
    print("3 project recovery contracts passed")
}
