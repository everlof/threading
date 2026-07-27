import AppKit

/// Brings the 24-bit backgrounds a CLI paints into the terminal palette's own register.
///
/// # What this is for
///
/// An agent CLI draws its diff with `48;2;R;G;B` — absolute 24-bit colour, chosen for a generic
/// dark terminal, with no way to ask what palette it landed in. Measured out of a Christmas
/// night pane: the added wash arrived at `#0E3203` and the removed at `#470802`, chroma **0.084
/// and 0.094**, against a terminal background of `#082019` at chroma 0.033. Nothing in that
/// palette goes near those numbers. Two bands three times more colourful than anything around
/// them are the loudest thing in the window, and they are *background*.
///
/// Indexed colours never have this problem — `ansi256` is the palette by definition, so a
/// program using `\u{1b}[41m` already gets the theme's red. Only truecolor escapes the palette,
/// and only truecolor arrives here.
///
/// # Why this recipe is not the one `Design.Diff` uses
///
/// The app's own diff views own both halves of the picture, so they can move a wash's lightness
/// and then re-derive an ink that stays legible on it. **Here we own neither.** The program
/// chose the text colour to sit on the background it also chose, and it is still choosing them
/// while this runs. So lightness is the one coordinate left alone: hold it, and whatever
/// contrast the program arranged between its own foreground and background survives untouched.
/// Every adjustment below is therefore made at constant lightness.
///
/// That leaves the two coordinates that carry the complaint anyway:
///
/// - **Chroma** is compressed above a knee. Below the knee nothing moves, so a program's
///   restrained choices are left exactly as sent; above it the excess is scaled down, which is
///   where a neon slab loses its neon without a mid-strength badge losing its colour.
/// - **Hue** is drawn toward the nearest colour the palette actually contains, by a *fraction*
///   of the distance and never past a cap. A fraction rather than a snap because contraction
///   toward attractors cannot reorder hues: two colours that arrived distinct stay distinct and
///   in the same order, so a chart drawn in eight background blocks keeps its eight readable
///   categories. Snapping to a small set of anchors is what would collapse them.
///
/// Neither step knows what a diff is, and that is deliberate — a rule that fired only on colours
/// it guessed were diffs would guess wrong on someone's progress bar. This one is honest about
/// being a normalisation: *everything* the program paints behind text keeps its identity and its
/// contrast, and merely stops shouting louder than the theme it is sitting in.
enum TerminalBackgroundHarmony {

    enum Recipe {

        /// Chroma below which a colour is passed through untouched. Set just above where the
        /// stock palettes' own backgrounds and dim surfaces sit, so the common case of a
        /// slightly-tinted background is never touched at all.
        static let chromaKnee: CGFloat = 0.045

        /// How far above the knee the squeeze may ever reach. Chroma above the knee is soft
        /// clipped so that it approaches `chromaKnee + chromaHeadroom` and never passes it.
        ///
        /// A ceiling rather than a linear scaling, because the two have different failure
        /// modes and only one of them is acceptable. Scaling the excess by a fraction is
        /// unbounded — a colour twice as vivid still comes out twice as vivid, so nothing
        /// actually guarantees the slab is gone. Clipping flat at a limit is bounded but
        /// discards ordering, so every loud background arrives at one chroma and a program's
        /// deliberate gradient becomes a stripe. The soft clip is monotonic *and* bounded: more
        /// colourful in is still more colourful out, and nothing exceeds the ceiling.
        static let chromaHeadroom: CGFloat = 0.035

        /// Fraction of the way to the nearest palette hue a colour is moved.
        static let hueAttraction: CGFloat = 0.6

        /// Chroma above the knee at which hue attraction reaches full strength, ramping from
        /// nothing at the knee itself.
        ///
        /// Without this the transform was **not the identity on quiet colours**, and that is a
        /// visible bug rather than a purity concern: a program filling a region with the
        /// terminal's own background — `tput setab` with the theme's background, or a TUI
        /// erasing a panel — had its chroma correctly left alone and its hue rotated anyway,
        /// so `#082019` came back as `#06201C` and the block showed a seam against the real
        /// ground. Ramping rather than gating at the knee, because a hard threshold would
        /// render two indistinguishable colours either side of it visibly differently.
        ///
        /// Tying the two adjustments together is also the honest rule: the further a colour is
        /// being pulled down in loudness, the more it is worth aligning to the palette; a
        /// colour being left at its own chroma has not asked for anything.
        static let hueRamp: CGFloat = 0.02

        /// The most any colour's hue may move, in degrees. The cap is what keeps the attraction
        /// a nudge: at 25° a yellow-green becomes the palette's green and cannot become its cyan.
        static let hueAttractionLimit: CGFloat = 25

        /// A palette entry duller than this is not a hue, it is a grey with rounding error, and
        /// is no use as an anchor.
        static let minimumAnchorChroma: CGFloat = 0.04

        /// A colour whose nearest anchor is further than this keeps its own hue. The palette has
        /// nothing to say about it, and dragging it 25° toward an unrelated entry is noise.
        static let anchorWindow: CGFloat = 60
    }

    // MARK: - Building

    /// The transform for one palette, with the palette's hues measured once.
    ///
    /// Returns a closure because this is installed on `TerminalView.trueColorBackgroundTransform`
    /// and runs from the draw path — SwiftTerm caches per colour, so each distinct background a
    /// program emits costs one pass, but the anchor list must not be rebuilt inside it.
    static func transform(for theme: TerminalTheme) -> (NSColor) -> NSColor {
        let anchors = anchorHues(of: theme)
        let stated = statedColours(of: theme)

        return { incoming in
            harmonize(incoming, anchors: anchors, stated: stated)
        }
    }

