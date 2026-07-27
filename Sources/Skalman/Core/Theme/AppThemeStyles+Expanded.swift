import AppKit

/// The expanded stock catalogue.
///
/// These are not palette swaps. Each uses the material vocabulary as part of its identity:
/// hard offset print shadows, soft clay lift, restrained editorial rules, or luminous halos.
/// The terminal palettes are stated alongside the chrome so “Follow App Theme” is a designed
/// pairing rather than an ANSI approximation generated after the fact.
extension AppThemeStyles {

    static let bauhaus = AppTheme(
        id: AppThemeID("bauhaus"),
        name: "Bauhaus",
        mode: .light,
        summary: "Primary geometry on warm paper, with hard black construction lines.",
        roles: [
            .ground: hex("#F4EBDD"),
            .surface: hex("#E7DCC8"),
            .panel: hex("#FFF9EC"),
            .elevated: hex("#FFFFFF"),
            .border: hex("#171717"),
            .divider: hex("#171717"),
            .label: hex("#171717"),
            .accent: hex("#D62828"),
            .accentMuted: hex("#D6282838"),
            .controlResting: hex("#F2C23055"),
            .controlHover: hex("#1E5AA855"),
            .selection: hex("#D628284A"),
            .statusPositive: hex("#197149"),
            .statusWarning: hex("#B56A00"),
            .statusNegative: hex("#D62828"),
            .syntaxKeyword: hex("#D62828"),
            .syntaxType: hex("#1E5AA8"),
            .syntaxString: hex("#197149"),
            .syntaxNumber: hex("#B56A00")
        ],
        terminalPalette: terminal(
            id: "app-bauhaus-terminal",
            name: "Bauhaus",
            foreground: "#171717",
            background: "#F4EBDD",
            cursor: "#171717",
            selection: "#E7C9B5",
            ansi: [
                "#171717", "#B42318", "#197149", "#9A6700",
                "#1E5AA8", "#7A3E9D", "#16717A", "#6B655B",
                "#4A4741", "#D62828", "#238B5B", "#C88900",
                "#2B6FC0", "#9B51B8", "#218B95", "#918A7D"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 0,
            controlRadius: 0,
            borderWidth: 2,
            glow: AppTheme.Glow(
                role: .label, radius: 0, opacity: 0.72, offsetX: 4, offsetY: -4
            )
        )
    )

    static let artDeco = AppTheme(
        id: AppThemeID("art-deco"),
        name: "Art Deco",
        mode: .dark,
        summary: "Midnight lacquer, brass rules, and restrained jewel tones.",
        roles: [
            .ground: hex("#070A10"),
            .surface: hex("#0D1320"),
            .panel: hex("#151D2B"),
            .elevated: hex("#1B2638"),
            .border: hex("#C7A665"),
            .divider: hex("#C7A66566"),
            .label: hex("#F4E8CC"),
            .accent: hex("#D7B56D"),
            .accentMuted: hex("#D7B56D2E"),
            .controlResting: hex("#D7B56D18"),
            .controlHover: hex("#D7B56D32"),
            .selection: hex("#0F8B8D66"),
            .statusPositive: hex("#4EB59D"),
            .statusWarning: hex("#E2B95F"),
            .statusNegative: hex("#D45B6B"),
            .syntaxKeyword: hex("#D7B56D"),
            .syntaxType: hex("#71B7C4"),
            .syntaxString: hex("#8EC9A9"),
            .syntaxNumber: hex("#D98CB3")
        ],
        terminalPalette: terminal(
            id: "app-art-deco-terminal",
            name: "Art Deco",
            foreground: "#F4E8CC",
            background: "#070A10",
            cursor: "#F4E8CC",
            selection: "#29404D",
            ansi: [
                "#151D2B", "#C45564", "#56A98F", "#C9A451",
                "#568FA8", "#A975A2", "#4BA0A5", "#C9BEA4",
                "#596273", "#E27482", "#77C7AA", "#E8C46E",
                "#79B2CC", "#C997C0", "#71C6CB", "#F4E8CC"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 1,
            controlRadius: 1,
            borderWidth: 1.5,
            glow: AppTheme.Glow(
                role: .accent, radius: 4, opacity: 0.18, offsetX: 0, offsetY: -2
            ),
            typeface: .serif
        )
    )

    static let neoBrutalism = AppTheme(
        id: AppThemeID("neo-brutalism"),
        name: "Neo Brutalism",
        mode: .light,
        summary: "Cream stock, loud blocks, thick ink, and unapologetic hard shadows.",
        roles: [
            .ground: hex("#FFF4D6"),
            .surface: hex("#FFD84D"),
            .panel: hex("#FFFDF6"),
            .elevated: hex("#C7B8FF"),
            .border: hex("#101010"),
            .divider: hex("#101010"),
            .label: hex("#101010"),
            .accent: hex("#0057FF"),
            .accentMuted: hex("#0057FF35"),
            .controlResting: hex("#FF5C5C55"),
            .controlHover: hex("#00C2A855"),
            .selection: hex("#0057FF4D"),
            .statusPositive: hex("#087F5B"),
            .statusWarning: hex("#A85D00"),
            .statusNegative: hex("#D92D20"),
            .syntaxKeyword: hex("#D92D20"),
            .syntaxType: hex("#0057FF"),
            .syntaxString: hex("#087F5B"),
            .syntaxNumber: hex("#7A36C2")
        ],
        terminalPalette: terminal(
            id: "app-neo-brutalism-terminal",
            name: "Neo Brutalism",
            foreground: "#101010",
            background: "#FFF4D6",
            cursor: "#101010",
            selection: "#C8D6FF",
            ansi: [
                "#101010", "#D92D20", "#087F5B", "#A85D00",
                "#0057FF", "#7A36C2", "#007A78", "#6B6250",
                "#4A4438", "#FF3B30", "#0FA779", "#D57A00",
                "#397CFF", "#9D5CE0", "#00A3A0", "#948A76"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 0,
            controlRadius: 0,
            borderWidth: 3,
            glow: AppTheme.Glow(
                role: .label, radius: 0, opacity: 0.9, offsetX: 5, offsetY: -5
            )
        )
    )

    static let claymorphism = AppTheme(
        id: AppThemeID("claymorphism"),
        name: "Claymorphism",
        mode: .light,
        summary: "Lavender clay, generous curves, and softly lifted candy controls.",
        roles: [
            .ground: hex("#F2E9FF"),
            .surface: hex("#E7D8FA"),
            .panel: hex("#FFF8FF"),
            .elevated: hex("#FFFFFF"),
            .border: hex("#8A63B833"),
            .divider: hex("#76549A35"),
            .label: hex("#352743"),
            .accent: hex("#7048C8"),
            .accentMuted: hex("#7048C82E"),
            .controlResting: hex("#E7C9FF"),
            .controlHover: hex("#D8B4FE"),
            .selection: hex("#7048C83D"),
            .statusPositive: hex("#287A55"),
            .statusWarning: hex("#A65F00"),
            .statusNegative: hex("#C2415D"),
            .syntaxKeyword: hex("#7048C8"),
            .syntaxType: hex("#3274A8"),
            .syntaxString: hex("#287A55"),
            .syntaxNumber: hex("#B44B7A")
        ],
        terminalPalette: terminal(
            id: "app-claymorphism-terminal",
            name: "Claymorphism",
            foreground: "#352743",
            background: "#F2E9FF",
            cursor: "#352743",
            selection: "#DCC8F3",
            ansi: [
                "#352743", "#B43E57", "#287A55", "#956000",
                "#3274A8", "#7048C8", "#307F86", "#756A7E",
                "#5D5068", "#D75870", "#3D9970", "#BB7B0B",
                "#4E92C7", "#9169E0", "#49A0A6", "#9B8FA3"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 22,
            controlRadius: 14,
            borderWidth: 1.5,
            glow: AppTheme.Glow(
                role: .accent, radius: 7, opacity: 0.20, offsetX: 0, offsetY: -5
            ),
            typeface: .rounded
        )
    )

    static let vaporwave = AppTheme(
        id: AppThemeID("vaporwave"),
        name: "Vaporwave",
        mode: .dark,
        summary: "Ultraviolet night, hot pink signal, and cyan afterglow.",
        roles: [
            .ground: hex("#120826"),
            .surface: hex("#1D0E3D"),
            .panel: hex("#2A1553"),
            .elevated: hex("#382069"),
            .border: hex("#8A5CF6"),
            .divider: hex("#56DFFC55"),
            .label: hex("#FFF1FF"),
            .accent: hex("#FF5FD2"),
            .accentMuted: hex("#FF5FD233"),
            .controlResting: hex("#56DFFC1F"),
            .controlHover: hex("#FF5FD238"),
            .selection: hex("#56DFFC45"),
            .statusPositive: hex("#5EF2C2"),
            .statusWarning: hex("#FFD166"),
            .statusNegative: hex("#FF5F7E"),
            .syntaxKeyword: hex("#FF5FD2"),
            .syntaxType: hex("#56DFFC"),
            .syntaxString: hex("#5EF2C2"),
            .syntaxNumber: hex("#FFD166")
        ],
        terminalPalette: terminal(
            id: "app-vaporwave-terminal",
            name: "Vaporwave",
            foreground: "#FFF1FF",
            background: "#120826",
            cursor: "#FFF1FF",
            selection: "#403168",
            ansi: [
                "#2A1553", "#FF5F7E", "#5EF2C2", "#FFD166",
                "#5A8CFF", "#FF5FD2", "#56DFFC", "#C9B8D8",
                "#735A91", "#FF86A0", "#88FFD8", "#FFE39A",
                "#85ACFF", "#FF8DDF", "#8BEAFF", "#FFF1FF"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 10,
            controlRadius: 8,
            borderWidth: 1,
            glow: AppTheme.Glow(
                role: .accent, radius: 9, opacity: 0.30
            ),
            typeface: .monospaced
        )
    )

    static let newsprint = AppTheme(
        id: AppThemeID("newsprint"),
        name: "Newsprint",
        mode: .light,
        summary: "Warm stock, dense ink, editorial red, and offset presswork.",
        roles: [
            .ground: hex("#EFE8D5"),
            .surface: hex("#E4DCC7"),
            .panel: hex("#FAF5E8"),
            .elevated: hex("#FFFDF7"),
            .border: hex("#282621"),
            .divider: hex("#28262166"),
            .label: hex("#1D1B18"),
            .accent: hex("#982F2F"),
            .accentMuted: hex("#982F2F28"),
            .controlResting: hex("#28262112"),
            .controlHover: hex("#982F2F22"),
            .selection: hex("#B85C4240"),
            .statusPositive: hex("#386641"),
            .statusWarning: hex("#9C5A16"),
            .statusNegative: hex("#982F2F"),
            .syntaxKeyword: hex("#982F2F"),
            .syntaxType: hex("#345B77"),
            .syntaxString: hex("#386641"),
            .syntaxNumber: hex("#7D4E57")
        ],
        terminalPalette: terminal(
            id: "app-newsprint-terminal",
            name: "Newsprint",
            foreground: "#1D1B18",
            background: "#EFE8D5",
            cursor: "#1D1B18",
            selection: "#D8CBB4",
            ansi: [
                "#1D1B18", "#982F2F", "#386641", "#8A5A16",
                "#345B77", "#7D4E57", "#3D6B6D", "#6C675C",
                "#4D4941", "#B64646", "#4E7E57", "#A77329",
                "#4D7895", "#986878", "#568486", "#938C7C"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 0,
            controlRadius: 0,
            borderWidth: 1.5,
            glow: AppTheme.Glow(
                role: .label, radius: 0, opacity: 0.18, offsetX: 2, offsetY: -2
            ),
            typeface: .serif
        )
    )

    static let botanical = AppTheme(
        id: AppThemeID("botanical"),
        name: "Botanical",
        mode: .light,
        summary: "Herbarium greens, quiet parchment, and softly rounded natural forms.",
        roles: [
            .ground: hex("#EDF2E7"),
            .surface: hex("#DFE8D9"),
            .panel: hex("#F8FAF3"),
            .elevated: hex("#FFFFFF"),
            .border: hex("#58705B"),
            .divider: hex("#58705B55"),
            .label: hex("#203124"),
            .accent: hex("#356B46"),
            .accentMuted: hex("#356B4630"),
            .controlResting: hex("#8FAF7D30"),
            .controlHover: hex("#6F966044"),
            .selection: hex("#5C8A6040"),
            .statusPositive: hex("#2E7D4F"),
            .statusWarning: hex("#9B671A"),
            .statusNegative: hex("#A5413F"),
            .syntaxKeyword: hex("#356B46"),
            .syntaxType: hex("#4F6F88"),
            .syntaxString: hex("#6A7338"),
            .syntaxNumber: hex("#8A5B45")
        ],
        terminalPalette: terminal(
            id: "app-botanical-terminal",
            name: "Botanical",
            foreground: "#203124",
            background: "#EDF2E7",
            cursor: "#203124",
            selection: "#CEDCC8",
            ansi: [
                "#203124", "#A5413F", "#2E7D4F", "#8A651F",
                "#4F6F88", "#7D5472", "#477779", "#6D786C",
                "#4D5E50", "#C05A57", "#459666", "#A78032",
                "#6688A1", "#966E89", "#609193", "#94A092"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 18,
            controlRadius: 10,
            borderWidth: 1,
            glow: AppTheme.Glow(
                role: .accent, radius: 7, opacity: 0.12, offsetX: 0, offsetY: -3
            ),
            typeface: .serif
        )
    )

    static let industrial = AppTheme(
        id: AppThemeID("industrial"),
        name: "Industrial",
        mode: .dark,
        summary: "Gunmetal structure, safety amber, and compact machined edges.",
        roles: [
            .ground: hex("#101315"),
            .surface: hex("#181D20"),
            .panel: hex("#23292D"),
            .elevated: hex("#2C3439"),
            .border: hex("#7B858B"),
            .divider: hex("#7B858B55"),
            .label: hex("#E8E3D8"),
            .accent: hex("#F5A623"),
            .accentMuted: hex("#F5A62330"),
            .controlResting: hex("#AAB2B71A"),
            .controlHover: hex("#F5A62330"),
            .selection: hex("#F5A62345"),
            .statusPositive: hex("#65B87A"),
            .statusWarning: hex("#F5A623"),
            .statusNegative: hex("#E35D5B"),
            .syntaxKeyword: hex("#F5A623"),
            .syntaxType: hex("#78A7B8"),
            .syntaxString: hex("#8DBD75"),
            .syntaxNumber: hex("#D88A6A")
        ],
        terminalPalette: terminal(
            id: "app-industrial-terminal",
            name: "Industrial",
            foreground: "#E8E3D8",
            background: "#101315",
            cursor: "#E8E3D8",
            selection: "#3C3526",
            ansi: [
                "#23292D", "#D65351", "#65A977", "#C58A2C",
                "#638D9D", "#9B718E", "#5F9997", "#B8B3AA",
                "#5F686D", "#EF7472", "#83C894", "#F5B84D",
                "#82ADBD", "#BA91AE", "#7BB8B6", "#E8E3D8"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 2,
            controlRadius: 2,
            borderWidth: 2,
            glow: AppTheme.Glow(
                role: .label, radius: 0, opacity: 0.45, offsetX: 3, offsetY: -3
            )
        )
    )

    /// Shared with the seasonal style in `AppThemeStyles+Christmas.swift`, which is why this is
    /// internal rather than private to this file.
    static func terminal(
        id: String,
        name: String,
        foreground: String,
        background: String,
        cursor: String,
        selection: String,
        ansi: [String]
    ) -> TerminalTheme {
        precondition(ansi.count == 16, "\(name) must state all sixteen ANSI colours")
        let colors = ansi.map(hex)
        return TerminalTheme(
            id: TerminalThemeID(id),
            name: name,
            foreground: hex(foreground),
            background: hex(background),
            cursor: hex(cursor),
            selection: hex(selection),
            black: colors[0],
            red: colors[1],
            green: colors[2],
            yellow: colors[3],
            blue: colors[4],
            magenta: colors[5],
            cyan: colors[6],
            white: colors[7],
            brightBlack: colors[8],
            brightRed: colors[9],
            brightGreen: colors[10],
            brightYellow: colors[11],
            brightBlue: colors[12],
            brightMagenta: colors[13],
            brightCyan: colors[14],
            brightWhite: colors[15]
        )
    }
}
