#if os(Linux)
import Foundation
import Glibc
import ThreadingPTYHostKit
@testable import CoreSlice

/// Revalidates the exact saved row before stopping its daemon child. Closing keeps the record
/// and provider transcript intact; the window releases its cached presentation on success.
enum SessionCloseAction {
    static func run(store: String, socket: String, sessionID: SessionID,
                    projectID: ProjectID, stopHostedChild: Bool) throws {
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let databaseURL = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw WindowFailure("session store does not exist")
        }
        let lock = Glibc.open(root.appendingPathComponent("host.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw WindowFailure("cannot open session store lock") }
        defer { Glibc.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw WindowFailure("session store is already owned")
        }
        let database = try ProjectDatabase(url: databaseURL)
        defer { database.close() }
        guard let record = try database.sessionRecord(id: sessionID),
              record.project.id == projectID, !record.session.isArchived else {
            throw WindowFailure("session is no longer in this project")
        }
        guard stopHostedChild else { return }

        switch GraphicalTerminal.agentPresence(socket: socket, id: sessionID) {
        case .absent, .exited:
            return
        case .running:
            guard PTYHostSessionStop.run(.agentSession(sessionID), socketPath: socket,
                                         build: "linux-native-window") else {
                throw WindowFailure("the hosted agent did not confirm its exit")
            }
        case .unavailable:
            throw WindowFailure("the session host could not confirm whether the agent is running")
        }
    }
}
#endif
