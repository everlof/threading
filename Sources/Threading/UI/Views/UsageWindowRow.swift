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
///
/// It also carries the user's own line when one is drawn on this window (`limits`). The line
/// changes two things and deliberately not a third: the track past it goes quiet, and the value
/// takes its severity from consumed-of-*bound* rather than consumed-of-window. The **printed
/// percentage and the fill's length stay the provider's own figure** — a row reading 47% under a
/// 50% line prints 47% in the critical tint, because the number is the fact and the tint is the
/// pressure.
final class UsageWindowRow: NSView {

    // MARK: - Properties

    /// Which window this row stands for.
    let windowID: String

    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let resetLabel = NSTextField(labelWithString: "")
    private let bar = UsageBarView()

    // MARK: - Initialization

    init(window: AccountUsage.Window, now: Date = Date(), limits: [CustomLimit] = []) {
        windowID = window.id
        super.init(frame: .zero)
        setupViews()
        // A row that has just been built is drawing nothing, so there is no travel to ask for.
        apply(window: window, now: now, limits: limits, animated: false)
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

    private func apply(
        window: AccountUsage.Window,
        now: Date,
        limits: [CustomLimit],
        animated: Bool
    ) {
        let expired = window.isExpired(at: now)
        let live = expired ? nil : window.fraction
        let severity = CustomLimitBounds.severity(
            of: live,
            on: window.id,
            in: limits,
            window: window,
            at: now
        )
        let rule = CustomLimitBounds.tightest(on: window.id, in: limits, window: window, at: now)
        let cap = rule.flatMap {
            CustomLimitBounds.resolvedBound(of: $0, window: window, at: now)
        }

        // The line is drawn as a change in the track, which says *that* there is one and not
        // whose or where. The rule names itself here — and in the accessibility label too, since
        // a quieter stretch of a 6pt bar is exactly the kind of fact that reaches nobody who is
        // not looking at it.
        toolTip = rule.map { CustomLimitReceipt.name(for: $0, windowName: window.label) }

        nameLabel.stringValue = window.label
        valueLabel.stringValue = Self.value(for: window, expired: expired)
        valueLabel.textColor = severity == .normal ? Design.Text.label : severity.glyphColor
        resetLabel.stringValue = Self.reset(for: window, expired: expired, now: now)
        setAccessibilityLabel(Self.spoken(
            window: window,
            expired: expired,
            rule: rule
        ))

        // The words state the new reading outright while the bar travels to it. A percentage
        // counting up is a number nobody can read mid-count, and the label is the exact answer
        // the bar is only ever the shape of.
        bar.apply(
            fraction: expired ? 0 : (window.fraction ?? 0),
            tint: severity.barColor,
            timeMark: expired ? nil : window.elapsedFraction(at: now),
            capMark: cap,
            animated: animated
        )
    }

    /// What a reader who cannot see the bar is told: the window, its number, and the user's own
    /// line when one binds it.
    private static func spoken(
        window: AccountUsage.Window,
        expired: Bool,
        rule: CustomLimit?
    ) -> String {
        let reading = "\(window.label) \(value(for: window, expired: expired))"
        guard let rule else { return reading }
        return reading + UsageDefaults.segmentSeparator
            + CustomLimitReceipt.name(for: rule, windowName: window.label)
    }

    private static func value(for window: AccountUsage.Window, expired: Bool) -> String {
        guard !expired, let percent = window.percent else { return UsageDefaults.unknownValue }
        return "\(percent)%"
    }

    /// Both the countdown and the absolute local time — "Resets in 3h 12m · 3:45 PM".
    private static func reset(
        for window: AccountUsage.Window,
        expired: Bool,
        now: Date = Date()
    ) -> String {
        if expired {
            return UsageWindowRowDefaults.expiredReset
        }

        guard let resetsAt = window.resetsAt else { return "" }

        // Counted from the moment the row was asked about, not from `Date()`. They are the same
        // instant in the app and different ones in a fixture, and a row that took `now` for every
        // other line and the wall clock for this one printed "Resets in 1m" beside a window three
        // days from its reset.
        return "Resets in \(UsageFormat.remaining(until: resetsAt, from: now)) · \(UsageFormat.absolute(resetsAt))"
    }
}

// MARK: - Usage Window Row Defaults

enum UsageWindowRowDefaults {
    static var expiredReset: String {
        L10n.string("Reset passed — awaiting a fresh reading")
    }
}
