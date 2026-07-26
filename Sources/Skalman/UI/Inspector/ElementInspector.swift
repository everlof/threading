import AppKit

/// The inspect mode: a transparent child window over the main window, capturing in one of
/// two ways. In **element** mode the view under the pointer is detected and outlined, and
/// clicking hands that view back. In **freeflow** mode nothing is detected — crosshair
/// guides follow the pointer, a click hands back the exact point, and a drag hands back the
/// rectangle it drew. Esc backs out of either.
///
/// A *child window*, not an overlay subview, for three reasons: it sits above everything
/// including the toolbar, it swallows the click so inspecting a button does not press it,
/// and it leaves the window's own layout and hit-testing untouched. It is also what keeps
/// the snapshot clean — the overlay was never in the captured view tree, so the marker is
/// drawn onto the bitmap instead of erased from it.
final class ElementInspector {

    // MARK: - Properties

    /// Called with the picked view, and the layers held while picking it, once the mode has
    /// been dismissed. Element mode.
    var onPick: ((NSView, InspectorLayers) -> Void)?

    /// Called with the picked point, in window coordinates. A freeflow click.
    var onPickPoint: ((NSPoint) -> Void)?

    /// Called with the dragged rectangle, in window coordinates. A freeflow drag.
    var onPickRegion: ((NSRect) -> Void)?

    private(set) var isActive = false
    private(set) var mode: InspectorMode = .element

    private weak var host: NSWindow?
    private var overlay: InspectorOverlayWindow?
    private var observers: [NSObjectProtocol] = []

    /// Where the current press began, and whether it has travelled far enough to be a drag.
    private var dragAnchor: NSPoint?
    private var isDraggingRegion = false

    // MARK: - Public Methods

    /// One entry for both menu items: inactive activates, the same mode again cancels, and
    /// the *other* mode switches in place — so the two commands toggle and convert rather
    /// than stacking.
    func toggle(_ mode: InspectorMode, over window: NSWindow) {
        guard isActive else {
            activate(over: window, mode: mode)
            return
        }

        if self.mode == mode {
            cancel()
        } else {
            switchMode(to: mode)
        }
    }

