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
    private let contentStack = NSStackView()

    // MARK: - Initialization

    init(account: AgentAccount) {
        self.account = account
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Design.Spacing.medium
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: Design.Spacing.inset
            ),
            contentStack.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -Design.Spacing.inset
            ),
            contentStack.widthAnchor.constraint(
                equalToConstant: UsagePopoverDefaults.contentWidth
            )
        ])

        view = container
        render()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(usageDidChange(_:)),
            name: .accountUsageDidChange,
            object: nil
        )
    }

    // MARK: - Private Methods

    @objc private func usageDidChange(_ notification: Notification) {
        guard notification.object as? String == account.id else { return }
        render()
    }

    private func render() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let usage = AccountUsageService.shared.usage(for: account)

        contentStack.addArrangedSubview(headerRow(planLabel: usage?.planLabel))

        if let usage {
            for window in usage.windows {
                let rowView = row(for: window)
                contentStack.addArrangedSubview(rowView)
                rowView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            }
        }

        if let footer = footerText(usage: usage) {
            let label = NSTextField(labelWithString: footer)
            label.font = Design.Typography.caption()
            label.textColor = .tertiaryLabelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            contentStack.addArrangedSubview(label)
        }
    }

    private func headerRow(planLabel: String?) -> NSView {
        let nameLabel = NSTextField(
            labelWithString: "\(account.provider.displayName) — \(account.displayName)"
        )
        nameLabel.font = Design.Typography.control()
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [nameLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small

        if let planLabel {
            let plan = NSTextField(labelWithString: planLabel)
            plan.font = Design.Typography.caption()
            plan.textColor = .secondaryLabelColor
            row.addArrangedSubview(plan)
        }

        return row
    }

    /// One window: its name and value on the first line, the bar beneath, and the reset
    /// countdown under that.
    private func row(for window: AccountUsage.Window) -> NSView {
        let expired = window.isExpired()

        let nameLabel = NSTextField(labelWithString: window.label)
        nameLabel.font = Design.Typography.control()
        nameLabel.textColor = .secondaryLabelColor

        let severity = UsageSeverity.from(fraction: expired ? nil : window.fraction)

        let valueText = expired
            ? AccountUsageItemDefaults.unknownValue
            : window.percent.map { "\($0)%" } ?? AccountUsageItemDefaults.unknownValue
        let valueLabel = NSTextField(labelWithString: valueText)
        valueLabel.font = Design.Typography.control()
        valueLabel.textColor = severity == .normal ? .labelColor : severity.glyphColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView(views: [nameLabel, spacer, valueLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline

        let bar = UsageBarView()
        bar.fraction = expired ? 0 : (window.fraction ?? 0)
        bar.tint = severity.barColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(
            equalToConstant: UsagePopoverDefaults.barHeight
        ).isActive = true

        let resetText: String
        if expired {
            resetText = "Reset passed — awaiting a fresh reading"
        } else if let resetsAt = window.resetsAt {
            resetText = "Resets in \(UsageFormat.remaining(until: resetsAt))"
        } else {
            resetText = ""
        }
        let resetLabel = NSTextField(labelWithString: resetText)
        resetLabel.font = Design.Typography.caption()
        resetLabel.textColor = .tertiaryLabelColor

        let column = NSStackView(views: [titleRow, bar, resetLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.tight

        titleRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        return column
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

// MARK: - Usage Bar View

/// A flat horizontal gauge: quiet full-width track, tinted fill for the spent fraction.
final class UsageBarView: NSView {

    // MARK: - Properties

    var fraction: Double = 0 { didSet { needsLayout = true } }
    var tint: NSColor = .controlAccentColor { didSet { needsLayout = true } }

    private let fillView = NSView()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        fillView.wantsLayer = true
        addSubview(fillView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let radius = bounds.height / 2
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius
        layer?.backgroundColor = Design.Surface.controlResting.cgColor

        let width = bounds.width * min(max(fraction, 0), 1)
        fillView.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        fillView.layer?.cornerCurve = .continuous
        fillView.layer?.cornerRadius = radius
        fillView.layer?.backgroundColor = tint.cgColor
        fillView.isHidden = width <= 0
    }
}

// MARK: - Usage Popover Defaults

enum UsagePopoverDefaults {
    static let contentWidth: CGFloat = 240
    static let barHeight: CGFloat = 4
}
