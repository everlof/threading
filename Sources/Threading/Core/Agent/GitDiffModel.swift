import Foundation
import NativeDiffCore

// MARK: - Shared Diff Model

/// Compatibility names for the app's existing git/staging code. The value types themselves
/// live in NativeDiffCore and are the same ones rendered by AppKit and UIKit.
typealias DiffLine = NativeDiffCore.DiffLine
typealias GitFileDiff = NativeDiffCore.DiffFile
typealias GitHunk = NativeDiffCore.DiffHunk
typealias GitDiffLine = NativeDiffCore.DiffLine

// MARK: - Review Mode

/// What the review pane is comparing. Raw values are persisted with the tab, so they are
/// stable names, not display strings.
enum GitReviewMode: String, Codable, CaseIterable, Sendable {
    case uncommitted
    case unstaged
    case staged
    case lastTurn
    case branch
    case commit

    var title: String {
        title(isTurnInFlight: false)
    }

    func title(isTurnInFlight: Bool) -> String {
        switch self {
        case .uncommitted: return L10n.string("Uncommitted")
        case .unstaged: return L10n.string("Unstaged")
        case .staged: return L10n.string("Staged")
        case .lastTurn:
            return isTurnInFlight ? L10n.string("This Turn") : L10n.string("Last Turn")
        case .branch: return L10n.string("Branch")
        case .commit: return L10n.string("Commits")
        }
    }

    var comparisonDescription: String {
        switch self {
        case .uncommitted:
            return L10n.string("HEAD → Working Tree · staged, unstaged, and untracked")
        case .unstaged:
            return L10n.string("Index → Working Tree · includes untracked")
        case .staged:
            return L10n.string("HEAD → Index")
        case .lastTurn:
            return L10n.string("Turn Start → Turn End")
        case .branch:
            return L10n.string("Merge Base → Working Tree")
        case .commit:
            return L10n.string("Browse committed changes")
        }
    }
}

// MARK: - Staging

/// Which way a control moves a change.
enum GitStagingAction: Sendable {
    case stage
    case unstage

    var fileTitle: String {
        self == .stage ? L10n.string("Stage File") : L10n.string("Unstage File")
    }
    var hunkTitle: String {
        self == .stage ? L10n.string("Stage") : L10n.string("Unstage")
    }

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
struct GitStaging: Sendable {
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

// MARK: - Commit Summary

/// One row of the history list.
struct GitCommitSummary: Sendable {
    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    let date: Date
    let added: Int
    let removed: Int

    /// False only during the short interval between metadata-first history presentation and
    /// progressive numstat enrichment. Zero is a real answer once this becomes true.
    let hasStats: Bool

    /// Parent hashes, first parent first — what the graph is drawn from. More than one means
    /// a merge.
    let parents: [String]

    /// Branch, tag and HEAD names pointing at this commit, as git reports them.
    let refs: [String]

    init(
        hash: String,
        shortHash: String,
        subject: String,
        author: String,
        date: Date,
        added: Int,
        removed: Int,
        hasStats: Bool = true,
        parents: [String],
        refs: [String]
    ) {
        self.hash = hash
        self.shortHash = shortHash
        self.subject = subject
        self.author = author
        self.date = date
        self.added = added
        self.removed = removed
        self.hasStats = hasStats
        self.parents = parents
        self.refs = refs
    }
}

// MARK: - Change Summary

/// A diff reduced to its totals — what the floating status card draws, and all it needs:
/// producing the hunks to throw them away would spend the parse on every checkout write.
struct GitChangeSummary: Equatable, Sendable {
    let files: Int
    let added: Int
    let removed: Int

    var isClean: Bool { files == 0 }

    static let clean = GitChangeSummary(files: 0, added: 0, removed: 0)
}

/// Exact line totals for one path without retaining its hunks. Progressive large comparisons
/// use these values to establish aggregate counts and an honest document-height estimate before
/// the row itself reaches the viewport.
struct GitFileLineStats: Equatable, Sendable {
    let path: String
    let added: Int
    let removed: Int
}

// MARK: - Status

/// The checkout's `git status`, reduced to what the review pane needs: which paths changed
/// where, and which are untracked.
struct GitStatus: Sendable {
    struct Entry: Sendable {
        let path: String
        let renamedFrom: String?
        let staged: Bool
        let unstaged: Bool
    }

