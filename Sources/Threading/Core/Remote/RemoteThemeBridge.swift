import AppKit
import ThreadingRemoteKit

/// Turns the Mac's resolved theme state into platform-neutral wire values.
///
/// Remote clients intentionally receive resolved colours, not a variant document. Custom themes
/// exist only on this Mac, and adaptive themes may change variant with its appearance; resolving
/// here makes both portable while preserving session/project terminal overrides.
@MainActor
enum RemoteThemeBridge {

    static func appTheme() -> RemoteThemeDTO {
        appTheme(AppThemeLibrary.current)
    }

    /// The current theme as `authorization` may use it. Fonts and the extension surface's
    /// shader are owner-only on the asset route, so a collaborator is not told their digests,
    /// family names or the surface recipe either.
    static func appTheme(for authorization: RemoteAuthorization?) -> RemoteThemeDTO {
        appTheme(AppThemeLibrary.current, includesOwnerAssets: receivesOwnerAssets(authorization))
    }

    static func receivesOwnerAssets(_ authorization: RemoteAuthorization?) -> Bool {
        authorization?.canReadHostUsage == true
    }

    /// Catalogue entries carry no welcome: a chooser previews palettes, the welcome follows the
    /// theme once it is in force, and up to 64 lines per pool across every custom theme is
    /// weight the catalogue has no use for.
    static func catalog(for authorization: RemoteAuthorization? = nil) -> RemoteThemeCatalogDTO {
        let ownerAssets = authorization.map(receivesOwnerAssets) ?? true
        return RemoteThemeCatalogDTO(
            appThemes: AppThemeLibrary.all.map {
                appTheme($0, includesOwnerAssets: ownerAssets, includesWelcome: false)
            },
            terminalThemes: ThemeAssignments.selectableThemes.map(terminalTheme)
        )
    }

    /// The chrome block and the material's bevel are deliberately not projected: the remote
    /// client has no window frame to dress and no bevel interpreter, and a DTO field nothing
    /// renders is churn. Extension executables stay on the Mac; one reviewed Metal backdrop
    /// recipe, process-scoped theme fonts, notification cues and terminal glow now have phone
    /// consumers, alongside typeface hints, title morphs, identity ink, particles and images.
    /// The two bevel roles ride along in the resolved colour map like every
    /// role — harmless, and a future client that learns to bevel finds its colours waiting.
    ///
    /// The welcome is projected for the same variant, with its inks resolved. The owner's given
    /// name rides along only when `includesOwnerAssets` — an owner's connection — and only when
    /// a line names `{user}`; `ownerName` is injectable so a test states a person.
    static func appTheme(
        _ theme: AppTheme,
        includesOwnerAssets: Bool = true,
        includesWelcome: Bool = true,
        ownerName: () -> String? = { RemoteThemeBridge.ownerGivenName }
    ) -> RemoteThemeDTO {
        var colors: [String: String] = [:]
        var mode = RemoteThemeMode(rawValue: theme.mode.rawValue)
        var glowColor: String?
        var backdropGradient: RemoteThemeGradient?
        var material = AppTheme.Material.system
        var words: RemoteThemeDTO.Words?
        var welcome: RemoteThemeWelcome?
        let appearance = drawingAppearance(for: theme)
        // A guest's projection carries no name, so on a guest's phone `{user}` lines are
        // ineligible, as a `{project}` line is without a project.
        let user = includesOwnerAssets ? ownerName() : nil

        appearance.performAsCurrentDrawingAppearance {
            if theme.isAdaptive {
                mode = NSAppearance.currentDrawing()
                    .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .dark
                    : .light
            }
            material = theme.variant(for: appearance)?.material ?? theme.material
            if !theme.isSystem, let stated = theme.variant(for: appearance)?.words {
                words = remoteWords(stated)
            }
            if let gradient = material.backdrop?.gradient,
               (2...ThemeBackdropLimits.maximumGradientStops).contains(gradient.stops.count),
               gradient.angleDegrees.isFinite,
               gradient.stops.allSatisfy({ (0...1).contains($0.position) }) {
                backdropGradient = RemoteThemeGradient(
                    stops: gradient.stops.map { .init(color: $0.color.hexString, position: $0.position) },
                    angleDegrees: gradient.angleDegrees,
                    drift: gradient.drift
                )
            }
            for role in AppThemeRole.allCases {
                var resolved = theme.resolved(role, appearance: appearance)
                // The Mac holds every rule to `Material.ruleInkBudget` at draw time
                // (`Design.Surface.divider`); remote clients draw their rules straight from
                // this value, so the projection carries the capped ink rather than each
                // client re-learning the budget.
                if role == .divider, let srgb = resolved.usingColorSpace(.sRGB) {
                    resolved = srgb.withAlphaComponent(
                        min(srgb.alphaComponent, material.ruleInkCeiling)
                    )
                }
                colors[role.wireName] = resolved.hexString
            }
            if let glow = material.glow {
                glowColor = theme.resolved(glow.role, appearance: appearance).hexString
            }
            if includesWelcome, !theme.isSystem,
               let stated = theme.variant(for: appearance)?.welcome, !stated.isEmpty {
                welcome = remoteWelcome(
                    stated,
                    theme: theme,
                    appearance: appearance,
                    user: user
                )
            }
        }

        let glow = material.glow.flatMap { materialGlow in
            glowColor.map {
                RemoteThemeDTO.Material.Glow(
                    color: $0,
                    radius: Double(materialGlow.radius),
                    opacity: materialGlow.opacity,
                    offsetX: Double(materialGlow.offsetX),
                    offsetY: Double(materialGlow.offsetY)
                )
            }
        }
        return RemoteThemeDTO(
            id: theme.id.rawValue,
            name: theme.name,
            mode: mode,
            colors: colors,
            material: .init(
                panelRadius: Double(material.panelRadius),
                controlRadius: Double(material.controlRadius),
                borderWidth: Double(material.borderWidth),
                glow: glow,
                textScale: Double(material.textScale),
                typeface: RemoteThemeTypeface(rawValue: material.typeface.rawValue),
                // This bridge promises resolved, portable state. Send the first named family the
                // host can actually use rather than an unavailable historical preference; a
                // remote client cannot reproduce this Mac's fallback search for itself.
                fontFamily: material.fontFamilies.first {
                    Design.Typography.availableFamilies.contains($0)
                },
                backdropGradient: backdropGradient,
                identityMarks: material.identityMarks.rawValue,
                particles: material.backdrop?.particles.map {
                    remoteParticles($0, variant: theme.variant(for: appearance))
                }
            ),
            words: words,
            titleMorph: theme.variant(for: appearance)?.titleMorph.map {
                .init(style: $0.style.rawValue, characters: $0.characters)
            },
            assets: RemoteThemeAssets.shared.manifest(for: theme, appearance: appearance).flatMap { manifest in
                let visible = manifest.filter { includesOwnerAssets || !$0.requiresOwner }
                return visible.isEmpty ? nil : visible
            },
            surface: includesOwnerAssets && theme.id == AppThemeLibrary.current.id
                ? RemoteThemeAssets.shared.surface : nil,
            welcome: welcome
        )
    }

