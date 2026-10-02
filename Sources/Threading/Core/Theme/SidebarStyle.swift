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

    /// A character standing at the column's foot, beneath the list, whose pose follows what the
    /// app is doing. Absent means no one is there.
    public var mascot: ThemeMascot?

    public init(
        background: Background? = nil,
        brand: Brand? = nil,
        navigatorWell: NavigatorWell? = nil,
        mascot: ThemeMascot? = nil
    ) {
        self.background = background
        self.brand = brand
        self.navigatorWell = navigatorWell
        self.mascot = mascot
    }

    /// Nothing stated at all — indistinguishable from a document without the block, and what
    /// an update that removes both halves normalises to.
    public var isEmpty: Bool {
        background == nil && brand == nil && navigatorWell == nil && mascot == nil
    }

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

    public struct Brand: Equatable {
        /// What sits in the logo slot. Absent means the Threading mark.
        public var logo: Logo
        /// The wordmark beside it. Absent means the app's own name in the default style.
        public var title: Title?
        /// A band of the theme's own colour behind the whole header row — brand and the list's
        /// controls — running up under the toolbar to the window's top edge. Absent means the
        /// header sits on the sidebar's ground like everything else.
        public var band: Band?
        /// How the theme's logo image answers the pointer, a launch and working agents, and
        /// what it gives off while it does. Absent means the logo holds still.
        public var motion: LogoMotion?
        /// The theme's logo image also stands in for the Threading mark on the Dock tile,
        /// drawn on the theme's own plate — the opt-in a contributed theme's icon mark already
        /// had. Needs an image logo.
        public var dockIcon: Bool
        /// Explicitly replaces the brand with a host-owned analyzer under any material.
        /// Audio is the user-enabled live spectrum; absent preserves the material's default.
        public var analyzer: Analyzer?

        public enum Analyzer: String, Codable, CaseIterable { case workload, audio }

        public init(
            logo: Logo = .mark,
            title: Title? = nil,
            band: Band? = nil,
            motion: LogoMotion? = nil,
            dockIcon: Bool = false,
            analyzer: Analyzer? = nil
        ) {
            self.logo = logo
            self.title = title
            self.band = band
            self.motion = motion
            self.dockIcon = dockIcon
            self.analyzer = analyzer
        }

        public var isEmpty: Bool {
            logo == .mark && title == nil && band == nil && motion == nil && !dockIcon && analyzer == nil
        }

        public enum Logo: Equatable {
            /// The Threading mark, drawn live in the theme's ink.
            case mark
            /// No logo; the wordmark stands alone.
            case hidden
            /// A theme-supplied image, resolved like every other sidebar asset.
            case asset(String)
        }

        public struct Title: Equatable {
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
            /// The wordmark's own ink. Absent means the band's ink when a band is stated and
            /// the variant's label otherwise. Held to the label's 3:1 floor against whatever
            /// it sits on — the band's stops, or the sidebar's ground and wash.
            public var color: NSColor?

            public init(
                text: String? = nil,
                fontFamily: String? = nil,
                fontSize: Double? = nil,
                weight: Weight? = nil,
                hidden: Bool = false,
                color: NSColor? = nil
            ) {
                self.text = text
                self.fontFamily = fontFamily
                self.fontSize = fontSize
                self.weight = weight
                self.hidden = hidden
                self.color = color
            }

            public var isEmpty: Bool {
                text == nil && fontFamily == nil && fontSize == nil
                    && weight == nil && !hidden && color == nil
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
        }

        // MARK: - Band

        /// The header's own ground. Its gradient runs from the window's top edge to the
        /// header's rule; `ink` is what the brand and the list's controls draw in over it.
        public struct Band: Equatable {
            public var gradient: Gradient
            /// Absent means the variant's label. Held to the label's 3:1 floor against every
            /// stop, because the band carries the `+` that adds a project.
            public var ink: NSColor?

            public init(gradient: Gradient, ink: NSColor? = nil) {
                self.gradient = gradient
                self.ink = ink
            }
        }

        // MARK: - Motion

        /// The logo as something that moves: three gestures, one ambient behaviour, and the
        /// particles all four give off. It moves the theme's own logo image — validation
        /// refuses it beside the Threading mark, which is drawn live and has gestures of its
        /// own.
        public struct LogoMotion: Equatable {
            /// While the pointer is over the brand row.
            public var hover: Beat?
            /// On a press anywhere on the brand row.
            public var press: Beat?
            /// Once per run, when the sidebar first appears.
            public var launch: Beat?
            /// Given off as a stream while hovered, as a burst on press and launch, and — when
            /// `working` is true — as a stream whose rate follows the agents at work.
            public var particles: ThemeParticles?
            /// Where particles leave the logo, in the logo slot's unit square: x from the
            /// leading edge, y from the top. Absent means the top centre — a bottle's neck.
            public var origin: Origin?
            /// Streams particles while any agent is working, faster the busier they are.
            public var working: Bool

            public init(
                hover: Beat? = nil,
                press: Beat? = nil,
                launch: Beat? = nil,
                particles: ThemeParticles? = nil,
                origin: Origin? = nil,
                working: Bool = false
            ) {
                self.hover = hover
                self.press = press
                self.launch = launch
                self.particles = particles
                self.origin = origin
                self.working = working
            }

            public var isEmpty: Bool {
                hover == nil && press == nil && launch == nil && particles == nil
                    && origin == nil && !working
            }

            public var resolvedOrigin: Origin { origin ?? Origin(x: 0.5, y: 0) }

            /// A gesture the host knows how to play on a logo. Every beat returns the logo
            /// exactly where it started, so an interrupted one never leaves it askew.
            public enum Beat: String, Codable, CaseIterable {
                /// Rises and grows a little, held while hovered.
                case lift
                /// Leans a few degrees and rights itself.
                case tilt
                /// Rocks side to side and settles.
                case wobble
                /// Drops, springs back, and settles.
                case bounce
                /// One full turn.
                case spin
                /// A quick side-to-side shudder.
                case shake
                /// Squashes, then pops out past its size and back.
                case pop
            }

            public struct Origin: Codable, Equatable {
                public var x: Double
                public var y: Double

                public init(x: Double, y: Double) {
                    self.x = x
                    self.y = y
                }
            }
        }
    }
}

