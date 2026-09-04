import AppKit

/// One line of an account's rate-limit windows — `5h 43% · 7d 73%` — that would rather say
/// **fewer** of them than say one of them half.
///
/// # Why this is not a label
///
/// It was one, with `byTruncatingTail` and the lowest compression resistance on the row, on the
/// stated reasoning that the chips beside it name choices and are unreadable half-drawn while a
/// reading keeps its meaning as it loses characters. That reasoning is wrong about where a
/// reading's meaning lives: squeezed by twenty points, `5h 86% · 7d 41%` came out as `5h 86…`,
/// which has lost the `%` — the glyph that made the number a proportion — and says nothing at all
/// about the week. A tail-truncated reading is not a shorter reading; it is a number whose units
/// went missing, next to a window the reader cannot know was dropped.
///
/// So the unit that gives way is the **window**, never the character. Given room for one reading
/// it states one, complete; given room for none it draws nothing and leaves the row to the
/// controls, which is the honest form of "there is no space for this". Compact chrome has a
/// separate cardinality boundary from the virtual usage detail: it names at most three windows
/// and states the omitted count. A provider-sized inventory must not turn one toolbar label,
/// tooltip, or accessibility value into thousands of attributed runs.
///
/// The intrinsic width is always the **whole** line, which is what keeps the choice stable: the
/// view is handed `min(full, available)` by its row, so a window that widens hands it more and
/// the dropped reading comes back. Sizing to what it last drew would have been a ratchet — the
/// first squeeze would have been permanent.
///
/// The ink rule is the toolbar pill's (`AccountUsageItemView`), from the same formatter: the
/// window's name a tier below its value, and the value tinted only once a window is close enough
/// to its limit for the colour to mean something.
final class UsageReadingLabel: NSView, InkSourced {

    // MARK: - Properties

    let inkSource: InkSource
    private var themeRedraw: ThemeRedraw?

    /// A one-line reading has room for the common account pair plus one model-scoped limit.
    /// Complete provider inventories belong to the virtual usage popover.
    static let maximumReadings = 3

    /// The windows to state, in the order the line prints them.
    var readings: [AccountUsage.Reading] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// The same bounded projection the line draws. VoiceOver and tooltips state an omitted count
    /// instead of eagerly spelling a provider-sized inventory that cannot be acted on here.
    var plainValue: String {
        Self.plainSummary(readings: readings)
    }

    private var ink: Design.Ink { inkSource.ink }

    override var intrinsicContentSize: NSSize {
        guard !readings.isEmpty else { return NSSize(width: 0, height: 0) }
        let size = line(count: min(readings.count, Self.maximumReadings)).size()
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    // MARK: - Initialization

    init(inkSource: InkSource = .chrome) {
        self.inkSource = inkSource
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The row's pressure valve, exactly as the label it replaced was: the chips beside it
        // name choices, and a chip compressed to an ellipsis is a decision the user can no
        // longer read. This one has a graceful answer to being squeezed, so it goes first.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        themeRedraw = ThemeRedraw(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Drawing

    /// A width change is a *content* change here: it decides how many windows are stated. A
    /// layer-backed view is not repainted for a resize on its own, and the row this sits in
    /// resizes constantly — every pane drag, every chip that grows or shrinks beside it.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = drawableReadingCount(in: bounds.width)
        guard count > 0 else { return }

        // Unflipped, so the point given is the line's lower-left corner.
        let text = line(count: count)
        let size = text.size()
        text.draw(at: NSPoint(x: 0, y: ((bounds.height - size.height) / 2).rounded()))
    }

    /// How many complete readings fit the width on offer — the whole line where there is room,
    /// and zero rather than a fragment where there is not.
    ///
    /// Measured rather than budgeted: window names are one to three glyphs and values one to
    /// four, so a character count is not a width, and there are at most a handful of windows to
    /// try. Half a point of slack absorbs the difference between a measured line and the integral
    /// width a stack view hands out, which otherwise drops the last window of a line that fits.
    func drawableReadingCount(in width: CGFloat) -> Int {
        var fitting = 0
        for count in stride(
            from: min(readings.count, Self.maximumReadings),
            through: 1,
            by: -1
        )
        where line(count: count).size().width <= width + 0.5 {
            fitting = count
            break
        }
        return fitting
    }

    private func line(count: Int) -> NSAttributedString {
        let maximum = min(readings.count, Self.maximumReadings)
        return Self.summary(
            readings: Array(readings.prefix(count)),
            omittedCount: count == maximum ? readings.count - maximum : 0,
            ink: ink
        )
    }

    /// `5h 43% · 7d 73%`: each window as a quiet name and its value, the value tinted by that
    /// window's own severity.
    ///
    /// Shared with the toolbar pill rather than written twice, because the composer's line
    /// promises to be *the same reading the pill will go on showing* once the session exists —
    /// and two compositions of one sentence is how a promise like that quietly stops being true.
    /// Consumes `AccountUsage.Reading`, so the stale-value and severity rules stay the model's.
    static func summary(
        readings: [AccountUsage.Reading],
        ink: Design.Ink,
        statusGrounds: [NSColor] = []
    ) -> NSAttributedString {
        let visible = Array(readings.prefix(maximumReadings))
        return summary(
            readings: visible,
            omittedCount: readings.count - visible.count,
            ink: ink,
            statusGrounds: statusGrounds
        )
    }

    static func plainSummary(readings: [AccountUsage.Reading]) -> String {
        let visible = readings.prefix(maximumReadings).map { "\($0.name) \($0.value)" }
        let omitted = readings.count - visible.count
        return (visible + (omitted > 0 ? [L10n.format("%d more windows", omitted)] : []))
            .joined(separator: UsageDefaults.segmentSeparator)
    }

    private static func summary(
        readings: [AccountUsage.Reading],
        omittedCount: Int,
        ink: Design.Ink,
        statusGrounds: [NSColor] = []
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        func append(_ text: String, font: NSFont, color: NSColor) {
            result.append(NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color]
            ))
        }

