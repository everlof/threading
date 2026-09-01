import AppKit

enum MainThreadStallHUDDefaults {
    /// How long a stall stays "the thing that just happened" before the pill settles back.
    static let alarmDuration: TimeInterval = 8

    /// Recent stalls kept for the expanded list. Bounded because the HUD is a glance, not the
    /// record — the incident files under Performance/Stalls are the record.
    static let rememberedStalls = 8

    /// Rows shown while expanded.
    static let visibleRows = 5

    static let dotDiameter: CGFloat = 7
    static let horizontalInset = Design.Spacing.medium
    static let verticalInset = Design.Spacing.small
    static let dotGap = Design.Spacing.small
    static let rowGap = Design.Spacing.hairline
    static let cornerRadius: CGFloat = 7
    static let borderWidth: CGFloat = 1

    /// Held well off the window's bottom-trailing corner: that corner is the easiest place to
    /// grab a window by, and a diagnostic readout that ate the resize grip would be a worse bug
    /// than the ones it reports.
    static let margin = Design.Spacing.large
}

/// A DEBUG-only pill that says whether the main thread is currently keeping up.
///
/// This app already records every main-queue freeze — a bounded incident JSON plus a Chrome
/// trace, both with the semantic spans that were in flight. What it had no way of doing was
/// *mentioning* it. The composer lag this was built for was noticed as a feeling, described as a
/// feeling, and only became a measurement because someone went looking through
/// `Performance/Stalls` afterwards. The evidence was sitting on disk the whole time.
///
/// So the pill is quiet while the app is healthy and loud the moment it is not, and it names the
/// same two facts the incident file carries: how long the main queue was gone, and which
/// semantic spans were open while it was. An empty span list is the informative case and says so
/// out loud, because that is what points at work no span covers.
///
/// It costs nothing while nothing is wrong: it observes an event that is only posted after a
/// stall, and the only repeating timer it runs is the one that settles it back afterwards.
/// Debug-only by construction — `MainWindowController` installs it inside `#if DEBUG`, so its
/// words are deliberately not localized: they name spans and durations for whoever is debugging
/// the build, and putting developer diagnostics into the shipping string catalogue would ask
/// translators for copy no user can ever reach.
/// A `ThemedControl` rather than a bare view because it answers a click: the boundary lint's
/// point is that anything pressable inherits keyboard access, focus, enabled state and an
/// accessibility role instead of re-deciding them, and a diagnostic readout is not a good reason
/// to opt out of that. It lives under `UI/Views` rather than `UI/Design` for the same reason
/// `AccountUsageItemView` does: the Component Gallery catalogues the reusable design vocabulary,
/// and one DEBUG-only readout of this app's own main queue is a feature surface, not vocabulary
/// anyone should be reaching for.
final class MainThreadStallHUDView: ThemedControl {

    /// One stall as the pill remembers it.
    private struct Entry {
        let duration: TimeInterval
        let operationNames: [String]
    }

    // MARK: - Properties

    private var entries: [Entry] = []
    private var totalCount = 0
    private var alarmUntil: Date?
    private var settleTimer: Timer?
    private var isExpanded = false
    private let appEvents = AppEventObservations()

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("debug.main-thread-hud")

        appEvents.observe(MainThreadStallDidOccur.self) { [weak self] event in
            self?.record(event)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        settleTimer?.invalidate()
    }

    // MARK: - Public Methods

    /// Feeds the pill directly. Tests use this; the app uses the event.
    func record(durationMilliseconds: Double, operationNames: [String]) {
        record(
            MainThreadStallDidOccur(
                durationMilliseconds: durationMilliseconds,
                operationNames: operationNames
            )
        )
    }

    /// What the pill currently says, so a test can assert on the words rather than the pixels.
    var statusText: String {
        guard let latest = entries.first, isAlarmed else { return "ok" }
        return Self.durationText(latest.duration)
    }

    var isAlarmed: Bool {
        guard let alarmUntil else { return false }
        return Date() < alarmUntil
    }

    // MARK: - Private Methods

    private func record(_ event: MainThreadStallDidOccur) {
        totalCount += 1
        entries.insert(
            Entry(
                duration: event.durationMilliseconds / 1000,
                operationNames: event.operationNames
            ),
            at: 0
        )
        if entries.count > MainThreadStallHUDDefaults.rememberedStalls {
            entries.removeLast(entries.count - MainThreadStallHUDDefaults.rememberedStalls)
        }

        alarmUntil = Date().addingTimeInterval(MainThreadStallHUDDefaults.alarmDuration)
        scheduleSettle()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// One timer, replaced rather than accumulated, and only ever alive while a stall is recent.
    private func scheduleSettle() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(
            withTimeInterval: MainThreadStallHUDDefaults.alarmDuration,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settleTimer = nil
                self.invalidateIntrinsicContentSize()
                self.needsDisplay = true
            }
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        duration >= 1
            ? String(format: "%.1fs", duration)
            : String(format: "%.0f ms", duration * 1000)
    }

