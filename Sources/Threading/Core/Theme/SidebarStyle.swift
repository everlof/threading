import AppKit

// MARK: - Sidebar Style

/// How a theme dresses the sidebar beyond its ground colour: an optional background treatment
/// under the list, and an optional restatement of the brand row above it.
///
/// This is deliberately the **one** place a theme reaches past colours-and-material into a
/// specific region of the window. The sidebar is the surface people asked to make their own —
/// a wordmark for their team, a gradient, a tiled pattern — and it is also the one pane whose
/// content is entirely ours (rows of names), so a background can sit *under* it without any
/// feature view having to know. The content pane's ground stays the terminal's or the
/// conversation's; a theme that could paint behind those would be painting behind another
/// program's output.
///
/// Everything here is optional, and absent means what absent means everywhere in the theme
/// system: the default — a plain themed surface below, the Threading mark and the app's own
/// name above. A style that states nothing looks exactly as it did before this type existed.
///
/// Images are referenced by **asset name**, never carried inline: a theme document lives in
/// `PreferenceStore` as JSON, and bytes do not belong there. Custom themes keep their assets in
/// `ThemeAssetStore` (disk, one folder per theme); contributed themes resolve the same names
/// against their package through `ExtensionAppearanceRegistry`. A name that resolves to nothing
/// degrades to the default treatment — the rule a dangling font family already follows.
struct SidebarStyle: Codable, Equatable {

    /// Painted between the themed surface and the list. Gradient below, image above.
    var background: Background?

    /// The brand row at the sidebar's top: logo and wordmark.
    var brand: Brand?

    init(background: Background? = nil, brand: Brand? = nil) {
        self.background = background
        self.brand = brand
    }

    /// Nothing stated at all — indistinguishable from a document without the block, and what
    /// an update that removes both halves normalises to.
    var isEmpty: Bool { background == nil && brand == nil }

    // MARK: - Background

    struct Background: Codable, Equatable {
        /// Drawn first, over the theme's surface colour.
        var gradient: Gradient?
        /// Drawn over the gradient (or the surface): a tiled pattern or a fitted picture.
        var image: ImageLayer?

        init(gradient: Gradient? = nil, image: ImageLayer? = nil) {
            self.gradient = gradient
            self.image = image
        }

        var isEmpty: Bool { gradient == nil && image == nil }
    }

    struct Gradient: Equatable {
        /// At least two, positions in 0...1. Order is the author's; rendering sorts.
        var stops: [Stop]
        /// CSS convention: the direction the gradient flows toward, in degrees clockwise from
        /// straight up — 0 flows toward the top, 90 toward the trailing edge, 180 toward the
        /// bottom. Chosen because it is the convention every agent already knows.
        var angleDegrees: Double

        init(stops: [Stop], angleDegrees: Double = 180) {
            self.stops = stops
            self.angleDegrees = angleDegrees
        }

        struct Stop: Equatable {
            let color: NSColor
            /// 0 at the start of the run, 1 at its end.
            let position: Double

            init(color: NSColor, position: Double) {
                self.color = color
                self.position = position
            }
        }
    }

    struct ImageLayer: Codable, Equatable {
        /// Resolved through `ThemeAssetStore` for custom themes and the extension registry for
        /// contributed ones. See `SidebarAssetSlot` for the names custom themes use.
        var asset: String
        var mode: Mode
        /// 0...1 over whatever is beneath. Full strength suits a drawn pattern; a photograph
        /// under white text usually wants far less, and the tool description says so.
        var opacity: Double

        init(asset: String, mode: Mode = .fill, opacity: Double = 1) {
            self.asset = asset
            self.mode = mode
            self.opacity = opacity
        }

        enum Mode: String, Codable, CaseIterable {
            /// Repeated at its own pixel size from the top-leading corner.
            case tile
            /// Scaled to cover the column, cropping whatever overflows.
            case fill
            /// Scaled to fit inside the column, letterboxed by the layers beneath.
            case fit
        }
    }

    // MARK: - Brand

    struct Brand: Codable, Equatable {
        /// What sits in the logo slot. Absent means the Threading mark.
        var logo: Logo
        /// The wordmark beside it. Absent means the app's own name in the default style.
        var title: Title?

        init(logo: Logo = .mark, title: Title? = nil) {
            self.logo = logo
            self.title = title
        }

        var isEmpty: Bool { logo == .mark && title == nil }

        enum Logo: Equatable {
            /// The Threading mark, drawn live in the theme's ink.
            case mark
            /// No logo; the wordmark stands alone.
            case hidden
            /// A theme-supplied image, resolved like every other sidebar asset.
            case asset(String)
        }

