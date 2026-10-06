import AppKit

// MARK: - Contrast

/// Whether a theme's text can be read on its own ground.
///
/// A theme is the one setting in the app that can make its *input* surface unusable, and the
/// terminal is where a user would have to type to undo it — so a palette arriving from
/// anywhere but a colour picker is checked before it is stored.
///
/// Only text-against-ground is checked. An ANSI colour close to the background is ordinary
/// (a dark `black` on a dark ground is how most themes are built, and rejecting it would
/// reject nearly every theme in circulation); text the colour of what it is drawn on is not.
public enum ThemeContrast {

    /// WCAG's floor for large text. Terminal type is smaller than that, but a theme is a
    /// deliberate aesthetic choice and holding it to body-text contrast would reject palettes
    /// people genuinely use — Solarized Dark included. This rejects the unreadable, not the
    /// low-contrast.
    public static let minimumRatio: CGFloat = TextLegibilityPolicy.glanceRatio

    public static func isLegible(foreground: NSColor, background: NSColor) -> Bool {
        ratio(foreground, background) >= minimumRatio
    }

    /// How far apart two colours look, as CIE76 ΔE in Lab.
    ///
    /// Contrast answers "can this be read on that"; this answers "are these two inks the same
    /// ink". A palette needs both, because a heading drawn in a colour 7.5 away from the body
    /// is perfectly legible and still invisible *as a heading*. 15 is the floor the stock
    /// palettes are held to: `#F7EFE6` against `#FFFFFF` is 7.5 and reads as one colour,
    /// `#D9D1C8` against `#FFFFFF` is 16.7 and reads as two.
    public static func perceptualDistance(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let a = lab(first)
        let b = lab(second)
        return ((a.l - b.l) * (a.l - b.l)
            + (a.a - b.a) * (a.a - b.a)
            + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    /// CIE Lab under the D65 white point, from the sRGB values a palette stores.
    private static func lab(_ color: NSColor) -> (l: CGFloat, a: CGFloat, b: CGFloat) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return (0, 0, 0) }

        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        let red = linear(srgb.redComponent)
        let green = linear(srgb.greenComponent)
        let blue = linear(srgb.blueComponent)

        // sRGB to CIE XYZ, then normalised by D65's white point.
        let x = (0.4124 * red + 0.3576 * green + 0.1805 * blue) / 0.95047
        let y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let z = (0.0193 * red + 0.1192 * green + 0.9505 * blue) / 1.08883

        func f(_ t: CGFloat) -> CGFloat {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t + 16.0 / 116.0)
        }

        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// The floor a palette's bold text is held apart from its body text by. Below this the two
    /// are one ink with two names, which is the whole defect the role exists to fix.
    public static let minimumBoldDistance: CGFloat = 15

    /// WCAG relative-luminance contrast, in the sRGB space these colours are stored in.
    public static func ratio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }

        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }
}
