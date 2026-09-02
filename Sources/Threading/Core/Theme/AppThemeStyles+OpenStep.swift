import AppKit

extension AppThemeStyles {

    /// OPENSTEP 4.2: the NeXT workstation's restrained black title band, square gray
    /// furniture, bookended controls, and the left-hand stippled scroller visible throughout
    /// its applications. The terminal is the period black-on-white shell rather than a modern
    /// dark console dressed in the same accent.
    public static let openStep = AppTheme(
        id: AppThemeID("openstep-42"),
        name: "OPENSTEP 4.2",
        mode: .light,
        summary: "Black NeXT title bands, left stippled scrollers, and square workstation depth.",
        variants: [.light: AppTheme.Variant(
            roles: [
                // OPENSTEP's native four-step neutral palette is literal: application gray
                // is #AAAAAA, shadow is #555555, and the remaining rails are black/white.
                // The previous #BEBEBE approximation made every control visibly washed out
                // beside the preserved Workspace Manager and Display Preferences pixels.
                .ground: hex("#AAAAAA"),
                .surface: hex("#AAAAAA"),
                .panel: hex("#AAAAAA"),
                .elevated: hex("#AAAAAA"),
                // NeXT's floating panels are the workstation gray. Derived from `elevated`
                // the card trended white — and this theme's terminal is the period's
                // black-on-white shell, which is the Platinum white-card-over-white-terminal
                // failure verbatim.
                .floatingSurface: hex("#AAAAAA"),
                .border: hex("#000000"),
                .divider: hex("#555555"),
                .label: hex("#000000"),
                // OPENSTEP's restrained indigo selection colour keeps interaction tellable
                // without competing with the black window band.
                .accent: hex("#45457A"),
                .accentMuted: hex("#45457A").withAlphaComponent(0.18),
                .controlResting: hex("#AAAAAA"),
                .controlHover: hex("#AAAAAA"),
                .selection: hex("#7979A6").withAlphaComponent(0.82),
                .statusPositive: hex("#286B3C"),
                .statusWarning: hex("#765500"),
                .statusNegative: hex("#8E2727"),
                .syntaxKeyword: hex("#353576"),
                .syntaxType: hex("#25636A"),
                .syntaxString: hex("#7A3030"),
                .syntaxNumber: hex("#5D4375"),
                .bevelHighlight: hex("#FFFFFF"),
                .bevelShadow: hex("#555555")
            ],
            terminalPalette: TerminalTheme(
                id: TerminalThemeID("app-openstep-42-terminal"),
                name: "OPENSTEP 4.2",
                foreground: hex("#333333"),
                boldForeground: hex("#101010"),  // The heading keeps the ramp’s black
                background: hex("#FFFFFF"),
                cursor: hex("#333333"),
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
                choiceHeight: 18,
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
                scrollerPlacement: .leading,
                scrollerTrackStyle: .stippled,
                scrollerAppearance: .openStep,
                menuAppearance: .openStep,
                choiceStyle: .popup
            ),
            sidebar: SidebarStyle(
                navigatorWell: .init(fill: hex("#FFFFFF"), bevel: .sunken)
            ),
            chrome: WindowChromeStyle(
                titleBar: .init(
                    activeGradient: .init(stops: [
                        .init(color: hex("#000000"), position: 0),
                        .init(color: hex("#000000"), position: 1)
                    ]),
                    inactiveGradient: .init(stops: [
                        .init(color: hex("#A2A2A2"), position: 0),
                        .init(color: hex("#A2A2A2"), position: 1)
                    ]),
                    ink: hex("#FFFFFF"),
                    inactiveInk: hex("#111111"),
                    titleAlignment: .center,
                    titleFontSize: 12,
                    // The complete native Workspace Manager caption is 23px including its
                    // asymmetric outer rails; 20px clipped both the bottom edge and the
                    // title's one-bit baseline.
                    height: 23,
                    buttonGlyphStyle: .openStep,
                    buttonPlacement: .trailing,
                    showsAppIcon: false,
                    // OPENSTEP panels carry the single close plate at the trailing edge.
                    // Miniaturisation is represented by the app icon in the dock, not a
                    // second title-band box.
                    visibleButtons: [.close]
                ),
                frame: .init(width: 1)
            )
        )]
    )
}
