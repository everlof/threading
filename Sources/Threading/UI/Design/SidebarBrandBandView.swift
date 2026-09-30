import AppKit

/// The band a theme lays behind the sidebar's header — `SidebarStyle.Brand.Band`: its own
/// gradient from the window's top edge down to the header's rule, so the brand and the list's
/// controls sit on a ground the theme chose for them rather than on the column's.
///
/// Its own view rather than a stop in the sidebar's gradient, and the difference is the reason
/// it exists. A stop is placed as a fraction of the column's height, so a red cap authored for
/// one window size bled into the first rows of a taller one and vanished above them in a
/// shorter one — and anything the list draws in the accent (a working ring, a badge) was red on
/// red wherever it overlapped. The band ends at the header's rule at every height, and the rows
/// below it keep the column's ground.
///
/// Controls on the band read their ink from it (`InkSource.brandBand`, named by the sidebar
/// through `hostGround`), the wordmark takes the band's ink unless the title states its own,
/// and the Threading mark does the same. Validation holds that ink to the label's 3:1 floor
/// against every stop, because the band carries the `+` that adds a project.
///
/// Frozen `CGColor`s restated on every apply, which runs on every theme change and appearance
/// flip — the `SidebarBackdropView` discipline. Decorative: not an accessibility element, and it
/// takes no clicks.
final class SidebarBrandBandView: NSView, ThemedComponent {

    private let gradientLayer = CAGradientLayer()
    private let appEvents = AppEventObservations()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        gradientLayer.type = .axial
        layer?.addSublayer(gradientLayer)
        setAccessibilityElement(false)
        apply()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.apply() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Whether the current theme states a band — what the sidebar asks before naming the
    /// band as its header controls' ground.
    var showsBand: Bool { !isHidden }

    /// Told after every apply, so the host can name (or stop naming) the band as its controls'
    /// ground on the same theme change or appearance flip that moved the band.
    var onApply: ((Bool) -> Void)? {
        didSet { onApply?(showsBand) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // An adaptive theme states a band per variant; a light/dark flip is a band change no
        // theme notification fires for.
        apply()
    }

    // MARK: - Private Methods

    private func apply() {
        let band = AppThemePalette.current.isSystem
            ? nil
            : SidebarAppearance.brand(for: effectiveAppearance).band
        isHidden = band == nil
        defer { onApply?(showsBand) }
        guard let gradient = band?.gradient else {
            gradientLayer.colors = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Frozen colours restated on every apply — never trusted to outlive a theme switch.
        gradientLayer.colors = gradient.colors.map(\.cgColor)
        gradientLayer.locations = gradient.locations.map { NSNumber(value: Double($0)) }
        // CSS angles: 0° flows toward the top, 90° toward the right; the layer's unit space has
        // its origin at the bottom-left, so "toward the top" is +y.
        let radians = gradient.angleDegrees * .pi / 180
        let direction = CGPoint(x: sin(radians) / 2, y: cos(radians) / 2)
        gradientLayer.startPoint = CGPoint(x: 0.5 - direction.x, y: 0.5 - direction.y)
        gradientLayer.endPoint = CGPoint(x: 0.5 + direction.x, y: 0.5 + direction.y)
        CATransaction.commit()
    }
}
