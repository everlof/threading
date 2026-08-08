import AppKit

// MARK: - Usage Window Grid View

/// The same working day, twice: once with its first window opened by the first message, and once
/// with it opened early on purpose.
///
/// This exists because the argument does not survive being written down. "Opening the window two
/// hours before you start pulls a third reset into the day" is four clauses and a claim, and the
/// reader has to take it on trust. Two rows of blocks make the same point in one look: the second
/// row starts further left, is broken one more time, and has more of it filled in.
///
/// **A block is a window and the gaps between them are the resets.** Filled means working with
/// allowance to spend; empty means the window is open and nothing is being spent, whether because
/// it is exhausted or because nobody has sat down yet. Two states, not three — which state an
/// empty stretch *is* comes from where it sits relative to the day-start rule, and that is what
/// the rule is for.
///
/// **Every surface here is drawn by `ThemedSurface`**, so a window block is a trough in whatever
/// the current material says a trough is: flat with a hairline edge on the modern themes, a
/// sunken bevel under Platinum and Win98, and filled with chunks rather than a smooth bar wherever
/// the theme's progress style is segmented. Workbench's authored gauge keeps a continuous fill
/// from its active title blue instead. The first version drew its own 1pt border and its own
/// corner radius, which is how a diagram ends up looking like it came from another app.
final class UsageWindowGridView: NSView {

    // MARK: - Lane

    private struct Lane {
        let title: String
        let outlook: UsageWindowPlan.Outlook
        let isPoked: Bool
    }

    // MARK: - Properties

