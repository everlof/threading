import AppKit

// MARK: - Window Chrome Appearance

/// Resolves the current theme's `WindowChromeStyle` into drawable values — gradient colours in
/// draw order, the band's ink for both key states, the measures the host needs — so the views
/// that dress the frame (`WindowTitleBandView`, `WindowChromeButton`, `WindowChromeFrameView`)
/// never read the document form themselves. The `SidebarAppearance` pattern, for the same
/// reason it exists there.
///
/// Everything optional in the document is answered here: an absent inactive gradient derives
/// from the active one by pulling each stop toward its own gray, an absent inactive ink dims
/// the stated one, and absent measures take the limits' defaults. Views therefore never carry
/// a fallback of their own — the one place that knows what absence means is this one.
@MainActor
public enum WindowChromeAppearance {

    public struct Gradient: Equatable {
        public let colors: [NSColor]
        public let locations: [CGFloat]
        /// CSS convention, as authored: degrees clockwise from "toward the top".
        public let angleDegrees: CGFloat
    }

    public struct Resolved: Equatable {
        public struct Texture: Equatable {
            public let kind: WindowChromeStyle.TitleBar.Texture.Kind
            public let color: NSColor
            public let spacing: CGFloat
        }

        public struct ClassicSkin: Equatable {
            public let assetName: String
            public let titleBarImage: NSImage

            public static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.assetName == rhs.assetName
                    && lhs.titleBarImage.size == rhs.titleBarImage.size
                    && lhs.titleBarImage.isEqual(rhs.titleBarImage)
            }
        }

        public let activeGradient: Gradient
        public let inactiveGradient: Gradient
        public let ink: NSColor
        public let inactiveInk: NSColor
        public let bandHeight: CGFloat
        public let titleAlignment: WindowChromeStyle.TitleBar.Alignment
        public let titleFontStyle: WindowChromeStyle.TitleBar.TitleFontStyle
        public let titleFontSize: CGFloat?
        public let glyphStyle: WindowChromeStyle.TitleBar.ButtonGlyphStyle
        public let buttonPlacement: WindowChromeStyle.TitleBar.ButtonPlacement
        public let showsAppIcon: Bool
        public let commands: WindowChromeStyle.TitleBar.CommandPlacement
        public let activeTexture: Texture?
        public let inactiveTexture: Texture?
        public let shape: WindowChromeStyle.TitleBar.Shape
        public let tabWidth: CGFloat
        public let visibleButtons: [WindowChromeStyle.TitleBar.ButtonRole]
        public let classicSkin: ClassicSkin?
        public let frameWidth: CGFloat
        public let frameCornerRadius: CGFloat
        public let frameAntialiasesCorners: Bool

