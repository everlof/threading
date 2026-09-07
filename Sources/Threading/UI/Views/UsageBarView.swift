import AppKit

// MARK: - Usage Bar View

/// A flat horizontal gauge: quiet full-width track, tinted fill for the spent fraction.
///
/// The fill can **travel** to a new value rather than appearing at it (`apply(…animated:)`),
/// because the composer asks this bar the same question about a second account the moment the
/// user switches: two readings of the same window, and a fill that jumped between them said
/// nothing about which way it moved. Assigning `fraction`, `tint` or `timeMark` directly still
/// lands immediately — the toolbar popover builds a row per reading and has nothing to travel
/// from.
final class UsageBarView: NSView {

    // MARK: - Motion

    /// The travel curve, as a pure function so the feel is testable without a clock.
    enum Motion {

        /// Eased out, with **no** overshoot — unlike `ThemedToggle`, whose settle past the end
        /// is what gives its knob weight. A gauge may not draw a value it does not have: a bar
        /// sailing past 90% and easing back would have reported a level the account never
        /// reached, on the one surface whose whole job is to say how much is left.
        static func travel(at phase: Double) -> Double {
            let remaining = 1 - min(max(phase, 0), 1)
            return 1 - remaining * remaining * remaining
        }
    }

    // MARK: - Properties

    /// The value asked for. Assigning it lands immediately; `apply(…animated:)` may ease the
    /// drawn value to it instead.
    var fraction: Double = 0 { didSet { landUnlessApplying() } }
    var tint: NSColor = Design.Surface.accent { didSet { landUnlessApplying() } }

    /// The linear time position within the window, 0…1, drawn as a thin vertical mark so the
    /// spent fill can be read against the clock. Nil hides it.
    ///
    /// Never travels: the mark is where the clock stands, and a clock that slid into place
    /// would be claiming a movement that did not happen in the second it took to draw.
    var timeMark: Double? { didSet { landUnlessApplying() } }

    /// The user's own line within the window, 0…1. Nil when no rule of theirs binds this window.
    ///
    /// Drawn as a vertical mark in the custom-limit role. The clock's line stays neutral while
    /// this one has the same colour as the footer legend, so two lines on the same six-point bar
    /// remain identifiable instead of looking like stray ticks.
    ///
    /// The **fill** is untouched by it. A bar's length and the percentage beside it stay the raw
    /// provider fraction, so consumption past the user's line still draws past it — that spend
    /// really happened, and a gauge may not quieten a number the account actually reached.
    ///
    /// Never travels, for `timeMark`'s reason: the line is where the user put it.
    var capMark: Double? { didSet { landUnlessApplying() } }

    /// What is actually drawn — `fraction` while idle, a point along the travel while in
    /// flight. Exposed so a test can read the gauge rather than the request.
    private(set) var displayedFraction: Double = 0

    /// The fill's drawn width, and the custom-limit mark's frame.
    ///
    /// Named rather than left to be reached for by subview *order*, which is how a test came to
    /// report a fill of zero on a bar that was drawing correctly: a second marker was inserted
    /// before the fill, and `subviews.first` quietly became a different view. A gauge that a test
    /// has to index into is a gauge whose tests break on layering.
    var drawnFillWidth: CGFloat { fillView.isHidden ? 0 : fillView.frame.width }
    var drawnCapMarkFrame: NSRect? { capMarkView.isHidden ? nil : capMarkView.frame }
    var drawnTimeMarkFrame: NSRect? { markView.isHidden ? nil : markView.frame }

    /// How far the fill's colour has crossfaded, 0 = `tintFrom` → 1 = `tint`. Held as a phase
    /// rather than a blended colour because a theme colour resolves against an appearance, and
    /// the only place that appearance is known is `layout()`.
    private var tintPhase: Double = 1
    private var tintFrom: NSColor = Design.Surface.accent

    private var animationPhase: Double = 1
    private var animationFrom: Double = 0
    private var animationStart: CFTimeInterval = 0
    private var animationDuration: TimeInterval = 0

    /// Set while `apply` is writing the requested values, so the property observers do not read
    /// its own assignments as a caller asking for an instant landing and cancel the travel.
    private var isApplying = false

    /// The frame source while the fill is in flight — a display link on 14+, a 60Hz timer on
    /// 13, the `ThemedToggle` pattern. Both retain the view, which is why arrival and window
    /// removal each stop it.
    private var displayLink: Any? // CADisplayLink, stored untyped for macOS 13
    private var fallbackTimer: Timer?

