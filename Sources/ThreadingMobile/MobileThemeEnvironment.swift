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
    /// The explicit appearance that matches an application-owned surface's resolved mode.
    ///
    /// Most UIKit editors can inherit this through `preferredColorScheme`. An editor that takes
    /// focus during a navigation transition must state it before becoming first responder:
    /// while the destination is in flight, `.default` can briefly resolve against the transition
    /// scene instead of the destination and make the keyboard material flash between modes.
    static func matching(_ colorScheme: ColorScheme) -> UIKeyboardAppearance {
        colorScheme == .light ? .light : .dark
    }

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
        modifier(MobileThemeEnvironmentModifier(theme: theme))
    }

    /// Text that belongs to the person or an agent — a transcript snippet, what is typed into
    /// an editor — keeps the platform's typography. A theme's font and typeface hint dress
    /// titles and chrome only (`docs/decisions/phone-theme-rendering.md`), yet `mobileTheme`
    /// states both for everything beneath it, so content steps back out here. `nil` clears the
    /// root's typeface hint; `.fontDesign(.default)` does not, and leaves an outer design in force.
    func mobileContentTypography(_ font: Font = .body) -> some View {
        self.font(font).fontDesign(nil)
    }
}

private struct MobileThemeEnvironmentModifier: ViewModifier {
    let theme: RemoteThemePalette
    @ObservedObject private var assets = MobileThemeAssets.shared

    func body(content: Content) -> some View {
        let _ = assets.revision
        var preparedTheme = theme
        preparedTheme.registeredFontName = assets.fontName(for: theme.source?.material.fontFamily)
        return content.environment(\.remoteTheme, preparedTheme)
            .preferredColorScheme(theme.colorScheme)
            .tint(theme.accent)
            .toggleStyle(MobileThemedToggleStyle(theme: theme))
            .foregroundStyle(theme.label)
            .fontDesign(preparedTheme.registeredFontName == nil ? theme.fontDesign : nil)
            .font(theme.chromeSwiftUIFont(.body))
    }
}


extension RemoteThemePalette {
    var fontDesign: Font.Design {
        switch source?.material.typeface?.rawValue {
        case "serif": .serif
        case "rounded": .rounded
        case "monospaced": .monospaced
        default: .default
        }
    }

    var systemFontDesign: UIFontDescriptor.SystemDesign {
        switch source?.material.typeface?.rawValue {
        case "serif": .serif
        case "rounded": .rounded
        case "monospaced": .monospaced
        default: .default
        }
    }

    var tintsIdentityMarks: Bool { source?.material.identityMarks == "tinted" }

    @MainActor func chromeFont(forTextStyle style: UIFont.TextStyle) -> UIFont {
        let native = UIFont.preferredFont(forTextStyle: style)
        if let name = registeredFontName ?? MobileThemeAssets.shared.fontName(for: source?.material.fontFamily),
           let font = UIFont(name: name, size: native.pointSize) { return font }
        guard let descriptor = native.fontDescriptor.withDesign(systemFontDesign) else { return native }
        return UIFont(descriptor: descriptor, size: native.pointSize)
    }

    @MainActor func chromeSwiftUIFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let resolvedWeight = weight ?? (style == .headline ? .semibold : .regular)
        if let name = registeredFontName ?? MobileThemeAssets.shared.fontName(for: source?.material.fontFamily) {
            let size: CGFloat = switch style {
            case .largeTitle: 34
            case .title: 28
            case .title2: 22
            case .title3: 20
            case .headline, .body: 17
            case .callout: 16
            case .subheadline: 15
            case .footnote: 13
            case .caption: 12
            case .caption2: 11
            @unknown default: 17
            }
            return .custom(name, size: size, relativeTo: style).weight(resolvedWeight)
        }
        return .system(style, design: fontDesign, weight: resolvedWeight)
    }
}
