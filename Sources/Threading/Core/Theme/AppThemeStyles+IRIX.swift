import AppKit

extension AppThemeStyles {

    /// SGI IRIX 6.5's Indigo Magic desktop: a stippled olive 4Dwm title band, black-outlined
    /// caption hardware, neutral Helvetica application furniture, and the cool blue-green work
    /// areas visible in the system tools and File Manager. This follows the default Interactive
    /// Desktop scheme rather than later purple fan themes often mistaken for stock IRIX.
    static let irix = AppTheme(
        id: AppThemeID("irix-indigo-magic"),
        name: "IRIX Indigo Magic",
        mode: .light,
        summary: "Stippled 4Dwm chrome, italic captions, and SGI blue-green work areas.",
        variants: [.light: AppTheme.Variant(
            roles: [
                .ground: hex("#BDBDBD"),
                .surface: hex("#BDBDBD"),
                .panel: hex("#C8C8C8"),
                .elevated: hex("#DEDEDE"),
                // 4Dwm's transient panels wear the same neutral gray as its frames; the
                // stemless period card takes the face gray rather than `elevated`'s pale
                // paper — the Platinum `floatingSurface` rule, applied across the family.
                .floatingSurface: hex("#BDBDBD"),
                .border: hex("#181818"),
                .divider: hex("#686868"),
                .label: hex("#101010"),
                // Desktop blue remains an interaction colour; the olive title band is frame
                // identity and therefore lives in the chrome block rather than the role set.
                .accent: hex("#4E78A3"),
                .accentMuted: hex("#4E78A3").withAlphaComponent(0.20),
                .controlResting: hex("#BDBDBD"),
                .controlHover: hex("#D5D5D5"),
                .selection: hex("#8C799F").withAlphaComponent(0.82),
                .statusPositive: hex("#137A45"),
                .statusWarning: hex("#8A6500"),
                .statusNegative: hex("#9B2929"),
                .syntaxKeyword: hex("#3D4F98"),
                .syntaxType: hex("#276F72"),
                .syntaxString: hex("#8F3948"),
                .syntaxNumber: hex("#76528C"),
                .bevelHighlight: hex("#F3F3E8"),
                .bevelShadow: hex("#555555")
            ],
            terminalPalette: TerminalTheme(
                id: TerminalThemeID("app-irix-indigo-magic-terminal"),
                name: "IRIX Indigo Magic",
                foreground: hex("#E8E8E8"),
                background: hex("#101010"),
                cursor: hex("#E8E8E8"),
                selection: hex("#4E6078"),
                black: hex("#101010"),
                red: hex("#B84A4A"),
                green: hex("#3F9A63"),
                yellow: hex("#B18B31"),
                blue: hex("#547CB2"),
                magenta: hex("#9267A3"),
                cyan: hex("#4A9898"),
                white: hex("#BDBDBD"),
                brightBlack: hex("#606060"),
                brightRed: hex("#E06A6A"),
                brightGreen: hex("#65BF83"),
                brightYellow: hex("#D4B357"),
                brightBlue: hex("#7AA1D1"),
                brightMagenta: hex("#B68AC4"),
                brightCyan: hex("#72BBBB"),
                brightWhite: hex("#FFFFFF")
            ),
            material: AppTheme.Material(
                panelRadius: 0,
                controlRadius: 0,
                borderWidth: 1,
                textScale: 0.84,
                choiceHeight: 20,
                glow: nil,
                popoverStyle: periodPopoverStyle,
                buttonStyle: AppTheme.Material.ButtonStyle(
                    fontWeight: .regular,
                    primaryTreatment: .raised,
                    primaryRole: .border
                ),
                bevel: AppTheme.Bevel(width: 2),
                typeface: .standard,
                fontFamily: "Helvetica",
                scrollerAppearance: .irix,
                menuAppearance: .irix,
                choiceStyle: .popup
            ),
            sidebar: SidebarStyle(
                // SGI applications use this cool work-area colour inside otherwise neutral
                // gray frames; the navigator well is the project tree's equivalent region.
                navigatorWell: .init(fill: hex("#82A8A5"), bevel: .sunken)
            ),
            chrome: WindowChromeStyle(
                titleBar: .init(
                    activeGradient: .init(stops: [
                        .init(color: hex("#A8A789"), position: 0),
                        .init(color: hex("#9E9D80"), position: 1)
                    ], angleDegrees: 180),
                    inactiveGradient: .init(stops: [
                        .init(color: hex("#B8B8B8"), position: 0),
                        .init(color: hex("#AAAAAA"), position: 1)
                    ]),
                    ink: hex("#101010"),
                    inactiveInk: hex("#303030"),
                    titleAlignment: .leading,
                    titleFontStyle: .italic,
                    titleFontSize: 13,
                    // Showcase's complete 4Dwm key-title construction is 32 native pixels:
                    // seven rows of outer stepped frame above a 25px title/control band.
                    height: 32,
                    buttonGlyphStyle: .irix,
                    buttonPlacement: .bookends,
                    showsAppIcon: false,
                    activeTexture: .init(
                        kind: .dither,
                        color: hex("#D5D4B4"),
                        spacing: 2
                    ),
                    inactiveTexture: .init(
                        kind: .dither,
                        color: hex("#D2D2D2"),
                        spacing: 2
                    ),
                    visibleButtons: [.windowMenu, .minimize, .zoom]
                ),
                // 4Dwm's resize frame is a substantial stepped rail. At two points it read as
                // the same generic hairline construction as the other retro families.
                frame: .init(width: 4)
            )
        )]
    )
}
