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
                // COLOR_HIGHLIGHT was an opaque navy. Letting the button face bleed through
                // lifts it to #131381, visibly lighter and more violet than the Win98 menu band.
                .selection: hex("#000080"),
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
                boldForeground: hex("#FFFFFF"),  // The console’s intensity bit
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
            // TrueType successor. W95FA is the explicitly OFL-licensed scalable recreation the
            // app may redistribute; installing the original still moves it to the front.
            material: AppTheme.Material(
                panelRadius: 0,
                controlRadius: 0,
                borderWidth: 1,
                // Win98 shell UI was set around eight points, but reproducing that literal
                // density across a modern high-resolution application made the project tree
                // and secondary copy needlessly small. This keeps the compact period hierarchy
                // while letting ordinary application content sit one optical step above it.
                textScale: 0.80,
                choiceHeight: 21,
                glow: nil,
                popoverStyle: windowsInfotipStyle,
                buttonStyle: AppTheme.Material.ButtonStyle(
                    fontWeight: .regular,
                    // Ported from the pinned MIT 98.css implementation: Win32 pushbuttons use
                    // a 75×23 minimum face with twelve pixels of horizontal title padding.
                    // The inset is already the design system's ordinary 12pt button inset;
                    // these two floors were the missing part of that native geometry.
                    // CSS and AppKit both address logical screen pixels here; physical-inch
                    // conversion was the wrong model. At the theme's 0.8 text scale the 12pt
                    // semantic control face is 9.6pt, so 55/48 lands the imported 11px strike
                    // exactly on an 11pt device-grid size.
                    fontScale: 55 / 48,
                    minimumWidth: 75,
                    minimumHeight: 23,
                    embossesDisabledTitle: true,
                    // GDI selected an 8pt bitmap strike and painted its small UI labels on the
                    // device grid. W95FA is an outline recreation, so allowing CoreText to
                    // smooth it produces the gray fringe that makes the face look modern.
                    antialiasesTitle: false,
                    primaryTreatment: .raised,
                    // COLOR_WINDOWFRAME, which Win32 painted black — not COLOR_BTNSHADOW, which
                    // is this theme's `.border` gray and is already carrying the bevel. The
                    // default button's extra outer frame is the one mark separating it from its
                    // siblings; in shadow gray it reads as another bevel edge and the dialog
                    // stops saying which action Return takes.
                    primaryRole: .label,
                    pressedOffsetX: 1,
                    pressedOffsetY: 1
                ),
                bevel: AppTheme.Bevel(width: 2),
                typeface: .standard,
                fontFamily: "MS Sans Serif",
                // W95FA is the OFL-licensed scalable recreation of MS Sans Serif. It stays a
                // fallback rather than replacing the real family, and is not downloaded by the
                // app; an installed copy is used automatically. Geneva is the last built-in,
                // period-safe stop before the modern system face.
                fontFallbacks: ["Microsoft Sans Serif", "W95FA", "Tahoma", "Geneva"],
                // COLOR_SCROLLBAR was the familiar white/button-face dither, not another
                // uninterrupted #C0C0C0 plate. It is what keeps the movable thumb legible
                // even before its raised edges are noticed.
                scrollerTrackStyle: .stippled,
                scrollerAppearance: .windows98,
                menuAppearance: .windows98,
                progressStyle: .segmented,
                choiceStyle: .dropdown,
                checkboxStyle: .windows98Tick
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
                        // This endpoint produces the preserved #B5 sample at the caption button
                        // cluster's measured x-position. The earlier #A8 made every inactive
                        // window much darker than the native right edge; #B8 overshot the other
                        // way, landing white ink at 1.98:1 — under the inactive floor by a
                        // hundredth. #B7 is the lightest endpoint the contrast rule allows, and
                        // one step of 255 is not a colour anybody can see.
                        .init(color: hex("#B7B7B7"), position: 1)
                    ], angleDegrees: 90),
                    ink: hex("#FFFFFF"),
                    inactiveInk: hex("#FFFFFF"),
                    titleAlignment: .leading,
                    titleFontSize: 11,
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
