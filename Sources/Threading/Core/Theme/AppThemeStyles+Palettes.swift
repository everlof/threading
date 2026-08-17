import AppKit

/// The palette-first styles: themes that are a colour language rather than a chrome.
///
/// Everything before this family changes the window's *material* — a takeover frame, a printed
/// rule system, a glow. These five keep the app's modern silhouette and spend their whole
/// identity on colour, which is what most terminal users mean by "a theme": the ground, the ink,
/// one accent, and a sixteen-colour palette that agrees with them. Each still states a geometry
/// of its own (the silhouette gate refuses a pure tint), but the differences are a few points of
/// radius, never new furniture.
///
/// Provenance is split, deliberately. Pure Black and Cappuccino are our own palettes, authored
/// like every design-movement style. Solarized, Nord, and Dracula are the community's: their
/// identity *is* their exact values, so the values are reproduced from the published MIT-licensed
/// definitions rather than approximated —
/// Solarized © Ethan Schoonover (MIT, https://ethanschoonover.com/solarized/),
/// Nord © Sven Greb (MIT, https://nordtheme.com),
/// Dracula © Dracula Theme contributors (MIT, https://draculatheme.com).
/// Where a scheme defines fewer surfaces than the app has roles (none of the three states a
/// third panel tone), the missing steps are interpolated inside the scheme's own ramp and said
/// so at the definition.
extension AppThemeStyles {

