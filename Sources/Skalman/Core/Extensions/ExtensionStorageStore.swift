import Foundation
import SkalmanExtensionKit

enum ExtensionStorageStoreError: LocalizedError {
    case persistentStoreTooLarge(identifier: String, maximum: Int)
    case dataVersionRollback(identifier: String, stored: Int, requested: Int)

    var errorDescription: String? {
        switch self {
        case .persistentStoreTooLarge(let identifier, let maximum):
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(maximum),
                countStyle: .file
            )
            return "Extension \(identifier) has a key-value store larger than its \(size) quota."
        case .dataVersionRollback(let identifier, let stored, let requested):
            return "Extension \(identifier) cannot move stored data from version \(stored) "
                + "back to version \(requested)."
        }
    }
}

/// The host's side of brokered key-value storage.
///
/// A protocol so `ExtensionHostService` can be tested without a real Application Support tree,
/// and so the storage that answers a brokered request is visibly the same storage the
/// experimental launcher grants as a directory.
protocol ExtensionKeyValueStoring: AnyObject {
    func keyValues(extensionIdentifier: String) throws -> [String: ExtensionJSONValue]
    func setKeyValue(
        _ value: ExtensionJSONValue,
        extensionIdentifier: String,
        key: String
    ) throws
    func removeKeyValue(extensionIdentifier: String, key: String) throws
}

/// The host's side of brokered cache storage.
protocol ExtensionCacheStoring: AnyObject {
    func cacheNames(extensionIdentifier: String) throws -> [String]
    func cacheData(extensionIdentifier: String, name: String) throws -> Data?
    func setCacheData(_ value: Data, extensionIdentifier: String, name: String) throws
    func removeCacheData(extensionIdentifier: String, name: String) throws
}

/// Allocates host-owned, per-extension storage outside immutable installed packages.
///
/// Two shapes, one state. The experimental `sandbox-exec` launcher grants a directory and the
/// extension writes it; the supported runner grants nothing and the host writes it on the
/// extension's behalf through `ExtensionKeyValueStoring`. Both go through the SDK's own
/// `ExtensionKeyValueStore`, so there is one implementation of the on-disk format rather than a
/// host copy that can drift from the one extensions were tested against.
final class ExtensionStorageStore: ExtensionKeyValueStoring, ExtensionCacheStoring, @unchecked Sendable {
    static let maximumCacheBytes: Int64 = 100 * 1024 * 1024

    let dataURL: URL
    let cachesURL: URL
    let settingsURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private var keyValueStores: [String: ExtensionKeyValueStore] = [:]
    private var cacheStores: [String: ExtensionCacheStore] = [:]

    private struct DataVersionState: Codable {
        static let currentFormatVersion = 1

        let formatVersion: Int
        let dataVersion: Int

        init(dataVersion: Int) {
            formatVersion = Self.currentFormatVersion
            self.dataVersion = dataVersion
        }
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.dataURL = rootURL.appendingPathComponent("Data", isDirectory: true)
        self.cachesURL = rootURL.appendingPathComponent("Caches", isDirectory: true)
        self.settingsURL = rootURL.appendingPathComponent("Settings", isDirectory: true)
        self.fileManager = fileManager
    }

