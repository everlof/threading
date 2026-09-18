@testable import CoreSlice
import Foundation

/// Verify the project-store move primitive without emulating StateManager's quarantine policy.
func runFileMoveContracts() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-linux-move-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for corrupt in [false, true] {
        let directory = root.appendingPathComponent(corrupt ? "corrupt" : "healthy", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("projects.db")
        let movedURL = directory.appendingPathComponent("preserved.db")
        let writer = try ProjectDatabase(url: url)
        defer { writer.close() }
        let first = AgentSession(kind: .claude, title: "Before reader")
        let latest = AgentSession(kind: .codex, title: "Committed while reader held WAL")
        var project = Project(name: "Preserved", folderURL: directory)
        project.sessions = [first]
        try writer.save(ProjectsState(projects: [project], selectedSessionID: first.id))
        let reader = try SQLiteDatabase(path: url.path)
        defer { reader.close() }
        try reader.execute("BEGIN")
        try require(try reader.scalar("SELECT COUNT(*) FROM session") == 1, "reader pins initial graph")
        project.sessions.append(latest)
        try writer.save(ProjectsState(projects: [project], selectedSessionID: latest.id))
        let receipt = SessionReadReceiptState(sessionID: latest.id, completionGeneration: 7,
                                             seenGenerationByParticipant: ["owner": 4])
        try require(try writer.saveSessionReadReceiptState(receipt), "receipt committed to WAL")
        // These are opaque storage payloads, deliberately not a claim about panel/attachment codecs.
        let panel = "opaque panel — preserve verbatim"
        let attachments = "opaque attachments — preserve verbatim"
        try writer.savePanelPayload(panel, for: latest.id)
        try writer.saveAttachmentsPayload(attachments, for: latest.id)
        let damagedPayload = "{ deliberately broken session JSON"
        if corrupt {
            let mutation = try SQLiteDatabase(path: url.path)
            defer { mutation.close() }
            try mutation.prepare("UPDATE session SET data = ? WHERE id = ?")
                .bind(1, damagedPayload).bind(2, latest.id.uuidString).run()
            mutation.close()
        }
        try require(try reader.scalar("SELECT COUNT(*) FROM session") == 1, "reader still observes old snapshot")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        try require(names.contains("projects.db-wal") && names.contains("projects.db-shm"), "fixture holds WAL sidecars")
        try require(!writer.prepareForFileMove(), "project move refused while reader holds WAL")
        try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names,
                    "refused move leaves database bundle in place")
        try require(try reader.scalar("SELECT COUNT(*) FROM session") == 1, "refused move preserves reader snapshot")
        try reader.execute("ROLLBACK")
        reader.close()

        try require(writer.prepareForFileMove(), "project move becomes safe after reader closes")
        writer.close()
        for suffix in ["-wal", "-shm"] {
            try require(!FileManager.default.fileExists(atPath: url.path + suffix), "checkpoint removes dependence on sidecars")
        }
        // Move only the main file. A successful reopen must not depend on the original WAL paths.
        try FileManager.default.moveItem(at: url, to: movedURL)
        try require(!FileManager.default.fileExists(atPath: url.path), "original main file was moved")
        let moved = try ProjectDatabase(url: movedURL)
        defer { moved.close() }
        if corrupt {
            do {
                _ = try moved.load()
                throw ContractFailure.failed("file move concealed corrupt session")
            } catch ProjectDatabaseLoadError.corruptRow(let table, let id, _) {
                try require(table == "session" && id == latest.id.uuidString, "moved corruption identifies original row")
            }
            let inspection = try SQLiteDatabase(path: movedURL.path)
            defer { inspection.close() }
            let payload = try inspection.prepare("SELECT data FROM session WHERE id = ?")
                .bind(1, latest.id.uuidString)
            defer { payload.finalize() }
            try require(try payload.step(), "moved corrupt row exists")
            try require(payload.text(0) == damagedPayload, "move preserves exact damaged payload for recovery")
            try require(try inspection.scalar("SELECT COUNT(*) FROM session") == 2, "move retains both healthy and damaged rows")
        } else {
            let state = try moved.load().state
            try require(state.projects.map(\.id) == [project.id], "move retains project identity")
            try require(state.projects[0].sessions.map(\.id) == [first.id, latest.id], "move folds latest WAL session into main file")
            try require(state.projects[0].sessions[1].title == latest.title, "move retains latest session payload")
            try require(state.selectedSessionID == latest.id, "move retains latest selection")
        }
        try require(try moved.sessionReadReceiptStates()[latest.id] == receipt, "move retains latest receipt")
        try require(try moved.panelPayload(for: latest.id) == panel, "move retains opaque panel payload")
        try require(try moved.attachmentsPayload(for: latest.id) == attachments, "move retains opaque attachment payload")
        print("PASS pinned project WAL refuses move, then checkpoints and relocates \(corrupt ? "damaged" : "healthy") state intact")
    }
    print("2 project file-move contracts passed")
}
