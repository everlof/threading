import Foundation
import Glibc
@testable import CoreSlice

/// Called only by the bounded disclosure worker, never by the UI actor.
enum NavigatorExpansionStore {
    static func save(store: String, projectID: String, expanded: Bool) throws {
        guard let id = ProjectID(uuidString: projectID) else {
            throw WindowFailure("invalid project identity")
        }
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let file = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw WindowFailure("store does not exist")
        }
        let lock = Glibc.open(root.appendingPathComponent("host.lock").path,
                             O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw WindowFailure("store is already owned")
        }
        let database = try ProjectDatabase(url: file)
        defer { database.close() }
        guard try database.updateProjectExpansion(id: id, expanded: expanded) else {
            throw WindowFailure("project is no longer in this store")
        }
    }
}
