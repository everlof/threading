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

    /// How strongly the rule separates what sits on either side of it.
    ///
    /// Most separators divide rows inside one surface and deliberately stay quiet. A boundary
    /// between sibling panes has to remain legible when both panes resolve to nearly the same
    /// ground, so it takes the theme's structural border ink instead.
    enum Role {
        case content
        case paneBoundary
    }

    private let orientation: Orientation
    private let role: Role
    private var themeRedraw: ThemeRedraw?

    init(_ orientation: Orientation = .horizontal, role: Role = .content) {
        self.orientation = orientation
        self.role = role
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

    /// The frame gap that leaves `inkGap` between this rule and what the adjacent view visibly
    /// draws. A padded control owns the correction; the separator merely applies it on the axis
    /// it divides. Bare labels and structural containers have no correction and keep the full
    /// gap.
    func frameGap(to adjacentView: NSView, forInkGap inkGap: CGFloat) -> CGFloat {
        guard let provider = adjacentView as? OpticalInsetProviding else {
            return max(0, inkGap)
        }
        let inset: CGFloat
        switch orientation {
        case .horizontal:
            inset = provider.opticalVerticalInset(
                forFrameHeight: Self.resolvedLength(of: adjacentView, on: .vertical)
            )
        case .vertical:
            inset = provider.opticalHorizontalInset
        }
        return max(0, inkGap - inset)
    }

    /// Applies one visible-ink gap on both sides of a rule arranged in a stack. The views are
    /// the actual neighbours whose frames the stack places; hidden or nested content remains the
    /// host's decision rather than something this component walks and guesses at.
    func applyOpticalSpacing(
        in stack: NSStackView,
        precededBy precedingView: NSView?,
        followedBy followingView: NSView?,
        inkGap: CGFloat
    ) {
        let expectedStackOrientation: NSUserInterfaceLayoutOrientation = orientation == .horizontal
            ? .vertical
            : .horizontal
        guard stack.orientation == expectedStackOrientation else {
            assertionFailure("A separator must be perpendicular to the stack it spaces")
            return
        }
        if let precedingView {
            stack.setCustomSpacing(
                frameGap(to: precedingView, forInkGap: inkGap),
                after: precedingView
            )
        }
        if let followingView {
            stack.setCustomSpacing(
                frameGap(to: followingView, forInkGap: inkGap),
                after: self
            )
        }
    }

    private enum Axis {
        case horizontal
        case vertical
    }

    /// Prefer an active fixed constraint over `bounds`: density can change a row constraint and
    /// ask for spacing again before the next layout pass, when the bounds still carry the old
    /// height. Intrinsic/fitting sizes are fallbacks for naturally sized controls.
    private static func resolvedLength(of view: NSView, on axis: Axis) -> CGFloat {
        let attribute: NSLayoutConstraint.Attribute = axis == .horizontal ? .width : .height
        var fixed: (priority: NSLayoutConstraint.Priority, value: CGFloat)?
        for constraint in view.constraints where constraint.isActive
            && constraint.relation == .equal
            && constraint.firstAttribute == attribute
            && constraint.secondItem == nil {
            guard let item = constraint.firstItem as? NSView, item === view else { continue }
            if fixed == nil || constraint.priority.rawValue > fixed!.priority.rawValue {
                fixed = (constraint.priority, constraint.constant)
            }
        }
        if let fixed, fixed.value > 0 { return fixed.value }

        let boundsLength = axis == .horizontal ? view.bounds.width : view.bounds.height
        if boundsLength > 0 { return boundsLength }

        let intrinsic = view.intrinsicContentSize
        let intrinsicLength = axis == .horizontal ? intrinsic.width : intrinsic.height
        if intrinsicLength > 0, intrinsicLength < 10_000 { return intrinsicLength }

        let fitting = view.fittingSize
        return max(0, axis == .horizontal ? fitting.width : fitting.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch role {
        case .content: Design.Surface.divider.setFill()
        case .paneBoundary: Design.Surface.border.setFill()
        }
        bounds.fill()
    }
}

// MARK: - Status Progress Ring

/// A compact semantic receipt split between positive, non-blocking, active, and adverse outcomes.
///
/// The host supplies counts; the design system owns the ring's geometry and status colours.
/// Non-blocking outcomes remain the neutral base track while adjacent text keeps every provider
/// state distinct, so neither the outcome nor its reason depends on hue.
@MainActor
enum ThemedStatusProgressRing {

    struct Fractions: Equatable {
        let positive: CGFloat
        let nonBlocking: CGFloat
        let active: CGFloat
        let negative: CGFloat
    }

    private enum Layout {
        /// Matches the mark slot on an ordinary compact button without enlarging the row.
        static let size = NSSize(width: 14, height: 14)
        /// Thick enough for the small remaining slice to survive at 1×.
        static let lineWidth: CGFloat = 3
        static let startAngle: CGFloat = 90
        static let fullCircle: CGFloat = 360
        static let maximumCount = 10_000
    }

    static func fractions(
        positive: Int,
        nonBlocking: Int,
        active: Int,
        negative: Int
    ) -> Fractions {
        let counts = [positive, nonBlocking, active, negative].map {
            min(max(0, $0), Layout.maximumCount)
        }
        let total = counts.reduce(0, +)
        guard total > 0 else {
            return Fractions(positive: 0, nonBlocking: 1, active: 0, negative: 0)
        }
        return Fractions(
            positive: CGFloat(counts[0]) / CGFloat(total),
            nonBlocking: CGFloat(counts[1]) / CGFloat(total),
            active: CGFloat(counts[2]) / CGFloat(total),
            negative: CGFloat(counts[3]) / CGFloat(total)
        )
    }

    static func image(
        positive: Int,
        nonBlocking: Int,
        active: Int,
        negative: Int
    ) -> NSImage {
        let reading = fractions(
            positive: positive,
            nonBlocking: nonBlocking,
            active: active,
            negative: negative
        )
        let image = NSImage(size: Layout.size, flipped: false) { rect in
            let ringRect = rect.insetBy(dx: Layout.lineWidth / 2, dy: Layout.lineWidth / 2)
            let track = NSBezierPath(ovalIn: ringRect)
            track.lineWidth = Layout.lineWidth
            Design.Text.tertiary.setStroke()
            track.stroke()

            draw(
                fraction: reading.positive,
                after: 0,
                in: ringRect,
                color: Design.Status.positive
            )
            draw(
                fraction: reading.active,
                after: reading.positive + reading.nonBlocking,
                in: ringRect,
                color: Design.Status.warning
            )
            draw(
                fraction: reading.negative,
                after: reading.positive + reading.nonBlocking + reading.active,
                in: ringRect,
                color: Design.Status.negative
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(
        fraction: CGFloat,
        after completedFraction: CGFloat,
        in rect: NSRect,
        color: NSColor
    ) {
        guard fraction > 0 else { return }
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let start = Layout.startAngle - completedFraction * Layout.fullCircle
        let end = start - fraction * Layout.fullCircle
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: centre,
            radius: radius,
            startAngle: start,
            endAngle: end,
            clockwise: true
        )
        arc.lineWidth = Layout.lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
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

    /// A ground this spinner's host paints over its ordinary surface, when there is one.
    ///
    /// At rest the accent is the status ink. Inside an emphasized selection that same accent is
    /// the ground itself, so the host names the new ground and the spinner takes its legible ink.
    /// The ground is retained rather than a resolved colour so live theme changes are answered
    /// again on the next draw.
    var hostGround: InkSource? {
        didSet {
            guard hostGround != oldValue else { return }
            needsDisplay = true
        }
    }

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
        arc.strokeColor = (hostGround?.ink.label ?? Design.Surface.accent).cgColor
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
            height: usesWorkbenchProgress
                ? ThemedProgressDrawing.workbenchHeight
                : (usesIRIXProgress
                    ? ThemedProgressDrawing.irixHeight
                    : (usesClassicProgress ? ThemedProgressDrawing.classicHeight : Layout.height))
        )
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }
    override func accessibilityLabel() -> String? {
        super.accessibilityLabel() ?? "Progress"
    }
    override func accessibilityValue() -> Any? { min(max(progress, 0), 1) }

    override func draw(_ dirtyRect: NSRect) {
        if usesWorkbenchProgress {
            ThemedProgressDrawing.drawWorkbench(
                in: bounds,
                fraction: progress,
                tint: workbenchProgressBlue
            )
            return
        }
        if usesIRIXProgress {
            ThemedProgressDrawing.drawIRIX(
                in: bounds,
                fraction: progress,
                tint: Design.Surface.accent
            )
            return
        }
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

    private var usesWorkbenchProgress: Bool {
        AppThemePalette.current.material(for: effectiveAppearance).progressStyle == .amiga
    }

    private var usesIRIXProgress: Bool {
        AppThemePalette.current.material(for: effectiveAppearance).progressStyle == .irix
    }

    private var workbenchProgressBlue: NSColor {
        WindowChromeAppearance.resolve()?.activeGradient.colors.first
            ?? Design.Surface.accent
    }
}

/// Shared classic progress anatomy. Usage meters used to bypass `ThemedProgressBar` and thereby
/// kept drawing a modern navy pill under Windows 98 even after the theme had explicitly chosen
/// segmented progress. Geometry lives here so every determinate gauge answers the same material.
@MainActor
enum ThemedProgressDrawing {
    static let classicHeight: CGFloat = 14
    /// Workbench's manual names a horizontal percentage gauge but preserves no native pixels.
    /// This compact height follows its 18px requester/control rhythm and remains source-inferred.
    static let workbenchHeight: CGFloat = 12
    /// The Indigo Magic scale's measured native figure is a compact fourteen-pixel well,
    /// matching the source crop's outer frame rather than the modern three-pixel rail.
    static let irixHeight: CGFloat = 14
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
        guard clamped > 0 else { return }

        drawSegments(in: track, tint: tint, upTo: track.minX + track.width * clamped)
    }

    /// Workbench's source-backed *grammar* is a horizontal percentage gauge, not Win32's
    /// separated blocks. Keep the four-colour trough and the active title blue while leaving
    /// the unresolved native thickness documented at the material level.
    static func drawWorkbench(in bounds: NSRect, fraction: Double, tint: NSColor) {
        _ = ThemedSurface.draw(
            bounds,
            fill: Design.Surface.field,
            border: Design.Surface.border,
            radius: 0,
            bevel: .sunken
        )

        let track = bounds.insetBy(dx: edge, dy: min(edge, bounds.height / 3))
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0, track.width > 0, track.height > 0 else { return }

        tint.setFill()
        NSRect(
            x: track.minX,
            y: track.minY,
            width: track.width * clamped,
            height: track.height
        ).fill()
    }

    /// Indigo Magic's progress scale is a hard, square well whose leading edge is diagonal.
    /// The source figure shows the diagonal as eight pixels across the inset track; keeping it
    /// as a path (rather than a rectangle followed by a decorative slash) makes the fill and
    /// the empty well share one silhouette at every fraction.
    static func drawIRIX(in bounds: NSRect, fraction: Double, tint: NSColor) {
        _ = ThemedSurface.draw(
            bounds,
            fill: Design.Surface.controlResting,
            border: Design.Surface.border,
            radius: 0,
            bevel: .sunken
        )

        let track = bounds.insetBy(dx: edge, dy: min(edge, bounds.height / 3))
        guard track.width > 0, track.height > 0 else { return }

        let path = irixTrackPath(in: track)
        Design.Surface.field.setFill()
        path.fill()

        let clamped = min(max(fraction, 0), 1)
        if clamped > 0 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            tint.setFill()
            NSRect(
                x: track.minX,
                y: track.minY,
                width: track.width * clamped,
                height: track.height
            ).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // The measured figure's diagonal and bottom rule are the same hard dark rail; redraw
        // the path after the fill so a saturated theme accent cannot consume the relief.
        Design.Surface.bevelShadow.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private static func irixTrackPath(in track: NSRect) -> NSBezierPath {
        let slant = min(8, max(1, floor(track.height - 1)))
        let path = NSBezierPath()
        path.move(to: NSPoint(x: track.minX + slant, y: track.maxY))
        path.line(to: NSPoint(x: track.maxX, y: track.maxY))
        path.line(to: NSPoint(x: track.maxX, y: track.minY))
        path.line(to: NSPoint(x: track.minX, y: track.minY))
        path.close()
        return path
    }

    /// The chunks alone, with no trough under them.
    ///
    /// Split out so a surface that draws its *own* trough can still fill it the way this theme
    /// fills a progress bar. The usage-window diagram is the caller: it draws one trough per
    /// window, and a fill that ignored the material would put a smooth bar inside a Win98 well.
    ///
    /// `upTo` exists for `drawSegmented`, whose last chunk may straddle the fraction and is then
    /// clipped by the *track*, not by the fraction. Left at nil the chunks fill `track`.
    static func drawSegments(in track: NSRect, tint: NSColor, upTo limit: CGFloat? = nil) {
        guard track.width > 0, track.height > 0 else { return }

        let limit = limit ?? track.maxX
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

// MARK: - Warning Mark

/// A triangular status mark, drawn in a `Design.Status` role with the theme's own corners.
///
/// The third mark a session row can wear, beside the spinner and the attention dot, and the one
/// that says the agent **stopped for a reason nobody typed** — today, an account whose usage
/// limit is spent. It is a triangle rather than a third dot because that is the whole point of
/// it: the dots are ranked against each other by fill, which only separates two states that are
/// both "the session wants you". A stop the user cannot answer is a different kind of fact and
/// gets a different silhouette, which is also what keeps it legible under Differentiate Without
/// Colour — the shape carries the meaning with the red removed.
///
/// **The corners follow the chrome.** The radius is the theme's control radius, capped at a
/// fraction of the triangle's own side: a corner is only a corner while it is small next to the
/// edge it interrupts, and `Design.Radius.control` is 8 under System, which on an 11pt triangle
/// would round the whole shape into a blob. A theme that squares its panels draws this sharp, the
/// same way `Design.Radius.pill` stops being a pill under Swiss Minimalist.
final class ThemedWarningMark: NSView, ThemedComponent {

    // MARK: - Types

    /// Which status role the mark is filled with. Two rather than one because the fill is the
    /// only thing separating "this went wrong" from "this needs a look", and a caller that had
    /// to reach for `Design.Status` itself would be choosing a colour rather than a meaning.
    enum Severity {
        /// Something is stopped or failed — the red role.
        case negative
        /// Something wants attention but is still running — the warning role.
        case warning

        var fill: NSColor {
            switch self {
            case .negative: return Design.Status.negative
            case .warning: return Design.Status.warning
            }
        }
    }

    // MARK: - Layout

    private enum Layout {
        static let size: CGFloat = 12
        /// The triangle inside that box. Slightly wider than tall, which is what makes an
        /// upward triangle read as level rather than as leaning back.
        static let width: CGFloat = 11
        static let height: CGFloat = 9.5
        /// How much of a side a rounded corner may take. Above about a fifth the three arcs
        /// meet and the triangle stops having edges at all.
        static let cornerFraction: CGFloat = 0.18
    }

    // MARK: - Properties

    var severity: Severity = .negative {
        didSet {
            guard severity != oldValue else { return }
            needsDisplay = true
        }
    }

    /// A ground the host painted over the mark's ordinary surface. The triangle already carries
    /// the warning without colour, so on an emphasized selection it takes the selection's ink
    /// instead of risking a status hue that disappears into the fill.
    var hostGround: InkSource? {
        didSet {
            guard hostGround != oldValue else { return }
            needsDisplay = true
        }
    }

    private var themeRedraw: ThemeRedraw?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeRedraw = ThemeRedraw(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.size, height: Layout.size)
    }

    // MARK: - Accessibility

    /// A mark states what it means or it is decoration. The label is the host's to set — the
    /// same shape can say "stopped at its usage limit" on a row and something else in a
    /// gallery — so only the role and the element flag are answered here.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    // MARK: - Drawing

    /// Drawn rather than laid into a layer: a resolved `CGColor` keeps the palette it was made
    /// under, and this mark can sit on a row for hours across a theme switch.
    override func draw(_ dirtyRect: NSRect) {
        (hostGround?.ink.label ?? severity.fill).setFill()
        Self.trianglePath(in: bounds).fill()
    }

    /// The rounded triangle, centred in `bounds` **by its ink**.
    ///
    /// Corners are tangent arcs rather than a scaled inset outline, so each one keeps the
    /// vertex's own angle — an inset triangle would round the apex and the base corners by
    /// visibly different amounts, since they are not the same angle.
    ///
    /// The ink is what is centred, not the vertices, and the difference is visible: rounding
    /// takes a point off the *apex* while the base corners are cut sideways, so a triangle
    /// centred on its three points draws a point low. Measured against the row it shares —
    /// the attention dots landed 0.25pt under the title's optical centre and this landed
    /// 1.25pt under, on a 28pt row, which reads as a mark that is not on the line.
    ///
    /// `centringInk` also weighs the shape, so the lift a triangle needs over a dot is measured
    /// from this path rather than claimed here. Nothing about the mark states that it is
    /// bottom-heavy; it simply is, and `OpticalCentring` reads it.
    static func trianglePath(in bounds: NSRect) -> NSBezierPath {
        let width = min(Layout.width, bounds.width)
        let height = min(Layout.height, bounds.height)
        let originX = bounds.midX - width / 2
        let originY = bounds.midY - height / 2

        let apex = NSPoint(x: originX + width / 2, y: originY + height)
        let right = NSPoint(x: originX + width, y: originY)
        let left = NSPoint(x: originX, y: originY)

        let radius = min(Design.Radius.control, min(width, height) * Layout.cornerFraction)
        let path = NSBezierPath()

        guard radius > 0 else {
            path.move(to: apex)
            path.line(to: right)
            path.line(to: left)
            path.close()
            return path.centringInk(in: bounds)
        }

        // Started at the midpoint of an edge rather than at a vertex: `appendArc(from:to:)`
        // draws the line *into* its corner, so a path opened on a corner would have that
        // corner's arc drawn last, over a subpath already closed through it.
        path.move(to: NSPoint(x: (apex.x + right.x) / 2, y: (apex.y + right.y) / 2))
        path.appendArc(from: right, to: left, radius: radius)
        path.appendArc(from: left, to: apex, radius: radius)
        path.appendArc(from: apex, to: right, radius: radius)
        path.close()
        return path.centringInk(in: bounds)
    }
}
