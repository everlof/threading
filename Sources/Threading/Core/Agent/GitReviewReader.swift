import Foundation

/// Checkout-preserving git operations for the review pane: diffs, status, history and turn
/// snapshots. Snapshots use a private alternate index; durable turn endpoints are then published
/// under Threading's private ref hierarchy. No operation mutates the checkout's real index or
/// worktree.
///
/// Everything runs `git` on a dedicated queue and completes on main — a branch diff can be
/// megabytes, and neither spawning nor parsing belongs on the thread that draws. Every
/// invocation passes `--no-optional-locks`, so a read never takes `index.lock` out from
/// under the agent working in the same checkout.
enum GitReviewReader {

    // MARK: - Types

    /// Shared with the index writer, so one vocabulary of failures reaches the pane.
    typealias Failure = GitFailure

    /// What to diff. The working-tree cases synthesize untracked files in; the others are
    /// exactly what git reports.
    enum DiffRequest: Sendable {
        case uncommitted
        case unstaged
        case staged
        case branch
        case lastTurn(GitTurnBaseline)
        case turnCheckpoint(GitTurnCheckpoint)
        case commit(hash: String)
    }

    // MARK: - Properties

    private static let queue = DispatchQueue(label: "codes.threading.git-review", qos: .userInitiated)

