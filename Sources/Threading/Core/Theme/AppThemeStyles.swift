import AppKit

/// The stock styles the app ships.
///
/// Named after public design movements and broad visual genres. The palettes here are our own
/// values, authored against those aesthetics; nothing is copied from a style guide or site.
///
/// **What a style can and cannot carry here.** A design style is roughly four layers: palette,
/// material, type, and layout with motion. Threading's layout *is* the product, so no theme moves
/// the sidebar. Themes do own shape, rules, and a directed panel shadow: enough for hard-print,
/// soft-clay, neon, and restrained editorial materials without turning a theme into a second
/// view hierarchy.
///
/// Each states only the roles in `AppThemeRole.authored`; the rest are derived, so a theme is a
/// dozen decisions rather than twenty-five.
enum AppThemeStyles {

    static let all: [AppTheme] = [
        editorial,
        cyberpunk,
        swissMinimalist,
        bauhaus,
        artDeco,
        neoBrutalism,
        claymorphism,
        vaporwave,
        newsprint,
        botanical,
        industrial,
        platinum,
        beOS,
        openStep,
        irix,
        win98,
        christmas
    ]

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
        // The terminal half of the style, written out rather than derived — see
        // `AppTheme.terminalPalette`. Built from the same neon the chrome states: the syntax
        // hues become magenta/cyan/green/yellow, `statusNegative` becomes red, and `black` is
        // the panel colour rather than true black so an ANSI-black glyph is still a glyph.
        terminalPalette: TerminalTheme(
            id: TerminalThemeID("app-cyberpunk-terminal"),
            name: "Cyberpunk",
            foreground: hex("#E6FFF4"),
            background: hex("#07070B"),
            cursor: hex("#E6FFF4"),
            selection: hex("#103D2C"),
            black: hex("#14142A"),
            red: hex("#FF3366"),
            green: hex("#00FF88"),
            yellow: hex("#FFB000"),
            blue: hex("#2E8BFF"),
            magenta: hex("#FF00FF"),
            cyan: hex("#00D4FF"),
            white: hex("#B9C6C0"),
            brightBlack: hex("#2E2E5A"),
            brightRed: hex("#FF6B93"),
            brightGreen: hex("#7CFFC4"),
            brightYellow: hex("#FFD166"),
            brightBlue: hex("#7AB4FF"),
            brightMagenta: hex("#FF7AFF"),
            brightCyan: hex("#7CE9FF"),
            brightWhite: hex("#E6FFF4")
        ),
        // Tight corners, a neon halo behind every panel, and mono type — the brief's own
        // trio; without the mono this read as "a dark theme", not as Cyberpunk.
        material: AppTheme.Material(
            panelRadius: 3,
            controlRadius: 2,
            borderWidth: 1,
            glow: AppTheme.Glow(role: .accent, radius: 10, opacity: 0.28),
            typeface: .monospaced
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
        // Paper, black type, one red. The ANSI colours are held *down* — a Swiss terminal that
        // lit up in eight bright hues would contradict the style it is named after — so they are
        // muted enough to sit on white and still be told apart, with red left at full strength
        // because red is the accent this style actually has.
        //
        // The greys break with convention on purpose. A light theme normally leaves `white` and
        // `brightWhite` near-white, because in a light palette those indices are meant as
        // *backgrounds* — but a CLI that dims its status line to index 7 then writes pale grey on
        // paper, which is what the first version of this did and it was unreadable. So the four
        // neutrals are a monotone ramp dark enough to read on white and still ordered
        // black → brightBlack → white → brightWhite, so nothing that picks one of them vanishes.
        terminalPalette: TerminalTheme(
            id: TerminalThemeID("app-swiss-minimalist-terminal"),
            name: "Swiss Minimalist",
            foreground: hex("#111111"),
            background: hex("#FFFFFF"),
            cursor: hex("#111111"),
            selection: hex("#FAD5D1"),
            black: hex("#111111"),
            red: hex("#D6180B"),
            green: hex("#2E6B4F"),
            yellow: hex("#A67C00"),
            blue: hex("#24408E"),
            magenta: hex("#8B2E6B"),
            cyan: hex("#1F6B75"),
            white: hex("#767676"),
            brightBlack: hex("#5A5A5A"),
            brightRed: hex("#FF3B2E"),
            brightGreen: hex("#3F8F6B"),
            brightYellow: hex("#C99A1E"),
            brightBlue: hex("#3557B8"),
            brightMagenta: hex("#B04A8C"),
            brightCyan: hex("#2E8C99"),
            brightWhite: hex("#A8A8A8")
        ),
        material: AppTheme.Material(panelRadius: 0, controlRadius: 0, borderWidth: 1, glow: nil)
    )

    /// Force-unwrapped deliberately: these are literals in this file, so a bad one is a build
    /// this test suite fails rather than a colour that silently renders white at runtime.
    static func hex(_ value: String) -> NSColor {
        guard let color = NSColor(hex: value) else {
            preconditionFailure("Malformed stock theme colour: \(value)")
        }
        return color
    }
}
