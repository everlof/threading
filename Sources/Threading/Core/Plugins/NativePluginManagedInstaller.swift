import Darwin
import Foundation

struct NativePluginManagedDidInstall: AppEvent {
    static let name = Notification.Name("NativePluginManagedDidInstall")
}

/// Downloads a first-party bundle into a private candidate, verifies it, then switches one
/// top-level symlink. It is called only for a requested feature or a previously used feature
/// after an app update. Filesystem and child-process work stays on a utility worker.
enum NativePluginManagedInstaller {
    enum InstallError: LocalizedError, Equatable {
        case unavailableInThisBuild
        case missingFromManifest
        case downloadFailed
        case archiveChanged
        case extractionFailed
        case destinationOccupied
        case activationFailed

        var errorDescription: String? {
            switch self {
            case .unavailableInThisBuild:
                return L10n.string("This app build does not offer plugin downloads.")
            case .missingFromManifest:
                return L10n.string("This plugin is not available for this app version.")
            case .downloadFailed:
                return L10n.string("The plugin download failed. Check your connection and try again.")
            case .archiveChanged:
                return L10n.string("The download did not match Threading’s signed plugin release.")
            case .extractionFailed:
                return L10n.string("The downloaded plugin could not be unpacked.")
            case .destinationOccupied:
                return L10n.string("Another plugin occupies this location. Remove it before installing.")
            case .activationFailed:
                return L10n.string("The verified plugin could not be activated.")
            }
        }
    }

    private static let manifestLimit = 64 * 1024
    private static let coordinator = InstallCoordinator()

    static func install(
        identifier: String,
        app: URL = Bundle.main.bundleURL,
        directory: URL = NativePluginManagedPaths.directory
    ) async throws -> URL {
        let (distribution, manifestData) = try await fetchDistribution(for: app)
        guard let plugin = distribution.plugins.first(where: { $0.bundleIdentifier == identifier })
        else { throw InstallError.missingFromManifest }
        return try await install(plugin, manifest: manifestData, directory: directory)
    }

    static func refreshPreviouslyUsed(
        app: URL = Bundle.main.bundleURL,
        directory: URL = NativePluginManagedPaths.directory
    ) async throws {
        let usage = try await Task.detached(priority: .utility) {
            try NativePluginManagedUsage.read(in: directory)
        }.value
        guard !usage.identifiers.isEmpty,
              let currentBuild = NativePluginManagedUsage.buildKey(for: app),
              usage.lastRefreshedBuild != currentBuild else { return }

        let (distribution, manifestData) = try await fetchDistribution(for: app)
        for identifier in usage.identifiers {
            guard let plugin = distribution.plugins.first(where: {
                $0.bundleIdentifier == identifier
            }) else { continue }
            _ = try await install(plugin, manifest: manifestData, directory: directory)
        }
        try await Task.detached(priority: .utility) {
            try NativePluginManagedUsage.markRefreshed(currentBuild, in: directory)
        }.value
    }

    private static func fetchDistribution(
        for app: URL
    ) async throws -> (NativePluginDistribution, Data) {
        guard let manifestURL = NativePluginDistribution.manifestURL(for: app) else {
            throw InstallError.unavailableInThisBuild
        }
        let manifestFile = try await download(manifestURL, maximumBytes: manifestLimit)
        defer { try? FileManager.default.removeItem(at: manifestFile) }
        let manifestData = try await Task.detached(priority: .utility) {
            try Data(contentsOf: manifestFile)
        }.value
        let distribution = try await Task.detached(priority: .utility) {
            try NativePluginDistribution.verify(manifestData, for: app)
        }.value
        return (distribution, manifestData)
    }

    private static func install(
        _ plugin: NativePluginDistribution.Plugin,
        manifest: Data,
        directory: URL
    ) async throws -> URL {
        let key = InstallCoordinator.Key(
            directoryPath: directory.standardizedFileURL.path,
            bundleIdentifier: plugin.bundleIdentifier,
            archiveSHA256: plugin.archiveSHA256
        )
        return try await coordinator.run(key: key) {
            try await installOnce(plugin, manifest: manifest, directory: directory)
        }
    }

    private static func installOnce(
        _ plugin: NativePluginDistribution.Plugin,
        manifest: Data,
        directory: URL
    ) async throws -> URL {
        let archive = try await download(plugin.archiveURL, maximumBytes: plugin.archiveBytes)
        defer { try? FileManager.default.removeItem(at: archive) }
        let installed = try await Task.detached(priority: .utility) {
            try activate(
                plugin: plugin,
                archive: archive,
                manifest: manifest,
                directory: directory
            )
        }.value
        await MainActor.run {
            NotificationCenter.default.post(NativePluginManagedDidInstall())
        }
        return installed
    }