        struct Title: Codable, Equatable {
            /// Absent means the app's own name (`AppInfo.name`).
            var text: String?
            /// A family on this machine; a name that resolves to nothing degrades to the
            /// theme's typeface, exactly as `Material.fontFamily` does.
            var fontFamily: String?
            /// Points, bounded by validation. Absent means the wordmark's own default.
            var fontSize: Double?
            var weight: Weight?
            /// A brand that is only a logo. The logo cannot also be hidden — validation
            /// refuses a brand with nothing left in it.
            var hidden: Bool

            init(
                text: String? = nil,
                fontFamily: String? = nil,
                fontSize: Double? = nil,
                weight: Weight? = nil,
                hidden: Bool = false
            ) {
                self.text = text
                self.fontFamily = fontFamily
                self.fontSize = fontSize
                self.weight = weight
                self.hidden = hidden
            }

            var isEmpty: Bool {
                text == nil && fontFamily == nil && fontSize == nil
                    && weight == nil && !hidden
            }

            enum Weight: String, Codable, CaseIterable {
                case regular, medium, semibold, bold

                var fontWeight: NSFont.Weight {
                    switch self {
                    case .regular: return .regular
                    case .medium: return .medium
                    case .semibold: return .semibold
                    case .bold: return .bold
                    }
                }
            }

            private enum CodingKeys: String, CodingKey {
                case text, fontFamily, fontSize, weight, hidden
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                text = try container.decodeIfPresent(String.self, forKey: .text)
                fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
                fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize)
                weight = try container.decodeIfPresent(Weight.self, forKey: .weight)
                hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
            }
        }
    }
}

// MARK: - Codable (hex colours, string-or-object logo)

extension SidebarStyle.Gradient: Codable {
    private enum CodingKeys: String, CodingKey {
        case stops, angleDegrees
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stops = try container.decode([Stop].self, forKey: .stops)
        angleDegrees = try container.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? 180
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stops, forKey: .stops)
        try container.encode(angleDegrees, forKey: .angleDegrees)
    }
}

extension SidebarStyle.Gradient.Stop: Codable {
    private enum CodingKeys: String, CodingKey {
        case color, position
    }

    /// Hex on the wire, like every colour in a theme document — hand-writable, diffable.
    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(color.hexString, forKey: .color)
        try container.encode(position, forKey: .position)
    }
}

extension SidebarStyle.Brand.Logo: Codable {
    private enum CodingKeys: String, CodingKey {
        case asset
    }

    /// `"mark"` and `"hidden"` are bare strings; an asset is `{"asset": name}` — so the two
    /// reserved words can never collide with a file a theme happens to ship.
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let word = try? single.decode(String.self) {
            switch word {
            case "mark": self = .mark
            case "hidden": self = .hidden
            default:
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "A logo is \"mark\", \"hidden\", or {\"asset\": name}."
                ))
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .asset(try container.decode(String.self, forKey: .asset))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .mark:
            var container = encoder.singleValueContainer()
            try container.encode("mark")
        case .hidden:
            var container = encoder.singleValueContainer()
            try container.encode("hidden")
        case .asset(let name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .asset)
        }
    }
}

// MARK: - Limits

/// The bounds `AppThemeEditing.validate` holds a sidebar block to, and the caps the asset
/// store enforces on the bytes behind it. Stated here beside the model so a limit and the
/// field it limits travel together.
enum SidebarStyleLimits {
    /// Two paints a wash; past eight the stops stop being a design and start being a bitmap.
    static let maximumGradientStops = 8
    /// The sidebar at its default width truncates well before this; the cap only refuses the
    /// pathological.
    static let maximumTitleLength = 40
    /// Points. The band the wordmark sits in is fixed, so a size that cannot fit is refused
    /// rather than clipped.
    static let titleSizeRange: ClosedRange<Double> = 10...22
    /// A sidebar asset is a pattern tile or a logo, not a photograph library. The cap matches
    /// what a 2× column-sized image genuinely needs, with room to spare.
    static let maximumImageBytes = 4 * 1024 * 1024
}

// MARK: - Asset Slots

/// The names a custom theme's sidebar assets are stored and referenced under.
///
/// Slots rather than free names: an MCP call hands over image *bytes*, not a file the document
/// could point back at, so the store needs a name to keep them under — and one logo plus one
/// background per variant is the whole vocabulary. Contributed themes are free to use their own
/// package-relative names; these constants only govern what `ThemeAssetStore` writes.
enum SidebarAssetSlot: String, CaseIterable {
    case logo
    case background

    /// One asset per slot per variant: a light chrome may want the mono logo its dark half
    /// inverts.
    func fileName(for kind: AppTheme.VariantKind) -> String {
        "\(kind.rawValue)-\(rawValue).png"
    }
}
