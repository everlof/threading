import AppKit

/// The stock styles the app ships.
///
/// Named after design movements — Bauhaus, Art Deco, Swiss/International Style — which are
/// public design history rather than anyone's property. The palettes here are our own values,
/// authored against those aesthetics; nothing is copied from any style guide or site.
///
/// **What a style can and cannot carry here.** A design style is roughly four layers: palette,
/// material (radius, border weight, shadow), type, and layout with motion. This ships the
/// first. Skalman's layout *is* the product, so no theme moves the sidebar, and the material
/// layer is deliberately not attempted yet — which is why the styles that live or die by
/// shadow (Neumorphism, Claymorphism, Neo Brutalism) are not offered at all rather than
/// offered as flat grey approximations of themselves.
///
/// Each states only the roles in `AppThemeRole.authored`; the rest are derived, so a theme is a
/// dozen decisions rather than twenty-five.
enum AppThemeStyles {

    static let all: [AppTheme] = [cyberpunk, swissMinimalist]

    /// High-contrast neon on near-black. The most demanding palette-only style: if this reads
    /// as Cyberpunk with no glow, no glitch and no monospace display face, the approach works.
    static let cyberpunk = AppTheme(
        id: AppThemeID("cyberpunk"),
        name: "Cyberpunk",
        mode: .dark,
        summary: "Neon on black, high contrast, terminal-forward.",
        roles: [
            .ground: hex("#0A0A0F"),
            .surface: hex("#12121A"),
            .panel: hex("#1C1C2E"),
            .border: hex("#2A2A3A"),
            .label: hex("#E0E0E0"),
            .accent: hex("#00FF88"),
            .statusPositive: hex("#00FF88"),
            .statusWarning: hex("#FFB000"),
            .statusNegative: hex("#FF3366"),
            .syntaxKeyword: hex("#FF00FF"),
            .syntaxType: hex("#00D4FF"),
            .syntaxString: hex("#00FF88"),
            .syntaxNumber: hex("#FFB000")
        ]
    )

    /// International Typographic Style: paper white, black text, one red accent, nothing else.
    /// The opposite failure mode to Cyberpunk — a style that is mostly *restraint*, where the
    /// risk is that a theme adds colour where the style's whole point is that it does not.
    static let swissMinimalist = AppTheme(
        id: AppThemeID("swiss-minimalist"),
        name: "Swiss Minimalist",
        mode: .light,
        summary: "Paper white, black type, a single red accent.",
        roles: [
            .ground: hex("#FFFFFF"),
            .surface: hex("#F4F4F4"),
            .panel: hex("#FFFFFF"),
            .border: hex("#D4D4D4"),
            .label: hex("#111111"),
            .accent: hex("#DC2626"),
            .statusPositive: hex("#15803D"),
            .statusWarning: hex("#B45309"),
            .statusNegative: hex("#DC2626"),
            .syntaxKeyword: hex("#111111"),
            .syntaxType: hex("#525252"),
            .syntaxString: hex("#DC2626"),
            .syntaxNumber: hex("#525252")
        ]
    )

    /// Force-unwrapped deliberately: these are literals in this file, so a bad one is a build
    /// this test suite fails rather than a colour that silently renders white at runtime.
    private static func hex(_ value: String) -> NSColor {
        guard let color = NSColor(hex: value) else {
            preconditionFailure("Malformed stock theme colour: \(value)")
        }
        return color
    }
}
