import AppKit

/// A drawn checkbox: box, mark and title as one full-width target, with hover, press, keyboard,
/// VoiceOver, and drag-out cancellation.
///
/// Extracted from `ThemedAlert`'s suppression row the day a list needed per-row selection: the
/// alert's "don't ask again" and an import list's "include this one" are the same control, and a
/// second drawing of it would be the duplication the theme boundary exists to prevent. Beyond
/// the alert's needs it adds `.mixed`, for a group row summarising children that disagree —
/// activating a mixed box selects everything, which is macOS's own reading of that state.
@MainActor
final class ThemedCheckbox: ThemedControl {
    private enum Layout {
        static let box: CGFloat = 16
        static let gap: CGFloat = Design.Spacing.small
        static let inset: CGFloat = Design.Spacing.tight
        static let markPointSize: CGFloat = 10
        static let markInset: CGFloat = 3
    }

    let title: String

    /// Settable so a group row can follow its children. User activation never *produces*
    /// `.mixed` — it cycles mixed → on and on ↔ off; mixed only arrives from data.
    var state: NSControl.StateValue {
        didSet {
            guard state != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Spoken title when the drawn one is empty or abbreviated — a bare box in a table row
    /// still has to say what it includes.
    private let accessibilityOverride: String?
    private let changed: (NSControl.StateValue) -> Void
    private var isPressed = false { didSet { needsDisplay = true } }

    init(
        title: String,
        state: NSControl.StateValue = .off,
        accessibility: String? = nil,
        changed: @escaping (NSControl.StateValue) -> Void
    ) {
        self.title = title
        self.state = state
        self.accessibilityOverride = accessibility
        self.changed = changed
        super.init(frame: .zero)
        if !title.isEmpty {
            toolTip = title
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        guard !title.isEmpty else {
            return NSSize(width: Layout.inset * 2 + Layout.box, height: Design.Size.chipHeight)
        }
        let width = ceil(title.size(withAttributes: [.font: Design.Typography.controlRegular()]).width)
        return NSSize(
            width: Layout.inset * 2 + Layout.box + Layout.gap + width,
            height: Design.Size.chipHeight
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let fires = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if fires { _ = performPrimaryAction() }
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        state = state == .on ? .off : .on
        changed(state)
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityTitle() -> String? { accessibilityOverride ?? title }

    /// The checkbox convention: 0 off, 1 on, 2 mixed. A Bool cannot say "some".
    override func accessibilityValue() -> Any? {
        switch state {
        case .on: 1
        case .mixed: 2
        default: 0
        }
    }

    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, isHovered || isPressed {
            ThemedSurface.draw(
                bounds,
                fill: isPressed ? Design.Surface.controlHover : Design.Surface.controlResting,
                radius: Design.Radius.control
            )
        }

        let box = NSRect(
            x: Layout.inset,
            y: (bounds.height - Layout.box) / 2,
            width: Layout.box,
            height: Layout.box
        )
        let filled = state != .off
        let shape = ThemedSurface.draw(
            box,
            fill: filled ? Design.Surface.accent : Design.Surface.controlResting,
            border: filled ? nil : Design.Surface.border,
            radius: Design.Radius.control(fitting: box.size)
        )
        let markName = state == .mixed ? "minus" : "checkmark"
        if filled,
           let mark = NSImage(systemSymbolName: markName, accessibilityDescription: nil)?
            .withSymbolConfiguration(Design.Symbol.configuration(
                Layout.markPointSize,
                weight: .semibold
            )) {
            TemplateImageDrawing.draw(
                mark,
                in: box.insetBy(dx: Layout.markInset, dy: Layout.markInset),
                tint: isEnabled ? Design.Text.selected : Design.Text.tertiary
            )
        }
        drawKeyboardFocus(around: shape)

        guard !title.isEmpty else { return }
        let font = Design.Typography.controlRegular()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isEnabled ? Design.Text.label : Design.Text.tertiary
        ]
        let x = box.maxX + Layout.gap
        let height = ceil(font.boundingRectForFont.height)
        (title as NSString).draw(
            in: NSRect(x: x, y: bounds.midY - height / 2, width: max(0, bounds.maxX - x), height: height),
            withAttributes: attributes
        )
    }
}