    /// A particle field as the phone's renderer takes it: inks as wire words it resolves
    /// against the palette, sprites as the asset slots their pictures travel in.
    private static func remoteParticles(
        _ particles: ThemeParticles,
        variant: AppTheme.Variant?
    ) -> RemoteThemeParticles {
        RemoteThemeParticles(
            style: particles.style, shape: particles.shape,
            colors: particles.colors.map(\.wireValue),
            density: particles.density, size: particles.size, speed: particles.speed,
            opacity: particles.opacity,
            sprites: particles.sprites.compactMap { name in
                variant?.sprites.firstIndex { $0.name == name }.map { "sprite.\($0)" }
            }
        )
    }

    // MARK: - Welcome

    /// The person the Mac greets, parsed once: it does not change while the app runs.
    static let ownerGivenName: String? = ComposerWelcome.givenName(from: NSFullUserName())

    /// The variant's welcome for the phone's new-chat screen, resolved in `appearance` (the
    /// caller's current drawing appearance). Lines cross as written; inks, families and the
    /// backdrop's gradient arrive resolved; the picture travels as the `welcome` asset.
    private static func remoteWelcome(
        _ welcome: ThemeWelcome,
        theme: AppTheme,
        appearance: NSAppearance,
        user: String?
    ) -> RemoteThemeWelcome? {
        // One snapshot of the families for both styles; the list is CoreText's, not a constant.
        let statesFamily = [welcome.greeting, welcome.caption].contains { $0?.style?.fontFamily != nil }
        let families = statesFamily ? Set(Design.Typography.availableFamilies) : []
        func style(_ stated: ThemeWelcome.TextStyle?) -> RemoteThemeWelcome.Style? {
            guard let stated else { return nil }
            let projected = RemoteThemeWelcome.Style(
                scale: stated.scale,
                weight: stated.weight.map { RemoteThemeWelcome.Weight(rawValue: $0.rawValue) },
                ink: stated.ink.map { $0.resolved(in: theme, appearance: appearance).hexString },
                fontFamily: stated.fontFamily.flatMap { families.contains($0) ? $0 : nil },
                typeface: stated.typeface.map { RemoteThemeTypeface(rawValue: $0.rawValue) }
            )
            return projected.isEmpty ? nil : projected
        }
        func wording(_ stated: ThemeWelcome.Wording?, hostLines: Bool) -> RemoteThemeWelcome.Wording? {
            stated.map {
                .init(lines: $0.lines, includesAppLines: hostLines && $0.includesAppLines, style: style($0.style))
            }
        }
        let backdrop = welcome.backdrop.flatMap { stated -> RemoteThemeWelcome.Backdrop? in
            guard !stated.isEmpty else { return nil }
            let gradient = stated.gradient.flatMap { gradient -> RemoteThemeGradient? in
                guard (2...ThemeBackdropLimits.maximumGradientStops).contains(gradient.stops.count),
                      gradient.angleDegrees.isFinite,
                      gradient.stops.allSatisfy({ (0...1).contains($0.position) }) else { return nil }
                return RemoteThemeGradient(
                    stops: gradient.stops.map { .init(color: $0.color.hexString, position: $0.position) },
                    angleDegrees: gradient.angleDegrees,
                    drift: gradient.drift
                )
            }
            return .init(
                gradient: gradient,
                particles: stated.particles.map { remoteParticles($0, variant: theme.variant(for: appearance)) }
            )
        }
        let lines = (welcome.greeting?.lines ?? []) + (welcome.caption?.lines ?? [])
        let projected = RemoteThemeWelcome(
            mark: welcome.mark.map { RemoteThemeWelcome.Mark(rawValue: $0.rawValue) },
            markSize: welcome.markSize,
            greeting: wording(welcome.greeting, hostLines: true),
            caption: wording(welcome.caption, hostLines: false),
            scrim: welcome.scrim.map { .init(hero: $0.hero, prompt: $0.prompt) },
            backdrop: backdrop,
            user: RemoteThemeWelcome.namesUser(in: lines) ? user : nil
        )
        return projected.isEmpty ? nil : projected
    }