    private let fillView = NSView()
    private let markView = NSView()
    private let capMarkView = NSView()

    /// The colours are resolved in `layout()`, which a theme change does not otherwise trigger —
    /// so the bar would keep the previous theme's accent until something else moved it.
    private var themeRedraw: ThemeRedraw?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        fillView.wantsLayer = true
        markView.wantsLayer = true
        capMarkView.wantsLayer = true
        addSubview(fillView)
        // Above the fill, so the pace line stays visible even where usage has passed it.
        addSubview(markView)
        // Last, because the user-authored boundary must survive both real spend and a coincident
        // clock line. Its semantic colour and the host's legend say what that precedence means.
        addSubview(capMarkView)
        themeRedraw = ThemeRedraw(self)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: usesWorkbenchProgress
                ? ThemedProgressDrawing.workbenchHeight
                : (usesIRIXProgress
                    ? ThemedProgressDrawing.irixHeight
                    : (usesClassicProgress
                        ? ThemedProgressDrawing.classicHeight
                        : UsageBarDefaults.height))
        )
    }

    /// `ThemeRedraw` asks for a redraw; this one needs a re-*layout*, because that is where its
    /// layer colours are set.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Draws a reading, travelling to it when asked and when there is something to travel from.
    ///
    /// One call rather than three assignments, because the fill and its severity colour change
    /// together and two of them animating from separate starts would cross.
    func apply(
        fraction newFraction: Double,
        tint newTint: NSColor,
        timeMark newMark: Double?,
        capMark newCapMark: Double? = nil,
        animated: Bool
    ) {
        let from = displayedFraction
        // The colour actually on screen, which mid-crossfade is the blend rather than either
        // end of it: restarting from `tintFrom` would step the fill back to a colour it had
        // already left.
        let fromTint = fillColor()

        isApplying = true
        fraction = newFraction
        tint = newTint
        timeMark = newMark
        capMark = newCapMark
        isApplying = false

        stopDriver()

        // `Design.Motion.standard` is zero under Reduce Motion, so the guard below is also the
        // accessibility branch — and it lands the value here, synchronously, rather than
        // costing a frame to arrive at what the caller is entitled to have now.
        let duration = Design.Motion.standard
        guard animated, duration > 0, window != nil,
              from != newFraction || fromTint != newTint else {
            land()
            return
        }

        animationFrom = from
        animationDuration = duration
        animationStart = CACurrentMediaTime()
        animationPhase = 0
        tintFrom = fromTint
        tintPhase = 0
        needsLayout = true
        needsDisplay = true
        startDriver()
    }

    /// One frame of travel, split from the tick so tests can drive the clock by hand.
    func advanceAnimation(now: CFTimeInterval) {
        guard animationPhase < 1 else { return }

        let phase = min(1, (now - animationStart) / animationDuration)
        animationPhase = phase

        let eased = Motion.travel(at: phase)
        displayedFraction = animationFrom + (fraction - animationFrom) * eased
        tintPhase = eased

        if phase >= 1 {
            land()
            return
        }

        needsLayout = true
        needsDisplay = true
    }

    // MARK: - Private Methods

    /// Arrival, and the only place the drawn value is allowed to *become* the asked-for one:
    /// a crossfade at phase 1 has already been flattened to one appearance's colour, and `tint`
    /// is a theme colour that still resolves against both.
    private func land() {
        displayedFraction = fraction
        tintPhase = 1
        animationPhase = 1
        stopDriver()
        needsLayout = true
        needsDisplay = true
    }

    /// A direct assignment is a caller with a value and no history — it lands, and takes any
    /// travel in flight with it.
    private func landUnlessApplying() {
        guard !isApplying else { return }
        land()
    }

    private func startDriver() {
        guard displayLink == nil, fallbackTimer == nil else { return }
        if #available(macOS 14.0, *) {
            let link = self.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(tick),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    private func stopDriver() {
        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.invalidate()
        }
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    @objc private func tick() {
        advanceAnimation(now: CACurrentMediaTime())
    }

    /// A driver retains its target, so a bar leaving the window lands its fill and stops rather
    /// than travelling unseen — or, timer-driven, never deallocating.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, animationPhase < 1 {
            land()
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        if usesHistoricalProgress {
            layer?.cornerRadius = 0
            layer?.backgroundColor = nil
            fillView.isHidden = true
        } else {
            layoutContinuousFill()
        }

        layoutCapMark()
        layoutTimeMark()
    }

    override func draw(_ dirtyRect: NSRect) {
        if usesWorkbenchProgress {
            ThemedProgressDrawing.drawWorkbench(
                in: bounds,
                fraction: displayedFraction,
                tint: workbenchProgressBlue
            )
        } else if usesIRIXProgress {
            ThemedProgressDrawing.drawIRIX(
                in: bounds,
                fraction: displayedFraction,
                tint: Design.Surface.accent
            )
        } else if usesClassicProgress {
            ThemedProgressDrawing.drawSegmented(
                in: bounds,
                fraction: displayedFraction,
                tint: fillColor()
            )
        }
    }

    private func layoutContinuousFill() {
        let radius = bounds.height / 2
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius
        applyLayerBackground(Design.Surface.controlResting)

        let width = bounds.width * min(max(displayedFraction, 0), 1)
        fillView.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        fillView.layer?.cornerCurve = .continuous
        fillView.layer?.cornerRadius = radius
        fillView.applyLayerBackground(fillColor())
        fillView.isHidden = width <= 0
    }

    /// The user's line, in one semantic colour over every progress material.
    ///
    /// Unlike the old track fade, the marker is valid on historical progress styles too: it is
    /// a line above their authored trough rather than a translucent surface laid across it.
    private func layoutCapMark() {
        guard let capMark else {
            capMarkView.isHidden = true
            return
        }

        let markWidth = Design.UsageBar.limitMarkWidth
        let markCentre = bounds.width * min(max(capMark, 0), 1)
        capMarkView.frame = NSRect(
            x: min(max(markCentre - markWidth / 2, 0), max(0, bounds.width - markWidth)),
            y: 0,
            width: min(markWidth, bounds.width),
            height: bounds.height
        )
        capMarkView.layer?.cornerCurve = .continuous
        capMarkView.layer?.cornerRadius = markWidth / 2
        capMarkView.applyLayerBackground(Design.UsageBar.limitMarkColor)
        capMarkView.isHidden = bounds.isEmpty
    }

    private func layoutTimeMark() {
        if let timeMark {
            let markWidth = min(Design.UsageBar.outlinedTimeMarkWidth, bounds.width)
            let markCentre = bounds.width * min(max(timeMark, 0), 1)
            let verticalInset: CGFloat = usesHistoricalProgress ? 2 : 0
            markView.frame = NSRect(
                x: min(max(markCentre - markWidth / 2, 0), bounds.width - markWidth),
                y: verticalInset,
                width: markWidth,
                height: max(0, bounds.height - verticalInset * 2)
            )
            markView.layer?.cornerCurve = .continuous
            markView.layer?.cornerRadius = usesHistoricalProgress ? 0 : markWidth / 2
            markView.applyLayerBackground(Design.UsageBar.timeMarkInk)
            markView.applyLayerBorder(Design.UsageBar.timeMarkOutline)
            markView.layer?.borderWidth = Design.UsageBar.timeMarkOutlineWidth
            markView.isHidden = bounds.isEmpty
        } else {
            markView.isHidden = true
        }
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

    private var usesHistoricalProgress: Bool {
        usesClassicProgress || usesWorkbenchProgress || usesIRIXProgress
    }

    private var workbenchProgressBlue: NSColor {
        WindowChromeAppearance.resolve()?.activeGradient.colors.first
            ?? Design.Surface.accent
    }

    /// The fill's colour for this pass: `tint` itself while idle, a blend along the crossfade
    /// while in flight.
    ///
    /// Blending needs one colour space and a theme colour is dynamic until it is resolved, so
    /// the resolution happens under this view's own appearance rather than whatever was current
    /// when the frame fired. A pair that will not convert crossfades as a straight swap, which
    /// is a colour the caller asked for rather than nothing at all.
    private func fillColor() -> NSColor {
        guard tintPhase < 1 else { return tint }

        var blended = tint
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let start = tintFrom.usingColorSpace(.sRGB),
                  let end = tint.usingColorSpace(.sRGB) else { return }
            blended = start.blended(withFraction: CGFloat(tintPhase), of: end) ?? tint
        }
        return blended
    }
}

// MARK: - Usage Bar Defaults

enum UsageBarDefaults {
    static let height = Design.UsageBar.height
}
