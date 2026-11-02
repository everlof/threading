import AppKit

/// What a message's actions float on, drawn only while they are relevant.
///
/// It takes no line of its own, so it lies over the message: on an opaque surface, at the message's
/// foot, or beside a user's bubble on the empty side of its row. Until it is drawn it must not
/// answer a press on the words beneath it, because a drag that begins there is a text selection.
final class ConversationMessageActionPlate: NSView {

    // MARK: - Properties

    private let appEvents = AppEventObservations()

    // MARK: - Initialization

    init(actions: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        applyFill()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyFill() }
        appEvents.observe(WindowBackdropDidChange.self) { [weak self] _ in self?.applyFill() }
        alphaValue = 0

        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)
        let pad = Design.Spacing.hairline
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            actions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Placement

    /// Floats over `message`: at its foot, or beside `bubble` when the message is a user's.
    func float(over message: NSView, beside bubble: NSView?) {
        message.addSubview(self)
        NSLayoutConstraint.activate([
            bottomAnchor.constraint(equalTo: message.bottomAnchor),
            bubble.map { trailingAnchor.constraint(equalTo: $0.leadingAnchor, constant: -Design.Spacing.small) }
                ?? trailingAnchor.constraint(equalTo: message.trailingAnchor)
        ])
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    /// The fill is flattened against the ground into one fixed colour, which the recorded surface
    /// can only replay. A ground or theme that moves has to be measured again, here.
    private func applyFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            applySurface(fill: WindowBackdrop.opaque(Design.Surface.panel), radius: .control)
        }
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0 ? super.hitTest(point) : nil
    }
}
