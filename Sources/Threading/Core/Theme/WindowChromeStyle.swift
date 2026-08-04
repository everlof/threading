import AppKit

// MARK: - Window Chrome Style

/// How a theme takes over the window's own frame: the title band, the window's buttons, and
/// the border around everything.
///
/// This is the second — and last — place a theme reaches past colours-and-material into a
/// specific region of the window (the first is `SidebarStyle`, whose rules apply here
/// unchanged: hex colours on the wire, absent fields meaning the default). It is also the
/// heavier of the two: **presence of this block is what opts a theme into drawing the entire
/// window frame itself.** While such a theme is active, the main window gives up its titled
/// AppKit frame — traffic lights, rounded corners, toolbar — and wears an app-drawn title band
/// and border instead; `WindowChromeCoordinator` performs the exchange in both directions. A
/// theme that states no chrome gets the native frame it always had, which is every theme that
/// existed before this type did.
///
/// What the block deliberately does *not* carry is behaviour. Dragging, double-click, resize
/// edges, minimise and zoom are the app's (and where possible still AppKit's, behind the
/// borderless mask); a theme states how the frame *looks*, never what it does.
struct WindowChromeStyle: Codable, Equatable {

    /// The band across the window's top: gradient, title, and the window's own buttons.
    var titleBar: TitleBar

    /// The border drawn around the window's edges. Absent means a one-point border in the
    /// theme's border role — enough to seat a square window on whatever is behind it.
    var frame: Frame?

    init(titleBar: TitleBar, frame: Frame? = nil) {
        self.titleBar = titleBar
        self.frame = frame
    }

    // MARK: - Title Bar

    struct TitleBar: Equatable {

        /// The band's fill while the window is key. Required — a takeover with no band fill
        /// has no identity, and everything else in the block can derive from this.
        var activeGradient: SidebarStyle.Gradient

        /// The band's fill while another window is key. Absent derives each active stop
        /// toward gray (`WindowChromeAppearance`), which is what an inactive title bar has
        /// meant for as long as title bars could be inactive.
        var inactiveGradient: SidebarStyle.Gradient?

        /// The title text and button glyphs. Absent means white. Validated to at least the
        /// label's contrast against every active stop, the way sidebar text is validated
        /// against its gradient.
        var ink: NSColor?

        /// Ink while the window is inactive. Absent dims `ink`. Held to the softer 2:1
        /// "tellable" floor rather than full label contrast — inactive title text reads as
        /// inactive precisely by carrying less ink.
        var inactiveInk: NSColor?

        var titleAlignment: Alignment

        /// The title's slant. Weight and size remain semantic design-system choices; this
        /// one authored distinction is enough for workstation chrome such as IRIX, whose
        /// bold italic caption is part of the frame rather than the application's typography.
        var titleFontStyle: TitleFontStyle

        /// Points, bounded by `WindowChromeStyleLimits.bandHeightRange`. Absent means
        /// `WindowChromeStyleLimits.defaultBandHeight`.
        var height: Double?

        /// How the close/minimize/zoom glyphs draw. One vocabulary interpreted by one
        /// component — a theme picks a style, it never draws its own buttons.
        var buttonGlyphStyle: ButtonGlyphStyle

        /// Where the three semantic window operations sit. The Windows lineage keeps one
        /// cluster at the trailing edge; classic Macintosh chrome places Close at the leading
        /// edge and its collapse/zoom pair at the trailing edge. This is layout *inside the
        /// title bar*, not application layout, and therefore belongs to the regional block.
        var buttonPlacement: ButtonPlacement

        /// Whether the application icon occupies the band's leading identity slot. Absent on
        /// the wire means true, preserving the first takeover implementation exactly.
        var showsAppIcon: Bool

        /// Optional raster-like treatments over the active and inactive fills. A texture is
        /// data interpreted by the shared band, never a theme-specific drawing branch.
        var activeTexture: Texture?
        var inactiveTexture: Texture?

        /// The outline occupied by the title band. Most systems span the window; BeOS seats a
        /// compact tab on the leading edge and leaves the rest of the window top transparent.
        var shape: Shape

        /// Width of a leading tab in points. Meaningful only for `leadingTab`; absent uses the
        /// period-sized default. Kept separate from `shape` so an authored theme can tune the
        /// tab without replacing the outline vocabulary.
        var tabWidth: Double?

        /// Which semantic window operations are present. Behaviour is still owned by the app;
        /// this list only lets a system omit furniture it never had (BeOS has no Minimize box).
        var visibleButtons: [ButtonRole]

