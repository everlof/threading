import AppKit
import ThreadingRemoteKit

// MARK: - Theme Backdrop

/// A dressing under a ground the app owns: a gradient, then an image over it.
///
/// One vocabulary with two homes. `SidebarStyle.background` states it for the project
/// sidebar — the first region a theme could reach into, and still the only one it addresses by
/// name. `AppTheme.Material.backdrop` states it for the app's *broad grounds* collectively:
/// every surface that opts into the material's backdrop treatment with
/// `applySurface(pattern: .backdrop)` — the display panel, the browser, the execution audit,
/// the drawer, the settings subpages, the About window — the same set `Material.backdropPattern`
/// already reaches. Cards and controls never inherit it, and the terminal is deliberately
/// neither: its ground belongs to the terminal palette, and painting behind another program's
/// output is not a theme.
///
/// Everything is optional, and absent means what absent means everywhere in the theme system:
/// the plain surface every theme drew before this existed.
///
/// Images are referenced by **asset name**, never carried inline: a theme document lives in
/// `PreferenceStore` as JSON, and bytes do not belong there. Custom themes keep their assets in
/// `ThemeAssetStore` (disk, one folder per theme, one fixed slot name per region and variant);
/// contributed themes resolve the same names against their package through
/// `ExtensionAppearanceRegistry`. A name that resolves to nothing degrades to the default
/// treatment — the rule a dangling font family already follows.
public struct ThemeBackdrop: Equatable {

    /// Drawn first, over the theme's own surface colour.
    public var gradient: Gradient?
    /// Drawn over the gradient (or the surface): a tiled pattern or a fitted picture.
    public var image: ImageLayer?
    /// A field of particles moving over both — bubbles rising through the column, snow falling
    /// past a pane. The host holds its strength under
    /// `ThemeParticleLimits.ambientOpacityCeiling` and stills it (a scatter, not a blank) under
    /// Reduce Motion, the Theme Motion setting, and while its window is unseen.
    public var particles: ThemeParticles?

    public init(
        gradient: Gradient? = nil,
        image: ImageLayer? = nil,
        particles: ThemeParticles? = nil
    ) {
        self.gradient = gradient
        self.image = image
        self.particles = particles
    }

    /// Nothing stated at all — indistinguishable from a document without the block, and what
    /// an update that removes every part normalises to.
    public var isEmpty: Bool { gradient == nil && image == nil && particles == nil }

    // MARK: - Gradient

    public struct Gradient: Equatable {
        /// At least two, positions in 0...1. Order is the author's; rendering sorts.
        public var stops: [Stop]
        /// CSS convention: the direction the gradient flows toward, in degrees clockwise from
        /// straight up — 0 flows toward the top, 90 toward the trailing edge, 180 toward the
        /// bottom. Chosen because it is the convention every agent already knows.
        public var angleDegrees: Double
        /// Optional decorative drift. Layout, scrolling and interaction timing remain host-owned.
        public var drift: ThemeGradientDrift?

        public init(stops: [Stop], angleDegrees: Double = 180, drift: ThemeGradientDrift? = nil) {
            self.stops = stops
            self.angleDegrees = angleDegrees
            self.drift = drift
        }

        public struct Stop: Equatable {
            public let color: NSColor
            /// 0 at the start of the run, 1 at its end.
            public let position: Double

            public init(color: NSColor, position: Double) {
                self.color = color
                self.position = position
            }
        }
    }

    // MARK: - Image

    public struct ImageLayer: Equatable {
        /// Resolved through `ThemeAssetStore` for custom themes and the extension registry for
        /// contributed ones. See `ThemeAssetSlot` for the names custom themes use.
        public var asset: String
        public var mode: Mode
        /// 0...1 over whatever is beneath. Full strength suits a drawn pattern; a photograph
        /// under text usually wants far less, and the tool description says so.
        public var opacity: Double
        /// Which edge or corner a `fill` keeps and a `fit` sits against. Centre is what every
        /// picture did before this existed; `bottom` is how an illustration stands on the
        /// column's foot however tall the window is. A tile always starts at the top-leading
        /// corner.
        public var alignment: ThemeImageAlignment

