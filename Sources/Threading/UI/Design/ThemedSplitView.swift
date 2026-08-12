import AppKit

/// The window's split view, with a divider that can actually be seen.
///
/// AppKit draws a divider in a chrome colour, and this window's panes do not sit on the chrome's
/// ground: a terminal pane paints the *window* with the terminal palette's background (see
/// `WindowBackdrop`), so the stock hairline is measured against one ground and drawn on another.
/// On a near-black terminal the seam between the sidebar and the session simply was not there,
/// and the panes read as one undivided surface.
///
/// `dividerColor` is the whole of the seam AppKit offers here. The rule is: **the theme's own
/// line wherever it visibly reads on the backdrop; the measured neutral only where it does
/// not.** The theme's rule is *measured* against the actual backdrop first, including when the
/// theme owns that ground: System light deliberately makes an ordinary divider quieter than a
/// border, but that five-percent hairline disappears as the only seam beside the sidebar. A rule
/// that already reads keeps its theme's hue; one the chrome swallows steps up to the theme's own
/// border, while one an unrelated terminal palette swallows gets neutral ink measured from that
/// ground. The backdrop moves when the selected session changes as well as when the theme does —
/// both are observed, because a divider that keeps the previous session's ink is the bug this
/// exists to fix, one palette later.
///
/// The seam also answers the pointer: wherever a press would begin dragging it, it takes the
/// accent — see `drawDivider(in:)` for why that zone is asked of `hitTest` rather than restated.
final class ThemedSplitView: NSSplitView {

    /// Called when a divider drag ends, with the divider's index and where the pointer was let
    /// go, in this view's coordinates.
    ///
    /// A pane stops dead at its floor while the pointer keeps travelling, and the distance
    /// between the two is the only record of how hard the divider was pushed — the frames say
    /// nothing, because nothing moved. The owner decides what a push that far means; this view
    /// only knows that a drag ended and where the hand was.
    var dividerDragDidEnd: ((_ dividerIndex: Int, _ pointerX: CGFloat) -> Void)?

    private let appEvents = AppEventObservations()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // `NSSplitViewController` configures the split view it makes for itself, and handing it
        // one instead inherits `NSSplitView`'s own defaults rather than the controller's. Two of
        // those matter and neither is announced: `isVertical` defaults to **false**, which stacks
        // the panes — the sidebar arrived as a band across the top of the window — and
        // `dividerStyle` defaults to `.thick`. Stated here so replacing the split view is a
        // change of ink and nothing else; a caller wanting a horizontal split still says so.
        isVertical = true
        dividerStyle = .thin

