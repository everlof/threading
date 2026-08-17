import AppKit

extension AppThemeStyles {

    /// A full-screen terminal program, wearing the window.
    ///
    /// The first takeover that reproduces no system. Every other one in this family is a
    /// reconstruction held to measured pixels from a specific release; this one is authored in
    /// the idiom the text-mode tools share — a box drawn in rule characters, a header row
    /// closed by a seam, hairline caption cells that invert under the pointer, one accent, and
    /// a grid nothing sits off. That is why its chrome-reference ledger records every component
    /// as `not_applicable` rather than `missing`: there is no original to measure it against,
    /// and pretending otherwise would put a permanent hole in an archive that is supposed to
    /// mean something.
    ///
    /// The palette is ours. It is deliberately not the neon of `cyberpunk`, which already owns
    /// "terminal-forward and loud": this one is quiet, and the accent is the only saturated
    /// thing in the window — a box-drawing interface reads by *structure*, and a second hue
    /// competing with the rules is what makes one look like a toy.
    static let tui = AppTheme(
        id: AppThemeID("tui"),
        name: "TUI",
        mode: .dark,
        summary: "A box-drawn frame, monospaced type, and one accent on slate.",
        variants: [.dark: AppTheme.Variant(
            roles: [
                .ground: hex("#101419"),
                .surface: hex("#151A21"),
                .panel: hex("#1A2029"),
                // A value well is *sunken* here rather than raised, and with no bevel to say
                // so the only thing left to say it with is depth of colour: a field goes
                // below the ground, the way a terminal's own input line is darker than the
                // box around it. Derived from `panel` this came out lighter, which read as a
                // card floating over the pane it is inside.
                .fieldSurface: hex("#0B0E13"),
                .elevated: hex("#212934"),
                // The period family's lesson, which applies to any theme without an ambient
                // shadow: a floating card derived from `elevated` is a paler rectangle with
                // nothing under it to explain the lift. Here it takes the panel's own value
                // and is separated by its border, exactly like every other box.
                .floatingSurface: hex("#1A2029"),
                // The rule character. Everything structural in this theme is one point of
                // this colour, including the window's own frame and the seam under the
                // title band, so they read as one continuous drawing.
                .border: hex("#3A4757"),
                .divider: hex("#28313D"),
                .label: hex("#C8D2DE"),
                .accent: hex("#5FBFA8"),
                .accentMuted: hex("#5FBFA8").withAlphaComponent(0.16),
                // Stated rather than derived, for `cyberpunk`'s reason: the derivation is the
                // label held down, which is a grey, and a grey control in a window built from
                // coloured rules reads as a different application's widget.
                .controlResting: hex("#1A2029"),
                .controlHover: hex("#5FBFA8").withAlphaComponent(0.14),
                .selection: hex("#5FBFA8").withAlphaComponent(0.28),
                .statusPositive: hex("#6FC08C"),
                .statusWarning: hex("#D6B06A"),
                .statusNegative: hex("#DE8189"),
                .syntaxKeyword: hex("#B49BE0"),
                .syntaxType: hex("#6FBAC4"),
                .syntaxString: hex("#9AC585"),
                .syntaxNumber: hex("#D6B06A")
            ],
            // The terminal's background is the window's own ground, which no other theme here
            // does. In every one of them the terminal is a black rectangle *inside* the
            // application; in this one the application is pretending to be the terminal, and a
            // darker pane would draw the seam this theme spends its whole design hiding.
            terminalPalette: TerminalTheme(
                id: TerminalThemeID("app-tui-terminal"),
                name: "TUI",
                foreground: hex("#C8D2DE"),
                boldForeground: hex("#FFFFFF"),  // The highlight white a text UI reverses to
                background: hex("#101419"),
                // The palette's own ink, not the accent. A block cursor is the largest solid
                // shape on the screen and a saturated one shouts over queued input — the rule
                // every paired palette here follows, and the accent is spent on selection.
                cursor: hex("#C8D2DE"),
                selection: hex("#1E4A45"),
                black: hex("#1A2029"),
                red: hex("#DE8189"),
                green: hex("#6FC08C"),
                yellow: hex("#D6B06A"),
                blue: hex("#7FA6D8"),
                magenta: hex("#B49BE0"),
                cyan: hex("#5FBFA8"),
                white: hex("#B4BECA"),
                brightBlack: hex("#4A5563"),
                brightRed: hex("#EE99A0"),
                brightGreen: hex("#8AD3A4"),
                brightYellow: hex("#E8C782"),
                brightBlue: hex("#9BBCE6"),
                brightMagenta: hex("#C7B2EC"),
                brightCyan: hex("#7FD5C0"),
                brightWhite: hex("#E4EAF1")
            ),
            material: AppTheme.Material(
                // Square, everywhere. A cell grid has no radius to spend, and a single
                // rounded control is the one thing that would give the illusion away.
                panelRadius: 0,
                controlRadius: 0,
                borderWidth: 1,
                // Monospaced glyphs are wider than the proportional ones every measurement in
                // `Design` was chosen against, so the same words need more room. Holding the
                // scale slightly down buys that width back inside the panes rather than
                // widening the panes, which is not a theme's decision to make.
                textScale: 0.94,
                choiceHeight: 22,
                glow: nil,
                popoverStyle: textModePopoverStyle,
                buttonStyle: AppTheme.Material.ButtonStyle(
                    // `[ Continue ]` is an outline, not a filled pill: a text-mode default
                    // action is marked by the brackets around it, and the one thing filled
                    // with accent in this window is the selected row.
                    fontWeight: .regular,
                    primaryTreatment: .outlined
                ),
                headingStyle: AppTheme.Material.HeadingStyle(fontWeight: .bold),
                // No bevel on purpose, and it is load-bearing rather than an omission: it is
                // what routes `WindowChromeFrameView` to its single one-point seat instead of
                // the raised two-ring edge every retro takeover wears, which is the whole
                // difference between a drawn box and a moulded one.
                bevel: nil,
                typeface: .monospaced,
                menuAppearance: .automatic,
                choiceStyle: .chip
            ),
            sidebar: SidebarStyle(
                // The project tree is the left box's interior. Flat, and a shade below the
                // sidebar around it, so the tree's own edge is the theme's rule and nothing
                // else — a bevel here would put a moulded panel inside a drawn one.
                navigatorWell: .init(fill: hex("#0D1116"), bevel: .none)
            ),
            chrome: WindowChromeStyle(
                titleBar: .init(
                    // Flat, and the same value as the ground: the header is a *row* of the
                    // box rather than a bar laid over it, so the only thing that separates it
                    // from the panes is the rule below it. Two identical stops because a
                    // gradient needs two, not because anything varies across the band.
                    activeGradient: .init(stops: [
                        .init(color: hex("#101419"), position: 0),
                        .init(color: hex("#101419"), position: 1)
                    ]),
                    inactiveGradient: .init(stops: [
                        .init(color: hex("#101419"), position: 0),
                        .init(color: hex("#101419"), position: 1)
                    ]),
                    // Spend the single accent on the active caption line: its title and
                    // operations are the window's status, while the rule and frame stay
                    // quiet enough to remain structure rather than decoration.
                    ink: hex("#5FBFA8"),
                    inactiveInk: hex("#6C7683"),
                    titleAlignment: .leading,
                    titleFontStyle: .upright,
                    titleFontSize: 12,
                    // Two rows of a 12pt monospaced grid: one for the caption line and one of
                    // air above and below it. The 28pt default left the title floating in the
                    // middle of a band twice the height of the row it names.
                    height: 26,
                    buttonGlyphStyle: .tui,
                    // A real window-menu cell opens the line, while the three immediate
                    // operations close it. That bookending makes the sparse header read as
                    // a deliberate status row instead of three marks stranded at the edge.
                    buttonPlacement: .bookends,
                    // No icon. A text-mode header carries a name and its operations; the
                    // application's mark belongs to the sidebar's brand row, where it already
                    // is, and a 14pt colour raster is the one thing in this window that could
                    // not have been drawn in characters.
                    showsAppIcon: false,
                    // The band says "not me" by dimming its seam as well as its title, which
                    // is the only inactive cue a flat chrome has — there is no gradient here
                    // to drain of colour.
                    activeTexture: .init(kind: .rule, color: hex("#3A4757")),
                    inactiveTexture: .init(kind: .rule, color: hex("#252E39")),
                    visibleButtons: [.windowMenu, .minimize, .zoom, .close]
                ),
                // One point, and a small curve. The radius is the concession to the platform;
                // the rasterization is not. Its stepped turn uses the same one-bit pen as every
                // rule inside the text console instead of inventing a soft coverage gradient.
                frame: .init(width: 1, cornerRadius: 6, antialiasesCorners: false)
            )
        )]
    )

    /// The text-mode transient surface: a box, its rule, and nothing else. It shares the
    /// period family's stemless compact shape for the same reason — a pointer that has to
    /// find an arrow is a pointer looking at a drawn callout rather than at a panel — but
    /// takes the flat edge, because this theme's material states no bevel to raise one with.
    static let textModePopoverStyle = AppTheme.Material.PopoverStyle(
        arrow: .none,
        edge: .flat,
        shadow: .none,
        density: .compact,
        glyphStyle: .classic
    )
}
