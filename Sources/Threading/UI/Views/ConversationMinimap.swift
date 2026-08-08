import AppKit

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

        /// Where the rail rests relative to the pane's own leading edge, when there is room.
        static let edgeInset: CGFloat = Design.Spacing.pane

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

        /// The same three constants read as one curve, sampled at whole marks out from the
        /// pointer: `[24, 16, 10, 8]`.
        ///
        /// **The stops are the design; the interpolation between them is only smoothness.**
        /// Sampling them by whole-number distance is what made the rail step. The pointer
        /// crossed the midpoint between two marks and every mark in the taper took a new width
        /// in one frame, so a control whose entire job is to say "you are here" moved in jumps
        /// while the pointer moved continuously. The values were never wrong, only the sampling.
        static var markerWidthProfile: [CGFloat] {
            [activeMarkerWidth] + neighbourMarkerWidths + [restingMarkerWidth]
        }

        /// Tallest the rail grows before its marks bunch closer than `markerSpacing`.
        static let maximumHeightFraction: CGFloat = 0.6

        /// The closest two marks may sit before the rail stops being pointable.
        ///
        /// `railHeight` caps at `maximumHeightFraction` of the pane while spacing was simply that
        /// height divided by the turns, so past about twenty-eight turns in a 900pt pane every
        /// further exchange packed the marks tighter, with no floor. At two hundred turns they
        /// were under three points apart and `mark(atY:)` was choosing between marks no pointer
        /// could separate — a control that answers a question the hand cannot ask.
        ///
        /// Past this floor the rail stops marking every turn and becomes a **bucketed index**:
        /// fewer marks than turns, each resolving to the turn it is nearest. That is a real loss,
        /// and the honest one — the alternative is marks that cannot be hit.
        static let minimumMarkerSpacing: CGFloat = Design.Spacing.medium
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

    /// How far the rail's leading edge sits from the pane's.
    ///
    /// **The rail belongs to the pane, not to the column.** Anchoring it to the column's
    /// leading edge looked right at 1000pt and wrong at 2000: the column is centred, so as the
    /// window grows the rail drifts inward with it and ends up stranded in the middle of an
    /// empty margin, attached to nothing the eye can see.
    ///
    /// So it rests near the pane's edge, and only gives that up when the gutter is too tight to
    /// hold both — at which point it slides left to keep its clearance from the text, which is
    /// the one thing it must never lose.
    static func railLeading(paneWidth: CGFloat, columnWidth: CGFloat) -> CGFloat {
        let columnLeading = gutter(paneWidth: paneWidth, columnWidth: columnWidth)
        let latest = columnLeading - Metrics.gutterInset - railWidth(
            paneWidth: paneWidth,
            columnWidth: columnWidth
        )
        return max(0, min(Metrics.edgeInset, latest))
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

    /// How many marks the rail draws.
    ///
    /// Every turn gets one until they would sit closer than `minimumMarkerSpacing`, after which
    /// the rail draws as many as it can hold and each stands for the turn it is nearest. Below
    /// that threshold — every conversation the rail serves up to its height cap — this is simply
    /// the turn count, and `turnIndex(forMark:)` / `markIndex(forTurn:)` are the identity.
    static func markCount(turnCount: Int, railHeight: CGFloat) -> Int {
        guard turnCount > 1 else { return max(0, turnCount) }
        guard railHeight > 0 else { return turnCount }

        let affordable = Int(railHeight / Metrics.minimumMarkerSpacing) + 1
        return max(2, min(turnCount, affordable))
    }

    /// Which turn a mark stands for. The rail's answer to a click, and to a hover.
    static func turnIndex(forMark mark: Int, markCount: Int, turnCount: Int) -> Int {
        guard markCount > 1, turnCount > 1 else { return 0 }
        let clamped = min(max(mark, 0), markCount - 1)
        return Int((CGFloat(clamped) / CGFloat(markCount - 1) * CGFloat(turnCount - 1)).rounded())
    }

    /// Which mark stands for a turn. The inverse, for placing the preview and for saying which
    /// marks are on screen.
    static func markIndex(forTurn turn: Int, markCount: Int, turnCount: Int) -> Int {
        guard markCount > 1, turnCount > 1 else { return 0 }
        let clamped = min(max(turn, 0), turnCount - 1)
        return Int((CGFloat(clamped) / CGFloat(turnCount - 1) * CGFloat(markCount - 1)).rounded())
    }

    /// The centre of a mark, measured down from the rail's top.
    ///
    /// Evenly spaced **on purpose**: this indexes the conversation, it does not scale it. A
    /// turn that ran forty tool calls and one that ran none are one exchange each, and spacing
    /// them by length would give a long turn a long stretch of rail that says nothing about
    /// how much was *said*.
    static func markerCenterY(mark: Int, markCount: Int, railHeight: CGFloat) -> CGFloat {
        guard markCount > 1 else { return railHeight / 2 }
        let clamped = min(max(mark, 0), markCount - 1)
        return railHeight * CGFloat(clamped) / CGFloat(markCount - 1)
    }

    /// Which mark a pointer at this height is nearest, or nil when there is nothing to point at.
    static func mark(atY y: CGFloat, markCount: Int, railHeight: CGFloat) -> Int? {
        guard markCount > 0 else { return nil }
        guard markCount > 1, railHeight > 0 else { return 0 }

        let progress = min(max(y / railHeight, 0), 1)
        return Int((progress * CGFloat(markCount - 1)).rounded())
    }

    /// A mark's width, given how far it sits from the one under the pointer.
    ///
    /// Nil `activeIndex` means the pointer is elsewhere and every mark rests at its shortest.
    static func markerWidth(index: Int, activeIndex: Int?) -> CGFloat {
        guard let activeIndex else { return Metrics.restingMarkerWidth }
        return markerWidth(distance: CGFloat(abs(index - activeIndex)))
    }

    // MARK: - Fisheye

    /// How far a mark sits from the pointer, counted in **marks rather than in points**.
    ///
    /// The unit matters once the rail is compressed. Past about twenty-eight turns `railHeight`
    /// hits its cap and the marks bunch closer than `markerSpacing`; a taper measured in points
    /// would then reach across a third of the rail and stop picking anything out. Measured in
    /// marks it keeps its shape at every density, which is what makes it read as "you are here"
    /// rather than as a glow.
    static func markerDistance(
        mark: Int,
        pointerY: CGFloat,
        markCount: Int,
        railHeight: CGFloat
    ) -> CGFloat {
        guard markCount > 1, railHeight > 0 else { return 0 }
        let spacing = railHeight / CGFloat(markCount - 1)
        guard spacing > 0 else { return 0 }

        let centre = markerCenterY(mark: mark, markCount: markCount, railHeight: railHeight)
        return abs(pointerY - centre) / spacing
    }

    /// The width profile read at a fractional distance.
    ///
    /// Smoothstep between the stops rather than a straight line, so the taper has no corner at
    /// a whole mark — a corner is visible here precisely because the eye is following the one
    /// thing that is moving.
    static func markerWidth(distance: CGFloat) -> CGFloat {
        let profile = Metrics.markerWidthProfile
        let outermost = profile.count - 1

        guard distance > 0 else { return profile[0] }
        guard distance < CGFloat(outermost) else { return profile[outermost] }

        let nearer = Int(distance)
        let phase = distance - CGFloat(nearer)
        return profile[nearer] + (profile[nearer + 1] - profile[nearer]) * smoothstep(phase)
    }

    /// A mark's width from where the pointer actually is, rather than from the mark it is
    /// nearest. Nil `pointerY` rests every mark.
    static func markerWidth(
        mark: Int,
        pointerY: CGFloat?,
        markCount: Int,
        railHeight: CGFloat
    ) -> CGFloat {
        guard let pointerY else { return Metrics.restingMarkerWidth }
        return markerWidth(distance: markerDistance(
            mark: mark,
            pointerY: pointerY,
            markCount: markCount,
            railHeight: railHeight
        ))
    }

    /// How strongly a mark is picked out: 1 under the pointer, falling to 0 at the edge of the
    /// taper.
    ///
    /// Colour rides the same falloff as width so the two cannot disagree about where the
    /// pointer is. Three hard colour buckets under a smooth taper looked like a rendering
    /// fault: the widths flowed and the tones snapped, on the same marks, in the same frame.
    static func markerEmphasis(distance: CGFloat) -> CGFloat {
        let span = CGFloat(Metrics.markerWidthProfile.count - 1)
        guard span > 0 else { return 0 }
        return 1 - smoothstep(min(max(distance / span, 0), 1))
    }

    /// The one easing curve the rail uses, so width and colour share a shape.
    private static func smoothstep(_ phase: CGFloat) -> CGFloat {
        let clamped = min(max(phase, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
