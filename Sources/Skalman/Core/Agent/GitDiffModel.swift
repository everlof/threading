import Foundation

// MARK: - Review Mode

/// What the review pane is comparing. Raw values are persisted with the tab, so they are
/// stable names, not display strings.
enum GitReviewMode: String, Codable, CaseIterable {
    case uncommitted
    case unstaged
    case staged
    case lastTurn
    case branch
    case commit

    var title: String {
        switch self {
        case .uncommitted: return "Uncommitted"
        case .unstaged: return "Unstaged"
        case .staged: return "Staged"
        case .lastTurn: return "Last Turn"
        case .branch: return "Branch"
        case .commit: return "Commits"
        }
    }
}

// MARK: - Staging

/// Which way a control moves a change.
enum GitStagingAction {
    case stage
    case unstage

    var fileTitle: String { self == .stage ? "Stage File" : "Unstage File" }
    var hunkTitle: String { self == .stage ? "Stage" : "Unstage" }

    /// Unstaging is the same patch applied backwards, which is what makes every action here
    /// reversible by the button beside it.
    var isReverse: Bool { self == .unstage }
}

/// What a mode's diff can be used to do to the index.
///
/// A patch applies to the index only when the index is what the diff was measured *from* —
/// so Unstaged (index → worktree) stages hunks, Staged (HEAD → index) unstages them, and
/// Uncommitted (HEAD → worktree) can only speak about whole files, since its hunks describe a
/// baseline the index may already have moved past. The remaining modes compare things that are
/// not the index at all and stay read-only, which is what the pane was before this existed.
struct GitStaging {
    let action: GitStagingAction
    let allowsHunks: Bool

    static func capability(for mode: GitReviewMode) -> GitStaging? {
        switch mode {
        case .unstaged: return GitStaging(action: .stage, allowsHunks: true)
        case .staged: return GitStaging(action: .unstage, allowsHunks: true)
        case .uncommitted: return GitStaging(action: .stage, allowsHunks: false)
        case .lastTurn, .branch, .commit: return nil
        }
    }
}

// MARK: - File Diff

/// One changed file in a git diff: what happened to it and the hunks showing how.
struct GitFileDiff {
    enum Change: Equatable {
        case modified
        case added
        case deleted
        /// Present in the worktree but unknown to git. `git diff` omits these, so they are
        /// synthesized from the file's own content.
        case untracked
        case renamed(from: String)
        case binary
    }

    let path: String
    let change: Change
    let hunks: [GitHunk]
    let added: Int
    let removed: Int
}

/// One `@@` section of a file's diff.
struct GitHunk {
    /// The full header line, e.g. `@@ -12,7 +12,9 @@ func foo()`.
    let header: String
    let lines: [GitDiffLine]
}

/// One line of a git diff. Reuses `DiffLine.Kind` so the review pane and the tool rows share
/// one vocabulary; the numbers are what a real diff carries that an edit-tool diff does not.
struct GitDiffLine {
    let kind: DiffLine.Kind
    let text: String
    /// Line number on the old side; nil for added lines and note rows.
    let oldNumber: Int?
    /// Line number on the new side; nil for removed lines and note rows.
    let newNumber: Int?
}

// MARK: - Commit Summary

/// One row of the history list.
struct GitCommitSummary {
    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    let date: Date
    let added: Int
    let removed: Int

    /// Parent hashes, first parent first — what the graph is drawn from. More than one means
    /// a merge.
    let parents: [String]

    /// Branch, tag and HEAD names pointing at this commit, as git reports them.
    let refs: [String]
}

// MARK: - Status

/// The checkout's `git status`, reduced to what the review pane needs: which paths changed
/// where, and which are untracked.
struct GitStatus {
    struct Entry {
        let path: String
        let renamedFrom: String?
        let staged: Bool
        let unstaged: Bool
    }

    let entries: [Entry]
    let untracked: [String]
}

// MARK: - Turn Baseline

/// A snapshot of the checkout at the moment a session started working, against which
/// "Last Turn" is diffed.
///
/// The snapshot is a `git stash create` commit — an unreferenced object that mutates no ref,
/// no index and no worktree. Untracked files are recorded separately because a stash commit
/// does not include them: a file untracked at capture and still untracked now is not the
/// turn's work.
struct GitTurnBaseline {
    let snapshotHash: String
    let capturedAt: Date
    let untrackedPaths: Set<String>
}
