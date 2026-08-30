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
    var onDrag: ((CGPoint, CGPoint, Int) -> Void)?
    var onText: ((String) -> Void)?

    private var pointerStart: (location: CGPoint, time: TimeInterval)?
    private var pointerCurrent: CGPoint?

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

        if interactionState.acceptsPointerRequests, isHovered || pointerStart != nil {
            Design.Surface.imageHoverWash.setFill()
            shape.path.fill()
            Design.Surface.accent.setStroke()
            let outline = shape.inset(by: Design.Radius.border / 2).path
            outline.lineWidth = Design.Radius.border
            outline.stroke()
        }
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
        pointerCurrent = location
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard pointerStart != nil else { return }
        pointerCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = pointerStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        defer { cancelPointerGesture() }
        guard let from = normalizedPoint(start.location),
              let to = normalizedPoint(end) else { return }

        let distance = hypot(end.x - start.location.x, end.y - start.location.y)
        if distance < 4 {
            onTap?(from)
        } else {
            let milliseconds = Int(((event.timestamp - start.time) * 1_000).rounded())
            onDrag?(from, to, min(2_000, max(100, milliseconds)))
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

    private func normalizedPoint(_ point: CGPoint) -> CGPoint? {
        let target = imageRect
        guard !target.isEmpty, target.contains(point) else { return nil }
        return CGPoint(
            x: min(1, max(0, (point.x - target.minX) / target.width)),
            y: min(1, max(0, (target.maxY - point.y) / target.height))
        )
    }

    private func cancelPointerGesture() {
        pointerStart = nil
        pointerCurrent = nil
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