    /// The directories a child is granted, which under the supported runner is none at all.
    ///
    /// App Sandbox cannot express a per-extension writable path, so a descriptor-mode launch
    /// exports nothing and both key-value and cache storage are brokered. `ExtensionCache`'s
    /// raw directory is therefore experimental-launcher only; `ExtensionCacheStore` is the API
    /// that works under both.
    func environment(
        for manifest: ExtensionManifest,
        transport: ExtensionHostTransport = .loopback
    ) throws -> [String: String] {
        guard transport == .loopback else { return [:] }

        lock.lock()
        defer { lock.unlock() }

        var environment: [String: String] = [:]
        if manifest.capabilities.contains(.keyValueStorage) {
            let directory = dataDirectory(for: manifest.identifier)
            try ensurePrivateDirectory(directory)

            let stateFile = directory.appendingPathComponent(
                ExtensionKeyValueStore.stateFileName,
                isDirectory: false
            )
            if let size = try? stateFile.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > ExtensionKeyValueStore.maximumStoreBytes {
                throw ExtensionStorageStoreError.persistentStoreTooLarge(
                    identifier: manifest.identifier,
                    maximum: ExtensionKeyValueStore.maximumStoreBytes
                )
            }
            environment[ExtensionStorageEnvironment.keyValueDirectory] = directory.path
        }

        if manifest.capabilities.contains(.cacheStorage) {
            let directory = cacheDirectory(for: manifest.identifier)
            if try directorySize(directory) > Self.maximumCacheBytes {
                try fileManager.removeItem(at: directory)
            }
            try ensurePrivateDirectory(directory)
            environment[ExtensionStorageEnvironment.cacheDirectory] = directory.path
        }
        return environment
    }

    /// The last schema version whose process completed registration.
    ///
    /// Zero means no extension generation has committed a data version yet. Reading this does
    /// not create storage, so merely inspecting or enabling a package leaves no state behind.
    func committedDataVersion(identifier: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        let url = dataVersionURL(for: identifier)
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        return try JSONDecoder().decode(
            DataVersionState.self,
            from: Data(contentsOf: url)
        ).dataVersion
    }

    /// Records a successful migration/startup atomically.
    ///
    /// Rollback is refused because an older extension cannot prove it understands state already
    /// migrated by a newer schema. The package update itself may still be rolled back when its
    /// `dataVersion` is unchanged.
    func commitDataVersion(_ version: Int, identifier: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let current: Int
        let url = dataVersionURL(for: identifier)
        if fileManager.fileExists(atPath: url.path) {
            current = try JSONDecoder().decode(
                DataVersionState.self,
                from: Data(contentsOf: url)
            ).dataVersion
        } else {
            current = 0
        }
        guard version >= current else {
            throw ExtensionStorageStoreError.dataVersionRollback(
                identifier: identifier,
                stored: current,
                requested: version
            )
        }

        let directory = dataDirectory(for: identifier)
        try ensurePrivateDirectory(directory)
        let data = try JSONEncoder().encode(DataVersionState(dataVersion: version))
        try data.write(to: url, options: .atomic)
    }

    // MARK: - ExtensionKeyValueStoring

    func keyValues(extensionIdentifier: String) throws -> [String: ExtensionJSONValue] {
        let store = try keyValueStore(for: extensionIdentifier)
        return Dictionary(
            uniqueKeysWithValues: try store.keys().map {
                ($0, try store.jsonValue(forKey: $0) ?? .null)
            }
        )
    }

    func setKeyValue(
        _ value: ExtensionJSONValue,
        extensionIdentifier: String,
        key: String
    ) throws {
        try keyValueStore(for: extensionIdentifier).setJSONValue(value, forKey: key)
    }

    func removeKeyValue(extensionIdentifier: String, key: String) throws {
        try keyValueStore(for: extensionIdentifier).removeValue(forKey: key)
    }

    /// One store per extension, retained for the app's lifetime.
    ///
    /// The store holds the decoded state in memory, so building a fresh one per request would
    /// re-read and re-decode the file on every `get`. Retaining it also means the host and the
    /// brokered extension share one view of the state rather than two that can disagree.
    private func keyValueStore(for identifier: String) throws -> ExtensionKeyValueStore {
        lock.lock()
        defer { lock.unlock() }
        if let existing = keyValueStores[identifier] {
            return existing
        }
        let store = try ExtensionKeyValueStore(
            directoryURL: dataDirectory(for: identifier)
        )
        keyValueStores[identifier] = store
        return store
    }

    // MARK: - ExtensionCacheStoring

