import AppKit

// MARK: - Theme Welcome Scrim View

/// Soft veils in the theme's ground colour behind the two regions a person works in on the
/// new-session composer — the hero (mark over greeting) and the prompt box — so a busy picture or
/// a bright particle field never sits straight under the words (`ThemeWelcome.Scrim`).
///
/// **A veil is radial, and it reaches past its region.** Each is an elliptical radial gradient
/// centred on its region: at the theme's peak opacity across the whole region, falling smoothly
/// to nothing at the region's frame inflated by `Design.Spacing.pane` — the ellipse is drawn
/// through that inflated frame's corners, so no corner of the region is left outside the peak
/// and no edge of the veil can be seen. A hard-edged plate would read as a card the theme never
/// asked for.
///
/// **The colour is resolved while drawing**, never frozen onto a layer: the ground role is read
/// in `draw(_:)` in the view's own appearance, so a theme switch or an appearance flip is a
/// redraw, which the theme sweep and `viewDidChangeEffectiveAppearance` both ask for. The
/// strengths are the theme's, read the same way, so the host states only *where* the regions
/// are and restates that on layout.
///
/// Decorative: it answers no hit test, is not an accessibility element, and draws nothing — and
/// stays hidden — while the theme states no scrim.
final class ThemeWelcomeScrimView: NSView, ThemedComponent {

    // MARK: - Properties

    /// How far a veil reaches past the region it sits behind.
    static let reach: CGFloat = Design.Spacing.pane

    /// The falloff from the peak to nothing, as fractions of the remaining radius: a smoothstep
    /// sampled finely enough that the ellipse shows no banding at the 0.9 ceiling.
    private static let falloffSamples = 8

    private let appEvents = AppEventObservations()

    /// The hero's frame, in this view's coordinates. `.zero` when there is no hero to veil.
    var heroRegion: CGRect = .zero {
        didSet { if heroRegion != oldValue { needsDisplay = true } }
    }

    /// The prompt box's frame, in this view's coordinates.
    var promptRegion: CGRect = .zero {
        didSet { if promptRegion != oldValue { needsDisplay = true } }
    }

    /// A welcome whose scrim to draw in place of the theme's — for a preview. Nil reads the
    /// theme in force.
    var preview: ThemeWelcome? {
        didSet { if preview != oldValue { apply() } }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
        apply()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.apply() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// The strengths the current theme states for this view's appearance.
    var scrim: ThemeWelcomeAppearance.Scrim {
        ThemeWelcomeAppearance.scrim(
            preview ?? ThemeWelcomeAppearance.welcome(for: effectiveAppearance)
        )
    }

    /// One veil as it is drawn: the ellipse its gradient spans, the share of that radius it
    /// holds at the peak for, and that peak.
    struct Veil: Equatable {
        let ellipse: CGRect
        let peakRadius: CGFloat
        let opacity: CGFloat
    }

    /// The veils for the current regions and theme, in drawing order. Empty when there is
    /// nothing to veil — what a test asks without reading pixels.
    var veils: [Veil] {
        let scrim = scrim
        return [(heroRegion, scrim.hero), (promptRegion, scrim.prompt)].compactMap { region, opacity in
            Self.veil(behind: region, opacity: opacity)
        }
    }

    /// The veil behind `region` at `opacity`, or nil for an empty region or no strength.
    static func veil(behind region: CGRect, opacity: CGFloat) -> Veil? {
        guard opacity > 0, region.width > 0, region.height > 0 else { return nil }
        let inflated = region.insetBy(dx: -reach, dy: -reach)
        // Through the inflated frame's corners: an ellipse whose semi-axes are √2 times the
        // frame's half-sides passes exactly through them.
        let ellipse = inflated.insetBy(
            dx: -(inflated.width * (2.squareRoot() - 1)) / 2,
            dy: -(inflated.height * (2.squareRoot() - 1)) / 2
        )
        // The region's own corner, as a fraction of the ellipse's radius: the peak holds out to
        // it, so every point of the region is under the full veil.
        let cornerX = (region.width / 2) / (ellipse.width / 2)
        let cornerY = (region.height / 2) / (ellipse.height / 2)
        let peakRadius = min((cornerX * cornerX + cornerY * cornerY).squareRoot(), 1)
        return Veil(ellipse: ellipse, peakRadius: peakRadius, opacity: opacity)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let veils = veils
        guard !veils.isEmpty else { return }
        // Resolved here, in this view's appearance — a dynamic role read at display time is
        // the one theme colour that cannot go stale.
        let ground = (Design.Surface.ground.usingColorSpace(.sRGB) ?? Design.Surface.ground)
            .withAlphaComponent(1)
        for veil in veils {
            draw(veil, ground: ground, in: context)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    // MARK: - Private Methods

    private func apply() {
        isHidden = scrim.isEmpty
        needsDisplay = true
    }

    private func draw(_ veil: Veil, ground: NSColor, in context: CGContext) {
        var locations: [CGFloat] = [0, veil.peakRadius]
        var colors: [CGColor] = [
            ground.withAlphaComponent(veil.opacity).cgColor,
            ground.withAlphaComponent(veil.opacity).cgColor
        ]
        for sample in 1...Self.falloffSamples {
            let progress = CGFloat(sample) / CGFloat(Self.falloffSamples)
            let eased = progress * progress * (3 - 2 * progress)
            locations.append(veil.peakRadius + (1 - veil.peakRadius) * progress)
            colors.append(ground.withAlphaComponent(veil.opacity * (1 - eased)).cgColor)
        }
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors as CFArray,
            locations: locations
        ) else { return }

        context.saveGState()
        // A unit circle scaled to the ellipse: one radial gradient, stretched.
        context.translateBy(x: veil.ellipse.midX, y: veil.ellipse.midY)
        context.scaleBy(x: veil.ellipse.width / 2, y: veil.ellipse.height / 2)
        context.drawRadialGradient(
            gradient,
            startCenter: .zero,
            startRadius: 0,
            endCenter: .zero,
            endRadius: 1,
            options: []
        )
        context.restoreGState()
    }
}
