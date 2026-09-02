import AppKit

// MARK: - Placeholder state

/// What a chart with nothing to plot is actually saying.
///
/// The two states look nothing alike on purpose. "Nothing was measured" is a finished answer and
/// the chart should stand still under it; "the sources are being read" is a promise, and a chart
/// that keeps a bare frame while it waits reads as the pane having failed to draw rather than as
/// the app working — the bug `DiffSkeletonView` exists for, one subsystem over.
public enum ThemedChartPlaceholder: Equatable, Sendable {

    /// Nothing was measured, and nothing is on its way.
    case empty

    /// A source is being read. `progress` is how much of it is done once the total is known, and
    /// `nil` while the work is still being counted.
    case loading(progress: Double?)

    public var isLoading: Bool {
        switch self {
        case .empty: return false
        case .loading: return true
        }
    }
}

// MARK: - Placeholder view

/// The block a chart shows instead of series: a ghost of the shape that is coming, what is being
/// read, and how far along it is.
///
/// It lives over the plot rectangle rather than over the whole control, so the message sits
/// between the axes where the marks would be, and the chart's own frame, grid and legend stay
/// where a reader already found them.
///
/// **The status is text, not drawing.** A centred string painted in `draw(_:)` cannot be reached
/// by VoiceOver, cannot truncate against a narrow pane, and cannot carry a determinate bar beside
/// it. Real labels and a real `ThemedProgressBar` give all three, and the bar answers each
/// material's own progress anatomy for free.
public final class ThemedChartPlaceholderView: NSView, ThemedComponent {

    // MARK: - Layout

    private enum Layout {
        /// Wide enough for a source name and a count on one line, narrow enough that the block
        /// stays a centred paragraph rather than a banner across a wide dashboard.
        static let messageWidth: CGFloat = 260
        static let progressWidth: CGFloat = 132
        /// The message block is lifted off the value axis so it sits in the plot's optical middle
        /// rather than on the middle grid rule, which struck the text through.
        static let messageRise: CGFloat = 8
    }

    // MARK: - Properties

    private let band = ChartPlaceholderBandView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(wrappingLabelWithString: "")
    private let progressBar = ThemedProgressBar()
    private let message = NSStackView()
    private let appEvents = AppEventObservations()
    private var themeRedraw: ThemeRedraw?

    public private(set) var placeholder: ThemedChartPlaceholder = .empty

    /// A seam for tests, which cannot watch a compositor.
    public var isBreathing: Bool { band.isPulsing }
    public var progressBarForTesting: ThemedProgressBar? { progressBar }
    public var bandForTesting: NSView { band }

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Positioned by frame, from the chart's own plot rectangle, which moves with the model
        // (a legend takes a band off the top, a ranking widens the leading gutter). Its children
        // are laid out normally inside those bounds. Left to Auto Layout with nothing pinning it
        // to the chart, this collapsed to an empty rectangle: the ghost drew nothing and the
        // message landed in a corner.
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
        wantsLayer = true
        themeRedraw = ThemeRedraw(self)

        titleField.applyFont(.emphasizedBody)
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        detailField.applyFont(.detail())
        detailField.alignment = .center
        detailField.lineBreakMode = .byTruncatingTail
        detailField.maximumNumberOfLines = 2

        message.orientation = .vertical
        message.alignment = .centerX
        message.spacing = Design.Spacing.small
        message.translatesAutoresizingMaskIntoConstraints = false
        message.addArrangedSubview(titleField)
        message.addArrangedSubview(detailField)
        message.addArrangedSubview(progressBar)

