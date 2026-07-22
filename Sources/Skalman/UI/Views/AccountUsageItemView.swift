import AppKit

/// Toolbar pill showing how much of the current account's rate limit is spent.
///
/// Sits at the window's trailing edge and follows the selected session's account. A small
/// ring gauges whichever window is closest to its limit; beside it every window is named
/// with its value — `5h 43% · 7d 73%` — because the two limits answer different questions
/// (can I keep going now, and will the week hold). Monochrome while usage is comfortable,
/// tinted only as a window approaches its limit — the toolbar is glanced at, not read, so
/// colour is reserved for the moment it means something. Hovering opens the detail popover.
///
/// Hidden outright for sessions with no metered account (shells, nothing selected): a pill
/// with nothing to say is noise in the one corner that is always visible.
final class AccountUsageItemView: NSView {

    // MARK: - Properties

    private let ringView = UsageRingView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let appEvents = AppEventObservations()

    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { updateBackground() } }

    private(set) var account: AgentAccount?

    /// Re-asks the service on a short cadence; the service's own spacing decides whether a
    /// tick actually fetches, so the timer stays cheap.
    private var refreshTimer: Timer?

    private weak var popover: NSPopover?

    /// Pending close of the hover popover, cancelled when the pointer returns to the pill or moves
    /// into the popover before it fires.
    private var closeWorkItem: DispatchWorkItem?

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
    }

    // MARK: - Setup

    private func setupViews() {
        applySurface(
            fill: Design.Surface.controlResting,
            radius: Design.Radius.pill(height: AccountUsageItemDefaults.height)
        )

        ringView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [ringView, summaryLabel])
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
        appEvents.observe(AccountUsageDidChange.self) { [weak self] event in
            self?.usageDidChange(event)
        }

        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: UsageDefaults.refreshTimerInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let account = self.account, self.window != nil else { return }
                AccountUsageService.shared.refresh(account)
            }
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

    private func usageDidChange(_ event: AccountUsageDidChange) {
        guard let account, event.accountID == account.id else { return }
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

        // The ring is the glance: one gauge, driven by whichever window is closest to its
        // limit. The text beside it names every window, which is where the insight lives —
        // a spent 5-hour window and a spent week mean different things.
        let peak = usage?.peakWindow()
        let severity = UsageSeverity.from(fraction: peak?.fraction)

        ringView.fraction = peak?.fraction
        ringView.tint = severity.glyphColor

        summaryLabel.attributedStringValue = Self.summary(windows: usage?.windows ?? [])
    }

    /// `5h 43% · 7d 73%`: each window as a quiet label and its value, the value tinted by
    /// that window's own severity. The vocabulary is Claude's own status line, so the short
    /// names read as familiar rather than cryptic.
    private static func summary(windows: [AccountUsage.Window]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        func append(_ text: String, font: NSFont, color: NSColor) {
            result.append(NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color]
            ))
        }

        guard !windows.isEmpty else {
            append(
                AccountUsageItemDefaults.unknownValue,
                font: Design.Typography.control(),
                color: .secondaryLabelColor
            )
            return result
        }

        for (index, window) in windows.enumerated() {
            if index > 0 {
                append(
                    AccountUsageItemDefaults.segmentSeparator,
                    font: Design.Typography.control(),
                    color: .tertiaryLabelColor
                )
            }

            append(
                "\(window.id) ",
                font: Design.Typography.caption(),
                color: .tertiaryLabelColor
            )

            let expired = window.isExpired()
            let severity = UsageSeverity.from(fraction: expired ? nil : window.fraction)
            let value = expired
                ? AccountUsageItemDefaults.unknownValue
                : window.percent.map { "\($0)%" } ?? AccountUsageItemDefaults.unknownValue

            append(
                value,
                font: Design.Typography.control(),
                color: severity == .normal ? .secondaryLabelColor : severity.glyphColor
            )
        }

        return result
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

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        cancelScheduledClose()
        showPopover()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        scheduleClose()
    }

    /// Opens the detail popover on hover. A short close delay plus the popover's own hover
    /// tracking let the pointer cross the gap between pill and popover without it vanishing.
    private func showPopover() {
        guard let account, popover?.isShown != true else { return }

        // Hovering is the moment the user cares; the service's floor keeps it polite.
        AccountUsageService.shared.refresh(account, force: true)

        let controller = AccountUsagePopoverViewController(account: account)
        controller.onHoverChange = { [weak self] hovering in
            if hovering { self?.cancelScheduledClose() } else { self?.scheduleClose() }
        }

        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        self.popover = popover
    }

    private func scheduleClose() {
        cancelScheduledClose()
        let item = DispatchWorkItem { [weak self] in
            self?.popover?.close()
            self?.popover = nil
        }
        closeWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AccountUsageItemDefaults.hoverCloseDelay,
            execute: item
        )
    }

    private func cancelScheduledClose() {
        closeWorkItem?.cancel()
        closeWorkItem = nil
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

// MARK: - Account Usage Item Defaults

enum AccountUsageItemDefaults {
    static let height: CGFloat = 20
    static let horizontalPadding: CGFloat = 8
    static let ringSize: CGFloat = 12
    static let ringLineWidth: CGFloat = 1.5

    /// Shown when a window's percentage is unknown, e.g. after its reset has passed.
    static let unknownValue = "—"

    /// Between window segments in the pill's summary.
    static let segmentSeparator = " · "

    /// Grace period after the pointer leaves the pill before the hover popover closes, long enough
    /// to cross the gap into the popover itself.
    static let hoverCloseDelay: TimeInterval = 0.35
}