    func activate(over window: NSWindow, mode: InspectorMode) {
        guard !isActive else { return }

        host = window
        self.mode = mode

        let overlay = InspectorOverlayWindow(host: window)
        overlay.inspectorView.onPointerMoved = { [weak self] point in self?.pointerMoved(to: point) }
        overlay.inspectorView.onMouseDown = { [weak self] point in self?.gestureBegan(at: point) }
        overlay.inspectorView.onMouseDragged = { [weak self] point in self?.gestureMoved(to: point) }
        overlay.inspectorView.onMouseUp = { [weak self] point in self?.gestureEnded(at: point) }
        overlay.inspectorView.onCancel = { [weak self] in self?.cancel() }
        // A modifier changes what is drawn without the pointer moving at all, so the overlay
        // has to answer the key as well as the mouse.
        overlay.inspectorView.onModifiersChanged = { [weak self] in self?.refreshIndicator() }

        window.addChildWindow(overlay, ordered: .above)

        // Key, so the overlay hears Esc — the window class opts in, since borderless windows
        // refuse key status by default. The host stays *main*, so its chrome does not dim in
        // the screenshot about to be taken.
        overlay.makeKey()
        overlay.makeFirstResponder(overlay.inspectorView)

        // A child window follows its parent's moves on its own, but not its resizes.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self, let host = self.host else { return }
            self.overlay?.setFrame(host.frame, display: true)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in self?.cancel() })

        self.overlay = overlay
        isActive = true

        refreshIndicator()
    }

    func cancel() {
        deactivate()
    }

    // MARK: - Private Methods

    private func deactivate() {
        guard isActive else { return }

        observers.forEach(NotificationCenter.default.removeObserver(_:))
        observers = []

        if let overlay {
            host?.removeChildWindow(overlay)
            overlay.orderOut(nil)
        }
        overlay = nil
        isActive = false
        dragAnchor = nil
        isDraggingRegion = false

        host?.makeKey()
    }

    private func switchMode(to mode: InspectorMode) {
        self.mode = mode
        dragAnchor = nil
        isDraggingRegion = false
        refreshIndicator()
    }

    /// Redraws for wherever the pointer already is — activation and a mode switch would
    /// otherwise show nothing until the mouse first moves.
    private func refreshIndicator() {
        guard let overlay else { return }
        pointerMoved(to: overlay.mouseLocationOutsideOfEventStream)
    }

    /// The walk starts at the window's frame view rather than `contentView`, so toolbar items
    /// are inspectable too. With full-size content the two share coordinates anyway.
    private func inspectionRoot() -> NSView? {
        guard let contentView = host?.contentView else { return nil }
        return contentView.superview ?? contentView
    }

    private func target(atWindowPoint point: NSPoint) -> NSView? {
        guard let root = inspectionRoot() else { return nil }
        return ElementHitTest.topmost(in: root, at: root.convert(point, from: nil))
    }

    /// Asked of the keyboard each time rather than tracked: `flagsChanged` says *when* to look,
    /// and AppKit's own record of what is down is the one that cannot fall out of step — a
    /// modifier released while another window was key never reaches this view at all.
    private func heldLayers() -> InspectorLayers {
        InspectorLayers.held(NSEvent.modifierFlags)
    }

    private func pointerMoved(to point: NSPoint) {
        guard let overlay else { return }

        // The overlay's frame matches the host's, so host-window coordinates draw 1:1.
        switch mode {
        case .element:
            guard let target = target(atWindowPoint: point) else {
                overlay.inspectorView.indicator = nil
                return
            }
            overlay.inspectorView.indicator = .element(
                levels: InspectorHierarchy.levels(for: target),
                layers: heldLayers()
            )

        case .freeflow:
            guard overlay.inspectorView.bounds.contains(
                overlay.inspectorView.convert(point, from: nil)
            ) else {
                overlay.inspectorView.indicator = nil
                return
            }
            overlay.inspectorView.indicator = .point(
                point,
                label: InspectorGeometry.describe(point)
            )
        }
    }

    // MARK: - Gesture

    private func gestureBegan(at point: NSPoint) {
        dragAnchor = point
        isDraggingRegion = false
    }

    /// A drag refines rather than commits: element mode keeps tracking whatever is under
    /// the pointer, freeflow rubber-bands the region once the press has travelled far
    /// enough to mean one.
    private func gestureMoved(to point: NSPoint) {
        switch mode {
        case .element:
            pointerMoved(to: point)

        case .freeflow:
            guard let anchor = dragAnchor else { return }

            if !isDraggingRegion {
                let travelled = max(abs(point.x - anchor.x), abs(point.y - anchor.y))
                guard travelled > InspectorDefaults.dragThreshold else { return }
                isDraggingRegion = true
            }

            let rect = InspectorGeometry.rect(from: anchor, to: point)
            overlay?.inspectorView.indicator = .region(
                rect,
                label: InspectorGeometry.describe(rect.size)
            )
        }
    }

    /// Capture happens on release, which is what lets one press mean either a click or a
    /// drag — nothing is committed until the pointer says which it was.
    private func gestureEnded(at point: NSPoint) {
        guard isActive else { return }

        let anchor = dragAnchor
        let dragged = isDraggingRegion
        dragAnchor = nil
        isDraggingRegion = false

        switch mode {
        case .element:
            let picked = target(atWindowPoint: point)
            // Read before the mode goes away: the report has to say what the screenshot shows,
            // and the screenshot shows whatever was held at the moment of the click.
            let layers = heldLayers()
            deactivate()
            if let picked {
                onPick?(picked, layers)
            }

        case .freeflow:
            guard let bounds = overlay?.inspectorView.bounds else { return }

            if dragged, let anchor {
                // Clamped to the window: the screenshot cannot show what a drag past the
                // edge asked for, and a region half off-frame is a wrong answer.
                let rect = InspectorGeometry.rect(from: anchor, to: point).intersection(bounds)
                deactivate()
                onPickRegion?(rect)
            } else {
                deactivate()
                onPickPoint?(point)
            }
        }
    }
}

// MARK: - Overlay Window

/// Borderless, transparent, and able to become key — a stock borderless window refuses key
/// status, which would leave Esc with nowhere to land.
final class InspectorOverlayWindow: NSWindow {

    let inspectorView = InspectorOverlayView()

