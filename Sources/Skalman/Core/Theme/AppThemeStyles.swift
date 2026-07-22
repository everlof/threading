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

    /// High-contrast neon on near-black.
    ///
    /// States its own `controlResting`/`controlHover` rather than letting them derive from the
    /// label: the derivation is `label` at 8%, which is a grey, and a grey control on a neon
    /// theme is how the first pass ended up looking like the same app in a different tint.
    /// Here they are the accent, held far down — so every hoverable thing glows faintly green
    /// instead of going pale.
    static let cyberpunk = AppTheme(
        id: AppThemeID("cyberpunk"),
        name: "Cyberpunk",
        mode: .dark,
        summary: "Neon on black, high contrast, terminal-forward.",
        roles: [
            .ground: hex("#07070B"),
            .surface: hex("#0D0D14"),
            .panel: hex("#14142A"),
            .elevated: hex("#1B1B36"),
            .border: hex("#2E2E5A"),
            .divider: hex("#1F1F3A"),
            .label: hex("#E6FFF4"),
            .accent: hex("#00FF88"),
            .accentMuted: hex("#00FF88").withAlphaComponent(0.18),
            .controlResting: hex("#00FF88").withAlphaComponent(0.10),
            .controlHover: hex("#00FF88").withAlphaComponent(0.20),
            .selection: hex("#00FF88").withAlphaComponent(0.30),
            .statusPositive: hex("#00FF88"),
            .statusWarning: hex("#FFB000"),
            .statusNegative: hex("#FF3366"),
            .syntaxKeyword: hex("#FF00FF"),
            .syntaxType: hex("#00D4FF"),
            .syntaxString: hex("#00FF88"),
            .syntaxNumber: hex("#FFB000")
        ],
        // Tight corners and a neon halo behind every panel — the one thing that makes this read
        // as Cyberpunk rather than as "a dark theme".
        material: AppTheme.Material(
            panelRadius: 3,
            controlRadius: 2,
            borderWidth: 1,
            glow: AppTheme.Glow(role: .accent, radius: 10, opacity: 0.28)
        )
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
            .surface: hex("#FFFFFF"),
            .panel: hex("#FAFAFA"),
            .elevated: hex("#FFFFFF"),
            // A rule you can actually see. The style is built from black lines on white, so a
            // pale system-grey hairline is the one thing it cannot have.
            .border: hex("#111111"),
            .divider: hex("#111111").withAlphaComponent(0.18),
            .label: hex("#111111"),
            .accent: hex("#D6180B"),
            .accentMuted: hex("#D6180B").withAlphaComponent(0.14),
            .controlResting: hex("#111111").withAlphaComponent(0.05),
            .controlHover: hex("#111111").withAlphaComponent(0.10),
            .selection: hex("#D6180B").withAlphaComponent(0.22),
            .statusPositive: hex("#0F7A34"),
            .statusWarning: hex("#B45309"),
            .statusNegative: hex("#D6180B"),
            // Type over colour: the International Style sets information in weight and
            // position, not in six hues, so code is black with one red for strings.
            .syntaxKeyword: hex("#111111"),
            .syntaxType: hex("#4A4A4A"),
            .syntaxString: hex("#D6180B"),
            .syntaxNumber: hex("#4A4A4A")
        ],
        // Square. The grid is the whole idea, and a 12pt radius rounds it away.
        material: AppTheme.Material(panelRadius: 0, controlRadius: 0, borderWidth: 1, glow: nil)
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
