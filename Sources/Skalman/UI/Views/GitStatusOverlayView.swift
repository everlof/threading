import AppKit

// MARK: - Defaults

enum GitStatusOverlayDefaults {
    static let height: CGFloat = 26
    static let fontSize: CGFloat = 11
    static let maxWidth: CGFloat = 280
    /// Quiet at rest, per the design system; full under the pointer.
    static let restingAlpha: CGFloat = 0.85
}

// MARK: - View

/// The floating card at the session pane's top-right corner: which branch the checkout is on
/// and how much uncommitted work it carries, one click from the full review.
///
/// The pane's surfaces answer "what is the agent saying"; this answers "what has it done to
/// the checkout" without asking the conversation to run a tool. It is deliberately a summary —
/// branch, `+N −M` — because the full answer already has a surface, the Git Review tab, which
/// is exactly where a click lands.
final class GitStatusOverlayView: BackdropOverlay {

    // MARK: - Properties

    /// Called on click; the container routes it to the review tab.
    var onOpen: (() -> Void)?

    private let stack = NSStackView()
    private let glyph = NSImageView()
    private var textLabel: NSTextField?

    /// Held so a backdrop change can rebuild the label, which carries its colours inside an
    /// attributed string and cannot be re-inked in place.
    private var lastReading: GitChangeMonitor.Reading?

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alphaValue = GitStatusOverlayDefaults.restingAlpha
        toolTip = "Open Git Review (⇧⌘R)"
        setAccessibilityRole(.button)

        wantsLayer = true
        layer?.cornerCurve = .continuous

        glyph.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Branch"
        )
        glyph.symbolConfiguration = .init(
            pointSize: GitStatusOverlayDefaults.fontSize,
            weight: .medium
        )

        stack.orientation = .horizontal
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(glyph)
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: GitStatusOverlayDefaults.height),
            widthAnchor.constraint(lessThanOrEqualToConstant: GitStatusOverlayDefaults.maxWidth),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.medium),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.medium),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Ink

    /// This card floats on the *terminal's* background, not on the chrome's ground — see
    /// `BackdropOverlay`. Its surface and its label both come from there.
    ///
    /// `+N −M` keeps `Design.Diff`: those two are semantic rather than decorative, and a green
    /// that stopped meaning added would cost more than the contrast it bought.
    override func applyInk(_ ink: Design.Ink) {
        layer?.cornerRadius = Design.Radius.pill(height: GitStatusOverlayDefaults.height)
        layer?.backgroundColor = ink.surface.cgColor
        layer?.borderWidth = Design.Radius.border
        layer?.borderColor = ink.border.cgColor
        glyph.contentTintColor = ink.secondary
        if let lastReading { update(with: lastReading) }
    }

    // MARK: - Public Methods

    func update(with reading: GitChangeMonitor.Reading) {
        lastReading = reading
        let text = Self.attributedText(for: reading, ink: ink)
        guard text.length > 0 else {
            clear()
            return
        }

        // Rebuilt rather than reassigned: a label measures itself at creation, and the helper
        // exists precisely because assigning attributed text afterwards does not re-measure.
        textLabel?.removeFromSuperview()
        let label = NSTextField.label(attributed: text)
        label.cell?.lineBreakMode = .byTruncatingMiddle
        textLabel = label
        stack.addArrangedSubview(label)

        isHidden = false
    }

    func clear() {
        lastReading = nil
        isHidden = true
    }

    // MARK: - Private Methods

    /// The card's whole sentence: the branch in secondary, the counters in the diff colours.
    /// A clean checkout shows the branch alone; a detached head shows the counters alone;
    /// both absent is nothing to say, and the caller hides the card.
    private static func attributedText(
        for reading: GitChangeMonitor.Reading,
        ink: Design.Ink
    ) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: GitStatusOverlayDefaults.fontSize,
            weight: .medium
        )
        let text = NSMutableAttributedString()

        if let branch = reading.branch {
            text.append(NSAttributedString(string: branch, attributes: [
                .font: font,
                .foregroundColor: ink.secondary
            ]))
        }

        if !reading.summary.isClean {
            if text.length > 0 {
                text.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            }
            text.append(NSAttributedString(string: "+\(reading.summary.added)", attributes: [
                .font: font,
                .foregroundColor: Design.Diff.added
            ]))
            text.append(NSAttributedString(string: " −\(reading.summary.removed)", attributes: [
                .font: font,
                .foregroundColor: Design.Diff.removed
            ]))
        }

        return text
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        onOpen?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        alphaValue = GitStatusOverlayDefaults.restingAlpha
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
