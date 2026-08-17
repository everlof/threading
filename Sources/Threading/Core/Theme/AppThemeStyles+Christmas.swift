import AppKit

/// The one seasonal style, and the first stock theme that authors **both** appearances.
///
/// Every other style in the catalogue is named after a design movement and pins a single
/// appearance, because a movement has one. Christmas does not: the season is snow in daylight
/// and fir in the dark, and picking one of those would have made half the year's users wrong.
/// So it states a light variant and a dark one and leaves `mode` adaptive — the same red and
/// the same gold seen against paper by day and against evergreen by night.
///
/// The pairing is the identity rather than the hue. Red alone is Swiss Minimalist's accent
/// already; what makes this read as Christmas is **red against green with gold between them**,
/// which is why the two are split across roles that are always visible at once: the accent is
/// holly red, `controlResting` is a fir wash, and the warning/string roles carry candlelight
/// gold. A control that rests green and lifts red is the whole style in one hover.
extension AppThemeStyles {

    static let christmas = AppTheme(
        id: AppThemeID("christmas"),
        name: "Christmas",
        mode: .system,
        summary: "Holly red on fir green, candlelight gold, snow by day and evergreen by night.",
        variants: [
            .light: christmasDaylight,
            .dark: christmasNight
        ]
    )

    /// Snow, not paper. The ground carries a trace of green so the fir lines drawn on it read as
    /// the same material rather than as ink on an unrelated white.
    private static let christmasDaylight = AppTheme.Variant(
        roles: [
            .ground: hex("#F2F7F3"),
            .surface: hex("#DCE9DE"),
            .panel: hex("#FFFFFF"),
            .elevated: hex("#FFFFFF"),
            // Fir, at full strength. A pale system hairline would leave the panels floating on
            // snow with nothing holding them — the green rule is what makes a card a card here.
            .border: hex("#14532D"),
            .divider: hex("#14532D33"),
            .label: hex("#0F2419"),
            .accent: hex("#C1121F"),
            .accentMuted: hex("#C1121F30"),
            // Green at rest, red under the pointer: the two colours of the style, spent on the
            // one surface the user makes move.
            .controlResting: hex("#14532D14"),
            .controlHover: hex("#C1121F24"),
            .selection: hex("#C1121F33"),
            .statusPositive: hex("#15803D"),
            .statusWarning: hex("#B07D18"),
            .statusNegative: hex("#C1121F"),
            .syntaxKeyword: hex("#C1121F"),
            .syntaxType: hex("#15803D"),
            .syntaxString: hex("#8A6D1F"),
            .syntaxNumber: hex("#2B5C8A")
        ],
        // The neutrals are a monotone ramp dark enough to read on snow rather than the
        // near-white a light palette conventionally puts at indices 7 and 15 — a CLI that dims
        // its status line to index 7 would otherwise write pale grey on white. Same rule as
        // Swiss Minimalist, arrived at the same way.
        terminalPalette: terminal(
            id: "app-christmas-terminal-light",
            name: "Christmas",
            foreground: "#0F2419",
            // Holly red pulled to the depth of a wreath berry. The theme’s accent itself is
            // the palette’s `red`, so a heading in it would be the colour a program prints an
            // error in; this is the same red, a shade darker than any slot.
            boldForeground: "#7A0A12",
            background: "#F2F7F3",
            cursor: "#0F2419",
            selection: "#D8E7DB",
            ansi: [
                "#0F2419", "#C1121F", "#15803D", "#8A6D1F",
                "#2B5C8A", "#8E3B6B", "#1F6F6B", "#6B7A70",
                "#47564C", "#E2373F", "#2E9E5B", "#B08D2A",
                "#3F7AB0", "#A9548A", "#2E8F8A", "#93A398"
            ]
        ),
        // Baubles: everything is rounder than the app's default, and a faint red halo sits
        // under each panel the way a string of lights sits behind an ornament. The offset is
        // downward so the light reads as coming from above the tree rather than from nowhere.
        material: AppTheme.Material(
            panelRadius: 16,
            controlRadius: 10,
            borderWidth: 1.5,
            glow: AppTheme.Glow(role: .accent, radius: 6, opacity: 0.18, offsetX: 0, offsetY: -2)
        )
    )

    /// Evergreen after dark. The ground is a green dark enough to behave as a ground — a window
    /// backdrop has to recede — with the panels lifted in the same hue so the depth is fir on
    /// fir rather than grey cards on a green wall.
    private static let christmasNight = AppTheme.Variant(
        roles: [
            .ground: hex("#082019"),
            .surface: hex("#0C2A20"),
            .panel: hex("#113328"),
            .elevated: hex("#184232"),
            .border: hex("#2E6B4E"),
            .divider: hex("#2E6B4E66"),
            .label: hex("#EAF4EC"),
            .accent: hex("#FF4D5A"),
            .accentMuted: hex("#FF4D5A2E"),
            .controlResting: hex("#2E6B4E42"),
            .controlHover: hex("#FF4D5A2E"),
            .selection: hex("#FF4D5A3D"),
            .statusPositive: hex("#34D399"),
            .statusWarning: hex("#F2C14E"),
            .statusNegative: hex("#FF4D5A"),
            .syntaxKeyword: hex("#FF4D5A"),
            .syntaxType: hex("#34D399"),
            .syntaxString: hex("#F2C14E"),
            .syntaxNumber: hex("#7FC8F8")
        ],
        terminalPalette: terminal(
            id: "app-christmas-terminal-dark",
            name: "Christmas",
            foreground: "#EAF4EC",
            // Candlelight rather than the candle: the pale end of the theme’s gold, since the
            // gold itself is this palette’s `brightYellow`.
            boldForeground: "#FFEFC2",
            background: "#082019",
            cursor: "#EAF4EC",
            selection: "#14432F",
            ansi: [
                "#113328", "#E5484D", "#2FBF71", "#E3B23C",
                "#5AA9E6", "#C77DBA", "#4FD1C5", "#B7C7BC",
                "#2A5343", "#FF6B70", "#6FE39C", "#F5D06A",
                "#8CC7F5", "#E0A3D6", "#86E7DE", "#F2FBF4"
            ]
        ),
        // The same ornament geometry, and the halo turned up: on a dark ground a 0.18 shadow is
        // invisible, and the fairy lights are the point of the night variant.
        material: AppTheme.Material(
            panelRadius: 16,
            controlRadius: 10,
            borderWidth: 1,
            glow: AppTheme.Glow(role: .accent, radius: 9, opacity: 0.32, offsetX: 0, offsetY: 0)
        )
    )
}