        // A divider move re-places the panes without moving this view's own frame, and that is
        // the one geometry change AppKit does not re-ask tracking areas for — measured,
        // `setPosition` moves the pane frames and posts this notification synchronously while
        // `layout()` waits for the next turn. Left alone, the hover strips would keep hinting
        // at the seam's old position after the first drag. Selector-based on purpose: an
        // observation of self by self needs no token juggling to outlive safely.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitSubviewsDidResize),
            name: NSSplitView.didResizeSubviewsNotification,
            object: self
        )

        observeInk()
    }

    @objc private func splitSubviewsDidResize(_ notification: Notification) {
        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Appearance

    /// The faintest a hairline may sit above its ground and still register as a line. Well
    /// below text legibility on purpose: a seam is found by the eye sweeping across it, not
    /// read — the System theme's own dark hairline sits at ~1.35:1.
    private static let visibleLineRatio: CGFloat = 1.2

    /// The seam is also the drag handle, so it stays grabbable however fine a theme rules.
    private static let minimumGrab: CGFloat = 1

    /// The seam weighs what every other rule in the window weighs.
    ///
    /// `dividerStyle = .thin` is a *fixed* point, while every other rule here — the pane
    /// headers' and footers' `SeparatorView`s, the shell drawer's grab strip, a table's column
    /// rules — is `Design.Radius.border` thick, because how heavily a style rules is part of its
    /// identity in the same way its palette is. A theme that rules at 2 (Bauhaus) or 3
    /// (Neo Brutalism) therefore drew heavy horizontal rules meeting a one-point vertical seam
    /// between the very same two panes, and the sidebar's header rule visibly stepped down where
    /// it crossed the split. Two weights for one decision, and the theme only ever stated one.
    override var dividerThickness: CGFloat { max(Self.minimumGrab, Design.Radius.border) }

    /// The theme's own line wherever it reads on the backdrop; measured ink where it cannot.
    ///
    /// The theme's *rule* ink, not its border: the seam is a rule between panes, and the pane
    /// headers' `SeparatorView`s it meets draw `Design.Surface.divider` — which is also where
    /// the rule-ink budget is enforced. Drawn in `Surface.border` it was the one full-strength
    /// rule left in a window whose every other rule had been held back, stepping in *ink* at
    /// exactly the crossing where it once stepped in weight.
    override var dividerColor: NSColor {
        let rule = Design.Surface.divider
        let backdrop = WindowBackdrop.color
        let drawn = backdrop.composited(under: rule)
        return ThemeContrast.ratio(drawn, backdrop) >= Self.visibleLineRatio
            ? rule
            : (WindowBackdrop.isChromeGround ? Design.Surface.border : WindowBackdrop.ink.rule)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - The Seam Under the Pointer

    /// The divider a press right now would attach to — under the pointer, or under the hand for
    /// the whole of a drag — or `nil` at rest.
    private var activeDividerIndex: Int? {
        didSet {
            guard oldValue != activeDividerIndex else { return }
            if let oldValue { setNeedsDisplay(dividerRect(at: oldValue)) }
            if let activeDividerIndex { setNeedsDisplay(dividerRect(at: activeDividerIndex)) }
        }
    }

    /// Held across `super.mouseDown`'s tracking loop. A drag overshoots a pane's floor with the
    /// divider stopped dead under the highlight, and the exit that overshoot generates must not
    /// put the seam out while the hand is still on it.
    private var isDraggingDivider = false

    private var dividerHoverAreas: [NSTrackingArea] = []

    /// The lit seam: the accent wherever it reads on the backdrop, because under the pointer the
    /// divider is the one control ready to act — which is what the accent already means
    /// everywhere else. The same visibility floor as `dividerColor`, with the strongest measured
    /// neutral standing in where a backdrop swallows the accent, or a hint would vanish exactly
    /// like the seam it is meant to point out.
    private var activeDividerColor: NSColor {
        let accent = Design.Surface.accent
        let backdrop = WindowBackdrop.color
        let drawn = backdrop.composited(under: accent)
        return ThemeContrast.ratio(drawn, backdrop) >= Self.visibleLineRatio
            ? accent
            : WindowBackdrop.ink.label
    }

    /// The seam, lit while a drag would attach to it.
    ///
    /// The resize cursor already says "this point grabs the divider", and this is that answer
    /// made visible on the seam itself — an extra hint in the ink, for a divider that is
    /// otherwise the quietest line in the window.
    override func drawDivider(in rect: NSRect) {
        if let index = activeDividerIndex, dividerRect(at: index).intersects(rect) {
            activeDividerColor.setFill()
            rect.fill()
        } else {
            super.drawDivider(in: rect)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in dividerHoverAreas { removeTrackingArea(area) }
        dividerHoverAreas = arrangedSubviews.dropLast().indices.compactMap { index in
            guard dividerIsGrabbable(at: index) else { return nil }
            let area = NSTrackingArea(
                rect: dividerRect(at: index).insetBy(dx: -Self.dividerGrab, dy: 0),
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                owner: self
            )
            addTrackingArea(area)
            return area
        }

        // The divider moves out from under a stationary pointer whenever a pane is dragged,
        // collapsed or re-laid out — see `NSView.hoverIsStale`. Corrected only in the leaving
        // direction, and never mid-drag: the divider under the hand *is* where the pointer left.
        if !isDraggingDivider, let index = activeDividerIndex {
            let pointer = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            if pointer.flatMap(attachedDividerIndex(at:)) != index {
                activeDividerIndex = nil
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        refreshActiveDivider(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        refreshActiveDivider(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        refreshActiveDivider(with: event)
    }

    /// The tracking areas only say the pointer is *near* a seam; where the highlight actually
    /// lights is `attachedDividerIndex(at:)`'s answer, re-asked on every crossing and movement
    /// inside the strip so the hint and the grab agree at the edges.
    private func refreshActiveDivider(with event: NSEvent) {
        guard !isDraggingDivider else { return }
        activeDividerIndex = attachedDividerIndex(at: convert(event.locationInWindow, from: nil))
    }

    /// The divider a click at `point` would begin dragging, answered the way the platform
    /// answers it.
    ///
    /// `NSSplitView` claims the points around a divider from its own panes in `hitTest` — for a
    /// hairline, measured at two points to either side — and that claim is what turns a press
    /// into a drag and flips the cursor. Asking it keeps the hint honest by construction: a
    /// zone restated here as a constant would drift the day AppKit widens its own.
    private func attachedDividerIndex(at point: NSPoint) -> Int? {
        let inSuperview = superview.map { convert(point, to: $0) } ?? point
        guard hitTest(inSuperview) === self else { return nil }
        return dividerIndex(at: point)
    }

    /// A divider beside a collapsed pane is hidden (`splitView(_:shouldHideDividerAt:)` in
    /// `SidebarSplitViewController`), and a seam that is not there must not light up: neither
    /// pane at this window's edges is reopened by dragging.
    private func dividerIsGrabbable(at index: Int) -> Bool {
        let leading = arrangedSubviews[index]
        let trailing = arrangedSubviews[index + 1]
        return !leading.isHidden && !leading.frame.isEmpty
            && !trailing.isHidden && !trailing.frame.isEmpty
    }

    private func dividerRect(at index: Int) -> NSRect {
        guard arrangedSubviews.indices.contains(index + 1) else { return .zero }
        return NSRect(
            x: arrangedSubviews[index].frame.maxX,
            y: 0,
            width: dividerThickness,
            height: bounds.height
        )
    }

    // MARK: - Dragging

    /// How far either side of the seam still counts as grabbing it. The drawn divider is a
    /// hairline, and AppKit widens its own hit area for exactly this reason; the answer only
    /// has to be as good as "which divider", since `super` decides whether a drag begins.
    private static let dividerGrab = Design.Spacing.small

    /// Reports where a divider drag ended, without taking the drag over.
    ///
    /// `super.mouseDown` does not return until the tracking loop has pulled its own mouse-up —
    /// there are no gesture recognizers on this view, checked at runtime — so everything AppKit
    /// does with a divider still happens, and the release is read once it has finished.
    ///
    /// The release point is read first from the **event that ended the loop**, which `nextEvent`
    /// leaves as the application's current one, and only then from the pointer itself. The two
    /// agree in the app, and only the first can be driven from a test, where the physical mouse
    /// is wherever the developer left it — while only the second survives a loop that ends on
    /// something other than a mouse-up.
    override func mouseDown(with event: NSEvent) {
        let pressed = convert(event.locationInWindow, from: nil)
        let index = dividerIndex(at: pressed)

        // Lit for the whole tracking loop `super` is about to run: the press is the moment the
        // hint's promise — dragging here attaches — is kept, not the moment it should go out.
        // Only for a press the platform would attach, though; an unhandled click *near* the seam
        // bubbles up here too, and lighting the divider for it would promise a drag that never
        // began.
        if let attached = attachedDividerIndex(at: pressed) {
            isDraggingDivider = true
            activeDividerIndex = attached
        }

        super.mouseDown(with: event)
        isDraggingDivider = false
        guard let index else { return }

        if let release = NSApp.currentEvent, release.type == .leftMouseUp {
            let released = convert(release.locationInWindow, from: nil)
            dividerDragDidEnd?(index, released.x)
            activeDividerIndex = attachedDividerIndex(at: released)
        } else if let window {
            let pointer = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let released = convert(pointer, from: nil)
            dividerDragDidEnd?(index, released.x)
            activeDividerIndex = attachedDividerIndex(at: released)
        }
    }

    private func dividerIndex(at point: NSPoint) -> Int? {
        arrangedSubviews.dropLast().indices.first { index in
            guard dividerIsGrabbable(at: index) else { return false }
            let seam = arrangedSubviews[index].frame.maxX
            return point.x >= seam - Self.dividerGrab
                && point.x <= seam + dividerThickness + Self.dividerGrab
        }
    }

    // MARK: - Private Methods

    private func observeInk() {
        appEvents.observe(WindowBackdropDidChange.self) { [weak self] _ in
            self?.needsDisplay = true
        }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.reweigh()
        }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.reweigh()
        }
    }

    /// A theme change moves the seam's *weight* as well as its ink, and the panes are placed
    /// against that weight: the split view reads `dividerThickness` while it builds the
    /// constraints between its arranged subviews and does not ask again on its own. Repainting
    /// alone left the panes spaced for the outgoing theme until the window was next resized.
    private func reweigh() {
        needsUpdateConstraints = true
        needsLayout = true
        needsDisplay = true
    }
}
