#if os(Linux)
import Foundation

/// A live checkout, read from Git control files on a worker. The git directory is the
/// checkout identity; the shared directory groups linked worktrees of one repository.
struct LinuxGitCheckout: Sendable {
    let root: String
    let identity: String
    let repositoryIdentity: String
    let branch: String?
    /// Git's administrative name for a linked worktree; absent for the main checkout.
    let worktreeName: String?

    static func discover(_ projects: [(id: String, path: String)]) -> LinuxGitCheckoutCatalog {
        var checkouts: [String: LinuxGitCheckout] = [:]
        var projectIDsByRepository: [String: [String]] = [:]
        for project in projects {
            guard let checkout = read(at: project.path) else { continue }
            checkouts[project.id] = checkout
            projectIDsByRepository[checkout.repositoryIdentity, default: []].append(project.id)
        }
        return LinuxGitCheckoutCatalog(checkouts: checkouts,
                                       projectIDsByRepository: projectIDsByRepository)
    }

    static func read(at path: String) -> LinuxGitCheckout? {
        let files = FileManager.default
        var directory = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        // A removed nested checkout must never inherit the containing checkout's identity.
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        while true {
            let entry = directory.appendingPathComponent(".git")
            if files.fileExists(atPath: entry.path) {
                guard let gitDirectory = gitDirectory(at: entry) else { return nil }
                let identity = gitDirectory.standardizedFileURL.resolvingSymlinksInPath().path
                let linkedLocation = linkedWorktree(for: identity)
                let head = boundedText(at: gitDirectory.appendingPathComponent("HEAD"))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "ref: refs/heads/"
                let branch = head.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
                return LinuxGitCheckout(root: directory.path, identity: identity,
                                        repositoryIdentity: linkedLocation?.repository ?? identity,
                                        branch: branch, worktreeName: linkedLocation?.name)
            }
            guard directory.path != "/" else { return nil }
            directory.deleteLastPathComponent()
        }
    }

    private static func gitDirectory(at entry: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return entry }
        guard let pointer = boundedText(at: entry)?.trimmingCharacters(in: .whitespacesAndNewlines),
              pointer.hasPrefix("gitdir: ") else { return nil }
        let path = String(pointer.dropFirst("gitdir: ".count))
        let destination = URL(fileURLWithPath: path, relativeTo: entry.deletingLastPathComponent())
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: destination.appendingPathComponent("HEAD").path)
        else { return nil }
        return destination
    }

    private static func linkedWorktree(for identity: String) -> (repository: String, name: String)? {
        let parts = identity.split(separator: "/")
        guard parts.count >= 3, parts[parts.count - 2] == "worktrees" else { return nil }
        return ("/" + parts.dropLast(2).joined(separator: "/"), String(parts[parts.count - 1]))
    }

    private static func boundedText(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_097),
              data.count <= 4_096 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct LinuxGitCheckoutCatalog: Sendable {
    static let empty = LinuxGitCheckoutCatalog(checkouts: [:], projectIDsByRepository: [:])

    let checkouts: [String: LinuxGitCheckout]
    let projectIDsByRepository: [String: [String]]
}
#endif
