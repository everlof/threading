import AppKit

/// The one-line fold a settled turn collapses behind — "Worked for 42s".
///
/// t3code's turn fold, drawn in this app's quiet-row language: once a turn has settled,
/// everything between its user message and its final assistant reply is hidden behind this
/// line, so a conversation reads as its exchanges rather than as the work that carried them
/// out. The fold owns the views it hid and toggles them on click; expansion is view state,
/// exactly like `ToolCallView.isExpanded`.
final class TurnFoldView: NSView {

    // MARK: - Properties

    private let label: String
    private let foldedViews: [NSView]

    private var chevron: NSImageView!
    private var titleLabel: NSTextField!

    private var isExpanded = false
    private var isHovered = false

    // MARK: - Initialization

    /// `duration` is the turn's measured length, when its terminal event carried one.
    /// `stopped` marks a turn that was interrupted rather than completed — it reads
    /// "Stopped after 42s", t3code's rule, so an abandoned turn does not claim to have worked.
    init(duration: TimeInterval?, stopped: Bool, folding views: [NSView]) {
        self.foldedViews = views
        self.label = Self.title(duration: duration, stopped: stopped)
        super.init(frame: .zero)
        setupViews()
    }

    /// A semantic disclosure for another already-ordered run, such as adjacent tool calls in a
    /// child transcript. The caller owns the label because this fold does not describe a turn.
    init(label: String, folding views: [NSView]) {
        self.foldedViews = views
        self.label = label
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Chat.toolRowResting, radius: .control)

        chevron = NSImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = Design.Text.quaternary
        chevron.symbolConfiguration = Design.Symbol.configuration(
            Design.Symbol.chevron,
            weight: .semibold
        )

        titleLabel = NSTextField(labelWithString: label)
        titleLabel.applyFont(.caption, in: .conversation)
        titleLabel.textColor = Design.Text.tertiary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.maximumNumberOfLines = 1

        addSubview(chevron)
        addSubview(titleLabel)

        let inset = Design.Spacing.small
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            chevron.widthAnchor.constraint(equalToConstant: Design.Chat.toolIconWidth),
            chevron.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: inset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])

        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(label)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggle)))
    }

    // MARK: - Private Methods

    private static func title(duration: TimeInterval?, stopped: Bool) -> String {
        let verb = stopped ? "Stopped" : "Worked"
        guard let duration else { return verb }
        return stopped
            ? "\(verb) after \(TurnStatusText.duration(duration))"
            : "\(verb) for \(TurnStatusText.duration(duration))"
    }

    @objc private func toggle() {
        isExpanded.toggle()
        foldedViews.forEach { $0.isHidden = !isExpanded }
        chevron.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        setAccessibilityExpanded(isExpanded)
        updateSurface()
    }

    // MARK: - Hover

    /// No fill at rest, so hover is the only thing saying the line can be clicked — the same
    /// rule, and the same staleness guard, as the tool rows around it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))

        if hoverIsStale(isHovered) {
            isHovered = false
            updateSurface()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateSurface()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateSurface()
    }

    private func updateSurface() {
        let isActive = isHovered || isExpanded
        applyLayerBackground(isActive ? Design.Chat.toolRowActive : Design.Chat.toolRowResting)
    }
}
