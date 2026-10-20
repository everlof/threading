#if os(Linux)
import Foundation
import Glibc
@testable import CoreSlice

/// The host-owned mutation behind the session menu's Pin/Unpin row. One indexed record read and
/// one payload write run on a worker while the UI keeps its standing outline responsive.
enum SessionPinAction {
    struct Result: Sendable {
        let changed: Bool
        let pinned: Bool
    }

    static func run(store: String, sessionID: SessionID, pinned: Bool) throws -> Result {
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
              !record.session.isArchived else {
            throw WindowFailure("session is no longer in the navigator")
        }
        var session = record.session
        guard session.isPinned != pinned else { return Result(changed: false, pinned: pinned) }
        session.isPinned = pinned
        try database.saveSession(session, in: record.project.id, position: record.position)
        return Result(changed: true, pinned: pinned)
    }
}
#endif
