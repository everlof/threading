import AppKit

extension AppThemeStyles {

    /// Commodore's stock Workbench 3.1/Intuition presentation: the original four-colour
    /// desktop vocabulary (#AAAAAA, #FFFFFF, #000000, #6688BB), hard one-bit edges, a
    /// monospaced system face, and the active window's blue title strip. This deliberately
    /// avoids MagicWB and later AmigaOS themes, whose extra colours are often mislabelled as
    /// the 3.1 default.
    static let amiga = AppTheme(
        id: AppThemeID("amiga-workbench-31"),
        name: "Amiga Workbench 3.1",
        mode: .light,
        summary: "Blue Intuition title strips, one-bit gadgets, and Workbench gray.",
        variants: [.light: AppTheme.Variant(
            roles: [
                .ground: hex("#AAAAAA"),
                .surface: hex("#AAAAAA"),
                // Workbench windows and requesters share the application gray; a lighter
                // panel would invent a fifth palette colour absent from the source capture.
                .panel: hex("#AAAAAA"),
                // Intuition string and check gadgets keep the same stock gray inside their
                // recessed rules.
                .fieldSurface: hex("#AAAAAA"),
                .elevated: hex("#FFFFFF"),
                // A Workbench requester is gray under black rules — one of the four stock
                // colours — never a white modern card. Derived from `elevated` the floating
                // surface broke the four-colour vocabulary this theme exists to keep.
                .floatingSurface: hex("#AAAAAA"),
                .border: hex("#000000"),
                .divider: hex("#000000"),
                .label: hex("#000000"),
                // The frame keeps Workbench's exact #6688BB. Interactive accents are a
                // darker relative so they still clear the theme contract on gray surfaces.
                .accent: hex("#31577F"),
                .accentMuted: hex("#6688BB").withAlphaComponent(0.28),
                .controlResting: hex("#AAAAAA"),
                .controlHover: hex("#C7C7C7"),
                .selection: hex("#6688BB").withAlphaComponent(0.86),
                .statusPositive: hex("#176A36"),
                .statusWarning: hex("#795B00"),
                .statusNegative: hex("#8A2020"),
                .syntaxKeyword: hex("#1E4772"),
                .syntaxType: hex("#4B3476"),
                .syntaxString: hex("#6E381E"),
                .syntaxNumber: hex("#31577F"),
                .bevelHighlight: hex("#FFFFFF"),
                .bevelShadow: hex("#000000")
            ],
            terminalPalette: TerminalTheme(
                id: TerminalThemeID("app-amiga-workbench-31-terminal"),
                name: "Amiga Workbench 3.1",
                foreground: hex("#000000"),
                // The Intuition title blue at ink depth. Workbench’s four colours leave no
                // other choice: white cannot be read on the gray, black is the body, and the
                // theme’s own #31577F is this palette’s `blue`.
                boldForeground: hex("#102A50"),
                background: hex("#AAAAAA"),
                cursor: hex("#000000"),
                selection: hex("#6688BB"),
                black: hex("#000000"),
                red: hex("#8A2020"),
                green: hex("#176A36"),
                yellow: hex("#795B00"),
                blue: hex("#31577F"),
                magenta: hex("#5D3C78"),
                cyan: hex("#27666A"),
                white: hex("#AAAAAA"),
                brightBlack: hex("#3A3A3A"),
                brightRed: hex("#B63B3B"),
                brightGreen: hex("#2C8B4E"),
                brightYellow: hex("#A27E18"),
                brightBlue: hex("#6688BB"),
                brightMagenta: hex("#805C9A"),
                brightCyan: hex("#4A888C"),
                brightWhite: hex("#FFFFFF")
            ),
            material: AppTheme.Material(
                panelRadius: 0,
                controlRadius: 0,
                borderWidth: 1,
                textScale: 0.92,
                choiceHeight: 18,
                glow: nil,
                popoverStyle: periodPopoverStyle,
                buttonStyle: AppTheme.Material.ButtonStyle(
                    fontWeight: .regular,
                    // Workbench's Topaz control labels are a one-bit bitmap strike. The open
                    // fallback must keep the same hard raster contract when it substitutes.
                    antialiasesTitle: false,
                    primaryTreatment: .raised,
                    primaryRole: .border
                ),
                bevel: AppTheme.Bevel(width: 2),
                typeface: .monospaced,
                // Workbench 3.1's ROM face is Topaz 8. The bundled GPL-FE recreation names its
                // 2.x face `Topaz a600a1200a400` in the font's actual CoreText name table (the
                // upstream prose says A4000, but resolving that spelling silently falls through).
                // Keep common installed-port spellings behind it, then Monaco as the safe last
                // resort for characters the historical face cannot supply.
                fontFamily: "Topaz",
                fontFallbacks: [
                    "Topaz a600a1200a400",
                    "Topaz a600a1200a4000",
                    "TopazPlus a600a1200a4000",
                    "TopazPlus",
                    "Monaco"
                ],
                scrollerPlacement: .trailing,
                scrollerTrackStyle: .stippled,
                scrollerAppearance: .amiga,
                menuAppearance: .amiga,
                progressStyle: .amiga,
                choiceStyle: .cycle,
                checkboxStyle: .recessedTick
            ),
            sidebar: SidebarStyle(
                navigatorWell: .init(fill: hex("#AAAAAA"), bevel: .sunken)
            ),
            chrome: WindowChromeStyle(
                titleBar: .init(
                    activeGradient: .init(stops: [
                        .init(color: hex("#6688BB"), position: 0),
                        .init(color: hex("#6688BB"), position: 1)
                    ]),
                    inactiveGradient: .init(stops: [
                        .init(color: hex("#AAAAAA"), position: 0),
                        .init(color: hex("#AAAAAA"), position: 1)
                    ]),
                    ink: hex("#000000"),
                    inactiveInk: hex("#000000"),
                    titleAlignment: .leading,
                    // The Workbench title strip is the compact 18px Intuition band, not the
                    // 26px modern-caption default. Keeping this explicit also leaves room for
                    // the full close/zoom/depth gadget faces without stretching them.
                    titleFontSize: 12,
                    height: 18,
                    buttonGlyphStyle: .amiga,
                    buttonPlacement: .split,
                    showsAppIcon: false,
                    visibleButtons: [.close, .zoom, .depth]
                ),
                frame: .init(width: 3)
            )
        )]
    )
}
