import Foundation
import NativeDiffCore

// MARK: - Commands

/// The argument lists `GitReviewReader` runs — pure builders, so tests can pin every mode's
/// argv without spawning anything.
enum GitReviewCommands {

    private static let logPretty =
        "--pretty=format:%x01%H%x00%h%x00%s%x00%an%x00%at%x00%P%x00%D%x02"
    /// Metadata-first history deliberately avoids Git's unique-abbreviation and decoration
    /// lookups. The reader already has the full hash, while refs and the exact abbreviation
    /// arrive with progressive statistics. The repeated `%H` preserves the parser's field
    /// framing; it is reduced to the ordinary seven-character placeholder in-process.
    private static let logMetadataPretty =
        "--pretty=format:%x01%H%x00%H%x00%s%x00%an%x00%at%x00%P%x00%x02"

    /// Prepended to every invocation: literal paths, and never taking `index.lock` for a read.
    static let common = ["-c", "core.quotepath=false", "--no-optional-locks"]

    /// Flags shared by everything that produces a unified diff.
    static let diffFlags = [
        "--no-color", "--no-ext-diff", "--no-textconv", "--find-renames",
        "-U\(GitReviewDefaults.contextLines)"
    ]

    /// A path/change index without hunks. On large comparisons this reaches the pane while Git
    /// is still generating the full patch, letting the virtual table present file identities
    /// before it cancels that redundant complete read and hydrates visible files by path.
    private static let diffIndexFlags = [
        "--raw", "-z", "--no-color", "--no-ext-diff", "--no-textconv", "--find-renames"
    ]

    static let head = "HEAD"

    /// `-w` folds away whitespace-only changes, for the pane's "Hide whitespace" toggle. Off by
    /// default, so every builder's argv is unchanged until the toggle asks for it.
    static let ignoreWhitespaceFlag = "-w"

    static func status() -> [String] {
        ["status", "--porcelain=v2", "-z", "--untracked-files=all"]
    }

    /// Untracked and non-ignored paths only. Review synthesis does not need tracked status
    /// records, and asking `status` for those makes a clean Linux-sized checkout walk roughly
    /// 95,000 tracked paths merely to return an empty untracked list.
    static func untrackedFiles() -> [String] {
        ["ls-files", "--others", "--exclude-standard", "-z"]
    }

    /// Tracked plus non-ignored untracked files, NUL-delimited so every legal path survives.
    static func repositoryFiles() -> [String] {
        ["ls-files", "-co", "--exclude-standard", "-z"]
    }

    /// One exact tracked or non-ignored untracked path. The explicit literal pathspec prevents a
    /// network-supplied name such as `*.swift` or `:(exclude)foo` from expanding into a catalogue.
    static func repositoryFile(_ path: String) -> [String] {
        repositoryFiles() + ["--", ":(literal)\(path)"]
    }

    /// The diff flags for one read, with the whitespace-ignore flag folded in only when asked.
    private static func diffFlags(
        ignoringWhitespace: Bool,
        contextLines: Int = GitReviewDefaults.contextLines
    ) -> [String] {
        var flags = Array(diffFlags.dropLast()) + ["-U\(max(contextLines, 0))"]
        if ignoringWhitespace { flags.append(ignoreWhitespaceFlag) }
        return flags
    }

    /// Paths received from Git are data, not pathspec syntax. A literal magic signature keeps
    /// brackets, globs, leading colons and exclude-looking names scoped to exactly that file.
    private static func literalPathspecs(_ paths: [String]) -> [String] {
        paths.map { ":(literal)\($0)" }
    }

    /// Index vs worktree when `ref` is nil; `ref` vs worktree otherwise.
    static func diff(
        against ref: String?,
        paths: [String] = [],
        ignoringWhitespace: Bool = false,
        contextLines: Int = GitReviewDefaults.contextLines
    ) -> [String] {
        var arguments = ["diff"] + diffFlags(
            ignoringWhitespace: ignoringWhitespace,
            contextLines: contextLines
        )
        if let ref { arguments.append(ref) }
        if !paths.isEmpty { arguments += ["--"] + literalPathspecs(paths) }
        return arguments
    }

