import CryptoKit
import Foundation

// MARK: - The manifest

/// One Linux binary this app can install on a host, named by its content.
///
/// Two digests, because two things are verified: `assetSHA256` is the compressed file that is
/// downloaded, checked before anything is unpacked, and `sha256` is the binary inside it — which is
/// also its install identifier on the host, so a component that passes here installs under the
/// exact name the host's own `sha256sum` will report.
struct RemoteHostComponent: Equatable, Sendable {
    let kind: RemoteHostBinaryKind
    let architecture: RemoteHostArchitecture
    /// The asset's file name on the release it is published with.
    let assetName: String
    let assetSHA256: String
    /// What the download costs, so a person can be told before it starts.
    let assetByteCount: Int
    let sha256: String

    var installIdentifier: String {
        String(sha256.prefix(RemoteHostDefaults.identifierHexLength))
    }
}

// MARK: - Providing a binary

/// Where a preparation gets the binaries it installs. One protocol so the download, the developer's
/// own build directory and a test's fixture are the same decision made three ways.
protocol RemoteHostComponentProviding: Sendable {
    /// The binary to install, fetching it if this Mac does not have it yet. Called off the main
    /// actor, from the host's own preparation queue, and may block for the length of a download.
    func binary(
        _ kind: RemoteHostBinaryKind,
        for architecture: RemoteHostArchitecture,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> RemoteHostBinary
}

enum RemoteHostComponentError: LocalizedError, Equatable {
    /// This build publishes no component for that machine.
    case unpublished(RemoteHostArchitecture)
    case downloadFailed(String)
    /// The bytes that arrived are not the bytes this build expects.
    case digestMismatch
    case unpackFailed(String)

    var errorDescription: String? {
        switch self {
        case .unpublished(let architecture):
            return L10n.format("This build has no Linux components for %@ hosts.", architecture.rawValue)
        case .downloadFailed(let detail):
            return L10n.format("The Linux components could not be downloaded: %@", detail)
        case .digestMismatch:
            return L10n.string("The downloaded Linux components are not the ones this build expects.")
        case .unpackFailed(let detail):
            return L10n.format("The Linux components could not be unpacked: %@", detail)
        }
    }

    var token: String {
        switch self {
        case .unpublished: return "componentsUnpublished"
        case .downloadFailed: return "componentDownloadFailed"
        case .digestMismatch: return "componentDigestMismatch"
        case .unpackFailed: return "componentUnpackFailed"
        }
    }
}

// MARK: - The developer's own build

/// The binaries `scripts/test-ptyd-linux.sh` wrote, named by the developer setting.
///
/// Kept now that components are published, because the loop it serves is real: change the daemon,
/// build it, install it on a host without publishing anything. It is an *override* rather than the
/// only route, and the Remote Hosts settings say when a host was set up from it, so a build that
/// works only because of a local directory cannot be mistaken for one that works.
struct RemoteHostDirectoryComponents: RemoteHostComponentProviding {
    let directory: URL

    func binary(
        _ kind: RemoteHostBinaryKind,
        for architecture: RemoteHostArchitecture,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> RemoteHostBinary {
        try RemoteHostBinary.load(kind, architecture: architecture, fromDirectory: directory)
    }
}

// MARK: - The published components

/// Fetches a published component once and keeps it, verified, under Application Support.
///
/// The cache is content-named — `remote-components/<digest>/<name>` — so a file that is there is a
/// file that was verified when it landed, and a half-written download can never be picked up as a
/// component: the unpacked binary is verified in a temporary directory and only then moved into its
/// digest's place.
final class RemoteHostPublishedComponents: RemoteHostComponentProviding {

    static let shared = RemoteHostPublishedComponents()

    /// Which component this build publishes for a machine. The compiled manifest in production;
    /// injectable so a test can ask about a build that publishes nothing, whatever this one does.
    typealias ManifestLookup = @Sendable (RemoteHostBinaryKind, RemoteHostArchitecture) -> RemoteHostComponent?

    private let session: URLSession
    private let root: URL
    private let lookup: ManifestLookup

    init(
        session: URLSession = .shared,
        root: URL = PTYHostLocation.supportRoot
            .appendingPathComponent(RemoteHostComponentDefaults.cacheDirectoryName, isDirectory: true),
        lookup: @escaping ManifestLookup = { RemoteHostComponentManifest.component($0, for: $1) }
    ) {
        self.session = session
        self.root = root
        self.lookup = lookup
    }

