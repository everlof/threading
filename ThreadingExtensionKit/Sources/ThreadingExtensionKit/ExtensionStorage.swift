import Foundation

/// Environment variables Threading supplies only for declared storage capabilities.
///
/// A directory is granted only by the experimental `sandbox-exec` launcher. The supported
/// runner grants none: App Sandbox cannot express "this child may write this one directory",
/// and a shared writable grant would let an extension that guessed a sibling's identifier read
/// its private state. Storage is brokered over the host connection instead — see
/// `docs/extensions/SANDBOX_RUNNER.md`.
public enum ExtensionStorageEnvironment {
    public static let keyValueDirectory = "THREADING_EXTENSION_KEY_VALUE_DIRECTORY"
    public static let cacheDirectory = "THREADING_EXTENSION_CACHE_DIRECTORY"
}

/// The whole key-value store, as the host reports it.
///
/// It is fetched in one call rather than per key because the store is capped at 1 MiB: paging a
/// bounded document costs round trips to reproduce a dictionary the extension is about to hold
/// in memory anyway.
public struct ExtensionKeyValueSnapshot: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let values: [String: ExtensionJSONValue]

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        values: [String: ExtensionJSONValue]
    ) {
        self.protocolVersion = protocolVersion
        self.values = values
    }
}

/// One key-value write, brokered by the host.
public struct ExtensionKeyValueWrite: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let value: ExtensionJSONValue

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        value: ExtensionJSONValue
    ) {
        self.protocolVersion = protocolVersion
        self.value = value
    }
}

public enum ExtensionStorageError: LocalizedError, Equatable {
    case unavailable(String)
    case invalidKey
    case invalidName
    case incompatibleFormat(Int)
    case unreadable(String)
    case tooManyKeys(maximum: Int)
    case quotaExceeded(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let capability):
            return "The extension does not have access to \(capability)."
        case .invalidKey:
            return "Storage keys must contain 1–512 UTF-8 bytes and no control characters."
        case .invalidName:
            return "Cache names must be a single path component of 1–255 UTF-8 bytes, "
                + "with no separators or control characters."
        case .incompatibleFormat(let version):
            return "The extension key-value store uses unsupported format version \(version)."
        case .unreadable(let message):
            return "The extension key-value store could not be read: \(message)"
        case .tooManyKeys(let maximum):
            return "The extension key-value store cannot contain more than \(maximum) keys."
        case .quotaExceeded(let maximumBytes):
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(maximumBytes),
                countStyle: .file
            )
            return "The extension key-value store exceeds its \(size) quota."
        }
    }
}

/// A small, persistent JSON/Codable store private to one installed extension.
///
/// The API is the same whichever way the state reaches disk. Under the supported runner an
/// extension has no writable path at all, so every mutation is brokered by the host; under the
/// experimental `sandbox-exec` launcher Threading grants one directory and the extension writes a
/// bounded state file atomically itself. Both are capability-gated on `storage.kv`, and the
/// host retains the state across disable, reload, update, and app restart.
///
/// The brokered calls are synchronous rather than `async` on purpose: storage has always been a
/// blocking API because it was file I/O, and an extension's serve loop is an ordinary
/// `readLine` loop. Making a stored counter async would be a large break for no gain.
public final class ExtensionKeyValueStore: @unchecked Sendable {
    public static let maximumKeys = 2_048
    public static let maximumStoreBytes = 1024 * 1024
    public static let stateFileName = "values.json"

    private struct State: Codable {
        static let currentFormatVersion = 1

        var formatVersion = currentFormatVersion
        var values: [String: ExtensionJSONValue] = [:]
    }

    private enum Backing {
        case directory(stateURL: URL, fileManager: FileManager)
        case broker(ExtensionKeyValueBroker)
    }

    private let backing: Backing
    private let lock = NSLock()
    private var state: State

