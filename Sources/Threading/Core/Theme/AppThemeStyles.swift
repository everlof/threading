import AppKit

/// The stock styles the app ships.
///
/// Named after public design movements and broad visual genres. The palettes here are our own
/// values, authored against those aesthetics; nothing is copied from a style guide or site.
/// The one carve-out is the palette-first family in `AppThemeStyles+Palettes.swift`: Solarized,
/// Nord, and Dracula are community schemes whose identity is their exact published values, so
/// those are reproduced from their MIT-licensed definitions and credited there.
///
/// **What a style can and cannot carry here.** A design style is roughly four layers: palette,
/// material, type, and layout with motion. Threading's layout *is* the product, so no theme moves
/// the sidebar. Themes do own shape, rules, and a directed panel shadow: enough for hard-print,
/// soft-clay, neon, and restrained editorial materials without turning a theme into a second
/// view hierarchy.
///
/// Each states only the roles in `AppThemeRole.authored`; the rest are derived, so a theme is a
/// dozen decisions rather than twenty-five.
enum AppThemeStyles {

    /// The house group, which carries no head: a heading over the two entries the app ships
    /// with would name a group nobody goes looking for, and the composer's identity menu already
    /// learned that a head repeating its single row's own name is furniture. `AppThemeLibrary`
    /// puts System at its front, being the one entry that is not a style at all.
    static let house = AppThemeSection([threading])

    /// The named families, in the order a picker shows them.
    ///
    /// Four kinds of thing were sitting in one twenty-eight-row list, and the list said so
    /// nowhere: a design movement, a colour scheme, a reproduction of a shipped desktop, and a
    /// reproduction of a piece of period software are chosen for entirely different reasons.
    /// Filing them is what lets a reader skip the twenty rows they are not looking for.
    static let styleFamilies: [AppThemeSection] = [
        AppThemeSection(L10n.string("Design styles"), [
            editorial,
            cyberpunk,
            swissMinimalist,
            bauhaus,
            artDeco,
            neoBrutalism,
            claymorphism,
            vaporwave,
            newsprint,
            botanical,
            industrial
        ]),
        // The palette-first family: a colour language rather than a chrome. See
        // `docs/architecture/themes.md`.
        AppThemeSection(L10n.string("Palettes"), [
            pureBlack,
            cappuccino,
            solarized,
            nord,
            dracula
        ]),
        AppThemeSection(L10n.string("Classic desktops"), [
            platinum,
            aqua,
            aquaTiger,
            beOS,
            openStep,
            irix,
            amiga,
            win98
        ]),
        // Not desktops: a media player's compact chrome and a text-mode application's box
        // drawing reproduce *software* of the same period, which is why Classic Player moved
        // out from between Workbench and Windows 98.
        AppThemeSection(L10n.string("Classic software"), [
            classicPlayer,
            tui
        ]),
        AppThemeSection(L10n.string("Seasonal"), [
            christmas
        ])
    ]

    /// Every stock family, house first.
    static var families: [AppThemeSection] { [house] + styleFamilies }

    /// The stock catalogue, derived from the families rather than listed again beside them.
    ///
    /// Deriving it is the point: a style that is not filed under a family does not exist, so the
    /// picker cannot fall out of step with the catalogue. The hand-maintained copy this replaces
    /// had already drifted once — see `takeovers`, which learned the same lesson one property
    /// along.
    static let all: [AppTheme] = families.flatMap(\.themes)

    /// The stock themes that draw the window frame themselves, derived from the one fact
    /// that defines them (`takesOverWindowChrome`) rather than listed again by hand.
    ///
    /// This is the only takeover registry. The Component Gallery's chrome story and the
    /// window-chrome test sweeps iterate this list, so a new takeover theme appears in both
    /// by being added to `all` — the gallery had already drifted once (Aqua and Tiger were
    /// missing) in the short life of the third hand-maintained copy.
    static var takeovers: [AppTheme] {
        all.filter(\.takesOverWindowChrome)
    }

    /// Shared period transient chrome: a stemless compact card, raised by the material's own
    /// edge and never by a modern ambient window shadow. Individual systems may refine it —
    /// Windows 98 does, because its infotip is a flat dark rule on pale information yellow.
    static let periodPopoverStyle = AppTheme.Material.PopoverStyle(
        arrow: .none,
        edge: .material,
        shadow: .none,
        density: .compact,
        glyphStyle: .classic
    )

    /// Aqua Help Tags are compact, stemless plates rather than modern speech bubbles. The
    /// pale-yellow surface and near-square corner come from the period HIG figures; Cheetah's
    /// figure is later than 10.0.x, so that family remains source-shaped in its ledger.
    static let aquaHelpTagPopoverStyle = AppTheme.Material.PopoverStyle(
        arrow: .none,
        surfaceRole: .tooltipSurface,
        edge: .flat,
        shadow: .system,
        density: .compact,
        glyphStyle: .system,
        cornerRadius: 1
    )

