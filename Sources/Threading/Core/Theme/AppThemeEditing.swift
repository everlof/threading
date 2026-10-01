import AppKit

public enum AppThemeEditingError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
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
public enum AppThemeEditing {

    public static func make(
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
    public enum SidebarChange {
        case inherit
        case remove
        case set(SidebarStyle)

        public func applied(to source: SidebarStyle?) -> SidebarStyle? {
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
    public enum ChromeChange {
        case inherit
        case remove
        case set(WindowChromeStyle)

        public func applied(to source: WindowChromeStyle?) -> WindowChromeStyle? {
            switch self {
            case .inherit: return source
            case .remove: return nil
            case .set(let style): return style
            }
        }
    }

    /// The same three-way statement for the transition block: a patch that recoloured one
    /// role must not silently take away how the theme arrives.
    public enum TransitionChange {
        case inherit
        case remove
        case set(ThemeTransition)

        public func applied(to source: ThemeTransition?) -> ThemeTransition? {
            switch self {
            case .inherit: return source
            case .remove: return nil
            case .set(let transition): return transition
            }
        }
    }

    /// The same three-way statement for the newer variant blocks — the sprite library, the
    /// moments and the words — in one generic shape rather than a fourth, fifth and sixth enum.
    public enum BlockChange<Value> {
        case inherit
        case remove
        case set(Value)

        public func applied(to source: Value?) -> Value? {
            switch self {
            case .inherit: return source
            case .remove: return nil
            case .set(let value): return value
            }
        }
    }

    public static func makeVariant(
        named name: String,
        from base: AppTheme,
        kind: AppTheme.VariantKind,
        roles overrides: [AppThemeRole: NSColor] = [:],
        material: AppTheme.Material? = nil,
        terminalPalette: TerminalTheme? = nil,
        sidebar: SidebarChange = .inherit,
        chrome: ChromeChange = .inherit,
        transition: TransitionChange = .inherit,
        sprites: BlockChange<[ThemeSprite]> = .inherit,
        moments: BlockChange<ThemeMoments> = .inherit,
        words: BlockChange<ThemeWords> = .inherit
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
            chrome: chrome.applied(to: source?.chrome),
            transition: transition.applied(to: source?.transition),
            sprites: sprites.applied(to: source?.sprites) ?? [],
            moments: moments.applied(to: source?.moments).flatMap { $0.isEmpty ? nil : $0 },
            words: words.applied(to: source?.words).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    public static func assemble(
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
        // The rename pass rebuilds each variant through `replacing`, which carries every
        // stored field by construction — the hand-written rebuild here was the trap
        // `SidebarStyleTests` and `WindowChromeStyleTests` each pin for their block: a field
        // left off the call vanished from every theme assemble touched while looking
        // untouched in the caller's patch.
        let renamed = variants.mapValues { variant in
            variant.replacing(terminalPalette: variant.terminalPalette.renamed(cleanName))
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
    public static func duplicate(
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

    public nonisolated static func validate(_ theme: AppTheme) throws {
        if theme.isSystem {
            guard theme.mode == .system, theme.variants.isEmpty else {
                throw AppThemeEditingError.invalid(
                    "The System theme is supplied by AppKit and cannot contain authored variants."
                )
            }
            return
        }

        guard theme.id.isSafeAssetDirectoryName else {
            throw AppThemeEditingError.invalid(
                "A theme id must be one safe file-name component."
            )
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

        // Bold text is text, and it is stated independently of the body, so a variant can
        // arrive with a readable body and an unreadable heading.
        guard ThemeContrast.isLegible(
            foreground: variant.terminalPalette.boldForeground,
            background: variant.terminalPalette.background
        ) else {
            let ratio = ThemeContrast.ratio(
                variant.terminalPalette.boldForeground,
                variant.terminalPalette.background
            )
            throw AppThemeEditingError.invalid(
                "The \(kind.rawValue) variant's paired terminal bold_foreground "
                    + "\(variant.terminalPalette.boldForeground.hexString) is only "
                    + "\(formatted(ratio)):1 against its background; "
                    + "at least \(Int(ThemeContrast.minimumRatio)):1 is required."
            )
        }

        let material = variant.material
        guard (0...40).contains(material.panelRadius) else {
            throw AppThemeEditingError.invalid("panel_radius must be between 0 and 40.")
        }
        guard (0...24).contains(material.controlRadius) else {
            throw AppThemeEditingError.invalid("control_radius must be between 0 and 24.")
        }
        guard (0.5...4).contains(material.borderWidth) else {
            throw AppThemeEditingError.invalid("border_width must be between 0.5 and 4.")
        }
        if let width = material.controlBorderWidth,
           !(0.5...4).contains(width) {
            throw AppThemeEditingError.invalid(
                "control_border_width must be between 0.5 and 4."
            )
        }
        guard (0.65...1.5).contains(material.textScale) else {
            throw AppThemeEditingError.invalid("text_scale must be between 0.65 and 1.5.")
        }
        guard (14...44).contains(material.choiceHeight) else {
            throw AppThemeEditingError.invalid("choice_height must be between 14 and 44.")
        }

        let popover = material.popoverStyle
        guard popover.edge != .material || popover.arrow == .none else {
            throw AppThemeEditingError.invalid(
                "popover_style.edge \"material\" requires arrow \"none\" so the bevel owns "
                    + "one coherent silhouette."
            )
        }
        if let radius = popover.cornerRadius {
            guard (0...24).contains(radius) else {
                throw AppThemeEditingError.invalid(
                    "popover_style.corner_radius must be between 0 and 24."
                )
            }
        }
        // Ground, surface, and panel were checked above. Derived roles intentionally inherit
        // those guarantees, so only separately-authored popover colours need another gate.
        // This keeps old sparse documents valid now that every material has a default style.
        if variant.roles[popover.surfaceRole] != nil {
            let popoverFill = composite(
                resolved.resolved(popover.surfaceRole, appearance: appearance),
                over: ground
            )
            let popoverLabel = composite(
                resolved.resolved(.label, appearance: appearance),
                over: popoverFill
            )
            let popoverContrast = ThemeContrast.ratio(popoverLabel, popoverFill)
            guard popoverContrast >= ThemeContrast.minimumRatio else {
                throw AppThemeEditingError.invalid(
                    "popover_style.surface_role \"\(popover.surfaceRole.wireName)\" leaves label "
                        + "text at only \(formatted(popoverContrast)):1; at least "
                        + "\(ThemeContrast.minimumRatio):1 is required."
                )
            }
        }

        if let pattern = material.backdropPattern {
            guard (0...1).contains(pattern.opacity) else {
                throw AppThemeEditingError.invalid(
                    "backdrop_pattern.opacity must be between 0 and 1."
                )
            }
            guard (8...64).contains(pattern.spacing) else {
                throw AppThemeEditingError.invalid(
                    "backdrop_pattern.spacing must be between 8 and 64 points."
                )
            }
            guard (0.5...6).contains(pattern.lineWidth) else {
                throw AppThemeEditingError.invalid(
                    "backdrop_pattern.line_width must be between 0.5 and 6 points."
                )
            }
            guard pattern.lineWidth <= pattern.spacing / 2 else {
                throw AppThemeEditingError.invalid(
                    "backdrop_pattern.line_width must be no more than half its spacing."
                )
            }
        }

        // The material's backdrop sits under every broad ground, so its gradient is held to
        // the label's floor against the *ground* — the sidebar's block is held against the
        // surface for the same reason in `validate(_ sidebar:…)`, through the same gate.
        if let backdrop = material.backdrop {
            try validate(
                backdrop,
                prefix: "material.backdrop",
                subject: "text on the backdrop gradient stop",
                kind: kind,
                label: resolved.resolved(.label, appearance: appearance),
                ground: ground
            )
        }

        let button = material.buttonStyle
        guard (-1...4).contains(button.tracking) else {
            throw AppThemeEditingError.invalid(
                "button_style.tracking must be between -1 and 4 points."
            )
        }
        guard (0.5...2).contains(button.fontScale) else {
            throw AppThemeEditingError.invalid(
                "button_style.font_scale must be between 0.5 and 2."
            )
        }
        if let width = button.minimumWidth, !(20...240).contains(width) {
            throw AppThemeEditingError.invalid(
                "button_style.minimum_width must be between 20 and 240 points."
            )
        }
        if let height = button.minimumHeight, !(14...60).contains(height) {
            throw AppThemeEditingError.invalid(
                "button_style.minimum_height must be between 14 and 60 points."
            )
        }
        for (field, value) in [
            ("hover_offset_x", button.hoverOffsetX),
            ("hover_offset_y", button.hoverOffsetY),
            ("pressed_offset_x", button.pressedOffsetX),
            ("pressed_offset_y", button.pressedOffsetY)
        ] {
            guard (-8...8).contains(value) else {
                throw AppThemeEditingError.invalid(
                    "button_style.\(field) must be between -8 and 8 points."
                )
            }
        }

        if let bevel = material.bevel {
            guard (1...3).contains(bevel.width) else {
                throw AppThemeEditingError.invalid("bevel.width must be between 1 and 3.")
            }
            // The classic hard edge is rectilinear and has no honest offset curve for a
            // rounded corner. Soft relief is the rounded counterpart and deliberately follows
            // that curve, so only the hard construction carries the square-corner requirement.
            guard bevel.style == .soft
                    || (material.panelRadius == 0 && material.controlRadius == 0) else {
                throw AppThemeEditingError.invalid(
                    "A hard-bevelled material must state panel_radius 0 and control_radius 0 — "
                        + "use bevel.style \"soft\" for rounded relief."
                )
            }
        }

        func validateGlow(_ glow: AppTheme.Glow, field: String) throws {
            // Layout reserves a constant gutter, so a tool-authored shadow may not silently
            // spill beyond it and become clipped by every scroll view. A directed shadow uses
            // part of that budget merely reaching its offset, before its blur begins.
            func validateShadow(
                radius: CGFloat,
                opacity: Double,
                offsetX: CGFloat,
                offsetY: CGFloat,
                field: String
            ) throws {
                guard (0...Design.Size.glowGutter / 2).contains(radius) else {
                    throw AppThemeEditingError.invalid(
                        "\(field).radius must be between 0 and "
                            + "\(Int(Design.Size.glowGutter / 2))."
                    )
                }
                guard (0...1).contains(opacity) else {
                    throw AppThemeEditingError.invalid("\(field).opacity must be between 0 and 1.")
                }
                let offsetLimit = Design.Size.glowGutter / 2
                guard (-offsetLimit...offsetLimit).contains(offsetX),
                      (-offsetLimit...offsetLimit).contains(offsetY) else {
                    throw AppThemeEditingError.invalid(
                        "\(field) offsets must be between -\(Int(offsetLimit)) "
                            + "and \(Int(offsetLimit)) points."
                    )
                }
                let horizontalExtent = abs(offsetX) + radius * 2
                let verticalExtent = abs(offsetY) + radius * 2
                guard horizontalExtent <= Design.Size.glowGutter,
                      verticalExtent <= Design.Size.glowGutter else {
                    throw AppThemeEditingError.invalid(
                        "\(field) radius plus offset exceeds the "
                            + "\(Int(Design.Size.glowGutter))-point panel-shadow gutter."
                    )
                }
            }

            try validateShadow(
                radius: glow.radius,
                opacity: glow.opacity,
                offsetX: glow.offsetX,
                offsetY: glow.offsetY,
                field: field
            )
            if let highlight = glow.highlight {
                try validateShadow(
                    radius: highlight.radius,
                    opacity: highlight.opacity,
                    offsetX: highlight.offsetX,
                    offsetY: highlight.offsetY,
                    field: "\(field).highlight"
                )
            }
        }
        if let glow = material.glow { try validateGlow(glow, field: "glow") }
        if let glow = material.controlGlow {
            try validateGlow(glow, field: "control_glow")
        }

        if let sidebar = variant.sidebar {
            try validate(sidebar, kind: kind, resolved: resolved, appearance: appearance)
        }

        if let chrome = variant.chrome {
            try validate(chrome, kind: kind, resolved: resolved, appearance: appearance)
        }

        if let transition = variant.transition {
            try validate(transition, kind: kind)
        }

        try validateCharacter(variant)
    }

    // MARK: - Character: sprites, mascot, moments, words

    /// The newer blocks' gates. All are bounds and references rather than contrast: a sprite is
    /// a particle and inherits the particle ceilings, the mascot stands beneath the list under
    /// the theme's own legibility (like its sidebar picture), a moment's shower is gone before
    /// anything under it can be read, and words are checked for length, not meaning.
    nonisolated private static func validateCharacter(_ variant: AppTheme.Variant) throws {
        guard variant.sprites.count <= ThemeSpriteLimits.maximumSprites else {
            throw AppThemeEditingError.invalid(
                "sprites holds at most \(ThemeSpriteLimits.maximumSprites) pictures per variant."
            )
        }
        var library = Set<String>()
        for sprite in variant.sprites {
            guard ThemeSprite.isValidName(sprite.name) else {
                throw AppThemeEditingError.invalid(
                    "sprites names are 1 to \(ThemeSpriteLimits.maximumNameLength) lowercase "
                        + "letters, digits, - or _; \"\(sprite.name)\" is not."
                )
            }
            guard library.insert(sprite.name).inserted else {
                throw AppThemeEditingError.invalid(
                    "sprites states \"\(sprite.name)\" twice; each name is one picture."
                )
            }
            guard !sprite.asset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppThemeEditingError.invalid(
                    "sprites.\(sprite.name) names no stored picture."
                )
            }
        }

        if let mascot = variant.sidebar?.mascot {
            try validate(mascot)
        }

        if let moments = variant.moments {
            for event in ThemeMomentEvent.allCases {
                guard let moment = moments[event] else { continue }
                let prefix = "moments.\(event.rawValue)"
                guard !moment.isEmpty else {
                    throw AppThemeEditingError.invalid(
                        "\(prefix) states neither particles nor a sound — remove it instead."
                    )
                }
                if let particles = moment.particles {
                    try validate(particles, prefix: "\(prefix).particles")
                }
                guard ThemeMomentLimits.durationRange.contains(moment.duration) else {
                    throw AppThemeEditingError.invalid(
                        "\(prefix).duration must be between "
                            + "\(ThemeMomentLimits.durationRange.lowerBound) and "
                            + "\(ThemeMomentLimits.durationRange.upperBound) seconds."
                    )
                }
                if let sound = moment.sound,
                   sound.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw AppThemeEditingError.invalid("\(prefix).sound names no stored sound.")
                }
            }
        }

        if let words = variant.words {
            try validate(words)
        }

        // Every sprite a particle block names has to be in this variant's library: the two
        // halves of an adaptive theme keep libraries of their own, and a dark block naming a
        // light-only picture would silently draw the host shape instead.
        for (prefix, particles) in particleBlocks(of: variant) {
            for name in particles.sprites where !library.contains(name) {
                throw AppThemeEditingError.invalid(
                    "\(prefix).sprites names \"\(name)\", which this variant's sprites "
                        + "library does not hold."
                )
            }
        }
    }

    /// Every particle block a variant states, with the field name an error should point at.
    nonisolated static func particleBlocks(
        of variant: AppTheme.Variant
    ) -> [(prefix: String, particles: ThemeParticles)] {
        var blocks: [(String, ThemeParticles)] = []
        if let particles = variant.sidebar?.background?.particles {
            blocks.append(("sidebar.particles", particles))
        }
        if let particles = variant.sidebar?.brand?.motion?.particles {
            blocks.append(("sidebar.logo_motion.particles", particles))
        }
        if let particles = variant.material.backdrop?.particles {
            blocks.append(("material.backdrop.particles", particles))
        }
        if let particles = variant.transition?.particles {
            blocks.append(("transition.particles", particles))
        }
        if let mascot = variant.sidebar?.mascot {
            for mood in ThemeMascotMood.allCases {
                if let particles = mascot.poses[mood]?.particles {
                    blocks.append(("sidebar.mascot.poses.\(mood.rawValue).particles", particles))
                }
            }
        }
        for event in ThemeMomentEvent.allCases {
            if let particles = variant.moments?[event]?.particles {
                blocks.append(("moments.\(event.rawValue).particles", particles))
            }
        }
        return blocks
    }

    nonisolated private static func validate(_ mascot: ThemeMascot) throws {
        guard mascot.poses[.idle] != nil else {
            throw AppThemeEditingError.invalid(
                "sidebar.mascot needs an idle pose; every mood without its own borrows it."
            )
        }
        guard ThemeMascotLimits.sizeRange.contains(mascot.size) else {
            throw AppThemeEditingError.invalid(
                "sidebar.mascot.size must be between "
                    + "\(Int(ThemeMascotLimits.sizeRange.lowerBound)) and "
                    + "\(Int(ThemeMascotLimits.sizeRange.upperBound)) points."
            )
        }
        for mood in ThemeMascotMood.allCases {
            guard let pose = mascot.poses[mood] else { continue }
            let prefix = "sidebar.mascot.poses.\(mood.rawValue)"
            guard !pose.asset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppThemeEditingError.invalid("\(prefix) names no stored picture.")
            }
            if let every = pose.every {
                guard ThemeMascotLimits.everyRange.contains(every) else {
                    throw AppThemeEditingError.invalid(
                        "\(prefix).every must be between "
                            + "\(ThemeMascotLimits.everyRange.lowerBound) and "
                            + "\(ThemeMascotLimits.everyRange.upperBound) seconds."
                    )
                }
            }
            if let particles = pose.particles {
                try validate(particles, prefix: "\(prefix).particles")
            }
            if let origin = pose.origin {
                guard (0...1).contains(origin.x), (0...1).contains(origin.y) else {
                    throw AppThemeEditingError.invalid(
                        "\(prefix).origin x and y must be between 0 and 1."
                    )
                }
            }
        }
    }

    nonisolated private static func validate(_ words: ThemeWords) throws {
        guard words.working.count <= ThemeWordsLimits.maximumWorkingWords else {
            throw AppThemeEditingError.invalid(
                "words.working takes at most \(ThemeWordsLimits.maximumWorkingWords) words."
            )
        }
        for word in words.working {
            let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty,
                  clean.count <= ThemeWordsLimits.maximumWorkingWordLength,
                  !clean.contains(where: \.isNewline) else {
                throw AppThemeEditingError.invalid(
                    "words.working entries are one line of 1 to "
                        + "\(ThemeWordsLimits.maximumWorkingWordLength) characters."
                )
            }
        }
        if let placeholder = words.composerPlaceholder {
            let clean = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty,
                  clean.count <= ThemeWordsLimits.maximumPlaceholderLength,
                  !clean.contains(where: \.isNewline) else {
                throw AppThemeEditingError.invalid(
                    "words.composer_placeholder is one line of 1 to "
                        + "\(ThemeWordsLimits.maximumPlaceholderLength) characters."
                )
            }
        }
    }

    /// A transition's gates are bounds: its particles cross the window for at most
    /// `transitionDurationRange` and its wash never quite replaces the chrome. Nothing here is
    /// measured for contrast — the overlay passes the pointer through, is silent to
    /// accessibility, and is gone before anything under it can be read or pressed.
    nonisolated private static func validate(
        _ transition: ThemeTransition,
        kind: AppTheme.VariantKind
    ) throws {
        try validate(transition.particles, prefix: "transition.particles")
        guard ThemeParticleLimits.transitionDurationRange.contains(transition.duration) else {
            throw AppThemeEditingError.invalid(
                "transition.duration must be between "
                    + "\(ThemeParticleLimits.transitionDurationRange.lowerBound) and "
                    + "\(ThemeParticleLimits.transitionDurationRange.upperBound) seconds."
            )
        }
        guard (0...ThemeParticleLimits.maximumWashOpacity).contains(transition.washOpacity) else {
            throw AppThemeEditingError.invalid(
                "transition.wash_opacity must be between 0 and "
                    + "\(ThemeParticleLimits.maximumWashOpacity)."
            )
        }
    }

    /// The bounds every particle block is held to, wherever it is stated.
    nonisolated private static func validate(
        _ particles: ThemeParticles,
        prefix: String
    ) throws {
        guard particles.colors.count <= ThemeParticleLimits.maximumColors else {
            throw AppThemeEditingError.invalid(
                "\(prefix).colors takes at most \(ThemeParticleLimits.maximumColors) inks."
            )
        }
        guard particles.sprites.count <= ThemeParticleLimits.maximumSprites else {
            throw AppThemeEditingError.invalid(
                "\(prefix).sprites names at most \(ThemeParticleLimits.maximumSprites) pictures."
            )
        }
        guard particles.shape == nil || particles.sprites.isEmpty else {
            throw AppThemeEditingError.invalid(
                "\(prefix) states both a shape and sprites — name one or the other."
            )
        }
        guard ThemeParticleLimits.densityRange.contains(particles.density) else {
            throw AppThemeEditingError.invalid("\(prefix).density must be between 0 and 1.")
        }
        if let size = particles.size {
            guard ThemeParticleLimits.sizeRange.contains(size) else {
                throw AppThemeEditingError.invalid(
                    "\(prefix).size must be between "
                        + "\(Int(ThemeParticleLimits.sizeRange.lowerBound)) and "
                        + "\(Int(ThemeParticleLimits.sizeRange.upperBound)) points."
                )
            }
        }
        guard ThemeParticleLimits.speedRange.contains(particles.speed) else {
            throw AppThemeEditingError.invalid(
                "\(prefix).speed must be between "
                    + "\(ThemeParticleLimits.speedRange.lowerBound) and "
                    + "\(ThemeParticleLimits.speedRange.upperBound)."
            )
        }
        guard ThemeParticleLimits.opacityRange.contains(particles.opacity) else {
            throw AppThemeEditingError.invalid("\(prefix).opacity must be between 0 and 1.")
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
            guard gradient.drift == nil else {
                throw AppThemeEditingError.invalid("chrome.\(name) does not support backdrop drift.")
            }
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

        // A band that seats the window's commands has to be tall enough to hold one. A toolbar
        // control states its height as required, so a shorter band does not squeeze it — it
        // breaks constraints and draws the row outside itself, which is a thing the document
        // can say and therefore a thing the document is answered for.
        if titleBar.commands == .inTitleBar {
            let height = titleBar.height ?? WindowChromeStyleLimits.defaultBandHeight
            guard height >= WindowChromeStyleLimits.commandsInTitleBarMinimumHeight else {
                throw AppThemeEditingError.invalid(
                    "chrome.title_bar.commands \"in_title_bar\" needs a band of at least "
                        + "\(Int(WindowChromeStyleLimits.commandsInTitleBarMinimumHeight)) "
                        + "points to seat the window's own commands; this one is "
                        + "\(Int(height))."
                )
            }
        }

        if let fontSize = titleBar.titleFontSize {
            guard WindowChromeStyleLimits.titleFontSizeRange.contains(fontSize) else {
                throw AppThemeEditingError.invalid(
                    "chrome.title_bar.title_font_size must be between "
                        + "\(Int(WindowChromeStyleLimits.titleFontSizeRange.lowerBound)) and "
                        + "\(Int(WindowChromeStyleLimits.titleFontSizeRange.upperBound)) points."
                )
            }
        }

        if let tabWidth = titleBar.tabWidth {
            guard WindowChromeStyleLimits.tabWidthRange.contains(tabWidth) else {
                throw AppThemeEditingError.invalid(
                    "chrome.title_bar.tab_width must be between "
                        + "\(Int(WindowChromeStyleLimits.tabWidthRange.lowerBound)) and "
                        + "\(Int(WindowChromeStyleLimits.tabWidthRange.upperBound)) points."
                )
            }
        }

        guard !titleBar.visibleButtons.isEmpty else {
            throw AppThemeEditingError.invalid(
                "chrome.title_bar.visible_buttons must contain at least one window operation."
            )
        }
        guard Set(titleBar.visibleButtons.map(\.rawValue)).count
            == titleBar.visibleButtons.count else {
            throw AppThemeEditingError.invalid(
                "chrome.title_bar.visible_buttons cannot repeat a window operation."
            )
        }

        for (name, texture) in [
            ("active_texture", titleBar.activeTexture),
            ("inactive_texture", titleBar.inactiveTexture)
        ] {
            guard let spacing = texture?.spacing else { continue }
            guard WindowChromeStyleLimits.textureSpacingRange.contains(spacing) else {
                throw AppThemeEditingError.invalid(
                    "chrome.title_bar.\(name).spacing must be between "
                        + "\(Int(WindowChromeStyleLimits.textureSpacingRange.lowerBound)) and "
                        + "\(Int(WindowChromeStyleLimits.textureSpacingRange.upperBound)) points."
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
            guard WindowChromeStyleLimits.frameCornerRadiusRange.contains(
                frame.cornerRadius
            ) else {
                throw AppThemeEditingError.invalid(
                    "chrome.frame.corner_radius must be between "
                        + "\(Int(WindowChromeStyleLimits.frameCornerRadiusRange.lowerBound)) and "
                        + "\(Int(WindowChromeStyleLimits.frameCornerRadiusRange.upperBound)) points."
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

        if let background = sidebar.background {
            try validate(
                background,
                prefix: "sidebar",
                subject: "sidebar text on the gradient stop",
                kind: kind,
                label: resolved.resolved(.label, appearance: appearance),
                ground: resolved.resolved(.surface, appearance: appearance)
            )
        }

        if let brand = sidebar.brand {
            if case .asset(let name) = brand.logo,
               name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AppThemeEditingError.invalid("sidebar.brand.logo names no asset.")
            }
            let label = resolved.resolved(.label, appearance: appearance)
            let surface = resolved.resolved(.surface, appearance: appearance)
            if let band = brand.band {
                // A band is drawn still — it is the ground the header's controls are measured
                // against — so a drift there would be accepted and never played.
                guard band.gradient.drift == nil else {
                    throw AppThemeEditingError.invalid("sidebar.band does not support gradient drift.")
                }
                // The band is the header's ground, and it carries the `+` that adds a project:
                // held to the label floor against every stop, like the sidebar's own wash.
                try validate(
                    ThemeBackdrop(gradient: band.gradient),
                    prefix: "sidebar.band",
                    subject: "header ink on the band stop",
                    kind: kind,
                    label: band.ink ?? label,
                    ground: surface
                )
            }
            if let color = brand.title?.color {
                // The wordmark sits on the band when there is one, and on the sidebar's own
                // ground and wash otherwise — so that is what it is measured against.
                if let band = brand.band {
                    try validate(
                        ThemeBackdrop(gradient: band.gradient),
                        prefix: "sidebar.band",
                        subject: "the title colour on the band stop",
                        kind: kind,
                        label: color,
                        ground: surface
                    )
                } else {
                    let ground = composite(surface, over: resolved.resolved(.ground, appearance: appearance))
                    let ratio = ThemeContrast.ratio(composite(color, over: ground), ground)
                    guard ratio >= ThemeContrast.minimumRatio else {
                        throw AppThemeEditingError.invalid(
                            "\(kind.rawValue) sidebar title colour \(color.hexString) on the "
                                + "sidebar surface has \(formatted(ratio)):1 contrast; "
                                + "at least \(Int(ThemeContrast.minimumRatio)):1 is required."
                        )
                    }
                    if let wash = sidebar.background, wash.gradient != nil {
                        try validate(
                            ThemeBackdrop(gradient: wash.gradient),
                            prefix: "sidebar",
                            subject: "the title colour on the gradient stop",
                            kind: kind,
                            label: color,
                            ground: surface
                        )
                    }
                }
            }
            if let motion = brand.motion {
                // The Threading mark is drawn live and already has gestures of its own; a
                // theme's motion is for the image it supplied.
                guard case .asset = brand.logo else {
                    throw AppThemeEditingError.invalid(
                        "sidebar.logo_motion moves the theme's own logo image — supply a logo "
                            + "image, or remove_logo_motion. The Threading mark keeps its own "
                            + "gestures."
                    )
                }
                if let particles = motion.particles {
                    try validate(particles, prefix: "sidebar.logo_motion.particles")
                }
                if let origin = motion.origin {
                    guard (0...1).contains(origin.x), (0...1).contains(origin.y) else {
                        throw AppThemeEditingError.invalid(
                            "sidebar.logo_motion.origin x and y must be between 0 and 1."
                        )
                    }
                }
            }
            if brand.dockIcon {
                guard case .asset = brand.logo else {
                    throw AppThemeEditingError.invalid(
                        "sidebar.logo_in_dock puts the theme's own logo image on the Dock tile "
                            + "— supply a logo image, or turn it off."
                    )
                }
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

    /// The gates a backdrop faces wherever it is stated: the sidebar's block against the
    /// surface it sits on, the material's against the ground. The gradient gets the terminal
    /// palette's treatment — each stop composited over `ground`, then the label composited
    /// over that, must keep the label at the same 3:1 floor. An image cannot be measured this
    /// way (its pixels are arbitrary), so its gates are bounds, and legibility stays the
    /// author's to check by looking.
    nonisolated private static func validate(
        _ backdrop: ThemeBackdrop,
        prefix: String,
        subject: String,
        kind: AppTheme.VariantKind,
        label: NSColor,
        ground: NSColor
    ) throws {
        if let gradient = backdrop.gradient {
            guard gradient.angleDegrees.isFinite else {
                throw AppThemeEditingError.invalid("\(prefix).gradient angle must be finite.")
            }
            if let drift = gradient.drift, !drift.isValid {
                throw AppThemeEditingError.invalid(
                    "\(prefix).gradient.drift needs a duration of 8–120 seconds and distance of 0.02–0.25."
                )
            }
            guard (2...ThemeBackdropLimits.maximumGradientStops).contains(gradient.stops.count) else {
                throw AppThemeEditingError.invalid(
                    "\(prefix).gradient needs 2 to \(ThemeBackdropLimits.maximumGradientStops) stops."
                )
            }
            guard gradient.stops.allSatisfy({ (0...1).contains($0.position) }) else {
                throw AppThemeEditingError.invalid(
                    "\(prefix).gradient stop positions must be between 0 and 1."
                )
            }
            for stop in gradient.stops {
                // A stop may be translucent; what the label actually sits on is the stop
                // composited over the ground beneath it, so that is what gets measured.
                let effectiveGround = ground.composited(under: stop.color)
                let ink = effectiveGround.composited(under: label)
                let ratio = ThemeContrast.ratio(ink, effectiveGround)
                guard ratio >= ThemeContrast.minimumRatio else {
                    throw AppThemeEditingError.invalid(
                        "\(kind.rawValue) \(subject) "
                            + "\(stop.color.hexString) has \(formatted(ratio)):1 contrast; "
                            + "at least \(Int(ThemeContrast.minimumRatio)):1 is required."
                    )
                }
            }
        }

        if let image = backdrop.image {
            guard (0...1).contains(image.opacity) else {
                throw AppThemeEditingError.invalid(
                    "\(prefix).image.opacity must be between 0 and 1."
                )
            }
            guard !image.asset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppThemeEditingError.invalid("\(prefix).image names no asset.")
            }
        }

        if let particles = backdrop.particles {
            try validate(particles, prefix: "\(prefix).particles")
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
