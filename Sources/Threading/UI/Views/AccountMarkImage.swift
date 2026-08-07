import AppKit

/// A login's runtime and its pressure in one 14pt mark: the agent's brand above, a meter of the
/// window that binds it below.
///
/// Exists because the composer's identity menu stopped being a menu of *one* runtime's logins.
/// Offering every login of every runtime in one list means each row has to say which runtime it
/// belongs to — and a menu row has exactly one image slot, which `UsageRingImage` already owned.
///
/// The ring lost that slot rather than the mark, and the meter replaces it: measured against the
/// real 14pt column, a brand mark drawn *inside* a ring is a coloured smudge that identifies
/// nothing, which is the one job the mark is here to do. Underlining it keeps both answers legible
/// — the silhouette says Claude or Codex, and a bar that is short and green or long and red
/// compares two logins without reading twelve numbers, which is the whole argument for the ring.
///
/// Drawn rather than composed from views for the same reason `UsageRingImage` is: a menu row takes
/// an `NSImage`, and one reusable image is cheaper than a view per row.
@MainActor
enum AccountMarkImage {

    private enum Layout {
        /// The image column a themed menu row reserves.
        static let size = NSSize(width: 14, height: 14)
        /// What is left for the mark once the meter's row is taken. Fixed rather than "whatever
        /// is unused", so the mark is the same size and in the same place on every row —
        /// including the rows that will never have a meter, and the ones whose reading has not
        /// landed yet. Sizing to the space actually used would grow and shrink a login's mark as
        /// the network answers, which reads as a defect rather than as a missing number.
        static let markSide: CGFloat = 10
        /// Thick enough to carry a hue at this size; a 1pt bar reads as an artefact of the mark
        /// rather than as a reading of its own.
        static let meterHeight: CGFloat = 2
        /// The mark's own row sits above the meter's, with a hairline of air between them so the
        /// two read as a pair rather than as one glyph with a coloured foot.
        static let markOrigin: CGFloat = meterHeight + 1
        /// Below this the fill is shorter than its own cap and reads as a dot at either end of
        /// the track, so it draws at the floor instead — the honest picture of "barely used".
        static let minimumVisibleFraction = 0.02
    }

    // MARK: - Public Methods

    /// `kind`'s mark, metered by the window a session started on `account` running `model` would
    /// run out of first.
    ///
    /// Nil only when the runtime has no mark at all, which no shipped `AgentKind` is — every one
    /// falls back to an SF Symbol. The *meter* is what goes missing on an account with no usage
    /// source, and the mark is drawn alone rather than the row losing its image.
    static func make(
        for kind: AgentKind,
        usage: AccountUsage?,
        metering model: String? = nil,
        at now: Date = Date()
    ) -> NSImage? {
        guard let mark = kind.icon else { return nil }

        let window = usage?.bindingWindow(at: now, metering: model)
        return make(mark: mark, fraction: window?.fraction)
    }

    /// The mark alone, centred — for a runtime row with no login behind it, where no reading
    /// can ever arrive to fill a meter.
    ///
    /// Centred rather than held in the metered slot, deliberately: the slot exists so a
    /// *login's* mark does not jump when its reading lands, and on a row that will never have
    /// one the reserved meter line is just the mark riding visibly high beside a centred
    /// title — which is exactly how it read in the identity menu's Grok and OpenCode rows.
    static func make(for kind: AgentKind) -> NSImage? {
        guard let mark = kind.icon else { return nil }
        return make(mark: mark, fraction: nil, reservesMeter: false)
    }

    // MARK: - Private Methods

    /// Not private for the type's sake — `fraction` is the whole contract, and a caller with a
    /// number rather than an account still gets the same picture.
    static func make(mark: NSImage, fraction: Double?, reservesMeter: Bool = true) -> NSImage {
        let image = NSImage(size: Layout.size, flipped: false) { rect in
            TemplateImageDrawing.draw(
                mark,
                in: NSRect(
                    x: rect.midX - Layout.markSide / 2,
                    y: reservesMeter
                        ? Layout.markOrigin
                        : (rect.height - Layout.markSide) / 2,
                    width: Layout.markSide,
                    height: Layout.markSide
                ),
                tint: Design.Text.label
            )

            guard let fraction else { return true }

            let track = NSRect(x: 0, y: 0, width: rect.width, height: Layout.meterHeight)
            let radius = Layout.meterHeight / 2
            Design.Text.quaternary.setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

            // The full track is always drawn, so an empty window still reads as a window rather
            // than as a missing reading — the same reason the ring draws its own track.
            let visible = max(Layout.minimumVisibleFraction, min(fraction, 1))
            let filled = NSRect(
                x: 0,
                y: 0,
                width: max(Layout.meterHeight, rect.width * CGFloat(visible)),
                height: Layout.meterHeight
            )
            UsageSeverity.from(fraction: fraction).glyphColor.setFill()
            NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()

            return true
        }

        // Not a template: the fill carries the severity, and the mark's own colour is the brand's.
        // A template would flatten both to the row's ink and lose the only two things this says.
        image.isTemplate = false
        return image
    }
}
