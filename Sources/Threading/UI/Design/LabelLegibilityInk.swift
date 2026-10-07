import AppKit

/// Contrast repair for a supplied ink and grounds, independent of the app theme registry.
@MainActor
public enum LabelLegibility {
    // MARK: - Floors

    public enum Defaults {

        /// WCAG AA for body text.
        ///
        /// The same value, and for the same reason, as
        /// `TextLegibilityPolicy.readingRatio`: this is the app's own chrome, and the
        /// app is not entitled to the latitude it extends to a palette somebody else authored.
        public static let readingRatio: CGFloat = TextLegibilityPolicy.readingRatio

        /// WCAG AA for large text — the floor below which text stops being text.
        ///
        /// `ThemeContrast.minimumRatio`, borrowed rather than restated: it already carries the
        /// argument for why 3.0 is the number that "rejects the unreadable, not the
        /// low-contrast", which is precisely what the quietest tier needs and all it needs.
        public static let glanceRatio: CGFloat = ThemeContrast.minimumRatio

        /// How finely the walk gives transparency back.
        ///
        /// Twenty-four, matching `SelectionSurface.Defaults.holdBackSteps`, and for the same
        /// reason: it puts the granularity under a percentage point of alpha across the widest
        /// range a tier can travel, which is finer than any authored value is meaningful to.
        public static let strengthSteps = TextLegibilityPolicy.strengthSteps

        /// Entries kept before the table is dropped and rebuilt.
        ///
        /// Every stock theme, in both appearances, at both contrast settings, for four tiers is
        /// well under this; the cap is for the case nobody predicted rather than one that is
        /// expected. See `cached`.
        public static let cacheLimit = 512
    }

    // MARK: - Holding a tier

    /// `tier` held at `floor` over every ground it can be drawn on.
    ///
    /// `ceiling` is the strength of the tier above — the point past which giving transparency
    /// back would stop this being the quieter of the two.
    ///
    /// Returns `tier` **unchanged** when it already reads on all of them.
    public static func held(
        _ tier: NSColor,
        at floor: CGFloat,
        over grounds: [NSColor],
        ceiling: CGFloat
    ) -> NSColor {
        guard let ink = tier.usingColorSpace(.sRGB), let first = grounds.first else { return tier }

        // Every ground, not the average of them: one value is drawn on all of these, so the
        // binding constraint is whichever ground the ink is nearest to in luminance, and which
        // one that is moves with the theme.
        func reads(_ candidate: NSColor) -> Bool {
            grounds.allSatisfy {
                ThemeContrast.ratio(candidate.composited(over: $0), $0) >= floor
            }
        }

        guard !reads(ink) else { return tier }

        let authored = ink.alphaComponent
        if authored < ceiling {
            let steps = Defaults.strengthSteps
            for step in 1...steps {
                let alpha = authored + (ceiling - authored) * CGFloat(step) / CGFloat(steps)
                let candidate = ink.withAlphaComponent(alpha)
                guard reads(candidate) else { continue }
                return candidate
            }
        }

        // No strength reads, so the tier's **ink** is the problem rather than its transparency —
        // a mid-grey label on a mid-grey ground, where opacity only ever walks toward a colour
        // that is itself too close to the ground. The last resort is the one `Design.Status`
        // already takes for a status hue: composite it, then keep the hue and move the lightness
        // until it reads. Chained over the grounds in turn, as `Status.readable` chains its two:
        // the result is opaque, so it means the same thing on each of them.
        return grounds.reduce(ink.composited(over: first)) { $0.legible(on: $1, ratio: floor) }
    }

}
