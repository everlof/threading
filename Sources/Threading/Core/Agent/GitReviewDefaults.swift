import Foundation
import NativeDiffCore

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
    /// The gutter before the number column that the hovered line's action plate is drawn in.
    /// Drawn over the number instead, the plate removed the one thing a reader hovers a line
    /// to read, and in hard-print themes its translucent plate overprinted the digits.
    static let lineActionGutterWidth: CGFloat = 24

    /// Below these pane widths the header folds its text-size run, then its navigation run,
    /// into the ··· menu. At 360pt all six glyphs otherwise ran into the totals, which had
    /// wrapped to one character per line.
    static let textSizeGroupFoldWidth: CGFloat = 500
    static let navigationGroupFoldWidth: CGFloat = 420

    /// Narrower than this, a split diff is two columns of clipped fragments; the pane shows the
    /// unified layout instead and keeps the split choice for when there is room again.
    static let splitLayoutMinimumWidth: CGFloat = 600

    /// Tried in order when origin has no recorded HEAD.
    static let defaultBranchCandidates = ["origin/main", "origin/master", "main", "master"]
}
