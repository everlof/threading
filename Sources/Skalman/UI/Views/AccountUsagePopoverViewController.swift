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

    /// Fired as the pointer enters and leaves the popover, so the owning pill can keep a
    /// hover-opened popover alive while the pointer is inside it.
    var onHoverChange: ((Bool) -> Void)?

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
        let container = HoverTrackingView()
        container.onHoverChange = { [weak self] hovering in self?.onHoverChange?(hovering) }

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
        // The linear time mark: where the clock is in this window, so the fill can be read as
        // ahead of or behind the pace.
        bar.timeMark = expired ? nil : window.elapsedFraction()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(
            equalToConstant: UsagePopoverDefaults.barHeight
        ).isActive = true

        let resetText: String
        if expired {
            resetText = "Reset passed — awaiting a fresh reading"
        } else if let resetsAt = window.resetsAt {
            // Both the countdown and the absolute local time — "in 3h 12m · 3:45 PM".
            resetText = "Resets in \(UsageFormat.remaining(until: resetsAt)) · \(UsageFormat.absolute(resetsAt))"
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

// MARK: - Usage Bar View

/// A flat horizontal gauge: quiet full-width track, tinted fill for the spent fraction.
final class UsageBarView: NSView {

    // MARK: - Properties

    var fraction: Double = 0 { didSet { needsLayout = true } }
    var tint: NSColor = .controlAccentColor { didSet { needsLayout = true } }

    /// The linear time position within the window, 0…1, drawn as a thin vertical mark so the
    /// spent fill can be read against the clock. Nil hides it.
    var timeMark: Double? { didSet { needsLayout = true } }

    private let fillView = NSView()
    private let markView = NSView()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        fillView.wantsLayer = true
        markView.wantsLayer = true
        addSubview(fillView)
        // Above the fill, so the pace line stays visible even where usage has passed it.
        addSubview(markView)
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

        if let timeMark {
            let markWidth = UsagePopoverDefaults.timeMarkWidth
            let x = bounds.width * min(max(timeMark, 0), 1)
            markView.frame = NSRect(
                x: min(max(x - markWidth / 2, 0), bounds.width - markWidth),
                y: 0, width: markWidth, height: bounds.height
            )
            markView.layer?.cornerCurve = .continuous
            markView.layer?.cornerRadius = markWidth / 2
            // labelColor adapts to light/dark, so the mark reads against both the track and any
            // tint fill it overlaps.
            markView.layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(UsagePopoverDefaults.timeMarkAlpha).cgColor
            markView.isHidden = false
        } else {
            markView.isHidden = true
        }
    }
}

// MARK: - Usage Popover Defaults

enum UsagePopoverDefaults {
    static let contentWidth: CGFloat = 240
    static let barHeight: CGFloat = 6
    static let timeMarkWidth: CGFloat = 2
    static let timeMarkAlpha: CGFloat = 0.85
}
