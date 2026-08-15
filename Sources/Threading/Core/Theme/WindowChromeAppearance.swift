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
enum WindowChromeAppearance {

    struct Gradient: Equatable {
        let colors: [NSColor]
        let locations: [CGFloat]
        /// CSS convention, as authored: degrees clockwise from "toward the top".
        let angleDegrees: CGFloat
    }

    struct Resolved: Equatable {
        struct Texture: Equatable {
            let kind: WindowChromeStyle.TitleBar.Texture.Kind
            let color: NSColor
            let spacing: CGFloat
        }

        struct ClassicSkin: Equatable {
            let assetName: String
            let titleBarImage: NSImage

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.assetName == rhs.assetName
                    && lhs.titleBarImage.size == rhs.titleBarImage.size
                    && lhs.titleBarImage.isEqual(rhs.titleBarImage)
            }
        }

        let activeGradient: Gradient
        let inactiveGradient: Gradient
        let ink: NSColor
        let inactiveInk: NSColor
        let bandHeight: CGFloat
        let titleAlignment: WindowChromeStyle.TitleBar.Alignment
        let titleFontStyle: WindowChromeStyle.TitleBar.TitleFontStyle
        let titleFontSize: CGFloat?
        let glyphStyle: WindowChromeStyle.TitleBar.ButtonGlyphStyle
        let buttonPlacement: WindowChromeStyle.TitleBar.ButtonPlacement
        let showsAppIcon: Bool
        let activeTexture: Texture?
        let inactiveTexture: Texture?
        let shape: WindowChromeStyle.TitleBar.Shape
        let tabWidth: CGFloat
        let visibleButtons: [WindowChromeStyle.TitleBar.ButtonRole]
        let classicSkin: ClassicSkin?
        let frameWidth: CGFloat
        let frameCornerRadius: CGFloat
        let frameAntialiasesCorners: Bool
    }

    /// What the current theme asks the frame to draw, or nil while the window is native —
    /// which is every theme that states no chrome.
    static func resolve() -> Resolved? {
        resolve(for: NSApplication.shared.effectiveAppearance)
    }

    static func resolve(for appearance: NSAppearance) -> Resolved? {
        let theme = AppThemePalette.current
        return theme.windowChrome(for: appearance).map {
            resolved(from: $0, themeID: theme.id)
        }
    }

    /// The document-to-drawable transform on its own, for a fixture — a gallery story, a
    /// render test — that shows the chrome without a takeover theme being in force. The
    /// chrome views take the result as a per-instance override, never through global state:
    /// a preview must not dress the real window.
    static func resolved(
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
    static var bandInk: Design.Ink {
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
    static var bandGround: NSColor {
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