        init(
            activeGradient: SidebarStyle.Gradient,
            inactiveGradient: SidebarStyle.Gradient? = nil,
            ink: NSColor? = nil,
            inactiveInk: NSColor? = nil,
            titleAlignment: Alignment = .leading,
            titleFontStyle: TitleFontStyle = .upright,
            height: Double? = nil,
            buttonGlyphStyle: ButtonGlyphStyle = .plain,
            buttonPlacement: ButtonPlacement = .trailing,
            showsAppIcon: Bool = true,
            activeTexture: Texture? = nil,
            inactiveTexture: Texture? = nil,
            shape: Shape = .fullWidth,
            tabWidth: Double? = nil,
            visibleButtons: [ButtonRole] = ButtonRole.standardOperations
        ) {
            self.activeGradient = activeGradient
            self.inactiveGradient = inactiveGradient
            self.ink = ink
            self.inactiveInk = inactiveInk
            self.titleAlignment = titleAlignment
            self.titleFontStyle = titleFontStyle
            self.height = height
            self.buttonGlyphStyle = buttonGlyphStyle
            self.buttonPlacement = buttonPlacement
            self.showsAppIcon = showsAppIcon
            self.activeTexture = activeTexture
            self.inactiveTexture = inactiveTexture
            self.shape = shape
            self.tabWidth = tabWidth
            self.visibleButtons = visibleButtons
        }

        enum Alignment: String, Codable, CaseIterable {
            case leading, center
        }

        enum TitleFontStyle: String, Codable, CaseIterable {
            case upright, italic
        }

        enum ButtonGlyphStyle: String, Codable, CaseIterable {
            /// Bare glyphs in the band's ink.
            case plain
            /// Square plates holding the glyphs — the Windows lineage. The plates take the
            /// theme's control surface and, under a bevel material, its bevel.
            case squares
            /// Platinum's small inset boxes: Close at the leading edge, WindowShade and Zoom
            /// at the trailing edge, all drawn as hard one-pixel figures.
            case platinum
            /// BeOS's small raised boxes, drawn in the title tab itself.
            case beOS = "beos"
            /// OPENSTEP's gray title plates: a nested-square miniaturize mark and the
            /// diagonal close figure from the NeXT window frame.
            case openStep = "openstep"
            /// IRIX 4Dwm's black-outlined gray caption boxes: Window menu at the leading
            /// edge, then Minimize and Maximize at the trailing edge.
            case irix
        }

        enum ButtonPlacement: String, Codable, CaseIterable {
            case trailing
            case split
            /// Places the first authored visible operation at the leading edge and the rest
            /// at the trailing edge. Unlike `split`, this preserves a system's own ordering:
            /// OPENSTEP starts with Miniaturize and ends with Close.
            case bookends
        }

        enum Shape: String, Codable, CaseIterable {
            case fullWidth = "full_width"
            case leadingTab = "leading_tab"
        }

        enum ButtonRole: String, Codable, CaseIterable {
            /// Opens the window manager's operations menu. It is furniture rather than an
            /// application command, so it belongs beside the other semantic frame roles.
            case windowMenu = "window_menu"
            case minimize
            case zoom
            case close

            /// The operations the original takeover implementation exposed. Kept explicit
            /// so adding a new semantic role does not silently add furniture to old themes.
            static let standardOperations: [Self] = [.minimize, .zoom, .close]
        }

        struct Texture: Equatable {
            var kind: Kind
            var color: NSColor?
            /// Points between repeated one-point lines. Absent means the kind's historical
            /// default; validation bounds it so a line cannot disappear or become a panel.
            var spacing: Double?

            init(kind: Kind, color: NSColor? = nil, spacing: Double? = nil) {
                self.kind = kind
                self.color = color
                self.spacing = spacing
            }

            enum Kind: String, Codable, CaseIterable {
                /// Horizontal one-pixel rules interrupted by the centred title — Platinum's
                /// active-window signature.
                case pinstripes
                /// A one-bit checker over the title fill. At two-point spacing this is the
                /// dense stipple used by workstation window managers such as IRIX 4Dwm.
                case dither
            }
        }
    }

    // MARK: - Frame

    struct Frame: Codable, Equatable {
        /// Points, bounded by `WindowChromeStyleLimits.frameWidthRange`. Drawn in the theme's
        /// border role by `WindowChromeFrameView`.
        var width: Double

        init(width: Double) {
            self.width = width
        }

        private enum CodingKeys: String, CodingKey {
            case width
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            width = try container.decodeIfPresent(Double.self, forKey: .width)
                ?? WindowChromeStyleLimits.defaultFrameWidth
        }
    }
}

// MARK: - Codable (hex ink on the wire)

extension WindowChromeStyle.TitleBar: Codable {

    private enum CodingKeys: String, CodingKey {
        case activeGradient, inactiveGradient, ink, inactiveInk
        case titleAlignment, titleFontStyle, height, buttonGlyphStyle, buttonPlacement, showsAppIcon
        case activeTexture, inactiveTexture, shape, tabWidth, visibleButtons
    }