    let entries: [Entry]
    let untracked: [String]
}

// MARK: - Repository Files

/// One bounded source file read for a remote repository browser.
struct GitRepositoryFile: Sendable {
    let path: String
    let content: String?
    let isBinary: Bool
    let isTruncated: Bool
}

// MARK: - Turn Baseline

/// A snapshot of the checkout at the moment a session started working, against which
/// "Last Turn" is diffed.
///
/// The snapshot is an unreferenced tree written through a private alternate index. It therefore
/// includes the exact bytes of tracked, staged, and non-ignored untracked files without moving
/// a ref or touching the checkout's real index or worktree.
struct GitTurnBaseline: Sendable {
    let treeHash: String
    let capturedAt: Date
}

// MARK: - Durable Turn Checkpoints

/// Threading's stable identity for one admitted provider turn.
///
/// This is deliberately independent of transcript row numbers. Native transports may also
/// carry a client-minted message id and terminal hooks may carry a provider turn id, but neither
/// exists on every surface. The checkpoint id is the common identity that survives relaunches.
struct GitTurnCheckpointID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        rawValue = value
    }

    var uuidString: String { rawValue.uuidString }
    var description: String { uuidString }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How far a turn's two-phase capture got. Transitional states are written before their git
/// operation begins; if the process exits there, the next launch converts them to `incomplete`.
enum GitTurnCaptureStatus: String, Codable, Sendable {
    case capturingBefore
    case inProgress
    case capturingAfter
    case complete
    case beforeCaptureFailed
    case finalCaptureFailed
    case incomplete
    case notAdmitted

    var hasDurableBefore: Bool {
        switch self {
        case .inProgress, .capturingAfter, .complete, .finalCaptureFailed, .incomplete:
            return true
        case .capturingBefore, .beforeCaptureFailed, .notAdmitted:
            return false
        }
    }

    var isTransitional: Bool {
        self == .capturingBefore || self == .inProgress || self == .capturingAfter
    }
}

/// The persisted association between a stable session turn and its app-owned git objects.
///
/// Successful records always carry the project, execution checkout, repository and worktree
/// identities. The checkout paths are retained as access hints for cleanup; repository identity
/// is the authority used before a diff or ref deletion is allowed.
struct GitTurnCheckpoint: Codable, Equatable, Sendable {
    let id: GitTurnCheckpointID
    let projectID: ProjectID?
    let sessionID: SessionID
    let ordinal: Int
    let userTurnID: String
    var assistantTurnID: String
    var providerTurnID: String?

    let logicalProjectPath: String?
    let executionCheckoutPath: String?
    let repositoryIdentity: String?
    let worktreeIdentity: String?

    let beforeRef: String?
    let afterRef: String?
    var beforeTreeHash: String?
    var afterTreeHash: String?

    var status: GitTurnCaptureStatus
    let requestedAt: Date
    var beforeCapturedAt: Date?
    var finalRequestedAt: Date?
    var completedAt: Date?
    var failureDescription: String?

    /// Other sessions that had a turn in flight in this worktree at any point inside this turn's
    /// window.
    ///
    /// Attribution here is best effort by construction: the comparison is the recorded tree pair,
    /// so a second chat editing the same checkout lands inside it. Naming who else was working is
    /// what lets a surface hedge instead of presenting shared work as exclusively this chat's.
    /// Nil means no contention was observed — and an archive written before the field existed
    /// decodes to exactly that.
    var overlappingSessionIDs: [SessionID]?

    /// Checkout-relative paths this session's structured edit tools named during the turn.
    ///
    /// The tree pair is complete but unattributed; the provider's tool calls are exactly
    /// attributed but incomplete, because an edit made through a shell command names no file.
    /// Crossing them is only sound in one direction: a claimed path is certainly this chat's,
    /// while an unclaimed path is merely unproven.
    ///
    /// Nil and empty are different answers and both are load-bearing. Nil is "claims were not
    /// tracked for this turn" — an archive from before the field, or a runtime with no live
    /// per-tool feed — and licenses no conclusion at all. Empty is "tracked, and this chat's edit
    /// tools claimed nothing".
    var claimedEditPaths: [String]?