        public init(
            asset: String,
            mode: Mode = .fill,
            opacity: Double = 1,
            alignment: ThemeImageAlignment = .center
        ) {
            self.asset = asset
            self.mode = mode
            self.opacity = opacity
            self.alignment = alignment
        }

        public enum Mode: String, Codable, CaseIterable {
            /// Repeated at its own pixel size from the top-leading corner.
            case tile
            /// Scaled to cover the region, cropping whatever overflows.
            case fill
            /// Scaled to fit inside the region, letterboxed by the layers beneath.
            case fit
        }
    }
}

// MARK: - Codable (hex colours)

extension ThemeBackdrop: Codable {
    private enum CodingKeys: String, CodingKey {
        case gradient, image, particles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gradient = try container.decodeIfPresent(Gradient.self, forKey: .gradient)
        image = try container.decodeIfPresent(ImageLayer.self, forKey: .image)
        particles = try container.decodeIfPresent(ThemeParticles.self, forKey: .particles)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(gradient, forKey: .gradient)
        try container.encodeIfPresent(image, forKey: .image)
        try container.encodeIfPresent(particles, forKey: .particles)
    }
}

extension ThemeBackdrop.ImageLayer: Codable {
    private enum CodingKeys: String, CodingKey {
        case asset, mode, opacity, alignment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        asset = try container.decode(String.self, forKey: .asset)
        mode = try container.decode(Mode.self, forKey: .mode)
        opacity = try container.decode(Double.self, forKey: .opacity)
        alignment = try container.decodeIfPresent(ThemeImageAlignment.self, forKey: .alignment)
            ?? .center
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(asset, forKey: .asset)
        try container.encode(mode, forKey: .mode)
        try container.encode(opacity, forKey: .opacity)
        // Centre is the historical meaning of an absent key, so a document that never chose
        // one round-trips byte-identical.
        if alignment != .center { try container.encode(alignment, forKey: .alignment) }
    }
}

extension ThemeBackdrop.Gradient: Codable {
    private enum CodingKeys: String, CodingKey {
        case stops, angleDegrees, drift
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stops = try container.decode([Stop].self, forKey: .stops)
        angleDegrees = try container.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? 180
        drift = try container.decodeIfPresent(ThemeGradientDrift.self, forKey: .drift)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stops, forKey: .stops)
        try container.encode(angleDegrees, forKey: .angleDegrees)
        try container.encodeIfPresent(drift, forKey: .drift)
    }
}

extension ThemeBackdrop.Gradient.Stop: Codable {
    private enum CodingKeys: String, CodingKey {
        case color, position
    }

    /// Hex on the wire, like every colour in a theme document — hand-writable, diffable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hex = try container.decode(String.self, forKey: .color)
        guard let parsed = NSColor(hex: hex) else {
            throw DecodingError.dataCorruptedError(
                forKey: .color,
                in: container,
                debugDescription: "\(hex) is not a colour."
            )
        }
        color = parsed
        position = try container.decode(Double.self, forKey: .position)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(color.hexString, forKey: .color)
        try container.encode(position, forKey: .position)
    }
}

// MARK: - Image Alignment

/// Where a picture sits in the region it is drawn into: the edge or corner a `fill` keeps when it
/// crops, and the one a `fit` stands against when it letterboxes. Leading and trailing follow
/// the reading direction the way every other edge in the app does.
public enum ThemeImageAlignment: String, Codable, CaseIterable {
    case center
    case top
    case bottom
    case leading
    case trailing
    case topLeading = "top_leading"
    case topTrailing = "top_trailing"
    case bottomLeading = "bottom_leading"
    case bottomTrailing = "bottom_trailing"

