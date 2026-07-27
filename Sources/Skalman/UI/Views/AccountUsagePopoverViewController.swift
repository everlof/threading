import AppKit

/// Detail behind the toolbar's usage pill: every rate-limit window for the account, each
/// with its bar, percentage and reset countdown.
///
/// Content is rebuilt from the service whenever the account's entry changes, so a refresh
/// completing while the popover is open lands in front of the user rather than behind the
/// next click.
final class AccountUsagePopoverViewController: NSViewController {

    // MARK: - Properties

    private let account: AgentAccount
    private let isEmbedded: Bool
    private let contentStack = NSStackView()
    private let appEvents = AppEventObservations()

    /// Fired as the pointer enters and leaves the popover, so the owning pill can keep a
    /// hover-opened popover alive while the pointer is inside it.
    var onHoverChange: ((Bool) -> Void)?

    // MARK: - Initialization

    init(account: AgentAccount, isEmbedded: Bool = false) {
        self.account = account
        self.isEmbedded = isEmbedded
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container: NSView
        if isEmbedded {
            container = NSView()
        } else {
            let trackingContainer = HoverTrackingView()
            trackingContainer.onHoverChange = { [weak self] hovering in
                self?.onHoverChange?(hovering)
            }
            container = trackingContainer
        }
        let inset = isEmbedded ? 0 : Design.Spacing.inset

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Design.Spacing.medium
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: inset
            ),
            contentStack.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: inset
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -inset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -inset
            ),
            contentStack.widthAnchor.constraint(
                equalToConstant: UsagePopoverDefaults.contentWidth
            )
        ])

        view = container
        render()

        appEvents.observe(AccountUsageDidChange.self) { [weak self] event in
            self?.usageDidChange(event)
        }
    }

    // MARK: - Private Methods

    private func usageDidChange(_ event: AccountUsageDidChange) {
        guard event.accountID == account.id else { return }
        render()
    }

    private func render() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let usage = AccountUsageService.shared.usage(for: account)

        contentStack.addArrangedSubview(headerRow(planLabel: usage?.planLabel))

        if let usage {
            // Model-scoped windows follow the account's own, as in the composer's panel: the
            // pill's peak deliberately ignores them, so the popover it opens is where a limit
            // that binds one model rather than the plan gets said out loud.
            for window in usage.windows + usage.modelWindows {
                let rowView = row(for: window)
                contentStack.addArrangedSubview(rowView)
                rowView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            }
        }

        if let footer = footerText(usage: usage) {
            let label = NSTextField(labelWithString: footer)
            label.font = Design.Typography.caption()
            label.textColor = Design.Text.tertiary
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            contentStack.addArrangedSubview(label)
        }
    }

    private func headerRow(planLabel: String?) -> NSView {
        let title = "\(account.provider.displayName) — \(account.displayName)"
        let nameLabel = NSTextField(labelWithString: title)
        nameLabel.font = Design.Typography.control()
        nameLabel.textColor = Design.Text.label
        nameLabel.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [nameLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small

        if let planLabel {
            let plan = NSTextField(labelWithString: planLabel)
            plan.font = Design.Typography.caption()
            plan.textColor = Design.Text.secondary
            row.addArrangedSubview(plan)
        }

        return row
    }

    /// One window, drawn by the shared row so the popover and the composer's usage panel
    /// stay the same thing seen twice.
    private func row(for window: AccountUsage.Window) -> NSView {
        UsageWindowRow(window: window)
    }

    /// The freshness line, with the source named when the reading is second-hand — a cached
    /// value observed an hour ago should say so rather than posing as live.
    private func footerText(usage: AccountUsage?) -> String? {
        if let usage {
            var text = "Updated \(UsageFormat.age(of: usage.observedAt))"
            if usage.source == .localCache {
                text += " · via Claude's status-line feed"
            }
            return text
        }

        return AccountUsageService.shared.errorMessage(for: account)
            ?? "Fetching usage…"
    }
}

// MARK: - Hover Tracking View

/// A container that reports pointer enter and exit, so a hover-opened popover can stay open while
/// the pointer is over its contents rather than closing the instant it leaves the pill.
final class HoverTrackingView: NSView {

    var onHoverChange: ((Bool) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

// MARK: - Usage Popover Defaults

enum UsagePopoverDefaults {
    static let contentWidth: CGFloat = 240
    static let width = contentWidth + 2 * Design.Spacing.inset
}