    static let windowsInfotipStyle = AppTheme.Material.PopoverStyle(
        arrow: .none,
        edge: .flat,
        shadow: .none,
        density: .compact,
        glyphStyle: .classic
    )

    /// Threading's own navy and orange frame. Marketing captures use this theme unless they
    /// are demonstrating the theme picker itself.
    static let threading = AppTheme(
        id: AppThemeID("threading"),
        name: "Threading",
        mode: .dark,
        summary: "A navy frame, warm text, and Threading orange.",
        variants: [.dark: AppTheme.Variant(
            roles: [
                .ground: hex("#040A12"),
                .surface: hex("#071626"),
                .panel: hex("#0A1C2F"),
                .elevated: hex("#102A43"),
                .border: hex("#2B4B65"),
                .divider: hex("#183A52"),
                .label: hex("#F7EFE6"),
                .accent: hex("#FF9A3D"),
                .accentMuted: hex("#FF9A3D").withAlphaComponent(0.13),
                .controlResting: hex("#0E253A"),
                .controlHover: hex("#173B55"),
                // Selection is a deeper navy rather than diluted orange. Orange remains the
                // action and focus ink, while selected rows stay crisp instead of turning
                // muddy brown over the app's blue surfaces.
                .selection: hex("#17405C"),
                .statusPositive: hex("#74C49A"),
                .statusWarning: hex("#E6A35D"),
                .statusNegative: hex("#E06E65"),
                .syntaxKeyword: hex("#FF9A3D"),
                .syntaxType: hex("#7DC9D2"),
                .syntaxString: hex("#B8C58A"),
                .syntaxNumber: hex("#E6B98C")
            ],
            terminalPalette: TerminalTheme(
                id: TerminalThemeID("app-threading-terminal"),
                name: "Threading",
                foreground: hex("#D9D1C8"),
                boldForeground: hex("#FFFFFF"),  // Body steps to the ramp’s own white
                background: hex("#040A12"),
                // The palette's own ink, not its orange. A block cursor sits *on* a character,
                // so the accent drew an alarm block over the first letter of queued input.
                cursor: hex("#D9D1C8"),
                selection: hex("#173A50"),
                black: hex("#071626"),
                red: hex("#E06E65"),
                green: hex("#74C49A"),
                yellow: hex("#E6A35D"),
                blue: hex("#6EA8D8"),
                magenta: hex("#C486B9"),
                cyan: hex("#7DC9D2"),
                white: hex("#D9D1C8"),
                brightBlack: hex("#4F697E"),
                brightRed: hex("#F08A81"),
                brightGreen: hex("#91D6AD"),
                brightYellow: hex("#F2BC78"),
                brightBlue: hex("#8DBEE3"),
                brightMagenta: hex("#D9A0CC"),
                brightCyan: hex("#9CDAE0"),
                brightWhite: hex("#F7EFE6")
            ),
            material: AppTheme.Material(
                panelRadius: 10,
                controlRadius: 7,
                borderWidth: 1,
                buttonStyle: AppTheme.Material.ButtonStyle(fontWeight: .semibold),
                headingStyle: AppTheme.Material.HeadingStyle(fontWeight: .semibold)
            ),
            sidebar: SidebarStyle(
                background: .init(gradient: .init(stops: [
                    .init(color: hex("#0B2237"), position: 0),
                    .init(color: hex("#071626"), position: 1)
                ], angleDegrees: 180)),
                navigatorWell: .init(fill: hex("#061321"), bevel: .none)
            ),
            chrome: WindowChromeStyle(
                titleBar: .init(
                    activeGradient: .init(stops: [
                        .init(color: hex("#0D253B"), position: 0),
                        .init(color: hex("#091B2E"), position: 1)
                    ], angleDegrees: 180),
                    inactiveGradient: .init(stops: [
                        .init(color: hex("#081524"), position: 0),
                        .init(color: hex("#06101C"), position: 1)
                    ], angleDegrees: 180),
                    ink: hex("#F7EFE6"),
                    inactiveInk: hex("#8693A0"),
                    titleAlignment: .leading,
                    titleFontStyle: .upright,
                    titleFontSize: 12,
                    height: 32,
                    buttonGlyphStyle: .plain,
                    buttonPlacement: .trailing,
                    showsAppIcon: false,
                    activeTexture: .init(kind: .rule, color: hex("#FF9A3D")),
                    inactiveTexture: .init(kind: .rule, color: hex("#2B4B65"))
                ),
                frame: .init(width: 1, cornerRadius: 12)
            )
        )]
    )