    static func diffStaged(
        paths: [String] = [],
        ignoringWhitespace: Bool = false,
        contextLines: Int = GitReviewDefaults.contextLines
    ) -> [String] {
        var arguments = ["diff", "--cached"] + diffFlags(
            ignoringWhitespace: ignoringWhitespace,
            contextLines: contextLines
        )
        if !paths.isEmpty { arguments += ["--"] + literalPathspecs(paths) }
        return arguments
    }

    /// Two immutable trees. Last Turn uses this shape so files that were untracked at either
    /// endpoint are ordinary tree entries rather than a path-only approximation.
    static func diff(
        from oldTree: String,
        to newTree: String,
        ignoringWhitespace: Bool = false,
        contextLines: Int = GitReviewDefaults.contextLines
    ) -> [String] {
        ["diff"] + diffFlags(
            ignoringWhitespace: ignoringWhitespace,
            contextLines: contextLines
        ) + [oldTree, newTree]
    }

    static func diff(
        from oldTree: String,
        to newTree: String,
        paths: [String],
        ignoringWhitespace: Bool = false,
        contextLines: Int = GitReviewDefaults.contextLines
    ) -> [String] {
        diff(
            from: oldTree,
            to: newTree,
            ignoringWhitespace: ignoringWhitespace,
            contextLines: contextLines
        )
            + ["--"] + literalPathspecs(paths)
    }

    /// Just the paths two trees differ on, relative to the directory the command runs in.
    ///
    /// `--relative` rather than the repository-root paths Git prints by default: the observed-work
    /// floor writes into a trace whose paths are relative to the session's execution folder, and
    /// that folder is not always the repository root. It also drops changes outside that folder,
    /// which is the same answer the atlas gives for them.
    ///
    /// `--no-renames` because a rename is two changed paths here, not one moved file: both the
    /// name that stopped existing and the name that started are files the turn touched.
    static func diffNames(from oldTree: String, to newTree: String) -> [String] {
        [
            "diff", "--name-only", "--relative", "--no-renames", "-z",
            "--no-color", "--no-ext-diff", "--no-textconv", oldTree, newTree
        ]
    }

    static func diffIndex(
        from oldTree: String,
        to newTree: String,
        ignoringWhitespace: Bool = false
    ) -> [String] {
        ["diff"] + diffIndexFlags + (ignoringWhitespace ? [ignoreWhitespaceFlag] : [])
            + [oldTree, newTree]
    }

    /// `--format=` suppresses the commit header, leaving pure diff on stdout.
    static func show(
        _ hash: String,
        paths: [String] = [],
        ignoringWhitespace: Bool = false,
        contextLines: Int = GitReviewDefaults.contextLines
    ) -> [String] {
        var arguments = ["show", hash, "--format="] + diffFlags(
            ignoringWhitespace: ignoringWhitespace,
            contextLines: contextLines
        )
        if !paths.isEmpty { arguments += ["--"] + literalPathspecs(paths) }
        return arguments
    }

    /// Control-character separators (0x01 record, 0x00 field, 0x02 header end) survive any
    /// subject line; `--numstat` supplies the per-commit counts.
    ///
    /// `%P` and `%D` are what the graph is drawn from — the parents give the lanes, the
    /// decorations give the branch and tag names. Both are appended after the fields that were
    /// there first, so a record from either shape parses.
    static func log(skip: Int) -> [String] {
        [
            "log", "--no-color", "--numstat",
            logPretty,
            "--skip=\(skip)", "--max-count=\(GitReviewDefaults.logPageSize)"
        ]
    }

