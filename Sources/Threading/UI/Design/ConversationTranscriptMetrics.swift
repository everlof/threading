import AppKit

/// The transcript's spacing and arrival metrics shared by every desktop host.
extension Design.Chat {
    /// How far past `columnWidth` the column may grow when the pane has room to spare: 52 reading
    /// ems become 68, about 950pt at the default text size.
    ///
    /// A fixed measure left a third of a wide pane in use and two empty thirds beside it, while
    /// tables, code and paths wrapped or scrolled inside it. Prose past this stops being a line an
    /// eye returns from comfortably, so the growth has a ceiling rather than following the pane.
    public static let columnGrowth: CGFloat = 68.0 / 52.0

    /// The share of a roomy pane the column takes on its way to that ceiling. Below the width where
    /// this share falls under `columnWidth`, the column stays the base measure; a pane narrower
    /// than the column gives it what remains inside the insets.
    public static let columnPaneShare: CGFloat = 0.6

    /// The column moves in steps while a pane is resized, so a slow drag rewraps the transcript
    /// every few points of travel rather than on each one.
    public static let columnStep: CGFloat = Design.Spacing.medium

    /// What stands between a pane's edge and a column that has run out of room: the reply box's
    /// inset from the pane plus its own padding, so the lines being read and the line being typed
    /// share one edge at every width.
    public static let columnMargin: CGFloat = Design.Spacing.inset * 2

    /// The column for a pane of `paneWidth`: wider when there is room, never below the base
    /// measure. Still a ceiling, not a request; see `ConversationVirtualRowHost`.
    @MainActor public static func columnWidth(inPane paneWidth: CGFloat) -> CGFloat {
        let base = columnWidth
        let share = ((paneWidth * columnPaneShare) / columnStep).rounded(.down) * columnStep
        return min(max(base, share), (base * columnGrowth).rounded())
    }

    /// What a heading stands clear of the block before it. Spacing above a heading and not
    /// below it is what attaches it to the section it names; with the ordinary block gap on
    /// both sides it floated halfway between two paragraphs.
    public static let headingLeading: CGFloat = Design.Spacing.large

    /// Vertical gap between one turn and the next. The divider now carries the boundary, so
    /// this only needs to be one large step rather than a second oversized separator.
    public static let turnSpacing: CGFloat = Design.Spacing.large

    /// What opens a new step of a working turn: a sentence or a thought, and the calls it led to,
    /// stand this far from the step before them.
    public static let stepSpacing: CGFloat = Design.Spacing.large

    /// Between the blocks of one document, and between an answer and whatever stands beside
    /// it: one value, so an answer split into rows reads exactly like one document.
    ///
    /// `inset`, not `small`: once lines stand `readingLineHeight` apart, a six-point gap
    /// between paragraphs was *less* than the gap between two lines of one paragraph, and an
    /// answer read as one undivided slab.
    public static let blockSpacing: CGFloat = Design.Spacing.inset

    /// How far a row under an open disclosure stands in from the disclosure's own words, which is
    /// also the room its rule and its hover plate share.
    public static let nestedRowIndent: CGFloat = Design.Spacing.inset

    /// A row's vertical rhythm: what it asks for above and below itself.
    ///
    /// Two neighbouring rows collapse their facing margins to the larger one, the way a
    /// document's paragraphs do, so a row never has to know what stands next to it and no
    /// list of pairs decides a gap. The pairwise rule this replaced put a user's bubble a
    /// turn's step under the heading above it and four points above the thinking beneath,
    /// because "either neighbour is work" beat everything the bubble might have wanted —
    /// and the bubble had nothing to want, since only pairs had values. Now each kind of
    /// row owns its two margins here, the table composes them with `gap(between:and:)`,
    /// and the row views carry no outer margins of their own.
    public struct Rhythm: Equatable, Sendable {
        public let above: CGFloat
        public let below: CGFloat

        public init(above: CGFloat, below: CGFloat) {
            self.above = above
            self.below = below
        }

        /// The gap between two rows: the larger of the margins that face each other.
        public static func gap(between upper: Rhythm, and lower: Rhythm) -> CGFloat {
            max(upper.below, lower.above)
        }

        /// The rule that opens an exchange: a turn's step above it, the bubble close under.
        public static let boundary = Rhythm(
            above: Design.Chat.turnSpacing,
            below: Design.Spacing.medium
        )

        /// The user's turn: close under its rule, a clear step before what answers it.
        public static let exchange = Rhythm(
            above: Design.Spacing.small,
            below: Design.Spacing.medium
        )

        /// Anything the agent says, reply or reasoning: a clear step above it, and close beneath,
        /// because what follows a sentence in a working turn is the work that sentence announced.
        /// The space belongs between steps, not between a step and its own calls.
        public static let answer = Rhythm(
            above: Design.Chat.stepSpacing,
            below: Design.Spacing.tight
        )

        /// A later block of an answer split into rows, spaced as the same document's blocks are.
        public static let answerBlock = Rhythm(
            above: Design.Chat.blockSpacing,
            below: Design.Spacing.tight
        )

        /// A heading inside an answer split into rows: `headingLeading` clear of what precedes
        /// it — the same step an unsplit answer keeps — and asking nothing extra below, so the
        /// section it names stands at the ordinary block gap beneath it.
        public static let heading = Rhythm(
            above: Design.Chat.headingLeading,
            below: Design.Spacing.small
        )

        /// A tool call, a run of them behind one disclosure, a settled turn's fold: nearly
        /// touching, since each row already carries the padding its hover plate needs.
        public static let work = Rhythm(
            above: Design.Spacing.hairline,
            below: Design.Spacing.hairline
        )

        /// A card, a placeholder, a notice, a pane's own furniture.
        public static let chrome = Rhythm(
            above: Design.Spacing.small,
            below: Design.Spacing.small
        )

        /// A seam the transcript starts under — a handoff banner, the child pane's
        /// heading — so whatever follows it opens a turn.
        public static let seam = Rhythm(
            above: Design.Spacing.small,
            below: Design.Chat.turnSpacing
        )
    }

    /// How far a newly arrived row rises into its place — see `Motion.transcriptArrive`.
    /// One `medium` step: enough to read as coming *up* from the reply box, short enough
    /// that the paragraph above it does not appear to move.
    public static let arrivalRise: CGFloat = Design.Spacing.medium

    /// How long after it was appended a row may still make its entrance. A row appended
    /// off screen — the reader scrolled up — materializes whenever they return, and arriving
    /// *then* would announce as new something that has been sitting there all along.
    public static let arrivalWindow: TimeInterval = 0.6
}
