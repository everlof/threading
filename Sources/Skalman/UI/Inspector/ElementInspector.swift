import AppKit

/// The inspect mode: a transparent child window over the main window, capturing in one of
/// two ways. In **element** mode the view under the pointer is detected and outlined, and
/// clicking hands that view back. In **freeflow** mode nothing is detected — crosshair
/// guides follow the pointer and clicking hands back the exact point. Esc backs out of
/// either.
///
/// A *child window*, not an overlay subview, for three reasons: it sits above everything
/// including the toolbar, it swallows the click so inspecting a button does not press it,
/// and it leaves the window's own layout and hit-testing untouched. It is also what keeps
/// the snapshot clean — the overlay was never in the captured view tree, so the marker is
/// drawn onto the bitmap instead of erased from it.
final class ElementInspector {

    // MARK: - Properties

    /// Called with the picked view once the mode has been dismissed. Element mode.
    var onPick: ((NSView) -> Void)?

    /// Called with the picked point, in window coordinates. Freeflow mode.
    var onPickPoint: ((NSPoint) -> Void)?

    private(set) var isActive = false
    private(set) var mode: InspectorMode = .element

    private weak var host: NSWindow?
    private var overlay: InspectorOverlayWindow?
    private var observers: [NSObjectProtocol] = []

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
        overlay.inspectorView.onPick = { [weak self] point in self?.pick(at: point) }
        overlay.inspectorView.onCancel = { [weak self] in self?.cancel() }

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

        host?.makeKey()
    }

    private func switchMode(to mode: InspectorMode) {
        self.mode = mode
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
                rect: target.convert(target.bounds, to: nil),
                label: InspectorIndicator.label(for: target)
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

    private func pick(at point: NSPoint) {
        switch mode {
        case .element:
            let picked = target(atWindowPoint: point)
            deactivate()
            if let picked {
                onPick?(picked)
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

/// What the overlay shows and the snapshot keeps, in window coordinates either way.
enum InspectorIndicator {
    case element(rect: NSRect, label: String)
    case point(NSPoint, label: String)

    static func label(for view: NSView) -> String {
        let rect = view.convert(view.bounds, to: nil)
        return "\(type(of: view)) — \(Int(rect.width.rounded()))×\(Int(rect.height.rounded()))"
    }
}

// MARK: - Overlay View

/// Draws the indicator and reports the pointer; every decision lives in `ElementInspector`.
final class InspectorOverlayView: NSView {

    var onPointerMoved: ((NSPoint) -> Void)?
    var onPick: ((NSPoint) -> Void)?
    var onCancel: (() -> Void)?

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
        onPick?(event.locationInWindow)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == InspectorDefaults.escapeKeyCode {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
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
        case .element(let rect, let label):
            drawElement(rect, label: label, within: bounds)
        case .point(let point, let label):
            drawPoint(point, label: label, within: bounds)
        }
    }

    // MARK: - Element

    private static func drawElement(_ rect: NSRect, label: String, within bounds: NSRect) {
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

    /// Resolved before any alpha is applied: `withAlphaComponent` *replaces* alpha, and a
    /// theme's accent is free to be translucent already — the ThemedButton lesson.
    private static func resolvedAccent() -> NSColor {
        Design.Surface.accent.usingColorSpace(.sRGB) ?? Design.Surface.accent
    }

    /// The label badge, preferring the space above the rect and falling inside it when the
    /// rect already touches the top — a highlight on the toolbar would otherwise push its
    /// own name off the window.
    private static func drawBadge(_ label: String, above rect: NSRect, within bounds: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.caption(),
            .foregroundColor: Design.Text.label
        ]

        let textSize = (label as NSString).size(withAttributes: attributes)
        let badgeSize = NSSize(
            width: ceil(textSize.width) + Design.Spacing.medium * 2,
            height: ceil(textSize.height) + Design.Spacing.tight * 2
        )

        var origin = NSPoint(x: rect.minX, y: rect.maxY + Design.Spacing.tight)
        if origin.y + badgeSize.height > bounds.maxY {
            origin.y = rect.maxY - badgeSize.height - Design.Spacing.tight
        }
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - badgeSize.width))

        let badgeRect = NSRect(origin: origin, size: badgeSize)
        let badge = NSBezierPath(
            roundedRect: badgeRect,
            xRadius: Design.Radius.control,
            yRadius: Design.Radius.control
        )

        Design.Surface.elevated.setFill()
        badge.fill()
        Design.Surface.border.setStroke()
        badge.lineWidth = Design.Radius.border
        badge.stroke()

        (label as NSString).draw(
            at: NSPoint(
                x: badgeRect.minX + Design.Spacing.medium,
                y: badgeRect.minY + Design.Spacing.tight
            ),
            withAttributes: attributes
        )
    }
}
