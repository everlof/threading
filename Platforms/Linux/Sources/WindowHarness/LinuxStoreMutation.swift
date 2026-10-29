#if os(Linux)
import Foundation
import Glibc
@testable import CoreSlice

/// Opens the Linux host's single-writer store for a short, exact-record mutation.
/// The lock stays held through the caller's operation and closes before UI receipts are applied.
enum LinuxStoreMutation {
    static func withDatabase<Result>(at store: String,
                                     _ operation: (ProjectDatabase) throws -> Result) throws -> Result {
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
        return try operation(database)
    }
}
#endif
