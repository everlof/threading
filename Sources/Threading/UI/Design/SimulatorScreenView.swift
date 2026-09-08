import AppKit

/// A live device framebuffer that remains a native Threading control.
///
/// The screen owns only presentation and input geometry. The Simulator feature owns the device,
/// consent decision and transport; keeping those out of this design component means a theme or
/// accessibility change cannot accidentally become another authority for device input.
final class SimulatorScreenView: ThemedControl {
    /// Whether the visible frame can accept input now or can safely use an input attempt to
    /// recover its direct transport. Recovery is deliberately distinct from `ready`: the pane
    /// may invite the gesture, but the feature controller must reconnect and authorize it before
    /// anything crosses the helper boundary.
    enum InteractionState: Equatable {
        case unavailable
        case recoverable
        case ready(touch: Bool, keyboard: Bool)

        var acceptsPointerRequests: Bool {
            switch self {
            case .unavailable: false
            case .recoverable: true
            case .ready(let touch, _): touch
            }
        }

        var acceptsKeyboardRequests: Bool {
            switch self {
            case .unavailable: false
            case .recoverable: true
            case .ready(_, let keyboard): keyboard
            }
        }
    }

    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    var interactionState: InteractionState = .unavailable {
        didSet {
            guard interactionState != oldValue else { return }
            if !interactionState.acceptsPointerRequests { cancelPointerGesture() }
            updateAccessibilityContract()
            needsDisplay = true
        }
    }

    var onTap: ((CGPoint) -> Void)?
    /// Phases of a live, finger-following touch driven by a click-drag or a trackpad scroll. The
    /// feature controller streams these to the device so panning follows the input in real time
    /// instead of firing one discrete swipe.
    var onTouchBegan: ((CGPoint) -> Void)?
    var onTouchMoved: ((CGPoint) -> Void)?
    var onTouchEnded: ((CGPoint) -> Void)?
    var onText: ((String) -> Void)?

    private var pointerStart: (location: CGPoint, time: TimeInterval)?
    /// Whether the current mouse gesture has crossed the tap threshold and become a streamed touch.
    private var isStreamingTouch = false
    /// The synthetic contact point a trackpad scroll drives; nil when no scroll gesture is active.
    private var scrollPoint: CGPoint?

    var imageRect: NSRect {
        guard let image else { return .zero }
        return ThemedImagePreview.fittedRect(
            for: image.size,
            in: bounds,
            allowsUpscaling: true
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.string("Simulator screen"))
        updateAccessibilityContract()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var acceptsFirstResponder: Bool {
        isEnabled
            && image != nil
            && (interactionState.acceptsPointerRequests
                || interactionState.acceptsKeyboardRequests)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let target = imageRect
        guard !target.isEmpty else { return }
        let shape = ThemedSurface.Shape(rect: target, radius: Design.Radius.control)

        NSGraphicsContext.saveGraphicsState()
        shape.path.addClip()
        image.draw(
            in: target,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()

        // No hover wash over a live device — it read as an odd white overlay on the real screen.
        // Keyboard focus is still indicated (subtle, and only while typing).
        drawKeyboardFocus(around: shape)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard isEnabled,
              interactionState.acceptsPointerRequests,
              imageRect.contains(location) else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        pointerStart = (location, event.timestamp)
        isStreamingTouch = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pointerStart else { return }
        let location = convert(event.locationInWindow, from: nil)
        // Cross the tap threshold once, then stream the touch so it follows the pointer live.
        if !isStreamingTouch,
           hypot(location.x - start.location.x, location.y - start.location.y) >= Self.tapThreshold {
            isStreamingTouch = true
            onTouchBegan?(clampedNormalizedPoint(start.location))
        }
        if isStreamingTouch {
            onTouchMoved?(clampedNormalizedPoint(location))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = pointerStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        defer { cancelPointerGesture() }
        if isStreamingTouch {
            onTouchEnded?(clampedNormalizedPoint(end))
        } else if let from = normalizedPoint(start.location) {
            onTap?(from)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Only precise (trackpad) scrolling drives panning; a notched mouse wheel falls through.
        guard isEnabled,
              interactionState.acceptsPointerRequests,
              event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }
        switch event.phase {
        case .began:
            let origin = clamp(convert(event.locationInWindow, from: nil), to: imageRect)
            scrollPoint = origin
            onTouchBegan?(clampedNormalizedPoint(origin))
        case .changed:
            guard var point = scrollPoint else { return }
            // A trackpad scroll moves the content; the finger follows it. Screen y grows downward,
            // so a positive scrolling delta pushes the contact down, matching a natural swipe.
            point.x += event.scrollingDeltaX
            point.y += event.scrollingDeltaY
            point = clamp(point, to: imageRect)
            scrollPoint = point
            onTouchMoved?(clampedNormalizedPoint(point))
        case .ended, .cancelled:
            if let point = scrollPoint { onTouchEnded?(clampedNormalizedPoint(point)) }
            scrollPoint = nil
        default:
            // Momentum phases are left to a later increment (see the controls draft's arm64
            // momentum note); a scroll that never reported a begin phase is ignored.
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        guard interactionState.acceptsKeyboardRequests,
              event.modifierFlags.intersection([.command, .control]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 51 {
            // The helper's typed keyboard envelope uses USB HID usage values; U+0008 is its
            // explicit backspace spelling and never crosses the process boundary as a key code.
            onText?("\u{8}")
        } else if let text = event.characters, !text.isEmpty {
            onText?(text)
        } else {
            super.keyDown(with: event)
        }
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled,
              image != nil,
              interactionState.acceptsPointerRequests else { return false }
        onTap?(CGPoint(x: 0.5, y: 0.5))
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override func accessibilityLabel() -> String? { L10n.string("Simulator screen") }

    override var restingPointer: NSCursor? { .arrow }

    private static let tapThreshold: CGFloat = 4

    private func normalizedPoint(_ point: CGPoint) -> CGPoint? {
        let target = imageRect
        guard !target.isEmpty, target.contains(point) else { return nil }
        return CGPoint(
            x: min(1, max(0, (point.x - target.minX) / target.width)),
            y: min(1, max(0, (target.maxY - point.y) / target.height))
        )
    }

    /// Normalizes a point into the device's 0…1 space, clamping rather than rejecting one outside
    /// the image — a streamed touch that runs past the edge should land at the edge, not vanish.
    private func clampedNormalizedPoint(_ point: CGPoint) -> CGPoint {
        let target = imageRect
        guard !target.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: min(1, max(0, (point.x - target.minX) / target.width)),
            y: min(1, max(0, (target.maxY - point.y) / target.height))
        )
    }

    private func clamp(_ point: CGPoint, to rect: NSRect) -> CGPoint {
        guard !rect.isEmpty else { return point }
        return CGPoint(
            x: min(rect.maxX, max(rect.minX, point.x)),
            y: min(rect.maxY, max(rect.minY, point.y))
        )
    }

    private func cancelPointerGesture() {
        pointerStart = nil
        isStreamingTouch = false
        needsDisplay = true
    }

    private func updateAccessibilityContract() {
        let help: String
        switch interactionState {
        case .unavailable:
            help = L10n.string("Simulator control is unavailable.")
        case .recoverable:
            help = L10n.string("Press to reconnect and control the Simulator.")
        case .ready:
            help = L10n.string("Tap, drag, or type to control the Simulator.")
        }
        setAccessibilityHelp(help)
        setAccessibilityEnabled(interactionState != .unavailable)
    }
}