    /// True once `GitTurnCheckpointDefaults.maximumClaimedEditPaths` was reached. The list is then
    /// a prefix rather than the whole set, so absence from it stops meaning anything and per-file
    /// marks must be suppressed.
    var claimedEditsOverflowed: Bool?

    /// Whether a surface may reason about an individual path's absence from `claimedEditPaths`.
    var hasUsableEditClaims: Bool {
        claimedEditPaths != nil && claimedEditsOverflowed != true
    }

    var canPresentDiff: Bool {
        switch status {
        case .inProgress, .capturingAfter:
            return beforeRef != nil && beforeTreeHash != nil
        case .complete:
            return beforeRef != nil && beforeTreeHash != nil
                && afterRef != nil && afterTreeHash != nil
        case .capturingBefore, .beforeCaptureFailed, .finalCaptureFailed, .incomplete,
             .notAdmitted:
            return false
        }
    }

    var isComplete: Bool { status == .complete }
}

// MARK: - Contested Turn Attribution

/// What a contested turn can honestly say about one changed file.
enum TurnAttributionMark: Equatable, Sendable {
    /// Either this chat's alone, or nothing is known well enough to say anything.
    case none
    /// No chat's edit tools named it. It may be a shell edit by anyone standing in this checkout.
    case unclaimed
    /// Another chat that was working here named it.
    case otherChat
    /// Both this chat and another named it, so the row's content may be merged work.
    case shared
}

/// The claims a contested turn is judged against, resolved once per review load.
///
/// The rule is deliberately monotone: another chat's claims may only *add* certainty. Their claim
/// on a path is a positive fact, so it stands on its own; their *silence* about a path proves
/// nothing and never strengthens a statement. That asymmetry is also why the two sides are not
/// gated alike — this chat's claims must be usable before absence from them may be read as
/// "unclaimed", while another chat's usable claims license naming them even when this chat's own
/// claims were never tracked. A terminal turn contested by a native chat is exactly that case:
/// nothing can be said about our files, and their files are still theirs.
struct TurnAttribution: Equatable {

    /// This chat's claims, or nil where they may not be reasoned from — untracked or overflowed.
    let ownClaims: Set<String>?

    /// The union of the overlapping chats' usable claims. Empty means none of them could be
    /// trusted, not that they wrote nothing.
    let otherChatClaims: Set<String>

    /// Nil where no row may be marked at all: an uncontested turn, or a contested one where
    /// neither side's claims can carry a statement.
    init?(checkpoint: GitTurnCheckpoint, claimedByOtherChats: Set<String>) {
        guard checkpoint.overlappingSessionIDs?.isEmpty == false else { return nil }
        let ownClaims = checkpoint.hasUsableEditClaims
            ? checkpoint.claimedEditPaths.map(Set.init)
            : nil
        guard ownClaims != nil || !claimedByOtherChats.isEmpty else { return nil }
        self.ownClaims = ownClaims
        self.otherChatClaims = claimedByOtherChats
    }

    func mark(for path: String) -> TurnAttributionMark {
        let theirs = otherChatClaims.contains(path)
        // Without usable claims of our own we cannot say a file is not ours — only that someone
        // else did name it.
        guard let ownClaims else { return theirs ? .otherChat : .none }
        switch (ownClaims.contains(path), theirs) {
        case (true, true): return .shared
        case (true, false): return .none
        case (false, true): return .otherChat
        case (false, false): return .unclaimed
        }
    }
}

/// A narrow notification for review surfaces. Checkpoint writes are per session, so refreshing
/// every open review pane would turn one turn boundary into repository work across the app.
struct GitTurnCheckpointsDidChange: AppEvent {
    static let name = Notification.Name("gitTurnCheckpointsDidChange")
    let sessionID: SessionID
}

/// One file's bytes at a review request's two endpoints, with what each endpoint is called —
/// what an image row compares. A side the endpoint does not hold (an added, deleted, or
/// untracked file) is nil rather than an error: half a pair is still worth showing.
struct GitEndpointFilePair: Sendable {
    let old: Data?
    let new: Data?
    let oldTitle: String
    let newTitle: String
}