    /// The spans that were open, or the sentence that says none were — which is the reading that
    /// actually locates a bug.
    private static func spanText(_ names: [String]) -> String {
        guard !names.isEmpty else { return "no active span" }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.prefix(2).joined(separator: ", ")
            + (unique.count > 2 ? " +\(unique.count - 2)" : "")
    }

    // MARK: - Content

    private var headlineColor: NSColor {
        isAlarmed ? Design.Status.negative : Design.Text.quaternary
    }

    private func headline() -> NSAttributedString {
        let text = isAlarmed
            ? "main \(statusText)"
            : "main ok"
        return NSAttributedString(
            string: text,
            attributes: [
                .font: Design.FontRole.numericDetail(weight: .semibold).resolved(),
                .foregroundColor: headlineColor
            ]
        )
    }

    /// Lines under the headline: the current stall's spans, then history while expanded.
    private func detailLines() -> [NSAttributedString] {
        var lines: [NSAttributedString] = []
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.FontRole.detail().resolved(),
            .foregroundColor: Design.Text.tertiary
        ]

        if isAlarmed, let latest = entries.first {
            lines.append(
                NSAttributedString(string: Self.spanText(latest.operationNames), attributes: attributes)
            )
        }

        if isExpanded {
            if totalCount > 0 {
                lines.append(
                    NSAttributedString(
                        string: "\(totalCount) since launch",
                        attributes: attributes
                    )
                )
            }
            for entry in entries.prefix(MainThreadStallHUDDefaults.visibleRows) {
                lines.append(
                    NSAttributedString(
                        string: "\(Self.durationText(entry.duration))  \(Self.spanText(entry.operationNames))",
                        attributes: attributes
                    )
                )
            }
        } else if !isAlarmed, totalCount > 0 {
            lines.append(
                NSAttributedString(string: "\(totalCount) stalls", attributes: attributes)
            )
        }

        return lines
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        let headlineSize = headline().size()
        let details = detailLines()
        let widest = details.map { $0.size().width }.max() ?? 0

        let contentWidth = max(
            MainThreadStallHUDDefaults.dotDiameter + MainThreadStallHUDDefaults.dotGap + headlineSize.width,
            widest
        )
        let detailHeight = details.reduce(0) { $0 + $1.size().height + MainThreadStallHUDDefaults.rowGap }

        return NSSize(
            width: ceil(contentWidth + MainThreadStallHUDDefaults.horizontalInset * 2),
            height: ceil(
                headlineSize.height + detailHeight + MainThreadStallHUDDefaults.verticalInset * 2
            )
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let plate = NSBezierPath(
            roundedRect: bounds,
            xRadius: MainThreadStallHUDDefaults.cornerRadius,
            yRadius: MainThreadStallHUDDefaults.cornerRadius
        )
        Design.Surface.elevated.setFill()
        plate.fill()
        (isAlarmed ? Design.Status.negative : Design.Surface.border).setStroke()
        plate.lineWidth = MainThreadStallHUDDefaults.borderWidth
        plate.stroke()

        let headline = headline()
        let headlineSize = headline.size()
        var y = bounds.maxY - MainThreadStallHUDDefaults.verticalInset - headlineSize.height

        let dot = NSRect(
            x: MainThreadStallHUDDefaults.horizontalInset,
            y: y + (headlineSize.height - MainThreadStallHUDDefaults.dotDiameter) / 2,
            width: MainThreadStallHUDDefaults.dotDiameter,
            height: MainThreadStallHUDDefaults.dotDiameter
        )
        (isAlarmed ? Design.Status.negative : Design.Status.positive).setFill()
        NSBezierPath(ovalIn: dot).fill()

        headline.draw(
            at: NSPoint(
                x: dot.maxX + MainThreadStallHUDDefaults.dotGap,
                y: y
            )
        )

        for line in detailLines() {
            let size = line.size()
            y -= size.height + MainThreadStallHUDDefaults.rowGap
            line.draw(at: NSPoint(x: MainThreadStallHUDDefaults.horizontalInset, y: y))
        }
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        _ = performPrimaryAction()
    }

    /// Expanding the history is the whole interaction, so it is the control's primary action.
    /// Overriding the base's means the pointer, the keyboard and an assistive client's press all
    /// arrive at the same line — which is the reason the boundary insists this be a control.
    override func performPrimaryAction() -> Bool {
        isExpanded.toggle()
        invalidateIntrinsicContentSize()
        needsDisplay = true
        return true
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityTitle() -> String? {
        let detail = detailLines().map(\.string).joined(separator: ", ")
        return detail.isEmpty ? "main thread \(statusText)" : "main thread \(statusText), \(detail)"
    }

    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    /// It reads as text and answers a press, so it names the hand rather than taking the base
    /// class's arrow.
    override var restingPointer: NSCursor? { .pointingHand }
}
