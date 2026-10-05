import CryptoKit
import Darwin
import Foundation

/// Blocking filesystem boundary, called only by TriggerStore's serial background actor.
/// Discovery caps the directory scan before parsing. No recursive discovery or shell expansion.
enum ProjectAutomationFiles {
    static let maximumDefinitions = 500
    static let maximumFileBytes = 1_048_576
    static let maximumAggregateBytes = 8_388_608
    static let maximumResources = 32
    static let directory = ".threading/automations"

    struct Snapshot: Sendable {
        let definition: ProjectAutomation
        let files: [String: Data]
        let fingerprint: String
        var instructions: String { String(decoding: files[definition.instructions] ?? Data(), as: UTF8.self) }
    }

    struct Entry: Sendable {
        let id: String
        let snapshot: Snapshot?
        let diagnostic: String?
    }

    enum Failure: LocalizedError {
        case invalid(String)
        case conflict
        var errorDescription: String? {
            switch self {
            case .invalid(let reason): "Project automation: \(reason)"
            case .conflict: "The automation files changed. Reload before saving or activating."
            }
        }
    }

    static func validID(_ id: String) -> Bool {
        ProjectAutomation.validID(id)
    }

    static func folder(checkout: String, id: String) throws -> URL {
        guard validID(id) else { throw Failure.invalid("invalid automation id") }
        let root = URL(fileURLWithPath: checkout).standardizedFileURL.resolvingSymlinksInPath()
        return try contained(directory + "/" + id, in: root)
    }

