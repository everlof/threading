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
                .fieldSurface: hex("#FFFFFF"),
                .elevated: hex("#D4D0C8"),
                .floatingSurface: hex("#FFFFE1"),
                .border: hex("#808080"),
                .divider: hex("#808080"),
                .label: hex("#000000"),
                .accent: hex("#000080"),
                .accentMuted: hex("#000080").withAlphaComponent(0.16),
                .controlResting: hex("#C0C0C0"),
                // Win32 pushbuttons did not recolour on pointer hover; state lived in focus and
                // the pressed bevel. Keeping the same face also prevents classic dropdowns from
                // acquiring a modern rollover wash.
                .controlHover: hex("#C0C0C0"),
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
            // Windows 98's English shell used 8-point MS Sans Serif. The original bitmap face is
            // rarely installed on a current Mac; Microsoft Sans Serif is its metric-compatible
            // TrueType successor, then Tahoma is the last Windows-era substitute. Nothing is
            // bundled — installing the original automatically moves it to the front.
            material: AppTheme.Material(
                panelRadius: 0,
                controlRadius: 0,
                borderWidth: 1,
                // Win98 shell UI was set around eight points. Scaling semantic roles keeps
                // that density throughout the chrome instead of shrinking one title label.
                textScale: 0.72,
                glow: nil,
                popoverStyle: windowsInfotipStyle,
                buttonStyle: AppTheme.Material.ButtonStyle(
                    fontWeight: .regular,
                    primaryTreatment: .raised,
                    primaryRole: .label,
                    pressedOffsetX: 1,
                    pressedOffsetY: 1
                ),
                bevel: AppTheme.Bevel(width: 2),
                typeface: .standard,
                fontFamily: "MS Sans Serif",
                fontFallbacks: ["Microsoft Sans Serif", "Tahoma"],
                progressStyle: .segmented,
                choiceStyle: .dropdown
            ),
            sidebar: SidebarStyle(
                // Explorer separates its white work area from the surrounding button-face
                // chrome with a sunken 3D edge. Keeping this regional prevents ordinary
                // panels from becoming white merely to make the tree authentic.
                navigatorWell: .init(fill: hex("#FFFFFF"), bevel: .sunken)
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
                    // Default classic non-client metrics: an 18px caption band holding
                    // 16×14 caption buttons. Keeping the actual relationship matters as much
                    // as the colours — the former 20/18×16 pair looked inflated beside Win98.
                    height: 18,
                    buttonGlyphStyle: .squares
                ),
                frame: WindowChromeStyle.Frame(width: 3)
            )
        )]
    )
}
