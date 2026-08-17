import AppKit

/// The header of a collapsible run of rows: a full-width control that shows and hides the
/// detail beneath it.
///
/// Exists because the settings pages had grown into walls. Tools listed every MCP tool of every
/// group and Extensions every manifest field of every package, so the decision-level control sat
/// somewhere inside the inventory documenting it. This row carries the decision — the caller
/// places its own control *beside* this view, never inside it — and the inventory folds away
/// until asked for. Storage's fold row was the hand-rolled first draft of the shape: a plain
/// view with a click gesture, which no keyboard and no assistive technology could operate.
///
/// The chevron leads, outline-style, so the state is readable at the row's start where the eye
/// begins, and every header's title starts on the same line whether or not its card is open.
///
/// The caller's interactive accessory stays a **sibling** on purpose: this control is one
/// accessibility element (the labels inside it are content, not children VoiceOver should walk),
/// and a toggle nested inside it would disappear from the accessibility tree entirely.
final class ThemedDisclosureRow: ThemedControl {

    enum Density {
        /// A section decision in a settings-style inventory.
        case standard
        /// An inline structural heading, such as one hunk inside a source diff.
        case compact

        var minimumHeight: CGFloat {
            switch self {
            case .standard: 44
            case .compact: 27
            }
        }

        var edgeInset: CGFloat {
            switch self {
            case .standard: Design.Spacing.inset
            case .compact: Design.Spacing.small
            }
        }

        var verticalInset: CGFloat {
            switch self {
            case .standard: Design.Spacing.medium
            case .compact: Design.Spacing.tight
            }
        }
    }

    // MARK: - Properties

    /// Whether the detail below this header is currently shown. Setting it moves the chevron
    /// and the reported accessibility value; it does not fire `onToggle`, so an owner can set
    /// the initial state without re-entrancy.
    var isExpanded: Bool {
        didSet {
            guard isExpanded != oldValue else { return }
            updateChevron()
            needsDisplay = true
        }
    }

    /// Called with the new state after a click, Space/Return, or an accessibility press.
    var onToggle: ((Bool) -> Void)?

    private let density: Density
    private let chevron = GlyphView()
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    // MARK: - Initialization

    init(
        content: NSView,
        isExpanded: Bool = false,
        density: Density = .standard
    ) {
        self.isExpanded = isExpanded
        self.density = density
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        chevron.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        addSubview(content)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: density.minimumHeight),

            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: density.edgeInset),
            chevron.widthAnchor.constraint(equalToConstant: Layout.chevronSlot),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),

            content.leadingAnchor.constraint(
                equalTo: chevron.trailingAnchor,
                constant: Design.Spacing.small
            ),
            content.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -density.edgeInset
            ),
            content.topAnchor.constraint(equalTo: topAnchor, constant: density.verticalInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -density.verticalInset)
        ])

        updateChevron()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Interaction

    /// The one semantic operation, shared by pointer, keyboard and accessibility.
    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        isExpanded.toggle()
        onToggle?(isExpanded)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside, isEnabled {
            _ = performPrimaryAction()
        }
    }

    /// A pointing hand, so the row reads as clickable before it is clicked.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Re-tinted at draw time, the same way `ThemedIconButton` keeps its glyph, so a live
        // theme switch reaches the chevron without anything being recorded on it.
        chevron.tint = Design.Text.tertiary

        if isPressed {
            ThemedSurface.draw(bounds, fill: Design.Surface.controlHover, radius: 0)
        } else if isHovered {
            ThemedSurface.draw(bounds, fill: Design.Surface.controlResting, radius: 0)
        }

        // The row is a rectangle spanning its card, so the ring restates that silhouette; the
        // card's own layer corner clips the ring where the first and last rows meet it.
        drawKeyboardFocus(around: ThemedSurface.Shape(rect: bounds, radius: 0))
    }

    private func updateChevron() {
        chevron.setSymbol(
            isExpanded ? "chevron.down" : "chevron.right",
            slot: Layout.chevronSlot,
            role: .chevron,
            weight: .semibold
        )
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }

    override func accessibilityValue() -> Any? { isExpanded }

    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    // MARK: - Layout Constants

    private enum Layout {
        /// A fixed slot rather than the chevron's own width, so every header's title starts on
        /// one line whichever way its chevron points.
        static let chevronSlot: CGFloat = 16

    }
}