    static func discover(checkout: String) throws -> [Entry] {
        let root = URL(fileURLWithPath: checkout).standardizedFileURL.resolvingSymlinksInPath()
        let base = try contained(directory, in: root)
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            throw Failure.invalid("cannot read the automations directory")
        }
        var entries: [Entry] = []
        var totalBytes = 0
        var examined = 0
        for case let url as URL in enumerator {
            enumerator.skipDescendants()
            examined += 1
            guard examined <= maximumDefinitions * 2 else { throw Failure.invalid("maximum 1,000 directory entries") }
            let id = url.lastPathComponent
            if id.hasPrefix(".") { continue }
            guard entries.count < maximumDefinitions else { throw Failure.invalid("maximum 500 definitions") }
            do {
                guard validID(id) else { throw Failure.invalid("invalid automation directory name") }
                let snapshot = try read(checkout: checkout, id: id)
                totalBytes += snapshot.files.values.reduce(0) { $0 + $1.count }
                guard totalBytes <= maximumAggregateBytes * 4 else { throw Failure.invalid("project automation files exceed 32 MiB") }
                entries.append(Entry(id: id, snapshot: snapshot, diagnostic: nil))
            } catch {
                if totalBytes > maximumAggregateBytes * 4 { throw error }
                entries.append(Entry(id: id, snapshot: nil, diagnostic: error.localizedDescription))
            }
        }
        return entries.sorted { $0.id < $1.id }
    }

    static func read(checkout: String, id: String) throws -> Snapshot {
        try read(folder: folder(checkout: checkout, id: id), expectedID: id)
    }

    private static func read(folder: URL, expectedID: String) throws -> Snapshot {
        let manifest = try readFile("automation.json", in: folder)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let definition = try decoder.decode(ProjectAutomation.self, from: manifest)
        guard definition.formatVersion == 1, definition.id == expectedID,
              validID(definition.id), !definition.name.isEmpty, definition.name.utf8.count <= 160,
              definition.resources.count <= maximumResources,
              Set(definition.resources).count == definition.resources.count,
              !definition.resources.contains(definition.instructions),
              definition.instructions != "automation.json",
              !definition.resources.contains("automation.json"),
              (1...1_440).contains(definition.maximumRuntimeMinutes),
              definition.agent.supportsNativeUI, definition.agent.supportsPermissionModes,
              definition.checkoutPolicy != .automationWorkspace || definition.executionMode.isTask else {
            throw Failure.invalid("unsupported version, identity or settings")
        }
        try definition.options.schedule?.validate()
        guard (definition.options.schedule == nil) == (definition.source != nil),
              definition.options.schedule != nil || definition.eventKind?.isEmpty == false else {
            throw Failure.invalid("choose a schedule or a named event source")
        }
        // Validate the portable rule grammar using harmless absolute reference stand-ins.
        let policy = try resolvedPermissions(definition.permissions, project: "/project", workspace: "/workspace", resources: "/resources")
        guard !policy.isFull || definition.executionMode == .taskLocalEdits || definition.executionMode == .assessThenFix else { throw Failure.invalid("full permission requires an editing mode") }
        var files = ["automation.json": manifest]
        var aggregate = manifest.count
        for path in [definition.instructions] + definition.resources {
            let data = try readFile(path, in: folder)
            aggregate += data.count
            guard aggregate <= maximumAggregateBytes else { throw Failure.invalid("files exceed 8 MiB") }
            files[path] = data
        }
        guard let instructions = files[definition.instructions].flatMap({ String(data: $0, encoding: .utf8) }),
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instructions.utf8.count <= 32_768 else { throw Failure.invalid("instructions must be UTF-8, nonempty and at most 32 KiB") }
        return Snapshot(definition: definition, files: files, fingerprint: fingerprint(files))
    }

    private static func fingerprint(_ files: [String: Data]) -> String {
        var hash = SHA256()
        for path in files.keys.sorted() {
            let data = files[path]!
            hash.update(data: Data("\(path.utf8.count):\(path):\(data.count):".utf8))
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func contained(_ path: String, in root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Failure.invalid("file references must be relative without traversal")
        }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path == url.path, url.path.hasPrefix(root.path + "/") else {
            throw Failure.invalid("symlinks are not allowed in automation paths")
        }
        return url
    }

    private static func readFile(_ path: String, in root: URL) throws -> Data {
        let url = try contained(path, in: root)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.invalid("missing or unreadable file: \(path)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maximumFileBytes else { throw Failure.invalid("not a regular file or over 1 MiB: \(path)") }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else { throw Failure.invalid("file grew beyond 1 MiB: \(path)") }
        return data
    }

    static func revision(snapshot: Snapshot, checkout: String) throws -> ProjectAutomationRevision {
        let workspace = AutomationWorkspace(automationID: snapshot.definition.id, checkoutPath: checkout)
        let root = URL(fileURLWithPath: checkout).standardizedFileURL.resolvingSymlinksInPath()
        let resources = try contained(".threading/local/automations/\(snapshot.definition.id)/revisions/\(snapshot.fingerprint)", in: root)
        try ensureIgnore(checkout: checkout)
        if FileManager.default.fileExists(atPath: resources.path) {
            guard try read(folder: resources, expectedID: snapshot.definition.id).fingerprint == snapshot.fingerprint else {
                throw Failure.invalid("the local revision snapshot was altered")
            }
        } else {
            try FileManager.default.createDirectory(at: resources.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = resources.deletingLastPathComponent().appendingPathComponent(".snapshot-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try writeFiles(snapshot.files, to: temporary)
            try FileManager.default.moveItem(at: temporary, to: resources)
        }
        return ProjectAutomationRevision(automationID: snapshot.definition.id, checkoutPath: checkout,
            fingerprint: snapshot.fingerprint, resourcesPath: resources.path, workspacePath: workspace.executionPath,
            resources: snapshot.definition.resources)
    }

    static func resolve(_ text: String, project: String, workspace: String, resources: String) -> String {
        text.replacingOccurrences(of: "{{project}}", with: project)
            .replacingOccurrences(of: "{{workspace}}", with: workspace)
            .replacingOccurrences(of: "{{resources}}", with: resources)
    }

    static func resolvedPermissions(_ policy: ProjectAutomationPermissions, project: String, workspace: String, resources: String) throws -> AutomationPermissionPolicy {
        if policy.mode == .full {
            guard policy.rules == nil else { throw Failure.invalid("full permission takes no rules") }
            return .full
        }
        guard let rules = policy.rules, rules.count <= AutomationPermissionPolicy.maximumRules else { throw Failure.invalid("missing or too many rules") }
        return try .allowList(parsing: rules.map { resolve($0, project: project, workspace: workspace, resources: resources) })
    }

    static func portable(_ text: String, project: String, workspace: String, resources: String) -> String {
        text.replacingOccurrences(of: resources, with: "{{resources}}")
            .replacingOccurrences(of: workspace, with: "{{workspace}}")
            .replacingOccurrences(of: project, with: "{{project}}")
    }

    /// Complete directory replacement makes manifest and instructions one atomic revision.
    /// Cooperating writers use flock; the fingerprint also catches outside edits at commit.
    static func save(_ definition: ProjectAutomation, instructions: String, checkout: String, expectedFingerprint: String?) throws -> Snapshot {
        let destination = try folder(checkout: checkout, id: definition.id)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try ensureIgnore(checkout: checkout)
        let root = URL(fileURLWithPath: checkout).standardizedFileURL.resolvingSymlinksInPath()
        let local = try contained(".threading/local/automations", in: root)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let lock = open(local.appendingPathComponent(".write-lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw Failure.invalid("cannot lock the configuration directory") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw Failure.conflict }
        let exists = FileManager.default.fileExists(atPath: destination.path)
        let previous = exists ? try read(checkout: checkout, id: definition.id) : nil
        guard previous?.fingerprint == expectedFingerprint else { throw Failure.conflict }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let originalFiles = exists ? try authoredFiles(in: destination) : [:]
        var files = originalFiles
        files["automation.json"] = try encoder.encode(definition)
        files[definition.instructions] = Data(instructions.utf8)
        let temporary = parent.appendingPathComponent(".save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeFiles(files, to: temporary)
        let saved = try read(folder: temporary, expectedID: definition.id)
        guard try !exists || (read(checkout: checkout, id: definition.id).fingerprint == expectedFingerprint
            && authoredFiles(in: destination) == originalFiles) else { throw Failure.conflict }
        if exists {
            guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw Failure.invalid("atomic configuration replacement failed")
            }
        } else {
            guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw Failure.conflict }
        }
        return saved
    }

    static func remove(checkout: String, id: String, fingerprint: String) throws {
        let destination = try folder(checkout: checkout, id: id)
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        guard try read(checkout: checkout, id: id).fingerprint == fingerprint else { throw Failure.conflict }
        try FileManager.default.removeItem(at: destination)
    }

    static func configurationFolder(checkout: String, id: String?) throws -> URL {
        let root = URL(fileURLWithPath: checkout).standardizedFileURL.resolvingSymlinksInPath()
        let destination = try id.map { try folder(checkout: checkout, id: $0) }
            ?? contained(directory, in: root)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    private static func authoredFiles(in root: URL) throws -> [String: Data] {
        let canonicalRoot = root.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: canonicalRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { throw Failure.invalid("cannot read configuration folder") }
        var files: [String: Data] = [:]
        var entries = 0
        var bytes = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= 128 else { throw Failure.invalid("configuration folder exceeds 128 entries") }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Failure.invalid("symlinks are not allowed in automation paths") }
            let canonicalPath = url.resolvingSymlinksInPath().path
            guard canonicalPath.hasPrefix(canonicalRoot.path + "/") else { throw Failure.invalid("configuration path escaped its folder") }
            let path = String(canonicalPath.dropFirst(canonicalRoot.path.count + 1))
            _ = try contained(path, in: canonicalRoot)
            if values.isDirectory == true { continue }
            let data = try readFile(path, in: canonicalRoot)
            bytes += data.count
            guard bytes <= maximumAggregateBytes else { throw Failure.invalid("configuration folder exceeds 8 MiB") }
            files[path] = data
        }
        return files
    }

    private static func writeFiles(_ files: [String: Data], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, data) in files {
            let url = try contained(path, in: directory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    static func ensureIgnore(checkout: String) throws {
        let root = URL(fileURLWithPath: checkout).standardizedFileURL.resolvingSymlinksInPath()
        let ignore = try contained(".threading/.gitignore", in: root)
        let existing = FileManager.default.fileExists(atPath: ignore.path) ? try readFile(".threading/.gitignore", in: root) : Data()
        let text = String(decoding: existing, as: UTF8.self)
        guard !text.components(separatedBy: .newlines).contains("/local/") else { return }
        try FileManager.default.createDirectory(at: ignore.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "/local/\n").utf8).write(to: ignore, options: .atomic)
    }
}