    init(host: NSWindow) {
        super.init(
            contentRect: host.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = inspectorView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Indicator

/// What the overlay shows and the snapshot keeps, in window coordinates throughout.
///
/// An element carries its whole chain rather than one rectangle, because the modifiers decide
/// how much of it is drawn and they are free to change between one pointer move and the next —
/// re-walking the view tree on every key press would answer a question already answered.
enum InspectorIndicator {
    case element(levels: [InspectorLevel], layers: InspectorLayers)
    case point(NSPoint, label: String)
    case region(NSRect, label: String)

    static func element(for view: NSView, layers: InspectorLayers) -> InspectorIndicator {
        .element(levels: InspectorHierarchy.levels(for: view), layers: layers)
    }
}

// MARK: - Overlay View

/// Draws the indicator and reports the pointer; every decision lives in `ElementInspector`.
final class InspectorOverlayView: NSView {

    var onPointerMoved: ((NSPoint) -> Void)?
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseDragged: ((NSPoint) -> Void)?
    var onMouseUp: ((NSPoint) -> Void)?
    var onCancel: (() -> Void)?
    var onModifiersChanged: (() -> Void)?

    var indicator: InspectorIndicator? {
        didSet { needsDisplay = true }
    }

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerMoved?(event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        indicator = nil
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(event.locationInWindow)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == InspectorDefaults.escapeKeyCode {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Reaches this view because the overlay is key, which is the same thing that lets Esc
    /// land here — one reason, two behaviours.
    override func flagsChanged(with event: NSEvent) {
        onModifiersChanged?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let indicator else { return }
        InspectorIndicatorDrawing.draw(indicator, within: bounds)
    }
}

// MARK: - Indicator Drawing

/// One drawing for both surfaces the indicator appears on: the live overlay while hovering,
/// and the captured bitmap the report keeps.
enum InspectorIndicatorDrawing {

    static func draw(_ indicator: InspectorIndicator, within bounds: NSRect) {
        switch indicator {
        case .element(let levels, let layers):
            // The unlayered case is the outlined rectangle it always was; the layers are
            // additions on top of it rather than a second way of drawing a pick.
            InspectorHierarchyDrawing.draw(levels: levels, layers: layers, within: bounds)
        case .region(let rect, let label):
            // One visual for an element and a drawn region: an outlined rectangle is an
            // outlined rectangle, whether a view was found under it or the pointer drew it.
            drawOutlined(rect, label: label, within: bounds)
        case .point(let point, let label):
            drawPoint(point, label: label, within: bounds)
        }
    }

    // MARK: - Outlined Rectangle

    private static func drawOutlined(_ rect: NSRect, label: String, within bounds: NSRect) {
        let accent = resolvedAccent()

        accent.withAlphaComponent(accent.alphaComponent * InspectorDefaults.fillAlpha).setFill()
        rect.fill(using: .sourceOver)

        accent.setStroke()
        let inset = InspectorDefaults.strokeWidth / 2
        let outline = NSBezierPath(rect: rect.insetBy(dx: inset, dy: inset))
        outline.lineWidth = InspectorDefaults.strokeWidth
        outline.stroke()

        drawBadge(label, above: rect, within: bounds)
    }

    // MARK: - Point

    /// Guides spanning the whole window, a ring at the pointer, and the coordinates. The
    /// guides are what say "freeflow": nothing is being detected, the mark is exactly where
    /// the pointer is.
    private static func drawPoint(_ point: NSPoint, label: String, within bounds: NSRect) {
        let accent = resolvedAccent()

        accent.withAlphaComponent(accent.alphaComponent * InspectorDefaults.guideAlpha).setStroke()
        let guides = NSBezierPath()
        guides.move(to: NSPoint(x: point.x, y: bounds.minY))
        guides.line(to: NSPoint(x: point.x, y: bounds.maxY))
        guides.move(to: NSPoint(x: bounds.minX, y: point.y))
        guides.line(to: NSPoint(x: bounds.maxX, y: point.y))
        guides.lineWidth = InspectorDefaults.guideWidth
        guides.stroke()

        accent.setStroke()
        let radius = InspectorDefaults.markerRadius
        let ring = NSBezierPath(ovalIn: NSRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        ring.lineWidth = InspectorDefaults.strokeWidth
        ring.stroke()

        let anchor = NSRect(
            origin: NSPoint(x: point.x + Design.Spacing.medium, y: point.y),
            size: .zero
        )
        drawBadge(label, above: anchor, within: bounds)
    }

    // MARK: - Shared

    /// Both live in `InspectorDrawing`, which is where the layered overlay reaches them too —
    /// a badge drawn two ways is two badges.
    private static func resolvedAccent() -> NSColor {
        InspectorDrawing.resolvedAccent()
    }

    private static func drawBadge(_ label: String, above rect: NSRect, within bounds: NSRect) {
        InspectorDrawing.badge(label, above: rect, within: bounds)
    }
}
