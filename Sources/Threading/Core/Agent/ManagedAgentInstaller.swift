import CryptoKit
import Foundation

/// One installation at a time bounds network, disk and verification work across all clients.
/// Downloading and staging never changes the active receipt; activation is the final write.
actor ManagedAgentInstaller {
    typealias Download = @Sendable (URL, URL) async throws -> Void
    static let local = ManagedAgentInstaller(store: .local)
    let store: ManagedAgentRuntimeStore
    private let download: Download

    init(store: ManagedAgentRuntimeStore,
         download: @escaping Download = { try await ManagedAgentDownload.fetch($0, to: $1) }) {
        self.store = store
        self.download = download
    }

    func install(_ kind: AgentKind) async throws {
        try await install(ManagedAgentCatalog.release(for: kind))
    }

    func install(_ release: ManagedAgentRelease) async throws {
        guard release.supportsCurrentSystem else {
            throw ManagedAgentError.verificationFailed(release.systemRequirement)
        }
        guard store.beginInstallation() else { throw ManagedAgentError.busy }
        defer { store.endInstallation() }
        let store = self.store
        let download = self.download
        let worker = Task.detached(priority: .utility) {
            try await Self.stageAndActivate(release, store: store, download: download)
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    func rollback(_ kind: AgentKind) async throws {
        guard store.beginInstallation() else { throw ManagedAgentError.busy }
        defer { store.endInstallation() }
        let store = self.store
        try await Task.detached(priority: .utility) { try store.rollback(kind) }.value
    }

    private static func stageAndActivate(_ release: ManagedAgentRelease,
                                         store: ManagedAgentRuntimeStore,
                                         download: Download) async throws {
        let files = FileManager.default
        let provider = store.providerRoot(release.kind)
        try files.createDirectory(at: provider, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        guard provider.resolvingSymlinksInPath() == provider.standardizedFileURL else {
            throw ManagedAgentError.invalidReceipt
        }
        // Retained binaries can still be mmap'd by a process hosted across an app restart.
        // Never replace/delete one while installing. Bound the inventory before making more.
        guard let entries = files.enumerator(at: provider, includingPropertiesForKeys: nil,
                                             options: [.skipsSubdirectoryDescendants]) else {
            throw ManagedAgentError.invalidReceipt
        }
        var generations = 0
        var count = 0
        for case let entry as URL in entries {
            count += 1
            if UUID(uuidString: entry.lastPathComponent) != nil { generations += 1 }
            guard generations < ManagedAgentCatalog.maximumRetainedInstallations,
                  count < ManagedAgentCatalog.maximumArchiveEntries else {
                throw ManagedAgentError.retentionLimit
            }
        }
        let staging = provider.appendingPathComponent(".staging-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("download.tgz")
        try await download(release.archiveURL, archive)
        try Task.checkCancellation()
        try verifyIntegrity(archive, expected: release.integrity)
        let payload = staging.appendingPathComponent("payload")
        try extract(archive, to: payload)
        if release.requiresBrotliUnpacking {
            let nodeArchive = staging.appendingPathComponent("node.tgz")
            try await download(ManagedAgentCatalog.nodeURL, nodeArchive)
            try verifyIntegrity(nodeArchive, expected: ManagedAgentCatalog.nodeIntegrity)
            let node = staging.appendingPathComponent("node")
            try extract(nodeArchive, to: node, members: [ManagedAgentCatalog.nodeArchiveMember])
            // Fixed source and argv, never interpolated provider data. The output cap also
            // bounds a malformed Brotli stream before a native executable is written.
            let script = "const f=require('fs'),z=require('zlib');"
                + "f.writeFileSync(process.argv[2],z.brotliDecompressSync(f.readFileSync(process.argv[1]),"
                + "{maxOutputLength:536870912}));"
            try run(node.appendingPathComponent("bin/node").path, ["-e", script,
                payload.appendingPathComponent("bin/grok.br").path,
                payload.appendingPathComponent(release.executable).path], timeout: 60)
        }
        try Task.checkCancellation()
        let executable = payload.appendingPathComponent(release.executable)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try verifyExecutable(executable, version: release.version, kind: release.kind)
        try Task.checkCancellation()
        let directory = UUID().uuidString
        let destination = provider.appendingPathComponent(directory)
        let installation = ManagedAgentInstallation(
            version: release.version, directory: directory, executable: release.executable,
            archiveIntegrity: release.integrity
        )
        try JSONEncoder().encode(installation).write(
            to: payload.appendingPathComponent(".threading-installation.json"), options: .atomic
        )
        try files.moveItem(at: payload, to: destination)
        // An activation write failure leaves an unselected installation for inspection. The
        // previous receipt remains authoritative, including after a crash at this boundary.
        try store.activate(installation, for: release.kind)
    }

    static func verifyIntegrity(_ file: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha512 = SHA512()
        var sha256 = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            sha512.update(data: chunk)
            sha256.update(data: chunk)
        }
        let actual: String
        if expected.hasPrefix("sha512-") {
            actual = "sha512-" + Data(sha512.finalize()).base64EncodedString()
        } else if expected.hasPrefix("sha256-") {
            actual = "sha256-" + sha256.finalize().map { String(format: "%02x", $0) }.joined()
        } else { throw ManagedAgentError.checksumMismatch }
        guard actual == expected else { throw ManagedAgentError.checksumMismatch }
    }

    static func validateArchiveListing(_ listing: String) throws {
        let names = listing.split(separator: "\n")
        guard !names.isEmpty, names.count <= ManagedAgentCatalog.maximumArchiveEntries else {
            throw ManagedAgentError.invalidArchive
        }
        let root = names[0].split(separator: "/").first
        guard names.allSatisfy({ name in
            ManagedAgentRuntimeStore.isRelativePath(String(name))
                && name.split(separator: "/").first == root
                && !name.contains("\\") && !name.contains("\r")
        }) else { throw ManagedAgentError.invalidArchive }
    }

    static func extract(_ archive: URL, to destination: URL, members: [String] = []) throws {
        let listing = try run("/usr/bin/tar", ["-tzf", archive.path] + members, timeout: 60,
                              maximumBytes: ManagedAgentCatalog.maximumArchiveListingBytes)
        try validateArchiveListing(listing)
        let metadata = try run("/usr/bin/tar", ["-tvzf", archive.path] + members, timeout: 60,
                               maximumBytes: ManagedAgentCatalog.maximumArchiveListingBytes)
        try validateArchiveMetadata(metadata)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try run("/usr/bin/tar", ["-xzf", archive.path, "--strip-components=1", "--no-same-owner",
                                 "--no-same-permissions", "-C", destination.path] + members, timeout: 120)
        // Do not admit archive links which escape the immutable package. tar refuses absolute
        // and .. member paths; this also checks the target of links inside a trusted archive.
        guard let enumerator = FileManager.default.enumerator(
            at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey],
            options: [], errorHandler: { _, _ in false }
        ) else { throw ManagedAgentError.invalidArchive }
        var count = 0
        var size: Int64 = 0
        for case let item as URL in enumerator {
            count += 1
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            size += Int64(values.fileSize ?? 0)
            guard count <= ManagedAgentCatalog.maximumArchiveEntries, size <= 2 * 1024 * 1024 * 1024,
                  item.resolvingSymlinksInPath().path.hasPrefix(destination.path + "/") else {
                throw ManagedAgentError.invalidArchive
            }
        }
    }

    /// The pinned distributions contain only directories and regular files. Refuse links and
    /// special files before extracting anything, and bound the advertised expanded byte count.
    static func validateArchiveMetadata(_ listing: String) throws {
        let entries = listing.split(separator: "\n")
        guard !entries.isEmpty, entries.count <= ManagedAgentCatalog.maximumArchiveEntries else {
            throw ManagedAgentError.invalidArchive
        }
        var bytes: Int64 = 0
        for entry in entries {
            let fields = entry.split(whereSeparator: \.isWhitespace)
            guard ["-", "d"].contains(entry.prefix(1)), fields.count >= 9,
                  let size = Int64(fields[4]), size >= 0, size <= 2 * 1024 * 1024 * 1024 else {
                throw ManagedAgentError.invalidArchive
            }
            bytes += size
            guard bytes <= 2 * 1024 * 1024 * 1024 else { throw ManagedAgentError.invalidArchive }
        }
    }

    static func verifyExecutable(_ executable: URL, version: String?, kind: AgentKind,
                                 path: String = ManagedAgentCatalog.systemPATH,
                                 managed: Bool = true) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-verify-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        var environment = ["HOME": home.path, "PATH": path, "TMPDIR": home.path,
                           "XDG_CONFIG_HOME": home.appendingPathComponent("config").path,
                           "XDG_DATA_HOME": home.appendingPathComponent("data").path,
                           "XDG_CACHE_HOME": home.appendingPathComponent("cache").path]
        let flags = managed ? ManagedAgentRuntimeStore.managedArguments(for: kind) : []
        if managed {
            environment.merge(ManagedAgentRuntimeStore.managedEnvironment(for: kind)) { _, value in value }
        }
        let result = try BoundedChildProcess.run(
            executable: executable.path, arguments: flags + kind.cliUpdateDefinition.versionArguments,
            environment: environment, timeout: 20, maximumOutputBytes: 16 * 1024
        )
        let output = String(decoding: result.output, as: UTF8.self)
        guard result.termination == .exited(0), !result.outputWasTruncated,
              let actual = AgentCLIVersion(output), version == nil || actual.display == version else {
            throw ManagedAgentError.verificationFailed(String(output.prefix(2048)))
        }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                            maximumBytes: Int = 16 * 1024) throws -> String {
        let result = try BoundedChildProcess.run(
            executable: executable, arguments: arguments,
            environment: ["PATH": ManagedAgentCatalog.systemPATH],
            timeout: timeout, maximumOutputBytes: maximumBytes
        )
        guard result.termination == .exited(0), !result.outputWasTruncated else {
            throw ManagedAgentError.verificationFailed(String(decoding: result.output.prefix(2048), as: UTF8.self))
        }
        return String(decoding: result.output, as: UTF8.self)
    }
}
