import AppKit

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
public struct ThemeBackdrop: Codable, Equatable {

    /// Drawn first, over the theme's own surface colour.
    public var gradient: Gradient?
    /// Drawn over the gradient (or the surface): a tiled pattern or a fitted picture.
    public var image: ImageLayer?

    public init(gradient: Gradient? = nil, image: ImageLayer? = nil) {
        self.gradient = gradient
        self.image = image
    }

    /// Nothing stated at all — indistinguishable from a document without the block, and what
    /// an update that removes both halves normalises to.
    public var isEmpty: Bool { gradient == nil && image == nil }

    // MARK: - Gradient

    public struct Gradient: Equatable {
        /// At least two, positions in 0...1. Order is the author's; rendering sorts.
        public var stops: [Stop]
        /// CSS convention: the direction the gradient flows toward, in degrees clockwise from
        /// straight up — 0 flows toward the top, 90 toward the trailing edge, 180 toward the
        /// bottom. Chosen because it is the convention every agent already knows.
        public var angleDegrees: Double

        public init(stops: [Stop], angleDegrees: Double = 180) {
            self.stops = stops
            self.angleDegrees = angleDegrees
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

    public struct ImageLayer: Codable, Equatable {
        /// Resolved through `ThemeAssetStore` for custom themes and the extension registry for
        /// contributed ones. See `ThemeAssetSlot` for the names custom themes use.
        public var asset: String
        public var mode: Mode
        /// 0...1 over whatever is beneath. Full strength suits a drawn pattern; a photograph
        /// under text usually wants far less, and the tool description says so.
        public var opacity: Double

        public init(asset: String, mode: Mode = .fill, opacity: Double = 1) {
            self.asset = asset
            self.mode = mode
            self.opacity = opacity
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

extension ThemeBackdrop.Gradient: Codable {
    private enum CodingKeys: String, CodingKey {
        case stops, angleDegrees
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stops = try container.decode([Stop].self, forKey: .stops)
        angleDegrees = try container.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? 180
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stops, forKey: .stops)
        try container.encode(angleDegrees, forKey: .angleDegrees)
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

    /// One asset per slot per variant: a light chrome may want the mono logo its dark half
    /// inverts, and a pale wallpaper its dark half does not.
    public func fileName(for kind: AppTheme.VariantKind) -> String {
        "\(kind.rawValue)-\(rawValue).png"
    }

    /// The byte ceiling the store and the package inspector hold this slot's image to.
    public var maximumImageBytes: Int {
        switch self {
        case .logo, .background: return SidebarStyleLimits.maximumImageBytes
        case .backdrop: return ThemeBackdropLimits.maximumImageBytes
        }
    }
}
