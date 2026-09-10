import AppKit

// MARK: - Sidebar Style

/// How a theme dresses the sidebar beyond its ground colour: an optional background treatment
/// under the list, and an optional restatement of the brand row above it.
///
/// This is deliberately the **one** place a theme reaches past colours-and-material into a
/// specific region of the window *by name*. The sidebar is the surface people asked to make
/// their own — a wordmark for their team, a gradient, a tiled pattern, a deliberately inset
/// navigator — and it is also the one pane whose content is entirely ours (rows of names), so
/// a background can sit *under* it without any feature view having to know. The app's other
/// broad grounds are dressed collectively rather than named: `AppTheme.Material.backdrop`
/// reaches every surface that opts into the material's backdrop treatment, in the same
/// `ThemeBackdrop` vocabulary this block's `background` uses. The terminal's ground stays the
/// terminal palette's; a theme that could paint behind it would be painting behind another
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
public struct SidebarStyle: Codable, Equatable {

    /// Painted between the themed surface and the list. Gradient below, image above.
    public var background: Background?

    /// The brand row at the sidebar's top: logo and wordmark.
    public var brand: Brand?

    /// The project tree's own work area. Absent keeps the historical transparent list over the
    /// sidebar background; stated themes can make it a contrasting raised, sunken, or flat
    /// field without feature code knowing which visual language it belongs to.
    public var navigatorWell: NavigatorWell?

    public init(
        background: Background? = nil,
        brand: Brand? = nil,
        navigatorWell: NavigatorWell? = nil
    ) {
        self.background = background
        self.brand = brand
        self.navigatorWell = navigatorWell
    }

    /// Nothing stated at all — indistinguishable from a document without the block, and what
    /// an update that removes both halves normalises to.
    public var isEmpty: Bool { background == nil && brand == nil && navigatorWell == nil }

    // MARK: - Navigator Work Area

    public struct NavigatorWell: Equatable {
        public var fill: NSColor
        public var bevel: Bevel

        public init(fill: NSColor, bevel: Bevel = .sunken) {
            self.fill = fill
            self.bevel = bevel
        }

        public enum Bevel: String, Codable, CaseIterable {
            case raised
            case sunken
            case none
        }
    }

    // MARK: - Background

    /// The sidebar's dressing is the shared backdrop vocabulary — gradient below, image above —
    /// so a theme states a sidebar and a pane wallpaper in one grammar, and the tools, the
    /// validation and the asset store treat both alike. The names below are the ones this
    /// block has always used; `ThemeBackdrop` is where the definitions live.
    public typealias Background = ThemeBackdrop
    public typealias Gradient = ThemeBackdrop.Gradient
    public typealias ImageLayer = ThemeBackdrop.ImageLayer

    // MARK: - Brand

    public struct Brand: Codable, Equatable {
        /// What sits in the logo slot. Absent means the Threading mark.
        public var logo: Logo
        /// The wordmark beside it. Absent means the app's own name in the default style.
        public var title: Title?

        public init(logo: Logo = .mark, title: Title? = nil) {
            self.logo = logo
            self.title = title
        }

        public var isEmpty: Bool { logo == .mark && title == nil }

        public enum Logo: Equatable {
            /// The Threading mark, drawn live in the theme's ink.
            case mark
            /// No logo; the wordmark stands alone.
            case hidden
            /// A theme-supplied image, resolved like every other sidebar asset.
            case asset(String)
        }

        public struct Title: Codable, Equatable {
            /// Absent means the app's own name (`AppInfo.name`).
            public var text: String?
            /// A family on this machine; a name that resolves to nothing degrades to the
            /// theme's typeface, exactly as `Material.fontFamily` does.
            public var fontFamily: String?
            /// Points, bounded by validation. Absent means the wordmark's own default.
            public var fontSize: Double?
            public var weight: Weight?
            /// A brand that is only a logo. The logo cannot also be hidden — validation
            /// refuses a brand with nothing left in it.
            public var hidden: Bool

            public init(
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

            public var isEmpty: Bool {
                text == nil && fontFamily == nil && fontSize == nil
                    && weight == nil && !hidden
            }

            public enum Weight: String, Codable, CaseIterable {
                case regular, medium, semibold, bold

                public var fontWeight: NSFont.Weight {
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

            public init(from decoder: Decoder) throws {
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

extension SidebarStyle.NavigatorWell: Codable {
    private enum CodingKeys: String, CodingKey {
        case fill, bevel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hex = try container.decode(String.self, forKey: .fill)
        guard let parsed = NSColor(hex: hex) else {
            throw DecodingError.dataCorruptedError(
                forKey: .fill,
                in: container,
                debugDescription: "\(hex) is not a colour."
            )
        }
        fill = parsed
        bevel = try container.decodeIfPresent(Bevel.self, forKey: .bevel) ?? .sunken
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fill.hexString, forKey: .fill)
        try container.encode(bevel, forKey: .bevel)
    }
}

extension SidebarStyle.Brand.Logo: Codable {
    private enum CodingKeys: String, CodingKey {
        case asset
    }

    /// `"mark"` and `"hidden"` are bare strings; an asset is `{"asset": name}` — so the two
    /// reserved words can never collide with a file a theme happens to ship.
    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
public enum SidebarStyleLimits {
    /// Two paints a wash; past eight the stops stop being a design and start being a bitmap.
    /// Shared with the material's backdrop — one grammar, one bound.
    public static let maximumGradientStops = ThemeBackdropLimits.maximumGradientStops
    /// The sidebar at its default width truncates well before this; the cap only refuses the
    /// pathological.
    public static let maximumTitleLength = 40
    /// Points. The band the wordmark sits in is fixed, so a size that cannot fit is refused
    /// rather than clipped.
    public static let titleSizeRange: ClosedRange<Double> = 10...22
    /// A sidebar asset is a pattern tile or a logo, not a photograph library. The cap matches
    /// what a 2× column-sized image genuinely needs, with room to spare.
    public static let maximumImageBytes = 4 * 1024 * 1024
}

// MARK: - Asset Slots

/// The sidebar's two slots are two of the three `ThemeAssetSlot` cases; the name this file has
/// always used stays for the call sites and tests written against it.
public typealias SidebarAssetSlot = ThemeAssetSlot
