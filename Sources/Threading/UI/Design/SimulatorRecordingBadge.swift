import AppKit

/// The "this is being recorded" mark over a device screen: a red dot, REC and the elapsed time,
/// and a press that stops the recording.
///
/// It exists because a selected toolbar button and a word in the status line were the only signs
/// that a recording was running, and neither is where the eye is while you use the device. The
/// badge floats over the screen's own corner, uses the status colour a person already reads as
/// "live", and is itself the stop control — so the way out is where the warning is.
///
/// The recording itself is the Simulator feature's; this draws the state it is handed.
final class SimulatorRecordingBadge: ThemedControl {

    enum Phase: Equatable {
        case recording(elapsedSeconds: Int)
        /// The movie is being finalized; the press no longer does anything.
        case finishing
    }

    @MainActor
    private enum Layout {
        static let horizontalInset = Design.Spacing.small
        static let verticalInset = Design.Spacing.tight
        static let dotDiameter: CGFloat = 8
        static let dotGap = Design.Spacing.small
        static let borderWidth: CGFloat = 1
    }

    var phase: Phase = .recording(elapsedSeconds: 0) {
        didSet {
            guard phase != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            setAccessibilityValue(title)
        }
    }

    var onPress: (() -> Void)?

    private var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("simulator.recording")
        setAccessibilityValue(title)
        toolTip = L10n.string("Stop Recording")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `REC 1:07`, or the finishing word — what the badge says and what it reads aloud.
    var title: String {
        switch phase {
        case .recording(let elapsed):
            L10n.format("REC %@", Self.elapsedText(elapsed))
        case .finishing:
            L10n.string("Saving…")
        }
    }

    /// `m:ss`, growing an hour field only when a recording runs that long.
    static func elapsedText(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    private var labelFont: NSFont { Design.Typography.numericControl(weight: .semibold) }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: labelFont, .foregroundColor: Design.Text.label]
    }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: textAttributes)
        let height = max(Layout.dotDiameter, Design.Typography.lineHeight(of: labelFont))
            + Layout.verticalInset * 2
        return NSSize(
            width: ceil(Layout.horizontalInset * 2 + Layout.dotDiameter + Layout.dotGap + text.width),
            height: ceil(height)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let live = Design.Status.negative
        let shape = ThemedSurface.draw(
            bounds.insetBy(dx: Layout.borderWidth / 2, dy: Layout.borderWidth / 2),
            fill: isPressed || isHovered ? Design.Surface.elevated : Design.Surface.floating,
            border: live,
            radius: bounds.height / 2,
            borderWidth: Layout.borderWidth
        )

        let dotRect = NSRect(
            x: bounds.minX + Layout.horizontalInset,
            y: bounds.midY - Layout.dotDiameter / 2,
            width: Layout.dotDiameter,
            height: Layout.dotDiameter
        )
        let dot = NSBezierPath(ovalIn: dotRect)
        (phase == .finishing ? Design.Text.tertiary : live).setFill()
        dot.fill()

        let text = title as NSString
        let size = text.size(withAttributes: textAttributes)
        text.draw(
            at: NSPoint(
                x: dotRect.maxX + Layout.dotGap,
                y: bounds.midY - size.height / 2
            ),
            withAttributes: textAttributes
        )

        drawKeyboardFocus(around: shape, color: Design.Text.label)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, phase != .finishing else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, phase != .finishing else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let fires = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if fires { _ = performPrimaryAction() }
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled, phase != .finishing, let onPress else { return false }
        onPress()
        return true
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? { L10n.string("Stop Recording") }

    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }
}
