import AppKit

/// Related icon actions carried as one compact run inside a toolbar or content control row.
///
/// The space *inside* a related run is tighter than the space between separate decisions. Keeping
/// that distinction in a component prevents every toolbar-like surface from rebuilding it with a
/// local `NSStackView`, and lets a `ControlRowView` promote the whole run to the theme's live row
/// height in one step.
class ControlButtonGroupView: BackdropOverlay, ControlRowMember {

    // MARK: - Properties

    private(set) var buttons: [ThemedIconButton]

    private let stack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    // MARK: - Initialization

    init(buttons: [ThemedIconButton], spacing: CGFloat = Design.Spacing.tight) {
        self.buttons = buttons
        super.init(frame: .zero)
        setup(spacing: spacing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Ink

    /// Deliberately empty: the group is geometry. Every button inside it reads its own backdrop.
    override func applyInk(_ ink: Design.Ink) {}

    // MARK: - Members

    /// Takes a member back into the group at the end of the run.
    ///
    /// Used by toolbar controls whose one live view temporarily moves into another host.
    func readopt(_ button: ThemedIconButton) {
        guard button.superview !== stack else { return }
        buttons.removeAll { $0 === button }
        buttons.append(button)
        stack.addArrangedSubview(button)
    }

    // MARK: - ControlRowMember

    func adopt(_ metrics: ControlRowMetrics) {
        for button in buttons {
            button.adopt(metrics)
        }
    }

    // MARK: - Setup

    private func setup(spacing: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = spacing
        addSubview(stack)

        for button in buttons {
            stack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
