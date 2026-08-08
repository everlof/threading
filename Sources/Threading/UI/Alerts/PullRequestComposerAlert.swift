import AppKit

/// The editable boundary between generated change-request copy and a provider write. Codex can update
/// the fields through `ChangeRequestTextComposer`; only the first dialog button returns a proposal
/// to the caller that owns the provider client.
@MainActor
enum PullRequestComposerAlert {
    static func ask(
        seed: ChangeRequestProposalSeed,
        root: URL,
        baseBranch: String,
        headBranch: String,
        isDraft: Bool,
        provider: SourceControlProvider
    ) -> ChangeRequestProposal? {
        let editor = PullRequestComposerAccessory(
            seed: seed,
            root: root,
            isDraft: isDraft,
            provider: provider
        )
        let alert = ThemedAlert()
        alert.messageText = isDraft
            ? L10n.format("Create draft %@", provider.changeRequestName)
            : L10n.format("Create %@", provider.changeRequestName)
        alert.informativeText = L10n.format(
            "Review what will be published from %@ into %@. Codex can edit these fields but cannot publish them.",
            headBranch,
            baseBranch
        )
        alert.alertStyle = .informational
        alert.accessoryView = editor
        alert.initialFirstResponder = editor.titleField
        alert.addButton(withTitle: L10n.format("Publish %@", provider.changeRequestName))
        alert.addButton(withTitle: L10n.string("Cancel"))

        guard ConfirmationAlert.chosenIndex(alert.runModal(), optionCount: 1) == 0 else {
            return nil
        }
        let title = editor.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return ChangeRequestProposal(
            title: title,
            body: editor.body.trimmingCharacters(in: .whitespacesAndNewlines),
            baseBranch: baseBranch,
            headBranch: headBranch,
            isDraft: editor.isDraft
        )
    }
}

@MainActor
private final class PullRequestComposerAccessory: NSView {
    let titleField = ThemedTextField()
    private let bodyScroll = ThemedTextView.scrolling()
    private let draftToggle = ThemedToggle()
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var draftButton = ThemedButton(
        title: L10n.string("Draft with Codex"),
        target: self,
        action: #selector(draftWithCodex)
    )

    private let seed: ChangeRequestProposalSeed
    private let root: URL
    private let provider: SourceControlProvider

    var title: String { titleField.stringValue }
    var body: String { bodyView.string }
    var isDraft: Bool { draftToggle.state == .on }

    private var bodyView: ThemedTextView { bodyScroll.textView }

    init(
        seed: ChangeRequestProposalSeed,
        root: URL,
        isDraft: Bool,
        provider: SourceControlProvider
    ) {
        self.seed = seed
        self.root = root
        self.provider = provider
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        draftToggle.state = isDraft ? .on : .off
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        titleField.stringValue = seed.title
        let titleAccessibilityLabel = L10n.format("%@ title", provider.changeRequestTitle)
        titleField.placeholderString = titleAccessibilityLabel
        titleField.setAccessibilityLabel(titleAccessibilityLabel)

        bodyView.string = seed.body
        bodyView.applyFont(.body)
        bodyView.setAccessibilityLabel(L10n.format(
            "%@ description",
            provider.changeRequestTitle
        ))
        bodyScroll.applySurface(
            fill: Design.Surface.controlResting,
            radius: .control,
            border: Design.Surface.border
        )

        let titleLabel = NSTextField(labelWithString: L10n.string("Title"))
        titleLabel.applyFont(.caption)
        titleLabel.textColor = Design.Text.secondary
        let bodyLabel = NSTextField(labelWithString: L10n.string("Description"))
        bodyLabel.applyFont(.caption)
        bodyLabel.textColor = Design.Text.secondary

        statusLabel.applyFont(.caption)
        statusLabel.textColor = Design.Text.secondary
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        draftButton.emphasis = .secondary
        draftButton.isHidden = AgentAccountDiscovery.accounts(for: .codex).isEmpty

        let draftLabel = NSTextField(labelWithString: L10n.string("Create as draft"))
        draftLabel.applyFont(.caption)
        draftLabel.textColor = Design.Text.secondary
        draftToggle.setAccessibilityLabel(L10n.string("Create as draft"))
        let draftChoice = NSStackView(views: [draftToggle, draftLabel])
        draftChoice.orientation = .horizontal
        draftChoice.alignment = .centerY
        draftChoice.spacing = Design.Spacing.tight

        let draftRow = NSStackView(views: [draftChoice, statusLabel, draftButton])
        draftRow.orientation = .horizontal
        draftRow.alignment = .centerY
        draftRow.spacing = Design.Spacing.small

        let stack = NSStackView(views: [titleLabel, titleField, bodyLabel, bodyScroll, draftRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PullRequestComposerDefaults.width),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bodyScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bodyScroll.heightAnchor.constraint(equalToConstant: PullRequestComposerDefaults.bodyHeight),
            draftRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func draftWithCodex() {
        draftButton.isEnabled = false
        statusLabel.stringValue = L10n.string("Codex is drafting…")
        ChangeRequestTextComposer.run(
            seed: seed,
            in: root,
            provider: provider
        ) { [weak self] outcome in
            guard let self else { return }
            self.draftButton.isEnabled = true
            switch outcome {
            case .success(let draft):
                self.titleField.stringValue = draft.title
                self.bodyView.string = draft.body
                self.statusLabel.stringValue = L10n.string("Draft ready — review it before publishing.")
            case .failure(let failure):
                self.statusLabel.stringValue = failure.message(for: self.provider)
                self.statusLabel.textColor = Design.Status.negative
            }
        }
    }
}

private enum PullRequestComposerDefaults {
    static let width: CGFloat = 520
    static let bodyHeight: CGFloat = 260
}
