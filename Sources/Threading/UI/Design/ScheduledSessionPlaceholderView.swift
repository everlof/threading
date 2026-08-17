import AppKit

/// The empty conversation surface for a session that exists but has not reached its trigger.
///
/// This is deliberately richer than `SessionPlaceholderView`: a scheduled conversation is not
/// merely absent. It carries a brief, frozen launch decisions and one exact condition that will
/// make it start. The visible brief is line-bounded because its size comes from user-authored
/// text; the full value remains in the durable scheduled record rather than being expanded into
/// an arbitrarily tall view tree.
///
/// **The trigger sentence is the headline, and the session's name is not restated.** The pane's
/// own header already carries the title, and the title *is* the brief's first words — so the
/// first version said the same sentence twice in two more type styles than the surface needed.
/// What remains is one ladder: the surface's name in a caption, the one fact it exists to state
/// in the subheading, the user's own words in body, and the frozen decisions in detail.
///
/// **The brief wraps; it does not truncate line by line.** `byTruncatingTail` on a multi-line
/// field truncates each *paragraph* at the field's width, so a two-paragraph brief drew as two
/// clipped lines with the pane's whole width standing empty around them. Word wrapping with
/// `truncatesLastVisibleLine` is the contract the line bound was always meant to have: fill the
/// column, and say so only where the bound actually cuts.
final class ScheduledSessionPlaceholderView: NSView {

    struct Model: Equatable {
        let trigger: String
        let problem: String?
        let brief: String
        let configuration: String
    }

    private let iconView = NSImageView()
    private let contentStack = NSStackView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let triggerLabel = NSTextField(wrappingLabelWithString: "")
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private let briefCaption = NSTextField(labelWithString: "")
    private let briefLabel = NSTextField(wrappingLabelWithString: "")
    private let configurationLabel = NSTextField(wrappingLabelWithString: "")
    private let startButton = ThemedButton()
    private let editButton = ThemedButton()
    private let cancelButton = ThemedButton()

    var onStartNow: (() -> Void)?
    var onEdit: (() -> Void)?
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

        triggerLabel.applyFont(.subheading)
        triggerLabel.textColor = Design.Text.label
        triggerLabel.alignment = .center
        triggerLabel.maximumNumberOfLines = 3
        triggerLabel.cell?.truncatesLastVisibleLine = true

        problemLabel.applyFont(.detail())
        problemLabel.textColor = Design.Status.warning
        problemLabel.alignment = .center
        problemLabel.maximumNumberOfLines = 3
        problemLabel.cell?.truncatesLastVisibleLine = true

        briefCaption.stringValue = L10n.string("Brief")
        briefCaption.applyFont(.caption)
        briefCaption.textColor = Design.Text.tertiary

        briefLabel.applyFont(.body)
        briefLabel.textColor = Design.Text.secondary
        briefLabel.maximumNumberOfLines = ScheduledSessionPlaceholderDefaults.maximumBriefLines
        briefLabel.cell?.truncatesLastVisibleLine = true

        configurationLabel.applyFont(.detail())
        configurationLabel.textColor = Design.Text.tertiary
        configurationLabel.alignment = .center
        configurationLabel.maximumNumberOfLines = 3
        configurationLabel.cell?.truncatesLastVisibleLine = true

        startButton.title = L10n.string("Start now")
        startButton.isProminent = true
        startButton.target = self
        startButton.action = #selector(startNowClicked)

        editButton.title = L10n.string("Edit")
        editButton.target = self
        editButton.action = #selector(editClicked)