        /// The radius the frame's silhouette actually turns through: the stated corner radius
        /// under a full-width band, and none under a leading tab, whose application body is
        /// rectangular below the tab. The host's clip, the well's inner clip and the frame's own
        /// drawing all take this one answer, so a shape can never round the content and square
        /// the outline — or the reverse.
        public var frameSilhouetteCornerRadius: CGFloat {
            shape == .fullWidth ? frameCornerRadius : 0
        }
    }

    /// What the current theme asks the frame to draw, or nil while the window is native —
    /// which is every theme that states no chrome.
    public static func resolve() -> Resolved? {
        resolve(for: NSApplication.shared.effectiveAppearance)
    }

    public static func resolve(for appearance: NSAppearance) -> Resolved? {
        let theme = AppThemePalette.current
        return theme.windowChrome(for: appearance).map {
            resolved(from: $0, themeID: theme.id)
        }
    }

    /// The document-to-drawable transform on its own, for a fixture — a gallery story, a
    /// render test — that shows the chrome without a takeover theme being in force. The
    /// chrome views take the result as a per-instance override, never through global state:
    /// a preview must not dress the real window.
    public static func resolved(
        from chrome: WindowChromeStyle,
        themeID: AppThemeID? = nil
    ) -> Resolved {
        let titleBar = chrome.titleBar
        let active = gradient(from: titleBar.activeGradient)
        let inactive = titleBar.inactiveGradient.map(gradient(from:))
            ?? grayed(active)
        let ink = titleBar.ink ?? .white

        return Resolved(
            activeGradient: active,
            inactiveGradient: inactive,
            ink: ink,
            inactiveInk: titleBar.inactiveInk ?? ink.withAlphaComponent(0.7),
            bandHeight: CGFloat(
                titleBar.height ?? WindowChromeStyleLimits.defaultBandHeight
            ),
            titleAlignment: titleBar.titleAlignment,
            titleFontStyle: titleBar.titleFontStyle,
            titleFontSize: titleBar.titleFontSize.map { CGFloat($0) },
            glyphStyle: titleBar.buttonGlyphStyle,
            buttonPlacement: titleBar.buttonPlacement,
            showsAppIcon: titleBar.showsAppIcon,
            commands: titleBar.commands,
            activeTexture: texture(from: titleBar.activeTexture, fallbackInk: ink),
            inactiveTexture: texture(
                from: titleBar.inactiveTexture,
                fallbackInk: titleBar.inactiveInk ?? ink.withAlphaComponent(0.7)
            ),
            shape: titleBar.shape,
            tabWidth: CGFloat(titleBar.tabWidth ?? WindowChromeStyleLimits.defaultTabWidth),
            visibleButtons: titleBar.visibleButtons,
            classicSkin: resolvedClassicSkin(titleBar.classicSkin, themeID: themeID),
            frameWidth: CGFloat(
                chrome.frame?.width ?? WindowChromeStyleLimits.defaultFrameWidth
            ),
            frameCornerRadius: CGFloat(
                chrome.frame?.cornerRadius
                    ?? WindowChromeStyleLimits.defaultFrameCornerRadius
            ),
            frameAntialiasesCorners: chrome.frame?.antialiasesCorners ?? true
        )
    }

    private static func resolvedClassicSkin(
        _ skin: WindowChromeStyle.TitleBar.ClassicSkin?,
        themeID: AppThemeID?
    ) -> Resolved.ClassicSkin? {
        guard let skin,
              let themeID,
              let image = ThemeAssetStore.image(named: skin.titleBarAsset, for: themeID)
        else { return nil }
        return Resolved.ClassicSkin(assetName: skin.titleBarAsset, titleBarImage: image)
    }

    // MARK: - The Band as a Ground

    /// The ink family for controls hosted *in* the band — `InkSource.titleBand`'s answer.
    ///
    /// Derived from the band's stated ink the way the backdrop's ink is derived from its
    /// ground: the band is a third ground in the window (the theme authors its gradient, not
    /// its roles), so components on it cut their tiers and surfaces from one base.
    public static var bandInk: Design.Ink {
        let resolved = resolve()
        let base = resolved?.ink ?? .white
        return Design.Ink(
            base: base,
            label: base,
            secondary: base.withAlphaComponent(0.7),
            tertiary: base.withAlphaComponent(0.45),
            quaternary: base.withAlphaComponent(0.25)
        )
    }

    /// The single colour that stands in for the band when a component must composite against
    /// it — the blend of the active stops, which is what the eye averages the band to.
    public static var bandGround: NSColor {
        guard let resolved = resolve(), !resolved.activeGradient.colors.isEmpty else {
            return Design.Surface.ground
        }
        let colors = resolved.activeGradient.colors.compactMap { $0.usingColorSpace(.sRGB) }
        guard !colors.isEmpty else { return Design.Surface.ground }
        let count = CGFloat(colors.count)
        return NSColor(
            srgbRed: colors.map(\.redComponent).reduce(0, +) / count,
            green: colors.map(\.greenComponent).reduce(0, +) / count,
            blue: colors.map(\.blueComponent).reduce(0, +) / count,
            alpha: 1
        )
    }

    // MARK: - Derivations

    private static func gradient(from stated: SidebarStyle.Gradient) -> Gradient {
        let ordered = stated.stops.sorted { $0.position < $1.position }
        return Gradient(
            colors: ordered.map(\.color),
            locations: ordered.map { CGFloat($0.position) },
            angleDegrees: CGFloat(stated.angleDegrees)
        )
    }

    private static func texture(
        from stated: WindowChromeStyle.TitleBar.Texture?,
        fallbackInk: NSColor
    ) -> Resolved.Texture? {
        guard let stated else { return nil }
        return Resolved.Texture(
            kind: stated.kind,
            color: stated.color ?? fallbackInk.withAlphaComponent(0.42),
            spacing: CGFloat(stated.spacing ?? WindowChromeStyleLimits.defaultTextureSpacing)
        )
    }

    /// What an inactive title bar has meant for as long as title bars could be inactive: the
    /// same band with its colour drained. Each stop moves most of the way to its own gray, so
    /// a navy band grays out instead of swapping to some unrelated palette.
    private static func grayed(_ gradient: Gradient) -> Gradient {
        Gradient(
            colors: gradient.colors.map { color in
                guard let srgb = color.usingColorSpace(.sRGB) else { return color }
                let gray = 0.299 * srgb.redComponent
                    + 0.587 * srgb.greenComponent
                    + 0.114 * srgb.blueComponent
                return NSColor(
                    srgbRed: srgb.redComponent + (gray - srgb.redComponent) * 0.8,
                    green: srgb.greenComponent + (gray - srgb.greenComponent) * 0.8,
                    blue: srgb.blueComponent + (gray - srgb.blueComponent) * 0.8,
                    alpha: srgb.alphaComponent
                )
            },
            locations: gradient.locations,
            angleDegrees: gradient.angleDegrees
        )
    }
}
