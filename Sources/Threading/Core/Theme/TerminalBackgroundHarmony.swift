import AppKit
import SwiftTerm

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
    /// A value-only transform safe to run on SwiftTerm's renderer thread.
    struct Transform: TerminalTrueColorBackgroundTransform {
        let anchors: [CGFloat]
        let stated: Set<UInt32>
        let cacheIdentity: UInt64

        init(theme: TerminalTheme) {
            anchors = anchorHues(of: theme)
            stated = statedColours(of: theme)
            cacheIdentity = TerminalBackgroundHarmony.cacheIdentity(
                anchors: anchors,
                stated: stated)
        }

        func transform(_ color: TerminalRenderedColor) -> TerminalRenderedColor {
            TerminalBackgroundHarmony.harmonize(color, anchors: anchors, stated: stated)
        }
    }

    /// The transform for one palette, with the palette's hues measured once on the main actor.
    /// SwiftTerm then applies only value math on its renderer thread and caches each result.
    static func transform(for theme: TerminalTheme) -> Transform {
        Transform(theme: theme)
    }

    private static func cacheIdentity(anchors: [CGFloat], stated: Set<UInt32>) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        func append(_ component: UInt64) {
            value ^= component
            value &*= 1_099_511_628_211
        }
        for color in stated.sorted() {
            append(UInt64(color))
        }
        for anchor in anchors {
            append(Double(anchor).bitPattern)
        }
        return value
    }

    /// Every colour the palette states, packed to 8-bit RGB.
    ///
    /// A program can emit a palette colour as truecolor rather than as an index — anything that
    /// queries the palette over OSC 4 and echoes the answer does exactly this — and it must not
    /// then render differently from the indexed form of the same colour. The palette is in tune
    /// with the theme by definition; there is nothing to harmonise.
    static func statedColours(of theme: TerminalTheme) -> Set<UInt32> {
        // Every colour, including the bold foreground: a palette that states one has it on
        // screen as often as its body text, and a program echoing it back as truecolor must
        // land on the same pixel as the palette's own.
        let palette = [
            theme.foreground, theme.boldForeground, theme.background,
            theme.cursor, theme.selection,
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
    ///
    /// Not the text roles, `boldForeground` included: this is the set of hues a background is
    /// pulled *towards*, and an ink is chosen to stand apart from the ground rather than to
    /// name a hue the ground should take.
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

    private static func harmonize(
        _ incoming: TerminalRenderedColor,
        anchors: [CGFloat],
        stated: Set<UInt32>
    ) -> TerminalRenderedColor {
        let packed = UInt32(incoming.red) << 16
            | UInt32(incoming.green) << 8
            | UInt32(incoming.blue)
        guard !stated.contains(packed) else { return incoming }

        let value = oklab(incoming)
        guard value.chroma > Recipe.chromaKnee else { return incoming }

        let degrees = value.hue * 180 / .pi
        let hue = attracted(degrees, to: anchors, strength: attractionStrength(value.chroma))
        return renderedColor(Oklab(
            lightness: value.lightness,
            chroma: compressed(value.chroma),
            hue: hue * .pi / 180))
    }

    private static func oklab(_ color: TerminalRenderedColor) -> Oklab {
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        let red = linear(CGFloat(color.red) / 255)
        let green = linear(CGFloat(color.green) / 255)
        let blue = linear(CGFloat(color.blue) / 255)
        let long = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
        let medium = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
        let short = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)

        return Oklab(
            lightness: 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short,
            a: 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short,
            b: 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short)
    }

    private static func renderedColor(_ value: Oklab) -> TerminalRenderedColor {
        func components(_ value: Oklab) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
            let long = pow(value.lightness + 0.3963377774 * value.a + 0.2158037573 * value.b, 3)
            let medium = pow(value.lightness - 0.1055613458 * value.a - 0.0638541728 * value.b, 3)
            let short = pow(value.lightness - 0.0894841775 * value.a - 1.2914855480 * value.b, 3)
            return (
                4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short,
                -1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short,
                -0.0041960863 * long - 0.7034186147 * medium + 1.7076147010 * short)
        }

        func fits(_ value: Oklab) -> Bool {
            let (red, green, blue) = components(value)
            let slack: CGFloat = -0.0005
            return [red, green, blue].allSatisfy { $0 >= slack && $0 <= 1 - slack }
        }

        var scaled = value
        if !fits(value) {
            var low: CGFloat = 0
            var high: CGFloat = 1
            for _ in 0..<PerceptualColor.gamutSearchSteps {
                let middle = (low + high) / 2
                let candidate = Oklab(
                    lightness: value.lightness,
                    a: value.a * middle,
                    b: value.b * middle)
                if fits(candidate) {
                    low = middle
                } else {
                    high = middle
                }
            }
            scaled = Oklab(
                lightness: value.lightness,
                a: value.a * low,
                b: value.b * low)
        }

        func byte(_ component: CGFloat) -> UInt8 {
            let clamped = min(max(component, 0), 1)
            let encoded = clamped <= 0.0031308
                ? clamped * 12.92
                : 1.055 * pow(clamped, 1 / 2.4) - 0.055
            return UInt8(min(max((encoded * 255).rounded(), 0), 255))
        }

        let (red, green, blue) = components(scaled)
        return TerminalRenderedColor(red: byte(red), green: byte(green), blue: byte(blue))
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
