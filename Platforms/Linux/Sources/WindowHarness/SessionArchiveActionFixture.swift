#if os(Linux)
import Foundation
@testable import CoreSlice

enum SessionArchiveActionFixture {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-linux-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let projectFolder = root.appendingPathComponent("project", isDirectory: true)
        let account = home.appendingPathComponent(".codex-test", isDirectory: true)
        let active = account.appendingPathComponent("sessions", isDirectory: true)
        let archived = account.appendingPathComponent("archived_sessions", isDirectory: true)
        for directory in [store, home, projectFolder, active, archived] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: account.appendingPathComponent("auth.json"))

        let transcriptID = TranscriptID("019f8e9e-5101-7033-922d-916884a443a7")
        let rolloutName = "rollout-\(transcriptID.rawValue).jsonl"
        let activeRollout = active.appendingPathComponent(rolloutName)
        let archivedRollout = archived.appendingPathComponent(rolloutName)
        try Data("{}\n".utf8).write(to: activeRollout)
        let command = root.appendingPathComponent("codex-archive-fixture")
        let script = """
        #!/bin/sh
        if [ -f "$CODEX_HOME/refuse" ]; then echo 'fixture refusal' >&2; exit 9; fi
        printf '%s\\n' "$1" >> "$CODEX_HOME/commands"
        if [ "$1" = archive ]; then
          mv "$CODEX_HOME/sessions/rollout-$2.jsonl" "$CODEX_HOME/archived_sessions/rollout-$2.jsonl"
        else
          mv "$CODEX_HOME/archived_sessions/rollout-$2.jsonl" "$CODEX_HOME/sessions/rollout-$2.jsonl"
        fi
        """
        try Data(script.utf8).write(to: command, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)

        let project = Project(name: "Archive", folderURL: projectFolder)
        guard var codex = AgentSessionCreation.makeRecord(kind: .codex,
            accountHandle: .named("codex-test")),
              let claude = AgentSessionCreation.makeRecord(kind: .claude)
        else { preconditionFailure("archive fixture sessions were not admitted") }
        codex.resumeState = .resumable(transcriptID)
        let databaseURL = store.appendingPathComponent("threading.db")
        do {
            let database = try ProjectDatabase(url: databaseURL)
            defer { database.close() }
            try database.addProject(project, position: 0)
            try database.addSession(codex, to: project.id, position: 0,
                                    selectNewSession: true)
            try database.addSession(claude, to: project.id, position: 1)
        }

        let socket = root.appendingPathComponent("missing-pty.sock").path
        let first = try SessionArchiveAction.run(store: store.path, socket: socket, shell: "/bin/sh",
            sessionID: codex.id, archived: true, codexExecutable: command.path, home: home)
        precondition(first.changed && first.projectID == project.id &&
                     !FileManager.default.fileExists(atPath: activeRollout.path) &&
                     FileManager.default.fileExists(atPath: archivedRollout.path),
                     "Codex archive did not move its rollout")
        let repeated = try SessionArchiveAction.run(store: store.path, socket: socket, shell: "/bin/sh",
            sessionID: codex.id, archived: true, codexExecutable: command.path, home: home)
        precondition(!repeated.changed, "repeated archive changed the row")
        let restored = try SessionArchiveAction.run(store: store.path, socket: socket, shell: "/bin/sh",
            sessionID: codex.id, archived: false, codexExecutable: command.path, home: home)
        precondition(restored.changed && FileManager.default.fileExists(atPath: activeRollout.path),
                     "Codex restore did not recover its rollout")
        let local = try SessionArchiveAction.run(store: store.path, socket: socket, shell: "/bin/sh",
            sessionID: claude.id, archived: true, home: home)
        precondition(local.changed, "local-only archive was refused")
        try Data().write(to: account.appendingPathComponent("refuse"))
        do {
            _ = try SessionArchiveAction.run(store: store.path, socket: socket, shell: "/bin/sh",
                sessionID: codex.id, archived: true, codexExecutable: command.path, home: home)
            preconditionFailure("rejected provider command archived the session")
        } catch { /* A rejected provider command must leave the local row and rollout active. */ }
        let database = try ProjectDatabase(url: databaseURL)
        defer { database.close() }
        let codexRecord = try database.sessionRecord(id: codex.id)?.session
        let claudeRecord = try database.sessionRecord(id: claude.id)?.session
        let selectedAfterArchive = try database.load().state.selectedSessionID
        precondition(codexRecord?.isArchived == false &&
                     codexRecord?.lastSynchronizedArchiveState == false &&
                     codexRecord?.archivedAt == nil &&
                     claudeRecord?.isArchived == true && claudeRecord?.archivedAt != nil &&
                     selectedAfterArchive == nil &&
                     FileManager.default.fileExists(atPath: activeRollout.path),
                     "provider refusal or local archive left the durable store inconsistent")
        let calls = try String(contentsOf: account.appendingPathComponent("commands"), encoding: .utf8)
        precondition(calls == "archive\nunarchive\n", "provider command ran for an idempotent action")
        print("PASS account-routed archive/restore, local-only archive, provider refusal and durable state")
    }
}
#endif
