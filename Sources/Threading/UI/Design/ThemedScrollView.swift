import AppKit

/// The scroll thumb and track owned by Threading's chrome.
///
/// System remains exactly AppKit's scroller: its drawing methods are handed straight back to
/// `NSScroller`. Authored themes replace only those two drawing parts, which is AppKit's public
/// customization seam and leaves its geometry, hit testing, dragging, user-selected
/// overlay/legacy style, and separate fade animations intact.
///
/// The ink source matters for the terminal. Ordinary scroll views sit on app-owned chrome;
/// SwiftTerm's scroller sits on the terminal palette that also paints the window backdrop. One
/// component takes that difference as data rather than introducing a second scrollbar.
///
/// A scroller that stands alone — outside any `NSScrollView` — additionally owns its own fade;
/// see `isUnmanaged`.
final class ThemedScroller: NSScroller, ThemedComponent, InkSourced {

    let inkSource: InkSource

    private var themeRedraw: ThemeRedraw?
    private let appEvents = AppEventObservations()
    private var hoverTracking: NSTrackingArea?
    private var isHovered = false
    private var hideWork: DispatchWorkItem?

    override class var isCompatibleWithOverlayScrollers: Bool {
        self == ThemedScroller.self
    }

    /// The identity theme owns no scrollbar appearance; AppKit draws both parts.
    var delegatesDrawingToAppKit: Bool {
        AppThemePalette.current.isSystem
    }

    override init(frame frameRect: NSRect) {
        inkSource = .chrome
        super.init(frame: frameRect)
        observeAppearance()
    }

    init(frame frameRect: NSRect, inkSource: InkSource) {
        self.inkSource = inkSource
        super.init(frame: frameRect)
        observeAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func observeAppearance() {
        themeRedraw = ThemeRedraw(self)
        appEvents.observe(WindowBackdropDidChange.self) { [weak self] _ in
            guard self?.inkSource == .backdrop else { return }
            self?.needsDisplay = true
        }
        appEvents.observe(NSScroller.preferredScrollerStyleDidChangeNotification) { [weak self] in
            self?.settleVisibility()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Standing Alone

    /// Whether nothing but this view decides when the scrollbar is on screen.
    ///
    /// A scroll view owns its scrollers: it fades them, and while they are faded it does not
    /// call their drawing parts at all — which is why every scroll surface in the app keeps
    /// AppKit's overlay behaviour for free. SwiftTerm's scroller has no such owner. It is a bare
    /// `NSScroller` the terminal positions, sizes and drives itself, so its `draw(_:)` runs on
    /// every display pass and calls both parts unconditionally.
    ///
    /// AppKit's own parts answer that by painting nothing whatsoever — measured, a standalone
    /// `NSScroller` covers zero pixels in either style, whatever the user's scroll-bar
    /// preference. That is why the terminal had no visible scrollbar at all before this
    /// component drew one, and why the one it drew stayed up forever: unconditional drawing is
    /// correct only for a scroller somebody else is fading.
    private var isUnmanaged: Bool {
        guard let superview else { return false }
        return !(superview is NSScrollView)
    }

    /// The user's own answer to the same question. "Always show scroll bars" asks for a
    /// scrollbar that does not leave, and for a standalone scroller this is the only place that
    /// preference is read.
    private var neverHides: Bool { NSScroller.preferredScrollerStyle == .legacy }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        settleVisibility()
        updateTrackingAreas()
    }

    /// The resting state, taken without animation: nothing has moved to animate from.
    private func settleVisibility() {
        hideWork?.cancel()
        hideWork = nil
        alphaValue = isUnmanaged && !neverHides ? 0 : 1
    }

    /// Brings the scrollbar up and starts the clock that takes it away again.
    private func reveal() {
        guard isUnmanaged, isEnabled else { return }
        setRevealed(true)
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        hideWork = nil
        guard isUnmanaged, !neverHides, !isHovered else { return }
        let work = DispatchWorkItem { [weak self] in self?.setRevealed(false) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Design.Motion.scrollerHold, execute: work)
    }

    /// The animator proxy writes the value through before it animates it, so a caller — or a
    /// test — reads the state it asked for whether or not the fade is running.
    private func setRevealed(_ revealed: Bool) {
        let target: CGFloat = revealed ? 1 : 0
        guard alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = revealed ? Design.Motion.appear : Design.Motion.vanish
            animator().alphaValue = target
        }
    }

    /// Movement of the *position* is the only thing worth showing a scrollbar for.
    ///
    /// Deliberately not `knobProportion`: a terminal pinned to the bottom of a growing buffer
    /// reports the same position — SwiftTerm's `scrollPosition` saturates at 1 — while its thumb
    /// shrinks on every line an agent prints. Revealing on the thumb would hold the scrollbar up
    /// for the whole of a streaming answer, which is the state this was reported in.
    override var doubleValue: Double {
        get { super.doubleValue }
        set {
            let moved = newValue != super.doubleValue
            super.doubleValue = newValue
            if moved { reveal() }
        }
    }

    /// Nothing to scroll, nothing to show — a terminal that just handed its screen to a
    /// full-screen program takes its scrollbar with it rather than leaving one behind.
    override var isEnabled: Bool {
        get { super.isEnabled }
        set {
            super.isEnabled = newValue
            guard !newValue, isUnmanaged, !neverHides else { return }
            hideWork?.cancel()
            hideWork = nil
            setRevealed(false)
        }
    }

    /// Reaching for the scrollbar keeps it, which is what makes a revealed one grabbable. A
    /// managed scroller is left alone: AppKit already tracks its own hover, and expands on it.
    ///
    /// The terminal's scroller is exactly the view `PointerTracking` describes — it is resized
    /// under a stationary pointer on every window resize and every font change — so the hover
    /// flag is re-derived here rather than waiting for a `mouseExited` that will not come.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverIsStale(isHovered) {
            isHovered = false
            scheduleHide()
        }
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
            self.hoverTracking = nil
        }
        guard isUnmanaged else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        reveal()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        scheduleHide()
    }

    override func drawKnob() {
        guard !delegatesDrawingToAppKit else {
            super.drawKnob()
            return
        }

        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        draw(inkSource.ink.secondary, in: knob)
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard !delegatesDrawingToAppKit else {
            super.drawKnobSlot(in: slotRect, highlight: flag)
            return
        }

        let ink = inkSource.ink
        draw(flag ? ink.surfaceHover : ink.surface, in: slotRect)
    }

    private func draw(_ color: NSColor, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        color.setFill()
        let shortSide = min(rect.width, rect.height)
        let radius = Design.Radius.pill(height: shortSide)
        NSBezierPath(
            roundedRect: rect,
            xRadius: radius,
            yRadius: radius
        ).fill()
    }
}

