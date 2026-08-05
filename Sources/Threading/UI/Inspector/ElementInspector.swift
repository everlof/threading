import AppKit

/// The inspect mode: a transparent child window over the main window, capturing in one of
/// three ways, chosen by the gesture and by what is held rather than by which command opened
/// it.
///
/// - **A click** hands back the view under the pointer, detected and outlined as you move.
/// - **A drag** hands back the rectangle it draws, whatever is under it. Element mode had no
///   use for a drag — it re-tracked the pointer and committed nothing — so a region costs no
///   modifier at all: dragging *is* what "this area" looks like.
/// - **⇧ held** suppresses detection. Crosshair guides follow the pointer and a click hands
///   back the exact point, which is the one capture a gesture cannot imply on its own.
///
/// Esc backs out. ⌃ and ⌥ layer hierarchy and spacing onto a detected element, and are
/// meaningless under ⇧ because there is no element to layer onto.
///
/// A *child window*, not an overlay subview, for three reasons: it sits above everything
/// including the toolbar, it swallows the click so inspecting a button does not press it,
/// and it leaves the window's own layout and hit-testing untouched. It is also what keeps
/// the snapshot clean — the overlay was never in the captured view tree, so the marker is
/// drawn onto the bitmap instead of erased from it.
@MainActor
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

    /// Asked of the keyboard each time, never stored — the same rule `heldLayers()` follows,
    /// and for the same reason: a modifier released while another window was key never
    /// reaches this view, so a copy of the flags is a copy that can be wrong.
    var mode: InspectorMode { InspectorMode.held(NSEvent.modifierFlags) }

    private weak var host: NSWindow?
    private var overlay: InspectorOverlayWindow?
    private var observers: [NSObjectProtocol] = []

    /// Where the current press began, and whether it has travelled far enough to be a drag.
    private var dragAnchor: NSPoint?
    private var isDraggingRegion = false

    // MARK: - Public Methods

    /// The one command: inactive activates, active cancels. There is no mode to switch to —
    /// the keyboard is asked for that on every frame.
    func toggle(over window: NSWindow) {
        if isActive {
            cancel()
        } else {
            activate(over: window)
        }
    }

    func activate(over window: NSWindow) {
        guard !isActive else { return }

        host = window

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
            Task { @MainActor [weak self] in
                guard let self, let host = self.host else { return }
                self.overlay?.setFrame(host.frame, display: true)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cancel() }
        })

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

    /// Redraws for wherever the pointer already is — activation, and every press or release
    /// of a modifier, would otherwise show nothing until the mouse first moves.
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

    /// A drag refines rather than commits, and it means the same thing in both modes: once the
    /// press has travelled far enough to be a drag it rubber-bands a region, and until then it
    /// keeps tracking whatever the mode would show for a hover.
    ///
    /// **A drag is a region even with nothing held.** Element mode had no other use for one, and
    /// the alternative — a modifier for the one gesture that already looks like "this area" —
    /// buys nothing. The cost is that a click which slips past the threshold captures a small
    /// region instead of the view; the outline stays up until the threshold trips, so the switch
    /// is visible in time to release and try again.
    private func gestureMoved(to point: NSPoint) {
        guard let anchor = dragAnchor else { return }

        if !isDraggingRegion {
            let travelled = max(abs(point.x - anchor.x), abs(point.y - anchor.y))
            guard travelled > InspectorDefaults.dragThreshold else {
                pointerMoved(to: point)
                return
            }
            isDraggingRegion = true
        }

        let rect = InspectorGeometry.rect(from: anchor, to: point)
        overlay?.inspectorView.indicator = .region(
            rect,
            label: InspectorGeometry.describe(rect.size)
        )
    }

    /// Capture happens on release, which is what lets one press mean a click or a drag —
    /// nothing is committed until the pointer says which it was. What is held at that moment
    /// decides the rest, because the report has to describe the screenshot and the screenshot
    /// shows whatever was held when it was taken.
    private func gestureEnded(at point: NSPoint) {
        guard isActive, let bounds = overlay?.inspectorView.bounds else { return }

        let anchor = dragAnchor
        let dragged = isDraggingRegion
        dragAnchor = nil
        isDraggingRegion = false

        if dragged, let anchor {
            // Clamped to the window: the screenshot cannot show what a drag past the edge
            // asked for, and a region half off-frame is a wrong answer.
            let rect = InspectorGeometry.rect(from: anchor, to: point).intersection(bounds)
            deactivate()
            onPickRegion?(rect)
            return
        }

        switch mode {
        case .element:
            let picked = target(atWindowPoint: point)
            let layers = heldLayers()
            deactivate()
            if let picked {
                onPick?(picked, layers)
            }

        case .freeflow:
            deactivate()
            onPickPoint?(point)
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
@MainActor
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
        InspectorIndicatorDrawing.draw(indicator, within: bounds, showingHint: true)
    }
}

// MARK: - Indicator Drawing

/// One drawing for both surfaces the indicator appears on: the live overlay while hovering,
/// and the captured bitmap the report keeps.
@MainActor
enum InspectorIndicatorDrawing {

    /// `showingHint` separates the two surfaces this draws on, and it is the only thing that
    /// differs between them: the live overlay says how to work itself, the captured bitmap does
    /// not — see `InspectorHint`.
    static func draw(
        _ indicator: InspectorIndicator,
        within bounds: NSRect,
        showingHint: Bool = false
    ) {
        // What the capture-side drawing has already claimed, so the hint lands clear of it.
        var occupied: [NSRect] = []

        switch indicator {
        case .element(let levels, let layers):
            // The unlayered case is the outlined rectangle it always was; the layers are
            // additions on top of it rather than a second way of drawing a pick.
            occupied.append(
                InspectorHierarchyDrawing.draw(levels: levels, layers: layers, within: bounds)
            )
        case .region(let rect, let label):
            // One visual for an element and a drawn region: an outlined rectangle is an
            // outlined rectangle, whether a view was found under it or the pointer drew it.
            drawOutlined(rect, label: label, within: bounds)
        case .point(let point, let label):
            drawPoint(point, label: label, within: bounds)
        }

        guard showingHint else { return }
        InspectorHintDrawing.draw(for: indicator, avoiding: occupied, within: bounds)
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