    func cacheNames(extensionIdentifier: String) throws -> [String] {
        try cacheStore(for: extensionIdentifier).names()
    }

    func cacheData(extensionIdentifier: String, name: String) throws -> Data? {
        try cacheStore(for: extensionIdentifier).data(forName: name)
    }

    func setCacheData(_ value: Data, extensionIdentifier: String, name: String) throws {
        let directory = cacheDirectory(for: extensionIdentifier)
        let store = try cacheStore(for: extensionIdentifier)

        // The 100 MiB ceiling is checked per write, not only at launch. A brokered extension
        // never restarts to have its cache reclaimed, so a launch-time sweep alone would let it
        // grow without bound for as long as the app stays open.
        let replaced = ((try? store.data(forName: name)) ?? nil)?.count ?? 0
        let projected = try directorySize(directory) - Int64(replaced) + Int64(value.count)
        guard projected <= Self.maximumCacheBytes else {
            throw ExtensionStorageError.quotaExceeded(
                maximumBytes: Int(Self.maximumCacheBytes)
            )
        }
        try store.setData(value, forName: name)
    }

    func removeCacheData(extensionIdentifier: String, name: String) throws {
        try cacheStore(for: extensionIdentifier).removeData(forName: name)
    }

    private func cacheStore(for identifier: String) throws -> ExtensionCacheStore {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cacheStores[identifier] {
            return existing
        }
        let store = try ExtensionCacheStore(directoryURL: cacheDirectory(for: identifier))
        cacheStores[identifier] = store
        return store
    }

    /// Drops the retained stores so a removed or reinstalled extension does not keep answering
    /// from the state of a directory that has moved.
    func forgetStores(identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        keyValueStores.removeValue(forKey: identifier)
        cacheStores.removeValue(forKey: identifier)
    }

    func dataDirectory(for identifier: String) -> URL {
        dataURL.appendingPathComponent(identifier, isDirectory: true)
    }

    private func dataVersionURL(for identifier: String) -> URL {
        dataDirectory(for: identifier)
            .appendingPathComponent("data-version.json", isDirectory: false)
    }

    func cacheDirectory(for identifier: String) -> URL {
        cachesURL.appendingPathComponent(identifier, isDirectory: true)
    }

    /// Moves private state beside a recoverable removed package instead of destroying it.
    func recover(identifier: String, alongside packageURL: URL) throws {
        forgetStores(identifier: identifier)
        lock.lock()
        defer { lock.unlock() }

        let recovery = Self.recoveryURL(alongside: packageURL)
        let data = dataDirectory(for: identifier)
        let cache = cacheDirectory(for: identifier)
        let settings = settingsDirectory(for: identifier)
        guard fileManager.fileExists(atPath: data.path)
                || fileManager.fileExists(atPath: cache.path)
                || fileManager.fileExists(atPath: settings.path) else {
            return
        }

        try fileManager.createDirectory(
            at: recovery,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if fileManager.fileExists(atPath: data.path) {
            try fileManager.moveItem(
                at: data,
                to: recovery.appendingPathComponent("Data", isDirectory: true)
            )
        }
        if fileManager.fileExists(atPath: cache.path) {
            try fileManager.moveItem(
                at: cache,
                to: recovery.appendingPathComponent("Cache", isDirectory: true)
            )
        }
        if fileManager.fileExists(atPath: settings.path) {
            try fileManager.moveItem(
                at: settings,
                to: recovery.appendingPathComponent("Settings", isDirectory: true)
            )
        }
    }

    static func recoveryURL(alongside packageURL: URL) -> URL {
        packageURL.deletingPathExtension().appendingPathExtension("storage")
    }

    func settingsDirectory(for identifier: String) -> URL {
        settingsURL.appendingPathComponent(identifier, isDirectory: true)
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func directorySize(_ directory: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
                if total > Self.maximumCacheBytes {
                    return total
                }
            }
        }
        return total
    }
}
