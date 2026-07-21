import AppKit

/// Toolbar pill showing how much of the current account's rate limit is spent.
///
/// Sits at the window's trailing edge and follows the selected session's account. It shows
/// the peak window as a small ring and percent, monochrome while usage is comfortable and
/// tinted only as a window approaches its limit — the toolbar is glanced at, not read, so
/// colour is reserved for the moment it means something. Clicking opens the detail popover.
///
/// Hidden outright for sessions with no metered account (shells, nothing selected): a pill
/// with nothing to say is noise in the one corner that is always visible.
final class AccountUsageItemView: NSView {

    // MARK: - Properties

    private let ringView = UsageRingView()
    private let percentLabel = NSTextField(labelWithString: "")

    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { updateBackground() } }

    private(set) var account: AgentAccount?

    /// Re-asks the service on a short cadence; the service's own spacing decides whether a
    /// tick actually fetches, so the timer stays cheap.
    private var refreshTimer: Timer?

    private weak var popover: NSPopover?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
        startObserving()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupViews() {
        applySurface(
            fill: Design.Surface.controlResting,
            radius: Design.Radius.pill(height: AccountUsageItemDefaults.height)
        )

        percentLabel.font = Design.Typography.control()
        percentLabel.textColor = .secondaryLabelColor

        ringView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [ringView, percentLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.tight
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AccountUsageItemDefaults.horizontalPadding
            ),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AccountUsageItemDefaults.horizontalPadding
            ),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: AccountUsageItemDefaults.height),
            ringView.widthAnchor.constraint(equalToConstant: AccountUsageItemDefaults.ringSize),
            ringView.heightAnchor.constraint(equalToConstant: AccountUsageItemDefaults.ringSize)
        ])
    }

    private func startObserving() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(usageDidChange(_:)),
            name: .accountUsageDidChange,
            object: nil
        )

        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: UsageDefaults.refreshTimerInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self, let account = self.account, self.window != nil else { return }
            AccountUsageService.shared.refresh(account)
        }
        refreshTimer.map { RunLoop.main.add($0, forMode: .common) }
    }

    // MARK: - Public Methods

    /// Points the pill at an account, or hides it when the current session has none.
    func configure(account: AgentAccount?) {
        self.account = account

        if let account {
            AccountUsageService.shared.refresh(account)
        }

        render()
    }

    // MARK: - Private Methods

    @objc private func usageDidChange(_ notification: Notification) {
        guard let account, notification.object as? String == account.id else { return }
        render()
    }

    private func render() {
        guard let account else {
            isHidden = true
            return
        }

        let usage = AccountUsageService.shared.usage(for: account)
        let errorMessage = AccountUsageService.shared.errorMessage(for: account)

        // Nothing yet, and no failure to explain: stay hidden until the first result.
        guard usage != nil || errorMessage != nil else {
            isHidden = true
            return
        }

        isHidden = false

        let peak = usage?.peakWindow()
        let severity = UsageSeverity.from(fraction: peak?.fraction)

        ringView.fraction = peak?.fraction
        ringView.tint = severity.glyphColor

        percentLabel.stringValue = peak?.percent.map { "\($0)%" }
            ?? AccountUsageItemDefaults.unknownValue
        percentLabel.textColor = severity == .normal
            ? .secondaryLabelColor
            : severity.glyphColor

        toolTip = tooltip(account: account, usage: usage, errorMessage: errorMessage)
    }

    private func tooltip(
        account: AgentAccount,
        usage: AccountUsage?,
        errorMessage: String?
    ) -> String {
        var lines = ["\(account.provider.displayName) — \(account.displayName)"]

        for window in usage?.windows ?? [] {
            let value: String
            if window.isExpired() || window.percent == nil {
                value = AccountUsageItemDefaults.unknownValue
            } else {
                value = "\(window.percent ?? 0)%"
            }

            var line = "\(window.label): \(value)"
            if let resetsAt = window.resetsAt, !window.isExpired() {
                line += " · resets in \(UsageFormat.remaining(until: resetsAt))"
            }
            lines.append(line)
        }

        if let errorMessage {
            lines.append(errorMessage)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard let account else { return }

        if let popover, popover.isShown {
            popover.close()
            return
        }

        // The open is the moment the user cares; the service's floor keeps it polite.
        AccountUsageService.shared.refresh(account, force: true)

        let controller = AccountUsagePopoverViewController(account: account)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        self.popover = popover
    }

    private func updateBackground() {
        layer?.backgroundColor = (isHovered
            ? Design.Surface.controlHover
            : Design.Surface.controlResting).cgColor
    }
}

// MARK: - Usage Ring View

/// A small circular gauge: a quiet full track with the spent fraction drawn over it.
final class UsageRingView: NSView {

    // MARK: - Properties

    var fraction: Double? { didSet { needsDisplay = true } }
    var tint: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth = AccountUsageItemDefaults.ringLineWidth
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        let track = NSBezierPath()
        track.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: 360
        )
        track.lineWidth = lineWidth
        NSColor.quaternaryLabelColor.setStroke()
        track.stroke()

        guard let fraction, fraction > 0 else { return }

        // From twelve o'clock, clockwise, like every gauge the user already reads.
        let progress = NSBezierPath()
        progress.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - 360 * min(fraction, 1),
            clockwise: true
        )
        progress.lineWidth = lineWidth
        progress.lineCapStyle = .round
        tint.setStroke()
        progress.stroke()
    }
}

// MARK: - Severity Colours

extension UsageSeverity {

    /// Tint for the ring, percent text and bars. Normal stays monochrome in glyph contexts
    /// and takes the user's accent in bar fills; pressure escalates through the system's
    /// own warning colours, so light and dark both work.
    var glyphColor: NSColor {
        switch self {
        case .normal: return .secondaryLabelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    var barColor: NSColor {
        switch self {
        case .normal: return .controlAccentColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

// MARK: - Usage Formatting

enum UsageFormat {

    /// Compact time until a reset: `47m`, `2h 14m`, `3d 4h`.
    static func remaining(until date: Date, from now: Date = Date()) -> String {
        let interval = max(0, date.timeIntervalSince(now))
        let minutes = Int(interval / 60)

        if minutes < 60 {
            return "\(max(minutes, 1))m"
        }

        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
        }

        let days = hours / 24
        let rest = hours % 24
        return rest > 0 ? "\(days)d \(rest)h" : "\(days)d"
    }

    /// How stale a reading is: `just now`, `4m ago`.
    static func age(of date: Date, at now: Date = Date()) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

// MARK: - Account Usage Item Defaults

enum AccountUsageItemDefaults {
    static let height: CGFloat = 20
    static let horizontalPadding: CGFloat = 8
    static let ringSize: CGFloat = 12
    static let ringLineWidth: CGFloat = 1.5

    /// Shown when a window's percentage is unknown, e.g. after its reset has passed.
    static let unknownValue = "—"
}
