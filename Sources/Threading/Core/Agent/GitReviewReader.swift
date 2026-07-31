import Foundation

/// Read-only git queries for the review pane: diffs, status, history and turn snapshots.
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
        case commit(hash: String)
    }

    // MARK: - Properties

    private static let queue = DispatchQueue(label: "codes.threading.git-review", qos: .userInitiated)

    /// Status summaries feed navigation chrome and must not wait behind a megabyte-scale review
    /// diff already being parsed on `queue`. They are intentionally independent reads: both are
    /// read-only (`--no-optional-locks`), while making this serial with the review made switching
    /// sessions inherit the cost of whichever diff happened to be open before it.
    private static let summaryQueue = DispatchQueue(
        label: "codes.threading.git-summary",
        qos: .userInitiated
    )

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
    /// rebuilt. Untracked files are absent, as they are from `git diff` itself. Completion on main.
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
            // The same unborn-HEAD rule as the full uncommitted diff: with nothing to diff
            // against, the index against the empty tree is everything staged so far.
            let tracked = GitDiffParser.summary(fromNumstat: try run(
                hasCommits(in: root)
                    ? GitReviewCommands.diffNumstat(against: GitReviewCommands.head)
                    : GitReviewCommands.diffNumstatStaged(),
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
        perform("git.read.create-snapshot", completion) {
            guard hasCommits(in: root) else { throw Failure.noCommits }

            // `stash create` writes an unreferenced commit and touches nothing else; empty
            // output means the tree is clean, in which case HEAD itself is the baseline.
            let created = decodeTrimmed(try run(GitReviewCommands.stashCreate(), in: root))
            let hash = created.isEmpty
                ? decodeTrimmed(try run(GitReviewCommands.headHash(), in: root))
                : created

            let status = GitDiffParser.status(fromPorcelainV2: try run(GitReviewCommands.status(), in: root))
            return GitTurnBaseline(
                snapshotHash: hash,
                capturedAt: Date(),
                untrackedPaths: Set(status.untracked)
            )
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
        case .lastTurn(let baseline):
            return try tracked + untrackedDiffs(in: root, excluding: baseline.untrackedPaths)
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
            // On an unborn HEAD there is nothing to diff against, but the index against the
            // empty tree is exactly "everything staged so far".
            return try run(
                hasCommits(in: root)
                    ? GitReviewCommands.diff(against: GitReviewCommands.head, ignoringWhitespace: ws)
                    : GitReviewCommands.diffStaged(ignoringWhitespace: ws),
                in: root
            )

        case .branch:
            guard hasCommits(in: root) else { throw Failure.noCommits }
            let base = try defaultBranch(in: root)
            let mergeBase = decodeTrimmed(try run(GitReviewCommands.mergeBase(base), in: root))
            return try run(GitReviewCommands.diff(against: mergeBase, ignoringWhitespace: ws), in: root)

        case .lastTurn(let baseline):
            guard commitExists(baseline.snapshotHash, in: root) else { throw Failure.baselineExpired }
            return try run(GitReviewCommands.diff(against: baseline.snapshotHash, ignoringWhitespace: ws), in: root)

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
            return (.revision(GitReviewCommands.head, title: "HEAD"), .worktree)
        case .branch:
            let base = try defaultBranch(in: root)
            let mergeBase = decodeTrimmed(try run(GitReviewCommands.mergeBase(base), in: root))
            return (.revision(mergeBase, title: L10n.string("Merge Base")), .worktree)
        case .lastTurn(let baseline):
            guard commitExists(baseline.snapshotHash, in: root) else { throw Failure.baselineExpired }
            return (
                .revision(baseline.snapshotHash, title: L10n.string("Turn Start")),
                .worktree
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
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = resolvedRoot
            .appendingPathComponent(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPrefix),
              let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= GitReviewDefaults.maximumDiffBytes else {
            return nil
        }
        return try? Data(contentsOf: candidate, options: .mappedIfSafe)
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

    private static func decodeTrimmed(_ data: Data) -> String {
        GitDiffParser.decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
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
            let url = root.appendingPathComponent(path)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            guard size <= GitReviewDefaults.untrackedByteCap,
                  let data = try? Data(contentsOf: url),
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
        let url = root.appendingPathComponent(path)

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        guard size <= GitReviewDefaults.untrackedByteCap,
              let data = try? Data(contentsOf: url) else {
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
    private static func run(_ arguments: [String], in root: URL) throws -> Data {
        try GitProcess.run(GitReviewCommands.common + arguments, in: root)
    }
}
