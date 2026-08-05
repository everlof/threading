import Foundation
import NativeDiffCore

// MARK: - Commands

/// The argument lists `GitReviewReader` runs — pure builders, so tests can pin every mode's
/// argv without spawning anything.
enum GitReviewCommands {

    /// Prepended to every invocation: literal paths, and never taking `index.lock` for a read.
    static let common = ["-c", "core.quotepath=false", "--no-optional-locks"]

    /// Flags shared by everything that produces a unified diff.
    static let diffFlags = [
        "--no-color", "--no-ext-diff", "--no-textconv", "--find-renames",
        "-U\(GitReviewDefaults.contextLines)"
    ]

    static let head = "HEAD"

    /// `-w` folds away whitespace-only changes, for the pane's "Hide whitespace" toggle. Off by
    /// default, so every builder's argv is unchanged until the toggle asks for it.
    static let ignoreWhitespaceFlag = "-w"

    static func status() -> [String] {
        ["status", "--porcelain=v2", "-z", "--untracked-files=all"]
    }

    /// Tracked plus non-ignored untracked files, NUL-delimited so every legal path survives.
    static func repositoryFiles() -> [String] {
        ["ls-files", "-co", "--exclude-standard", "-z"]
    }

    /// The diff flags for one read, with the whitespace-ignore flag folded in only when asked.
    private static func diffFlags(ignoringWhitespace: Bool) -> [String] {
        ignoringWhitespace ? diffFlags + [ignoreWhitespaceFlag] : diffFlags
    }

    /// Index vs worktree when `ref` is nil; `ref` vs worktree otherwise.
    static func diff(against ref: String?, ignoringWhitespace: Bool = false) -> [String] {
        var arguments = ["diff"] + diffFlags(ignoringWhitespace: ignoringWhitespace)
        if let ref { arguments.append(ref) }
        return arguments
    }

    static func diffStaged(ignoringWhitespace: Bool = false) -> [String] {
        ["diff", "--cached"] + diffFlags(ignoringWhitespace: ignoringWhitespace)
    }

    /// Two immutable trees. Last Turn uses this shape so files that were untracked at either
    /// endpoint are ordinary tree entries rather than a path-only approximation.
    static func diff(
        from oldTree: String,
        to newTree: String,
        ignoringWhitespace: Bool = false
    ) -> [String] {
        ["diff"] + diffFlags(ignoringWhitespace: ignoringWhitespace) + [oldTree, newTree]
    }

    /// `--format=` suppresses the commit header, leaving pure diff on stdout.
    static func show(_ hash: String, ignoringWhitespace: Bool = false) -> [String] {
        ["show", hash, "--format="] + diffFlags(ignoringWhitespace: ignoringWhitespace)
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
            "--pretty=format:%x01%H%x00%h%x00%s%x00%an%x00%at%x00%P%x00%D%x02",
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

    static func headHash() -> [String] {
        ["rev-parse", head]
    }

    static func verifyCommit(_ ref: String) -> [String] {
        ["rev-parse", "--verify", "--quiet", ref + "^{commit}"]
    }

    static func verifyTree(_ ref: String) -> [String] {
        ["rev-parse", "--verify", "--quiet", ref + "^{tree}"]
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
    static let logPageSize = 100

    /// Lines one file's diff draws before truncating with a note.
    static let fileDisplayCap = 400

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
