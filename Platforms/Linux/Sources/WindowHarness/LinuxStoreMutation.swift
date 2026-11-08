#if os(Linux)
import Foundation
import Glibc
@testable import CoreSlice

/// Opens the Linux host's single-writer store for a short, exact-record mutation.
/// The lock stays held through the caller's operation and closes before UI receipts are applied.
enum LinuxStoreMutation {
    private static let writers = WriterRegistry()

    /// All registry state is protected by `condition`; leases stay on their acquiring worker.
    private final class WriterRegistry: @unchecked Sendable {
        private let condition = NSCondition()
        private var activeStores: Set<String> = []

        func acquire(_ path: String, wait: Bool) throws {
            let deadline = Date().addingTimeInterval(5)
            condition.lock()
            defer { condition.unlock() }
            while activeStores.contains(path) {
                guard wait, condition.wait(until: deadline) else {
                    throw WindowFailure("session store is busy")
                }
            }
            activeStores.insert(path)
        }

        func release(_ path: String) {
            condition.lock()
            activeStores.remove(path)
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Separate workers in this process share the store; another host still must fail the
    /// nonblocking OS lock. Keep only active owners, and bound waits to SQLite's own budget.
    static func acquire(at root: URL, waitForLocalWriter: Bool = true) throws -> Lease {
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        try writers.acquire(path, wait: waitForLocalWriter)
        do {
            return try Lease(path: path)
        } catch {
            writers.release(path)
            throw error
        }
    }

    final class Lease {
        private let path: String
        private var descriptor: Int32

        fileprivate init(path: String) throws {
            self.path = path
            descriptor = Glibc.open(path + "/host.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw WindowFailure("cannot open session store lock") }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                Glibc.close(descriptor)
                descriptor = -1
                throw WindowFailure("session store is already owned")
            }
        }

        func close() {
            guard descriptor >= 0 else { return }
            Glibc.close(descriptor)
            descriptor = -1
            LinuxStoreMutation.writers.release(path)
        }

        deinit { close() }
    }

    static func withDatabase<Result>(at store: String,
                                     _ operation: (ProjectDatabase) throws -> Result) throws -> Result {
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let databaseURL = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw WindowFailure("session store does not exist")
        }
        let lease = try acquire(at: root)
        defer { lease.close() }
        let database = try ProjectDatabase(url: databaseURL)
        defer { database.close() }
        return try operation(database)
    }
}
#endif
