import AppKit

/// The native change-request strip in Git Review: one current state, one next transition, and the
/// repository policy beside it. The controller supplies the provider-neutral reading and owns
/// every effect.
final class GitReviewChangeRequestBar: NSView {
    private let surface = ThemedSurfaceView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let policyChip = ChipView()
    private var policy: ChangeRequestPublishPolicy = .reviewBeforePublishing
    private var provider: SourceControlProvider?
    private lazy var actionButton = ThemedButton(
        title: "",
        target: self,
        action: #selector(performPrimaryAction)
    )
    private lazy var openButton: ThemedButton = {
        let button = ThemedButton(
            symbol: "arrow.up.right.square",
            accessibility: L10n.string("Open change request"),
            target: self,
            action: #selector(openPullRequest)
        )
        button.emphasis = .tertiary
        button.toolTip = L10n.string("Open change request")
        return button
    }()

    var onPrimaryAction: (() -> Void)?
    var onOpen: (() -> Void)?
    var onPolicyChange: ((ChangeRequestPublishPolicy) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setProvider(_ provider: SourceControlProvider) {
        self.provider = provider
        let label = L10n.format(
            "Open %@ on %@",
            provider.changeRequestName,
            provider.displayName
        )
        openButton.setAccessibilityLabel(label)
        openButton.toolTip = label
        configurePolicy(policy)
    }

    func showLoading(branch: String?) {
        isHidden = false
        let requestTitle = provider?.changeRequestTitle ?? L10n.string("Change request")
        titleLabel.stringValue = branch.map { "\(requestTitle) · \($0)" } ?? requestTitle
        detailLabel.stringValue = provider.map { L10n.format("Reading %@…", $0.displayName) }
            ?? L10n.string("Reading provider…")
        statusLabel.stringValue = ""
        // The read is a state with no transition, and the strip's rule is that such a state is
        // copy rather than a disabled primary button.
        actionButton.title = ""
        actionButton.isEnabled = false
        actionButton.isHidden = true
        openButton.isHidden = true
    }

    func configure(
        title: String,
        detail: String,
        status: String,
        statusColor: NSColor,
        actionTitle: String?,
        actionEnabled: Bool,
        showsOpen: Bool,
        policy: ChangeRequestPublishPolicy
    ) {
        isHidden = false
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        statusLabel.stringValue = status
        statusLabel.textColor = statusColor
        actionButton.title = actionTitle ?? ""
        actionButton.emphasis = .primary
        actionButton.isEnabled = actionTitle != nil && actionEnabled
        actionButton.isHidden = actionTitle == nil
        openButton.isHidden = !showsOpen
        configurePolicy(policy)
    }

    func showFailure(_ message: String, policy: ChangeRequestPublishPolicy) {
        configure(
            title: provider?.changeRequestTitle ?? L10n.string("Change request"),
            detail: message,
            status: "",
            statusColor: Design.Text.tertiary,
            actionTitle: L10n.string("Retry"),
            actionEnabled: true,
            showsOpen: false,
            policy: policy
        )
        // Retrying a background metadata read is recovery, not the pane's primary workflow.
        // Keeping the failure action at primary emphasis made a transient GitHub problem the
        // loudest thing in Git Review.
        actionButton.emphasis = .secondary
    }

    private func setup() {
        surface.applySurface(fill: Design.Surface.panel, radius: .control)

        titleLabel.applyFont(.control)
        titleLabel.textColor = Design.Text.label
        titleLabel.lineBreakMode = .byTruncatingTail
        // The number and title are what the strip is for. At 420pt they were the first thing
        // squeezed out, leaving "3 checks pending" beside half a branch name.
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        detailLabel.applyFont(.caption)
        detailLabel.textColor = Design.Text.secondary
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.applyFont(.caption)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.init(260), for: .horizontal)

        policyChip.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        policyChip.itemsProvider = { [weak self] in self?.policyEntries() ?? [] }
        policyChip.onSelect = { [weak self] item in
            guard let raw = item.representedValue as? String,
                  let policy = ChangeRequestPublishPolicy(rawValue: raw) else { return }
            self?.configurePolicy(policy)
            self?.onPolicyChange?(policy)
        }

        actionButton.emphasis = .primary
        actionButton.setContentHuggingPriority(.required, for: .horizontal)

        let heading = NSStackView(views: [titleLabel, statusLabel])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = Design.Spacing.small

        let copy = NSStackView(views: [heading, detailLabel])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = Design.Spacing.hairline
        copy.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // The policy chooser and the next transition are peers. A plain stack lets each one
        // choose its own height, which changes with the material and visibly put Bauhaus's
        // shadowed chooser off-level beside its button. The shared row owns their height and
        // optical edges, while the copy keeps the slack between the two runs.
        let row = ControlRowView(
            leading: [copy],
            trailing: [policyChip, openButton, actionButton]
        )

        addSubview(surface)
        surface.addSubview(row)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),

            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: Design.Spacing.medium),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -Design.Spacing.medium),
            row.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
        ])
        setAccessibilityElement(true)
    }

    private func configurePolicy(_ policy: ChangeRequestPublishPolicy) {
        self.policy = policy
        let resolvedProvider = provider ?? .github
        policyChip.configure(
            symbolName: "slider.horizontal.3",
            title: policy.title(for: resolvedProvider)
        )
        let explanation = policy.explanation(for: resolvedProvider)
        policyChip.toolTip = explanation
        policyChip.setAccessibilityHelp(explanation)
    }

    private func policyEntries() -> [ThemedMenuEntry] {
        ChangeRequestPublishPolicy.allCases.map { policy in
            .item(ThemedMenuItem(
                title: policy.title(for: provider ?? .github),
                subtitle: policy.explanation(for: provider ?? .github),
                representedValue: policy.rawValue,
                isSelected: policy == self.policy
            ))
        }
    }

    @objc private func performPrimaryAction() { onPrimaryAction?() }
    @objc private func openPullRequest() { onOpen?() }
}
