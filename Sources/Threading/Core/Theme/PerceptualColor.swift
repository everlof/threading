import AppKit

/// A colour measured in **Oklab** — the space this app reasons about appearance in, as opposed
/// to the sRGB it stores colours in.
///
/// The distinction is not academic, and the diff wash is where it first mattered. sRGB's numbers
/// say what a display should emit, not what a colour *looks* like: green at half brightness is
/// five times as luminous as red at half brightness, so a green and a red wash mixed at the same
/// alpha over the same ground land at visibly different strengths — the green a slab, the red a
/// stain. Nudging one of them by hand fixes that ground and breaks the next one.
///
/// Oklab is arranged so equal steps look equal. Lightness runs 0…1 with 0.5 the mid grey the eye
/// agrees is halfway; `a`/`b` carry the colour as a plane, which is why a hue is an angle here
/// and a chroma is a distance. Two colours a fixed lightness apart from their ground read as
/// equally strong whatever their hue, which is the whole property `Design.Diff.on(_:)` is built
/// on.
///
/// HSB would have been the reachable answer — `NSColor` hands it over — and it is the wrong one:
/// its "brightness" is the largest sRGB channel, so pure yellow and pure blue are both 1.0.
struct Oklab: Equatable {

    /// Perceptual lightness, 0 (black) to 1 (white).
    var lightness: CGFloat

    /// Green ↔ red.
    var a: CGFloat

    /// Blue ↔ yellow.
    var b: CGFloat

    /// How colourful, as the distance from the neutral axis. Around 0.03 for a wash, 0.2 for a
    /// vivid system colour, past 0.3 only for neon.
    var chroma: CGFloat { sqrt(a * a + b * b) }

    /// Which colour, as an angle in radians. Red sits near 0.5 rad, green near 2.5.
    var hue: CGFloat { atan2(b, a) }

    init(lightness: CGFloat, a: CGFloat, b: CGFloat) {
        self.lightness = lightness
        self.a = a
        self.b = b
    }

    /// The polar form: a lightness, how colourful, and which colour.
    init(lightness: CGFloat, chroma: CGFloat, hue: CGFloat) {
        self.init(lightness: lightness, a: chroma * cos(hue), b: chroma * sin(hue))
    }
}

// MARK: - Conversion

extension NSColor {

    /// This colour measured in Oklab.
    ///
    /// Resolves through sRGB, so a **dynamic** colour answers for whatever drawing appearance is
    /// current — measure inside `performAsCurrentDrawingAppearance` where the answer must match
    /// what a particular view draws, exactly as `applySurface` freezes its `CGColor` there.
    var oklab: Oklab {
        guard let srgb = usingColorSpace(.sRGB) else { return Oklab(lightness: 0, a: 0, b: 0) }

        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }

        let red = linear(srgb.redComponent)
        let green = linear(srgb.greenComponent)
        let blue = linear(srgb.blueComponent)

        let long = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
        let medium = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
        let short = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)

        return Oklab(
            lightness: 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short,
            a: 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short,
            b: 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
        )
    }

    /// The sRGB colour for an Oklab value, **chroma reduced until it fits**.
    ///
    /// Oklab describes colours no display can show — most of the space is outside sRGB — and the
    /// obvious answer, clipping each channel, changes the lightness as well as the colourfulness:
    /// a too-vivid green clips to a green that is also *lighter*, which is the one property a
    /// derivation built on equal lightness steps cannot afford to lose. Holding lightness and
    /// hue and giving up only chroma keeps the wash at the strength it was asked for and merely
    /// makes it less colourful than requested.
    static func oklab(_ value: Oklab) -> NSColor {
        func components(_ value: Oklab) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
            let long = pow(value.lightness + 0.3963377774 * value.a + 0.2158037573 * value.b, 3)
            let medium = pow(value.lightness - 0.1055613458 * value.a - 0.0638541728 * value.b, 3)
            let short = pow(value.lightness - 0.0894841775 * value.a - 1.2914855480 * value.b, 3)

            return (
                4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short,
                -1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short,
                -0.0041960863 * long - 0.7034186147 * medium + 1.7076147010 * short
            )
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
                if fits(Oklab(lightness: value.lightness, a: value.a * middle, b: value.b * middle)) {
                    low = middle
                } else {
                    high = middle
                }
            }
            scaled = Oklab(lightness: value.lightness, a: value.a * low, b: value.b * low)
        }

        let (red, green, blue) = components(scaled)

        func encoded(_ component: CGFloat) -> CGFloat {
            let clamped = min(max(component, 0), 1)
            return clamped <= 0.0031308
                ? clamped * 12.92
                : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }

        return NSColor(
            srgbRed: encoded(red),
            green: encoded(green),
            blue: encoded(blue),
            alpha: 1
        )
    }
}

// MARK: - Legibility

extension NSColor {

    /// This colour moved along its own lightness axis until it reads on `ground`.
    ///
    /// Keeps hue and chroma — the answer is still recognisably the theme's green, only lighter
    /// or darker — and returns the colour unchanged when it already passes, so a theme whose
    /// palette was authored with care is never second-guessed. The step that cannot be skipped
    /// is *which way*: nearer to white and nearer to black are both tried, and the smaller move
    /// that reaches the ratio wins. Assuming "away from the ground's lightness" picks the long
    /// way round for a mid-tone ground and lands on a colour further from the one asked for.
    ///
    /// Terminates because the extremes always pass: at lightness 0 and 1 the gamut mapping has
    /// taken the chroma with it, leaving black and white.
    ///
    /// **The answer sits on the boundary.** The bisection converges on the exact lightness where
    /// the ratio is met, so a caller who needs the floor to hold in *rendered pixels* has to ask
    /// for a hair more than the floor: the colour goes through an 8-bit channel and a colour
    /// space on its way to a raster, and either can spend a margin this thin. `GeneratedAppIcon`
    /// states its own — see the note there.
    func legible(
        on ground: NSColor,
        ratio minimum: CGFloat = ThemeContrast.minimumRatio
    ) -> NSColor {
        guard ThemeContrast.ratio(self, ground) < minimum else { return self }

        let value = oklab
        let alpha = usingColorSpace(.sRGB)?.alphaComponent ?? 1

        /// The nearest lightness in one direction that reaches the ratio, if any does.
        func search(towards target: CGFloat) -> (lightness: CGFloat, color: NSColor)? {
            func candidate(_ lightness: CGFloat) -> NSColor {
                NSColor.oklab(Oklab(lightness: lightness, chroma: value.chroma, hue: value.hue))
                    .withAlphaComponent(alpha)
            }
            guard ThemeContrast.ratio(candidate(target), ground) >= minimum else { return nil }

            var near = value.lightness
            var far = target
            for _ in 0..<PerceptualColor.legibilitySearchSteps {
                let middle = (near + far) / 2
                if ThemeContrast.ratio(candidate(middle), ground) >= minimum {
                    far = middle
                } else {
                    near = middle
                }
            }
            return (far, candidate(far))
        }

        let candidates = [search(towards: 1), search(towards: 0)].compactMap { $0 }
        return candidates
            .min { abs($0.lightness - value.lightness) < abs($1.lightness - value.lightness) }?
            .color ?? self
    }
}

// MARK: - Constants

enum PerceptualColor {

    /// Bisections used to find the largest in-gamut chroma. Twenty-four is far past the point
    /// where the answer moves an 8-bit channel; the loop is cheap and runs on colour changes.
    static let gamutSearchSteps = 24

    static let legibilitySearchSteps = 18
}
