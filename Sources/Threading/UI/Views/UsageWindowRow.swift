import AppKit

/// One rate-limit window, written out: its name and percentage on a line, a bar beneath, and
/// the reset countdown under that.
///
/// Drawn wherever a window is written out at length: the toolbar pill's popover, and the usage
/// settings page.
///
/// The bar carries a **time mark**: where the clock stands in the window. Fill short of the
/// mark is under pace; fill past it is spending faster than the window refills, which is the
/// thing a percentage alone cannot tell you.
final class UsageWindowRow: NSView {

    // MARK: - Properties

    /// Which window this row stands for.
    let windowID: String

    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let resetLabel = NSTextField(labelWithString: "")
    private let bar = UsageBarView()

    // MARK: - Initialization

    init(window: AccountUsage.Window, now: Date = Date()) {
        windowID = window.id
        super.init(frame: .zero)
        setupViews()
        // A row that has just been built is drawing nothing, so there is no travel to ask for.
        apply(window: window, now: now, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Private Methods

    private func setupViews() {
        nameLabel.applyFont(.control)
        nameLabel.textColor = Design.Text.secondary

        valueLabel.applyFont(.control)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView(views: [nameLabel, spacer, valueLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline

        bar.translatesAutoresizingMaskIntoConstraints = false

        resetLabel.applyFont(.caption)
        resetLabel.textColor = Design.Text.tertiary

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
            bar.widthAnchor.constraint(equalTo: column.widthAnchor)
        ])
    }

    private func apply(window: AccountUsage.Window, now: Date, animated: Bool) {
        let expired = window.isExpired(at: now)
        let severity = UsageSeverity.from(fraction: expired ? nil : window.fraction)

        nameLabel.stringValue = window.label
        valueLabel.stringValue = Self.value(for: window, expired: expired)
        valueLabel.textColor = severity == .normal ? Design.Text.label : severity.glyphColor
        resetLabel.stringValue = Self.reset(for: window, expired: expired)

        // The words state the new reading outright while the bar travels to it. A percentage
        // counting up is a number nobody can read mid-count, and the label is the exact answer
        // the bar is only ever the shape of.
        bar.apply(
            fraction: expired ? 0 : (window.fraction ?? 0),
            tint: severity.barColor,
            timeMark: expired ? nil : window.elapsedFraction(at: now),
            animated: animated
        )
    }

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
    static var expiredReset: String {
        L10n.string("Reset passed — awaiting a fresh reading")
    }
}
