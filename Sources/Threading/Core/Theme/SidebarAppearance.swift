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
public enum SidebarAppearance {

    // MARK: - Navigator Work Area

    public struct NavigatorWell: Equatable {
        public let fill: NSColor
        public let bevel: SurfaceBevel
        /// Content starts inside the authored edge so the document view cannot paint over it.
        public let edgeWidth: CGFloat
    }

    /// Nil preserves the original transparent navigator. A stated well is a region-level
    /// decision, not a new global surface role: a theme may want white Explorer work areas
    /// while keeping every ordinary panel silver.
    public static func navigatorWell() -> NavigatorWell? {
        navigatorWell(for: NSApplication.shared.effectiveAppearance)
    }

    public static func navigatorWell(for appearance: NSAppearance) -> NavigatorWell? {
        let theme = AppThemePalette.current
        guard let stated = theme.variant(for: appearance)?.sidebar?.navigatorWell else {
            return nil
        }
        let bevel: SurfaceBevel
        switch stated.bevel {
        case .raised: bevel = .automatic
        case .sunken: bevel = .sunken
        case .none: bevel = .none
        }
        let edgeWidth = stated.bevel == .none ? 0 : theme.material(for: appearance).bevel?.width ?? 0
        return NavigatorWell(fill: stated.fill, bevel: bevel, edgeWidth: edgeWidth)
    }

    // MARK: - Background

    public struct Background: Equatable {
        public var gradient: Gradient?
        public var image: ImageLayer?

        public struct Gradient: Equatable {
            public let colors: [NSColor]
            public let locations: [CGFloat]
            /// CSS convention, as authored: degrees clockwise from "toward the top".
            public let angleDegrees: CGFloat
        }

        public struct ImageLayer: Equatable {
            public let image: NSImage
            public let mode: SidebarStyle.ImageLayer.Mode
            public let opacity: CGFloat
        }
    }

    /// What the current theme asks the sidebar's ground to draw, or nil for the plain surface
    /// every theme drew before this existed.
    public static func background() -> Background? {
        background(for: NSApplication.shared.effectiveAppearance)
    }

    public static func background(for appearance: NSAppearance) -> Background? {
        let theme = AppThemePalette.current
        guard let stated = theme.variant(for: appearance)?.sidebar?.background else {
            return nil
        }
        return ThemeBackdropAppearance.resolve(stated, themeID: theme.id)
    }

    // MARK: - Brand

    public struct Brand: Equatable {
        public enum Logo: Equatable {
            /// The Threading mark, drawn live.
            case mark
            case image(NSImage)
            case hidden
        }

        public let logo: Logo
        /// Nil when the theme hides the wordmark.
        public let title: String?
        /// The recipe the wordmark label records, so the theme sweep re-resolves it.
        public let titleRole: Design.FontRole
    }

    /// Always answers: absence at every level means the Threading mark beside the app's name.
    public static func brand() -> Brand {
        brand(for: NSApplication.shared.effectiveAppearance)
    }

    public static func brand(for appearance: NSAppearance) -> Brand {
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
        ThemeBackdropAppearance.image(named: name, themeID: themeID)
    }
}

// MARK: - Theme Backdrop Appearance

/// Resolves a stated `ThemeBackdrop` into drawable values — decoded images, sorted gradient
/// stops — for whichever region asked. The sidebar's block and the material's backdrop go
/// through the same door, so the two never disagree about what a name resolves to or which
/// order stops are drawn in.
@MainActor
public enum ThemeBackdropAppearance {

    /// The same resolved shape the sidebar has always drawn from; one type, two regions.
    public typealias Resolved = SidebarAppearance.Background

    /// The material's backdrop under the current theme, or nil for the plain ground every
    /// theme drew before it existed. Asked by `applySurface` for every surface that opts into
    /// the backdrop treatment, in that surface's own effective appearance — an adaptive theme
    /// states a dressing per variant, and the Component Gallery previews both at once.
    public static func material(for appearance: NSAppearance) -> Resolved? {
        let theme = AppThemePalette.current
        guard let stated = theme.material(for: appearance).backdrop else { return nil }
        return resolve(stated, themeID: theme.id)
    }

    /// Stated style in, drawable values out. Nil when nothing resolves — an image whose name
    /// answers to no asset, a gradient with fewer than two stops — so a caller can hide the
    /// whole layer rather than draw an empty one.
    public static func resolve(_ stated: ThemeBackdrop, themeID: AppThemeID) -> Resolved? {
        guard !stated.isEmpty else { return nil }

        var resolved = Resolved()

        if let gradient = stated.gradient, gradient.stops.count >= 2 {
            let ordered = gradient.stops.sorted { $0.position < $1.position }
            resolved.gradient = Resolved.Gradient(
                colors: ordered.map(\.color),
                locations: ordered.map { CGFloat($0.position) },
                angleDegrees: CGFloat(gradient.angleDegrees)
            )
        }

        if let layer = stated.image,
           let image = image(named: layer.asset, themeID: themeID) {
            resolved.image = Resolved.ImageLayer(
                image: image,
                mode: layer.mode,
                opacity: CGFloat(max(0, min(1, layer.opacity)))
            )
        }

        return resolved.gradient == nil && resolved.image == nil ? nil : resolved
    }

    /// The tier that owns the theme answers for its bytes: a contributed theme's were read out
    /// of its package at inspection, a custom theme's live in `ThemeAssetStore`. The registry
    /// is consulted first only because contributed ids are namespaced; the two cannot collide.
    static func image(named name: String, themeID: AppThemeID) -> NSImage? {
        ExtensionAppearanceRegistry.shared.sidebarAsset(named: name, forThemeID: themeID)
            ?? ThemeAssetStore.image(named: name, for: themeID)
    }
}