    /// Every colour the palette states, packed to 8-bit RGB.
    ///
    /// A program can emit a palette colour as truecolor rather than as an index — anything that
    /// queries the palette over OSC 4 and echoes the answer does exactly this — and it must not
    /// then render differently from the indexed form of the same colour. The palette is in tune
    /// with the theme by definition; there is nothing to harmonise.
    static func statedColours(of theme: TerminalTheme) -> Set<UInt32> {
        let palette = [
            theme.foreground, theme.background, theme.cursor, theme.selection,
            theme.black, theme.red, theme.green, theme.yellow,
            theme.blue, theme.magenta, theme.cyan, theme.white,
            theme.brightBlack, theme.brightRed, theme.brightGreen, theme.brightYellow,
            theme.brightBlue, theme.brightMagenta, theme.brightCyan, theme.brightWhite
        ]
        return Set(palette.compactMap(packed))
    }

    /// 8-bit RGB in one integer, which is the resolution a truecolor escape carries — so this
    /// compares what was actually on the wire rather than two floats that will never be equal.
    private static func packed(_ colour: NSColor) -> UInt32? {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return nil }
        let red = UInt32((srgb.redComponent * 255).rounded())
        let green = UInt32((srgb.greenComponent * 255).rounded())
        let blue = UInt32((srgb.blueComponent * 255).rounded())
        return red << 16 | green << 8 | blue
    }

    /// The palette's chromatic hues, in degrees.
    ///
    /// Both the normal and bright halves, because a theme routinely states its most saturated
    /// version of a hue only in the bright row, and that is the one an incoming vivid colour
    /// should be measured against.
    static func anchorHues(of theme: TerminalTheme) -> [CGFloat] {
        let palette = [
            theme.red, theme.green, theme.yellow, theme.blue,
            theme.magenta, theme.cyan,
            theme.brightRed, theme.brightGreen, theme.brightYellow,
            theme.brightBlue, theme.brightMagenta, theme.brightCyan
        ]

        return palette.compactMap { colour in
            let value = colour.oklab
            guard value.chroma >= Recipe.minimumAnchorChroma else { return nil }
            return value.hue * 180 / .pi
        }
    }

    // MARK: - Recipe

    static func harmonize(
        _ incoming: NSColor,
        anchors: [CGFloat],
        stated: Set<UInt32> = []
    ) -> NSColor {
        // A colour the palette already states is left exactly alone, however vivid it is — the
        // indexed and truecolor spellings of one colour have to render identically.
        if let packed = packed(incoming), stated.contains(packed) { return incoming }

        let value = incoming.oklab

        // Below the knee this is the identity, and it hands back the *original* colour rather
        // than a rebuilt one. The trip through Oklab and back is not bit-exact — `cbrt` and
        // `pow` see to that — so reconstructing a colour nothing is being done to still moves
        // it a step, which is enough to seam a block painted in the terminal's own background
        // against the real ground. Returning the input is the only way to mean *unchanged*.
        guard value.chroma > Recipe.chromaKnee else { return incoming }

        let degrees = value.hue * 180 / .pi
        let hue = attracted(degrees, to: anchors, strength: attractionStrength(value.chroma))
        let chroma = compressed(value.chroma)

        // Lightness carried through untouched — see the note on the type.
        return NSColor.oklab(
            Oklab(lightness: value.lightness, chroma: chroma, hue: hue * .pi / 180)
        )
    }

    /// The soft clip: identity below the knee, asymptotic to the ceiling above it.
    ///
    /// `excess / (excess + headroom)` runs 0…1 as the excess runs 0…∞, so the result leaves the
    /// knee at unit slope — a colour just over the line is barely touched — and approaches
    /// `knee + headroom` without ever arriving. Strictly increasing everywhere, which is what
    /// keeps two different incoming chromas two different outgoing ones.
    static func compressed(_ chroma: CGFloat) -> CGFloat {
        let excess = chroma - Recipe.chromaKnee
        guard excess > 0 else { return chroma }
        return Recipe.chromaKnee + Recipe.chromaHeadroom * (excess / (excess + Recipe.chromaHeadroom))
    }

    /// How much of the hue attraction applies at this chroma: none at or below the knee, full
    /// once the colour is `hueRamp` past it. Zero here makes the whole transform the identity.
    static func attractionStrength(_ chroma: CGFloat) -> CGFloat {
        let excess = chroma - Recipe.chromaKnee
        guard excess > 0 else { return 0 }
        return min(1, excess / Recipe.hueRamp)
    }

    /// This hue moved a bounded fraction of the way toward the nearest anchor.
    private static func attracted(
        _ hue: CGFloat,
        to anchors: [CGFloat],
        strength: CGFloat
    ) -> CGFloat {
        guard strength > 0 else { return hue }

        let nearest = anchors
            .map { (anchor: $0, delta: signedDelta(from: hue, to: $0)) }
            .min { abs($0.delta) < abs($1.delta) }

        guard let nearest, abs(nearest.delta) <= Recipe.anchorWindow else { return hue }

        let step = nearest.delta * Recipe.hueAttraction * strength
        let capped = min(abs(step), Recipe.hueAttractionLimit) * (step < 0 ? -1 : 1)
        return hue + capped
    }

    /// Shortest signed rotation between two hues, −180...180. Hue is a circle, and every
    /// comparison here is a nearness test that would be wrong at the wrap point without this.
    private static func signedDelta(from: CGFloat, to: CGFloat) -> CGFloat {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }
}