    /// Prefers the host broker, and falls back to a granted directory.
    ///
    /// The precedence matches `ExtensionHostConnection`'s: a process that was handed a broker
    /// was launched by the runner, and the runner grants no writable path.
    public convenience init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        if let broker = ExtensionKeyValueBroker(environment: environment) {
            try self.init(broker: broker)
            return
        }
        guard let path = environment[ExtensionStorageEnvironment.keyValueDirectory],
              !path.isEmpty else {
            throw ExtensionStorageError.unavailable("persistent key-value storage")
        }
        try self.init(directoryURL: URL(fileURLWithPath: path, isDirectory: true))
    }

    init(broker: ExtensionKeyValueBroker) throws {
        self.backing = .broker(broker)
        let snapshot = try broker.snapshot()
        guard snapshot.protocolVersion == ExtensionKeyValueSnapshot.currentProtocolVersion else {
            throw ExtensionStorageError.incompatibleFormat(snapshot.protocolVersion)
        }
        guard snapshot.values.count <= Self.maximumKeys else {
            throw ExtensionStorageError.tooManyKeys(maximum: Self.maximumKeys)
        }
        self.state = State(values: snapshot.values)
    }

    /// The directory backing, used by the experimental launcher, by the host on an extension's
    /// behalf, and by tests. Extensions should use `init(environment:)`.
    public init(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let stateURL = directoryURL.appendingPathComponent(
            Self.stateFileName,
            isDirectory: false
        )
        self.backing = .directory(stateURL: stateURL, fileManager: fileManager)

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if fileManager.fileExists(atPath: stateURL.path) {
                let data = try Data(contentsOf: stateURL)
                guard data.count <= Self.maximumStoreBytes else {
                    throw ExtensionStorageError.quotaExceeded(
                        maximumBytes: Self.maximumStoreBytes
                    )
                }
                let decoded = try JSONDecoder().decode(State.self, from: data)
                guard decoded.formatVersion == State.currentFormatVersion else {
                    throw ExtensionStorageError.incompatibleFormat(decoded.formatVersion)
                }
                guard decoded.values.count <= Self.maximumKeys else {
                    throw ExtensionStorageError.tooManyKeys(maximum: Self.maximumKeys)
                }
                state = decoded
            } else {
                state = State()
            }
        } catch let error as ExtensionStorageError {
            throw error
        } catch {
            throw ExtensionStorageError.unreadable(error.localizedDescription)
        }
    }

    public func jsonValue(forKey key: String) throws -> ExtensionJSONValue? {
        try Self.validate(key: key)
        lock.lock()
        defer { lock.unlock() }
        return state.values[key]
    }

    public func setJSONValue(_ value: ExtensionJSONValue, forKey key: String) throws {
        try Self.validate(key: key)
        lock.lock()
        defer { lock.unlock() }

        var candidate = state
        if candidate.values[key] == nil, candidate.values.count >= Self.maximumKeys {
            throw ExtensionStorageError.tooManyKeys(maximum: Self.maximumKeys)
        }
        candidate.values[key] = value

        // The local copy is updated only after the write is accepted, whichever backing
        // accepted it. A refused write must leave the extension's view matching the host's.
        switch backing {
        case .directory:
            try persist(candidate)
        case .broker(let broker):
            try broker.write(value, forKey: key)
        }
        state = candidate
    }

    public func removeValue(forKey key: String) throws {
        try Self.validate(key: key)
        lock.lock()
        defer { lock.unlock() }

        guard state.values[key] != nil else { return }
        var candidate = state
        candidate.values.removeValue(forKey: key)
        switch backing {
        case .directory:
            try persist(candidate)
        case .broker(let broker):
            try broker.remove(forKey: key)
        }
        state = candidate
    }

    public func keys(withPrefix prefix: String? = nil) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return state.values.keys
            .filter { prefix.map($0.hasPrefix) ?? true }
            .sorted()
    }

    public func value<Value: Decodable>(
        forKey key: String,
        as type: Value.Type = Value.self
    ) throws -> Value? {
        guard let value = try jsonValue(forKey: key) else { return nil }
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func set<Value: Encodable>(_ value: Value, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        let jsonValue = try JSONDecoder().decode(ExtensionJSONValue.self, from: data)
        try setJSONValue(jsonValue, forKey: key)
    }

    private func persist(_ candidate: State) throws {
        guard case .directory(let stateURL, let fileManager) = backing else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(candidate)
        guard data.count <= Self.maximumStoreBytes else {
            throw ExtensionStorageError.quotaExceeded(
                maximumBytes: Self.maximumStoreBytes
            )
        }
#if os(WASI)
        try data.write(to: stateURL)
#else
        try data.write(to: stateURL, options: .atomic)
#endif
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
    }

    /// Public because the host enforces the same rule on a brokered write. Two copies of a key
    /// rule is how the two ends come to disagree about what a valid key is.
    public static func validate(key: String) throws {
        let byteCount = key.lengthOfBytes(using: .utf8)
        guard byteCount > 0,
              byteCount <= 512,
              key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw ExtensionStorageError.invalidKey
        }
    }
}

/// The host-owned directory for disposable extension data.
///
/// Available only under the experimental `sandbox-exec` launcher. The supported runner grants
/// no writable path, so a runner-launched extension gets `unavailable` here and should use
/// `ExtensionCacheStore`, which works under both.
public enum ExtensionCache {
    public static func directoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let path = environment[ExtensionStorageEnvironment.cacheDirectory],
              !path.isEmpty else {
            throw ExtensionStorageError.unavailable("cache storage")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// The names of every cache entry an extension currently holds.
public struct ExtensionCacheListing: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let names: [String]

    public init(protocolVersion: Int = Self.currentProtocolVersion, names: [String]) {
        self.protocolVersion = protocolVersion
        self.names = names
    }
}

/// One cache entry, or its absence. A miss is a value, not an error: an extension is required
/// to tolerate every entry disappearing between accesses.
public struct ExtensionCacheEntry: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let value: Data?

