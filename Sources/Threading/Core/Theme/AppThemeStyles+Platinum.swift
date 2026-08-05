import AppKit

extension AppThemeStyles {

    /// Mac OS 8/9's Platinum appearance: cool silver surfaces, black type, a restrained blue
    /// selection, and the active window identified by fine horizontal rules interrupted by a
    /// centred title. Close lives on the leading edge; WindowShade and Zoom live opposite it.
    ///
    /// The palette is authored from period screenshots rather than from current macOS system
    /// roles. Charcoal is named because it is the face Platinum used; on machines without it,
    /// the ordinary theme-family fallback deliberately returns to the platform face.
    static let platinum = AppTheme(
        id: AppThemeID("platinum-9"),
        name: "Mac OS 9 Platinum",
        mode: .light,
        summary: "Striped silver title bars, split window boxes, and classic Platinum depth.",
        variants: [.light: AppTheme.Variant(
            roles: [
                .ground: hex("#D6D6D6"),
                .surface: hex("#DDDDDD"),
                .panel: hex("#EEEEEE"),
                .elevated: hex("#FFFFFF"),
                .border: hex("#444444"),
                .divider: hex("#777777"),
                .label: hex("#000000"),
                .accent: hex("#3151B5"),
                .accentMuted: hex("#3151B5").withAlphaComponent(0.16),
                .controlResting: hex("#DDDDDD"),
                .controlHover: hex("#EEEEEE"),
                .selection: hex("#3151B5").withAlphaComponent(0.88),
                .statusPositive: hex("#14733B"),
                .statusWarning: hex("#8A5B00"),
                .statusNegative: hex("#A01818"),
                .syntaxKeyword: hex("#202080"),
                .syntaxType: hex("#005A66"),
                .syntaxString: hex("#8B1A1A"),
                .syntaxNumber: hex("#3151B5"),
                .bevelHighlight: hex("#FFFFFF"),
                .bevelShadow: hex("#777777")
            ],
            terminalPalette: TerminalTheme(
                id: TerminalThemeID("app-platinum-9-terminal"),
                name: "Mac OS 9 Platinum",
                foreground: hex("#111111"),
                background: hex("#FFFFFF"),
                cursor: hex("#111111"),
                selection: hex("#B7C5E8"),
                black: hex("#111111"),
                red: hex("#A01818"),
                green: hex("#14733B"),
                yellow: hex("#8A5B00"),
                blue: hex("#3151B5"),
                magenta: hex("#7B347C"),
                cyan: hex("#006D78"),
                white: hex("#777777"),
                brightBlack: hex("#555555"),
                brightRed: hex("#C83A32"),
                brightGreen: hex("#278C4F"),
                brightYellow: hex("#A87800"),
                brightBlue: hex("#5272D2"),
                brightMagenta: hex("#9B529D"),
                brightCyan: hex("#188994"),
                brightWhite: hex("#AAAAAA")
            ),
            material: AppTheme.Material(
                panelRadius: 0,
                controlRadius: 0,
                borderWidth: 1,
                textScale: 0.82,
                glow: nil,
                popoverStyle: periodPopoverStyle,
                bevel: AppTheme.Bevel(width: 2),
                typeface: .standard,
                fontFamily: "Charcoal",
                // Geneva is the period Mac small-screen face available on current macOS when
                // Charcoal itself is absent.
                fontFallbacks: ["Geneva"]
            ),
            sidebar: SidebarStyle(
                navigatorWell: .init(fill: hex("#FFFFFF"), bevel: .sunken)
            ),
            chrome: WindowChromeStyle(
                titleBar: .init(
                    activeGradient: .init(stops: [
                        .init(color: hex("#DDDDDD"), position: 0),
                        .init(color: hex("#DDDDDD"), position: 1)
                    ]),
                    inactiveGradient: .init(stops: [
                        .init(color: hex("#DDDDDD"), position: 0),
                        .init(color: hex("#DDDDDD"), position: 1)
                    ]),
                    ink: hex("#000000"),
                    inactiveInk: hex("#666666"),
                    titleAlignment: .center,
                    height: 20,
                    buttonGlyphStyle: .platinum,
                    buttonPlacement: .split,
                    showsAppIcon: false,
                    activeTexture: .init(
                        kind: .pinstripes,
                        color: hex("#888888"),
                        spacing: 2
                    )
                ),
                frame: .init(width: 2)
            )
        )]
    )
}
