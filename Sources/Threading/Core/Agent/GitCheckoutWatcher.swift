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
final class GitCheckoutWatcher: @unchecked Sendable {

    /// What the watcher listens for.
    enum Scope {
        /// Everything a diff depends on: the worktree's content plus the git metadata that
        /// changes what a read would say.
        case checkout

        /// Only which branch the checkout is on — the worktree's own `HEAD`, nothing else.
        /// No worktree content is watched at all, so builds and agent edits never wake it,
        /// which is what makes an app-lifetime stream per checkout affordable.
        case branch
    }

    // MARK: - Properties

    /// The roots handed to FSEvents.
    private let watchedPaths: [String]

    /// Git metadata directories among them, whose contents are noise except for a few entries.
    private let gitDirectories: [String]

    private let scope: Scope

    private let onChange: @MainActor @Sendable () -> Void

    private var stream: FSEventStreamRef?
    private var coalesceItem: DispatchWorkItem?

    private let queue = DispatchQueue(label: "codes.threading.git-watch", qos: .utility)

    // MARK: - Initialization

    /// Fails when the path is not inside a repository — there is then nothing a review pane
    /// could refresh to.
    init?(
        root: URL,
        scope: Scope = .checkout,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let location = GitInfo.worktreeLocation(for: root.path) else { return nil }
        self.scope = scope

        switch scope {
        case .checkout:
            let gitDirectories = [location.worktreeIdentity, location.repositoryIdentity]
            self.gitDirectories = Array(Set(gitDirectories)).map { $0.standardizedPath }
            self.watchedPaths = Self.pruningContained(
                ([location.root.path] + gitDirectories).map { $0.standardizedPath }
            )
        case .branch:
            // A branch switch is a write to the worktree's *own* `HEAD` — for a linked
            // worktree that file lives in `<repo>/.git/worktrees/<name>`, so the worktree
            // identity is the one directory that needs watching in either layout.
            self.gitDirectories = [location.worktreeIdentity.standardizedPath]
            self.watchedPaths = self.gitDirectories
        }
        self.onChange = onChange
    }

    deinit {
        // `stop` only releases the stream and cancels a work item; both are safe from any queue.
        stop()
    }

    // MARK: - Public Methods

    /// Begins watching. Idempotent, so a pane that is shown twice does not open two streams.
    func start() {
        guard stream == nil, !watchedPaths.isEmpty else { return }

        // The stream holds a strong reference for as long as it lives, so a callback already
        // in flight on the watch queue cannot be running against a freed watcher. The cycle
        // this makes is broken by `stop`, which every path to going away calls.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<GitCheckoutWatcher>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<GitCheckoutWatcher>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        // File-level events, because the filtering below is per file: a directory-level report
        // of `.git` says only that something in it moved, which is true of every git command.
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<GitCheckoutWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let flags = (0..<count).map { rawFlags[$0] }
            watcher.handle(paths: paths, flags: flags)
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            GitWatchDefaults.latency,
            flags
        ) else {
            ThreadingLogger.git.error(
                "FSEvents stream could not be created for \(self.watchedPaths.first ?? "", privacy: .public)"
            )
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Stops watching and drops any coalesced notification still pending.
    func stop() {
        coalesceItem?.cancel()
        coalesceItem = nil

        guard let stream else { return }
        FSEventStreamStop(stream)
        // Stop synchronously guarantees that the callback will not run again; invalidate then
        // unschedules the stream from its dispatch queue. Do not clear the queue first:
        // FSEvents documents invalidating an already-unscheduled stream as an error.
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Private Methods

    /// Runs on `queue`. A batch that says nothing about the diff is dropped here, before it
    /// costs a main-queue hop.
    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let matters = paths.indices.contains { index in
            isRelevant(paths[index], flags: index < flags.count ? flags[index] : 0)
        }
        guard matters else { return }

        DispatchQueue.main.async { [weak self] in
            self?.scheduleNotification()
        }
    }

    /// The trailing edge of a burst. An agent's turn writes a file at a time and git's own
    /// commands rewrite the index repeatedly, so the interesting moment is the quiet after
    /// them, not the first write into them.
    private func scheduleNotification() {
        coalesceItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.coalesceItem = nil
            MainActor.assumeIsolated { self.onChange() }
        }
        coalesceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + GitWatchDefaults.coalesce, execute: item)
    }

    private func isRelevant(_ path: String, flags: FSEventStreamEventFlags) -> Bool {
        // A dropped-events or moved-root report carries no usable path; re-read rather than
        // silently show a stale diff.
        let unreliable = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
        )
        if flags & unreliable != 0 { return true }

        switch scope {
        case .checkout: return GitWatchFilter.isRelevant(path, gitDirectories: gitDirectories)
        case .branch: return GitWatchFilter.isBranchRelevant(path, gitDirectories: gitDirectories)
        }
    }

    private static func pruningContained(_ paths: [String]) -> [String] {
        GitWatchFilter.pruningContained(paths)
    }
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