    private var workday: DateInterval?
    private var span: DateInterval?
    private var lanes: [Lane] = []
    private var themeRedraw: ThemeRedraw?

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter
    }()

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: UsageWindowGridDefaults.height)
    }

    // MARK: - Public Methods

    /// Draws the comparison for one working day.
    ///
    /// The burn is the input everything else follows from, so a caller with a measured one passes
    /// it and a caller without passes the assumption — the picture is honest either way, and the
    /// caption beside it says which was used.
    func show(workday: DateInterval, burn: TimeInterval, windowLength: TimeInterval) {
        let comparison = UsageWindowPlan.comparison(
            workday: workday,
            burn: burn,
            windowLength: windowLength
        )
        let lead = UsageWindowPlan.lead(burn: burn, windowLength: windowLength)

        self.workday = workday
        self.span = DateInterval(
            start: workday.start.addingTimeInterval(-lead),
            end: workday.end
        )
        self.lanes = [
            Lane(
                title: UsageWindowGridStrings.unpoked,
                outlook: comparison.unpoked,
                isPoked: false
            ),
            Lane(
                title: UsageWindowGridStrings.poked(
                    at: Self.time.string(from: workday.start.addingTimeInterval(-lead))
                ),
                outlook: comparison.poked,
                isPoked: true
            )
        ]

        setAccessibilityLabel(accessibilityDescription())
        needsDisplay = true
    }

    // MARK: - Drawing

    /// Three columns — label, plot, total — because the first version put the labels *above* the
    /// bars and had nowhere to run the day-start rule that did not cross a word. A column layout
    /// leaves the plot a clean rectangle, which is what lets one rule serve both lanes.
    override func draw(_ dirtyRect: NSRect) {
        guard let span, span.duration > 0, !lanes.isEmpty else { return }

        let labelWidth = UsageWindowGridDefaults.labelColumnWidth
        let totalWidth = UsageWindowGridDefaults.totalColumnWidth
        let plot = NSRect(
            x: labelWidth,
            y: UsageWindowGridDefaults.axisHeight,
            width: max(bounds.width - labelWidth - totalWidth, 1),
            height: bounds.height - UsageWindowGridDefaults.axisHeight
        )

        // Behind the blocks, running the plot's full height: where it is covered it is covered by
        // a window that was already open at that moment, which is exactly the thing being shown.
        drawDayStartRule(in: plot, span: span)

        var top = plot.maxY
        for lane in lanes {
            let bar = NSRect(
                x: plot.minX,
                y: top - UsageWindowGridDefaults.barHeight,
                width: plot.width,
                height: UsageWindowGridDefaults.barHeight
            )

            drawLabel(lane.title, besideBar: bar, width: labelWidth)
            drawTotal(for: lane, besideBar: bar, width: totalWidth)
            drawWindows(lane.outlook, in: bar, span: span)

            top -= UsageWindowGridDefaults.barHeight + UsageWindowGridDefaults.laneGap
        }
    }

    /// One lane's windows: a themed trough per window, filled where the day was productive.
    private func drawWindows(
        _ outlook: UsageWindowPlan.Outlook,
        in rect: NSRect,
        span: DateInterval
    ) {
        let progressStyle = AppThemePalette.current
            .material(for: effectiveAppearance)
            .progressStyle
        let isSegmented = progressStyle == .segmented
        let isWorkbench = progressStyle == .amiga
        let isIRIX = progressStyle == .irix
        let progressTint = isWorkbench
            ? (WindowChromeAppearance.resolve()?.activeGradient.colors.first
                ?? Design.Surface.accent)
            : Design.Surface.accent

        for window in outlook.windows {
            guard let block = self.rect(for: window.interval, in: rect, span: span),
                  block.width > 0 else { continue }

            if isIRIX {
                let fraction: CGFloat
                if let productive = window.productive,
                   let fill = self.rect(for: productive, in: rect, span: span),
                   fill.width > 0 {
                    fraction = min(max((fill.maxX - block.minX) / block.width, 0), 1)
                } else {
                    fraction = 0
                }
                ThemedProgressDrawing.drawIRIX(
                    in: block,
                    fraction: Double(fraction),
                    tint: progressTint
                )
                continue
            }

            // The theme decides the edge: a bevel material bevels it and ignores the border, a
            // flat one strokes the hairline. Either way the block cannot end up with a treatment
            // this file invented.
            let trough = ThemedSurface.draw(
                block,
                fill: Design.Surface.controlResting,
                border: Design.Surface.border,
                bevel: .sunken
            )

            guard let productive = window.productive,
                  let fill = self.rect(for: productive, in: rect, span: span),
                  fill.width > 0 else { continue }

            // Clipped to the trough it sits in, so the fill's ends are capped by the trough's own
            // corners rather than by a radius computed a second time here.
            NSGraphicsContext.saveGraphicsState()
            trough.inset(by: UsageWindowGridDefaults.fillInset).path.addClip()

            if isSegmented {
                ThemedProgressDrawing.drawSegments(in: fill, tint: progressTint)
            } else {
                progressTint.setFill()
                fill.fill()
            }

            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The rule where the working day begins. Anything left of it is a window that was open
    /// before anybody sat down, which is the whole mechanism in one vertical line.
    private func drawDayStartRule(in plot: NSRect, span: DateInterval) {
        guard let workday else { return }

        let x = plot.minX + plot.width * CGFloat(
            workday.start.timeIntervalSince(span.start) / span.duration
        )
        guard x > plot.minX + 0.5 else { return }

        Design.Surface.divider.setFill()
        NSRect(
            x: x - UsageWindowGridDefaults.ruleWidth / 2,
            y: plot.minY,
            width: UsageWindowGridDefaults.ruleWidth,
            height: plot.height
        ).fill()

        // Centred in the axis band rather than sitting on its floor: a period theme's caption is
        // a taller face than the system one, and drawn at y=0 Platinum's lost its descenders off
        // the bottom of the view.
        let label = NSAttributedString(
            string: UsageWindowGridStrings.dayStarts(Self.time.string(from: workday.start)),
            attributes: attributes(color: Design.Text.tertiary)
        )
        label.draw(at: NSPoint(
            x: x + Design.Spacing.tight,
            y: max(0, (UsageWindowGridDefaults.axisHeight - label.size().height) / 2)
        ))
    }

    private func drawLabel(_ title: String, besideBar bar: NSRect, width: CGFloat) {
        let text = NSAttributedString(
            string: title,
            attributes: attributes(color: Design.Text.secondary)
        )
        draw(
            text: title,
            attributes: attributes(color: Design.Text.secondary),
            at: NSPoint(
                x: max(0, width - Design.Spacing.medium - text.size().width),
                y: bar.midY - text.size().height / 2
            )
        )
    }

    /// The productive total, and on the poked lane what it gained. The delta is the number the
    /// picture exists to produce, so it is the one in the accent colour.
    private func drawTotal(for lane: Lane, besideBar bar: NSRect, width: CGFloat) {
        let text = NSMutableAttributedString(
            string: UsageWindowGridStrings.productive(
                UsageFormat.duration(lane.outlook.productiveTime)
            ),
            attributes: attributes(color: Design.Text.secondary)
        )

        let baseline = lanes.first?.outlook.productiveTime ?? 0
        let gained = lane.outlook.productiveTime - baseline
        if lane.isPoked, gained > 0 {
            text.append(NSAttributedString(
                string: UsageWindowGridDefaults.totalSeparator,
                attributes: attributes(color: Design.Text.secondary)
            ))
            text.append(NSAttributedString(
                string: UsageWindowGridStrings.gained(UsageFormat.duration(gained)),
                attributes: attributes(color: Design.Surface.accent)
            ))
        }

        text.draw(at: NSPoint(
            x: bounds.width - width + Design.Spacing.medium,
            y: bar.midY - text.size().height / 2
        ))
    }

    // MARK: - Geometry

    /// Where an interval lands inside the plot, or nil when it falls outside the drawn span.
    private func rect(
        for interval: DateInterval,
        in rect: NSRect,
        span: DateInterval
    ) -> NSRect? {
        guard let visible = interval.intersection(with: span), visible.duration > 0 else {
            return nil
        }

        let scale = rect.width / CGFloat(span.duration)
        let x = CGFloat(visible.start.timeIntervalSince(span.start)) * scale
        let width = CGFloat(visible.duration) * scale

        return NSRect(
            x: rect.minX + x,
            y: rect.minY,
            width: width,
            height: rect.height
        )
    }

    private func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: Design.FontRole.caption.resolved(), .foregroundColor: color]
    }

    private func draw(
        text: String,
        attributes: [NSAttributedString.Key: Any],
        at origin: NSPoint
    ) {
        NSAttributedString(string: text, attributes: attributes).draw(at: origin)
    }

    // MARK: - Accessibility

    /// The picture in words, because the difference between the two rows is carried by fill and
    /// by one extra break — neither of which survives being read aloud.
    private func accessibilityDescription() -> String {
        lanes.map { lane in
            UsageWindowGridStrings.laneDescription(
                lane.title,
                windows: lane.outlook.windows.filter { $0.productive != nil }.count,
                productive: UsageFormat.duration(lane.outlook.productiveTime),
                waiting: UsageFormat.duration(lane.outlook.cappedTime)
            )
        }
        .joined(separator: " ")
    }
}

