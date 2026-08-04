import AppKit

enum AppThemeEditingError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// Builds a durable custom theme from a stock or custom base.
///
/// A base may omit derived roles, and System deliberately stores no roles at all. Custom
/// documents instead materialise the authored vocabulary at creation time. That keeps them
/// independent of a later stock-theme change and prevents a fixed dark ground from falling
/// through to a dynamic light system label.
@MainActor
enum AppThemeEditing {

    static func make(
        id: AppThemeID,
        name: String,
        base: AppTheme,
        mode: AppTheme.Mode? = nil,
        summary: String? = nil,
        roles overrides: [AppThemeRole: NSColor] = [:],
        material: AppTheme.Material? = nil,
        terminalPalette: TerminalTheme? = nil
    ) throws -> AppTheme {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw AppThemeEditingError.invalid("Provide a name for the app theme.")
        }

        let requestedMode = mode ?? base.mode
        // A custom document has one fixed palette. When its base is the adaptive System theme,
        // snapshot the appearance the user is actually looking at rather than claiming those
        // fixed colours can follow both modes.
        let targetMode: AppTheme.Mode
        if requestedMode == .system {
            targetMode = NSAppearance.currentDrawing()
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        } else {
            targetMode = requestedMode
        }
        let kind = AppTheme.VariantKind(mode: targetMode)
        let variant = makeVariant(
            named: cleanName,
            from: base,
            kind: kind,
            roles: overrides,
            material: material,
            terminalPalette: terminalPalette
        )
        return try assemble(
            id: id,
            name: cleanName,
            mode: targetMode == .system ? (kind == .dark ? .dark : .light) : targetMode,
            summary: summary,
            variants: [kind: variant]
        )
    }

    /// Materialises one editable appearance from a base and merges only the supplied changes.
    ///
    /// If the base has no matching variant, its available appearance is used as the design
    /// starting point. System is resolved under the requested appearance. Validation later
    /// catches a new opposite variant whose inherited colours were not changed enough to read.
    /// How a caller states what should happen to the sidebar block, distinctly from saying
    /// nothing. A plain optional cannot tell "leave it alone" from "take it away", and losing
    /// that distinction is how an update that changed one colour would strip a theme's brand.
    enum SidebarChange {
        case inherit
        case remove
        case set(SidebarStyle)

        func applied(to source: SidebarStyle?) -> SidebarStyle? {
            switch self {
            case .inherit: return source
            case .remove: return nil
            case .set(let style): return style.isEmpty ? nil : style
            }
        }
    }

    /// The same three-way statement for the chrome block, for the same reason: a plain optional
    /// cannot tell "leave it alone" from "take it away", and an update that changed one colour
    /// must not silently hand the window frame back to AppKit. No empty-normalisation arm —
    /// a chrome block's title bar is required, so there is no empty style to normalise.
    enum ChromeChange {
        case inherit
        case remove
        case set(WindowChromeStyle)

        func applied(to source: WindowChromeStyle?) -> WindowChromeStyle? {
            switch self {
            case .inherit: return source
            case .remove: return nil
            case .set(let style): return style
            }
        }
    }

    static func makeVariant(
        named name: String,
        from base: AppTheme,
        kind: AppTheme.VariantKind,
        roles overrides: [AppThemeRole: NSColor] = [:],
        material: AppTheme.Material? = nil,
        terminalPalette: TerminalTheme? = nil,
        sidebar: SidebarChange = .inherit,
        chrome: ChromeChange = .inherit
    ) -> AppTheme.Variant {
        let appearance = kind.appearance ?? NSAppearance.currentDrawing()
        let source = base.variant(kind)
            ?? base.variant(kind == .light ? .dark : .light)
        var roles = source?.roles ?? [:]
        appearance.performAsCurrentDrawingAppearance {
            for role in AppThemeRole.authored where roles[role] == nil {
                let resolved = base.resolved(role, appearance: appearance)
                roles[role] = resolved.usingColorSpace(.sRGB) ?? resolved
            }
        }
        for (role, color) in overrides {
            roles[role] = color
        }
        return AppTheme.Variant(
            roles: roles,
            terminalPalette: (terminalPalette
                ?? source?.terminalPalette
                ?? base.terminalPalette).renamed(name),
            material: material ?? source?.material ?? base.material,
            sidebar: sidebar.applied(to: source?.sidebar),
            chrome: chrome.applied(to: source?.chrome)
        )
    }

    static func assemble(
        id: AppThemeID,
        name: String,
        mode: AppTheme.Mode,
        summary: String?,
        variants: [AppTheme.VariantKind: AppTheme.Variant]
    ) throws -> AppTheme {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw AppThemeEditingError.invalid("Provide a name for the app theme.")
        }
        // Every optional block must ride through this rebuild by hand. The rename pass
        // reconstructs each variant, and a field left off the call vanishes from every theme
        // assemble touches while looking untouched in the caller's patch — the trap
        // `SidebarStyleTests` and `WindowChromeStyleTests` each pin for their block.
        let renamed = variants.mapValues { variant in
            AppTheme.Variant(
                roles: variant.roles,
                terminalPalette: variant.terminalPalette.renamed(cleanName),
                material: variant.material,
                sidebar: variant.sidebar,
                chrome: variant.chrome
            )
        }
        let theme = AppTheme(
            id: id,
            name: cleanName,
            mode: mode,
            summary: summary,
            variants: renamed
        )
        try validate(theme)
        return theme
    }

    /// Duplicating is a value copy of the entire style, including an optional opposite
    /// appearance. It never snapshots an adaptive theme down to whichever variant is visible.
    static func duplicate(
        _ source: AppTheme,
        id: AppThemeID,
        name: String
    ) throws -> AppTheme {
        let variants: [AppTheme.VariantKind: AppTheme.Variant]
        if source.isSystem {
            variants = Dictionary(uniqueKeysWithValues: AppTheme.VariantKind.allCases.map {
                (
                    $0,
                    makeVariant(named: name, from: source, kind: $0)
                )
            })
        } else {
            variants = source.variants
        }
        return try assemble(
            id: id,
            name: name,
            mode: source.mode,
            summary: source.summary,
            variants: variants
        )
    }

    nonisolated static func validate(_ theme: AppTheme) throws {
        if theme.isSystem {
            guard theme.mode == .system, theme.variants.isEmpty else {
                throw AppThemeEditingError.invalid(
                    "The System theme is supplied by AppKit and cannot contain authored variants."
                )
            }
            return
        }

        guard !theme.variants.isEmpty else {
            throw AppThemeEditingError.invalid(
                "An app theme must provide at least one light or dark variant."
            )
        }
        switch theme.mode {
        case .light where theme.variant(.light) == nil:
            throw AppThemeEditingError.invalid(
                "A theme with light appearance must provide a light variant."
            )
        case .dark where theme.variant(.dark) == nil:
            throw AppThemeEditingError.invalid(
                "A theme with dark appearance must provide a dark variant."
            )
        case .system where theme.variant(.light) == nil || theme.variant(.dark) == nil:
            throw AppThemeEditingError.invalid(
                "An adaptive theme must provide both light and dark variants."
            )
        default:
            break
        }

        // Band colours may differ between appearances; whether the window wears its own frame
        // may not. An adaptive theme whose light half stated chrome and whose dark half did
        // not would swap the entire window frame every time macOS changed appearance.
        if theme.isAdaptive,
           (theme.variant(.light)?.chrome != nil) != (theme.variant(.dark)?.chrome != nil) {
            throw AppThemeEditingError.invalid(
                "An adaptive theme must state window chrome in both variants or neither."
            )
        }

        for kind in theme.availableVariants {
            guard let variant = theme.variant(kind) else { continue }
            try validate(variant, kind: kind, theme: theme)
        }
    }

    nonisolated private static func validate(
        _ variant: AppTheme.Variant,
        kind: AppTheme.VariantKind,
        theme: AppTheme
    ) throws {
        let resolved = AppTheme(
            id: theme.id,
            name: theme.name,
            mode: kind == .dark ? .dark : .light,
            summary: theme.summary,
            variants: [kind: variant]
        )

        for role in AppThemeRole.authored where variant.roles[role] == nil {
            throw AppThemeEditingError.invalid(
                "The \(kind.rawValue) variant has no \(role.wireName) colour after merging its base."
            )
        }

        let appearance = kind.appearance ?? NSAppearance.currentDrawing()
        let ground = resolved.resolved(.ground, appearance: appearance)
        guard ground.alphaComponent >= 0.999 else {
            throw AppThemeEditingError.invalid(
                "\(kind.rawValue).ground must be opaque because the window has no theme surface behind it."
            )
        }
        let surface = composite(resolved.resolved(.surface, appearance: appearance), over: ground)
        let panel = composite(resolved.resolved(.panel, appearance: appearance), over: surface)

        for (role, effectiveSurface) in [
            (AppThemeRole.ground, ground),
            (.surface, surface),
            (.panel, panel)
        ] {
            let effectiveLabel = composite(
                resolved.resolved(.label, appearance: appearance),
                over: effectiveSurface
            )
            let ratio = ThemeContrast.ratio(effectiveLabel, effectiveSurface)
            guard ratio >= ThemeContrast.minimumRatio else {
                throw AppThemeEditingError.invalid(
                    "\(kind.rawValue) \(resolved.resolved(.label, appearance: appearance).hexString) "
                        + "text on \(role.wireName) "
                        + "\(resolved.resolved(role, appearance: appearance).hexString) "
                        + "has \(formatted(ratio)):1 contrast; "
                        + "at least \(Int(ThemeContrast.minimumRatio)):1 is required."
                )
            }
        }

        let effectiveAccent = composite(
            resolved.resolved(.accent, appearance: appearance),
            over: ground
        )
        let accentRatio = ThemeContrast.ratio(
            effectiveAccent,
            ground
        )
        guard accentRatio >= 2 else {
            throw AppThemeEditingError.invalid(
                "The accent is only \(formatted(accentRatio)):1 against the window ground; "
                    + "at least 2:1 is required."
            )
        }

        // Code is body text too. The conversation's diffs and code blocks draw the syntax
        // roles over the chrome, so a variant whose keyword colour vanishes there ships
        // unreadable diffs — found by a live theme whose light variant kept its dark syntax
        // set, and every keyword drew as white-on-white. Two deliberate softenings: the floor
        // is the accent's 2:1 rather than the label's 3:1, because Apple's own light teal
        // sits at 2.2:1 and a System duplicate must stay valid; and only the ground is
        // measured, because the panel is a wash a few percent off it — a gate that also
        // measured the wash failed on rounding, not on readability.
        for role in [AppThemeRole.syntaxKeyword, .syntaxType, .syntaxString, .syntaxNumber] {
            let colour = composite(
                resolved.resolved(role, appearance: appearance),
                over: ground
            )
            let ratio = ThemeContrast.ratio(colour, ground)
            guard ratio >= 2 else {
                throw AppThemeEditingError.invalid(
                    "\(kind.rawValue) \(role.wireName) "
                        + "\(resolved.resolved(role, appearance: appearance).hexString) on the "
                        + "window ground has \(formatted(ratio)):1 contrast; "
                        + "at least 2:1 is required."
                )
            }
        }

        // Status hues annotate the chrome — session dots, ± counters, diff signs — and need
        // the accent's floor to stay tellable from the ground.
        for role in [AppThemeRole.statusPositive, .statusWarning, .statusNegative] {
            let colour = composite(
                resolved.resolved(role, appearance: appearance),
                over: ground
            )
            let ratio = ThemeContrast.ratio(colour, ground)
            guard ratio >= 2 else {
                throw AppThemeEditingError.invalid(
                    "\(kind.rawValue) \(role.wireName) "
                        + "\(resolved.resolved(role, appearance: appearance).hexString) is only "
                        + "\(formatted(ratio)):1 against the window ground; "
                        + "at least 2:1 is required."
                )
            }
        }

        guard ThemeContrast.isLegible(
            foreground: variant.terminalPalette.foreground,
            background: variant.terminalPalette.background
        ) else {
            throw AppThemeEditingError.invalid(
                "The \(kind.rawValue) variant's paired terminal text is not legible against its background."
            )
        }

        let material = variant.material
        guard (0...24).contains(material.panelRadius) else {
            throw AppThemeEditingError.invalid("panel_radius must be between 0 and 24.")
        }
        guard (0...24).contains(material.controlRadius) else {
            throw AppThemeEditingError.invalid("control_radius must be between 0 and 24.")
        }
        guard (0.5...4).contains(material.borderWidth) else {
            throw AppThemeEditingError.invalid("border_width must be between 0.5 and 4.")
        }
        guard (0.65...1.5).contains(material.textScale) else {
            throw AppThemeEditingError.invalid("text_scale must be between 0.65 and 1.5.")
        }

        if let bevel = material.bevel {
            guard (1...3).contains(bevel.width) else {
                throw AppThemeEditingError.invalid("bevel.width must be between 1 and 3.")
            }
            // A bevel only draws on square corners (a rectilinear edge has no honest offset
            // curve for a rounded one), so a material stating both would author a treatment
            // that never appears. Refused rather than silently ignored.
            guard material.panelRadius == 0, material.controlRadius == 0 else {
                throw AppThemeEditingError.invalid(
                    "A bevelled material must state panel_radius 0 and control_radius 0 — "
                        + "bevels draw only on square corners."
                )
            }
        }

        if let glow = material.glow {
            // Layout reserves a constant gutter, so a tool-authored shadow may not silently
            // spill beyond it and become clipped by every scroll view. A directed shadow uses
            // part of that budget merely reaching its offset, before its blur begins.
            guard (0...Design.Size.glowGutter / 2).contains(glow.radius) else {
                throw AppThemeEditingError.invalid(
                    "glow.radius must be between 0 and \(Int(Design.Size.glowGutter / 2))."
                )
            }
            guard (0...1).contains(glow.opacity) else {
                throw AppThemeEditingError.invalid("glow.opacity must be between 0 and 1.")
            }
            guard (-10...10).contains(glow.offsetX), (-10...10).contains(glow.offsetY) else {
                throw AppThemeEditingError.invalid(
                    "glow offsets must be between -10 and 10 points."
                )
            }
            let horizontalExtent = abs(glow.offsetX) + glow.radius * 2
            let verticalExtent = abs(glow.offsetY) + glow.radius * 2
            guard horizontalExtent <= Design.Size.glowGutter,
                  verticalExtent <= Design.Size.glowGutter else {
                throw AppThemeEditingError.invalid(
                    "glow radius plus offset exceeds the \(Int(Design.Size.glowGutter))-point "
                        + "panel-shadow gutter."
                )
            }
        }

        if let sidebar = variant.sidebar {
            try validate(sidebar, kind: kind, resolved: resolved, appearance: appearance)
        }

        if let chrome = variant.chrome {
            try validate(chrome, kind: kind, resolved: resolved, appearance: appearance)
        }
    }

    /// The chrome block's own gates. The band gets the sidebar gradient's treatment — its ink
    /// is the window's title and buttons, and a band that swallows them loses the window its
    /// close button. The inactive band is deliberately held to the softer "tellable" floor:
    /// inactive title text signals inactivity by carrying less ink, and the classic inactive
    /// palettes sit below full label contrast on purpose.
    nonisolated private static func validate(
        _ chrome: WindowChromeStyle,
        kind: AppTheme.VariantKind,
        resolved: AppTheme,
        appearance: NSAppearance
    ) throws {
        let ground = resolved.resolved(.ground, appearance: appearance)

        func check(
            _ gradient: SidebarStyle.Gradient,
            named name: String,
            ink: NSColor,
            floor: CGFloat
        ) throws {
            guard (2...WindowChromeStyleLimits.maximumGradientStops)
                .contains(gradient.stops.count) else {
                throw AppThemeEditingError.invalid(
                    "chrome.\(name) needs 2 to "
                        + "\(WindowChromeStyleLimits.maximumGradientStops) stops."
                )
            }
            guard gradient.stops.allSatisfy({ (0...1).contains($0.position) }) else {
                throw AppThemeEditingError.invalid(
                    "chrome.\(name) stop positions must be between 0 and 1."
                )
            }
            for stop in gradient.stops {
                // A stop may be translucent; the band sits over the window ground, so that
                // is what a translucent stop is measured against.
                let band = ground.composited(under: stop.color)
                let effectiveInk = band.composited(under: ink)
                let ratio = ThemeContrast.ratio(effectiveInk, band)
                guard ratio >= floor else {
                    throw AppThemeEditingError.invalid(
                        "\(kind.rawValue) chrome ink on the \(name) stop "
                            + "\(stop.color.hexString) has \(formatted(ratio)):1 contrast; "
                            + "at least \(Int(floor)):1 is required."
                    )
                }
            }
        }

        let titleBar = chrome.titleBar
        try check(
            titleBar.activeGradient,
            named: "title_bar.active_gradient",
            ink: titleBar.ink ?? .white,
            floor: ThemeContrast.minimumRatio
        )
        if let inactive = titleBar.inactiveGradient {
            try check(
                inactive,
                named: "title_bar.inactive_gradient",
                ink: titleBar.inactiveInk ?? titleBar.ink ?? .white,
                floor: WindowChromeStyleLimits.inactiveInkMinimumRatio
            )
        }

        if let height = titleBar.height {
            guard WindowChromeStyleLimits.bandHeightRange.contains(height) else {
                throw AppThemeEditingError.invalid(
                    "chrome.title_bar.height must be between "
                        + "\(Int(WindowChromeStyleLimits.bandHeightRange.lowerBound)) and "
                        + "\(Int(WindowChromeStyleLimits.bandHeightRange.upperBound)) points."
                )
            }
        }

        if let frame = chrome.frame {
            guard WindowChromeStyleLimits.frameWidthRange.contains(frame.width) else {
                throw AppThemeEditingError.invalid(
                    "chrome.frame.width must be between "
                        + "\(Int(WindowChromeStyleLimits.frameWidthRange.lowerBound)) and "
                        + "\(Int(WindowChromeStyleLimits.frameWidthRange.upperBound)) points."
                )
            }
        }
    }

    /// The sidebar block's own gates. The gradient gets the same treatment the terminal
    /// palette does — the sidebar is where every session is *found*, so a wash that swallows
    /// its labels locks the user out of the rest of the app as surely as an unreadable
    /// terminal would. An image cannot be measured this way (its pixels are arbitrary), so its
    /// gates are bounds, and legibility stays the author's to check by looking.
    nonisolated private static func validate(
        _ sidebar: SidebarStyle,
        kind: AppTheme.VariantKind,
        resolved: AppTheme,
        appearance: NSAppearance
    ) throws {
        if let navigator = sidebar.navigatorWell {
            guard navigator.fill.alphaComponent >= 0.999 else {
                throw AppThemeEditingError.invalid(
                    "sidebar.navigator_well.fill must be opaque so its text contrast is stable."
                )
            }
            let label = resolved.resolved(.label, appearance: appearance)
            let ink = composite(label, over: navigator.fill)
            let ratio = ThemeContrast.ratio(ink, navigator.fill)
            guard ratio >= ThemeContrast.minimumRatio else {
                throw AppThemeEditingError.invalid(
                    "\(kind.rawValue) sidebar text on navigator_well.fill "
                        + "\(navigator.fill.hexString) has \(formatted(ratio)):1 contrast; "
                        + "at least \(Int(ThemeContrast.minimumRatio)):1 is required."
                )
            }
        }

        if let gradient = sidebar.background?.gradient {
            guard (2...SidebarStyleLimits.maximumGradientStops).contains(gradient.stops.count) else {
                throw AppThemeEditingError.invalid(
                    "sidebar.gradient needs 2 to \(SidebarStyleLimits.maximumGradientStops) stops."
                )
            }
            guard gradient.stops.allSatisfy({ (0...1).contains($0.position) }) else {
                throw AppThemeEditingError.invalid(
                    "sidebar.gradient stop positions must be between 0 and 1."
                )
            }
            let label = resolved.resolved(.label, appearance: appearance)
            let surface = resolved.resolved(.surface, appearance: appearance)
            for stop in gradient.stops {
                // A stop may be translucent; what the label actually sits on is the stop
                // composited over the themed surface, so that is what gets measured.
                let ground = surface.composited(under: stop.color)
                let ink = ground.composited(under: label)
                let ratio = ThemeContrast.ratio(ink, ground)
                guard ratio >= ThemeContrast.minimumRatio else {
                    throw AppThemeEditingError.invalid(
                        "\(kind.rawValue) sidebar text on the gradient stop "
                            + "\(stop.color.hexString) has \(formatted(ratio)):1 contrast; "
                            + "at least \(Int(ThemeContrast.minimumRatio)):1 is required."
                    )
                }
            }
        }

        if let image = sidebar.background?.image {
            guard (0...1).contains(image.opacity) else {
                throw AppThemeEditingError.invalid("sidebar.image.opacity must be between 0 and 1.")
            }
            guard !image.asset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppThemeEditingError.invalid("sidebar.image names no asset.")
            }
        }

        if let brand = sidebar.brand {
            if case .asset(let name) = brand.logo,
               name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AppThemeEditingError.invalid("sidebar.brand.logo names no asset.")
            }
            if let title = brand.title {
                if brand.logo == .hidden, title.hidden {
                    throw AppThemeEditingError.invalid(
                        "sidebar.brand cannot hide both the logo and the title — remove the "
                            + "brand block instead to fall back to the default."
                    )
                }
                if let text = title.text {
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty,
                          clean.count <= SidebarStyleLimits.maximumTitleLength else {
                        throw AppThemeEditingError.invalid(
                            "sidebar.brand.title.text must be 1 to "
                                + "\(SidebarStyleLimits.maximumTitleLength) characters."
                        )
                    }
                }
                if let size = title.fontSize {
                    guard SidebarStyleLimits.titleSizeRange.contains(size) else {
                        throw AppThemeEditingError.invalid(
                            "sidebar.brand.title.font_size must be between "
                                + "\(Int(SidebarStyleLimits.titleSizeRange.lowerBound)) and "
                                + "\(Int(SidebarStyleLimits.titleSizeRange.upperBound)) points."
                        )
                    }
                }
            }
        }
    }

    nonisolated private static func formatted(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    /// Resolves translucency the way the themed views do before measuring contrast. Measuring
    /// the RGB components of a 10%-opaque white label directly would call it white-on-black
    /// with 21:1 contrast even though the user actually sees a near-black grey.
    nonisolated private static func composite(
        _ foreground: NSColor,
        over background: NSColor
    ) -> NSColor {
        guard let foreground = foreground.usingColorSpace(.sRGB),
              let background = background.usingColorSpace(.sRGB) else {
            return foreground
        }
        let alpha = foreground.alphaComponent
        return NSColor(
            srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
            green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
            blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha),
            alpha: 1
        )
    }
}