/// A clip view whose default is the only background a themed scroll surface wants: none.
///
/// Kept separate because conversations replace the ordinary clip view with a flipped subclass.
/// Subclassing this preserves the invariant without every call site remembering to turn the
/// AppKit background off after construction.
class ThemedClipView: NSClipView, ThemedComponent {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A scroll view that starts transparent, replacing `NSScrollView`.
///
/// The stock default is the erosion: `drawsBackground` is true, so a scroll view someone
/// forgot to configure paints `controlBackgroundColor` — a *system* surface — behind
/// whatever the themed pane put there. Ten of the app's twelve scroll views were switching
/// it off by hand and two had forgotten, which is exactly the argument for a type: the
/// correct state becomes the starting state, and the two forgotten ones were fixed by the
/// rename alone.
///
/// Scrollers retain AppKit's behavior and presentation policy while `ThemedScroller` replaces
/// their two drawing parts under an authored theme. System delegates those parts straight back
/// to AppKit, so the identity theme remains genuinely native rather than an imitation.
class ThemedScrollView: NSScrollView, ThemedComponent, SystemChromeBoundary {

    enum SurfaceRole {
        /// The long-standing default: the document is visually part of its containing pane.
        case transparent
        /// A theme-authored project-tree work area, if the active theme states one.
        case sidebarNavigator
    }

    var surfaceRole: SurfaceRole = .transparent {
        didSet { applySurfaceRole() }
    }

    /// Hands vertical-dominant gestures to the nearest enclosing scroll view.
    ///
    /// Opt this in for a nested, horizontal-only viewport such as a Markdown code block. AppKit
    /// otherwise sends the whole trackpad gesture to the view beneath the pointer, even when
    /// that view has no vertical range, which makes the surrounding conversation appear stuck.
    /// Horizontal-dominant gestures remain local.
    var forwardsVerticalScrollToAncestor = false

    /// Reports a wheel or trackpad event before it scrolls, momentum included.
    ///
    /// This is how a caller tells the user's hand from its own `setBoundsOrigin`: AppKit
    /// routes only real gestures through here, so no generation counter is needed to keep
    /// programmatic scrolls from being mistaken for the user leaving. Scroller-thumb drags
    /// never pass through `scrollWheel` — watch the live-scroll notifications for those.
    var onUserScroll: (() -> Void)?
    private let appEvents = AppEventObservations()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        contentView = ThemedClipView(frame: contentView.frame)
        verticalScroller = ThemedScroller(frame: .zero)
        horizontalScroller = ThemedScroller(frame: .zero)
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applySurfaceRole()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        if surfaceRole == .sidebarNavigator,
           let well = SidebarAppearance.navigatorWell(for: effectiveAppearance) {
            ThemedSurface.draw(
                bounds,
                fill: well.fill,
                radius: 0,
                bevel: well.bevel
            )
        }
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurfaceRole()
    }

    private func applySurfaceRole() {
        let well = surfaceRole == .sidebarNavigator
            ? SidebarAppearance.navigatorWell(for: effectiveAppearance)
            : nil
        let inset = well?.edgeWidth ?? 0
        let edges = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        contentInsets = edges
        scrollerInsets = edges
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if forwardsVerticalScrollToAncestor,
           abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
           let ancestorScrollView {
            ancestorScrollView.scrollWheel(with: event)
            return
        }

        onUserScroll?()
        super.scrollWheel(with: event)
    }

    private var ancestorScrollView: NSScrollView? {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }

    /// A table with a header makes AppKit insert a second clip view beside `contentView`.
    /// It is framework-owned and cannot be replaced through the public API, but its stock
    /// background is still ours to neutralise.
    override func tile() {
        super.tile()
        for case let clip as NSClipView in subviews where clip !== contentView {
            clip.drawsBackground = false
        }
    }

    func permitsSystemChrome(_ view: NSView) -> Bool {
        // macOS 26 inserts visual-effect views into overlay-scrolling chrome. Depending on
        // the scroll view's state, the effect is either direct or nested under private
        // NSScrollPocket/NSHardPocketView wrappers. Permit that AppKit-owned side of the tree
        // while refusing effects in contentView/documentView, where application content lives.
        if view is NSVisualEffectView {
            var ancestor = view.superview
            while let current = ancestor, current !== self {
                if current === contentView || current === documentView {
                    return false
                }
                ancestor = current.superview
            }
            return ancestor === self
        }

        // The only raw clip AppKit may add is the direct, transparent header clip described
        // above. This does not grant permission to a raw clip in the document subtree.
        guard let clip = view as? NSClipView else { return false }
        return clip.superview === self && !clip.drawsBackground
    }
}