        for (index, reading) in readings.enumerated() {
            if index > 0 {
                result.append(gap(Design.Spacing.small, font: Design.Typography.control()))
                append(
                    UsageDefaults.segmentMark,
                    font: Design.Typography.control(),
                    color: ink.tertiary
                )
                result.append(gap(Design.Spacing.small, font: Design.Typography.control()))
            }
            append(
                reading.name,
                font: Design.Typography.caption(),
                color: ink.tertiary
            )
            result.append(gap(Design.Spacing.tight, font: Design.Typography.caption()))
            append(
                reading.value,
                font: Design.Typography.control(),
                color: valueColor(
                    for: reading.severity,
                    ink: ink,
                    statusGrounds: statusGrounds
                )
            )
        }

        if omittedCount > 0 {
            result.append(gap(Design.Spacing.small, font: Design.Typography.control()))
            append(
                UsageDefaults.segmentMark,
                font: Design.Typography.control(),
                color: ink.tertiary
            )
            result.append(gap(Design.Spacing.small, font: Design.Typography.control()))
            append(
                L10n.format("%d more windows", omittedCount),
                font: Design.Typography.caption(),
                color: ink.tertiary
            )
        }

        return result
    }

    /// The value and ring share one semantic tint. Normal usage stays in the supplied ink;
    /// pressure keeps its status hue, adjusted only when a component names an additional face
    /// that the ordinary chrome status role was not measured against.
    static func valueColor(
        for severity: UsageSeverity,
        ink: Design.Ink,
        statusGrounds: [NSColor] = []
    ) -> NSColor {
        guard severity != .normal else { return ink.secondary }
        return statusGrounds.reduce(severity.glyphColor) { color, ground in
            color.legible(on: ground, ratio: LabelLegibility.Defaults.readingRatio)
        }
    }

    /// One space, set to the width the design system asked for rather than the width the font
    /// happens to give it.
    ///
    /// A space is not a spacing token. At caption size the one between `5h` and `86%` measured
    /// barely three points while the separator's own spaces measured three and a third, so
    /// `5h 86% · 7d 41%` stood at four near-equal gaps: the line read as four loose tokens
    /// instead of two readings, and the pair that belongs together was the tightest thing on
    /// the row. It was reported as exactly that.
    ///
    /// The gap is a `.kern` on a real space rather than a substituted glyph, so `plainValue`,
    /// the accessibility value and every test that reads the composed string still see the
    /// sentence they always did — only its metrics changed. `max(0, …)` keeps a font whose
    /// space is already wider than the token from being pulled backwards into a collision.
    private static func gap(_ width: CGFloat, font: NSFont) -> NSAttributedString {
        let space = NSAttributedString(string: " ", attributes: [.font: font])
        return NSAttributedString(
            string: " ",
            attributes: [.font: font, .kern: max(0, width - space.size().width)]
        )
    }

    // MARK: - Accessibility

    /// The whole reading, however much of it the row had room to draw.
    override func isAccessibilityElement() -> Bool { !readings.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { plainValue }
    override func accessibilityLabel() -> String? { L10n.string("Usage") }
}
