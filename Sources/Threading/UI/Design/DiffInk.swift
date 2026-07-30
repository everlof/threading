import AppKit

extension Design {

    /// What a diff draws with on **one** ground: the ink its markers and counters are set in,
    /// and the wash behind a changed line.
    ///
    /// Both halves are answers to the same question, which is why they arrive together. A wash
    /// is only meaningful against the thing it sits on, and the ink is only legible against the
    /// wash — deriving one without the other is how a green marker ended up on a green slab.
    struct DiffInk: Equatable {

        /// The ink for a `+` marker, an added line number, a `+N` counter.
        let added: NSColor

        /// The same for a removal.
        let removed: NSColor

        /// The full-width fill behind an added line. Opaque: it was computed *for* this ground,
        /// so letting anything else show through would undo the measurement.
        let addedWash: NSColor

        /// The same for a removed line.
        let removedWash: NSColor
    }
}

// MARK: - Derivation

extension Design.Diff {

    /// The diff palette for the ground it will be drawn on.
    ///
    /// # Why this is measured rather than stated
    ///
    /// A diff wash used to be the theme's green or red at a fixed 16% alpha, and a fixed alpha
    /// says nothing about how strong the result *looks*. The same recipe gave a neon slab on
    /// Cyberpunk's near-black, a muddy olive smear on Bauhaus's warm paper, and — the case that
    /// prompted this — two saturated blocks in a conversation, where the ground is not the app
    /// theme's at all but the **terminal palette's** background (see `WindowBackdrop`). Three
    /// grounds, one constant, three different-looking answers.
    ///
    /// So the wash is derived from the ground instead, in Oklab, where a fixed lightness step
    /// reads as a fixed strength whatever the hue (`PerceptualColor`):
    ///
    /// - **Lightness** moves away from the ground by a step scaled to the room available — a
    ///   near-black ground has all of it, paper has almost none — so the wash is a tint of the
    ///   ground under every theme rather than a patch of colour laid over it.
    /// - **Colourfulness** is taken from the theme's own diff ink and held to a band. A muted
    ///   style gets a muted wash and Cyberpunk gets a vivid one, which is the whole of "in tune
    ///   with the theme"; the band is what stops either extreme from becoming grey or neon.
    /// - **Hue** is the theme's, clamped into the green and red arcs. This is the one thing that
    ///   is *not* negotiable: a theme is free to state a teal `statusPositive` and gets a
    ///   teal-green wash, but nothing it can state makes an added line orange.
    /// - **The ground's own tint is kept**, not replaced: the wash is the ground plus a diff
    ///   tint, so warm paper stays warm under a red wash and a green-black terminal keeps its
    ///   cast. Replacing it made every theme's washes the same two colours.
    ///
    /// One asymmetry is deliberate: **removed always ends up darker than added**, on light and
    /// dark grounds alike. It is the convention every diff tool follows, and it means the two
    /// are told apart by lightness as well as by hue — the only part of this a red-green
    /// colourblind reader can use, beyond the `+`/`−` in the gutter.
    ///
    /// Translucent grounds are flattened against the chrome's own, because a wash computed
    /// against a colour nobody sees is a wash measured against nothing.
    static func on(_ ground: NSColor) -> Design.DiffInk {
        let base = ground.composited(over: Design.Surface.ground)
        let value = base.oklab

        // The same test `Design.Text.on(_:)` uses, and for the same reason: measuring both
        // extremes answers for a mid-tone ground, where a luminance threshold guesses.
        let isDark = ThemeContrast.ratio(.white, base) >= ThemeContrast.ratio(.black, base)
        let boost = Design.Accessibility.increasesContrast ? Recipe.increasedContrast : 1

        // The room between the ground and the end of the scale it is moving towards. Without
        // this a fixed step lands past white on paper and vanishes into a near-black ground.
        let headroom = isDark ? 1 - value.lightness : value.lightness
        let step = (isDark ? Recipe.riseOnDark : -Recipe.fallOnLight) * headroom * boost

        // The recessive side is whichever of the two must come out darker: on a dark ground the
        // washes rise, so removal rises less; on a light one they sink, so removal sinks more.
        let addedStep = isDark ? step : step * Recipe.recessiveShare
        let removedStep = isDark ? step * Recipe.recessiveShare : step

        let addedWash = wash(
            on: value,
            ink: Design.Diff.added,
            band: Recipe.addedHues,
            step: addedStep,
            boost: boost
        )
        let removedWash = wash(
            on: value,
            ink: Design.Diff.removed,
            band: Recipe.removedHues,
            step: removedStep,
            boost: boost
        )

        return Design.DiffInk(
            // Legible on both the ground it may be counted on and the wash it may be marked on.
            // The two are a lightness step apart, so the second call almost never moves it.
            added: Design.Diff.added.legible(on: base).legible(on: addedWash),
            removed: Design.Diff.removed.legible(on: base).legible(on: removedWash),
            addedWash: addedWash,
            removedWash: removedWash
        )
    }