    /// The unit position of the picture's slack: 0 puts the picture against the leading (or
    /// top) edge, 1 against the trailing (or bottom), 0.5 centres it. Top-down, so the caller
    /// flips it for a layer whose y axis points up.
    public var unitPosition: (x: CGFloat, y: CGFloat) {
        switch self {
        case .center: return (0.5, 0.5)
        case .top: return (0.5, 0)
        case .bottom: return (0.5, 1)
        case .leading: return (0, 0.5)
        case .trailing: return (1, 0.5)
        case .topLeading: return (0, 0)
        case .topTrailing: return (1, 0)
        case .bottomLeading: return (0, 1)
        case .bottomTrailing: return (1, 1)
        }
    }

    /// The frame a picture of `imageSize` takes in `bounds` for `mode` — larger than the bounds
    /// for a `fill`, which its host clips — or nil for a tile, which is drawn as a pattern.
    /// `flipped` is true when `bounds` has its origin at the top (an AppKit flipped view or a
    /// layer beneath one); unit positions are top-down.
    public func frame(
        for imageSize: CGSize,
        in bounds: CGRect,
        mode: ThemeBackdrop.ImageLayer.Mode,
        flipped: Bool,
        layoutDirection: NSUserInterfaceLayoutDirection = .leftToRight
    ) -> CGRect? {
        guard mode != .tile,
              imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let widthRatio = bounds.width / imageSize.width
        let heightRatio = bounds.height / imageSize.height
        let scale = mode == .fill ? max(widthRatio, heightRatio) : min(widthRatio, heightRatio)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        var unit = unitPosition
        if layoutDirection == .rightToLeft { unit.x = 1 - unit.x }
        if !flipped { unit.y = 1 - unit.y }
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) * unit.x,
            y: bounds.minY + (bounds.height - size.height) * unit.y,
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - Limits

/// The bounds a backdrop is held to, stated beside the model so a limit and the field it limits
/// travel together. The sidebar's block shares the gradient bound and keeps its own image cap in
/// `SidebarStyleLimits`, because a column and a pane are different sizes of picture.
public enum ThemeBackdropLimits {
    /// Two paints a wash; past eight the stops stop being a design and start being a bitmap.
    public static let maximumGradientStops = 8
    /// A pane wallpaper is stored at 2× of a wide pane, and the byte cap is what such a PNG
    /// genuinely needs with room to spare — twice the sidebar's, because the region is.
    public static let maximumImageBytes = 8 * 1024 * 1024
}

// MARK: - Asset Slots

/// The names a custom theme's image assets are stored and referenced under.
///
/// Slots rather than free names: an MCP call hands over image *bytes*, not a file the document
/// could point back at, so the store needs a name to keep them under — and one image per region
/// per variant is the whole vocabulary. Contributed themes are free to use their own
/// package-relative names; these constants only govern what `ThemeAssetStore` writes.
public enum ThemeAssetSlot: String, CaseIterable {
    /// The sidebar brand row's logo.
    case logo
    /// The sidebar's background picture (`SidebarStyle.background.image`).
    case background
    /// The material's backdrop picture (`AppTheme.Material.backdrop.image`), under every
    /// broad ground.
    case backdrop
    /// The new-session composer's welcome picture (`ThemeWelcome.backdrop.image`). A pane-sized
    /// picture like the material's, so it shares that slot's budget, but a slot of its own: a
    /// theme may dress the welcome with art it would never put under the display panel.
    case welcome

    /// One asset per slot per variant: a light chrome may want the mono logo its dark half
    /// inverts, and a pale wallpaper its dark half does not.
    public func fileName(for kind: AppTheme.VariantKind) -> String {
        "\(kind.rawValue)-\(rawValue).png"
    }

    /// The byte ceiling the store and the package inspector hold this slot's image to.
    public var maximumImageBytes: Int {
        switch self {
        case .logo, .background: return SidebarStyleLimits.maximumImageBytes
        case .backdrop, .welcome: return ThemeBackdropLimits.maximumImageBytes
        }
    }
}
