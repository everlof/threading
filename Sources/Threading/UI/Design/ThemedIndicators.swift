import AppKit

/// A hairline rule, replacing `NSBox(boxType: .separator)`.
///
/// A box is a container that happens to be able to draw a line, and the line it draws is a
/// *system* grey — which on a themed page is the one grey the theme has already replaced.
/// Swiss Minimalist is the case that makes this obvious: the style is black rules on white, and
/// a pale system hairline is the single thing it cannot have.
final class SeparatorView: NSView, ThemedComponent {

    enum Orientation {
        case horizontal
        case vertical
    }

    private let orientation: Orientation
    private var themeRedraw: ThemeRedraw?

    init(_ orientation: Orientation = .horizontal) {
        self.orientation = orientation
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The rule's thickness is the theme's border width, so a style that draws heavy rules draws
    /// them here too rather than only around its cards.
    override var intrinsicContentSize: NSSize {
        switch orientation {
        case .horizontal: NSSize(width: NSView.noIntrinsicMetric, height: Design.Radius.border)
        case .vertical: NSSize(width: Design.Radius.border, height: NSView.noIntrinsicMetric)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Design.Surface.divider.setFill()
        bounds.fill()
    }
}

// MARK: - Spinner

/// An indeterminate spinner drawn from the theme, replacing `NSProgressIndicator(style: .spinning)`.
///
/// The system spinner is drawn in a system grey and cannot be told otherwise — `contentTintColor`
/// does not reach it — so a working session on a neon page spun in the one colour the page had
/// removed. This draws an arc in the theme's accent.
///
/// It animates with a `CABasicAnimation` on a sublayer rather than by redrawing on a timer: a
/// spinner runs for as long as an agent is working, which is minutes, and a timer-driven redraw
/// of a 12pt view is main-thread work for the whole of it.
final class ThemedSpinner: NSView, ThemedComponent {

    private enum Layout {
        static let size: CGFloat = 14
        static let lineWidth: CGFloat = 1.5
        /// A gap in the ring is what makes rotation visible at all.
        static let sweep: CGFloat = 0.72
        static let period: CFTimeInterval = 0.9
        /// Used only before the view has a window or a screen to ask. Retina rather than 1×
        /// because guessing low is the case that ships blurry — `ThreadingMarkView`'s rule.
        static let assumedBackingScale: CGFloat = 2
    }

    private let arc = CAShapeLayer()
    private var themeRedraw: ThemeRedraw?

    /// Mirrors `NSProgressIndicator.isDisplayedWhenStopped`, and defaults the same way this app
    /// used it: a stopped spinner is not a small grey ring, it is nothing.
    var isAnimating: Bool = false {
        didSet { applyAnimation() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineWidth = Layout.lineWidth
        arc.lineCap = .round
        layer?.addSublayer(arc)
        applyContentsScale()
        themeRedraw = ThemeRedraw(self)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        // `didSet` does not run for an initial value, so without this a spinner is a static
        // three-quarter ring from construction until something first toggles `isAnimating` —
        // the "small grey ring" this deliberately is not. Call sites had started working around
        // it by hiding the spinner themselves.
        applyAnimation()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.size, height: Layout.size)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }
    override func accessibilityLabel() -> String? {
        super.accessibilityLabel() ?? "Working"
    }

    override func layout() {
        super.layout()
        let inset = Layout.lineWidth
        let box = bounds.insetBy(dx: inset, dy: inset)
        arc.frame = bounds
        arc.path = CGPath(
            ellipseIn: box,
            transform: nil
        )
        arc.strokeStart = 0
        arc.strokeEnd = Layout.sweep
    }

    /// A shape layer's `strokeColor` is a `CGColor`, which resolves once and freezes — the exact
    /// bug themed controls draw to avoid. A spinner cannot be drawn without a layer if it is to
    /// animate off the main thread, so the colour is re-applied on every redraw instead, and
    /// `ThemeRedraw` is what asks for one.
    override func draw(_ dirtyRect: NSRect) {
        arc.strokeColor = Design.Surface.accent.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The same trap `ThreadingMarkView` documents: a shape layer added by hand is not given
    /// the view's `contentsScale`, so the arc rasterised its path at 1× and the compositor
    /// scaled it up — a 1.5pt ring that was two pixels of grey smear on every Retina display,
    /// for every minute an agent worked. Re-asked when the window moves between displays.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
    }

    private func applyContentsScale() {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? Layout.assumedBackingScale
        layer?.contentsScale = scale
        arc.contentsScale = scale
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        applyAnimation()
    }

    private func applyAnimation() {
        isHidden = !isAnimating

        guard isAnimating else {
            arc.removeAnimation(forKey: "spin")
            return
        }
        guard !Design.Motion.reducesMotion else {
            // The visible three-quarter arc still says "working"; only its perpetual movement
            // disappears. This preserves status without replacing one animation with another.
            arc.removeAnimation(forKey: "spin")
            return
        }
        guard arc.animation(forKey: "spin") == nil else { return }

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2
        spin.duration = Layout.period
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        arc.frame = bounds
        arc.add(spin, forKey: "spin")
    }
}

// MARK: - Progress Bar

/// A determinate progress bar drawn from the theme, replacing `NSProgressIndicator(style: .bar)`.
///
/// One page load's worth of feedback in the browser pane, in the accent rather than in the system
/// blue a themed window has already moved away from.
final class ThemedProgressBar: NSView, ThemedComponent {

    private enum Layout {
        static let height: CGFloat = 3
    }

    private var themeRedraw: ThemeRedraw?

    /// 0…1. Clamped, because a caller reading a fraction off a web view is reading someone
    /// else's number.
    var progress: Double = 0 {
        didSet {
            needsDisplay = true
            if progress != oldValue {
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeRedraw = ThemeRedraw(self)
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        invalidateIntrinsicContentSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: usesClassicProgress ? ThemedProgressDrawing.classicHeight : Layout.height
        )
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }
    override func accessibilityLabel() -> String? {
        super.accessibilityLabel() ?? "Progress"
    }
    override func accessibilityValue() -> Any? { min(max(progress, 0), 1) }

    override func draw(_ dirtyRect: NSRect) {
        if usesClassicProgress {
            drawClassicProgress()
            return
        }
        Design.Surface.controlResting.setFill()
        bounds.fill()

        let fraction = min(max(progress, 0), 1)
        guard fraction > 0 else { return }
        Design.Surface.accent.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height).fill()
    }

    /// The default Win32 progress control was a sunken trough filled with discrete blocks;
    /// `PBS_SMOOTH` was an opt-in style. The material states that choice directly so a custom
    /// nineties theme can request it without every hard-bevel system being mistaken for Win32.
    private func drawClassicProgress() {
        ThemedProgressDrawing.drawSegmented(
            in: bounds,
            fraction: progress,
            tint: Design.Surface.accent
        )
    }

    private var usesClassicProgress: Bool {
        AppThemePalette.current.material(for: effectiveAppearance).progressStyle == .segmented
    }
}

/// Shared classic progress anatomy. Usage meters used to bypass `ThemedProgressBar` and thereby
/// kept drawing a modern navy pill under Windows 98 even after the theme had explicitly chosen
/// segmented progress. Geometry lives here so every determinate gauge answers the same material.
@MainActor
enum ThemedProgressDrawing {
    static let classicHeight: CGFloat = 14
    private static let edge: CGFloat = 2
    private static let segmentWidth: CGFloat = 7
    private static let segmentGap: CGFloat = 2

    static func drawSegmented(in bounds: NSRect, fraction: Double, tint: NSColor) {
        _ = ThemedSurface.draw(
            bounds,
            fill: Design.Surface.controlResting,
            radius: 0,
            bevel: .sunken
        )

        let track = bounds.insetBy(dx: edge, dy: min(edge, bounds.height / 3))
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0, track.width > 0, track.height > 0 else { return }
        let limit = track.minX + track.width * clamped
        let stride = segmentWidth + segmentGap
        tint.setFill()

        var x = track.minX
        while x + segmentWidth / 2 <= limit {
            NSRect(
                x: x,
                y: track.minY,
                width: min(segmentWidth, track.maxX - x),
                height: track.height
            ).fill()
            x += stride
        }
    }
}
