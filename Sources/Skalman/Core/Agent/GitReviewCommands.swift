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

    static func stashCreate() -> [String] {
        ["stash", "create"]
    }

    static func headHash() -> [String] {
        ["rev-parse", head]
    }

    static func verifyCommit(_ ref: String) -> [String] {
        ["rev-parse", "--verify", "--quiet", ref + "^{commit}"]
    }

    static func originHead() -> [String] {
        ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]
    }

    static func mergeBase(_ ref: String) -> [String] {
        ["merge-base", ref, head]
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

    /// A file auto-expands only under this many lines…
    static let autoExpandFileLineLimit = DiffPresentationPolicy.default.fileLineLimit
    /// …and only until this many lines are expanded across the whole diff.
    static let autoExpandTotalLineLimit = DiffPresentationPolicy.default.totalLineLimit

    /// A large comparison opens as a file index rather than constructing hundreds of diff-line
    /// views before the user has chosen a file. Headers remain available and each file can still
    /// be expanded on demand.
    static let largeDiffFileThreshold = DiffPresentationPolicy.default.largeFileThreshold
    static let largeDiffChangedLineThreshold =
        DiffPresentationPolicy.default.largeChangedLineThreshold

    /// Untracked files larger than this get a row but no synthesized preview.
    static let untrackedByteCap = 256 * 1024
    /// git's own heuristic: a NUL within the first this-many bytes means binary.
    static let binarySniffBytes = 8000
    /// Characters of one line the pane will draw; minified sources are cut, not wrapped forever.
    static let lineCharacterCap = DiffPresentationPolicy.default.lineCharacterLimit
    /// Diffs past this size fail as too large rather than stall the app.
    static let maximumDiffBytes = 8 * 1024 * 1024

    static let lineNumberWidth: CGFloat = 36

    /// Tried in order when origin has no recorded HEAD.
    static let defaultBranchCandidates = ["origin/main", "origin/master", "main", "master"]
}