    private static func download(_ url: URL, maximumBytes: Int) async throws -> URL {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        let limiter = DownloadLimit(maximumBytes: maximumBytes)
        do {
            let (file, response) = try await URLSession.shared.download(for: request, delegate: limiter)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let bytes = try? FileManager.default.attributesOfItem(atPath: file.path)[.size]
                      as? NSNumber,
                  bytes.intValue > 0, bytes.intValue <= maximumBytes else {
                throw InstallError.downloadFailed
            }
            // URLSession owns its temporary file. Move it before returning, so the subsequent
            // verifier never depends on the lifetime of a networking callback.
            let retained = FileManager.default.temporaryDirectory
                .appendingPathComponent("threading-plugin-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: file, to: retained)
            return retained
        } catch {
            throw InstallError.downloadFailed
        }
    }

    private static func activate(
        plugin: NativePluginDistribution.Plugin,
        archive: URL,
        manifest: Data,
        directory: URL
    ) throws -> URL {
        guard (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size]
            as? NSNumber)?.intValue == plugin.archiveBytes,
              (try? NativePluginDistribution.sha256(archive)) == plugin.archiveSHA256 else {
            throw InstallError.archiveChanged
        }

        let managed = NativePluginManagedPaths.managedDirectory(in: directory)
        let incoming = managed.appendingPathComponent("incoming/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: incoming) }
        let result = try BoundedChildProcess.run(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", archive.path, incoming.path],
            timeout: 60,
            maximumOutputBytes: 1024
        )
        guard result.termination == .exited(0) else { throw InstallError.extractionFailed }
        let bundle = incoming.appendingPathComponent(plugin.bundleName, isDirectory: true)
        try NativePluginManagedCode.verify(
            bundle: bundle,
            expectedIdentifier: plugin.bundleIdentifier,
            expectedCodeDirectoryHash: plugin.codeDirectoryHash
        )
        let cleaned = try BoundedChildProcess.run(
            executable: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", bundle.path],
            timeout: 15,
            maximumOutputBytes: 1024
        )
        guard cleaned.termination == .exited(0) else { throw InstallError.activationFailed }
        try NativePluginManagedCode.verify(
            bundle: bundle,
            expectedIdentifier: plugin.bundleIdentifier,
            expectedCodeDirectoryHash: plugin.codeDirectoryHash
        )

        let version = managed.appendingPathComponent("versions/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        let installed = version.appendingPathComponent(plugin.bundleName, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: bundle, to: installed)
            try manifest.write(to: version.appendingPathComponent("manifest.json"), options: .atomic)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let visible = directory.appendingPathComponent(plugin.bundleName, isDirectory: true)
            let priorVersion = NativePluginManagedPaths.ownedVersion(
                for: visible, in: directory
            )
            let occupied = FileManager.default.fileExists(atPath: visible.path)
                || (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: visible.path
                )) != nil
            guard !occupied || priorVersion != nil else { throw InstallError.destinationOccupied }
            try NativePluginManagedUsage.record(plugin.bundleIdentifier, in: directory)
            let link = managed.appendingPathComponent("link-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: installed)
            defer { try? FileManager.default.removeItem(at: link) }
            guard rename(link.path, visible.path) == 0 else {
                throw InstallError.activationFailed
            }
            if let priorVersion, priorVersion != version {
                try? FileManager.default.removeItem(at: priorVersion)
            }
            // `visible` was formed before the rename. NSURL may cache that the path did not
            // exist, so hand the caller a fresh URL for immediate receipt/discovery checks.
            return URL(fileURLWithPath: visible.path, isDirectory: true)
        } catch {
            try? FileManager.default.removeItem(at: version)
            throw error
        }
    }
}

/// Settings, an on-demand plugin pane and background refresh can request the same build together.
/// Share its download and atomic activation so one caller cannot replace the version another
/// caller has just opened.
actor InstallCoordinator {
    struct Key: Hashable, Sendable {
        let directoryPath: String
        let bundleIdentifier: String
        let archiveSHA256: String
    }

    private var active: [Key: Task<URL, Error>] = [:]

    func run(
        key: Key,
        operation: @escaping @Sendable () async throws -> URL
    ) async throws -> URL {
        if let current = active[key] { return try await current.value }
        let task = Task { try await operation() }
        active[key] = task
        do {
            let result = try await task.value
            active[key] = nil
            return result
        } catch {
            active[key] = nil
            throw error
        }
    }
}

enum NativePluginManagedPaths {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Threading/Plugins", isDirectory: true)
    }

    static func managedDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent(".managed", isDirectory: true)
    }

    /// Ownership check for replacing a stale link. It does not grant execution trust: receipts
    /// still verify the signed manifest and notarized code. Requiring our exact version path
    /// prevents an install from replacing an unrelated manual symlink at the public filename.
    static func ownedVersion(for visible: URL, in directory: URL) -> URL? {
        guard visible.deletingLastPathComponent().standardizedFileURL.path
                == directory.standardizedFileURL.path,
              let destination = try? FileManager.default.destinationOfSymbolicLink(
                atPath: visible.path
              ), destination.hasPrefix("/") else { return nil }
        let target = URL(fileURLWithPath: destination).standardizedFileURL
        let version = target.deletingLastPathComponent()
        let versions = managedDirectory(in: directory)
            .appendingPathComponent("versions", isDirectory: true).standardizedFileURL
        guard target.lastPathComponent == visible.lastPathComponent,
              version.deletingLastPathComponent().path == versions.path,
              UUID(uuidString: version.lastPathComponent) != nil else { return nil }
        return version
    }
}

private final class DownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximumBytes: Int64

    init(maximumBytes: Int) {
        self.maximumBytes = Int64(maximumBytes)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumBytes { downloadTask.cancel() }
    }
}