        band.translatesAutoresizingMaskIntoConstraints = false
        addSubview(band)
        addSubview(message)
        // A preferred width the block keeps in a wide dashboard, and hard non-negative ceilings
        // that let a chart shrink all the way through its temporary zero-width construction
        // pass. Encoding the inset as a negative constant on the only required ceiling made
        // `width == 0` demand `message.width <= -20`, which no layout can satisfy. The inset is a
        // preference; staying inside the component is the invariant.
        let preferredWidth = message.widthAnchor.constraint(equalToConstant: Layout.messageWidth)
        preferredWidth.priority = NSLayoutConstraint.Priority(749)
        preferredWidth.identifier = "chartPlaceholder.preferredMessageWidth"
        let insetWidth = message.widthAnchor.constraint(
            lessThanOrEqualTo: widthAnchor,
            constant: -Design.Spacing.medium * 2
        )
        insetWidth.priority = .defaultHigh
        insetWidth.identifier = "chartPlaceholder.preferredInsetWidth"
        let hardWidthCeiling = message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)
        hardWidthCeiling.identifier = "chartPlaceholder.hardWidthCeiling"
        let preferredProgressWidth = progressBar.widthAnchor.constraint(
            equalToConstant: Layout.progressWidth
        )
        preferredProgressWidth.priority = NSLayoutConstraint.Priority(749)
        preferredProgressWidth.identifier = "chartPlaceholder.preferredProgressWidth"
        let progressHardCeiling = progressBar.widthAnchor.constraint(
            lessThanOrEqualTo: message.widthAnchor
        )
        progressHardCeiling.identifier = "chartPlaceholder.progressHardCeiling"
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: leadingAnchor),
            band.trailingAnchor.constraint(equalTo: trailingAnchor),
            band.topAnchor.constraint(equalTo: topAnchor),
            band.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Layout.messageRise),
            preferredWidth,
            insetWidth,
            hardWidthCeiling,
            titleField.widthAnchor.constraint(equalTo: message.widthAnchor),
            detailField.widthAnchor.constraint(equalTo: message.widthAnchor),
            preferredProgressWidth,
            progressHardCeiling
        ])

        applyInk()
        // The labels take their ink here rather than at draw time, so a live theme switch has to
        // reach them explicitly — the same two halves `PaneNoticeView` keeps in step.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyInk() }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.applyInk()
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    public func show(_ placeholder: ThemedChartPlaceholder, title: String, detail: String?) {
        self.placeholder = placeholder
        titleField.stringValue = title
        detailField.stringValue = detail ?? ""
        detailField.isHidden = (detail ?? "").isEmpty
        band.mode = placeholder.isLoading ? .ghost : .baseline

        switch placeholder {
        case .loading(let progress?):
            progressBar.isHidden = false
            progressBar.progress = min(max(progress, 0), 1)
        case .loading(nil), .empty:
            // An indeterminate scan has a breathing ghost to say it is working. A bar pinned at
            // zero for the length of it would be a worse answer than no bar at all.
            progressBar.isHidden = true
            progressBar.progress = 0
        }
        progressBar.setAccessibilityLabel(title)
    }

    // MARK: - Private Methods

    private func applyInk() {
        titleField.textColor = Design.Text.secondary
        detailField.textColor = Design.Text.tertiary
        needsDisplay = true
    }

    /// The chart underneath keeps its hover, selection and tooltip behaviour: this block is a
    /// status, not a target.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Ghost band

/// The silhouette behind the message: either the shape of the chart that is coming, or the flat
/// baseline of the one that measured nothing.
///
/// The pulse is a layer-opacity animation for `DiffSkeletonView`'s reason — a redraw timer would
/// be main-thread work for the whole length of a scan — and it belongs to this view alone so the
/// status text above it never breathes with it. Reduce Motion removes the movement and keeps the
/// silhouette, which is the part carrying the meaning.
private final class ChartPlaceholderBandView: NSView, ThemedComponent {

    enum Mode {
        /// Work is in flight: a ghost of a stacked chart's own shape.
        case ghost
        /// Nothing was measured: a dotted rule along zero, which is the true value.
        case baseline
    }

    private enum Layout {
        /// Deliberately fixed rather than generated, so a render test compares two pictures of
        /// the same ghost. The two runs stand in for the stacked bands the Usage chart draws.
        static let front: [CGFloat] = [0.20, 0.30, 0.17, 0.34, 0.25, 0.41, 0.29, 0.36, 0.19, 0.28, 0.38, 0.24]
        static let behind: [CGFloat] = [0.44, 0.57, 0.36, 0.63, 0.49, 0.72, 0.56, 0.67, 0.42, 0.55, 0.70, 0.48]
        static let baselineDash: [CGFloat] = [2, 4]
        static let baselineInset: CGFloat = 1
    }

