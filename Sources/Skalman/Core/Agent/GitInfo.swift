import Foundation

/// Reads git metadata for a project folder.
///
/// Values are read directly from the `.git` directory rather than by shelling out, so
/// they can be refreshed cheaply without spawning a process per project.
enum GitInfo {

    // MARK: - Public Methods

    /// Returns the repository root containing `path`, or nil when not inside a git repository.
    static func repositoryRoot(for path: String) -> URL? {
        var directory = URL(fileURLWithPath: path).standardizedFileURL

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
        guard let root = repositoryRoot(for: path),
              let gitDirectory = gitDirectory(for: root) else { return nil }

        let headURL = gitDirectory.appendingPathComponent(GitDefaults.headFile)
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }

        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(GitDefaults.refPrefix) else {
            return nil  // Detached HEAD: a bare commit hash, not a branch.
        }

        return String(trimmed.dropFirst(GitDefaults.refPrefix.count))
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

        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
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
}

// MARK: - Git Defaults

enum GitDefaults {
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
}
