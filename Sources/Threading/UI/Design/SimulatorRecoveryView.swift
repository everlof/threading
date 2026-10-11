import AppKit

/// A bounded replacement for an unavailable framebuffer. Device discovery and identity remain
/// the pane's responsibility; this component owns wrapping, actions and live theme response.
final class SimulatorRecoveryView: NSView, ThemedComponent {
    private enum Layout {
        static let maximumWidth: CGFloat = 280
        static let maximumDetailLines = 6
    }

    private let titleLabel = NSTextField(wrappingLabelWithString: L10n.string("Simulator unavailable"))
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    let retryButton = ThemedButton(title: L10n.string("Retry"), target: nil, action: nil)
    let chooseButton = ThemedButton(title: L10n.string("Choose Simulator"), target: nil, action: nil)
    private let column = NSStackView()
    private let events = AppEventObservations()
    var onRetry: (() -> Void)?
    var onChoose: (() -> Void)?

    /// The heading and the chooser name what the pane shows: a Simulator, or an Android device.
    var namesDevice = false {
        didSet {
            guard namesDevice != oldValue else { return }
            titleLabel.stringValue = namesDevice ? L10n.string("Device unavailable") : L10n.string("Simulator unavailable")
            chooseButton.title = namesDevice ? L10n.string("Choose Device") : L10n.string("Choose Simulator")
        }
    }

    var detail: String {
        get { detailLabel.stringValue }
        set { detailLabel.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("simulator.recovery")
        titleLabel.applyFont(.emphasizedBody)
        detailLabel.applyFont(.detail())
        detailLabel.maximumNumberOfLines = Layout.maximumDetailLines
        for label in [titleLabel, detailLabel] {
            label.alignment = .center
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        retryButton.emphasis = .secondary
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.setAccessibilityIdentifier("simulator.recovery.retry")
        chooseButton.emphasis = .tertiary
        chooseButton.target = self
        chooseButton.action = #selector(choose)
        chooseButton.setAccessibilityIdentifier("simulator.recovery.choose")

        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = Design.Placeholder.line
        column.translatesAutoresizingMaskIntoConstraints = false
        for child in [titleLabel, detailLabel, retryButton, chooseButton] { column.addArrangedSubview(child) }
        column.setCustomSpacing(Design.Placeholder.group, after: detailLabel)
        addSubview(column)
        let preferredWidth = column.widthAnchor.constraint(equalToConstant: Layout.maximumWidth)
        preferredWidth.priority = .defaultLow
        let inset = column.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -Design.Spacing.medium * 2)
        inset.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            preferredWidth, inset,
            titleLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        events.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
        events.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in self?.applyTheme() }
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = column.bounds.width
        for label in [titleLabel, detailLabel] where width > 0 && abs(label.preferredMaxLayoutWidth - width) > 0.5 {
            label.preferredMaxLayoutWidth = width
            label.invalidateIntrinsicContentSize()
        }
    }

    private func applyTheme() {
        titleLabel.textColor = Design.Text.label
        detailLabel.textColor = Design.Text.secondary
    }

    @objc private func retry() { onRetry?() }
    @objc private func choose() { onChoose?() }
}