    /// The history surface can draw its graph and every textual field without opening the
    /// commits' trees and blobs. Statistics follow as progressive enrichment; keeping this
    /// first command metadata-only makes cold history presentation independent of diff weight.
    static func logMetadata(skip: Int) -> [String] {
        [
            "log", "--no-color", logMetadataPretty,
            "--skip=\(skip)", "--max-count=\(GitReviewDefaults.logPageSize)"
        ]
    }

    /// Subjects only, for the commit draft's voice sample — no numstat, no hundred-commit
    /// page. `log()` above always pays for both, which is right for the history browser and
    /// waste here.
    static func recentSubjects(count: Int) -> [String] {
        ["log", "--no-color", "--pretty=format:%s", "--max-count=\(count)"]
    }

    /// Totals only, for the status card: per-file counts with no hunks to parse or cap.
    /// Index vs worktree when `ref` is nil; `ref` vs worktree otherwise.
    static func diffNumstat(against ref: String?) -> [String] {
        var arguments = ["diff", "--numstat", "--no-color", "--no-ext-diff", "--no-textconv"]
        if let ref { arguments.append(ref) }
        return arguments
    }

    static func diffNumstatStaged() -> [String] {
        ["diff", "--cached", "--numstat", "--no-color", "--no-ext-diff", "--no-textconv"]
    }

    /// Per-file counts for an immutable comparison. The broad pass explicitly disables rename
    /// discovery: on Linux's 970-file stress range, asking diffcore to search for renames made
    /// the same exact line count roughly five times slower despite the range containing none.
    /// The reader re-runs only paths the already-complete raw roster identified as renames with
    /// `detectingRenames` enabled, preserving rename semantics without making every file pay.
    static func diffNumstat(
        from oldTree: String,
        to newTree: String,
        paths: [String] = [],
        detectingRenames: Bool = false,
        ignoringWhitespace: Bool = false
    ) -> [String] {
        var arguments = [
            "diff", "--numstat", "-z", "--no-color", "--no-ext-diff", "--no-textconv",
            detectingRenames ? "--find-renames" : "--no-renames",
        ]
        if ignoringWhitespace { arguments.append(ignoreWhitespaceFlag) }
        arguments += [oldTree, newTree]
        if !paths.isEmpty {
            arguments += ["--"] + literalPathspecs(paths)
        }
        return arguments
    }

    static func headHash() -> [String] {
        ["rev-parse", head]
    }

    static func verifyCommit(_ ref: String) -> [String] {
        ["rev-parse", "--verify", "--quiet", ref + "^{commit}"]
    }

    static func verifyTree(_ ref: String) -> [String] {
        ["rev-parse", "--verify", "--quiet", ref + "^{tree}"]
    }

    /// Publishes an immutable checkpoint tree under Threading's private ref namespace. The
    /// empty expected-old value makes creation compare-and-swap: a UUID collision or foreign
    /// pre-existing ref is a failure, never something this app overwrites.
    static func updateRef(_ ref: String, to tree: String) -> [String] {
        ["update-ref", ref, tree, ""]
    }

    /// Deletes one app-owned checkpoint ref. `git update-ref -d` is idempotent for a missing ref.
    static func deleteRef(_ ref: String) -> [String] {
        ["update-ref", "-d", ref]
    }

    /// Enumerates the app namespace for bounded orphan collection. The reader still validates
    /// every returned name before it can become a deletion target.
    static func checkpointRefs() -> [String] {
        ["for-each-ref", "--format=%(refname)", GitTurnCheckpointRefs.prefix]
    }

    /// The real index is copied only as the tracked-file roster for a private alternate index.
    /// `--path-format=absolute` also resolves linked-worktree indexes correctly.
    static func indexPath() -> [String] {
        ["rev-parse", "--path-format=absolute", "--git-path", "index"]
    }

    static func readEmptyTree() -> [String] {
        ["read-tree", "--empty"]
    }

    /// Refreshes every tracked path and admits non-ignored untracked files into the alternate
    /// index. The caller supplies `GIT_INDEX_FILE`, so the checkout's real index is untouched.
    static func addWorkingTreeToIndex() -> [String] {
        ["add", "-A", "--", "."]
    }

