import AppKit

extension AppThemeStyles {

    /// OPENSTEP 4.2: the NeXT workstation's restrained black title band, square gray
    /// furniture, bookended controls, and the left-hand stippled scroller visible throughout
    /// its applications. The terminal is the period black-on-white shell rather than a modern
    /// dark console dressed in the same accent.
    static let openStep = AppTheme(
        id: AppThemeID("openstep-42"),
        name: "OPENSTEP 4.2",
        mode: .light,
        summary: "Black NeXT title bands, left stippled scrollers, and square workstation depth.",
        variants: [.light: AppTheme.Variant(
            roles: [
                .ground: hex("#BEBEBE"),
                .surface: hex("#BEBEBE"),
                .panel: hex("#D6D6D6"),
                .elevated: hex("#EAEAEA"),
                .border: hex("#111111"),
                .divider: hex("#686868"),
                .label: hex("#111111"),
                // OPENSTEP's restrained indigo selection colour keeps interaction tellable
                // without competing with the black window band.
                .accent: hex("#45457A"),
                .accentMuted: hex("#45457A").withAlphaComponent(0.18),
                .controlResting: hex("#BEBEBE"),
                .controlHover: hex("#D8D8D8"),
                .selection: hex("#7979A6").withAlphaComponent(0.82),
                .statusPositive: hex("#286B3C"),
                .statusWarning: hex("#765500"),
                .statusNegative: hex("#8E2727"),
                .syntaxKeyword: hex("#353576"),
                .syntaxType: hex("#25636A"),
                .syntaxString: hex("#7A3030"),
                .syntaxNumber: hex("#5D4375"),
                .bevelHighlight: hex("#FFFFFF"),
                .bevelShadow: hex("#5F5F5F")
            ],
            terminalPalette: TerminalTheme(
                id: TerminalThemeID("app-openstep-42-terminal"),
                name: "OPENSTEP 4.2",
                foreground: hex("#101010"),
                background: hex("#FFFFFF"),
                cursor: hex("#101010"),
                selection: hex("#B7B7D0"),
                black: hex("#101010"),
                red: hex("#8E2727"),
                green: hex("#286B3C"),
                yellow: hex("#765500"),
                blue: hex("#353576"),
                magenta: hex("#673C69"),
                cyan: hex("#25636A"),
                white: hex("#C8C8C8"),
                brightBlack: hex("#626262"),
                brightRed: hex("#B23B3B"),
                brightGreen: hex("#3D8A52"),
                brightYellow: hex("#987319"),
                brightBlue: hex("#565697"),
                brightMagenta: hex("#885A8A"),
                brightCyan: hex("#43838A"),
                brightWhite: hex("#FFFFFF")
            ),
            material: AppTheme.Material(
                panelRadius: 0,
                controlRadius: 0,
                borderWidth: 1,
                textScale: 0.86,
                glow: nil,
                popoverStyle: periodPopoverStyle,
                bevel: AppTheme.Bevel(width: 2),
                typeface: .standard,
                fontFamily: "Helvetica",
                scrollerPlacement: .leading,
                scrollerTrackStyle: .stippled
            ),
            sidebar: SidebarStyle(
                navigatorWell: .init(fill: hex("#FFFFFF"), bevel: .sunken)
            ),
            chrome: WindowChromeStyle(
                titleBar: .init(
                    activeGradient: .init(stops: [
                        .init(color: hex("#111111"), position: 0),
                        .init(color: hex("#111111"), position: 1)
                    ]),
                    inactiveGradient: .init(stops: [
                        .init(color: hex("#A2A2A2"), position: 0),
                        .init(color: hex("#A2A2A2"), position: 1)
                    ]),
                    ink: hex("#FFFFFF"),
                    inactiveInk: hex("#111111"),
                    titleAlignment: .center,
                    height: 24,
                    buttonGlyphStyle: .openStep,
                    buttonPlacement: .bookends,
                    showsAppIcon: false,
                    visibleButtons: [.minimize, .close]
                ),
                frame: .init(width: 1)
            )
        )]
    )
}
