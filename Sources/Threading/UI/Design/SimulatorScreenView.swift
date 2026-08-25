import AppKit

/// A live device framebuffer that remains a native Threading control.
///
/// The screen owns only presentation and input geometry. The Simulator feature owns the device,
/// consent decision and transport; keeping those out of this design component means a theme or
/// accessibility change cannot accidentally become another authority for device input.
final class SimulatorScreenView: ThemedControl {
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    var allowsInteraction = false {
        didSet {
            guard allowsInteraction != oldValue else { return }
            if !allowsInteraction { cancelPointerGesture() }
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var acceptsFirstResponder: Bool {
        isEnabled && allowsInteraction && image != nil
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

        if allowsInteraction, isHovered || pointerStart != nil {
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
        guard isEnabled, allowsInteraction, imageRect.contains(location) else {
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
        guard allowsInteraction,
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
        guard allowsInteraction else { return false }
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
}
