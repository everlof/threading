import Darwin
import Foundation

// MARK: - Snapshot

/// The `initialize` and `tools/list` results from the last connection that succeeded.
struct CatalogueSnapshot: Sendable, Equatable {
    var initializeResult: Data?
    var toolsListResult: Data?

    var isEmpty: Bool { initializeResult == nil && toolsListResult == nil }
}

// MARK: - Cache

/// The catalogue the bridge answers a handshake from when the app is not running.
///
/// **Why a file and not only memory.** The case this exists for is a CLI *starting* while
/// Threading is closed, and the CLI starts the bridge — so the bridge's memory is empty at
/// exactly the moment the answer is needed. The file is the only thing that survives from the
/// last time the app was open.
///
/// **Why the results are stored verbatim rather than a tool list.** Nothing in this binary knows
/// what a tool is, and that is the drift rule from the feature draft: a catalogue compiled in
/// here would be a second copy of `MCPToolCatalog` that goes stale without anything failing. The
/// bridge stores the two answers as bytes and repeats them; the app remains the only author.
///
/// The path is chosen by the app and passed on the command line. The bridge has no path policy:
/// one decision, made where the session's other per-session files are already written.
final class CatalogueCache: @unchecked Sendable {

    // MARK: - Properties

    private let url: URL
    private let lock = NSLock()

    // MARK: - Initialization

    init(path: String) {
        url = URL(fileURLWithPath: path)
    }

    // MARK: - Public Methods

    /// Reads the cache, answering an empty snapshot for anything unreadable.
    ///
    /// Deliberately total: a truncated, corrupt or foreign file is treated as no cache at all and
    /// is overwritten by the next successful connect. There is nothing here worth failing a
    /// launch over — the worst case is one handshake that lists no tools.
    func load() -> CatalogueSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object[Key.version] as? Int == Self.version else {
            return CatalogueSnapshot()
        }
        return CatalogueSnapshot(
            initializeResult: Self.reserialize(object[Key.initializeResult]),
            toolsListResult: Self.reserialize(object[Key.toolsListResult])
        )
    }

    /// Writes the snapshot, owner-readable only, replacing whatever was there.
    ///
    /// The temporary file is created with `0600` *before* it has content and renamed into place,
    /// so there is no moment at which a complete cache is world-readable and no moment at which a
    /// reader can see half a file. A failure is reported and dropped: the bridge works without a
    /// cache, and refusing to serve a session because a cache could not be written would trade a
    /// degraded case for a broken one.
    @discardableResult
    func store(_ snapshot: CatalogueSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var object: [String: Any] = [Key.version: Self.version]
        if let initializeResult = snapshot.initializeResult,
           let value = try? JSONSerialization.jsonObject(with: initializeResult) {
            object[Key.initializeResult] = value
        }
        if let toolsListResult = snapshot.toolsListResult,
           let value = try? JSONSerialization.jsonObject(with: toolsListResult) {
            object[Key.toolsListResult] = value
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else {
            return false
        }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )

        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(getpid()).tmp"
        )
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: Self.filePermissions]
        ) else {
            return false
        }
        // `createFile` sets the mode after creating, so state it once more where nothing can be
        // between: this is the permission the test asserts and the reason the file is not shared.
        _ = chmod(temporary.path, mode_t(Self.filePermissions))

        // `rename(2)` rather than `FileManager.replaceItemAt`, which requires the destination to
        // already exist — the first write of a cache is exactly the case where it does not — and
        // which would replace the mode set above with the original's.
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        return true
    }

    // MARK: - Private Methods

    private static let version = 1
    private static let filePermissions = 0o600
    private static let directoryPermissions = 0o700

    private enum Key {
        static let version = "version"
        static let initializeResult = "initializeResult"
        static let toolsListResult = "toolsListResult"
    }

    /// Turns a decoded JSON value back into the bytes the bridge repeats. Only an object is
    /// accepted, because both cached values are JSON-RPC `result` objects.
    ///
    /// Sorted keys, matching how a freshly fetched result is canonicalised. Without that a
    /// loaded snapshot could never compare equal to the same catalogue fetched again, and every
    /// launch would rewrite this file once for nothing.
    private static func reserialize(_ value: Any?) -> Data? {
        guard let object = value as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
