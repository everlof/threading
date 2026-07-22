import Foundation

// MARK: - Conversation Minimap

/// Where the turn rail's marks go, and whether it may be drawn at all.
///
/// Pure arithmetic, separated from the view for the same reason `ConversationTimeline` is
/// separated from `ConversationRendering`: the interesting rules here — that the rail is an
/// *index* rather than a scaled map, and that it disappears rather than encroach on the text —
/// are decisions, and decisions should be testable without a window.
///
/// This is t3code's `MessagesTimeline.logic.ts` minimap arithmetic, ported: the geometry, the
/// fisheye, and the gutter rule that switches the whole thing off are theirs.
enum ConversationMinimap {

    // MARK: - Metrics

    enum Metrics {
        /// Vertical distance between two marks. The rail's height follows from the number of
        /// turns rather than from the conversation's length — see `railHeight`.
        ///
        /// t3code uses 8, which at three turns is a 16pt smudge that reads as a rendering
        /// artefact rather than a control. Measured off Codex's own rail instead — about
        /// twenty-five marks over five hundred points — which is roomy enough that a short
        /// conversation still looks like an index of something.
        static let markerSpacing: CGFloat = 20

        static let markerHeight: CGFloat = 2

        /// Below this, a rail says nothing a glance at the pane would not: one mark is not an
        /// index of anything.
        static let minimumTurns = 2

        /// Clearance between the rail and the text column, so the two never touch.
        static let gutterInset: CGFloat = 12

        /// The rail never grows past this, however wide the window gets. It is a control, and
        /// a 200pt one would read as a third pane.
        static let maximumWidth: CGFloat = 40

        /// A gutter this wide can hold the rail without it feeling wedged in, so it is shown
        /// at rest. Narrower, and it stays hidden until the pointer comes near.
        static let persistentGutter: CGFloat = 48

        /// Longest a mark grows: the one under the pointer.
        static let activeMarkerWidth: CGFloat = 24

        /// Widths for marks one, two, and more than two places from the pointer. The taper is
        /// what makes the rail readable as a *position* rather than as a row of identical
        /// ticks — it says "you are here" without a label.
        static let neighbourMarkerWidths: [CGFloat] = [16, 10]
        static let restingMarkerWidth: CGFloat = 8

        /// Tallest the rail grows before its marks bunch closer than `markerSpacing`.
        static let maximumHeightFraction: CGFloat = 0.6
    }

    // MARK: - Availability

    /// The space either side of a centred content column.
    static func gutter(paneWidth: CGFloat, columnWidth: CGFloat) -> CGFloat {
        max(0, (paneWidth - min(paneWidth, columnWidth)) / 2)
    }

    /// How wide the rail may be in a given pane, or zero when it must not be drawn.
    ///
    /// **Zero is the important answer.** A pane narrow enough that the column fills it has no
    /// room for a rail, and drawing one anyway would put a control on top of the text — which
    /// in a three-pane window is the common case, not the edge case.
    static func railWidth(paneWidth: CGFloat, columnWidth: CGFloat) -> CGFloat {
        let available = gutter(paneWidth: paneWidth, columnWidth: columnWidth) - Metrics.gutterInset
        return max(0, min(Metrics.maximumWidth, available.rounded(.down)))
    }

    /// Whether the rail stays visible without being asked for.
    static func isPersistent(paneWidth: CGFloat, columnWidth: CGFloat) -> Bool {
        gutter(paneWidth: paneWidth, columnWidth: columnWidth) >= Metrics.persistentGutter
    }

    /// Whether a rail is worth drawing for this many turns in this much room.
    static func isAvailable(turnCount: Int, paneWidth: CGFloat, columnWidth: CGFloat) -> Bool {
        turnCount >= Metrics.minimumTurns && railWidth(paneWidth: paneWidth, columnWidth: columnWidth) > 0
    }

    // MARK: - Geometry

    /// How tall the rail is for a given number of turns, bounded by the pane.
    ///
    /// It grows with the *count*, not with the conversation's length, and is centred rather
    /// than filling the height — a rail spanning a tall window for four turns would imply the
    /// spacing meant something.
    static func railHeight(turnCount: Int, paneHeight: CGFloat) -> CGFloat {
        let natural = CGFloat(max(0, turnCount - 1)) * Metrics.markerSpacing
        return min(max(natural, Metrics.markerHeight), paneHeight * Metrics.maximumHeightFraction)
    }

    /// The centre of a mark, measured down from the rail's top.
    ///
    /// Evenly spaced **on purpose**: this indexes the conversation, it does not scale it. A
    /// turn that ran forty tool calls and one that ran none are one exchange each, and spacing
    /// them by length would give a long turn a long stretch of rail that says nothing about
    /// how much was *said*.
    static func markerCenterY(index: Int, turnCount: Int, railHeight: CGFloat) -> CGFloat {
        guard turnCount > 1 else { return railHeight / 2 }
        let clamped = min(max(index, 0), turnCount - 1)
        return railHeight * CGFloat(clamped) / CGFloat(turnCount - 1)
    }

    /// Which mark a pointer at this height is nearest, or nil when there is nothing to point at.
    static func index(atY y: CGFloat, turnCount: Int, railHeight: CGFloat) -> Int? {
        guard turnCount > 0 else { return nil }
        guard turnCount > 1, railHeight > 0 else { return 0 }

        let progress = min(max(y / railHeight, 0), 1)
        return Int((progress * CGFloat(turnCount - 1)).rounded())
    }

    /// A mark's width, given how far it sits from the one under the pointer.
    ///
    /// Nil `activeIndex` means the pointer is elsewhere and every mark rests at its shortest.
    static func markerWidth(index: Int, activeIndex: Int?) -> CGFloat {
        guard let activeIndex else { return Metrics.restingMarkerWidth }

        let distance = abs(index - activeIndex)
        if distance == 0 { return Metrics.activeMarkerWidth }
        if distance <= Metrics.neighbourMarkerWidths.count {
            return Metrics.neighbourMarkerWidths[distance - 1]
        }
        return Metrics.restingMarkerWidth
    }
}
