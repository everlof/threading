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
final class AccountUsageItemView: BackdropOverlay {

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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Ink

    /// The pill's surface as well as its text: `Design.Surface.controlResting` is the *chrome's*
    /// label colour at 8%, which over a backdrop of the opposite tone is invisible — which is
    /// exactly how this pill disappeared under a light theme on a dark terminal.
    override func applyInk(_ ink: Design.Ink) {
        updateBackground()
        ringView.trackColor = ink.quaternary
        // The summary is an attributed string built per window, so it carries its colours with
        // it — rebuilding is the only way to re-ink it.
        render()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = Design.Radius.pill(height: AccountUsageItemDefaults.height)
        updateBackground()

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

        summaryLabel.attributedStringValue = Self.summary(windows: usage?.windows ?? [], ink: ink)
    }

    /// `5h 43% · 7d 73%`: each window as a quiet label and its value, the value tinted by
    /// that window's own severity. The vocabulary is Claude's own status line, so the short
    /// names read as familiar rather than cryptic.
    private static func summary(windows: [AccountUsage.Window], ink: Design.Ink) -> NSAttributedString {
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
                color: ink.secondary
            )
            return result
        }

        for (index, window) in windows.enumerated() {
            if index > 0 {
                append(
                    AccountUsageItemDefaults.segmentSeparator,
                    font: Design.Typography.control(),
                    color: ink.tertiary
                )
            }

            append(
                "\(window.id) ",
                font: Design.Typography.caption(),
                color: ink.tertiary
            )

            let expired = window.isExpired()
            let severity = UsageSeverity.from(fraction: expired ? nil : window.fraction)
            let value = expired
                ? AccountUsageItemDefaults.unknownValue
                : window.percent.map { "\($0)%" } ?? AccountUsageItemDefaults.unknownValue

            append(
                value,
                font: Design.Typography.control(),
                color: severity == .normal ? ink.secondary : severity.glyphColor
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
        layer?.cornerRadius = Design.Radius.pill(height: AccountUsageItemDefaults.height)
        applyLayerBackground(isHovered ? ink.surfaceHover : ink.surface)
    }
}
