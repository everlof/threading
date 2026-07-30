import AppKit

/// Several toolbar actions carried as **one** toolbar item.
///
/// `NSToolbar` spaces its items for a bordered, labelled toolbar, which is generous next to
/// controls this compact: three icon buttons arrived as three items and read as three unrelated
/// things floating in the title bar rather than as the pane controls they are. A group is the one
/// way to choose that spacing, because the gap between items belongs to the toolbar and the gap
/// inside an item belongs to us.
///
/// It draws nothing itself — the buttons are already `BackdropThemedControl`s and ink themselves.
final class ToolbarButtonGroupView: BackdropOverlay {

    // MARK: - Initialization

    init(buttons: [ThemedIconButton], spacing: CGFloat = Design.Spacing.tight) {
        super.init(frame: .zero)
        setup(buttons: buttons, spacing: spacing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Ink

    /// Deliberately empty: this view is a layout container with no ink of its own, and every
    /// button inside it reads the backdrop for itself.
    override func applyInk(_ ink: Design.Ink) {}

    // MARK: - Setup

    private func setup(buttons: [ThemedIconButton], spacing: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
