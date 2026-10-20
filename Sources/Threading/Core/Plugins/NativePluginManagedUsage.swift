import Foundation

/// Remembers which optional first-party plugins the person installed. A successful app update
/// re-fetches only these identifiers. The record grants no trust: every installed build still
/// needs its signed manifest and notarized code at load time.
enum NativePluginManagedUsage {
    enum UsageError: Error { case capacityReached }

    struct State: Codable, Sendable {
        var schemaVersion = 1
        var identifiers: [String] = []
        var lastRefreshedBuild: String?
    }

    private static let storage = Storage()

    static func buildKey(for app: URL) -> String? {
        NativePluginDistribution.manifestURL(for: app)?.absoluteString
    }

    static func read(in directory: URL) throws -> State {
        try storage.read(in: directory)
    }

    static func record(_ identifier: String, in directory: URL) throws {
        try storage.update(in: directory) { state in
            guard !state.identifiers.contains(identifier) else { return }
            guard state.identifiers.count < 32 else { throw UsageError.capacityReached }
            state.identifiers.append(identifier)
            state.identifiers.sort()
        }
    }

    static func markRefreshed(_ build: String, in directory: URL) throws {
        try storage.update(in: directory) { $0.lastRefreshedBuild = build }
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()

        func read(in directory: URL) throws -> State {
            lock.lock()
            defer { lock.unlock() }
            return try readUnlocked(in: directory)
        }

        func update(in directory: URL, change: (inout State) throws -> Void) throws {
            lock.lock()
            defer { lock.unlock() }
            var state = try readUnlocked(in: directory)
            try change(&state)
            let managed = NativePluginManagedPaths.managedDirectory(in: directory)
            try FileManager.default.createDirectory(
                at: managed, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoded = try JSONEncoder().encode(state)
            try encoded.write(to: file(in: directory), options: .atomic)
        }

        private func readUnlocked(in directory: URL) throws -> State {
            let url = file(in: directory)
            guard FileManager.default.fileExists(atPath: url.path) else { return State() }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: 8 * 1024 + 1),
                  data.count <= 8 * 1024,
                  let state = try? JSONDecoder().decode(State.self, from: data),
                  state.schemaVersion == 1,
                  state.identifiers.count <= 32 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return state
        }

        private func file(in directory: URL) -> URL {
            NativePluginManagedPaths.managedDirectory(in: directory)
                .appendingPathComponent("usage.json")
        }
    }
}
