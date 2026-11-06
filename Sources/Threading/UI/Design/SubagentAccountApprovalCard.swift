import AppKit

/// Host-owned identity, usage evidence and one-shot actions. No provider permission policy or
/// extension can supply this card's answer. Only one card is mounted per conversation.
final class SubagentAccountApprovalCard: NSView {
    let request: SubagentAccountApproval
    var onLayoutChange: (() -> Void)?
    private let usageLabel = NSTextField(wrappingLabelWithString: "")
    private let freshnessLabel = NSTextField(wrappingLabelWithString: "")
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var approveButton = ThemedButton(
        title: L10n.string("Approve and Start"), target: self, action: #selector(approve))
    private lazy var refreshButton = ThemedButton(
        title: L10n.string("Refresh Usage"), target: self, action: #selector(refreshUsage))
    private lazy var denyButton = ThemedButton(
        title: L10n.string("Deny"), target: self, action: #selector(deny))

    init(request: SubagentAccountApproval) {
        self.request = request
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("conversation.subagent-account-approval")
        applySurface(fill: Design.Surface.panel, radius: .control, border: Design.Surface.border)
        let header = ConversationDecisionHeader(
            title: L10n.string("Approve subagent account"),
            detail: L10n.string("This starts one subagent on the account below."),
            symbol: "person.crop.circle.badge.checkmark")
        let accountName: String
        if let account = request.account {
            accountName = account.displayName == account.handle.name
                ? account.displayName : "\(account.displayName) (\(account.handle.name))"
        } else {
            accountName = request.accountName
        }
        let identity = label(
            [request.plan.kind.displayName, accountName,
             request.plan.model ?? L10n.string("Default model")].joined(separator: " · "),
            primary: true)
        let task = label(SessionNaming.promptTitle(from: request.brief) ?? L10n.string("Subagent task"))
        task.setAccessibilityLabel(L10n.string("Subagent task"))
        for field in [usageLabel, freshnessLabel, stateLabel] {
            field.applyFont(.caption, in: .conversation)
            field.textColor = Design.Text.secondary
            field.isSelectable = true
        }
        usageLabel.setAccessibilityIdentifier("conversation.subagent-account-approval.usage")
        freshnessLabel.setAccessibilityIdentifier("conversation.subagent-account-approval.freshness")
        approveButton.emphasis = .primary
        denyButton.emphasis = .tertiary
        approveButton.setAccessibilityIdentifier("conversation.subagent-account-approval.approve")
        denyButton.setAccessibilityIdentifier("conversation.subagent-account-approval.deny")
        refreshButton.setAccessibilityIdentifier("conversation.subagent-account-approval.refresh")
        // No Return key equivalent: typing into the composer must never approve an arrival.
        let actions = ControlRowView(leading: [denyButton], trailing: [refreshButton, approveButton])
        let column = NSStackView(views: [header, identity, task, usageLabel, freshnessLabel, stateLabel, actions])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.medium
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        for child in column.arrangedSubviews {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.inset),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.inset)
        ])
        request.onChange = { [weak self] in self?.update() }
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Terminal fallback: provider-sized evidence scrolls without moving the window's Cancel.
    func scrollableAccessory() -> NSView {
        let scroll = ThemedScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = self
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            topAnchor.constraint(equalTo: clip.topAnchor),
            widthAnchor.constraint(equalTo: clip.widthAnchor)
        ])
        return scroll
    }

    private func label(_ text: String, primary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.applyFont(primary ? .subheading : .caption, in: .conversation)
        field.textColor = primary ? Design.Text.label : Design.Text.secondary
        return field
    }

    private func update() {
        let now = request.observedNow
        let rules = request.rules
        let usage = request.reading.usage
        // Provider data is bounded before creating any display text or views.
        let windows = usage?.windows(metering: request.plan.model) ?? []
        usageLabel.stringValue = windows.prefix(8).map { window in
            let value = window.isExpired(at: now) ? nil : window.fraction
            let consumed = value.map { L10n.format("%lld%% used", Int64(($0 * 100).rounded())) }
                ?? L10n.string("Usage unknown")
            let reset = window.resetsAt.map {
                L10n.format("resets %@", $0.formatted(date: .abbreviated, time: .shortened))
            } ?? L10n.string("Reset time unknown")
            let bound = CustomLimitBounds.effectiveBound(on: window.id, in: rules, window: window, at: now)
            let limit = bound < 1 ? L10n.format(" · Your limit: %lld%%", Int64((bound * 100).rounded())) : ""
            return "\(window.compactName): \(consumed) · \(reset)\(limit)"
        }.joined(separator: "\n")
        if windows.count > 8 {
            usageLabel.stringValue += "\n" + L10n.format("%lld more usage windows", Int64(windows.count - 8))
        }
        if windows.isEmpty { usageLabel.stringValue = L10n.string("Usage unavailable") }
        freshnessLabel.stringValue = usage.map {
            L10n.format("Last reading: %@", $0.observedAt.formatted(date: .abbreviated, time: .standard))
        } ?? L10n.string("No usage reading yet")
        if request.account == nil {
            stateLabel.stringValue = L10n.string("This provider does not report account usage to Threading.")
        } else if request.isRefreshing {
            stateLabel.stringValue = L10n.string("Refreshing usage…")
        } else if request.reading.error != nil {
            stateLabel.stringValue = L10n.string("Usage could not be refreshed. Try again before approving.")
        } else if !request.canApprove {
            stateLabel.stringValue = L10n.string("A fresh reading with room under your limits is required. Refresh usage to try again.")
        } else {
            stateLabel.stringValue = L10n.string("Approval applies only to this start and this account.")
        }
        approveButton.isEnabled = request.canApprove
        refreshButton.isEnabled = !request.isRefreshing
        refreshButton.isHidden = request.account == nil
        onLayoutChange?()
    }

    @objc private func approve() { request.approve() }
    @objc private func deny() { request.deny() }
    @objc private func refreshUsage() { request.refresh() }
}
