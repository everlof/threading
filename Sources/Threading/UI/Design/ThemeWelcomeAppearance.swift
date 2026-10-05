import AppKit

// MARK: - Theme Welcome Appearance

/// Resolves a theme's welcome (`ThemeWelcome`) into drawable values for one appearance, so the
/// components that draw it — the ground, the mark, the scrims — and the composer that sets its
/// words never read a theme document themselves.
///
/// Nothing here is new resolution. The backdrop goes through `ThemeBackdropAppearance.resolve`,
/// the one door every backdrop region uses; the logo is the sidebar brand's own picture and the
/// mascot the sidebar's own, resolved through `SidebarAppearance`; inks are `ThemeInk`s resolved
/// against the theme in force. Absence at every level is the app's own composer, and a mark the
/// theme cannot draw — a `logo` with no picture, a `mascot` with no idle pose — is the app's mark
/// rather than a hole, the dangling-reference rule every theme lookup follows.
///
/// Every reading takes the welcome it reads, so a preview (the Component Gallery, a render) can
/// state one without installing a theme; `welcome(for:)` is the theme in force's.
@MainActor
enum ThemeWelcomeAppearance {

    // MARK: - Welcome

    /// The welcome the variant in force for `appearance` states, or nil for the app's own.
    static func welcome(for appearance: NSAppearance) -> ThemeWelcome? {
        AppThemePalette.current.variant(for: appearance)?.welcome
    }

    // MARK: - Backdrop

    /// The welcome's backdrop as drawable values, or nil when it states none or nothing in it
    /// resolves. Pictures resolve through the tier that owns the theme in force.
    static func backdrop(
        _ welcome: ThemeWelcome?,
        appearance: NSAppearance
    ) -> ThemeBackdropAppearance.Resolved? {
        guard let stated = welcome?.backdrop else { return nil }
        return ThemeBackdropAppearance.resolve(
            stated,
            themeID: AppThemePalette.current.id,
            appearance: appearance
        )
    }

    /// The single colour the eye reads the welcome's ground as: the backdrop gradient's stops
    /// composited over the `ground` role and averaged, or the ground itself without one — the
    /// ground the welcome's inks are validated against, and what glyphs are smoothed against.
    static func ground(_ welcome: ThemeWelcome?, appearance: NSAppearance) -> NSColor {
        var ground = AppThemePalette.current.resolved(.ground, appearance: appearance)
        appearance.performAsCurrentDrawingAppearance {
            let base = ground.usingColorSpace(.sRGB) ?? ground
            // The stated gradient only: a picture would have to be decoded to be averaged,
            // and this is asked whenever a line restates its ink.
            guard let colors = welcome?.backdrop?.gradient
                .flatMap(ThemeBackdropAppearance.gradient)?.colors
                .compactMap({ $0.composited(over: base).usingColorSpace(.sRGB) }),
                  !colors.isEmpty else {
                ground = base
                return
            }
            let count = CGFloat(colors.count)
            ground = NSColor(
                srgbRed: colors.map(\.redComponent).reduce(0, +) / count,
                green: colors.map(\.greenComponent).reduce(0, +) / count,
                blue: colors.map(\.blueComponent).reduce(0, +) / count,
                alpha: 1
            )
        }
        return ground
    }

    // MARK: - Mark

    /// What stands above the greeting, with what it needs to be drawn.
    enum Mark: Equatable {
        /// The Threading mark, drawn live.
        case app
        /// The sidebar brand's own picture.
        case logo(NSImage)
        /// The sidebar's mascot, in the window's mood.
        case mascot(SidebarAppearance.Mascot)
        /// Nothing: the greeting stands alone. Named apart from `Optional.none` so a `Mark?`
        /// can never be read as one.
        case hidden
    }

    static func mark(_ welcome: ThemeWelcome?, appearance: NSAppearance) -> Mark {
        // Unwrapped first: an absent mark is the app's, never confused with a hidden one.
        let stated: ThemeWelcome.Mark = welcome?.mark ?? .app
        switch stated {
        case .app:
            return .app
        case .hidden:
            return .hidden
        case .logo:
            guard case .image(let image) = SidebarAppearance.brand(for: appearance).logo else {
                return .app
            }
            return .logo(image)
        case .mascot:
            return SidebarAppearance.mascot(for: appearance).map(Mark.mascot) ?? .app
        }
    }

    /// The mark's side in points: the welcome's, held to `ThemeWelcomeLimits.markSides`, or the
    /// host's own when it states none.
    static func markSide(_ welcome: ThemeWelcome?, default fallback: CGFloat) -> CGFloat {
        guard let stated = welcome?.markSize, stated.isFinite else { return fallback }
        let limits = ThemeWelcomeLimits.markSides
        return CGFloat(min(max(stated, limits.lowerBound), limits.upperBound))
    }

    // MARK: - Scrim

    /// The veils' peak opacities, held to `ThemeWelcomeLimits.scrimOpacities`. Zero is no veil.
    struct Scrim: Equatable {
        var hero: CGFloat = 0
        var prompt: CGFloat = 0

        var isEmpty: Bool { hero <= 0 && prompt <= 0 }
    }

    static func scrim(_ welcome: ThemeWelcome?) -> Scrim {
        guard let stated = welcome?.scrim else { return Scrim() }
        let limits = ThemeWelcomeLimits.scrimOpacities
        func clamp(_ value: Double?) -> CGFloat {
            guard let value, value.isFinite else { return 0 }
            return CGFloat(min(max(value, limits.lowerBound), limits.upperBound))
        }
        return Scrim(hero: clamp(stated.hero), prompt: clamp(stated.prompt))
    }

    // MARK: - Words

    /// The two lines a welcome sets.
    enum Line {
        case greeting
        case caption
    }

    /// The pool a line is picked from, or nil when the welcome leaves it to the app.
    static func wording(_ line: Line, of welcome: ThemeWelcome?) -> ThemeWelcome.Wording? {
        switch line {
        case .greeting: return welcome?.greeting
        case .caption: return welcome?.caption
        }
    }

    /// The ink a line is drawn in when the welcome states one, resolved against the theme in
    /// force; nil leaves the line the app's own ink.
    static func ink(_ line: Line, of welcome: ThemeWelcome?, appearance: NSAppearance) -> NSColor? {
        guard let ink = wording(line, of: welcome)?.style?.ink else { return nil }
        var color: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            color = ink.resolved(in: AppThemePalette.current, appearance: appearance)
        }
        return color
    }
}
