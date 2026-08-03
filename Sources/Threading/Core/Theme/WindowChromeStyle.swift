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

        /// Points, bounded by `WindowChromeStyleLimits.bandHeightRange`. Absent means
        /// `WindowChromeStyleLimits.defaultBandHeight`.
        var height: Double?

        /// How the close/minimize/zoom glyphs draw. One vocabulary interpreted by one
        /// component — a theme picks a style, it never draws its own buttons.
        var buttonGlyphStyle: ButtonGlyphStyle

        init(
            activeGradient: SidebarStyle.Gradient,
            inactiveGradient: SidebarStyle.Gradient? = nil,
            ink: NSColor? = nil,
            inactiveInk: NSColor? = nil,
            titleAlignment: Alignment = .leading,
            height: Double? = nil,
            buttonGlyphStyle: ButtonGlyphStyle = .plain
        ) {
            self.activeGradient = activeGradient
            self.inactiveGradient = inactiveGradient
            self.ink = ink
            self.inactiveInk = inactiveInk
            self.titleAlignment = titleAlignment
            self.height = height
            self.buttonGlyphStyle = buttonGlyphStyle
        }

        enum Alignment: String, Codable, CaseIterable {
            case leading, center
        }

        enum ButtonGlyphStyle: String, Codable, CaseIterable {
            /// Bare glyphs in the band's ink.
            case plain
            /// Square plates holding the glyphs — the Windows lineage. The plates take the
            /// theme's control surface and, under a bevel material, its bevel.
            case squares
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
        case titleAlignment, height, buttonGlyphStyle
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
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        buttonGlyphStyle = try container.decodeIfPresent(
            ButtonGlyphStyle.self,
            forKey: .buttonGlyphStyle
        ) ?? .plain
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activeGradient, forKey: .activeGradient)
        try container.encodeIfPresent(inactiveGradient, forKey: .inactiveGradient)
        try container.encodeIfPresent(ink?.hexString, forKey: .ink)
        try container.encodeIfPresent(inactiveInk?.hexString, forKey: .inactiveInk)
        try container.encode(titleAlignment, forKey: .titleAlignment)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encode(buttonGlyphStyle, forKey: .buttonGlyphStyle)
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

// MARK: - Limits

/// The bounds `AppThemeEditing.validate` holds a chrome block to, stated beside the model so
/// a limit and the field it limits travel together — the `SidebarStyleLimits` rule.
enum WindowChromeStyleLimits {
    /// Points. Below 22 the band cannot hold its own buttons at a clickable size; past 44 it
    /// stops being a title bar and starts being a pane.
    static let bandHeightRange: ClosedRange<Double> = 22...44
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
}