    /// Turn admission must not wait behind a large review already being parsed — or behind a
    /// different session whose checkout is slow. Each capture owns a UUID-named alternate index,
    /// and git's object writes are atomic, so independent session baselines can safely overlap.
    private static let snapshotQueue = DispatchQueue(
        label: "codes.threading.git-turn-snapshot",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Status summaries feed navigation chrome and must not wait behind a megabyte-scale review
    /// diff already being parsed on `queue`. They are intentionally independent reads: both are
    /// read-only (`--no-optional-locks`), while making this serial with the review made switching
    /// sessions inherit the cost of whichever diff happened to be open before it.
    private static let summaryQueue = DispatchQueue(
        label: "codes.threading.git-summary",
        qos: .userInitiated
    )

    /// Ref transactions are serialized within one repository, while unrelated repositories can
    /// still capture concurrently. Git already locks its ref backend; this narrower app-level
    /// ordering additionally keeps retention deletion from racing a final publication we own.
    private static let refQueueLock = NSLock()
    nonisolated(unsafe) private static var refQueues: [String: DispatchQueue] = [:]

    // MARK: - Public Methods

    /// The diff for a request, parsed into per-file models. Completion arrives on main.
    static func diff(
        _ request: DiffRequest,
        in root: URL,
        ignoringWhitespace: Bool = false,
        completion: @escaping @MainActor @Sendable (Result<[GitFileDiff], Failure>) -> Void
    ) {
        perform(
            "git.read.diff",
            metadata: ["comparison": metricName(for: request)],
            completion
        ) {
            try performDiff(request, in: root, ignoringWhitespace: ignoringWhitespace)
        }
    }

    /// The raw unified-diff patch for a request, exactly as git writes it — for handing the
    /// changes to `git apply`. Reconstructing it from the parsed model would drop the file
    /// headers `git apply` reads (new-file, deleted-file, rename), so it is re-read rather than
    /// rebuilt. Working-tree modes omit synthesized untracked rows; Last Turn is the exception
    /// because both endpoints are complete trees and git emits those files itself. Completion on main.
    static func rawDiff(
        _ request: DiffRequest,
        in root: URL,
        ignoringWhitespace: Bool = false,
        completion: @escaping @MainActor @Sendable (Result<String, Failure>) -> Void
    ) {
        perform(
            "git.read.raw-diff",
            metadata: ["comparison": metricName(for: request)],
            completion
        ) {
            GitDiffParser.decode(try rawDiffData(request, in: root, ignoringWhitespace: ignoringWhitespace))
        }
    }

    /// One page of history, newest first. Completion arrives on main.
    static func log(
        skip: Int,
        in root: URL,
        completion: @escaping @MainActor @Sendable (Result<[GitCommitSummary], Failure>) -> Void
    ) {
        perform("git.read.log", metadata: ["skip": String(skip)], completion) {
            guard hasCommits(in: root) else { throw Failure.noCommits }
            return GitDiffParser.commits(fromLog: try run(GitReviewCommands.log(skip: skip), in: root))
        }
    }

    /// The checkout's tracked and non-ignored untracked files, sorted for a compact browser.
    static func repositoryFiles(
        in root: URL,
        completion: @escaping @MainActor @Sendable (Result<[String], Failure>) -> Void
    ) {
        perform("git.read.repository-files", completion) {
            try repositoryFilePaths(in: root)
        }
    }

    /// Reads one repository-relative file after proving it belongs to git's visible file list
    /// and remains inside the checkout after resolving symlinks. The byte cap applies before
    /// decoding, so a remote request cannot turn a large generated file into a large allocation.
    static func repositoryFile(
        path: String,
        in root: URL,
        completion: @escaping @MainActor @Sendable (Result<GitRepositoryFile, Failure>) -> Void
    ) {
        perform("git.read.repository-file", completion) {
            guard try repositoryFilePaths(in: root).contains(path) else {
                throw Failure.gitFailed("File not found.")
            }

            let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            let candidate = resolvedRoot
                .appendingPathComponent(path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let rootPrefix = resolvedRoot.path.hasSuffix("/")
                ? resolvedRoot.path
                : resolvedRoot.path + "/"
            guard candidate.path.hasPrefix(rootPrefix),
                  let values = try? candidate.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                  ]),
                  values.isRegularFile == true else {
                throw Failure.gitFailed("File not found.")
            }

            let cap = GitReviewDefaults.remoteRepositoryFileByteCap
            let handle = try FileHandle(forReadingFrom: candidate)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: cap + 1) ?? Data()
            let truncated = data.count > cap
            let bounded = truncated ? Data(data.prefix(cap)) : data
            let binary = bounded.prefix(GitReviewDefaults.binarySniffBytes).contains(0)

            return GitRepositoryFile(
                path: path,
                content: binary ? nil : GitDiffParser.decode(bounded),
                isBinary: binary,
                isTruncated: truncated
            )
        }
    }

    /// One file's bytes at a request's two endpoints, for the image rows: the old side from
    /// the revision the diff measured from, the new side from what it measured to.
    ///
    /// A side git does not hold at its endpoint comes back nil rather than failing the pair —
    /// that is exactly what an added, deleted, or untracked file looks like. A renamed binary
    /// is the accepted gap: the parser collapses it to `.binary` under its *new* path, so the
    /// old side reads as missing and the pair presents as added.
    static func endpointFilePair(
        path: String,
        request: DiffRequest,
        in root: URL,
        completion: @escaping @MainActor @Sendable (Result<GitEndpointFilePair, Failure>) -> Void
    ) {
        perform(
            "git.read.endpoint-file-pair",
            metadata: ["comparison": metricName(for: request)],
            completion
        ) {
            let (old, new) = try endpoints(for: request, in: root)
            return GitEndpointFilePair(
                old: bytes(at: old, path: path, in: root),
                new: bytes(at: new, path: path, in: root),
                oldTitle: old.title,
                newTitle: new.title
            )
        }
    }

    /// The newest commit subjects — the commit draft's voice sample. An unborn HEAD is an
    /// empty sample, not an error: a first commit simply has no voice to match yet.
    /// Completion arrives on main.
    static func recentSubjects(
        count: Int,
        in root: URL,
        completion: @escaping @MainActor @Sendable (Result<[String], Failure>) -> Void
    ) {
        perform(
            "git.read.recent-subjects",
            on: summaryQueue,
            metadata: ["count": String(count)],
            completion
        ) {
            guard hasCommits(in: root) else { return [] }
            return GitDiffParser.decode(
                try run(GitReviewCommands.recentSubjects(count: count), in: root)
            )
            .split(separator: "\n")
            .map(String.init)
        }
    }

    /// The uncommitted totals for the floating status card: numstat against HEAD plus
    /// untracked line counts, without producing a single hunk. Completion arrives on main.
    static func uncommittedSummary(
        in root: URL,
        completion: @escaping @MainActor @Sendable (Result<GitChangeSummary, Failure>) -> Void
    ) {
        perform("git.read.uncommitted-summary", on: summaryQueue, completion) {
            // The same unborn-HEAD rule as the full uncommitted diff: compare the empty tree
            // to the worktree, not merely to the index. A newly staged file may have been
            // edited again before the first commit and those latest bytes are still uncommitted.
            let baseline = hasCommits(in: root)
                ? GitReviewCommands.head
                : try emptyTree(in: root)
            let tracked = GitDiffParser.summary(fromNumstat: try run(
                GitReviewCommands.diffNumstat(against: baseline),
                in: root
            ))
            let untracked = try untrackedSummary(in: root)

            return GitChangeSummary(
                files: tracked.files + untracked.files,
                added: tracked.added + untracked.added,
                removed: tracked.removed
            )
        }
    }

    /// Captures the checkout's current state as a Last Turn baseline. Completion arrives on main.
    static func createSnapshot(
        in root: URL,
        completion: @escaping @MainActor @Sendable (Result<GitTurnBaseline, Failure>) -> Void
    ) {
        perform("git.read.create-snapshot", on: snapshotQueue, completion) {
            return GitTurnBaseline(
                treeHash: try workingTreeSnapshot(in: root),
                capturedAt: Date()
            )
        }
    }

    /// Captures the exact working-copy bytes and publishes the resulting tree at an app-owned
    /// ref. The real index and worktree are only read. Completion arrives on main.
    static func createCheckpointSnapshot(
        ref: String,
        expectedRepositoryIdentity: String,
        in root: URL,
        completion: @escaping @MainActor @Sendable (Result<GitTurnBaseline, Failure>) -> Void
    ) {
        perform("git.write.create-turn-checkpoint", on: snapshotQueue, completion) {
            guard GitTurnCheckpointRefs.isOwned(ref),
                  GitInfo.worktreeLocation(for: root.path)?.repositoryIdentity
                    == expectedRepositoryIdentity else {
                throw Failure.checkpointRepositoryMismatch
            }

            let baseline = GitTurnBaseline(
                treeHash: try workingTreeSnapshot(in: root),
                capturedAt: Date()
            )
            try refQueue(for: expectedRepositoryIdentity).sync {
                _ = try run(GitReviewCommands.updateRef(ref, to: baseline.treeHash), in: root)
            }
            return baseline
        }
    }

    /// Removes only explicitly named refs inside Threading's namespace. A caller cannot turn
    /// this into a branch, tag, remote-ref, or namespace-wide deletion.
    static func deleteCheckpointRefs(
        _ refs: [String],
        expectedRepositoryIdentity: String,
        in root: URL,
        completion: @escaping @MainActor @Sendable (Result<Void, Failure>) -> Void
    ) {
        perform("git.write.delete-turn-checkpoints", on: snapshotQueue, completion) {
            guard !refs.isEmpty else { return }
            guard refs.allSatisfy(GitTurnCheckpointRefs.isOwned),
                  GitInfo.worktreeLocation(for: root.path)?.repositoryIdentity
                    == expectedRepositoryIdentity else {
                throw Failure.checkpointRepositoryMismatch
            }

            try refQueue(for: expectedRepositoryIdentity).sync {
                for ref in refs {
                    _ = try run(GitReviewCommands.deleteRef(ref), in: root)
                }
            }
        }
    }

    /// Lists only well-formed refs in Threading's private namespace for startup reconciliation.
    /// Repository identity is checked before the namespace is read, matching capture and delete.
    static func checkpointRefs(
        expectedRepositoryIdentity: String,
        in root: URL,
        completion: @escaping @MainActor @Sendable (Result<[String], Failure>) -> Void
    ) {
        perform("git.read.turn-checkpoint-refs", on: snapshotQueue, completion) {
            guard GitInfo.worktreeLocation(for: root.path)?.repositoryIdentity
                    == expectedRepositoryIdentity else {
                throw Failure.checkpointRepositoryMismatch
            }
            return GitDiffParser.decode(try run(GitReviewCommands.checkpointRefs(), in: root))
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .filter(GitTurnCheckpointRefs.isOwned)
        }
    }

    // MARK: - Private Methods

    private static func perform<Value: Sendable>(
        _ operation: StaticString,
        on queue: DispatchQueue = GitReviewReader.queue,
        metadata: [String: String] = [:],
        _ completion: @escaping @MainActor @Sendable (Result<Value, Failure>) -> Void,
        _ work: @escaping @Sendable () throws -> Value
    ) {
        let span = PerformanceRecorder.shared.begin(
            operation,
            category: "git.background",
            metadata: metadata
        )
        queue.async {
            let result: Result<Value, Failure>
            do {
                result = .success(try work())
            } catch let failure as Failure {
                result = .failure(failure)
            } catch {
                result = .failure(.gitFailed(error.localizedDescription))
            }
            let metricResult: String
            switch result {
            case .success: metricResult = "success"
            case .failure: metricResult = "failure"
            }
            span.end(metadata: [
                "result": metricResult
            ])
            Task { @MainActor in
                completion(result)
            }
        }
    }

    /// Stable, aggregate comparison names for telemetry. `String(describing:)` would include
    /// commit hashes and Last Turn baseline details, neither of which belongs in a trace.
    private static func metricName(for request: DiffRequest) -> String {
        switch request {
        case .uncommitted: return "uncommitted"
        case .unstaged: return "unstaged"
        case .staged: return "staged"
        case .branch: return "branch"
        case .lastTurn: return "last-turn"
        case .turnCheckpoint: return "turn-checkpoint"
        case .commit: return "commit"
        }
    }

    private static func performDiff(
        _ request: DiffRequest,
        in root: URL,
        ignoringWhitespace: Bool
    ) throws -> [GitFileDiff] {
        let tracked = GitDiffParser.files(fromUnifiedDiff: GitDiffParser.decode(
            try trackedDiffData(request, in: root, ignoringWhitespace: ignoringWhitespace)
        ))

        // The working-tree modes append untracked files, which `git diff` never mentions; a
        // commit or the raw-patch path speaks only for what git already reported.
        switch request {
        case .unstaged, .uncommitted, .branch:
            return try tracked + untrackedDiffs(in: root, excluding: [])
        case .lastTurn, .turnCheckpoint:
            // Both endpoints are trees, so untracked files are already represented exactly.
            return tracked
        case .staged, .commit:
            return tracked
        }
    }

    /// The exact bytes git writes for a request's tracked diff, shared by the parsed and raw
    /// paths so both speak from the same command for every mode.
    private static func rawDiffData(
        _ request: DiffRequest,
        in root: URL,
        ignoringWhitespace: Bool
    ) throws -> Data {
        try trackedDiffData(request, in: root, ignoringWhitespace: ignoringWhitespace)
    }

    private static func trackedDiffData(
        _ request: DiffRequest,
        in root: URL,
        ignoringWhitespace: Bool
    ) throws -> Data {
        let ws = ignoringWhitespace
        switch request {
        case .staged:
            return try run(GitReviewCommands.diffStaged(ignoringWhitespace: ws), in: root)

        case .unstaged:
            return try run(GitReviewCommands.diff(against: nil, ignoringWhitespace: ws), in: root)

        case .uncommitted:
            // On an unborn HEAD, a real empty tree preserves the normal ref→worktree semantics.
            // `--cached` would stop at the index and miss edits made after a file was staged.
            let baseline = hasCommits(in: root)
                ? GitReviewCommands.head
                : try emptyTree(in: root)
            return try run(
                GitReviewCommands.diff(against: baseline, ignoringWhitespace: ws),
                in: root
            )

        case .branch:
            guard hasCommits(in: root) else { throw Failure.noCommits }
            let base = try defaultBranch(in: root)
            let mergeBase = decodeTrimmed(try run(GitReviewCommands.mergeBase(base), in: root))
            return try run(GitReviewCommands.diff(against: mergeBase, ignoringWhitespace: ws), in: root)

        case .lastTurn(let baseline):
            guard treeExists(baseline.treeHash, in: root) else { throw Failure.baselineExpired }
            let currentTree = try workingTreeSnapshot(in: root)
            return try run(
                GitReviewCommands.diff(
                    from: baseline.treeHash,
                    to: currentTree,
                    ignoringWhitespace: ws
                ),
                in: root
            )

        case .turnCheckpoint(let checkpoint):
            let trees = try checkpointTrees(checkpoint, in: root)
            return try run(
                GitReviewCommands.diff(
                    from: trees.before,
                    to: trees.after,
                    ignoringWhitespace: ws
                ),
                in: root
            )

        case .commit(let hash):
            return try run(GitReviewCommands.show(hash, ignoringWhitespace: ws), in: root)
        }
    }

    // MARK: - Endpoints

    /// Where one side of a request's diff lives: a revision `git show` can address, or the
    /// working tree itself.
    private enum Endpoint {
        case revision(String, title: String)
        case worktree

        var title: String {
            switch self {
            case .revision(_, let title): return title
            case .worktree: return L10n.string("Working Tree")
            }
        }
    }

    /// The two endpoints each request measures between — the same pairs `trackedDiffData`'s
    /// commands imply, stated as addresses a single file can be read from.
    private static func endpoints(for request: DiffRequest, in root: URL) throws -> (Endpoint, Endpoint) {
        switch request {
        case .staged:
            return (
                .revision(GitReviewCommands.head, title: "HEAD"),
                .revision(":0", title: L10n.string("Index"))
            )
        case .unstaged:
            return (.revision(":0", title: L10n.string("Index")), .worktree)
        case .uncommitted:
            if hasCommits(in: root) {
                return (.revision(GitReviewCommands.head, title: "HEAD"), .worktree)
            }
            return (
                .revision(try emptyTree(in: root), title: L10n.string("Empty Tree")),
                .worktree
            )
        case .branch:
            let base = try defaultBranch(in: root)
            let mergeBase = decodeTrimmed(try run(GitReviewCommands.mergeBase(base), in: root))
            return (.revision(mergeBase, title: L10n.string("Merge Base")), .worktree)
        case .lastTurn(let baseline):
            guard treeExists(baseline.treeHash, in: root) else { throw Failure.baselineExpired }
            let currentTree = try workingTreeSnapshot(in: root)
            return (
                .revision(baseline.treeHash, title: L10n.string("Turn Start")),
                .revision(currentTree, title: L10n.string("Working Tree"))
            )
        case .turnCheckpoint(let checkpoint):
            let trees = try checkpointTrees(checkpoint, in: root)
            return (
                .revision(trees.before, title: L10n.string("Turn Start")),
                .revision(
                    trees.after,
                    title: checkpoint.status == .complete
                        ? L10n.string("Turn End")
                        : L10n.string("Working Tree")
                )
            )
        case .commit(let hash):
            let short = String(hash.prefix(7))
            return (.revision(hash + "^", title: "\(short)^"), .revision(hash, title: short))
        }
    }

    private static func bytes(at endpoint: Endpoint, path: String, in root: URL) -> Data? {
        switch endpoint {
        case .revision(let revision, _):
            return try? run(GitReviewCommands.showBlob(revision: revision, path: path), in: root)
        case .worktree:
            return worktreeBytes(path: path, in: root)
        }
    }

    /// The same containment discipline as `repositoryFile` — resolve symlinks, prove the root
    /// prefix, require a regular file — without the ls-files membership check, because the
    /// paths here come from git's own diff output rather than from a remote request.
    private static func worktreeBytes(path: String, in root: URL) -> Data? {
        boundedWorktreeBytes(
            path: path,
            in: root,
            maximumBytes: GitReviewDefaults.maximumDiffBytes
        )
    }

    /// Git paths are still input. In particular, an untracked symlink can name bytes outside
    /// the checkout and a generated file can grow after `status` reports it. Resolve containment
    /// and enforce the allocation cap in the same helper for diff and summary reads.
    private static func boundedWorktreeBytes(
        path: String,
        in root: URL,
        maximumBytes: Int
    ) -> Data? {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = resolvedRoot
            .appendingPathComponent(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else { return nil }
        return try? BoundedFileReader.read(candidate, maximumBytes: maximumBytes)
    }

    /// The ref the Branch mode measures from: origin's HEAD when known, else the first
    /// conventional name that resolves.
    private static func defaultBranch(in root: URL) throws -> String {
        if let symbolic = try? run(GitReviewCommands.originHead(), in: root) {
            let name = decodeTrimmed(symbolic)
            if !name.isEmpty { return name }
        }
        for candidate in GitReviewDefaults.defaultBranchCandidates where commitExists(candidate, in: root) {
            return candidate
        }
        throw Failure.noDefaultBranch
    }

    private static func hasCommits(in root: URL) -> Bool {
        commitExists(GitReviewCommands.head, in: root)
    }

    private static func commitExists(_ ref: String, in root: URL) -> Bool {
        (try? run(GitReviewCommands.verifyCommit(ref), in: root)) != nil
    }

    private static func treeExists(_ ref: String, in root: URL) -> Bool {
        (try? run(GitReviewCommands.verifyTree(ref), in: root)) != nil
    }

    /// Resolves and validates both checkpoint endpoints before any bytes are presented. The ref
    /// itself must still exist and resolve to the exact tree recorded in metadata; falling back
    /// to a loose object hash would silently turn a deleted or replaced checkpoint into another
    /// record's diff.
    private static func checkpointTrees(
        _ checkpoint: GitTurnCheckpoint,
        in root: URL
    ) throws -> (before: String, after: String) {
        guard let repositoryIdentity = checkpoint.repositoryIdentity,
              GitInfo.worktreeLocation(for: root.path)?.repositoryIdentity
                == repositoryIdentity else {
            throw Failure.checkpointRepositoryMismatch
        }
        let expectedRefs = GitTurnCheckpointRefs.pair(
            sessionID: checkpoint.sessionID,
            checkpointID: checkpoint.id
        )
        guard let beforeRef = checkpoint.beforeRef,
              beforeRef == expectedRefs.before,
              let beforeHash = checkpoint.beforeTreeHash,
              resolvedTree(beforeRef, in: root) == beforeHash else {
            throw Failure.checkpointMissing
        }

        switch checkpoint.status {
        case .complete:
            guard let afterRef = checkpoint.afterRef,
                  afterRef == expectedRefs.after,
                  let afterHash = checkpoint.afterTreeHash,
                  resolvedTree(afterRef, in: root) == afterHash else {
                throw Failure.checkpointMissing
            }
            return (beforeHash, afterHash)

        case .inProgress, .capturingAfter:
            return (beforeHash, try workingTreeSnapshot(in: root))

        case .capturingBefore, .beforeCaptureFailed, .finalCaptureFailed, .incomplete,
             .notAdmitted:
            throw Failure.checkpointIncomplete(
                checkpoint.failureDescription
                    ?? L10n.string("This turn did not reach a complete checkpoint.")
            )
        }
    }

    private static func resolvedTree(_ ref: String, in root: URL) -> String? {
        guard let data = try? run(GitReviewCommands.verifyTree(ref), in: root) else {
            return nil
        }
        let hash = decodeTrimmed(data)
        return hash.isEmpty ? nil : hash
    }

    /// Writes rather than hard-codes the empty-tree id so SHA-256 repositories get the object
    /// format they use. The object is unreachable and harmlessly deduplicated by git.
    private static func emptyTree(in root: URL) throws -> String {
        decodeTrimmed(try run(
            GitReviewCommands.writeEmptyTree(),
            in: root,
            input: Data()
        ))
    }

    /// Writes an immutable tree for the exact working-copy bytes through a temporary alternate
    /// index. Copying the real index preserves forced-added/ignored tracked paths; `git add -A`
    /// then replaces its staged contents with the worktree and admits ordinary untracked files.
    private static func workingTreeSnapshot(in root: URL) throws -> String {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("threading-git-snapshot-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let alternateIndex = directory.appendingPathComponent("index")
        let realIndexPath = decodeTrimmed(try run(GitReviewCommands.indexPath(), in: root))
        if !realIndexPath.isEmpty, fileManager.fileExists(atPath: realIndexPath) {
            try fileManager.copyItem(
                at: URL(fileURLWithPath: realIndexPath),
                to: alternateIndex
            )
        }

        let environment = ["GIT_INDEX_FILE": alternateIndex.path]
        if !fileManager.fileExists(atPath: alternateIndex.path) {
            _ = try run(GitReviewCommands.readEmptyTree(), in: root, environment: environment)
        }
        _ = try run(GitReviewCommands.addWorkingTreeToIndex(), in: root, environment: environment)
        return decodeTrimmed(try run(GitReviewCommands.writeTree(), in: root, environment: environment))
    }

    private static func decodeTrimmed(_ data: Data) -> String {
        GitDiffParser.decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func refQueue(for repositoryIdentity: String) -> DispatchQueue {
        refQueueLock.lock()
        defer { refQueueLock.unlock() }
        if let existing = refQueues[repositoryIdentity] { return existing }
        let queue = DispatchQueue(
            label: "codes.threading.git-turn-refs." + String(repositoryIdentity.hashValue),
            qos: .userInitiated
        )
        refQueues[repositoryIdentity] = queue
        return queue
    }

    private static func repositoryFilePaths(in root: URL) throws -> [String] {
        GitDiffParser.decode(try run(GitReviewCommands.repositoryFiles(), in: root))
            .split(separator: "\u{00}", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
    }

    // MARK: - Untracked Synthesis

    /// `git diff` never mentions untracked files, so the working-tree modes append them as
    /// all-added diffs built from the files themselves.
    private static func untrackedDiffs(in root: URL, excluding: Set<String>) throws -> [GitFileDiff] {
        let status = GitDiffParser.status(fromPorcelainV2: try run(GitReviewCommands.status(), in: root))
        return status.untracked
            .filter { !excluding.contains($0) }
            .map { synthesizedDiff(path: $0, root: root) }
    }

    /// Untracked files as the summary counts them: one file each, its lines as additions.
    /// The synthesis caps apply here too — an over-cap or binary file counts as a file
    /// carrying no lines rather than being read whole.
    private static func untrackedSummary(in root: URL) throws -> GitChangeSummary {
        let status = GitDiffParser.status(fromPorcelainV2: try run(GitReviewCommands.status(), in: root))

        var added = 0
        for path in status.untracked {
            guard let data = boundedWorktreeBytes(
                path: path,
                in: root,
                maximumBytes: GitReviewDefaults.untrackedByteCap
            ),
                  !data.prefix(GitReviewDefaults.binarySniffBytes).contains(0) else { continue }
            added += lineCount(of: data)
        }

        return GitChangeSummary(files: status.untracked.count, added: added, removed: 0)
    }

    /// Newline count, with an unterminated final line counting as a line — the same total the
    /// synthesized diff would report, without materialising its rows.
    private static func lineCount(of data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let newlines = data.reduce(into: 0) { count, byte in
            if byte == UInt8(ascii: "\n") { count += 1 }
        }
        return data.last == UInt8(ascii: "\n") ? newlines : newlines + 1
    }

    private static func synthesizedDiff(path: String, root: URL) -> GitFileDiff {
        guard let data = boundedWorktreeBytes(
            path: path,
            in: root,
            maximumBytes: GitReviewDefaults.untrackedByteCap
        ) else {
            return GitFileDiff(path: path, change: .untracked, hunks: [], added: 0, removed: 0)
        }

        // git's own binary heuristic: a NUL early in the file.
        if data.prefix(GitReviewDefaults.binarySniffBytes).contains(0) {
            return GitFileDiff(path: path, change: .binary, hunks: [], added: 0, removed: 0)
        }

        var lines = GitDiffParser.decode(data).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        let diffLines = lines.enumerated().map { index, text in
            GitDiffLine(kind: .added, text: text, oldNumber: nil, newNumber: index + 1)
        }
        let hunks = diffLines.isEmpty
            ? []
            : [GitHunk(header: "@@ -0,0 +1,\(diffLines.count) @@", lines: diffLines)]

        return GitFileDiff(path: path, change: .untracked, hunks: hunks, added: diffLines.count, removed: 0)
    }

    // MARK: - Process

    /// Every read is prefixed with the flags that keep it a read: literal paths, and never
    /// taking `index.lock` out from under the agent.
    private static func run(
        _ arguments: [String],
        in root: URL,
        input: Data? = nil,
        environment: [String: String] = [:]
    ) throws -> Data {
        try GitProcess.run(
            GitReviewCommands.common + arguments,
            in: root,
            input: input,
            environmentOverrides: environment
        )
    }
}