    /// The cached binary for a component, or nil when it has not been fetched.
    func cachedURL(for component: RemoteHostComponent) -> URL? {
        let url = location(of: component)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    func binary(
        _ kind: RemoteHostBinaryKind,
        for architecture: RemoteHostArchitecture,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> RemoteHostBinary {
        guard let component = lookup(kind, architecture) else {
            throw RemoteHostComponentError.unpublished(architecture)
        }
        guard let source = RemoteHostComponentManifest.url(for: component) else {
            throw RemoteHostComponentError.downloadFailed(component.assetName)
        }
        return try fetch(component, from: source, progress: progress)
    }

    /// Fetches one component from an explicit address. The manifest names that address in
    /// production; a test names its own, which is the only way to exercise the verification without
    /// a network.
    func fetch(
        _ component: RemoteHostComponent,
        from source: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> RemoteHostBinary {
        if let url = cachedURL(for: component) {
            return RemoteHostBinary(
                url: url,
                architecture: component.architecture,
                sha256: component.sha256,
                kind: component.kind
            )
        }
        let url = try download(component, from: source, progress: progress)
        return RemoteHostBinary(
            url: url,
            architecture: component.architecture,
            sha256: component.sha256,
            kind: component.kind
        )
    }

    // MARK: - Private Methods

    private func location(of component: RemoteHostComponent) -> URL {
        root
            .appendingPathComponent(component.installIdentifier, isDirectory: true)
            .appendingPathComponent(component.kind.executableName, isDirectory: false)
    }

    private func download(
        _ component: RemoteHostComponent,
        from source: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> URL {
        let scratch = root.appendingPathComponent(
            RemoteHostComponentDefaults.scratchPrefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let asset = scratch.appendingPathComponent(component.assetName)
        try download(source, to: asset, progress: progress)
        guard digest(of: asset) == component.assetSHA256 else {
            throw RemoteHostComponentError.digestMismatch
        }

        let unpacked = scratch.appendingPathComponent(component.kind.executableName)
        try unpack(asset, to: unpacked)
        guard digest(of: unpacked) == component.sha256 else {
            throw RemoteHostComponentError.digestMismatch
        }

        let destination = location(of: component)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: unpacked, to: destination)
        } catch {
            throw RemoteHostComponentError.unpackFailed(error.localizedDescription)
        }
        EventLog.shared.record(.session, "Downloaded a Linux component for remote hosts", [
            "component": component.assetName,
            "bytes": String(component.assetByteCount)
        ])
        return destination
    }

    /// Downloads to a file, reporting progress, and waits. The caller is a preparation on its own
    /// queue, which is already the thing a person is watching.
    private func download(
        _ source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let observer = DownloadObserver(progress: progress)
        let finished = DispatchSemaphore(value: 0)
        let outcome = DownloadOutcome()

        let task = session.downloadTask(with: source) { url, response, error in
            defer { finished.signal() }
            if let error {
                outcome.fail(RemoteHostComponentError.downloadFailed(error.localizedDescription))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), let url else {
                outcome.fail(RemoteHostComponentError.downloadFailed("HTTP \(status)"))
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: url, to: destination)
            } catch {
                outcome.fail(RemoteHostComponentError.downloadFailed(error.localizedDescription))
            }
        }
        let progressObservation = task.progress.observe(\.fractionCompleted) { value, _ in
            observer.report(value.fractionCompleted)
        }
        defer { progressObservation.invalidate() }
        task.resume()

        switch finished.wait(timeout: .now() + RemoteHostComponentDefaults.downloadTimeout) {
        case .success:
            if let failure = outcome.failure { throw failure }
        case .timedOut:
            task.cancel()
            throw RemoteHostComponentError.downloadFailed("timed out")
        }
    }

    /// `gunzip`, which every Mac has, rather than a decompressor of our own: the asset is a plain
    /// gzip file so that the same bytes can be unpacked by hand when something has gone wrong.
    private func unpack(_ asset: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RemoteHostComponentDefaults.gunzipPath)
        process.arguments = ["-c", asset.path]
        let output = FileManager.default.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.posixPermissions: RemoteHostComponentDefaults.binaryPermissions]
        )
        guard output, let handle = try? FileHandle(forWritingTo: destination) else {
            throw RemoteHostComponentError.unpackFailed(destination.lastPathComponent)
        }
        defer { try? handle.close() }
        process.standardOutput = handle
        do {
            try process.run()
        } catch {
            throw RemoteHostComponentError.unpackFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RemoteHostComponentError.unpackFailed("gunzip exited \(process.terminationStatus)")
        }
    }

    /// Hashes in chunks: a component is tens of megabytes and this runs on a preparation's queue.
    private func digest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: RemoteHostInstallDefaults.hashChunkBytes),
              !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum RemoteHostComponentDefaults {
    static let cacheDirectoryName = "remote-components"
    static let scratchPrefix = "fetch-"
    static let binaryPermissions = 0o700
    static let gunzipPath = "/usr/bin/gunzip"
    /// Generous: this is a tens-of-megabytes download on whatever connection the person has, and a
    /// stuck one is already reported by its own lack of progress.
    static let downloadTimeout: DispatchTimeInterval = .seconds(30 * 60)
}

/// Progress across the download's callback queue, coalesced so a percentage does not cost a hop per
/// packet.
private final class DownloadObserver: @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var last = -1.0

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func report(_ fraction: Double) {
        lock.lock()
        let step = (fraction * 100).rounded(.down) / 100
        let changed = step > last
        if changed { last = step }
        lock.unlock()
        if changed { progress(step) }
    }
}

private final class DownloadOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func fail(_ error: Error) {
        lock.lock()
        if stored == nil { stored = error }
        lock.unlock()
    }
}

// MARK: - Choosing a source

/// Which components a preparation uses: this build's published ones, or the developer's own build.
///
/// The override is deliberate and visible rather than silent. A host set up from a local directory
/// is running bytes no release ever published, and the Remote Hosts settings say so, because the
/// alternative is a machine that works for one person and nobody can explain why.
enum RemoteHostComponentSource {

    @MainActor
    static func current(
        developerDirectory: URL? = AppSettings.shared.developerRemoteHostBinaryDirectory
    ) -> RemoteHostComponentProviding {
        if let developerDirectory {
            return RemoteHostDirectoryComponents(directory: developerDirectory)
        }
        return RemoteHostPublishedComponents.shared
    }

    /// Whether this build can set up a host at all without a developer directory.
    static var hasPublishedComponents: Bool {
        !RemoteHostComponentManifest.components.isEmpty && !RemoteHostComponentManifest.release.isEmpty
    }
}
