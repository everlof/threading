import AppKit

// MARK: - Sidebar Appearance

/// Resolves the current theme's `SidebarStyle` into drawable values — decoded images, gradient
/// colours, the wordmark's text and font recipe — so the two views that dress the sidebar
/// (`SidebarBackdropView`, `SidebarBrandView`) never touch asset stores or registries
/// themselves.
///
/// Assets resolve through the tier that owns the theme: a contributed theme's bytes were read
/// out of its package at inspection (`ExtensionAppearanceRegistry`), a custom theme's live in
/// `ThemeAssetStore`. A name neither can answer degrades to the default treatment — the
/// dangling-reference rule every theme lookup here follows. The registry is consulted first
/// only because contributed ids are namespaced; the two stores cannot actually collide.
@MainActor
enum SidebarAppearance {

    // MARK: - Background

    struct Background: Equatable {
        var gradient: Gradient?
        var image: ImageLayer?

        struct Gradient: Equatable {
            let colors: [NSColor]
            let locations: [CGFloat]
            /// CSS convention, as authored: degrees clockwise from "toward the top".
            let angleDegrees: CGFloat
        }

        struct ImageLayer: Equatable {
            let image: NSImage
            let mode: SidebarStyle.ImageLayer.Mode
            let opacity: CGFloat
        }
    }

    /// What the current theme asks the sidebar's ground to draw, or nil for the plain surface
    /// every theme drew before this existed.
    static func background(
        for appearance: NSAppearance = NSApplication.shared.effectiveAppearance
    ) -> Background? {
        let theme = AppThemePalette.current
        guard let stated = theme.variant(for: appearance)?.sidebar?.background,
              !stated.isEmpty else { return nil }

        var resolved = Background()

        if let gradient = stated.gradient, gradient.stops.count >= 2 {
            let ordered = gradient.stops.sorted { $0.position < $1.position }
            resolved.gradient = Background.Gradient(
                colors: ordered.map(\.color),
                locations: ordered.map { CGFloat($0.position) },
                angleDegrees: CGFloat(gradient.angleDegrees)
            )
        }

        if let layer = stated.image,
           let image = image(named: layer.asset, themeID: theme.id) {
            resolved.image = Background.ImageLayer(
                image: image,
                mode: layer.mode,
                opacity: CGFloat(max(0, min(1, layer.opacity)))
            )
        }

        return resolved.gradient == nil && resolved.image == nil ? nil : resolved
    }

    // MARK: - Brand

    struct Brand: Equatable {
        enum Logo: Equatable {
            /// The Threading mark, drawn live.
            case mark
            case image(NSImage)
            case hidden
        }

        let logo: Logo
        /// Nil when the theme hides the wordmark.
        let title: String?
        /// The recipe the wordmark label records, so the theme sweep re-resolves it.
        let titleRole: Design.FontRole
    }

    /// Always answers: absence at every level means the Threading mark beside the app's name.
    static func brand(
        for appearance: NSAppearance = NSApplication.shared.effectiveAppearance
    ) -> Brand {
        let theme = AppThemePalette.current
        let stated = theme.variant(for: appearance)?.sidebar?.brand

        let logo: Brand.Logo
        switch stated?.logo ?? .mark {
        case .mark:
            logo = .mark
        case .hidden:
            logo = .hidden
        case .asset(let name):
            // A dangling asset name is the default mark, not a hole where a logo should be.
            logo = image(named: name, themeID: theme.id).map(Brand.Logo.image) ?? .mark
        }

        let title = stated?.title
        let text: String?
        if title?.hidden == true {
            text = nil
        } else {
            let custom = title?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            text = (custom?.isEmpty == false ? custom : nil) ?? AppInfo.name
        }

        return Brand(
            logo: logo,
            title: text,
            titleRole: .wordmark(
                family: title?.fontFamily,
                size: title?.fontSize.map { CGFloat($0) },
                weight: (title?.weight ?? .semibold).fontWeight
            )
        )
    }

    // MARK: - Private Methods

    private static func image(named name: String, themeID: AppThemeID) -> NSImage? {
        ExtensionAppearanceRegistry.shared.sidebarAsset(named: name, forThemeID: themeID)
            ?? ThemeAssetStore.image(named: name, for: themeID)
    }
}
