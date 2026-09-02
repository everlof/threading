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
public enum AppThemeStyles {

    /// The house group, which carries no head: a heading over the two entries the app ships
    /// with would name a group nobody goes looking for, and the composer's identity menu already
    /// learned that a head repeating its single row's own name is furniture. `AppThemeLibrary`
    /// puts System at its front, being the one entry that is not a style at all.
    public static let house = AppThemeSection([threading])

    /// The named families, in the order a picker shows them.
    ///
    /// Four kinds of thing were sitting in one twenty-eight-row list, and the list said so
    /// nowhere: a design movement, a colour scheme, a reproduction of a shipped desktop, and a
    /// reproduction of a piece of period software are chosen for entirely different reasons.
    /// Filing them is what lets a reader skip the twenty rows they are not looking for.
    public static let styleFamilies: [AppThemeSection] = [
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
            pure,
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
    public static var families: [AppThemeSection] { [house] + styleFamilies }

    /// The stock catalogue, derived from the families rather than listed again beside them.
    ///
    /// Deriving it is the point: a style that is not filed under a family does not exist, so the
    /// picker cannot fall out of step with the catalogue. The hand-maintained copy this replaces
    /// had already drifted once — see `takeovers`, which learned the same lesson one property
    /// along.
    public static let all: [AppTheme] = families.flatMap(\.themes)

    /// Stock ids retired by a rename, each pointing at the theme that replaced it.
    ///
    /// A theme's id is its persistence identity (`AppThemeID`), so a stock theme cannot simply
    /// change its slug: the standing choice on every Mac that picked it, the phone's icon
    /// recommendation and any `set_app_theme` call an agent learned would all fall through to the
    /// product default. `AppThemeLibrary.theme(withID:)` consults this after the catalogue
    /// misses, so a retired id keeps resolving without ever appearing as a catalogue entry of its
    /// own. Restore never writes, so the old id can stay on disk indefinitely; the next
    /// deliberate pick records the successor.
    public static let retiredIDs: [AppThemeID: AppThemeID] = [
        retiredPureBlackID: pure.id
    ]

    /// The stock themes that draw the window frame themselves, derived from the one fact
    /// that defines them (`takesOverWindowChrome`) rather than listed again by hand.
    ///
    /// This is the only takeover registry. The Component Gallery's chrome story and the
    /// window-chrome test sweeps iterate this list, so a new takeover theme appears in both
    /// by being added to `all` — the gallery had already drifted once (Aqua and Tiger were
    /// missing) in the short life of the third hand-maintained copy.
    public static var takeovers: [AppTheme] {
        all.filter(\.takesOverWindowChrome)
    }

    /// Shared period transient chrome: a stemless compact card, raised by the material's own
    /// edge and never by a modern ambient window shadow. Individual systems may refine it —
    /// Windows 98 does, because its infotip is a flat dark rule on pale information yellow.
    public static let periodPopoverStyle = AppTheme.Material.PopoverStyle(
        arrow: .none,
        edge: .material,
        shadow: .none,
        density: .compact,
        glyphStyle: .classic
    )

    /// Aqua Help Tags are compact, stemless plates rather than modern speech bubbles. The
    /// pale-yellow surface and near-square corner come from the period HIG figures; Cheetah's
    /// figure is later than 10.0.x, so that family remains source-shaped in its ledger.
    public static let aquaHelpTagPopoverStyle = AppTheme.Material.PopoverStyle(
        arrow: .none,
        surfaceRole: .tooltipSurface,
        edge: .flat,
        shadow: .system,
        density: .compact,
        glyphStyle: .system,
        cornerRadius: 1
    )

    public static let windowsInfotipStyle = AppTheme.Material.PopoverStyle(
        arrow: .none,
        edge: .flat,
        shadow: .none,
        density: .compact,
        glyphStyle: .classic
    )

    /// Threading's own adaptive navy, warm paper, and orange dress. Marketing captures use this
    /// theme unless they are demonstrating the theme picker itself.
    public static let threading = AppTheme(
        id: AppThemeID("threading"),
        name: "Threading",
        mode: .system,
        summary: "Navy and warm paper with Threading orange, following macOS light or dark.",
        variants: [
            .light: threadingLight,
            .dark: threadingDark
        ]
    )

    /// The house palette is authored in OKLCH. Unlike a historical or community palette there
    /// are no source RGB values to reproduce, so perceptual lightness and chroma are the actual
    /// design decisions and sRGB is only the display encoding they resolve into.
    private static let threadingLight = AppTheme.Variant(
        roles: [
            .ground: oklch(0.975, 0.012, 75),
            .surface: oklch(0.940, 0.020, 245),
            .panel: oklch(0.990, 0.006, 75),
            .elevated: oklch(1.000, 0.000, 0),
            .border: oklch(0.680, 0.055, 245),
            .divider: oklch(0.820, 0.035, 245),
            .label: oklch(0.235, 0.045, 250),
            // The dark variant's orange is intentionally lowered in lightness for paper: the
            // same hue and chroma at its night value falls below the accent contrast floor.
            .accent: oklch(0.640, 0.170, 55),
            .accentMuted: oklch(0.640, 0.170, 55, alpha: 0.13),
            .controlResting: oklch(0.910, 0.025, 245),
            .controlHover: oklch(0.850, 0.045, 245),
            .selection: oklch(0.820, 0.065, 242),
            .statusPositive: oklch(0.500, 0.120, 155),
            .statusWarning: oklch(0.520, 0.130, 70),
            .statusNegative: oklch(0.540, 0.180, 25),
            .syntaxKeyword: oklch(0.540, 0.160, 55),
            .syntaxType: oklch(0.500, 0.100, 220),
            .syntaxString: oklch(0.480, 0.110, 135),
            .syntaxNumber: oklch(0.520, 0.130, 70)
        ],
        terminalPalette: TerminalTheme(
            id: TerminalThemeID("app-threading-terminal-light"),
            name: "Threading",
            foreground: oklch(0.320, 0.025, 250),
            boldForeground: oklch(0.200, 0.045, 250),
            background: oklch(0.990, 0.006, 75),
            cursor: oklch(0.320, 0.025, 250),
            selection: oklch(0.860, 0.055, 242),
            black: oklch(0.200, 0.045, 250),
            red: oklch(0.500, 0.170, 25),
            green: oklch(0.450, 0.120, 150),
            yellow: oklch(0.480, 0.120, 75),
            blue: oklch(0.470, 0.140, 250),
            magenta: oklch(0.500, 0.140, 330),
            cyan: oklch(0.450, 0.090, 205),
            // A light terminal's white slots are readable greys, not ink that disappears into
            // the page. The ramp remains ordered black → brightBlack → white → brightWhite.
            white: oklch(0.560, 0.018, 250),
            brightBlack: oklch(0.420, 0.022, 250),
            brightRed: oklch(0.600, 0.150, 25),
            brightGreen: oklch(0.560, 0.120, 150),
            brightYellow: oklch(0.580, 0.130, 75),
            brightBlue: oklch(0.580, 0.120, 250),
            brightMagenta: oklch(0.600, 0.120, 330),
            brightCyan: oklch(0.560, 0.100, 205),
            brightWhite: oklch(0.700, 0.012, 250)
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
                .init(color: oklch(0.930, 0.028, 245), position: 0),
                .init(color: oklch(0.950, 0.018, 245), position: 1)
            ], angleDegrees: 180)),
            navigatorWell: .init(fill: oklch(0.965, 0.015, 245), bevel: .none)
        )
    )

    /// The existing night palette, expressed in the perceptual coordinates it was measured to.
    /// Its displayed colours remain within one Delta E of the previous values; the source now
    /// records lightness, chroma, and hue instead of treating encoded display channels as the
    /// design space.
    private static let threadingDark = AppTheme.Variant(
        roles: [
            .ground: oklch(0.141761, 0.021319, 250.637),
            .surface: oklch(0.196295, 0.038688, 251.311),
            .panel: oklch(0.222204, 0.044380, 251.573),
            .elevated: oklch(0.278481, 0.056376, 249.755),
            .border: oklch(0.400138, 0.058162, 244.494),
            .divider: oklch(0.335281, 0.057992, 242.068),
            .label: oklch(0.955907, 0.014783, 70.887),
            .accent: oklch(0.776078, 0.158539, 59.042),
            .accentMuted: oklch(0.776078, 0.158539, 59.042, alpha: 0.13),
            .controlResting: oklch(0.257564, 0.049251, 248.386),
            .controlHover: oklch(0.339314, 0.061642, 242.957),
            // Selection is a deeper navy rather than diluted orange. Orange remains the
            // action and focus ink, while selected rows stay crisp instead of turning
            // muddy brown over the app's blue surfaces.
            .selection: oklch(0.356897, 0.066545, 241.952),
            .statusPositive: oklch(0.757137, 0.100383, 159.803),
            .statusWarning: oklch(0.766015, 0.117694, 65.666),
            .statusNegative: oklch(0.670404, 0.143983, 26.240),
            .syntaxKeyword: oklch(0.776078, 0.158539, 59.042),
            .syntaxType: oklch(0.789724, 0.076308, 205.349),
            .syntaxString: oklch(0.798882, 0.080142, 118.352),
            .syntaxNumber: oklch(0.815228, 0.078915, 66.341)
        ],
        terminalPalette: TerminalTheme(
            id: TerminalThemeID("app-threading-terminal"),
            name: "Threading",
            foreground: oklch(0.864591, 0.015155, 70.867),
            boldForeground: oklch(1.000000, 0.000000, 0),
            background: oklch(0.141761, 0.021319, 250.637),
            // The palette's own ink, not its orange. A block cursor sits *on* a character,
            // so the accent drew an alarm block over the first letter of queued input.
            cursor: oklch(0.864591, 0.015155, 70.867),
            selection: oklch(0.333692, 0.056003, 239.149),
            black: oklch(0.196295, 0.038688, 251.311),
            red: oklch(0.670404, 0.143983, 26.240),
            green: oklch(0.757137, 0.100383, 159.803),
            yellow: oklch(0.766015, 0.117694, 65.666),
            blue: oklch(0.710473, 0.093066, 244.605),
            magenta: oklch(0.698604, 0.101447, 333.093),
            cyan: oklch(0.789724, 0.076308, 205.349),
            white: oklch(0.864591, 0.015155, 70.867),
            brightBlack: oklch(0.508400, 0.045501, 243.150),
            brightRed: oklch(0.740552, 0.125849, 25.871),
            brightGreen: oklch(0.818889, 0.090747, 157.593),
            brightYellow: oklch(0.829515, 0.105663, 71.917),
            brightBlue: oklch(0.780188, 0.074036, 241.458),
            brightMagenta: oklch(0.773029, 0.088695, 334.769),
            brightCyan: oklch(0.848492, 0.063324, 203.583),
            brightWhite: oklch(0.955907, 0.014783, 70.887)
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
                .init(color: oklch(0.245556, 0.049539, 248.688), position: 0),
                .init(color: oklch(0.196295, 0.038688, 251.311), position: 1)
            ], angleDegrees: 180)),
            navigatorWell: .init(
                fill: oklch(0.182872, 0.034692, 250.860),
                bevel: .none
            )
        )
    )

    /// High-contrast terminal chrome on the live reference's near-black violet stack.
    ///
    /// States its own `controlResting`/`controlHover` rather than letting them derive from the
    /// label: the derivation is `label` at 8%, which is a grey, and a grey control on a neon
    /// theme is how the first pass ended up looking like the same app in a different tint.
    /// Here they are the accent, held far down — so every hoverable thing glows faintly green
    /// instead of going pale.
    public static let cyberpunk = AppTheme(
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
    public static let swissMinimalist = AppTheme(
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

    /// The default authoring path for palettes designed here. OKLCH keeps lightness and chroma
    /// perceptual; `NSColor.oklch` reduces only chroma when a request falls outside sRGB.
    public static func oklch(
        _ lightness: CGFloat,
        _ chroma: CGFloat,
        _ hueDegrees: CGFloat,
        alpha: CGFloat = 1
    ) -> NSColor {
        NSColor.oklch(OKLCH(
            lightness: lightness,
            chroma: chroma,
            hueDegrees: hueDegrees,
            alpha: alpha
        ))
    }

    /// Exact-source palettes remain hexadecimal: historical pixels and published community
    /// schemes are display values to reproduce, not colours Threading is free to redesign.
    /// Force-unwrapped deliberately so a malformed source value fails immediately.
    public static func hex(_ value: String) -> NSColor {
        guard let color = NSColor(hex: value) else {
            preconditionFailure("Malformed stock theme colour: \(value)")
        }
        return color
    }
}
