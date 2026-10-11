import AppKit

/// A device's fixed controls keep their full touch targets and wrap as a group in a narrow pane.
/// An iOS device has six; an Android device has its own set. Hidden buttons take no slot, so one
/// view serves a member whose device changes platform.
final class SimulatorHardwareControlsView: NSView, PointerClaiming {
    var restingPointer: NSCursor? { .arrow }
    override func resetCursorRects() { registerPointerClaims() }
    private let buttons: [ThemedIconButton]
    var onHeightChange: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat?
    override var isFlipped: Bool { true }

    init(buttons: [ThemedIconButton]) {
        precondition(!buttons.isEmpty)
        self.buttons = buttons
        super.init(frame: .zero)
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = true
            button.frame = NSRect(origin: .zero, size: ThemedIconButton.Target.device.size)
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var visibleButtons: [ThemedIconButton] { buttons.filter { !$0.isHidden } }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let count = max(1, visibleButtons.count)
        let rows = (count + columns(for: width, count: count) - 1) / columns(for: width, count: count)
        return CGFloat(rows) * ThemedIconButton.Target.device.size.height + CGFloat(rows - 1) * Design.Spacing.medium
    }

    /// The fewest rows that fit, balanced across them (six in a four-wide pane are 3 + 3, nine in
    /// an eight-wide one 5 + 4), so a wrapped group stays a block rather than leaving one control
    /// dangling.
    private func columns(for width: CGFloat, count: Int) -> Int {
        let size = ThemedIconButton.Target.device.size.width
        guard width > 0 else { return count }
        let widest = max(1, min(count, Int((width + Design.Spacing.medium) / (size + Design.Spacing.medium))))
        let rows = (count + widest - 1) / widest
        return (count + rows - 1) / rows
    }

    /// Re-flows after the owner shows or hides buttons for a different device.
    func buttonsChanged() {
        needsLayout = true
        reportedHeight = nil
    }

    override func layout() {
        super.layout()
        let size = ThemedIconButton.Target.device.size
        let visible = visibleButtons
        let columns = columns(for: bounds.width, count: max(1, visible.count))
        let rowWidth = CGFloat(columns) * size.width + CGFloat(columns - 1) * Design.Spacing.medium
        let left = max(0, (bounds.width - rowWidth) / 2)
        for (index, button) in visible.enumerated() {
            button.frame = NSRect(x: left + CGFloat(index % columns) * (size.width + Design.Spacing.medium),
                                  y: CGFloat(index / columns) * (size.height + Design.Spacing.medium),
                                  width: size.width, height: size.height)
        }
        let height = preferredHeight(for: bounds.width)
        if reportedHeight != height { reportedHeight = height; onHeightChange?(height) }
    }
}
