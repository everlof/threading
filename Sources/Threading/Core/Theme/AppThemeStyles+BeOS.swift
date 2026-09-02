import AppKit

extension AppThemeStyles {

    /// BeOS R5: warm-gray application furniture, hard two-pixel lighting, and the unmistakable
    /// yellow title tab attached to (rather than stretched across) each window. The shell palette
    /// follows the black Terminal window shipped on the BeOS desktop.
    public static let beOS = AppTheme(
        id: AppThemeID("beos-r5"),
        name: "BeOS R5",
        mode: .light,
        summary: "Yellow title tabs, compact window boxes, and crisp BeOS depth.",
        variants: [.light: AppTheme.Variant(
            roles: [
                .ground: hex("#D8D8D8"),
                .surface: hex("#D8D8D8"),
                .panel: hex("#E2E2E2"),
                // R5 checkboxes and editable/value wells are white inside their nested dark
                // seating. Haiku's pinned BeControlLook calls this `lightenMax` from the panel.
                .fieldSurface: hex("#FFFFFF"),
                .elevated: hex("#FFFFFF"),
                // The floating card is the period's warm application gray, not paper.
                // Deriving it from `elevated` made it white — invisible over the theme's
                // own white wells, the exact failure Platinum documents on its
                // `floatingSurface`; the fix had reached only half the period family.
                .floatingSurface: hex("#D8D8D8"),
                .border: hex("#303030"),
                .divider: hex("#888888"),
                .label: hex("#101010"),
                // BeOS uses yellow as title furniture; interactive selection is its cooler
                // desktop blue so controls remain distinct from the warm window tab.
                .accent: hex("#005A9C"),
                .accentMuted: hex("#005A9C").withAlphaComponent(0.18),
                .controlResting: hex("#D8D8D8"),
                .controlHover: hex("#ECECEC"),
                .selection: hex("#F2CD35").withAlphaComponent(0.88),
                .statusPositive: hex("#1D7042"),
                .statusWarning: hex("#8A5B00"),
                .statusNegative: hex("#A32121"),
                .syntaxKeyword: hex("#203B94"),
                .syntaxType: hex("#006E74"),
                .syntaxString: hex("#8B2828"),
                .syntaxNumber: hex("#72528E"),
                .bevelHighlight: hex("#FFFFFF"),
                .bevelShadow: hex("#747474")
            ],
            terminalPalette: TerminalTheme(
                id: TerminalThemeID("app-beos-r5-terminal"),
                name: "BeOS R5",
                foreground: hex("#C8C8C8"),
                boldForeground: hex("#FFFFFF"),  // Body steps to the ramp’s own white
                background: hex("#101010"),
                cursor: hex("#C8C8C8"),
                selection: hex("#5E531F"),
                black: hex("#101010"),
                red: hex("#C83B32"),
                green: hex("#42A05C"),
                yellow: hex("#D2A900"),
                blue: hex("#496EC4"),
                magenta: hex("#A95DA4"),
                cyan: hex("#38A0A4"),
                white: hex("#C8C8C8"),
                brightBlack: hex("#686868"),
                brightRed: hex("#F05A50"),
                brightGreen: hex("#62C17C"),
                brightYellow: hex("#F2CD35"),
                brightBlue: hex("#7395E4"),
                brightMagenta: hex("#CB80C5"),
                brightCyan: hex("#61C3C6"),
                brightWhite: hex("#FFFFFF")
            ),
            material: AppTheme.Material(
                panelRadius: 0,
                controlRadius: 0,
                borderWidth: 1,
                textScale: 0.84,
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
                // BeOS exposed this family as Swis721 BT. Keep the common expanded spelling in
                // the chain for third-party ports, then fall to its closest installed relative.
                fontFamily: "Swis721 BT",
                fontFallbacks: ["Swiss 721", "Helvetica"],
                scrollerAppearance: .beOS,
                menuAppearance: .beOS,
                choiceStyle: .popup,
                checkboxStyle: .beOSCross
            ),
            sidebar: SidebarStyle(
                navigatorWell: .init(fill: hex("#FFFFFF"), bevel: .sunken)
            ),
            chrome: WindowChromeStyle(
                titleBar: .init(
                    activeGradient: .init(
                        stops: [
                            .init(color: hex("#FFCB00"), position: 0),
                            .init(color: hex("#FFCB00"), position: 1)
                        ],
                        angleDegrees: 180
                    ),
                    inactiveGradient: .init(stops: [
                        .init(color: hex("#D6D6D6"), position: 0),
                        .init(color: hex("#AAAAAA"), position: 1)
                    ]),
                    ink: hex("#101010"),
                    inactiveInk: hex("#4B4B4B"),
                    titleAlignment: .center,
                    titleFontSize: 12,
                    // R5 tabs sit only a few pixels above their 16px caption boxes. The former
                    // 28pt tab read like a modern toolbar when placed beside a period capture.
                    height: 19,
                    buttonGlyphStyle: .beOS,
                    buttonPlacement: .split,
                    showsAppIcon: false,
                    shape: .leadingTab,
                    // BeOS sized tabs to their short title and two boxes. The main-window title
                    // fits the period minimum; 210pt left an implausible yellow shelf beside it.
                    tabWidth: 120,
                    visibleButtons: [.close, .zoom]
                ),
                frame: .init(width: 2)
            )
        )]
    )
}