    /// High-contrast terminal chrome on the live reference's near-black violet stack.
    ///
    /// States its own `controlResting`/`controlHover` rather than letting them derive from the
    /// label: the derivation is `label` at 8%, which is a grey, and a grey control on a neon
    /// theme is how the first pass ended up looking like the same app in a different tint.
    /// Here they are the accent, held far down — so every hoverable thing glows faintly green
    /// instead of going pale.
    static let cyberpunk = AppTheme(
        id: AppThemeID("cyberpunk"),
        name: "Cyberpunk",
        mode: .dark,
        summary: "Neon on black, high contrast, terminal-forward.",
        roles: [
            // Measured from the rendered page: #0A0A0F canvas, #12121A secondary planes,
            // and #1C1C2E modules divided by the same #2A2A3A construction line.
            .ground: hex("#0A0A0F"),
            .surface: hex("#12121A"),
            .panel: hex("#1C1C2E"),
            .elevated: hex("#24243A"),
            .border: hex("#2A2A3A"),
            .divider: hex("#2A2A3A"),
            .label: hex("#E0E0E0"),
            .accent: hex("#00FF88"),
            .accentMuted: hex("#00FF88").withAlphaComponent(0.10),
            .controlResting: hex("#1C1C2E"),
            .controlHover: hex("#00FF88").withAlphaComponent(0.14),
            .selection: hex("#00FF88").withAlphaComponent(0.30),
            .statusPositive: hex("#00FF88"),
            .statusWarning: hex("#FFB000"),
            .statusNegative: hex("#FF3366"),
            .syntaxKeyword: hex("#FF00FF"),
            .syntaxType: hex("#00D4FF"),
            .syntaxString: hex("#00FF88"),
            .syntaxNumber: hex("#FFB000")
        ],
        // The terminal half of the style, written out rather than derived — see
        // `AppTheme.terminalPalette`. Built from the same neon the chrome states: the syntax
        // hues become magenta/cyan/green/yellow, `statusNegative` becomes red, and `black` is
        // the panel colour rather than true black so an ANSI-black glyph is still a glyph.
        terminalPalette: TerminalTheme(
            id: TerminalThemeID("app-cyberpunk-terminal"),
            name: "Cyberpunk",
            foreground: hex("#E0E0E0"),
            // Hazard yellow. The accent green is this palette’s `green`, and so is every
            // other neon here except this one.
            boldForeground: hex("#FCEE0A"),
            background: hex("#0A0A0F"),
            cursor: hex("#E0E0E0"),
            selection: hex("#103D2C"),
            black: hex("#12121A"),
            red: hex("#FF3366"),
            green: hex("#00FF88"),
            yellow: hex("#FFB000"),
            blue: hex("#2E8BFF"),
            magenta: hex("#FF00FF"),
            cyan: hex("#00D4FF"),
            white: hex("#B9C6C0"),
            brightBlack: hex("#2A2A3A"),
            brightRed: hex("#FF6B93"),
            brightGreen: hex("#7CFFC4"),
            brightYellow: hex("#FFD166"),
            brightBlue: hex("#7AB4FF"),
            brightMagenta: hex("#FF7AFF"),
            brightCyan: hex("#7CE9FF"),
            brightWhite: hex("#E0E0E0")
        ),
        // Tight corners, a neon halo behind every panel, and mono type — the brief's own
        // trio; without the mono this read as "a dark theme", not as Cyberpunk.
        material: AppTheme.Material(
            panelRadius: 2,
            controlRadius: 2,
            borderWidth: 1,
            backdropPattern: AppTheme.Material.BackdropPattern(
                kind: .grid, role: .accent, opacity: 0.20, spacing: 40, lineWidth: 1
            ),
            // The reference repeats two concentric green glows: a crisp 5px light and a
            // 10px quarter-strength halo. Core Animation's radius is half CSS's blur.
            glow: AppTheme.Glow(
                role: .accent,
                radius: 5,
                opacity: 0.25,
                highlight: AppTheme.Glow.Highlight(
                    role: .accent,
                    radius: 2.5,
                    opacity: 1
                )
            ),
            controlGlow: AppTheme.Glow(
                role: .accent,
                radius: 5,
                opacity: 0.25,
                highlight: AppTheme.Glow.Highlight(
                    role: .accent,
                    radius: 2.5,
                    opacity: 1
                )
            ),
            buttonStyle: AppTheme.Material.ButtonStyle(
                textTransform: .uppercase,
                fontWeight: .medium,
                tracking: 0.6,
                primaryTreatment: .outlined
            ),
            headingStyle: AppTheme.Material.HeadingStyle(fontWeight: .bold),
            typeface: .monospaced
        )
    )

