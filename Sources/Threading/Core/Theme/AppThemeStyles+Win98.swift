import AppKit

extension AppThemeStyles {

    /// Mid-nineties desktop chrome: one silver, bevels doing the work borders do elsewhere,
    /// a navy title band — and the first theme to state a `WindowChromeStyle`, so the app
    /// draws the entire window frame while it is worn.
    ///
    /// The style's whole idea is that surfaces are *lit* rather than outlined: everything is
    /// the same `#C0C0C0`, and raised against sunken is what tells a button from a well
    /// (`Material.bevel`). That is why `controlResting` is deliberately the surface's own
    /// colour — a resting control is distinguished by its edges, which is the brief.
    ///
    /// The id is deliberately not the display name (`AppThemeID`'s whole point): the name can
    /// be reconsidered without resetting anyone's standing choice.
    static let win98 = AppTheme(
        id: AppThemeID("retro-98"),
        name: "Windows 98",
        mode: .light,
        summary: "Silver bevels, a navy title band, the whole frame drawn by the app.",
        variants: [.light: AppTheme.Variant(
            roles: [
                .ground: hex("#C0C0C0"),
                .surface: hex("#C0C0C0"),
                .panel: hex("#C0C0C0"),
                .elevated: hex("#D4D0C8"),
                .border: hex("#808080"),
                .divider: hex("#808080"),
                .label: hex("#000000"),
                .accent: hex("#000080"),
                .accentMuted: hex("#000080").withAlphaComponent(0.16),
                .controlResting: hex("#C0C0C0"),
                .controlHover: hex("#D0D0D0"),
                .selection: hex("#000080").withAlphaComponent(0.9),
                .statusPositive: hex("#008000"),
                .statusWarning: hex("#808000"),
                .statusNegative: hex("#B00000"),
                .syntaxKeyword: hex("#000080"),
                .syntaxType: hex("#008080"),
                .syntaxString: hex("#B00000"),
                .syntaxNumber: hex("#0000FF"),
                // The classic pair: BTNSHADOW gray for the inner shaded ring; the near-black
                // frame line derives from it (`BevelArtwork.edgeColors`).
                .bevelHighlight: hex("#FFFFFF"),
                .bevelShadow: hex("#808080")
            ],
            // The DOS console this chrome shipped beside: VGA's own sixteen, light gray on
            // black. ANSI black is lifted off the true-black background just enough that a
            // black glyph is still a glyph — the Cyberpunk rule.
            terminalPalette: TerminalTheme(
                id: TerminalThemeID("app-retro-98-terminal"),
                name: "Windows 98",
                foreground: hex("#C0C0C0"),
                background: hex("#000000"),
                cursor: hex("#C0C0C0"),
                selection: hex("#000080"),
                black: hex("#2A2A2A"),
                red: hex("#AA0000"),
                green: hex("#00AA00"),
                yellow: hex("#AA5500"),
                blue: hex("#0000AA"),
                magenta: hex("#AA00AA"),
                cyan: hex("#00AAAA"),
                white: hex("#AAAAAA"),
                brightBlack: hex("#555555"),
                brightRed: hex("#FF5555"),
                brightGreen: hex("#55FF55"),
                brightYellow: hex("#FFFF55"),
                brightBlue: hex("#5555FF"),
                brightMagenta: hex("#FF55FF"),
                brightCyan: hex("#55FFFF"),
                brightWhite: hex("#FFFFFF")
            ),
            // Square everything — validation requires it of a bevel material — one-point
            // rules, no halo (light came from the top-left in 1998, not from behind), and
            // Tahoma when the machine has it, degrading to the system face per
            // `Material.fontFamily`'s contract. Nothing is bundled.
            material: AppTheme.Material(
                panelRadius: 0,
                controlRadius: 0,
                borderWidth: 1,
                glow: nil,
                bevel: AppTheme.Bevel(width: 2),
                typeface: .standard,
                fontFamily: "Tahoma"
            ),
            chrome: WindowChromeStyle(
                titleBar: WindowChromeStyle.TitleBar(
                    activeGradient: SidebarStyle.Gradient(stops: [
                        .init(color: hex("#000080"), position: 0),
                        .init(color: hex("#1084D0"), position: 1)
                    ], angleDegrees: 90),
                    // Grayed rather than derived, because the classic inactive band is its
                    // own statement — held to the softer "tellable" floor with white ink,
                    // where the authentic `#D4D0C8` ink would vanish entirely.
                    inactiveGradient: SidebarStyle.Gradient(stops: [
                        .init(color: hex("#808080"), position: 0),
                        .init(color: hex("#A8A8A8"), position: 1)
                    ], angleDegrees: 90),
                    ink: hex("#FFFFFF"),
                    inactiveInk: hex("#FFFFFF"),
                    titleAlignment: .leading,
                    height: 28,
                    buttonGlyphStyle: .squares
                ),
                frame: WindowChromeStyle.Frame(width: 4)
            )
        )]
    )
}
