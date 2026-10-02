import Foundation

/// Watches a checkout for the writes that change what a diff would say, and reports them
/// coalesced on the main queue.
///
/// FSEvents rather than polling, for the same reason `SessionActivityTracker` reads output
/// rather than asking the agent: the tree is written by something the app does not control, so
/// the only honest signal is the write itself. A poll would either lag the agent or spend a
/// `git diff` a second on a checkout nothing touched.
///
/// Two paths are watched, not one. A linked worktree's `index` and `HEAD` live in
/// `<repo>/.git/worktrees/<name>` and its refs in `<repo>/.git/refs`, neither of which is under
/// the checkout at all — the same split `GitInfo` already resolves for reading. Paths contained
/// by another watched path are dropped, since FSEvents already reports a directory's children.
///
/// One watcher per review tab. Two sessions on one checkout run two streams rather than sharing
/// one: a stream is a kernel subscription and a filter, not a cache, and sharing would buy a
/// duplicate callback back at the cost of a registry with lifetimes to get wrong. The one
/// registry that does exist is `CheckoutBranchFollower`'s, which keeps a single *branch-scoped*
/// watcher per checkout for the app's lifetime — cheap enough to, because that scope watches
/// one file.
final class GitCheckoutWatcher: Sendable {

    /// What the watcher listens for.
    enum Scope: Sendable {
        /// Everything a diff depends on: the worktree's content plus the git metadata that
        /// changes what a read would say.
        case checkout

        /// Only which branch the checkout is on — the worktree's own `HEAD`, nothing else.
        /// No worktree content is watched at all, so builds and agent edits never wake it,
        /// which is what makes an app-lifetime stream per checkout affordable.
        case branch
    }

    private let events: FileSystemEventStream

    /// Fails when the path is not inside a repository. The cached Git identity determines the
    /// fixed watch roots; all daemon registration and teardown happen on the shared worker.
    init?(
        root: URL,
        scope: Scope = .checkout,
        backend: (any FileSystemEventStreamBackend)? = nil,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let location = GitInfo.worktreeLocation(for: root.path) else { return nil }
        let gitDirectories: [String]
        let watchedPaths: [String]
        let coalesce: TimeInterval
        switch scope {
        case .checkout:
            gitDirectories = Array(Set([location.worktreeIdentity, location.repositoryIdentity]))
                .map { $0.standardizedPath }
            watchedPaths = GitWatchFilter.pruningContained([location.root.path] + gitDirectories)
            coalesce = GitWatchDefaults.coalesce
        case .branch:
            gitDirectories = [location.worktreeIdentity.standardizedPath]
            watchedPaths = gitDirectories
            coalesce = GitWatchDefaults.branchCoalesce
        }

        events = FileSystemEventStream(
            paths: watchedPaths,
            latency: GitWatchDefaults.latency,
            coalesce: coalesce,
            isRelevant: { paths, flags in
                paths.indices.contains { index in
                    let eventFlags = index < flags.count ? flags[index] : 0
                    let unreliable = FSEventStreamEventFlags(
                        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                    )
                    if eventFlags & unreliable != 0 { return true }
                    switch scope {
                    case .checkout:
                        return GitWatchFilter.isRelevant(paths[index], gitDirectories: gitDirectories)
                    case .branch:
                        return GitWatchFilter.isBranchRelevant(paths[index], gitDirectories: gitDirectories)
                    }
                }
            },
            onChange: onChange,
            backend: backend
        )
    }

    /// Idempotent admission. An initial notification follows successful asynchronous arming.
    func start() { events.start() }

    /// Revokes queued notifications synchronously; daemon teardown runs off main.
    func stop() { events.stop() }

}

// MARK: - Filter

/// Which of FSEvents' paths are worth a git read. Pure, because this is where the traps are:
/// nearly everything a git command writes is *its own* bookkeeping, and answering "the tree
/// changed" to a lock file appearing would re-read the checkout several times per command.
enum GitWatchFilter {

    static func isRelevant(_ path: String, gitDirectories: [String]) -> Bool {
        // Lock files are how git announces it is *about* to write; the write itself follows.
        if path.hasSuffix(GitWatchDefaults.lockSuffix) { return false }

        guard let relative = gitRelativePath(for: path, gitDirectories: gitDirectories) else {
            // An ordinary file in the worktree. Whether git ignores it is not knowable here —
            // the diff read that follows is what decides.
            return true
        }
        if relative.isEmpty { return false }

        if GitWatchDefaults.gitEntriesOfInterest.contains(relative) { return true }
        return GitWatchDefaults.gitPrefixesOfInterest.contains { relative.hasPrefix($0) }
    }

    /// The `.branch` scope's whole filter: only the worktree's own `HEAD` moves a checkout
    /// between branches. Ref writes, the index, and the worktree change what a diff says,
    /// never which branch is checked out — and `HEAD.lock` misses the comparison on its own.
    static func isBranchRelevant(_ path: String, gitDirectories: [String]) -> Bool {
        gitRelativePath(for: path, gitDirectories: gitDirectories) == GitDefaults.headFile
    }

    /// The path's location inside a watched git directory, or nil when it is worktree content.
    static func gitRelativePath(for path: String, gitDirectories: [String]) -> String? {
        for directory in gitDirectories {
            if path == directory { return "" }
            if path.hasPrefix(directory + "/") {
                return String(path.dropFirst(directory.count + 1))
            }
        }
        return nil
    }

    /// FSEvents reports a directory's children, so a path already covered by another watched
    /// path is not worth a second subscription.
    static func pruningContained(_ paths: [String]) -> [String] {
        let unique = Array(Set(paths)).sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in unique where !kept.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            kept.append(path)
        }
        return kept
    }
}

// MARK: - Defaults

enum GitWatchDefaults {
    /// FSEvents' own batching window.
    static let latency: CFTimeInterval = 0.4

    /// How long the tree must be quiet before the pane re-reads. Longer than the latency on
    /// purpose: a `git checkout` or an agent's multi-file edit is many batches.
    static let coalesce: TimeInterval = 0.8

    /// The `.branch` scope's own window, an order of magnitude shorter.
    ///
    /// That scope admits one file, and git writes a checkout's `HEAD` once per switch by
    /// renaming a lock file onto it — so there is no burst to wait out, only the sidebar
    /// spending most of a second still naming the branch the user just left. What remains
    /// worth coalescing is a rebase, which rewrites `HEAD` per commit; those readings are
    /// detached and `ProjectStore.refreshBranches(forCheckoutAt:)` drops them anyway.
    static let branchCoalesce: TimeInterval = 0.1

    static let lockSuffix = ".lock"

    /// Entries of a git directory whose contents change what a diff says.
    static let gitEntriesOfInterest: Set<String> = [
        "index", "HEAD", "ORIG_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
        "REBASE_HEAD", "packed-refs"
    ]

    /// Directories of a git directory, matched by prefix: refs of every kind, and the per
    /// worktree metadata holding another checkout's `index` and `HEAD`.
    static let gitPrefixesOfInterest = ["refs/", "worktrees/"]
}

// MARK: - Path Helpers

private extension String {
    /// FSEvents reports resolved paths (`/private/var…`), so the watched roots must be resolved
    /// too or every prefix comparison misses.
    var standardizedPath: String {
        URL(fileURLWithPath: self).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
