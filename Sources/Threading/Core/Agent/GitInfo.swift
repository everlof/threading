import Foundation
import os

/// Reads git metadata for a project folder.
///
/// Values are read directly from the `.git` directory rather than by shelling out, so
/// they can be refreshed cheaply without spawning a process per project.
enum GitInfo {

    private enum CachedWorktreeLocation {
        case found(WorktreeLocation)
        case missing

        var value: WorktreeLocation? {
            switch self {
            case .found(let location): return location
            case .missing: return nil
            }
        }
    }

    private static let worktreeLocations = OSAllocatedUnfairLock(
        initialState: [String: CachedWorktreeLocation]()
    )

    // MARK: - Public Methods

    /// Returns the repository root containing `path`, or nil when not inside a git repository.
    static func repositoryRoot(for path: String) -> URL? {
        var directory = URL(fileURLWithPath: path).standardizedFileURL
        // A removed nested worktree is not a subdirectory of its former containing
        // checkout. Walking up from a missing path would borrow that checkout's branch
        // and repository identity for a saved project that no longer exists.
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }

        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }

        return nil
    }

    /// Returns the currently checked out branch name, or nil when unavailable or detached.
    ///
    /// Reads `HEAD`, which holds either a `ref:` line naming the branch or a bare commit
    /// hash when the head is detached.
    static func currentBranch(for path: String) -> String? {
        guard let location = worktreeLocation(for: path) else { return nil }

        let headURL = URL(fileURLWithPath: location.worktreeIdentity)
            .appendingPathComponent(GitDefaults.headFile)
        guard let contents = boundedString(at: headURL, maximumBytes: GitDefaults.maximumControlFileBytes)
        else { return nil }

        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(GitDefaults.refPrefix) else {
            return nil  // Detached HEAD: a bare commit hash, not a branch.
        }

        return String(trimmed.dropFirst(GitDefaults.refPrefix.count))
    }

    /// Returns the commit currently checked out in a worktree.
    ///
    /// A symbolic `HEAD` usually resolves in the repository's shared refs directory, while a
    /// detached `HEAD` contains the commit directly. Loose refs win over `packed-refs`, matching
    /// git's own lookup order.
    static func headRevision(for path: String) -> String? {
        guard let location = worktreeLocation(for: path) else { return nil }

        let headURL = URL(fileURLWithPath: location.worktreeIdentity)
            .appendingPathComponent(GitDefaults.headFile)
        guard let contents = boundedString(at: headURL, maximumBytes: GitDefaults.maximumControlFileBytes) else {
            return nil
        }

        let head = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.hasPrefix("ref: ") else {
            return isCommitHash(head) ? head : nil
        }

        let reference = String(head.dropFirst("ref: ".count))
        let candidates = [
            URL(fileURLWithPath: location.worktreeIdentity).appendingPathComponent(reference),
            URL(fileURLWithPath: location.repositoryIdentity).appendingPathComponent(reference)
        ]
        for candidate in candidates {
            if let value = boundedString(
                at: candidate,
                maximumBytes: GitDefaults.maximumControlFileBytes
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
               isCommitHash(value) {
                return value
            }
        }

        let packedRefs = URL(fileURLWithPath: location.repositoryIdentity)
            .appendingPathComponent(GitDefaults.packedRefsFile)
        return packedReference(reference, at: packedRefs)
    }

    /// Suggests a project name for a folder.
    ///
    /// The folder's own name is used when it differs from the repository root, so two
    /// packages added out of the same monorepo do not both end up named after the repo.
    static func suggestedProjectName(for folderURL: URL) -> String {
        folderURL.standardizedFileURL.lastPathComponent
    }

    /// The repository path of a folder relative to its root, e.g. `packages/api`.
    ///
    /// Nil when the folder *is* the root, or is not in a repository, so callers can show
    /// this only when it adds something.
    static func pathWithinRepository(for folderURL: URL) -> String? {
        let folder = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let root = repositoryRoot(for: folder.path)?.resolvingSymlinksInPath(),
              folder.path != root.path,
              folder.path.hasPrefix(root.path + "/") else { return nil }

        return String(folder.path.dropFirst(root.path.count + 1))
    }

    /// A folder's place in git, resolved in one pass: the worktree it belongs to and the
    /// repository above that.
    ///
    /// The distinction is the whole point of telling worktrees apart. `worktreeIdentity` is the
    /// worktree's own git directory — `git rev-parse --git-dir` — which is stable per checkout
    /// and *does not change when the branch does*. `repositoryIdentity` is the shared git
    /// directory — `git rev-parse --git-common-dir` — one per repository across all its
    /// worktrees. Read off disk rather than by shelling out; both are `.git` paths.
    struct WorktreeLocation: Equatable {
        /// The worktree's root — the directory holding its `.git` — so a path that sits in a
        /// subdirectory resolves back to the checkout it belongs to.
        let root: URL

        /// Stable per-worktree identity: `<repo>/.git` for the main checkout,
        /// `<repo>/.git/worktrees/<name>` for a linked one.
        let worktreeIdentity: String

        /// Stable per-repository identity, shared by every worktree of the repo.
        let repositoryIdentity: String

        /// The linked worktree's name, or nil for the main checkout.
        let worktreeName: String?
    }

    /// Resolves a path's worktree and repository, or nil when it is not inside a repository.
    static func worktreeLocation(for path: String) -> WorktreeLocation? {
        let key = cacheKey(for: path)
        if let cached = worktreeLocations.withLock({ $0[key] }) {
            return cached.value
        }

        let location = resolveWorktreeLocation(for: path)
        worktreeLocations.withLock {
            $0[key] = location.map(CachedWorktreeLocation.found) ?? .missing
        }
        return location
    }

    /// Drops the checkout memo before a stopped session refreshes its git state. Every cached
    /// path known to resolve to the same worktree is removed together.
    static func invalidateCache(for path: String) {
        let key = cacheKey(for: path)
        worktreeLocations.withLock { entries in
            let identity = entries[key]?.value?.worktreeIdentity
            entries = entries.filter { candidateKey, entry in
                guard candidateKey != key else { return false }
                guard let identity else { return true }
                return entry.value?.worktreeIdentity != identity
            }
        }
    }

    private static func resolveWorktreeLocation(for path: String) -> WorktreeLocation? {
        guard let root = repositoryRoot(for: path),
              let gitDirectory = gitDirectory(for: root) else { return nil }

        let identity = gitDirectory.path

        // A linked worktree's git dir ends in `/worktrees/<name>`; trimming that yields the
        // repository shared by every worktree, and the component after it is the name.
        guard let range = identity.range(of: GitDefaults.worktreesComponent) else {
            return WorktreeLocation(
                root: root,
                worktreeIdentity: identity,
                repositoryIdentity: identity,
                worktreeName: nil
            )
        }

        return WorktreeLocation(
            root: root,
            worktreeIdentity: identity,
            repositoryIdentity: String(identity[identity.startIndex..<range.lowerBound]),
            worktreeName: identity[range.upperBound...].split(separator: "/").first.map(String.init)
        )
    }

    /// Stable identity of the worktree a folder is a checkout of — the key for "which
    /// checkout", where the branch is only ever a display value.
    static func worktreeIdentity(for path: String) -> String? {
        worktreeLocation(for: path)?.worktreeIdentity
    }

    /// The name of the linked worktree a folder is a checkout of, or nil for an ordinary
    /// checkout — the repository's main working tree, or a folder outside any repository.
    static func worktreeName(for path: String) -> String? {
        worktreeLocation(for: path)?.worktreeName
    }

    /// Identifies the repository a folder belongs to, shared by all of its worktrees.
    static func repositoryIdentity(for path: String) -> String? {
        worktreeLocation(for: path)?.repositoryIdentity
    }

    /// Whether a path is a repository's own working tree, rather than a linked worktree or a
    /// directory inside one.
    ///
    /// Both halves are load-bearing. Without the first, a linked worktree would answer for the
    /// repository. Without the second, a monorepo package — `mono/packages/api`, which resolves
    /// to `mono`'s git directory and has no worktree name — would answer for it too, and name
    /// the whole repository after itself.
    ///
    /// One memoized `worktreeLocation` read: every caller here has already asked this path for
    /// its branch or its identity, so this is a cache hit rather than a second walk.
    static func isMainWorkingTree(_ path: String) -> Bool {
        guard let location = worktreeLocation(for: path) else { return false }

        return location.worktreeName == nil
            && location.root.standardizedFileURL.path
                == URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The URL of the repository's `origin` remote, or nil when there is none.
    ///
    /// Read from the *shared* git directory's config — remotes belong to the repository,
    /// not a checkout — so every worktree of a repo answers the same.
    static func remoteOriginURL(for path: String) -> String? {
        guard let identity = repositoryIdentity(for: path) else { return nil }

        let configURL = URL(fileURLWithPath: identity)
            .appendingPathComponent(GitDefaults.configFile)
        guard let contents = boundedString(
            at: configURL,
            maximumBytes: GitDefaults.maximumConfigBytes
        ) else { return nil }

        var inOriginSection = false
        for rawLine in contents.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("[") {
                inOriginSection = line == GitDefaults.originSectionHeader
                continue
            }

            guard inOriginSection else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == GitDefaults.remoteURLKey
            else { continue }

            let url = parts[1].trimmingCharacters(in: .whitespaces)
            return url.isEmpty ? nil : url
        }

        return nil
    }

    /// Display name for a repository identity, e.g. `/Users/me/sonda/.git` becomes `sonda`.
    static func repositoryName(forIdentity identity: String) -> String {
        let url = URL(fileURLWithPath: identity)

        // A submodule's identity ends in `/modules/<name>`, where the name is the last
        // component rather than the directory containing `.git`.
        if identity.contains(GitDefaults.modulesComponent) {
            return url.lastPathComponent
        }

        return url.deletingLastPathComponent().lastPathComponent
    }

    // MARK: - Private Methods

    private static func cacheKey(for path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isCommitHash(_ value: String) -> Bool {
        (40...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }

    /// Resolves the directory holding a checkout's git metadata.
    ///
    /// Usually `<root>/.git`, but submodules and worktrees put a *file* there containing a
    /// `gitdir:` pointer to the real location, so reading `<root>/.git/HEAD` finds nothing.
    private static func gitDirectory(for root: URL) -> URL? {
        let dotGit = root.appendingPathComponent(GitDefaults.gitEntry)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return dotGit
        }

        guard let contents = boundedString(
            at: dotGit,
            maximumBytes: GitDefaults.maximumControlFileBytes
        ) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(GitDefaults.gitDirPrefix) else { return nil }

        let pointer = String(trimmed.dropFirst(GitDefaults.gitDirPrefix.count))
            .trimmingCharacters(in: .whitespaces)

        // The pointer is absolute for worktrees and relative for submodules.
        let resolved = pointer.hasPrefix("/")
            ? URL(fileURLWithPath: pointer)
            : root.appendingPathComponent(pointer)

        return resolved.standardizedFileURL
    }

    private static func boundedString(at url: URL, maximumBytes: Int) -> String? {
        guard let data = try? BoundedFileReader.read(url, maximumBytes: maximumBytes) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// `packed-refs` scales with repository history and can legitimately be very large. Scan it
    /// in bounded chunks instead of making every project snapshot allocate the whole file.
    private static func packedReference(_ reference: String, at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var pending = Data()
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 64 * 1024), !read.isEmpty else {
                    break
                }
                chunk = read
            } catch {
                return nil
            }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                if let revision = packedRevision(in: line, matching: reference) {
                    return revision
                }
            }
            guard pending.count <= GitDefaults.maximumPackedRefLineBytes else { return nil }
        }
        guard !pending.isEmpty else { return nil }
        return packedRevision(
            in: String(decoding: pending, as: UTF8.self),
            matching: reference
        )
    }

    private static func packedRevision(in line: String, matching reference: String) -> String? {
        guard !line.hasPrefix("#"), !line.hasPrefix("^") else { return nil }
        let fields = line.split(separator: " ", maxSplits: 1)
        guard fields.count == 2, fields[1] == reference else { return nil }
        let value = String(fields[0])
        return isCommitHash(value) ? value : nil
    }
}

// MARK: - Git Defaults

enum GitDefaults {
    static let maximumControlFileBytes = 64 * 1024
    static let maximumConfigBytes = 4 * 1024 * 1024
    static let maximumPackedRefLineBytes = 4 * 1024
    /// Prefix of a symbolic `HEAD` entry, followed by the branch ref path.
    static let refPrefix = "ref: refs/heads/"

    static let gitEntry = ".git"
    static let headFile = "HEAD"

    /// Absolute path, since a GUI app cannot rely on `git` being on its inherited `PATH`.
    static let executablePath = "/usr/bin/git"

    /// Prefix of the pointer a submodule or worktree stores in place of a `.git` directory.
    static let gitDirPrefix = "gitdir:"

    /// Path components git uses for linked worktrees and submodules respectively.
    static let worktreesComponent = "/worktrees/"
    static let modulesComponent = "/modules/"

    /// The repository-level config file, holding among other things its remotes.
    static let configFile = "config"
    static let packedRefsFile = "packed-refs"
    static let originSectionHeader = "[remote \"origin\"]"
    static let remoteURLKey = "url"
}