    static func writeTree() -> [String] {
        ["write-tree"]
    }

    /// Materializes the repository's native empty tree object (SHA-1 or SHA-256) without
    /// assuming the well-known SHA-1 id. Used as unborn HEAD for full working-tree comparisons.
    static func writeEmptyTree() -> [String] {
        ["hash-object", "-w", "-t", "tree", "--stdin"]
    }

    static func originHead() -> [String] {
        ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]
    }

    static func mergeBase(_ ref: String) -> [String] {
        ["merge-base", ref, head]
    }

    /// Two arbitrary files, no repository required. `--no-index` exits 1 to say the files
    /// differ, so the runner is told both exits are answers. No `--find-renames`: there are
    /// exactly two paths, and they are the pair.
    static func compareFiles(oldPath: String, newPath: String) -> [String] {
        [
            "diff", "--no-color", "--no-ext-diff", "--no-textconv",
            "-U\(GitReviewDefaults.contextLines)", "--no-index", "--", oldPath, newPath
        ]
    }

    /// One file's bytes at one revision — `HEAD:path`, `:0:path` for the index, a baseline or
    /// merge-base hash. The plain `show` builder is not reused because it appends the diff
    /// flags, which mean nothing to a blob.
    static func showBlob(revision: String, path: String) -> [String] {
        ["show", "\(revision):\(path)"]
    }
}

// MARK: - Defaults

enum GitReviewDefaults {
    static let timeout: TimeInterval = 15
    static let refreshDebounce: TimeInterval = 1.5
    static let contextLines = 3
    static let expandedContextInitial = 20
    static let maximumExpandedContextLines = 10_000
    static let logPageSize = 100

    /// Below this, an extra process costs more than the blank interval it could hide.
    static let progressiveDiffFileThreshold = 100
    static let progressiveDiffDelay: TimeInterval = 0.1
    /// One process hydrates at most the current viewport. A serial hydration queue and this cap
    /// keep a fast scroll from becoming one child per row or an unbounded pathspec argument list.
    static let progressiveDiffHydrationBatch = 16
    static let progressiveDiffHydrationSettleDelay: TimeInterval = 0.04
    /// Totals are enrichment, never an input to the first useful viewport. Wait for a genuine
    /// pause so their blob walk does not compete with a reader who immediately keeps moving.
    static let progressiveDiffStatsSettleDelay: TimeInterval = 0.6

    /// How long the scroller thumb must hold still, mid-drag, before the ghost viewport is
    /// replaced with real rows. Short enough that a scrub's natural reading pause is answered;
    /// long enough that a slow continuous drag never pays TextKit per pointer event.
    static let scrollerSeekSettleDelay: TimeInterval = 0.15

    /// Lines one file's diff draws before truncating with a note.
    static let fileDisplayCap = 400
    /// A one-character query in a large patch must not turn into an unbounded navigation
    /// array. The status reports a trailing `+` when this presentation cap is reached.
    static let findMatchCap = 10_000

    /// Untracked files larger than this get a row but no synthesized preview.
    static let untrackedByteCap = 256 * 1024
    /// git's own heuristic: a NUL within the first this-many bytes means binary.
    static let binarySniffBytes = 8000
    /// Characters of one line the pane will draw; minified sources are cut, not wrapped forever.
    static let lineCharacterCap = DiffPresentationPolicy.default.lineCharacterLimit
    /// Diffs past this size fail as too large rather than stall the app.
    static let maximumDiffBytes = 8 * 1024 * 1024

    /// The mobile repository browser is an overview, not an unbounded archive transport.
    static let remoteRepositoryFileLimit = 5_000
    static let remoteRepositoryFileByteCap = 512 * 1024

    static let lineNumberWidth: CGFloat = 36

    /// Tried in order when origin has no recorded HEAD.
    static let defaultBranchCandidates = ["origin/main", "origin/master", "main", "master"]
}
