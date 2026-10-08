import AppKit

/// Six fixed device controls keep their full touch targets and wrap as a group in a narrow pane.
final class SimulatorHardwareControlsView: NSView, PointerClaiming {
    var restingPointer: NSCursor? { .arrow }
    override func resetCursorRects() { registerPointerClaims() }
    private let buttons: [ThemedIconButton]
    var onHeightChange: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat?
    override var isFlipped: Bool { true }

    init(buttons: [ThemedIconButton]) {
        precondition(buttons.count == 6)
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

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let rows = buttons.count / columns(for: width)
        return CGFloat(rows) * ThemedIconButton.Target.device.size.height + CGFloat(rows - 1) * Design.Spacing.medium
    }

    private func columns(for width: CGFloat) -> Int {
        let size = ThemedIconButton.Target.device.size.width
        guard width > 0 else { return buttons.count }
        for columns in [6, 3, 2, 1] {
            if CGFloat(columns) * size + CGFloat(columns - 1) * Design.Spacing.medium <= width { return columns }
        }
        return 1
    }

    override func layout() {
        super.layout()
        let size = ThemedIconButton.Target.device.size
        let columns = columns(for: bounds.width)
        let rowWidth = CGFloat(columns) * size.width + CGFloat(columns - 1) * Design.Spacing.medium
        let left = max(0, (bounds.width - rowWidth) / 2)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: left + CGFloat(index % columns) * (size.width + Design.Spacing.medium),
                                  y: CGFloat(index / columns) * (size.height + Design.Spacing.medium),
                                  width: size.width, height: size.height)
        }
        let height = preferredHeight(for: bounds.width)
        if reportedHeight != height { reportedHeight = height; onHeightChange?(height) }
    }
}