// MARK: - Codable (brand, title, band, motion)

extension SidebarStyle.Brand: Codable {
    private enum CodingKeys: String, CodingKey {
        case logo, title, band, motion, dockIcon, analyzer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logo = try container.decodeIfPresent(Logo.self, forKey: .logo) ?? .mark
        title = try container.decodeIfPresent(Title.self, forKey: .title)
        band = try container.decodeIfPresent(Band.self, forKey: .band)
        motion = try container.decodeIfPresent(LogoMotion.self, forKey: .motion)
        dockIcon = try container.decodeIfPresent(Bool.self, forKey: .dockIcon) ?? false
        analyzer = try container.decodeIfPresent(Analyzer.self, forKey: .analyzer)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(logo, forKey: .logo)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(band, forKey: .band)
        try container.encodeIfPresent(motion, forKey: .motion)
        if dockIcon { try container.encode(dockIcon, forKey: .dockIcon) }
        try container.encodeIfPresent(analyzer, forKey: .analyzer)
    }
}

extension SidebarStyle.Brand.Title: Codable {
    private enum CodingKeys: String, CodingKey {
        case text, fontFamily, fontSize, weight, hidden, color
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize)
        weight = try container.decodeIfPresent(Weight.self, forKey: .weight)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        color = try container.decodeIfPresent(String.self, forKey: .color).flatMap(NSColor.init(hex:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(fontFamily, forKey: .fontFamily)
        try container.encodeIfPresent(fontSize, forKey: .fontSize)
        try container.encodeIfPresent(weight, forKey: .weight)
        try container.encode(hidden, forKey: .hidden)
        try container.encodeIfPresent(color?.hexString, forKey: .color)
    }
}

extension SidebarStyle.Brand.Band: Codable {
    private enum CodingKeys: String, CodingKey {
        case gradient, ink
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gradient = try container.decode(SidebarStyle.Gradient.self, forKey: .gradient)
        ink = try container.decodeIfPresent(String.self, forKey: .ink).flatMap(NSColor.init(hex:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gradient, forKey: .gradient)
        try container.encodeIfPresent(ink?.hexString, forKey: .ink)
    }
}

extension SidebarStyle.Brand.LogoMotion: Codable {
    private enum CodingKeys: String, CodingKey {
        case hover, press, launch, particles, origin, working
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hover = try container.decodeIfPresent(Beat.self, forKey: .hover)
        press = try container.decodeIfPresent(Beat.self, forKey: .press)
        launch = try container.decodeIfPresent(Beat.self, forKey: .launch)
        particles = try container.decodeIfPresent(ThemeParticles.self, forKey: .particles)
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin)
        working = try container.decodeIfPresent(Bool.self, forKey: .working) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(hover, forKey: .hover)
        try container.encodeIfPresent(press, forKey: .press)
        try container.encodeIfPresent(launch, forKey: .launch)
        try container.encodeIfPresent(particles, forKey: .particles)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encode(working, forKey: .working)
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
