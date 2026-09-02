import AppKit

/// The expanded stock catalogue.
///
/// These are not palette swaps. Each uses the material vocabulary as part of its identity:
/// hard offset print shadows, soft clay lift, restrained editorial rules, or luminous halos.
/// The terminal palettes are stated alongside the chrome so “Follow App Theme” is a designed
/// pairing rather than an ANSI approximation generated after the fact.
extension AppThemeStyles {

    public static let bauhaus = AppTheme(
        id: AppThemeID("bauhaus"),
        name: "Bauhaus",
        mode: .light,
        summary: "Primary geometry on cool paper, with heavy ink and hard printed lift.",
        roles: [
            // The live rendering is cool #F0F0F0 rather than parchment. White modules carry
            // the black construction lines; red, yellow, and blue are the only strong planes.
            .ground: hex("#F0F0F0"),
            .surface: hex("#FFFFFF"),
            .panel: hex("#FFFFFF"),
            .elevated: hex("#FFFFFF"),
            .border: hex("#000000"),
            .divider: hex("#121212"),
            .label: hex("#121212"),
            .accent: hex("#D02020"),
            .accentMuted: hex("#D0202038"),
            .controlResting: hex("#F0C02055"),
            .controlHover: hex("#1040C055"),
            .selection: hex("#D020204A"),
            .statusPositive: hex("#197149"),
            .statusWarning: hex("#B56A00"),
            .statusNegative: hex("#D02020"),
            .syntaxKeyword: hex("#D02020"),
            .syntaxType: hex("#1040C0"),
            .syntaxString: hex("#197149"),
            .syntaxNumber: hex("#B56A00")
        ],
        terminalPalette: terminal(
            id: "app-bauhaus-terminal",
            name: "Bauhaus",
            foreground: "#121212",
            // The other primary, at ink weight. Red is where the eye goes in this style, but
            // red is also the palette’s own slot; blue is the primary it has left to spend.
            boldForeground: "#0B2C7A",
            background: "#F0F0F0",
            cursor: "#121212",
            selection: "#E7C9B5",
            ansi: [
                "#121212", "#B42318", "#197149", "#9A6700",
                "#1040C0", "#7A3E9D", "#16717A", "#6B655B",
                "#4A4741", "#D02020", "#238B5B", "#C88900",
                "#2B6FC0", "#9B51B8", "#218B95", "#918A7D"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 0,
            controlRadius: 0,
            // Cards on the reference use 4px ink with an 8px hard shadow. Compact controls
            // use the same construction at half scale: 2px ink and their own 4px lift.
            borderWidth: 4,
            controlBorderWidth: 2,
            backdropPattern: AppTheme.Material.BackdropPattern(
                kind: .dots, role: .panel, opacity: 0.20, spacing: 20, lineWidth: 4
            ),
            glow: AppTheme.Glow(
                role: .label, radius: 0, opacity: 1, offsetX: 8, offsetY: -8
            ),
            controlGlow: AppTheme.Glow(
                role: .label, radius: 0, opacity: 1, offsetX: 4, offsetY: -4
            ),
            buttonStyle: AppTheme.Material.ButtonStyle(
                textTransform: .uppercase,
                fontWeight: .bold,
                tracking: 0.6,
                primaryBorderRole: .label,
                pressedOffsetX: 2,
                pressedOffsetY: 2
            ),
            headingStyle: AppTheme.Material.HeadingStyle(fontWeight: .bold),
            fontFamily: "Futura"
        )
    )

    public static let artDeco = AppTheme(
        id: AppThemeID("art-deco"),
        name: "Art Deco",
        mode: .dark,
        summary: "Midnight lacquer, brass rules, and restrained jewel tones.",
        roles: [
            .ground: hex("#0A0A0F"),
            .surface: hex("#050505"),
            .panel: hex("#141414"),
            .elevated: hex("#0A0A0A"),
            .border: hex("#D4AF37"),
            .divider: hex("#D4AF374D"),
            .label: hex("#F2F0E4"),
            .accent: hex("#D4AF37"),
            .accentMuted: hex("#D4AF372E"),
            .controlResting: hex("#D4AF3718"),
            .controlHover: hex("#D4AF3732"),
            .selection: hex("#0F8B8D66"),
            .statusPositive: hex("#4EB59D"),
            .statusWarning: hex("#E2B95F"),
            .statusNegative: hex("#D45B6B"),
            .syntaxKeyword: hex("#D4AF37"),
            .syntaxType: hex("#71B7C4"),
            .syntaxString: hex("#8EC9A9"),
            .syntaxNumber: hex("#D98CB3")
        ],
        terminalPalette: terminal(
            id: "app-art-deco-terminal",
            name: "Art Deco",
            foreground: "#F2F0E4",
            boldForeground: "#D4AF37",  // The theme’s brass, as on its rules and border
            background: "#0A0A0F",
            cursor: "#F2F0E4",
            selection: "#2F2916",
            ansi: [
                "#141414", "#C45564", "#56A98F", "#C9A451",
                "#568FA8", "#A975A2", "#4BA0A5", "#C9BEA4",
                "#596273", "#E27482", "#77C7AA", "#E8C46E",
                "#79B2CC", "#C997C0", "#71C6CB", "#F2F0E4"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 0,
            controlRadius: 0,
            borderWidth: 1,
            backdropPattern: AppTheme.Material.BackdropPattern(
                kind: .diagonalGrid, role: .accent, opacity: 0.03, spacing: 40, lineWidth: 1
            ),
            glow: AppTheme.Glow(
                // Gold elements use centred 10–15px halos, never a drop shadow.
                role: .accent, radius: 7.5, opacity: 0.10
            ),
            controlGlow: AppTheme.Glow(role: .accent, radius: 5, opacity: 0.10),
            buttonStyle: AppTheme.Material.ButtonStyle(
                textTransform: .uppercase,
                fontWeight: .medium,
                fontFamily: "Avenir Next",
                tracking: 1.2,
                primaryTreatment: .outlined
            ),
            headingStyle: AppTheme.Material.HeadingStyle(
                fontFamily: "Avenir Next",
                fontWeight: .regular
            )
        )
    )

    public static let neoBrutalism = AppTheme(
        id: AppThemeID("neo-brutalism"),
        name: "Neo Brutalism",
        mode: .light,
        summary: "Halftone stock, loud blocks, four-point ink, and unapologetic hard shadows.",
        roles: [
            .ground: hex("#FFFDF5"),
            .surface: hex("#C4B5FD"),
            .panel: hex("#FFFFFF"),
            .elevated: hex("#FFD93D"),
            .border: hex("#000000"),
            .divider: hex("#000000"),
            .label: hex("#000000"),
            .accent: hex("#FF6B6B"),
            .accentMuted: hex("#FF6B6B35"),
            .controlResting: hex("#FFD93D80"),
            .controlHover: hex("#C4B5FD80"),
            .selection: hex("#FF6B6B4D"),
            .statusPositive: hex("#087F5B"),
            .statusWarning: hex("#A85D00"),
            .statusNegative: hex("#D92D20"),
            .syntaxKeyword: hex("#D92D20"),
            .syntaxType: hex("#3159C7"),
            .syntaxString: hex("#087F5B"),
            .syntaxNumber: hex("#7A36C2")
        ],
        terminalPalette: terminal(
            id: "app-neo-brutalism-terminal",
            name: "Neo Brutalism",
            foreground: "#333333",
            boldForeground: "#000000",  // Body steps back; the heading keeps the raw black
            background: "#FFFDF5",
            cursor: "#333333",
            selection: "#C8D6FF",
            ansi: [
                "#000000", "#D92D20", "#087F5B", "#A85D00",
                "#3159C7", "#7A36C2", "#007A78", "#6B6250",
                "#4A4438", "#FF3B30", "#0FA779", "#D57A00",
                "#397CFF", "#9D5CE0", "#00A3A0", "#948A76"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 0,
            controlRadius: 0,
            borderWidth: 4,
            backdropPattern: AppTheme.Material.BackdropPattern(
                kind: .dots, role: .label, opacity: 1, spacing: 20, lineWidth: 3
            ),
            glow: AppTheme.Glow(
                // The large modules overwhelmingly use a 12px hard offset; compact controls
                // and badges repeat it at 4px. Keeping those scales separate avoids the old
                // halfway 5px shadow that matched neither.
                role: .label, radius: 0, opacity: 1, offsetX: 12, offsetY: -12
            ),
            popoverStyle: AppTheme.Material.PopoverStyle(
                arrow: .none,
                edge: .material,
                shadow: .material
            ),
            controlGlow: AppTheme.Glow(
                role: .label, radius: 0, opacity: 1, offsetX: 4, offsetY: -4
            ),
            buttonStyle: AppTheme.Material.ButtonStyle(
                textTransform: .uppercase,
                fontWeight: .bold,
                tracking: 0.3,
                primaryBorderRole: .label,
                hoverOffsetX: 4,
                hoverOffsetY: 4,
                pressedOffsetX: 2,
                pressedOffsetY: 2,
                collapseShadowOnHover: true
            ),
            headingStyle: AppTheme.Material.HeadingStyle(fontWeight: .bold)
        )
    )

    public static let claymorphism = AppTheme(
        id: AppThemeID("claymorphism"),
        name: "Claymorphism",
        mode: .light,
        summary: "Lavender clay, pill-soft curves, and directional light over violet shade.",
        roles: [
            // The reference keeps its canvas almost white. The volume comes from light and
            // shade around each object, not from filling every pane saturated purple.
            .ground: hex("#F5F3FF"),
            .surface: hex("#EEEAF7"),
            .panel: hex("#FBFAFF"),
            .elevated: hex("#FFFFFF"),
            .border: hex("#9B8AB81F"),
            // The measured card shadow on the live reference: neutral lavender at 20%, kept
            // separate from the more violet inset shade below.
            .divider: hex("#A096B433"),
            .label: hex("#332F3A"),
            .accent: hex("#7C3AED"),
            .accentMuted: hex("#A78BFA33"),
            .controlResting: hex("#F5F3FF"),
            .controlHover: hex("#EDE9FE"),
            .selection: hex("#A78BFA4D"),
            .statusPositive: hex("#287A55"),
            .statusWarning: hex("#A65F00"),
            .statusNegative: hex("#C2415D"),
            .syntaxKeyword: hex("#7C3AED"),
            .syntaxType: hex("#3274A8"),
            .syntaxString: hex("#287A55"),
            .syntaxNumber: hex("#B44B7A"),
            // A soft bevel reads these as a diagonal inset gradient rather than as the hard
            // pixel rings used by Windows 98: white catches the upper-left, violet settles
            // into the lower-right. Their alpha is part of the material's softness.
            .bevelHighlight: hex("#FFFFFFE6"),
            .bevelShadow: hex("#8B5CF60D")
        ],
        terminalPalette: terminal(
            id: "app-claymorphism-terminal",
            name: "Claymorphism",
            foreground: "#332F3A",
            boldForeground: "#5B21B6",  // A deeper pull of the theme’s violet accent
            background: "#F5F3FF",
            cursor: "#332F3A",
            selection: "#DDD6FE",
            ansi: [
                "#332F3A", "#B43E57", "#287A55", "#956000",
                "#3274A8", "#7C3AED", "#307F86", "#756A7E",
                "#5D5068", "#D75870", "#3D9970", "#BB7B0B",
                "#4E92C7", "#9169E0", "#49A0A6", "#9B8FA3"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 32,
            controlRadius: 20,
            borderWidth: 1,
            glow: AppTheme.Glow(
                // Measured from the live Design Prompts rendering. CSS's 32px blur maps to a
                // 16-point Core Animation radius; the object travels 16 points lower-right.
                // The pale half is the source's separate -10/-10, 24px white lift.
                role: .divider,
                radius: 16,
                opacity: 1,
                offsetX: 16,
                offsetY: -16,
                highlight: AppTheme.Glow.Highlight(
                    role: .bevelHighlight,
                    radius: 12,
                    opacity: 1,
                    offsetX: -10,
                    offsetY: 10
                )
            ),
            popoverStyle: AppTheme.Material.PopoverStyle(
                arrow: .none,
                edge: .material,
                shadow: .material
            ),
            controlGlow: AppTheme.Glow(
                // The source's button shadow scaled to Threading's 26-point controls (the
                // reference buttons are 56 points tall): violet depth down-right and a smaller
                // white lift up-left. This is intentionally not the neutral panel shadow.
                role: .accent,
                radius: 6,
                opacity: 0.3,
                offsetX: 6,
                offsetY: -6,
                highlight: AppTheme.Glow.Highlight(
                    role: .bevelHighlight,
                    radius: 4,
                    opacity: 0.45,
                    offsetX: -4,
                    offsetY: 4
                )
            ),
            buttonStyle: AppTheme.Material.ButtonStyle(
                fontWeight: .bold,
                // The live reference's secondary button is an opaque white clay object. The
                // lavender control role is its recessed input recipe; sharing it made compact
                // buttons disappear until only their purple shadow remained.
                secondaryRole: .elevated,
                secondaryHoverRole: .elevated,
                hoverOffsetY: -2,
                pressedOffsetY: 1
            ),
            bevel: AppTheme.Bevel(width: 3, style: .soft),
            typeface: .rounded
        )
    )

    public static let vaporwave = AppTheme(
        id: AppThemeID("vaporwave"),
        name: "Vaporwave",
        mode: .dark,
        summary: "Black ultraviolet grid, full-magenta signal, and cyan terminal afterglow.",
        roles: [
            .ground: hex("#090014"),
            .surface: hex("#000000"),
            .panel: hex("#1A103C"),
            .elevated: hex("#1A103CCC"),
            .border: hex("#00FFFF"),
            .divider: hex("#00FFFF66"),
            .label: hex("#E0E0E0"),
            .accent: hex("#FF00FF"),
            .accentMuted: hex("#FF00FF1A"),
            .controlResting: hex("#1A103CCC"),
            .controlHover: hex("#FF00FF1A"),
            .selection: hex("#00FFFF33"),
            .statusPositive: hex("#5EF2C2"),
            .statusWarning: hex("#FFD166"),
            .statusNegative: hex("#FF5F7E"),
            .syntaxKeyword: hex("#FF00FF"),
            .syntaxType: hex("#00FFFF"),
            .syntaxString: hex("#5EF2C2"),
            .syntaxNumber: hex("#FFD166")
        ],
        terminalPalette: terminal(
            id: "app-vaporwave-terminal",
            name: "Vaporwave",
            foreground: "#E0E0E0",
            // The violet between the palette’s magenta and its blue — the one neon in this
            // vocabulary no ANSI slot has already spent.
            boldForeground: "#C77DFF",
            background: "#090014",
            cursor: "#E0E0E0",
            selection: "#1A103C",
            ansi: [
                "#1A103C", "#FF5F7E", "#5EF2C2", "#FFD166",
                "#5A8CFF", "#FF00FF", "#00FFFF", "#C9B8D8",
                "#735A91", "#FF86A0", "#88FFD8", "#FFE39A",
                "#85ACFF", "#FF8DDF", "#8BEAFF", "#E0E0E0"
            ]
        ),
        material: AppTheme.Material(
            // The page is a grid of square terminal modules. Its only rounded shapes are
            // status pills; the former 10/8 material made the whole theme generic neon SaaS.
            panelRadius: 0,
            controlRadius: 0,
            borderWidth: 1,
            backdropPattern: AppTheme.Material.BackdropPattern(
                kind: .perspectiveGrid,
                role: .accent,
                opacity: 0.30,
                spacing: 40,
                lineWidth: 2
            ),
            glow: AppTheme.Glow(
                role: .accent, radius: 7.5, opacity: 0.22
            ),
            controlGlow: AppTheme.Glow(role: .syntaxType, radius: 10, opacity: 0.30),
            buttonStyle: AppTheme.Material.ButtonStyle(
                textTransform: .uppercase,
                fontWeight: .regular,
                tracking: 0.6,
                primaryTreatment: .outlined,
                primaryRole: .syntaxType
            ),
            headingStyle: AppTheme.Material.HeadingStyle(fontWeight: .bold),
            typeface: .monospaced
        )
    )

    public static let newsprint = AppTheme(
        id: AppThemeID("newsprint"),
        name: "Newsprint",
        mode: .light,
        summary: "Near-white stock, dense ink, editorial red, and rule-driven presswork.",
        roles: [
            .ground: hex("#F9F9F7"),
            .surface: hex("#F2F2F0"),
            .panel: hex("#FFFFFF"),
            .elevated: hex("#FFFFFF"),
            .border: hex("#111111"),
            .divider: hex("#11111173"),
            .label: hex("#111111"),
            .accent: hex("#CC0000"),
            .accentMuted: hex("#CC000028"),
            .controlResting: hex("#1111110D"),
            .controlHover: hex("#CC00001A"),
            .selection: hex("#CC000033"),
            .statusPositive: hex("#386641"),
            .statusWarning: hex("#9C5A16"),
            .statusNegative: hex("#CC0000"),
            .syntaxKeyword: hex("#CC0000"),
            .syntaxType: hex("#345B77"),
            .syntaxString: hex("#386641"),
            .syntaxNumber: hex("#7D4E57")
        ],
        terminalPalette: terminal(
            id: "app-newsprint-terminal",
            name: "Newsprint",
            foreground: "#333333",
            boldForeground: "#111111",  // Body steps to press grey; headlines keep full ink
            background: "#F9F9F7",
            cursor: "#333333",
            selection: "#E2D7D3",
            ansi: [
                "#111111", "#CC0000", "#386641", "#8A5A16",
                "#345B77", "#7D4E57", "#3D6B6D", "#6C675C",
                "#4D4941", "#B64646", "#4E7E57", "#A77329",
                "#4D7895", "#986878", "#568486", "#938C7C"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 0,
            controlRadius: 0,
            borderWidth: 1,
            // The reference is completely shadowless. Hierarchy comes from black rules and
            // white/near-white stock, not the old offset shadow.
            glow: nil,
            buttonStyle: AppTheme.Material.ButtonStyle(
                textTransform: .uppercase,
                fontWeight: .bold,
                fontFamily: "Baskerville",
                tracking: 1,
                primaryRole: .label
            ),
            headingStyle: AppTheme.Material.HeadingStyle(fontWeight: .bold),
            typeface: .serif,
            fontFamily: "Baskerville"
        )
    )

    public static let botanical = AppTheme(
        id: AppThemeID("botanical"),
        name: "Botanical",
        mode: .light,
        summary: "Warm ivory, charcoal green, muted clay, and broad organic forms.",
        roles: [
            .ground: hex("#F9F8F4"),
            .surface: hex("#F2F0EB"),
            .panel: hex("#FFFFFF"),
            .elevated: hex("#FFFFFF"),
            .border: hex("#DCCFC2"),
            .divider: hex("#DCCFC2"),
            .label: hex("#2D3A31"),
            .accent: hex("#C27B66"),
            .accentMuted: hex("#C27B6633"),
            .controlResting: hex("#8C9A8433"),
            .controlHover: hex("#C27B6633"),
            .selection: hex("#8C9A8440"),
            .statusPositive: hex("#2E7D4F"),
            .statusWarning: hex("#9B671A"),
            .statusNegative: hex("#A5413F"),
            .syntaxKeyword: hex("#C27B66"),
            .syntaxType: hex("#4F6F88"),
            .syntaxString: hex("#6A7338"),
            .syntaxNumber: hex("#8A5B45")
        ],
        terminalPalette: terminal(
            id: "app-botanical-terminal",
            name: "Botanical",
            foreground: "#2D3A31",
            // Clay, the theme’s second colour, at bark depth. A deeper leaf reads as the
            // palette’s own `green`, and a heading is not a program’s success line.
            boldForeground: "#6B4030",
            background: "#F9F8F4",
            cursor: "#2D3A31",
            selection: "#DDD9D1",
            ansi: [
                "#203124", "#A5413F", "#2E7D4F", "#8A651F",
                "#4F6F88", "#7D5472", "#477779", "#6D786C",
                "#4D5E50", "#C05A57", "#459666", "#A78032",
                "#6688A1", "#966E89", "#609193", "#94A092"
            ]
        ),
        material: AppTheme.Material(
            // Forty-pixel cards and pill controls are the dominant silhouette across the live
            // page. The 18/10 version was neither the source's organic volume nor a compact UI.
            panelRadius: 40,
            controlRadius: 24,
            borderWidth: 1,
            glow: AppTheme.Glow(
                // Shadows are neutral black at roughly ten percent, never green halos.
                role: .label, radius: 6, opacity: 0.10, offsetX: 0, offsetY: -4
            ),
            buttonStyle: AppTheme.Material.ButtonStyle(
                textTransform: .uppercase,
                fontWeight: .bold,
                tracking: 1.2,
                primaryRole: .label
            ),
            headingStyle: AppTheme.Material.HeadingStyle(
                typeface: .serif,
                fontFamily: "Iowan Old Style",
                fontWeight: .regular
            )
        )
    )

    /// Fashion-editorial colour blocking translated into a low-light work surface: warm ink,
    /// cognac, powder blue, deep teal, and cream. The source is a colour relationship rather
    /// than an image asset, so the theme remains original and works across every app surface.
    public static let editorial = AppTheme(
        id: AppThemeID("editorial"),
        name: "Editorial",
        mode: .dark,
        summary: "Warm ink, cognac, powder blue, and deep teal.",
        roles: [
            .ground: hex("#090B0B"),
            .surface: hex("#111716"),
            .panel: hex("#172321"),
            .elevated: hex("#1D2E2B"),
            .border: hex("#55736D"),
            .divider: hex("#2B4540"),
            .label: hex("#F3E7D3"),
            .accent: hex("#D47842"),
            .accentMuted: hex("#D47842").withAlphaComponent(0.22),
            .controlResting: hex("#7DC9D2").withAlphaComponent(0.09),
            .controlHover: hex("#D47842").withAlphaComponent(0.18),
            .selection: hex("#7DC9D2").withAlphaComponent(0.24),
            .statusPositive: hex("#74C49A"),
            .statusWarning: hex("#E6A35D"),
            .statusNegative: hex("#E06E65"),
            .syntaxKeyword: hex("#E08A56"),
            .syntaxType: hex("#7DC9D2"),
            .syntaxString: hex("#B8C58A"),
            .syntaxNumber: hex("#E6B98C")
        ],
        terminalPalette: terminal(
            id: "app-editorial-terminal",
            name: "Editorial",
            foreground: "#F3E7D3",
            // Cognac — the theme’s own chrome accent, and the one warm tone here that is not
            // also an ANSI slot.
            boldForeground: "#D47842",
            background: "#090B0B",
            cursor: "#F3E7D3",
            selection: "#284B4C",
            ansi: [
                "#172321", "#C86058", "#67A984", "#C9914E",
                "#6298A5", "#A9788B", "#67AEB5", "#C8BFAF",
                "#55736D", "#E06E65", "#82C9A1", "#E6A35D",
                "#7DC9D2", "#C58FA5", "#8DD3D8", "#F3E7D3"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 9,
            controlRadius: 5,
            borderWidth: 1,
            glow: AppTheme.Glow(
                role: .accent, radius: 9, opacity: 0.13, offsetX: 0, offsetY: -2
            ),
            typeface: .serif
        )
    )

    public static let industrial = AppTheme(
        id: AppThemeID("industrial"),
        name: "Industrial",
        mode: .light,
        summary: "Cool machine enamel, coral signal controls, and paired neumorphic relief.",
        roles: [
            // Despite its name, the current Design Prompts rendering is a light industrial
            // neumorphism: #E0E5EC enamel, #D1D9E6 recesses, and #FF4757 signal red.
            .ground: hex("#E0E5EC"),
            .surface: hex("#D1D9E6"),
            .panel: hex("#E0E5EC"),
            .elevated: hex("#F0F2F5"),
            .border: hex("#FFFFFF80"),
            .divider: hex("#BABECC"),
            .label: hex("#2D3436"),
            .accent: hex("#FF4757"),
            .accentMuted: hex("#FF475733"),
            .controlResting: hex("#E0E5EC"),
            .controlHover: hex("#F0F2F5"),
            .selection: hex("#FF47574D"),
            .statusPositive: hex("#3E7A4F"),
            .statusWarning: hex("#A66B13"),
            // These two reds double as the paired control-shadow colours below.
            .statusNegative: hex("#A6323C"),
            .syntaxKeyword: hex("#FF646E"),
            .syntaxType: hex("#78A7B8"),
            .syntaxString: hex("#3E7A4F"),
            .syntaxNumber: hex("#D88A6A"),
            .bevelHighlight: hex("#FFFFFF"),
            .bevelShadow: hex("#BABECC")
        ],
        terminalPalette: terminal(
            id: "app-industrial-terminal",
            name: "Industrial",
            foreground: "#2D3436",
            boldForeground: "#0B1113",  // Iron, a step below the body’s steel
            background: "#E0E5EC",
            cursor: "#2D3436",
            selection: "#F4B6BC",
            ansi: [
                "#2D3436", "#A6323C", "#4F8F61", "#A66B13",
                "#527C8C", "#855E7A", "#4F8583", "#697277",
                "#566066", "#D94B58", "#65A977", "#C98922",
                "#6A98A8", "#9F7895", "#68A3A1", "#879096"
            ]
        ),
        material: AppTheme.Material(
            panelRadius: 16,
            controlRadius: 24,
            borderWidth: 1,
            glow: AppTheme.Glow(
                // The dominant raised module is 8/8/16 grey plus -8/-8/16 white.
                role: .bevelShadow,
                radius: 8,
                opacity: 1,
                offsetX: 8,
                offsetY: -8,
                highlight: AppTheme.Glow.Highlight(
                    role: .bevelHighlight,
                    radius: 8,
                    opacity: 1,
                    offsetX: -8,
                    offsetY: 8
                )
            ),
            controlGlow: AppTheme.Glow(
                // Coral CTAs use their own tighter paired relief instead of grey panel depth.
                role: .statusNegative,
                radius: 4,
                opacity: 0.4,
                offsetX: 4,
                offsetY: -4,
                highlight: AppTheme.Glow.Highlight(
                    role: .syntaxKeyword,
                    radius: 4,
                    opacity: 0.4,
                    offsetX: -4,
                    offsetY: 4
                )
            ),
            buttonStyle: AppTheme.Material.ButtonStyle(
                textTransform: .uppercase,
                fontWeight: .bold,
                tracking: 0.6,
                secondaryShadow: .panel,
                primaryBorderRole: .border,
                pressedOffsetY: 2
            ),
            headingStyle: AppTheme.Material.HeadingStyle(fontWeight: .bold),
            bevel: AppTheme.Bevel(width: 2, style: .soft)
        )
    )

    /// Shared with the seasonal style in `AppThemeStyles+Christmas.swift`, which is why this is
    /// internal rather than private to this file.
    public static func terminal(
        id: String,
        name: String,
        foreground: String,
        // Terminal.app's "Bold Text". Stated by every palette here rather than defaulted, so a
        // new theme cannot quietly ship headings that are only a weight.
        boldForeground: String,
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
            boldForeground: hex(boldForeground),
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
