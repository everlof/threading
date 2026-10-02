@testable import CoreSlice
import Foundation

private enum MigrationRefusal: Error { case commit }
private func json<Value: Encodable>(_ value: Value) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

/// Use the production historical DDL, as the shipping migration regression does.
func runMigrationContracts() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-linux-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("version-four.db")
    let manager = AgentSession(kind: .claude, title: "Manager")
    let child = AgentSession(kind: .codex, title: "Child")
    let project = Project(name: "Historical", folderURL: directory)
    var closed = Supervision(managerID: manager.id, childID: child.id,
                             brief: "Old tenure", assignedAt: Date(timeIntervalSince1970: 100))
    closed.state = .released
    closed.closedAt = Date(timeIntervalSince1970: 120)
    closed.outcome = "Completed"
    let event = SupervisionEvent(supervisionID: closed.id, at: Date(timeIntervalSince1970: 120),
                                 kind: .released, detail: closed.outcome)
    let grant = ControlGrant.manager(sessionID: manager.id, projectID: project.id,
                                     maximumPermissionMode: .manual, origin: .newManagerTemplate,
                                     at: Date(timeIntervalSince1970: 90))
    let historical = try SQLiteDatabase(path: url.path)
    defer { historical.close() }
    let steps = [ProjectDatabaseSchema.version1, ProjectDatabaseSchema.version2,
                 ProjectDatabaseSchema.version3, ProjectDatabaseSchema.version4]
    try historical.migrate(to: 4) { try historical.execute(steps[$0 - 1]) }
    try historical.transaction {
        try historical.prepare("INSERT INTO project (id, position, name, folder_path, data) VALUES (?, ?, ?, ?, ?)")
            .bind(1, project.id.uuidString).bind(2, 0).bind(3, project.name)
            .bind(4, project.folderPath).bind(5, try json(project)).run()
        for (position, session) in [manager, child].enumerated() {
            try historical.prepare("INSERT INTO session (id, project_id, position, kind, last_active_at, data) VALUES (?, ?, ?, ?, ?, ?)")
                .bind(1, session.id.uuidString).bind(2, project.id.uuidString).bind(3, position)
                .bind(4, session.kind.rawValue).bind(5, session.lastActiveAt.timeIntervalSince1970)
                .bind(6, try json(session)).run()
        }
        try historical.prepare("INSERT INTO supervision (id, manager_session_id, child_session_id, assigned_at, state, data) VALUES (?, ?, ?, ?, ?, ?)")
            .bind(1, closed.id.uuidString).bind(2, manager.id.uuidString).bind(3, child.id.uuidString)
            .bind(4, closed.assignedAt.timeIntervalSince1970).bind(5, closed.state.rawValue)
            .bind(6, try json(closed)).run()
        try historical.prepare("INSERT INTO supervision_event (id, supervision_id, at, kind, data) VALUES (?, ?, ?, ?, ?)")
            .bind(1, event.id.uuidString.lowercased()).bind(2, closed.id.uuidString)
            .bind(3, event.at.timeIntervalSince1970).bind(4, event.kind.rawValue)
            .bind(5, try json(event)).run()
        try historical.prepare("INSERT INTO control_grant (id, actor_session_id, conferred_at, revoked_at, data) VALUES (?, ?, ?, NULL, ?)")
            .bind(1, grant.id.uuidString).bind(2, manager.id.uuidString)
            .bind(3, grant.conferredAt.timeIntervalSince1970).bind(4, try json(grant)).run()
    }
    historical.close()

    do {
        let refused = try ProjectDatabase(url: url, transactionCommitPreflight: { throw MigrationRefusal.commit })
        refused.close()
        throw ContractFailure.failed("migration ignored commit refusal")
    } catch MigrationRefusal.commit { }
    let inspection = try SQLiteDatabase(path: url.path)
    defer { inspection.close() }
    try require(try inspection.scalar("PRAGMA user_version") == 4, "refused migration retains schema version")
    try require(try inspection.scalar("SELECT COUNT(*) FROM supervision_event") == 1, "refused migration retains history")
    try require(try inspection.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('supervision_v5', 'supervision_event_v5', 'session_attention')") == 0,
                "refused migration rolls back intermediate and later tables")
    try require(try inspection.scalar("PRAGMA foreign_key_check") == nil, "refused migration retains foreign keys")
    print("PASS refused schema migration rolls back DDL, version and history")

    let migrated = try ProjectDatabase(url: url)
    defer { migrated.close() }
    try require(try inspection.scalar("PRAGMA user_version") == ProjectDatabaseSchema.version, "migration reaches current schema")
    try require(try migrated.load().state.projects[0].sessions.map(\.id) == [manager.id, child.id], "migration retains ordered graph")
    try require(try migrated.controlGrants(for: manager.id) == [grant], "migration retains grant")
    try require(try migrated.supervisions(childID: child.id) == [closed], "migration retains closed tenure")
    try require(try migrated.supervisionEvents(for: closed.id) == [event], "migration retains event payload")
    let active = Supervision(managerID: manager.id, childID: child.id,
                             brief: "Readopted", assignedAt: Date(timeIntervalSince1970: 130))
    try migrated.saveSupervision(active)
    let receipt = SessionReadReceiptState(sessionID: child.id, completionGeneration: 1)
    try require(try migrated.saveSessionReadReceiptState(receipt), "new receipt schema works after upgrade")
    migrated.close()
    let reopened = try ProjectDatabase(url: url)
    defer { reopened.close() }
    try require(try reopened.supervisions(childID: child.id) == [closed, active], "reopen retains both tenures")
    try require(try reopened.supervisionEvents(for: closed.id) == [event], "reopen retains historical event")
    try require(try reopened.sessionReadReceiptStates()[child.id] == receipt, "reopen retains new receipt")
    print("PASS schema-4 upgrade preserves authority history and supports readoption and receipts")

    let duplicate = Supervision(managerID: manager.id, childID: child.id,
                                brief: "Must refuse", assignedAt: Date(timeIntervalSince1970: 140))
    do {
        try reopened.saveSupervision(duplicate)
        throw ContractFailure.failed("upgrade allowed two active tenures for one child")
    } catch let failure as SQLiteDatabase.Failure {
        try require(failure.isConstraintViolation, "active-child uniqueness has typed constraint refusal")
    }
    try require(try reopened.supervisions(childID: child.id) == [closed, active], "constraint refusal preserves history")
    var retained = project
    retained.sessions = [child]
    try reopened.save(ProjectsState(projects: [retained]))
    try require(try reopened.controlGrants(for: manager.id).isEmpty, "deleted manager leaves no grant")
    try require(try reopened.supervisions(childID: child.id).isEmpty, "deleted manager leaves no tenure")
    try require(try inspection.scalar("SELECT COUNT(*) FROM supervision_event") == 0, "deleted manager cascades events")
    try require(try reopened.sessionReadReceiptStates()[child.id] == receipt, "surviving child's receipt retained")
    try require(try inspection.scalar("PRAGMA foreign_key_check") == nil, "upgraded store has no dangling references")
    print("PASS upgraded constraints refuse duplicate authority and cascade deleted manager records")
    print("3 project migration contracts passed")
}
