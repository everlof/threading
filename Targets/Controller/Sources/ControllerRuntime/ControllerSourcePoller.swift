import Foundation
import ThreadingController
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Runs one source's probe on this host. The hash is checked before anything runs, so an edited
/// probe is never executed under an old approval; secrets are resolved by name from owner-only
/// files and exist only in the probe's environment.
public enum ControllerSourcePoller {
    public static func poll(store: ControllerStore, id: SourceID, database: String, manual: Bool = false) async throws -> [SourceEvent] {
        let source = try await store.beginPoll(id, manual: manual)
        let observed = try? TriggerProbe.contentHash(of: [source.spec.executable] + (source.spec.script.map { [$0] } ?? []))
        guard observed == source.approvedHash else {
            return try await store.recordPoll(id, revision: source.revision, observedHash: observed,
                                              run: ProbeRun(outcome: .failed, events: [], cursor: nil, diagnostics: "changed"))
        }
        let root = URL(fileURLWithPath: database).deletingLastPathComponent()
        let directory = root.appendingPathComponent("sources").appendingPathComponent(id.description)
        let run: ProbeRun
        do {
            try privateDirectory(root.appendingPathComponent("sources"))
            try privateDirectory(directory)
            var environment = source.spec.environment
            for (variable, name) in source.spec.secrets { environment[variable] = try secret(name, root: root) }
            environment["THREADING_SOURCE_ID"] = id.description
            environment["THREADING_SOURCE_REVISION"] = String(source.revision)
            run = await TriggerProbe.run(ProbeInvocation(
                executable: source.spec.executable, arguments: source.spec.arguments, environment: environment,
                directory: directory.path, cursor: source.cursor, limit: source.spec.limit,
                timeout: TimeInterval(source.spec.timeoutSeconds)))
        } catch let error as ControllerError {
            run = ProbeRun(outcome: .failed, events: [], cursor: nil, diagnostics: error.description)
        }
        return try await store.recordPoll(id, revision: source.revision, observedHash: observed, run: run)
    }

    /// `<database directory>/secrets/NAME`, owner-only. Written by `secret-set`, never read back
    /// through any command.
    public static func secretPath(_ name: String, database: String) throws -> URL {
        guard SecretName.isValid(name) else { throw ControllerError.invalidInput("secret_name") }
        return URL(fileURLWithPath: database).deletingLastPathComponent().appendingPathComponent("secrets").appendingPathComponent(name)
    }
    public static func storeSecret(_ name: String, value: String, database: String) throws {
        let path = try secretPath(name, database: database)
        try privateDirectory(path.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: path)
        guard FileManager.default.createFile(atPath: path.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ControllerError.invalidInput("secret_write")
        }
    }

    static func secret(_ name: String, root: URL) throws -> String {
        let path = root.appendingPathComponent("secrets").appendingPathComponent(name).path
        guard SecretName.isValid(name) else { throw ControllerError.invalidInput("secret_name") }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ControllerError.invalidInput("secret_unavailable: \(name)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_uid == getuid(), info.st_size <= 16_384,
              let data = try handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            throw ControllerError.invalidInput("secret_unavailable: \(name)")
        }
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    static func privateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw ControllerError.invalidInput("private_directory")
        }
    }
}