// MARK: - Usage Window Grid Strings

private enum UsageWindowGridStrings {
    static var unpoked: String { L10n.string("Without a poke") }

    static func poked(at time: String) -> String {
        L10n.format("Poked at %@", time)
    }

    static func dayStarts(_ time: String) -> String {
        L10n.format("you start %@", time)
    }

    static func productive(_ duration: String) -> String {
        L10n.format("%@ working", duration)
    }

    static func gained(_ duration: String) -> String {
        L10n.format("+%@", duration)
    }

    static func laneDescription(
        _ title: String,
        windows: Int,
        productive: String,
        waiting: String
    ) -> String {
        L10n.format(
            "%@: %lld windows used, %@ working, %@ waiting.",
            title,
            Int64(windows),
            productive,
            waiting
        )
    }
}

// MARK: - Usage Window Grid Defaults

enum UsageWindowGridDefaults {
    /// A window block is as tall as the classic progress bar it becomes under a segmented
    /// material, so switching themes changes the treatment and not the layout.
    static let barHeight = ThemedProgressDrawing.classicHeight

    static let laneGap: CGFloat = 20

    /// Room under the plot for the day-start label, sized for the tallest caption face a theme
    /// ships rather than for the system one.
    static let axisHeight: CGFloat = 22
    static let height: CGFloat = barHeight * 2 + laneGap + axisHeight

    /// The two text columns. Wide enough for `Without a poke` and `7h working  +1h` at the
    /// caption size, which are the longest strings either column takes.
    static let labelColumnWidth: CGFloat = 118
    static let totalColumnWidth: CGFloat = 120

    /// How far inside its trough a fill is clipped, so a bevel keeps its inner edge.
    static let fillInset: CGFloat = 1

    static let ruleWidth: CGFloat = 1

    /// Between the total and the gain beside it. Layout rather than copy, so the gain's own
    /// string stays a key a translator can read.
    static let totalSeparator = "  "
}