        cancelButton.title = L10n.string("Cancel schedule")
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        let actions = NSStackView(views: [startButton, editButton, cancelButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small

        // The user's words read left-aligned under their caption, on the column's own leading
        // edge: a centred paragraph re-ragged every line of a multi-line brief. Everything that
        // *names* — the state, the trigger, the configuration — stays centred above and below.
        let briefColumn = NSStackView(views: [briefCaption, briefLabel])
        briefColumn.orientation = .vertical
        briefColumn.alignment = .leading
        briefColumn.spacing = Design.Placeholder.caption

        // The announcement cluster: the headline and, when present, the warning under it. A
        // cluster rather than two direct members because the section seam after it has to
        // survive the warning hiding — a custom spacing recorded after a hidden arranged view
        // leaves with it, which is how the seam before "Brief" collapsed to the base spacing in
        // the ordinary no-warning case. `Design.Placeholder` states the rule.
        let headerCluster = NSStackView(views: [triggerLabel, problemLabel])
        headerCluster.orientation = .vertical
        headerCluster.alignment = .centerX
        headerCluster.spacing = Design.Placeholder.line

        let stack = contentStack
        for view in [
            iconView,
            stateLabel,
            headerCluster,
            briefColumn,
            configurationLabel,
            actions
        ] {
            stack.addArrangedSubview(view)
        }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Placeholder.line
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(Design.Placeholder.afterIcon, after: iconView)
        stack.setCustomSpacing(Design.Placeholder.section, after: headerCluster)
        stack.setCustomSpacing(Design.Placeholder.group, after: briefColumn)
        stack.setCustomSpacing(Design.Placeholder.group, after: configurationLabel)

        // The column takes the width it is allowed rather than shrinking to its shortest line:
        // a brief given a third of a wide pane while the rest stood empty read as truncation by
        // layout. Preferred below required, so a narrow pane still wins through the insets.
        let preferredWidth = stack.widthAnchor.constraint(
            equalToConstant: ScheduledSessionPlaceholderDefaults.maximumWidth
        )
        preferredWidth.priority = .defaultHigh

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
            preferredWidth,
            briefColumn.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // The centred sentences take the column's width outright, exactly as the brief
            // column does. Centred *as members*, a long sentence was compressed to the column
            // and truncated on its cached one-line intrinsic height instead of wrapping; with
            // the width stated, the field measures its wrapped height against it, and centred
            // text in a full-width label draws where a centred member would. The brief proved
            // the structure; these take it, through the cluster that carries the header pair.
            headerCluster.widthAnchor.constraint(equalTo: stack.widthAnchor),
            triggerLabel.widthAnchor.constraint(equalTo: headerCluster.widthAnchor),
            problemLabel.widthAnchor.constraint(equalTo: headerCluster.widthAnchor),
            configurationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        briefCaption.setAccessibilityIdentifier("scheduled-session.brief-caption")
        briefLabel.setAccessibilityIdentifier("scheduled-session.brief")
        configurationLabel.setAccessibilityIdentifier("scheduled-session.configuration")
        startButton.setAccessibilityIdentifier("scheduled-session.start-now")
        editButton.setAccessibilityIdentifier("scheduled-session.edit")
        cancelButton.setAccessibilityIdentifier("scheduled-session.cancel")
    }

    /// A wrapping label measures its height against a stated width, so each is told the
    /// column's — *after* the pass that decided it, and never a width read off the label's own
    /// frame: seeding from frames ratchets, because the first pass runs before any frame
    /// exists, and a width locked in at zero is the width every later pass solves around.
    override func layout() {
        super.layout()
        let width = contentStack.frame.width
        guard width > 0 else { return }
        var changed = false
        for label in [triggerLabel, problemLabel, briefLabel, configurationLabel]
        where abs(label.preferredMaxLayoutWidth - width) > 0.5 {
            label.preferredMaxLayoutWidth = width
            // Explicitly: a field whose preferred width moves does not reliably drop its cached
            // one-line intrinsic size, and the trigger sentence kept truncating at the width the
            // first pass compressed it to instead of wrapping at the width it was just told.
            label.invalidateIntrinsicContentSize()
            changed = true
        }
        if changed { needsLayout = true }
    }

    func configure(_ model: Model) {
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

    @objc private func editClicked() {
        onEdit?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}

private enum ScheduledSessionPlaceholderDefaults {
    static let maximumWidth: CGFloat = 680
    static let horizontalInset: CGFloat = 64
    static let iconSize: CGFloat = 42
    static let maximumBriefLines = 12
}