    /// True black, not the system's elevated grey — the ground a self-lit display turns off.
    ///
    /// The style is *absence*: an achromatic chrome whose accent is white, so nothing in the
    /// window competes with the content's own colour. The syntax roles are a grey ramp for the
    /// same reason — code keeps its hierarchy in lightness, and the terminal palette below is
    /// where colour lives. The ANSI hues are kept slightly muted because fully saturated
    /// primaries bloom against true black.
    static let pureBlack = AppTheme(
        id: AppThemeID("pure-black"),
        name: "Pure Black",
        mode: .dark,
        summary: "True black, white ink, colour only where a program asks for it.",
        roles: [
            .ground: hex("#000000"),
            .surface: hex("#0A0A0A"),
            .panel: hex("#101010"),
            .elevated: hex("#161616"),
            .border: hex("#2E2E2E"),
            .divider: hex("#FFFFFF").withAlphaComponent(0.10),
            .label: hex("#F2F2F2"),
            .accent: hex("#FFFFFF"),
            .accentMuted: hex("#FFFFFF").withAlphaComponent(0.10),
            .controlResting: hex("#FFFFFF").withAlphaComponent(0.05),
            .controlHover: hex("#FFFFFF").withAlphaComponent(0.10),
            // Stated opaque — the white wash it renders to over this chrome. A translucent
            // white selection is invisible on any light ground it is composited over, and a
            // selection's job is to read wherever the row is painted.
            .selection: hex("#292929"),
            .statusPositive: hex("#4CC38A"),
            .statusWarning: hex("#E5B454"),
            .statusNegative: hex("#E5484D"),
            .syntaxKeyword: hex("#F2F2F2"),
            .syntaxType: hex("#C7C7C7"),
            .syntaxString: hex("#8C8C8C"),
            .syntaxNumber: hex("#A8A8A8")
        ],
        terminalPalette: terminal(
            id: "app-pure-black-terminal",
            name: "Pure Black",
            foreground: "#B3B3B3",
            boldForeground: "#FFFFFF",  // The one colour this theme allows itself
            background: "#000000",
            cursor: "#B3B3B3",
            selection: "#333333",
            ansi: [
                "#1A1A1A", "#E5484D", "#4CC38A", "#E5B454",
                "#6E9FDB", "#C586C0", "#5BB8C4", "#B3B3B3",
                "#666666", "#F0716C", "#74D99F", "#F2C97D",
                "#91BDF0", "#D9A6E8", "#7FD6E0", "#F2F2F2"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 8,
            controlRadius: 5,
            borderWidth: 1
        )
    )

    /// Coffee, both ways up: steamed milk with espresso ink by day, espresso with cream ink by
    /// night, caramel as the accent in both. Adaptive like Christmas and for the same reason —
    /// the drink is the identity, not one of its two grounds.
    static let cappuccino = AppTheme(
        id: AppThemeID("cappuccino"),
        name: "Cappuccino",
        mode: .system,
        summary: "Steamed milk and espresso, caramel accent, foam by day and roast by night.",
        variants: [
            .light: cappuccinoLatte,
            .dark: cappuccinoRoast
        ]
    )

    private static let cappuccinoLatte = AppTheme.Variant(
        roles: [
            .ground: hex("#F3EBE2"),
            .surface: hex("#EAE0D4"),
            .panel: hex("#FBF6F0"),
            .elevated: hex("#FFFFFF"),
            .border: hex("#C9B8A4"),
            .divider: hex("#3B2E25").withAlphaComponent(0.14),
            .label: hex("#3B2E25"),
            .accent: hex("#A9622D"),
            .accentMuted: hex("#A9622D").withAlphaComponent(0.16),
            .controlResting: hex("#3B2E25").withAlphaComponent(0.05),
            .controlHover: hex("#A9622D").withAlphaComponent(0.14),
            .selection: hex("#A9622D").withAlphaComponent(0.22),
            .statusPositive: hex("#55743D"),
            .statusWarning: hex("#8A6A10"),
            .statusNegative: hex("#B3402F"),
            .syntaxKeyword: hex("#8C4A22"),
            .syntaxType: hex("#4C6B94"),
            .syntaxString: hex("#55743D"),
            .syntaxNumber: hex("#8A5474")
        ],
        // The neutrals are the monotone ramp a light palette needs here — dark enough to read
        // on cream, ordered black → brightBlack → white → brightWhite. Same rule as Swiss
        // Minimalist and Christmas daylight, arrived at the same way.
        terminalPalette: terminal(
            id: "app-cappuccino-terminal-light",
            name: "Cappuccino",
            foreground: "#3B2E25",
            boldForeground: "#120D09",  // Espresso, the darkest roast in the cup
            background: "#F3EBE2",
            cursor: "#3B2E25",
            selection: "#E6D7C4",
            ansi: [
                "#3B2E25", "#B3402F", "#55743D", "#8A6A10",
                "#4C6B94", "#8A5474", "#3E7A76", "#7A6D5F",
                "#5C5045", "#C75A44", "#6B8A50", "#A3831F",
                "#5F81AD", "#A16A8C", "#52948F", "#9C8E7E"
            ]
        ),
        material: cappuccinoMaterial
    )

    private static let cappuccinoRoast = AppTheme.Variant(
        roles: [
            .ground: hex("#171210"),
            .surface: hex("#1E1713"),
            .panel: hex("#251D18"),
            .elevated: hex("#2D241E"),
            .border: hex("#4A3A2E"),
            .divider: hex("#EFE3D5").withAlphaComponent(0.12),
            .label: hex("#EFE3D5"),
            .accent: hex("#D08B4C"),
            .accentMuted: hex("#D08B4C").withAlphaComponent(0.16),
            .controlResting: hex("#EFE3D5").withAlphaComponent(0.06),
            .controlHover: hex("#D08B4C").withAlphaComponent(0.16),
            .selection: hex("#D08B4C").withAlphaComponent(0.26),
            .statusPositive: hex("#7FB069"),
            .statusWarning: hex("#E0B458"),
            .statusNegative: hex("#E06E5A"),
            .syntaxKeyword: hex("#D08B4C"),
            .syntaxType: hex("#8FB5A8"),
            .syntaxString: hex("#C4B28A"),
            .syntaxNumber: hex("#D9A97E")
        ],
        terminalPalette: terminal(
            id: "app-cappuccino-terminal-dark",
            name: "Cappuccino",
            foreground: "#CFC0B0",
            boldForeground: "#FFF7EC",  // Steamed milk; the body steps to the ramp’s white
            background: "#171210",
            cursor: "#CFC0B0",
            selection: "#3D2F24",
            ansi: [
                "#251D18", "#E06E5A", "#7FB069", "#E0B458",
                "#7E9CC0", "#B98AA6", "#7FB8AE", "#CFC0B0",
                "#6B5B4C", "#F08D77", "#98C687", "#EDC97E",
                "#9BB5D6", "#CFA5BE", "#99CEC5", "#EFE3D5"
            ]
        ),
        material: cappuccinoMaterial
    )

    /// Rounder than the app's default — the foam, not the cup.
    private static let cappuccinoMaterial = AppTheme.Material(
        panelRadius: 14,
        controlRadius: 9,
        borderWidth: 1
    )

    /// Ethan Schoonover's palette, exactly. The sixteen ANSI values and both grounds are the
    /// published ones — Solarized's identity is the values, and the contrast floor's 3:1 was
    /// chosen back when the gate was designed precisely so this palette passes as authored.
    /// Both variants share one ANSI table, as the original does: the bright slots carry the
    /// base tones, so `brightBlack` *is* the dark ground and sharing is the design, not a
    /// shortcut. Only `panel`/`elevated` are ours, interpolated inside the base ramp because
    /// the scheme states two background tones and the app has four surface roles.
    static let solarized = AppTheme(
        id: AppThemeID("solarized"),
        name: "Solarized",
        mode: .system,
        summary: "Ethan Schoonover's sixteen, precision light and dark on shared hues.",
        variants: [
            .light: solarizedLight,
            .dark: solarizedDark
        ]
    )

    private static let solarizedLight = AppTheme.Variant(
        roles: [
            .ground: hex("#FDF6E3"),
            .surface: hex("#EEE8D5"),
            .panel: hex("#FFFCF2"),
            .elevated: hex("#FFFFFF"),
            .border: hex("#93A1A1"),
            .divider: hex("#586E75").withAlphaComponent(0.25),
            // The chrome label is the palette's own ANSI ink (base02), not the terminal's
            // base00 body tone. The app holds its own chrome to AA on selected rows
            // (`SelectionSurface`), a floor the muted base tones cannot reach over base2 —
            // the latitude the 3:1 gate extends to Solarized is for the terminal, where the
            // canonical foreground below stays exactly as published.
            .label: hex("#073642"),
            .accent: hex("#268BD2"),
            .accentMuted: hex("#268BD2").withAlphaComponent(0.14),
            .controlResting: hex("#657B83").withAlphaComponent(0.06),
            .controlHover: hex("#268BD2").withAlphaComponent(0.12),
            .selection: hex("#268BD2").withAlphaComponent(0.20),
            .statusPositive: hex("#859900"),
            .statusWarning: hex("#B58900"),
            .statusNegative: hex("#DC322F"),
            .syntaxKeyword: hex("#859900"),
            .syntaxType: hex("#268BD2"),
            .syntaxString: hex("#2AA198"),
            .syntaxNumber: hex("#D33682")
        ],
        terminalPalette: terminal(
            id: "app-solarized-terminal-light",
            name: "Solarized",
            foreground: "#657B83",
            boldForeground: "#073642",  // base02
            background: "#FDF6E3",
            cursor: "#657B83",
            selection: "#EEE8D5",
            ansi: solarizedANSI
        ),
        material: solarizedMaterial
    )

    private static let solarizedDark = AppTheme.Variant(
        roles: [
            .ground: hex("#002B36"),
            .surface: hex("#073642"),
            .panel: hex("#0B4354"),
            .elevated: hex("#114E60"),
            .border: hex("#586E75"),
            .divider: hex("#586E75").withAlphaComponent(0.40),
            // base2 — the palette's ANSI white — for the same reason the light variant's
            // label is base02: chrome text answers to the app's AA floor, terminal text to
            // the scheme's published base0.
            .label: hex("#EEE8D5"),
            .accent: hex("#268BD2"),
            .accentMuted: hex("#268BD2").withAlphaComponent(0.15),
            .controlResting: hex("#93A1A1").withAlphaComponent(0.06),
            .controlHover: hex("#268BD2").withAlphaComponent(0.14),
            .selection: hex("#268BD2").withAlphaComponent(0.22),
            .statusPositive: hex("#859900"),
            .statusWarning: hex("#B58900"),
            .statusNegative: hex("#DC322F"),
            .syntaxKeyword: hex("#859900"),
            .syntaxType: hex("#268BD2"),
            .syntaxString: hex("#2AA198"),
            .syntaxNumber: hex("#D33682")
        ],
        terminalPalette: terminal(
            id: "app-solarized-terminal-dark",
            name: "Solarized",
            foreground: "#839496",
            boldForeground: "#EEE8D5",  // base2
            background: "#002B36",
            cursor: "#839496",
            selection: "#073642",
            ansi: solarizedANSI
        ),
        material: solarizedMaterial
    )

    private static let solarizedANSI = [
        "#073642", "#DC322F", "#859900", "#B58900",
        "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
        "#002B36", "#CB4B16", "#586E75", "#657B83",
        "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"
    ]

    /// Squarer than the app's default — the precision half of Solarized's own brief.
    private static let solarizedMaterial = AppTheme.Material(
        panelRadius: 6,
        controlRadius: 4,
        borderWidth: 1
    )

    /// Sven Greb's arctic palette, exactly: the four Polar Night tones are the surface ramp,
    /// Snow Storm is the ink, and Frost carries the accent and syntax. The published terminal
    /// mapping repeats the aurora hues in the bright slots, so it is kept as published rather
    /// than lightened.
    static let nord = AppTheme(
        id: AppThemeID("nord"),
        name: "Nord",
        mode: .dark,
        summary: "Polar night surfaces, snow storm ink, frost blue accents.",
        roles: [
            .ground: hex("#2E3440"),
            .surface: hex("#3B4252"),
            .panel: hex("#434C5E"),
            .elevated: hex("#4C566A"),
            .border: hex("#4C566A"),
            .divider: hex("#4C566A").withAlphaComponent(0.60),
            .label: hex("#D8DEE9"),
            .accent: hex("#88C0D0"),
            .accentMuted: hex("#88C0D0").withAlphaComponent(0.14),
            .controlResting: hex("#D8DEE9").withAlphaComponent(0.05),
            .controlHover: hex("#88C0D0").withAlphaComponent(0.14),
            .selection: hex("#88C0D0").withAlphaComponent(0.22),
            .statusPositive: hex("#A3BE8C"),
            .statusWarning: hex("#EBCB8B"),
            .statusNegative: hex("#BF616A"),
            .syntaxKeyword: hex("#81A1C1"),
            .syntaxType: hex("#8FBCBB"),
            .syntaxString: hex("#A3BE8C"),
            .syntaxNumber: hex("#B48EAD")
        ],
        terminalPalette: terminal(
            id: "app-nord-terminal",
            name: "Nord",
            foreground: "#D8DEE9",
            // nord12, the one Aurora tone the published ANSI mapping leaves unspent. Every
            // Nord colour bright enough to clear AA on nord0 is already a slot or a Snow
            // Storm tone the body cannot be told from; see the sweep’s stated exception.
            boldForeground: "#D08770",
            background: "#2E3440",
            cursor: "#D8DEE9",
            selection: "#434C5E",
            ansi: [
                "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
                "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
                "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 10,
            controlRadius: 6,
            borderWidth: 1
        )
    )

    /// The Dracula spec, exactly: background, current line, comment blue, and the six named
    /// hues. The opaque `selection` is the one deliberate departure from this family's
    /// translucent accent washes — #44475A "current line" *is* how Dracula marks the selected
    /// thing, so a purple wash would be a different theme wearing the name.
    static let dracula = AppTheme(
        id: AppThemeID("dracula"),
        name: "Dracula",
        mode: .dark,
        summary: "The classic dark violet, pink and cyan on a midnight ground.",
        roles: [
            .ground: hex("#282A36"),
            .surface: hex("#2E3040"),
            .panel: hex("#343746"),
            .elevated: hex("#44475A"),
            .border: hex("#44475A"),
            .divider: hex("#6272A4").withAlphaComponent(0.40),
            .label: hex("#F8F8F2"),
            .accent: hex("#BD93F9"),
            .accentMuted: hex("#BD93F9").withAlphaComponent(0.15),
            .controlResting: hex("#F8F8F2").withAlphaComponent(0.05),
            .controlHover: hex("#BD93F9").withAlphaComponent(0.12),
            .selection: hex("#44475A"),
            .statusPositive: hex("#50FA7B"),
            .statusWarning: hex("#F1FA8C"),
            .statusNegative: hex("#FF5555"),
            .syntaxKeyword: hex("#FF79C6"),
            .syntaxType: hex("#8BE9FD"),
            .syntaxString: hex("#F1FA8C"),
            .syntaxNumber: hex("#BD93F9")
        ],
        terminalPalette: terminal(
            id: "app-dracula-terminal",
            name: "Dracula",
            foreground: "#F8F8F2",
            // Dracula publishes Orange and maps it to no ANSI slot, which is exactly what a
            // heading needs: the scheme’s own colour, and not one a program can print.
            boldForeground: "#FFB86C",
            background: "#282A36",
            cursor: "#F8F8F2",
            selection: "#44475A",
            ansi: [
                "#21222C", "#FF5555", "#50FA7B", "#F1FA8C",
                "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5",
                "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 9,
            controlRadius: 6,
            borderWidth: 1
        )
    )
}