    /// One wash: the ground, lifted by `step` and tinted towards the ink's own hue.
    private static func wash(
        on ground: Oklab,
        ink: NSColor,
        band: ClosedRange<CGFloat>,
        step: CGFloat,
        boost: CGFloat
    ) -> NSColor {
        let hue = band.clampingAngle(ink.oklab.hue)
        let chroma = min(
            max(ink.oklab.chroma * Recipe.chromaShare, Recipe.chromaFloor * boost),
            Recipe.chromaCeiling * boost
        )

        // How much of the ground's own colourfulness already points this way. Subtracting it
        // keeps the *result* at the chroma asked for rather than adding to a ground that was
        // already reddish — and the floor is what stops a ground pointing the opposite way from
        // cancelling the tint out into grey.
        let direction = (cos(hue), sin(hue))
        let existing = ground.a * direction.0 + ground.b * direction.1
        let tint = max(chroma - existing, chroma * Recipe.minimumTintShare)

        let combined = Oklab(
            lightness: min(max(ground.lightness + step, 0), 1),
            a: ground.a + tint * direction.0,
            b: ground.b + tint * direction.1
        )

        // Clamped **again**, on the sum rather than on the ink alone.
        //
        // Adding a tint to a ground is vector addition, so the answer's hue is somewhere
        // between the two — and a strongly coloured ground wins that argument. Clamping only
        // the ink's hue therefore did not deliver the arc it promised: on Vaporwave's `#2A1553`
        // panel the added wash came out **cyan** and the removed one magenta, and on the
        // Christmas terminal ground removal landed at 0.81 rad, the orange this recipe
        // explicitly holds short of. The ground still shapes the result — it moves the hue
        // within the arc and sets how much chroma survives — it simply cannot push it out.
        return .oklab(Oklab(
            lightness: combined.lightness,
            chroma: combined.chroma,
            hue: band.clampingAngle(combined.hue)
        ))
    }

    /// The numbers this derivation turns on, and where each came from.
    ///
    /// Calibrated against the washes GitHub and VS Code ship — measured in Oklab rather than
    /// guessed at, because those two are what a reader arrives here already used to. Their
    /// added lines sit 0.07–0.13 lightness above a dark ground and 0.02–0.05 below a light one,
    /// at a chroma of 0.02–0.04. Anything much past that stops being a wash.
    private enum Recipe {

        /// Green through to the teal-green a theme is allowed to reach for. Oklab's green
        /// arc — pure sRGB green is 2.49 rad, GitHub's added wash 2.90.
        static let addedHues: ClosedRange<CGFloat> = 2.27...3.05

        /// Crimson through to the warm red an orange-leaning theme lands on. Held short of
        /// pure red's 0.51 rad, which at wash chroma over a dark ground reads brown rather
        /// than red — the one hue that made a removed line look like a warning.
        static let removedHues: ClosedRange<CGFloat> = -0.14...0.44

        /// The share of the room above a dark ground the wash climbs.
        static let riseOnDark: CGFloat = 0.10

        /// And below a light one. Smaller because a tint darkens paper visibly at a step that
        /// would be invisible on ink — the asymmetry both reference implementations show.
        static let fallOnLight: CGFloat = 0.045

        /// What the darker of the two moves, against the other's full step.
        static let recessiveShare: CGFloat = 0.72

        /// A wash's chroma as a share of the ink's. A fifth keeps Cyberpunk's neon green
        /// recognisably itself at a strength that can sit behind code.
        static let chromaShare: CGFloat = 0.22

        /// Below this a wash is grey, above it a wash competes with the code on top of it.
        static let chromaFloor: CGFloat = 0.028
        static let chromaCeiling: CGFloat = 0.055

        /// The least tint a wash gets when the ground's own colour opposes it.
        static let minimumTintShare: CGFloat = 0.5

        /// Increase Contrast lifts the step and the colourfulness together — a stronger wash,
        /// still the same colour.
        static let increasedContrast: CGFloat = 1.7
    }
}

// MARK: - Angles

private extension ClosedRange where Bound == CGFloat {

    /// The nearest angle inside this arc, wrapping — so a hue just past the far edge snaps to
    /// that edge rather than crossing the whole wheel to the near one.
    func clampingAngle(_ angle: CGFloat) -> CGFloat {
        let turn = CGFloat.pi * 2

        func normalised(_ value: CGFloat) -> CGFloat {
            let remainder = value.truncatingRemainder(dividingBy: turn)
            return remainder < 0 ? remainder + turn : remainder
        }

        let span = normalised(upperBound - lowerBound)
        let offset = normalised(angle - lowerBound)
        guard offset > span else { return angle }
        return normalised(offset - span) < turn - offset ? upperBound : lowerBound
    }
}
