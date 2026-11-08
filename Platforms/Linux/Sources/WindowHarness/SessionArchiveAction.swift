#if os(Linux)
import Foundation
import Glibc
import ThreadingPTYHostKit
@testable import CoreSlice

/// The Linux host's durable half of the session row Archive action. Runs on a utility worker.
/// The store lock covers the provider move and matching row write, so another Linux host cannot
/// change that row between the two sides of the operation.
enum SessionArchiveAction {
    struct Result: Sendable {
        let projectID: ProjectID
        let changed: Bool
    }

    static func run(
        store: String,
        socket: String,
        shell: String,
        sessionID: SessionID,
        archived: Bool,
        changedAt: Date = Date(),
        codexExecutable: String? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Result {
        guard shell.hasPrefix("/") else { throw WindowFailure("archive shell must be absolute") }
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let databaseURL = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw WindowFailure("session store does not exist")
        }
        let lease = try LinuxStoreMutation.acquire(at: root)
        defer { lease.close() }
        let database = try ProjectDatabase(url: databaseURL)
        defer { database.close() }
        guard let record = try database.sessionRecord(id: sessionID) else {
            throw WindowFailure("session is no longer in the store")
        }
        var session = record.session
        guard session.isArchived != archived else {
            return Result(projectID: record.project.id, changed: false)
        }

        let providerBacked = session.kind.supports(.providerArchive)
            && session.resumeState.transcriptID != nil
        if providerBacked {
            guard let transcriptID = session.resumeState.transcriptID,
                  let location = CodexAccountLocations.resolve(session.accountHandle, home: home)
            else { throw WindowFailure("the session's Codex account is unavailable") }
            if archived { stopDaemonWriter(socket: socket, sessionID: sessionID) }
            let account = AgentAccount(provider: session.kind, handle: session.accountHandle,
                                       configPath: location.configPath)
            let snapshot = ProviderArchiveSnapshot.read(account: account, sessionIDs: [transcriptID])
            if snapshot?[transcriptID].archivedValue != archived {
                try runProviderCommand(archived: archived, session: session,
                                       transcriptID: transcriptID, account: account,
                                       shell: shell, executable: codexExecutable)
            }
        }

        guard session.synchronizeArchiveState(archived, at: changedAt) else {
            return Result(projectID: record.project.id, changed: false)
        }
        try database.saveArchivedSession(session, in: record.project.id,
                                         position: record.position)
        if archived && !providerBacked {
            // Local-only archives commit first, matching ProviderArchiveSync on macOS.
            stopDaemonWriter(socket: socket, sessionID: sessionID)
        }
        return Result(projectID: record.project.id, changed: true)
    }

    private static func stopDaemonWriter(socket: String, sessionID: SessionID) {
        guard case .running = GraphicalTerminal.agentPresence(socket: socket, id: sessionID) else {
            return
        }
        _ = PTYHostSessionStop.run(.agentSession(sessionID), socketPath: socket,
                                   build: "linux-native-window")
    }

    private static func runProviderCommand(
        archived: Bool,
        session: AgentSession,
        transcriptID: TranscriptID,
        account: AgentAccount,
        shell: String,
        executable: String?
    ) throws {
        var command = AgentAccountRoute.prefix(for: session.kind,
                                                handle: session.accountHandle,
                                                configPath: account.configPath)
        command.append(word: executable ?? session.kind.executableName)
        command.append(word: archived ? "archive" : "unarchive")
        command.append(word: transcriptID.rawValue)
        let environment = AgentEnvironment.removingInheritedIdentity(
            from: ProcessInfo.processInfo.environment)
        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: shell,
                arguments: ["-l", "-c", command.source],
                environment: environment,
                timeout: ProviderArchiveDefaults.commandTimeout,
                maximumOutputBytes: ProviderArchiveDefaults.maximumCommandOutputBytes
            )
        } catch {
            throw WindowFailure("Codex could not start its archive command: \(error.localizedDescription)")
        }
        guard result.termination == .exited(0) else {
            let reported = String(decoding: result.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = reported.isEmpty ? String(describing: result.termination)
                : String(reported.prefix(ProviderArchiveDefaults.maximumErrorLength))
            throw WindowFailure("Codex could not \(archived ? "archive" : "restore") this conversation: \(detail)")
        }
    }
}
#endif
