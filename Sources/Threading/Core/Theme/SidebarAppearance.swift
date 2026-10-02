import AppKit
import ThreadingRemoteKit

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
        public var particles: Particles?

        /// A stated particle block with its inks resolved against the variant that stated it.
        public struct Particles: Equatable {
            public let spec: ThemeParticles
            public let colors: [NSColor]
            /// The block's sprites, decoded from the variant's library. Empty draws the style's
            /// host shape — a block naming none, or naming only sprites whose pictures are gone.
            public var sprites: [Sprite] = []

            /// One decoded sprite. Equal when it is the same stored picture drawn the same way:
            /// a replaced file decodes to a new image, so a field restarts with the new art.
            public struct Sprite: Equatable {
                /// Stable for one stored file — the theme and the asset name.
                public let key: String
                public let image: CGImage
                public let tinted: Bool

                public init(key: String, image: CGImage, tinted: Bool) {
                    self.key = key
                    self.image = image
                    self.tinted = tinted
                }

                public static func == (lhs: Sprite, rhs: Sprite) -> Bool {
                    lhs.key == rhs.key && lhs.tinted == rhs.tinted && lhs.image === rhs.image
                }
            }
        }

        public struct Gradient: Equatable {
            public let colors: [NSColor]
            public let locations: [CGFloat]
            /// CSS convention, as authored: degrees clockwise from "toward the top".
            public let angleDegrees: CGFloat
            public var drift: ThemeGradientDrift? = nil
        }

        public struct ImageLayer: Equatable {
            public let image: NSImage
            public let mode: SidebarStyle.ImageLayer.Mode
            public let opacity: CGFloat
            public var alignment: ThemeImageAlignment = .center
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
        return ThemeBackdropAppearance.resolve(stated, themeID: theme.id, appearance: appearance)
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
        /// The wordmark's ink: the stated title colour, else the band's ink, else nil for the
        /// label every brand drew before either existed.
        public let titleColor: NSColor?
        /// The header's own ground, when the theme states one.
        public let band: Band?
        /// How the logo moves, with its particles' inks already resolved.
        public let motion: LogoMotion?
        public var analyzer: SidebarStyle.Brand.Analyzer? = nil

        public struct Band: Equatable {
            public let gradient: Background.Gradient
            /// What the header's controls and wordmark draw in over the band.
            public let ink: NSColor
        }

        public struct LogoMotion: Equatable {
            public let spec: SidebarStyle.Brand.LogoMotion
            public let particles: Background.Particles?
        }
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

        let band = stated?.band.flatMap { band in
            ThemeBackdropAppearance.gradient(band.gradient).map { gradient in
                Brand.Band(
                    gradient: gradient,
                    ink: band.ink ?? theme.resolved(.label, appearance: appearance)
                )
            }
        }

        let motion = stated?.motion.map { motion in
            Brand.LogoMotion(
                spec: motion,
                particles: motion.particles.map {
                    ThemeBackdropAppearance.particles($0, theme: theme, appearance: appearance)
                }
            )
        }

        return Brand(
            logo: logo,
            title: text,
            titleRole: .wordmark(
                family: title?.fontFamily,
                size: title?.fontSize.map { CGFloat($0) },
                weight: (title?.weight ?? .semibold).fontWeight
            ),
            titleColor: title?.color ?? band?.ink,
            band: band,
            motion: motion,
            analyzer: stated?.analyzer
        )
    }

    // MARK: - Mascot

    /// The mascot with its pictures decoded and its particle inks resolved for one appearance.
    public struct Mascot: Equatable {
        public let spec: ThemeMascot
        public let poses: [ThemeMascotMood: Pose]

        public struct Pose: Equatable {
            public let spec: ThemeMascot.Pose
            public let image: NSImage
            public let particles: Background.Particles?
        }

        /// The pose drawn for `mood`, following the model's borrowing rule over the poses whose
        /// pictures resolved. Nil only for a celebration the theme does not draw.
        public func pose(for mood: ThemeMascotMood) -> Pose? {
            if let own = poses[mood] { return own }
            switch mood {
            case .celebrating: return nil
            case .attention: return poses[.working] ?? poses[.idle]
            case .resting, .working, .idle: return poses[.idle]
            }
        }

        /// Width over height of the box the mascot stands in: the widest pose's proportions,
        /// so changing pose never changes the box and the list's breathing room stays put.
        public var aspectRatio: CGFloat {
            let ratios = poses.values.compactMap { pose -> CGFloat? in
                let size = pose.image.size
                return size.height > 0 ? size.width / size.height : nil
            }
            return min(max(ratios.max() ?? 1, 0.25), 4)
        }
    }

    /// The current theme's mascot for `appearance`, or nil when it states none or its idle
    /// picture is gone — a mascot with no pose to fall back on is no mascot.
    public static func mascot(for appearance: NSAppearance) -> Mascot? {
        let theme = AppThemePalette.current
        guard let stated = theme.variant(for: appearance)?.sidebar?.mascot else { return nil }
        var poses: [ThemeMascotMood: Mascot.Pose] = [:]
        for (mood, pose) in stated.poses {
            guard let image = image(named: pose.asset, themeID: theme.id) else { continue }
            poses[mood] = Mascot.Pose(
                spec: pose,
                image: image,
                particles: pose.particles.map {
                    ThemeBackdropAppearance.particles($0, theme: theme, appearance: appearance)
                }
            )
        }
        guard poses[.idle] != nil else { return nil }
        return Mascot(spec: stated, poses: poses)
    }

    // MARK: - The Band as a Ground

    /// The ink family for the header's controls while a band is stated — `InkSource.brandBand`'s
    /// answer. Cut from the band's one ink the way the title band's is, because the band is a
    /// ground the theme authors directly rather than through roles.
    public static var bandInk: Design.Ink {
        let base = brand(for: NSAppearance.currentDrawing()).band?.ink ?? Design.Text.label
        return Design.Ink(
            base: base,
            label: base,
            secondary: base.withAlphaComponent(0.7),
            tertiary: base.withAlphaComponent(0.45),
            quaternary: base.withAlphaComponent(0.25)
        )
    }

    /// The single colour that stands in for the band when a component must composite against
    /// it: the average of its stops, which is what the eye reads the band as.
    public static var bandGround: NSColor {
        guard let colors = brand(for: NSAppearance.currentDrawing()).band?.gradient.colors
            .compactMap({ $0.usingColorSpace(.sRGB) }),
              !colors.isEmpty else {
            return Design.Surface.ground
        }
        let count = CGFloat(colors.count)
        return NSColor(
            srgbRed: colors.map(\.redComponent).reduce(0, +) / count,
            green: colors.map(\.greenComponent).reduce(0, +) / count,
            blue: colors.map(\.blueComponent).reduce(0, +) / count,
            alpha: 1
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
        return resolve(stated, themeID: theme.id, appearance: appearance)
    }

    /// Stated style in, drawable values out. Nil when nothing resolves — an image whose name
    /// answers to no asset, a gradient with fewer than two stops — so a caller can hide the
    /// whole layer rather than draw an empty one.
    ///
    /// Particle inks resolve against the current palette in `appearance`: every region that
    /// draws a backdrop draws the theme in force, and an adaptive theme's two variants may
    /// name the same role and mean two different reds.
    public static func resolve(
        _ stated: ThemeBackdrop,
        themeID: AppThemeID,
        appearance: NSAppearance = NSAppearance.currentDrawing()
    ) -> Resolved? {
        guard !stated.isEmpty else { return nil }

        var resolved = Resolved()

        if let gradient = stated.gradient {
            resolved.gradient = self.gradient(gradient)
        }

        if let particles = stated.particles {
            resolved.particles = self.particles(
                particles,
                theme: AppThemePalette.current,
                appearance: appearance
            )
        }

        if let layer = stated.image,
           let image = image(named: layer.asset, themeID: themeID) {
            resolved.image = Resolved.ImageLayer(
                image: image,
                mode: layer.mode,
                opacity: CGFloat(max(0, min(1, layer.opacity))),
                alignment: layer.alignment
            )
        }

        return resolved.gradient == nil && resolved.image == nil && resolved.particles == nil
            ? nil
            : resolved
    }

    /// Sorted stops, the one order every region draws a gradient in — or nil for a gradient
    /// no region can draw: too few or too many stops, a position outside 0…1, an angle that is
    /// not a number.
    public static func gradient(_ stated: ThemeBackdrop.Gradient) -> Resolved.Gradient? {
        guard (2...ThemeBackdropLimits.maximumGradientStops).contains(stated.stops.count),
              stated.angleDegrees.isFinite,
              stated.stops.allSatisfy({ (0...1).contains($0.position) }) else {
            return nil
        }
        let ordered = stated.stops.sorted { $0.position < $1.position }
        return Resolved.Gradient(
            colors: ordered.map(\.color),
            locations: ordered.map { CGFloat($0.position) },
            angleDegrees: CGFloat(stated.angleDegrees),
            drift: stated.drift
        )
    }

    /// A particle block with its inks turned into colours for the variant in `appearance`, and
    /// its sprites decoded from that variant's library.
    public static func particles(
        _ stated: ThemeParticles,
        theme: AppTheme,
        appearance: NSAppearance
    ) -> Resolved.Particles {
        var colors: [NSColor] = []
        appearance.performAsCurrentDrawingAppearance {
            colors = stated.resolvedInks.map { $0.resolved(in: theme, appearance: appearance) }
        }
        return Resolved.Particles(
            spec: stated,
            colors: colors,
            sprites: sprites(stated.sprites, theme: theme, appearance: appearance)
        )
    }

    /// Names in, decoded pictures out, in the order stated. A name the library does not hold,
    /// or whose file is gone, is dropped rather than drawn as a hole — and a block left with
    /// none falls back to its style's shape.
    public static func sprites(
        _ names: [String],
        theme: AppTheme,
        appearance: NSAppearance
    ) -> [Resolved.Particles.Sprite] {
        guard !names.isEmpty, let library = theme.variant(for: appearance)?.sprites,
              !library.isEmpty else { return [] }
        return names.compactMap { name in
            guard let sprite = library.first(where: { $0.name == name }),
                  let image = image(named: sprite.asset, themeID: theme.id),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return nil }
            return Resolved.Particles.Sprite(
                key: "\(theme.id.rawValue)/\(sprite.asset)",
                image: cgImage,
                tinted: sprite.tinted
            )
        }
    }

    /// The tier that owns the theme answers for its bytes: a contributed theme's were read out
    /// of its package at inspection, a custom theme's live in `ThemeAssetStore`. The registry
    /// is consulted first only because contributed ids are namespaced; the two cannot collide.
    static func image(named name: String, themeID: AppThemeID) -> NSImage? {
        ExtensionAppearanceRegistry.shared.sidebarAsset(named: name, forThemeID: themeID)
            ?? ThemeAssetStore.image(named: name, for: themeID)
    }
}