    /// International Typographic Style: paper white, black text, one red accent, nothing else.
    /// The opposite failure mode to Cyberpunk — a style that is mostly *restraint*, where the
    /// risk is that a theme adds colour where the style's whole point is that it does not.
    static let swissMinimalist = AppTheme(
        id: AppThemeID("swiss-minimalist"),
        name: "Swiss Minimalist",
        mode: .light,
        summary: "Paper white, black type, a single red accent.",
        roles: [
            .ground: hex("#FFFFFF"),
            .surface: hex("#F2F2F2"),
            .panel: hex("#FFFFFF"),
            .elevated: hex("#FFFFFF"),
            // A rule you can actually see. The style is built from black lines on white, so a
            // pale system-grey hairline is the one thing it cannot have.
            .border: hex("#111111"),
            .divider: hex("#111111").withAlphaComponent(0.18),
            .label: hex("#111111"),
            // The live composition's only chromatic ink is international orange.
            .accent: hex("#FF3000"),
            .accentMuted: hex("#FF3000").withAlphaComponent(0.14),
            .controlResting: hex("#111111").withAlphaComponent(0.05),
            .controlHover: hex("#111111").withAlphaComponent(0.10),
            .selection: hex("#FF3000").withAlphaComponent(0.22),
            .statusPositive: hex("#0F7A34"),
            .statusWarning: hex("#B45309"),
            .statusNegative: hex("#FF3000"),
            // Type over colour: the International Style sets information in weight and
            // position, not in six hues, so code is black with one red for strings.
            .syntaxKeyword: hex("#111111"),
            .syntaxType: hex("#4A4A4A"),
            .syntaxString: hex("#FF3000"),
            .syntaxNumber: hex("#4A4A4A")
        ],
        // Square. The grid is the whole idea, and a 12pt radius rounds it away.
        // Paper, black type, one red. The ANSI colours are held *down* — a Swiss terminal that
        // lit up in eight bright hues would contradict the style it is named after — so they are
        // muted enough to sit on white and still be told apart, with red left at full strength
        // because red is the accent this style actually has.
        //
        // The greys break with convention on purpose. A light theme normally leaves `white` and
        // `brightWhite` near-white, because in a light palette those indices are meant as
        // *backgrounds* — but a CLI that dims its status line to index 7 then writes pale grey on
        // paper, which is what the first version of this did and it was unreadable. So the four
        // neutrals are a monotone ramp dark enough to read on white and still ordered
        // black → brightBlack → white → brightWhite, so nothing that picks one of them vanishes.
        terminalPalette: TerminalTheme(
            id: TerminalThemeID("app-swiss-minimalist-terminal"),
            name: "Swiss Minimalist",
            foreground: hex("#333333"),
            boldForeground: hex("#111111"),  // The heading keeps the ramp’s black
            background: hex("#FFFFFF"),
            cursor: hex("#333333"),
            selection: hex("#FAD5D1"),
            black: hex("#111111"),
            red: hex("#FF3000"),
            green: hex("#2E6B4F"),
            yellow: hex("#A67C00"),
            blue: hex("#24408E"),
            magenta: hex("#8B2E6B"),
            cyan: hex("#1F6B75"),
            white: hex("#767676"),
            brightBlack: hex("#5A5A5A"),
            brightRed: hex("#FF3B2E"),
            brightGreen: hex("#3F8F6B"),
            brightYellow: hex("#C99A1E"),
            brightBlue: hex("#3557B8"),
            brightMagenta: hex("#B04A8C"),
            brightCyan: hex("#2E8C99"),
            brightWhite: hex("#A8A8A8")
        ),
        // The reference's framing system alternates 2px dividers and 4px structural borders.
        // Two points is the honest weight at application scale; the former hairline read grey.
        material: AppTheme.Material(
            panelRadius: 0,
            controlRadius: 0,
            borderWidth: 2,
            backdropPattern: AppTheme.Material.BackdropPattern(
                kind: .grid, role: .label, opacity: 0.03, spacing: 24, lineWidth: 1
            ),
            glow: nil,
            buttonStyle: AppTheme.Material.ButtonStyle(
                textTransform: .uppercase,
                fontWeight: .medium,
                tracking: 0.3
            ),
            headingStyle: AppTheme.Material.HeadingStyle(fontWeight: .bold)
        )
    )

    /// Force-unwrapped deliberately: these are literals in this file, so a bad one is a build
    /// this test suite fails rather than a colour that silently renders white at runtime.
    static func hex(_ value: String) -> NSColor {
        guard let color = NSColor(hex: value) else {
            preconditionFailure("Malformed stock theme colour: \(value)")
        }
        return color
    }
}
