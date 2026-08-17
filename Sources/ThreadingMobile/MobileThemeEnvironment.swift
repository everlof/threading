import SwiftUI
import UIKit

extension UIColor {
    /// sRGB relative luminance — how bright this colour reads, not how bright its channels are.
    ///
    /// Averaging the channels calls a saturated blue and a saturated yellow equally light, which
    /// is why the theme's ink and the keyboard's appearance are both chosen from this instead.
    var remoteRelativeLuminance: CGFloat? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// Light or dark is the whole of what iOS lets a theme say about the system keyboard.
///
/// There is no API that tints keycaps, so `UIKeyboardAppearance` is the entire seam and the only
/// question worth getting right is which side of the line a themed background falls on. It is
/// read from sRGB relative luminance so that one rule answers it and the choice of ink over the
/// accent, rather than leaving the keyboard to `getWhite`'s unspecified grayscale conversion and
/// a separate midpoint that can drift away from the rest of the palette.
enum MobileKeyboardAppearance {
    /// The keyboard that belongs over this background.
    static func over(_ background: UIColor) -> UIKeyboardAppearance {
        guard let luminance = background.remoteRelativeLuminance else { return .dark }
        return luminance > lightThreshold ? .light : .dark
    }

    /// The WCAG contrast crossover: above this a background carries dark ink, below it light ink.
    static let lightThreshold: CGFloat = 0.179
}

extension View {
    /// Dresses a view tree in the Mac's theme: the palette itself, plus the four presentation
    /// values that are read from it rather than from `remoteTheme` directly.
    ///
    /// A sheet is presented in its own hosting scene, and a custom `EnvironmentKey` set on the
    /// presenting view does not cross that boundary. So the issue report — the one surface always
    /// reached by a sheet from the root — drew the built-in fallback palette on a phone whose Mac
    /// was running Cyberpunk: grey plates, a white accent on Send, and a light keyboard under a
    /// dark theme, because `preferredColorScheme` did not cross either. Every sheet therefore
    /// re-states the theme instead of assuming it inherits.
    func mobileTheme(_ theme: RemoteThemePalette) -> some View {
        environment(\.remoteTheme, theme)
            .preferredColorScheme(theme.colorScheme)
            .tint(theme.accent)
            .toggleStyle(MobileThemedToggleStyle(theme: theme))
            .foregroundStyle(theme.label)
    }
}