    /// Every field but the active gradient is optional on the wire, the `Material` rule: a
    /// document written before a field existed decodes to the value the app used then.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeGradient = try container.decode(SidebarStyle.Gradient.self, forKey: .activeGradient)
        inactiveGradient = try container.decodeIfPresent(
            SidebarStyle.Gradient.self,
            forKey: .inactiveGradient
        )
        ink = try Self.decodeColor(container, key: .ink)
        inactiveInk = try Self.decodeColor(container, key: .inactiveInk)
        titleAlignment = try container.decodeIfPresent(Alignment.self, forKey: .titleAlignment)
            ?? .leading
        titleFontStyle = try container.decodeIfPresent(
            TitleFontStyle.self,
            forKey: .titleFontStyle
        ) ?? .upright
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        buttonGlyphStyle = try container.decodeIfPresent(
            ButtonGlyphStyle.self,
            forKey: .buttonGlyphStyle
        ) ?? .plain
        buttonPlacement = try container.decodeIfPresent(
            ButtonPlacement.self,
            forKey: .buttonPlacement
        ) ?? .trailing
        showsAppIcon = try container.decodeIfPresent(Bool.self, forKey: .showsAppIcon) ?? true
        activeTexture = try container.decodeIfPresent(Texture.self, forKey: .activeTexture)
        inactiveTexture = try container.decodeIfPresent(Texture.self, forKey: .inactiveTexture)
        shape = try container.decodeIfPresent(Shape.self, forKey: .shape) ?? .fullWidth
        tabWidth = try container.decodeIfPresent(Double.self, forKey: .tabWidth)
        visibleButtons = try container.decodeIfPresent(
            [ButtonRole].self,
            forKey: .visibleButtons
        ) ?? ButtonRole.standardOperations
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activeGradient, forKey: .activeGradient)
        try container.encodeIfPresent(inactiveGradient, forKey: .inactiveGradient)
        try container.encodeIfPresent(ink?.hexString, forKey: .ink)
        try container.encodeIfPresent(inactiveInk?.hexString, forKey: .inactiveInk)
        try container.encode(titleAlignment, forKey: .titleAlignment)
        try container.encode(titleFontStyle, forKey: .titleFontStyle)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encode(buttonGlyphStyle, forKey: .buttonGlyphStyle)
        try container.encode(buttonPlacement, forKey: .buttonPlacement)
        try container.encode(showsAppIcon, forKey: .showsAppIcon)
        try container.encodeIfPresent(activeTexture, forKey: .activeTexture)
        try container.encodeIfPresent(inactiveTexture, forKey: .inactiveTexture)
        try container.encode(shape, forKey: .shape)
        try container.encodeIfPresent(tabWidth, forKey: .tabWidth)
        try container.encode(visibleButtons, forKey: .visibleButtons)
    }

    private static func decodeColor(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> NSColor? {
        guard let hex = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        guard let parsed = NSColor(hex: hex) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(hex) is not a colour."
            )
        }
        return parsed
    }
}

extension WindowChromeStyle.TitleBar.Texture: Codable {

    private enum CodingKeys: String, CodingKey {
        case kind, color, spacing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        spacing = try container.decodeIfPresent(Double.self, forKey: .spacing)
        if let hex = try container.decodeIfPresent(String.self, forKey: .color) {
            guard let parsed = NSColor(hex: hex) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .color,
                    in: container,
                    debugDescription: "\(hex) is not a colour."
                )
            }
            color = parsed
        } else {
            color = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(color?.hexString, forKey: .color)
        try container.encodeIfPresent(spacing, forKey: .spacing)
    }
}

// MARK: - Limits

/// The bounds `AppThemeEditing.validate` holds a chrome block to, stated beside the model so
/// a limit and the field it limits travel together — the `SidebarStyleLimits` rule.
enum WindowChromeStyleLimits {
    /// Points. Below 18 the band cannot hold its compact caption buttons; past 44 it
    /// stops being a title bar and starts being a pane.
    static let bandHeightRange: ClosedRange<Double> = 18...44
    /// What a band measures when the theme does not say — the native pane-tab height's
    /// neighbourhood, so the window's top does not jump between modes more than it must.
    static let defaultBandHeight: Double = 28
    /// Points. One is a seam; past six the frame reads as a wall, and resize edges live
    /// under it.
    static let frameWidthRange: ClosedRange<Double> = 1...6
    /// What an absent frame block draws: the thinnest visible seat.
    static let defaultFrameWidth: Double = 1
    /// The band's gradient carries the same stop budget as the sidebar's.
    static let maximumGradientStops = SidebarStyleLimits.maximumGradientStops
    /// The softer contrast floor inactive ink is held to — the status-hue "tellable from the
    /// ground" rule rather than the label's, because inactive text signals inactivity by
    /// carrying less ink (Windows itself set `#D4D0C8` on `#808080`, which is 2.6:1).
    static let inactiveInkMinimumRatio: CGFloat = 2
    /// Points between title-band texture strokes. One collapses into a solid fill; past eight
    /// the treatment stops reading as a texture tied to the chrome.
    static let textureSpacingRange: ClosedRange<Double> = 2...8
    static let defaultTextureSpacing: Double = 2
    /// Points. Narrower cannot hold two caption boxes and a useful title; wider stops reading
    /// as a tab. The default follows the compact BeOS application-window proportions.
    static let tabWidthRange: ClosedRange<Double> = 120...360
    static let defaultTabWidth: Double = 200
}
