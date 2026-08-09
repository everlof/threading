import AppKit

extension AppThemeStyles {

    /// Clean-room player chrome for the classic `.wsz` importer.
    ///
    /// The stock form borrows the format's measured 14-point geometry and broad material idiom
    /// but no Winamp artwork, logo, or palette asset. A user-imported skin replaces the
    /// title-band pixels while all window actions remain Threading's own semantic controls.
    static let classicPlayer = AppTheme(
        id: AppThemeID("classic-player"),
        name: "Classic Player",
        mode: .dark,
        summary: "Compact media-player chrome with local classic .wsz skin support.",
        variants: [.dark: AppTheme.Variant(
            roles: [
                .ground: hex("#171622"),
                .surface: hex("#29283A"),
                .panel: hex("#353348"),
                .fieldSurface: hex("#070909"),
                .elevated: hex("#414055"),
                .border: hex("#101119"),
                .divider: hex("#6E6D7D"),
                .label: hex("#E8E9DE"),
                .accent: hex("#39EF51"),
                .accentMuted: hex("#39EF51").withAlphaComponent(0.18),
                .controlResting: hex("#515465"),
                .controlHover: hex("#686C7B"),
                .selection: hex("#264B2C"),
                .statusPositive: hex("#42E763"),
                .statusWarning: hex("#E6B85C"),
                .statusNegative: hex("#E16F73"),
                .syntaxKeyword: hex("#D59BE8"),
                .syntaxType: hex("#74C8D5"),
                .syntaxString: hex("#A8D174"),
                .syntaxNumber: hex("#E6B85C"),
                .bevelHighlight: hex("#9A9CAB"),
                .bevelShadow: hex("#08090E")
            ],
            terminalPalette: TerminalTheme(
                id: TerminalThemeID("app-classic-player-terminal"),
                name: "Classic Player",
                foreground: hex("#54F269"),
                background: hex("#070909"),
                cursor: hex("#54F269"),
                selection: hex("#234329"),
                black: hex("#29283A"),
                red: hex("#D95C62"),
                green: hex("#42D961"),
                yellow: hex("#D9AD50"),
                blue: hex("#6594D8"),
                magenta: hex("#C080D3"),
                cyan: hex("#61B6C3"),
                white: hex("#C8CAD0"),
                brightBlack: hex("#777786"),
                brightRed: hex("#F17B80"),
                brightGreen: hex("#72F18A"),
                brightYellow: hex("#F0CD72"),
                brightBlue: hex("#83B0F0"),
                brightMagenta: hex("#D9A0E8"),
                brightCyan: hex("#83D2DC"),
                brightWhite: hex("#F1F1E5")
            ),
            material: AppTheme.Material(
                panelRadius: 0,
                controlRadius: 0,
                borderWidth: 1,
                textScale: 0.90,
                choiceHeight: 20,
                glow: nil,
                popoverStyle: periodPopoverStyle,
                buttonStyle: .init(
                    textTransform: .uppercase,
                    titleRendering: .pixel5x6,
                    fontWeight: .regular,
                    fontScale: 0.92,
                    minimumHeight: 20,
                    embossesDisabledTitle: true,
                    primaryTreatment: .raised
                ),
                bevel: .init(width: 2),
                typeface: .monospaced,
                scrollerTrackStyle: .stippled,
                progressStyle: .segmented,
                chartStyle: .spectrum,
                choiceStyle: .dropdown,
                toggleStyle: .onOffButton
            ),
            sidebar: SidebarStyle(
                navigatorWell: .init(fill: hex("#070909"), bevel: .sunken)
            ),
            chrome: WindowChromeStyle(
                titleBar: .init(
                    activeGradient: .init(stops: [
                        .init(color: hex("#171622"), position: 0),
                        .init(color: hex("#3B3950"), position: 1)
                    ], angleDegrees: 90),
                    inactiveGradient: .init(stops: [
                        .init(color: hex("#30303B"), position: 0),
                        .init(color: hex("#4B4A58"), position: 1)
                    ], angleDegrees: 90),
                    ink: hex("#E8E9E2"),
                    inactiveInk: hex("#B2B3AE"),
                    titleAlignment: .center,
                    titleFontSize: 8,
                    height: 14,
                    buttonGlyphStyle: .classicPlayer,
                    buttonPlacement: .bookends,
                    showsAppIcon: false,
                    activeTexture: .init(
                        kind: .captionRails,
                        color: hex("#E4DEA0")
                    ),
                    inactiveTexture: .init(
                        kind: .captionRails,
                        color: hex("#929286")
                    ),
                    visibleButtons: [.windowMenu, .minimize, .zoom, .close]
                ),
                frame: .init(width: 2)
            )
        )]
    )
}