    private static let pulseKey = "chart-placeholder-pulse"

    private let appEvents = AppEventObservations()
    private var themeRedraw: ThemeRedraw?

    var mode: Mode = .ghost {
        didSet {
            guard mode != oldValue else { return }
            needsDisplay = true
            applyPulse()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        themeRedraw = ThemeRedraw(self)
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.applyPulse()
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Pulse

    var isPulsing: Bool { layer?.animation(forKey: Self.pulseKey) != nil }

    /// An animation belongs to the layer tree, which drops it whenever the view leaves a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPulse()
    }

    private func applyPulse() {
        guard mode == .ghost, window != nil, !Design.Motion.reducesMotion else {
            layer?.removeAnimation(forKey: Self.pulseKey)
            return
        }
        guard layer?.animation(forKey: Self.pulseKey) == nil else { return }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = Design.Motion.skeletonPulseFloor
        pulse.duration = Design.Motion.skeletonPulsePeriod
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        layer?.add(pulse, forKey: Self.pulseKey)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        switch mode {
        case .ghost:
            fill(Layout.behind, opacity: Design.Opacity.skeletonChartBandBehind)
            fill(Layout.front, opacity: Design.Opacity.skeletonChartBand)
        case .baseline:
            drawBaseline()
        }
    }

    private func fill(_ values: [CGFloat], opacity: CGFloat) {
        guard values.count > 1 else { return }
        let step = bounds.width / CGFloat(values.count - 1)
        let points = values.enumerated().map { index, value in
            NSPoint(x: bounds.minX + CGFloat(index) * step, y: bounds.minY + value * bounds.height)
        }

        // Midpoint quadratics: each sample becomes a *control* point and the curve runs from one
        // midpoint to the next, so the outline has no corners at all. A decorative silhouette
        // wants a soft edge rather than the measured monotone curve the real series are held to,
        // and the first attempt — corners at the samples themselves — drew a jagged mountain
        // range that looked like a series somebody had plotted.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: points[0].x, y: bounds.minY))
        path.line(to: points[0])
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let next = points[index + 1]
            let end = NSPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
            appendQuadratic(to: end, control: control, in: path)
        }
        appendQuadratic(
            to: points[points.count - 1],
            control: points[points.count - 1],
            in: path
        )
        path.line(to: NSPoint(x: points[points.count - 1].x, y: bounds.minY))
        path.close()
        ink.withAlphaComponent(opacity).setFill()
        path.fill()
    }

    /// `NSBezierPath` grew a quadratic segment in macOS 14; the app targets 13, so the equivalent
    /// cubic is written out here rather than branching on the OS for a decorative curve.
    private func appendQuadratic(to end: NSPoint, control: NSPoint, in path: NSBezierPath) {
        let start = path.currentPoint
        let first = NSPoint(
            x: start.x + 2.0 / 3.0 * (control.x - start.x),
            y: start.y + 2.0 / 3.0 * (control.y - start.y)
        )
        let second = NSPoint(
            x: end.x + 2.0 / 3.0 * (control.x - end.x),
            y: end.y + 2.0 / 3.0 * (control.y - end.y)
        )
        path.curve(to: end, controlPoint1: first, controlPoint2: second)
    }

    private func drawBaseline() {
        let path = NSBezierPath()
        let y = bounds.minY + Layout.baselineInset
        path.move(to: NSPoint(x: bounds.minX, y: y))
        path.line(to: NSPoint(x: bounds.maxX, y: y))
        path.lineWidth = Design.Radius.border
        path.setLineDash(Layout.baselineDash, count: Layout.baselineDash.count, phase: 0)
        ink.setStroke()
        path.stroke()
    }

    /// The ghost follows the chart's own material: a spectrum analyzer's well has no neutral grey
    /// in it, so the silhouette is drawn in the accent it already glows with.
    private var ink: NSColor {
        Design.Chart.style == .spectrum ? Design.Surface.accent : Design.Text.quaternary
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