    public init(protocolVersion: Int = Self.currentProtocolVersion, value: Data?) {
        self.protocolVersion = protocolVersion
        self.value = value
    }
}

/// One cache write, brokered by the host.
public struct ExtensionCacheWrite: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let value: Data

    public init(protocolVersion: Int = Self.currentProtocolVersion, value: Data) {
        self.protocolVersion = protocolVersion
        self.value = value
    }
}

/// Disposable, per-extension storage addressed by name.
///
/// This replaces handing an extension a directory, because the supported runner cannot grant
/// one: App Sandbox has no way to say "this child may write this path and no other", and the
/// blanket grant that would be needed instead is one an extension could walk sideways through
/// to a sibling's data. Under the experimental launcher it reads and writes the granted
/// directory; under the runner the host does it. One API either way.
///
/// It is a **byte API keyed by name, not a filesystem**. Handing back an open descriptor per
/// file would need `SCM_RIGHTS`, which is ancillary data the broker's HTTP framing cannot
/// carry — a second framing on one socket is precisely the hazard that framing exists to
/// avoid. An extension that needs to stream more than `maximumEntryBytes` at a time needs a
/// durable large-file surface, which this deliberately is not: Threading may delete any entry at
/// any moment.
public final class ExtensionCacheStore: @unchecked Sendable {
    /// Large enough for a downloaded asset or a serialized index, small enough that one entry
    /// still fits a single brokered request once base64 has inflated it by a third.
    public static let maximumEntryBytes = 4 * 1024 * 1024
    public static let maximumNameBytes = 255

    private enum Backing {
        case directory(URL, FileManager)
        case broker(ExtensionCacheBroker)
    }

    private let backing: Backing

    /// Prefers the host broker, and falls back to a granted directory — the same precedence
    /// `ExtensionKeyValueStore` and `ExtensionHostConnection` use, for the same reason.
    public convenience init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        if let broker = ExtensionCacheBroker(environment: environment) {
            self.init(broker: broker)
            return
        }
        try self.init(directoryURL: ExtensionCache.directoryURL(environment: environment))
    }

    public init(directoryURL: URL, fileManager: FileManager = .default) throws {
        self.backing = .directory(directoryURL, fileManager)
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ExtensionStorageError.unreadable(error.localizedDescription)
        }
    }

    init(broker: ExtensionCacheBroker) {
        self.backing = .broker(broker)
    }

    public func data(forName name: String) throws -> Data? {
        try Self.validate(name: name)
        switch backing {
        case .directory(let directory, let fileManager):
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            do {
                return try Data(contentsOf: url)
            } catch {
                // A cache read that fails is a cache miss. The entry may have been reclaimed
                // between the existence check and the read, which is normal here.
                return nil
            }
        case .broker(let broker):
            return try broker.data(forName: name)
        }
    }

    public func setData(_ value: Data, forName name: String) throws {
        try Self.validate(name: name)
        guard value.count <= Self.maximumEntryBytes else {
            throw ExtensionStorageError.quotaExceeded(maximumBytes: Self.maximumEntryBytes)
        }
        switch backing {
        case .directory(let directory, _):
            do {
#if os(WASI)
                try value.write(
                    to: directory.appendingPathComponent(name, isDirectory: false)
                )
#else
                try value.write(
                    to: directory.appendingPathComponent(name, isDirectory: false),
                    options: .atomic
                )
#endif
            } catch {
                throw ExtensionStorageError.unreadable(error.localizedDescription)
            }
        case .broker(let broker):
            try broker.setData(value, forName: name)
        }
    }

    public func removeData(forName name: String) throws {
        try Self.validate(name: name)
        switch backing {
        case .directory(let directory, let fileManager):
            try? fileManager.removeItem(
                at: directory.appendingPathComponent(name, isDirectory: false)
            )
        case .broker(let broker):
            try broker.removeData(forName: name)
        }
    }

    public func names() throws -> [String] {
        switch backing {
        case .directory(let directory, let fileManager):
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile == true }
                .map(\.lastPathComponent)
                .sorted()
        case .broker(let broker):
            return try broker.names()
        }
    }

    /// A name is one path component and nothing else.
    ///
    /// This is the whole of the traversal defence on the extension's side, and the host repeats
    /// it — the broker takes a name from a request body, and a broker that trusted its caller's
    /// path would be a write primitive rather than a cache.
    public static func validate(name: String) throws {
        let byteCount = name.lengthOfBytes(using: .utf8)
        guard byteCount > 0,
              byteCount <= maximumNameBytes,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw ExtensionStorageError.invalidName
        }
    }
}
