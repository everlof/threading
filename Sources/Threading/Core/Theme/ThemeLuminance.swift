import Foundation

// MARK: - Theme Luminance

/// The sRGB arithmetic the theme's picture checks share: compositing one colour over another and
/// WCAG relative luminance through a table-driven transfer function.
///
/// Its own file because two checks need it in two images. `ThemeImageLegibility` (pictures under
/// text, app only) and `ThemeArtSeparation` (pictures against their ground, which the brand row
/// also uses inside `ThreadingDesignKit`) measure the same quantity, and the kit compiles the
/// app's sources through symlinks — so the shared part lives where both can link it.
enum ThemeLuminance {

    struct RGB: Sendable, Equatable {
        let r: Double, g: Double, b: Double

        func over(_ ground: RGB, opacity: Double) -> RGB {
            RGB(r: r * opacity + ground.r * (1 - opacity),
                g: g * opacity + ground.g * (1 - opacity),
                b: b * opacity + ground.b * (1 - opacity))
        }

        /// WCAG relative luminance of this sRGB colour.
        var luminance: Double {
            0.2126 * Linearization.linear(r) + 0.7152 * Linearization.linear(g)
                + 0.0722 * Linearization.linear(b)
        }
    }

    /// The sRGB transfer function as a table, linearly interpolated: within 1e-6 of the exact
    /// curve everywhere, which is far below what a 3:1 advisory can resolve. Linearising a channel
    /// is then a table read rather than a `pow` — the exact path made about 80 million `pow`
    /// calls for a full theme (`ThemeImageLegibility`, performance.md).
    enum Linearization {
        private static let steps = 4_096
        private static let table: [Double] = (0...steps).map { step in
            exact(Double(step) / Double(steps))
        }

        static func exact(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        static func linear(_ value: Double) -> Double {
            let position = min(max(value, 0), 1) * Double(steps)
            let index = Int(position)
            guard index < steps else { return table[steps] }
            let fraction = position - Double(index)
            return table[index] + (table[index + 1] - table[index]) * fraction
        }
    }
}
