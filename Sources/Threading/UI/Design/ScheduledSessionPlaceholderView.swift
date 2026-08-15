import AppKit

/// The empty conversation surface for a session that exists but has not reached its trigger.
///
/// This is deliberately richer than `SessionPlaceholderView`: a scheduled conversation is not
/// merely absent. It carries a brief, frozen launch decisions and one exact condition that will
/// make it start. The visible brief is line-bounded because its size comes from user-authored
/// text; the full value remains in the durable scheduled record rather than being expanded into
/// an arbitrarily tall view tree.
final class ScheduledSessionPlaceholderView: NSView {

    struct Model: Equatable {
        let title: String
        let trigger: String
        let problem: String?
        let brief: String
        let configuration: String
    }

    private let iconView = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let triggerLabel = NSTextField(wrappingLabelWithString: "")
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private let briefCaption = NSTextField(labelWithString: "")
    private let briefLabel = NSTextField(wrappingLabelWithString: "")
    private let configurationLabel = NSTextField(wrappingLabelWithString: "")
    private let startButton = ThemedButton()
    private let cancelButton = ThemedButton()

    var onStartNow: (() -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(
            systemSymbolName: "clock.badge.checkmark",
            accessibilityDescription: L10n.string("Scheduled session")
        )
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = Design.Surface.accent

        stateLabel.stringValue = L10n.string("Scheduled session")
        stateLabel.applyFont(.caption)
        stateLabel.textColor = Design.Surface.accent
        stateLabel.alignment = .center

        titleLabel.applyFont(.placeholderTitle)
        titleLabel.textColor = Design.Text.label
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        triggerLabel.applyFont(.subheading)
        triggerLabel.textColor = Design.Text.secondary
        triggerLabel.alignment = .center
        triggerLabel.maximumNumberOfLines = 3

        problemLabel.applyFont(.detail())
        problemLabel.textColor = Design.Status.warning
        problemLabel.alignment = .center
        problemLabel.maximumNumberOfLines = 3

        briefCaption.stringValue = L10n.string("Brief")
        briefCaption.applyFont(.caption)
        briefCaption.textColor = Design.Text.tertiary
        briefCaption.alignment = .center

        briefLabel.applyFont(.body)
        briefLabel.textColor = Design.Text.label
        briefLabel.alignment = .center
        briefLabel.maximumNumberOfLines = ScheduledSessionPlaceholderDefaults.maximumBriefLines
        briefLabel.lineBreakMode = .byTruncatingTail

        configurationLabel.applyFont(.detail())
        configurationLabel.textColor = Design.Text.tertiary
        configurationLabel.alignment = .center
        configurationLabel.maximumNumberOfLines = 3

        startButton.title = L10n.string("Start now")
        startButton.isProminent = true
        startButton.target = self
        startButton.action = #selector(startNowClicked)

        cancelButton.title = L10n.string("Cancel schedule")
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        let actions = NSStackView(views: [startButton, cancelButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small

        let stack = NSStackView(views: [
            iconView,
            stateLabel,
            titleLabel,
            triggerLabel,
            problemLabel,
            briefCaption,
            briefLabel,
            configurationLabel,
            actions
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Spacing.tight
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(Design.Spacing.medium, after: iconView)
        stack.setCustomSpacing(Design.Spacing.large, after: problemLabel)
        stack.setCustomSpacing(Design.Spacing.medium, after: briefLabel)
        stack.setCustomSpacing(Design.Spacing.large, after: configurationLabel)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: ScheduledSessionPlaceholderDefaults.horizontalInset
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -ScheduledSessionPlaceholderDefaults.horizontalInset
            ),
            stack.widthAnchor.constraint(
                lessThanOrEqualToConstant: ScheduledSessionPlaceholderDefaults.maximumWidth
            ),
            iconView.widthAnchor.constraint(
                equalToConstant: ScheduledSessionPlaceholderDefaults.iconSize
            ),
            iconView.heightAnchor.constraint(
                equalToConstant: ScheduledSessionPlaceholderDefaults.iconSize
            )
        ])

        setAccessibilityElement(false)
        setAccessibilityIdentifier("scheduled-session.placeholder")
        triggerLabel.setAccessibilityIdentifier("scheduled-session.trigger")
        briefLabel.setAccessibilityIdentifier("scheduled-session.brief")
        configurationLabel.setAccessibilityIdentifier("scheduled-session.configuration")
        startButton.setAccessibilityIdentifier("scheduled-session.start-now")
        cancelButton.setAccessibilityIdentifier("scheduled-session.cancel")
    }

    func configure(_ model: Model) {
        titleLabel.stringValue = model.title
        triggerLabel.stringValue = model.trigger
        problemLabel.stringValue = model.problem ?? ""
        problemLabel.isHidden = model.problem == nil
        briefLabel.stringValue = model.brief
        briefLabel.toolTip = model.brief
        configurationLabel.stringValue = model.configuration
        configurationLabel.isHidden = model.configuration.isEmpty
    }

    @objc private func startNowClicked() {
        onStartNow?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}

private enum ScheduledSessionPlaceholderDefaults {
    static let maximumWidth: CGFloat = 600
    static let horizontalInset: CGFloat = 64
    static let iconSize: CGFloat = 42
    static let maximumBriefLines = 7
}
