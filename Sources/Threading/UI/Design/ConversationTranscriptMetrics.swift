import AppKit

/// The transcript's spacing and arrival metrics shared by every desktop host.
extension Design.Chat {
    /// What a heading stands clear of the block before it. Spacing above a heading and not
    /// below it is what attaches it to the section it names; with the ordinary block gap on
    /// both sides it floated halfway between two paragraphs.
    public static let headingLeading: CGFloat = Design.Spacing.large

    /// Vertical gap between one turn and the next. The divider now carries the boundary, so
    /// this only needs to be one large step rather than a second oversized separator.
    public static let turnSpacing: CGFloat = Design.Spacing.large

    /// Between the blocks of one document, and between an answer and whatever stands beside
    /// it: one value, so an answer split into rows reads exactly like one document.
    ///
    /// `inset`, not `small`: once lines stand `readingLineHeight` apart, a six-point gap
    /// between paragraphs was *less* than the gap between two lines of one paragraph, and an
    /// answer read as one undivided slab.
    public static let blockSpacing: CGFloat = Design.Spacing.inset

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
            below: Design.Spacing.small
        )

        /// The user's turn: close under its rule, a clear step before what answers it.
        public static let exchange = Rhythm(
            above: Design.Spacing.small,
            below: Design.Spacing.medium
        )

        /// The agent's answer, and each block of one when it is split into rows.
        public static let answer = Rhythm(
            above: Design.Chat.blockSpacing,
            below: Design.Chat.blockSpacing
        )

        /// A heading inside an answer split into rows: `headingLeading` clear of what precedes
        /// it — the same step an unsplit answer keeps — and asking nothing extra below, so the
        /// section it names stands at the ordinary block gap beneath it.
        public static let heading = Rhythm(
            above: Design.Chat.headingLeading,
            below: Design.Spacing.small
        )

        /// Thinking, a tool call, a run of them behind one disclosure: tight, so the work
        /// reads as one strip and the sentences around it stand out.
        public static let work = Rhythm(
            above: Design.Spacing.tight,
            below: Design.Spacing.tight
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
