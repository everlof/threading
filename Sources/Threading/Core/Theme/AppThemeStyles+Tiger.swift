import AppKit

extension AppThemeStyles {

    /// Mac OS X 10.4 Tiger's mature Aqua appearance.
    ///
    /// Tiger is not a rename of Cheetah. Finder moved from the first release's emphatic
    /// pinstripes to a unified brushed-metal frame, kept smaller glass traffic lights, put
    /// both scroll arrows together at the trailing end, and reserved saturated blue for the
    /// thumb, selected rows, and compact pop-up segments. Keeping a separate document lets a
    /// custom theme choose either historical moment without an ID-specific branch in a view.
    static let aquaTiger = AppTheme(
        id: AppThemeID("aqua-tiger"),
        name: "Mac OS X 10.4 Tiger",
        mode: .light,
        summary: "Brushed-metal Aqua, trailing arrow pairs, and slim blue gel controls.",
        variants: [.light: AppTheme.Variant(
            roles: [
                .ground: hex("#E7E7E7"),
                .surface: hex("#ECECEC"),
                .panel: hex("#FFFFFF"),
                .fieldSurface: hex("#FFFFFF"),
                .elevated: hex("#F8F8F8"),
                .floatingSurface: hex("#EEEEEE"),
                .border: hex("#7A7A7A"),
                .divider: hex("#A9A9A9"),
                .label: hex("#111111"),
                .accent: hex("#1686D9"),
                .accentMuted: hex("#1686D9").withAlphaComponent(0.17),
                .controlResting: hex("#ECECEC"),
                .controlHover: hex("#DDEEFF"),
                .selection: hex("#2F8BD5"),
                .statusPositive: hex("#2E8A38"),
                .statusWarning: hex("#9B6800"),
                .statusNegative: hex("#C73B32"),
                .syntaxKeyword: hex("#2447A8"),
                .syntaxType: hex("#006B78"),
                .syntaxString: hex("#8B2D2D"),
                .syntaxNumber: hex("#6240A0"),
                .bevelHighlight: hex("#FFFFFF"),
                .bevelShadow: hex("#8A8A8A")
            ],
            terminalPalette: TerminalTheme(
                id: TerminalThemeID("app-aqua-tiger-terminal"),
                name: "Mac OS X 10.4 Tiger",
                foreground: hex("#111111"),
                background: hex("#FFFFFF"),
                cursor: hex("#111111"),
                selection: hex("#B7D8F2"),
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
                panelRadius: 6,
                controlRadius: 6,
                borderWidth: 1,
                textScale: 0.90,
                choiceHeight: 22,
                buttonStyle: AppTheme.Material.ButtonStyle(
                    fontWeight: .regular,
                    primaryTreatment: .raised,
                    primaryRole: .accent
                ),
                typeface: .standard,
                fontFamily: "Lucida Grande",
                fontFallbacks: ["Helvetica Neue"],
                scrollerAppearance: .aquaTiger,
                menuAppearance: .aquaTiger,
                choiceStyle: .aquaPopup
            ),
            sidebar: SidebarStyle(
                navigatorWell: .init(fill: hex("#FFFFFF"), bevel: .sunken)
            ),
            chrome: WindowChromeStyle(
                titleBar: .init(
                    activeGradient: .init(stops: [
                        .init(color: hex("#FAFAFA"), position: 0),
                        .init(color: hex("#B0B0B0"), position: 0.08),
                        .init(color: hex("#A6A6A6"), position: 1)
                    ], angleDegrees: 180),
                    inactiveGradient: .init(stops: [
                        .init(color: hex("#FAFAFA"), position: 0),
                        .init(color: hex("#C0C0C0"), position: 0.08),
                        .init(color: hex("#B8B8B8"), position: 1)
                    ], angleDegrees: 180),
                    ink: hex("#111111"),
                    inactiveInk: hex("#767676"),
                    titleAlignment: .center,
                    titleFontSize: 13,
                    height: 22,
                    buttonGlyphStyle: .aquaTiger,
                    buttonPlacement: .leading,
                    showsAppIcon: false,
                    activeTexture: .init(
                        kind: .brushedMetal,
                        color: hex("#797979").withAlphaComponent(0.34),
                        spacing: 2
                    ),
                    inactiveTexture: .init(
                        kind: .brushedMetal,
                        color: hex("#A0A0A0").withAlphaComponent(0.28),
                        spacing: 2
                    ),
                    visibleButtons: [.close, .minimize, .zoom]
                ),
                frame: .init(width: 1, cornerRadius: 7)
            )
        )]
    )
}
