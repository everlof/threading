import AppKit

/// One rate-limit window, written out: its name and percentage on a line, a bar beneath, and
/// the reset countdown under that.
///
/// Shared by the toolbar's popover and the composer's usage panel. The two ask the same
/// question — how much of this window is left, and am I ahead of the clock — so they draw the
/// same answer rather than each inventing a layout for it.
///
/// The bar carries a **time mark**: where the clock stands in the window. Fill short of the
/// mark is under pace; fill past it is spending faster than the window refills, which is the
/// thing a percentage alone cannot tell you.
final class UsageWindowRow: NSView {

    // MARK: - Initialization

    init(window: AccountUsage.Window, now: Date = Date()) {
        super.init(frame: .zero)
        setupViews(window: window, now: now)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews(window: AccountUsage.Window, now: Date) {
        let expired = window.isExpired(at: now)
        let severity = UsageSeverity.from(fraction: expired ? nil : window.fraction)

        let nameLabel = NSTextField(labelWithString: window.label)
        nameLabel.font = Design.Typography.control()
        nameLabel.textColor = .secondaryLabelColor

        let valueLabel = NSTextField(labelWithString: Self.value(for: window, expired: expired))
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
        bar.timeMark = expired ? nil : window.elapsedFraction(at: now)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let resetLabel = NSTextField(labelWithString: Self.reset(for: window, expired: expired))
        resetLabel.font = Design.Typography.caption()
        resetLabel.textColor = .tertiaryLabelColor

        let column = NSStackView(views: [titleRow, bar, resetLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.tight
        column.translatesAutoresizingMaskIntoConstraints = false

        addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),

            titleRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            bar.widthAnchor.constraint(equalTo: column.widthAnchor),
            bar.heightAnchor.constraint(equalToConstant: UsageBarDefaults.height)
        ])
    }

    // MARK: - Private Methods

    private static func value(for window: AccountUsage.Window, expired: Bool) -> String {
        guard !expired, let percent = window.percent else { return UsageDefaults.unknownValue }
        return "\(percent)%"
    }

    /// Both the countdown and the absolute local time — "Resets in 3h 12m · 3:45 PM".
    private static func reset(for window: AccountUsage.Window, expired: Bool) -> String {
        if expired {
            return UsageWindowRowDefaults.expiredReset
        }

        guard let resetsAt = window.resetsAt else { return "" }

        return "Resets in \(UsageFormat.remaining(until: resetsAt)) · \(UsageFormat.absolute(resetsAt))"
    }
}

// MARK: - Usage Window Row Defaults

enum UsageWindowRowDefaults {
    static let expiredReset = "Reset passed — awaiting a fresh reading"
}