    /// The theme's words, cleaned as the Mac uses them (`ThemeWording`): empty slots are left
    /// out so the phone's own copy answers for them.
    private static func remoteWords(_ words: ThemeWords) -> RemoteThemeDTO.Words? {
        func cleaned(_ value: String?) -> String? {
            let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean?.isEmpty == false ? clean : nil
        }
        let working = words.working.compactMap { cleaned($0) }
        let remote = RemoteThemeDTO.Words(
            working: working.isEmpty ? nil : working,
            composerPlaceholder: cleaned(words.composerPlaceholder),
            untitledSession: cleaned(words.untitledSession)
        )
        return remote == RemoteThemeDTO.Words() ? nil : remote
    }

    static func terminalTheme(for sessionID: SessionID) -> RemoteTerminalThemeDTO {
        terminalTheme(ThemeAssignments.theme(for: sessionID))
    }

    static func terminalTheme(for terminalID: TerminalID) -> RemoteTerminalThemeDTO {
        terminalTheme(ThemeAssignments.theme(forTerminal: terminalID))
    }

    static func terminalTheme(_ theme: TerminalTheme) -> RemoteTerminalThemeDTO {
        return RemoteTerminalThemeDTO(
            id: theme.id.rawValue,
            name: theme.name,
            foreground: theme.foreground.hexString,
            boldForeground: theme.boldForeground.hexString,
            background: theme.background.hexString,
            cursor: theme.cursor.hexString,
            selection: theme.selection.hexString,
            ansi: [
                theme.black, theme.red, theme.green, theme.yellow,
                theme.blue, theme.magenta, theme.cyan, theme.white,
                theme.brightBlack, theme.brightRed, theme.brightGreen, theme.brightYellow,
                theme.brightBlue, theme.brightMagenta, theme.brightCyan, theme.brightWhite,
            ].map(\.hexString),
            glow: theme.glow.map { .init(radius: Double($0.radius), opacity: Double($0.opacity)) }
        )
    }

    /// A fixed app theme pins `NSApp.appearance`; using that pinned appearance to preview an
    /// inactive adaptive choice would resolve the wrong variant. Read the user's global mode
    /// for adaptive catalogue entries unless one is already active.
    static func drawingAppearance(for theme: AppTheme) -> NSAppearance {
        guard theme.isAdaptive else { return theme.mode.appearance ?? NSApp.effectiveAppearance }
        if AppThemeLibrary.current.isAdaptive { return NSApp.effectiveAppearance }
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
    }

    static func update(for sessionID: SessionID, authorization: RemoteAuthorization? = nil) -> RemoteThemeUpdateDTO {
        RemoteThemeUpdateDTO(
            theme: authorization.map { appTheme(for: $0) } ?? appTheme(),
            terminalTheme: terminalTheme(for: sessionID)
        )
    }
}
