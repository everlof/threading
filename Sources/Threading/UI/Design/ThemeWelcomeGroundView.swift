import AppKit

// MARK: - Theme Welcome Ground View

/// The new-session composer's ground: a structural root that wears the theme's welcome backdrop
/// (`ThemeWelcome.backdrop`) beneath every view it holds.
///
/// **The same machinery every backdrop draws with.** The wash, the picture and the particle field
/// are one `ThemeBackdropDressingLayer` — the layer `applySurface(pattern: .backdrop)` hangs under
/// the broad grounds — resolved through `ThemeBackdropAppearance.resolve`. So a welcome's drift
/// is `ThemeBackdropMotionView`'s, its particles are `ThemeParticleFieldLayer`'s, and all of it
/// answers `ThemeParticleHold`: Reduce Motion, the Theme animations setting and Low Power Mode
/// leave a still frame, and a hidden composer holds its field in time.
///
/// **Beneath everything, by being the root.** The dressing is this view's own layer's bottom
/// sublayer rather than a sibling view, so the composer's own first subview — the extension
/// plane `composer.backdrop@1` dresses — stays first and stays above the theme's art. AppKit
/// adds subview layers as sublayers too, and may insert one below everything, so the dressing is
/// put back at the bottom whenever a subview arrives and on every layout.
///
/// Self-wired like `SidebarBackdropView`: a theme switch and an appearance flip restate it, and
/// it is cleared rather than skipped when a theme states nothing, so leaving a welcome takes its
/// wallpaper with it. It takes no clicks of its own beyond what an empty root takes, and it is
/// not an accessibility element.
final class ThemeWelcomeGroundView: NSView, ThemedComponent {

    // MARK: - Properties

    /// Named apart from `applySurface`'s dressing, which that path finds and strips by name.
    static let layerName = "threading.welcomeBackdrop"

    private let dressing = ThemeBackdropDressingLayer()
    private let appEvents = AppEventObservations()
    private var lastReportedVisibility: Bool?

    /// Told whether the ground can be seen — in a window and not hidden, itself or through an
    /// ancestor — whenever that changes. A host whose work is only worth doing while it is seen
    /// (a clock in the greeting) starts and stops on this.
    var onVisibilityChange: ((Bool) -> Void)?

    /// Told after the ground restated itself for a new appearance — an adaptive theme's variant
    /// flip, which no theme notification announces.
    var onAppearanceChange: (() -> Void)?

    /// A welcome to draw in place of the theme's — for a preview that states one without
    /// installing a theme. Nil, the product's answer, reads the theme in force.
    var preview: ThemeWelcome? {
        didSet { if preview != oldValue { apply() } }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dressing.name = Self.layerName
        dressing.isHidden = true
        layer?.insertSublayer(dressing, at: 0)
        setAccessibilityElement(false)
        apply()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.apply() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Whether the theme's welcome dresses this ground — what a test asks without pixels.
    var isDressed: Bool { !dressing.isHidden }

    /// The dressing itself, for a test asking what it shows.
    var backdrop: ThemeBackdropDressingLayer { dressing }

    /// In a window and not hidden. The composer is shown and put away by hiding its root.
    var isVisible: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    // MARK: - Layout

    override func layout() {
        super.layout()
        keepDressingAtTheBottom()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dressing.frame = bounds
        CATransaction.commit()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        keepDressingAtTheBottom()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dressing.contentsScale = window?.backingScaleFactor ?? dressing.contentsScale
        // A field decides whether it moves from its window; a move is a new answer.
        dressing.particles.refresh()
        reportVisibility()
    }

    override func viewDidHide() {
        super.viewDidHide()
        dressing.particles.refresh()
        reportVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        dressing.particles.refresh()
        reportVisibility()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // An adaptive theme states its welcome per variant, and a system light/dark flip is a
        // variant change no theme notification fires for.
        apply()
        onAppearanceChange?()
    }

    // MARK: - Private Methods

    /// Shows the welcome backdrop the current theme states for this appearance, or nothing.
    private func apply() {
        let welcome = preview ?? ThemeWelcomeAppearance.welcome(for: effectiveAppearance)
        guard let resolved = ThemeWelcomeAppearance.backdrop(
            welcome,
            appearance: effectiveAppearance
        ) else {
            dressing.stopMotion()
            dressing.apply(ThemeBackdropAppearance.Resolved(), in: self)
            dressing.isHidden = true
            return
        }
        dressing.isHidden = false
        dressing.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? dressing.contentsScale
        // Frozen colours and pictures are restated in this view's own appearance on every
        // apply, the discipline `applySurface` keeps for the same layer.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dressing.apply(resolved, in: self)
        }
        needsLayout = true
    }

    private func keepDressingAtTheBottom() {
        guard let layer, layer.sublayers?.first !== dressing else { return }
        dressing.removeFromSuperlayer()
        layer.insertSublayer(dressing, at: 0)
    }

    private func reportVisibility() {
        let visible = isVisible
        guard visible != lastReportedVisibility else { return }
        lastReportedVisibility = visible
        onVisibilityChange?(visible)
    }
}
