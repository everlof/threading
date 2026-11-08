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
        let lease = try LinuxStoreMutation.acquire(at: root)
        defer { lease.close() }
        let database = try ProjectDatabase(url: file)
        defer { database.close() }
        guard try database.updateProjectExpansion(id: id, expanded: expanded) else {
            throw WindowFailure("project is no longer in this store")
        }
    }
}
