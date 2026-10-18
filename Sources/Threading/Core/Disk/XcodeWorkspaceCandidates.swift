import Foundation

/// The workspaces a manifest-less DerivedData folder could have been built for, keyed by the hash
/// Xcode would have named its folder with (`XcodeDerivedDataName`).
///
/// A folder without `info.plist` still carries that hash, and a hash is only useful against a path
/// to recompute it from. Those paths are the checkouts Threading has a record of — each project's
/// folder, every session's working directory (a managed worktree's included, after it is
/// removed), and every worktree git itself records for a project, the ones deleted without a
/// prune included — each joined to wherever that project keeps its Xcode project or workspace,
/// learned from the project's own folder. A candidate that matches and no longer exists is proof
/// the cache is orphaned; one that matches and exists attributes it; no match leaves it
/// unattributed, never orphaned.
///
/// Built on the scan's background queue. Every step is bounded: the project-file search, the
/// worktree records read, and the candidates hashed.
struct XcodeWorkspaceCandidates: Sendable, Equatable {

    /// One project's contribution: its own folder, and the other checkouts known to belong to it.
    struct Project: Sendable, Equatable {
        let folder: String
        let checkouts: [String]
    }

    /// Workspace path by Xcode's hash of it.
    let byHash: [String: String]

    static let empty = XcodeWorkspaceCandidates(byHash: [:])

    private enum Limits {
        /// Entries examined per project folder looking for `.xcodeproj` and `.xcworkspace`.
        static let searchedEntries = 4_000
        /// How deep a project file may sit: `App.xcodeproj` or `ios/App.xcodeproj`, the two
        /// layouts every project on the measuring machine used.
        static let searchDepth = 2
        /// Worktree records read per repository.
        static let worktreeRecords = 1_024
        static let recordBytes = 4_096
        /// Candidates hashed in all.
        static let candidates = 100_000
    }

    /// Directories never searched for a project file: build output and dependencies, which can
    /// be enormous and hold vendored projects nobody opens.
    private static let skippedDirectories: Set<String> = [
        "node_modules", "build", "Build", "DerivedData", "Pods", "target", "dist", "vendor", "Carthage"
    ]

    private static let projectExtensions: Set<String> = ["xcodeproj", "xcworkspace"]

    // MARK: - Gathering

    static func gather(_ projects: [Project], fileManager: FileManager = .default) -> XcodeWorkspaceCandidates {
        var byHash: [String: String] = [:]
        var budget = Limits.candidates

        for project in projects {
            let folder = standardized(project.folder)
            let relativeFiles = projectFiles(in: folder, fileManager: fileManager)
            guard !relativeFiles.isEmpty else { continue }

            let checkouts = Set([folder] + project.checkouts.map(standardized)
                + worktreeRecords(of: folder, fileManager: fileManager))
            for checkout in checkouts.sorted() {
                for relative in relativeFiles {
                    guard budget > 0 else { return XcodeWorkspaceCandidates(byHash: byHash) }
                    budget -= 1
                    let path = checkout + "/" + relative
                    byHash[XcodeDerivedDataName.hash(forWorkspace: path)] = path
                }
            }
        }
        return XcodeWorkspaceCandidates(byHash: byHash)
    }

    // MARK: - Private

    /// Project files under `folder`, as paths relative to it.
    private static func projectFiles(in folder: String, fileManager: FileManager) -> [String] {
        var found: [String] = []
        var examined = 0
        var pending: [(relative: String, depth: Int)] = [("", 0)]

        while let (relative, depth) = pending.popLast() {
            let directory = relative.isEmpty ? folder : folder + "/" + relative
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }

            for name in names.sorted() where !name.hasPrefix(".") {
                examined += 1
                guard examined <= Limits.searchedEntries else { return found }

                let path = relative.isEmpty ? name : relative + "/" + name
                if projectExtensions.contains((name as NSString).pathExtension) {
                    found.append(path)
                } else if depth + 1 < Limits.searchDepth,
                          !skippedDirectories.contains(name),
                          isRealDirectory(folder + "/" + path, fileManager: fileManager) {
                    pending.append((path, depth + 1))
                }
            }
        }
        return found
    }

    /// The checkouts git records as this repository's worktrees, read from
    /// `.git/worktrees/*/gitdir`. A worktree deleted without `git worktree prune` is still
    /// recorded, which is exactly the case worth knowing about.
    private static func worktreeRecords(of folder: String, fileManager: FileManager) -> [String] {
        let records = folder + "/.git/worktrees"
        guard let names = try? fileManager.contentsOfDirectory(atPath: records) else { return [] }

        return names.prefix(Limits.worktreeRecords).compactMap { name in
            guard let handle = FileHandle(forReadingAtPath: records + "/" + name + "/gitdir") else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: Limits.recordBytes),
                  let line = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  line.hasSuffix("/.git") else { return nil }
            return standardized(String(line.dropLast("/.git".count)))
        }
    }

    private static func isRealDirectory(_ path: String, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    /// Only a trailing slash is dropped. Xcode hashes the path string it was given, and any
    /// further normalising — resolving symlinks, or Foundation's habit of trimming `/private` —
    /// would hash a different string from the one it used.
    private static func standardized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
