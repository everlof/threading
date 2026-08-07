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
                // Platinum reserves white for writable and list wells. A transient palette or
                // information card is the gray button face with raised relief; deriving this
                // from `elevated` made the corner card disappear over a white terminal.
                .floatingSurface: hex("#DDDDDD"),
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
                // Apple's own Platinum pop-up specimen is exactly sixteen pixels high.
                choiceHeight: 16,
                glow: nil,
                popoverStyle: periodPopoverStyle,
                buttonStyle: AppTheme.Material.ButtonStyle(
                    fontWeight: .regular,
                    primaryTreatment: .raised,
                    primaryRole: .border
                ),
                bevel: AppTheme.Bevel(width: 2),
                typeface: .standard,
                fontFamily: "Charcoal",
                // Geneva is the period Mac small-screen face available on current macOS when
                // Charcoal itself is absent.
                fontFallbacks: ["Geneva"],
                scrollerAppearance: .platinum,
                menuAppearance: .platinum,
                choiceStyle: .doubleArrowPopup
            ),
            sidebar: SidebarStyle(
                navigatorWell: .init(fill: hex("#FFFFFF"), bevel: .sunken)
            ),
            chrome: WindowChromeStyle(
                titleBar: .init(
                    activeGradient: .init(stops: [
                        .init(color: hex("#CCCCCC"), position: 0),
                        .init(color: hex("#CCCCCC"), position: 1)
                    ]),
                    inactiveGradient: .init(stops: [
                        .init(color: hex("#CCCCCC"), position: 0),
                        .init(color: hex("#CCCCCC"), position: 1)
                    ]),
                    ink: hex("#000000"),
                    inactiveInk: hex("#666666"),
                    titleAlignment: .center,
                    titleFontSize: 12,
                    height: 17,
                    buttonGlyphStyle: .platinum,
                    buttonPlacement: .split,
                    showsAppIcon: false,
                    activeTexture: .init(
                        kind: .pinstripes,
                        color: hex("#777777"),
                        spacing: 2
                    ),
                    visibleButtons: [.close, .zoom]
                ),
                frame: .init(width: 2)
            )
        )]
    )

    /// Mac OS X 10.0 Cheetah's first public Aqua appearance. This is deliberately a separate
    /// chrome from classic Platinum: Lucida Grande, a pale pinstriped title band, leading
    /// traffic-light gems, rounded translucent controls, and the saturated ribbed blue
    /// scrollbar that made the original interface look like coloured glass.
    static let aqua = AppTheme(
        id: AppThemeID("aqua-cheetah"),
        name: "Mac OS X Aqua",
        mode: .light,
        summary: "Cheetah pinstripes, glass traffic lights, and glossy blue Aqua scrollbars.",
        variants: [.light: AppTheme.Variant(
            roles: [
                .ground: hex("#E9E9E9"),
                .surface: hex("#F1F1F1"),
                .panel: hex("#FFFFFF"),
                .fieldSurface: hex("#FFFFFF"),
                .elevated: hex("#FAFAFA"),
                .floatingSurface: hex("#EEEEEE"),
                .border: hex("#777777"),
                .divider: hex("#B4B4B4"),
                .label: hex("#111111"),
                .accent: hex("#0878D5"),
                .accentMuted: hex("#0878D5").withAlphaComponent(0.18),
                .controlResting: hex("#E5E5E5"),
                .controlHover: hex("#DCEEFF"),
                .selection: hex("#3B79D6").withAlphaComponent(0.86),
                .statusPositive: hex("#268A2F"),
                .statusWarning: hex("#9A6400"),
                .statusNegative: hex("#C5352E"),
                .syntaxKeyword: hex("#2447A8"),
                .syntaxType: hex("#006B78"),
                .syntaxString: hex("#8B2D2D"),
                .syntaxNumber: hex("#6B3BA7"),
                .bevelHighlight: hex("#FFFFFF"),
                .bevelShadow: hex("#8A8A8A")
            ],
            terminalPalette: TerminalTheme(
                id: TerminalThemeID("app-aqua-cheetah-terminal"),
                name: "Mac OS X Aqua",
                foreground: hex("#111111"),
                background: hex("#FFFFFF"),
                cursor: hex("#111111"),
                selection: hex("#B8D8F4"),
                black: hex("#111111"),
                red: hex("#B73732"),
                green: hex("#287B35"),
                yellow: hex("#8D6500"),
                blue: hex("#145EA8"),
                magenta: hex("#76509B"),
                cyan: hex("#157786"),
                white: hex("#BDBDBD"),
                brightBlack: hex("#555555"),
                brightRed: hex("#D75850"),
                brightGreen: hex("#3F9B4E"),
                brightYellow: hex("#AE820A"),
                brightBlue: hex("#2B7CC6"),
                brightMagenta: hex("#946DB8"),
                brightCyan: hex("#3094A1"),
                brightWhite: hex("#E6E6E6")
            ),
            material: AppTheme.Material(
                panelRadius: 8,
                controlRadius: 7,
                borderWidth: 1,
                textScale: 0.92,
                choiceHeight: 22,
                buttonStyle: AppTheme.Material.ButtonStyle(
                    fontWeight: .regular,
                    primaryTreatment: .raised,
                    primaryRole: .accent
                ),
                typeface: .standard,
                fontFamily: "Lucida Grande",
                fontFallbacks: ["Helvetica Neue"],
                scrollerAppearance: .aqua,
                menuAppearance: .aqua,
                choiceStyle: .popup
            ),
            sidebar: SidebarStyle(
                navigatorWell: .init(fill: hex("#FFFFFF"), bevel: .sunken)
            ),
            chrome: WindowChromeStyle(
                titleBar: .init(
                    activeGradient: .init(stops: [
                        .init(color: hex("#F6F6F6"), position: 0),
                        .init(color: hex("#DEDEDE"), position: 1)
                    ], angleDegrees: 180),
                    inactiveGradient: .init(stops: [
                        .init(color: hex("#F5F5F5"), position: 0),
                        .init(color: hex("#E3E3E3"), position: 1)
                    ], angleDegrees: 180),
                    ink: hex("#111111"),
                    inactiveInk: hex("#777777"),
                    titleAlignment: .center,
                    titleFontSize: 13,
                    height: 22,
                    buttonGlyphStyle: .aqua,
                    buttonPlacement: .leading,
                    showsAppIcon: false,
                    activeTexture: .init(
                        kind: .aquaPinstripes,
                        color: hex("#000000").withAlphaComponent(0.03),
                        spacing: 4
                    ),
                    inactiveTexture: .init(
                        kind: .aquaPinstripes,
                        color: hex("#000000").withAlphaComponent(0.02),
                        spacing: 4
                    ),
                    visibleButtons: [.close, .minimize, .zoom]
                ),
                frame: .init(width: 1, cornerRadius: 6)
            )
        )]
    )
}
