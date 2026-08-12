import AppKit

// MARK: - Project Stats Popover

/// The hover popover for a project row: what the code is made of and how recently it moves.
///
/// The session popover answers "what is this conversation"; this one answers "what is this
/// codebase" — composition, size, and a bounded twelve-week Git activity glance. The source
/// counter is bundled with Threading; no package-manager state leaks into this presentation.
final class ProjectStatsPopoverViewController: NSViewController {

    // MARK: - Info

    @MainActor
    struct Info {
        let projectName: String
        let stats: CodeStats
        let bar: CodeStatsBar
        let activity: ProjectActivity?
        let measuredAt: Date

        /// Built from the service's cache; nil when there is nothing to show, which is the
        /// row's cue not to present at all.
        init?(project: Project) {
            let service = ProjectStatsService.shared
            guard let stats = service.stats(for: project.id),
                  !stats.isEmpty,
                  let codeMeasuredAt = service.codeMeasuredAt(for: project.id)
            else { return nil }

            let activity = service.activity(for: project.id)
            let measuredAt = activity
                .flatMap { _ in service.activityMeasuredAt(for: project.id) }
                .map { min(codeMeasuredAt, $0) }
                ?? codeMeasuredAt
            self.init(
                projectName: project.name,
                stats: stats,
                activity: activity,
                measuredAt: measuredAt
            )
        }

        /// The direct form, which is what lets the render tests feed a synthetic reading.
        init(
            projectName: String,
            stats: CodeStats,
            activity: ProjectActivity? = nil,
            measuredAt: Date
        ) {
            self.projectName = projectName
            self.stats = stats
            self.bar = CodeStatsBar.make(from: stats)
            self.activity = activity
            self.measuredAt = measuredAt
        }
    }

    // MARK: - Properties

    private let info: Info
    /// The ordinary controller owns its popover width and insets. When it becomes the native
    /// `.proceed` content of a customizable presentation, the outer host owns that chrome.
    private let isEmbedded: Bool

    private static let count: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Initialization

    init(info: Info, isEmbedded: Bool = false) {
        self.info = info
        self.isEmbedded = isEmbedded
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let rows = NSStackView(views: makeStatsRows(info))
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Design.Spacing.small
        rows.translatesAutoresizingMaskIntoConstraints = false
        let inset = isEmbedded ? 0 : Design.Spacing.inset
        rows.edgeInsets = NSEdgeInsets(
            top: inset, left: inset,
            bottom: inset, right: inset
        )

        let container = NSView()
        container.addSubview(rows)

        // Pinned, not capped, for the same reason as the session popover: everything inside
        // is compressible, so a mere maximum collapses to the narrowest fitting column.
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: container.topAnchor),
            rows.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(
                equalToConstant: isEmbedded
                    ? ProjectPopoverDefaults.contentWidth
                    : ProjectPopoverDefaults.width
            )
        ])

        view = container
    }

    // MARK: - Private Methods

    private func makeStatsRows(_ info: Info) -> [NSView] {
        let summary = NSTextField(labelWithString: summaryLine(for: info))
        summary.applyFont(.subheading)
        summary.textColor = Design.Text.secondary

        let bar = CodeStatsBarView(bar: info.bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(
            equalToConstant: ProjectPopoverDefaults.width - 2 * Design.Spacing.inset
        ).isActive = true
        bar.heightAnchor.constraint(equalToConstant: CodeStatsBarDefaults.height).isActive = true

        var rows: [NSView] = [nameLabel(info.projectName), summary, bar]
        rows.append(contentsOf: info.bar.segments.map(legendRow(for:)))
        if let activity = info.activity {
            rows.append(contentsOf: activityRows(activity))
        }

        let age = NSTextField(labelWithString: agedLine(for: info))
        age.applyFont(.subheading)
        age.textColor = Design.Text.tertiary
        rows.append(age)

        return rows
    }

    private func nameLabel(_ projectName: String) -> NSTextField {
        let name = NSTextField(labelWithString: projectName)
        name.applyFont(.control)
        name.textColor = Design.Text.label
        name.lineBreakMode = .byTruncatingTail
        return name
    }

    /// One legend row: the segment's dot, its name, and its share pushed to the far edge.
    private func legendRow(for segment: CodeStatsBar.Segment) -> NSView {
        let dot = CodeStatsLegendDot(segment: segment)

        let name = NSTextField(labelWithString: segment.name)
        name.applyFont(.subheading)
        name.textColor = Design.Text.secondary
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The one view that absorbs the row's slack, so the values sit at the trailing edge
        // and read as a column down the legend.
        name.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let value = NSTextField(labelWithString: valueLine(for: segment))
        value.applyFont(.numericDetail())
        value.textColor = Design.Text.tertiary
        value.setContentHuggingPriority(.required, for: .horizontal)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [dot, name, value])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(
            equalToConstant: ProjectPopoverDefaults.width - 2 * Design.Spacing.inset
        ).isActive = true

        return stack
    }

    /// A semantic label and exact count flank the compact trend. The chart stays supplemental:
    /// VoiceOver receives a complete sentence, and a capped history omits bars rather than
    /// drawing the newest 20,000 commits as if they represented the whole window.
    private func activityRows(_ activity: ProjectActivity) -> [NSView] {
        let title = NSTextField(labelWithString: L10n.string("Recent activity"))
        title.applyFont(.subheading)
        title.textColor = Design.Text.secondary
        title.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let count = NSTextField(labelWithString: activityCount(activity))
        count.applyFont(.numericDetail())
        count.textColor = Design.Text.tertiary
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        let heading = NSStackView(views: [title, count])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.distribution = .fill
        heading.spacing = Design.Spacing.small
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.widthAnchor.constraint(equalToConstant: ProjectPopoverDefaults.contentWidth).isActive = true

        var rows: [NSView] = [heading]
        if !activity.isTruncated, activity.latestCommitAt != nil {
            let sparkline = ThemedBarSparklineView(
                values: activity.weeklyCommits.map(Double.init),
                accessibilityLabel: activityAccessibilityLabel(activity)
            )
            sparkline.widthAnchor.constraint(
                equalToConstant: ProjectPopoverDefaults.contentWidth
            ).isActive = true
            rows.append(sparkline)
        }

        let latest = NSTextField(labelWithString: latestCommitLine(activity))
        latest.applyFont(.subheading)
        latest.textColor = Design.Text.tertiary
        rows.append(latest)
        return rows
    }

    // MARK: - Text

    private func summaryLine(for info: Info) -> String {
        let code = Self.count.string(from: NSNumber(value: info.stats.totalCode)) ?? ""
        let files = Self.count.string(from: NSNumber(value: info.stats.totalFiles)) ?? ""
        return "\(code) lines of code · \(files) files"
    }

    private func valueLine(for segment: CodeStatsBar.Segment) -> String {
        let lines = Self.count.string(from: NSNumber(value: segment.code)) ?? ""
        return "\(percent(segment.fraction)) · \(lines)"
    }

    /// Whole percentages; a share that rounds to nothing still says it exists.
    private func percent(_ fraction: CGFloat) -> String {
        let rounded = Int((fraction * 100).rounded())
        return rounded == 0 ? "<1%" : "\(rounded)%"
    }

    private func agedLine(for info: Info) -> String {
        L10n.format(
            "Updated %@",
            Self.relativeDate.localizedString(for: info.measuredAt, relativeTo: Date())
        )
    }

    private func activityCount(_ activity: ProjectActivity) -> String {
        let formatted = Self.count.string(
            from: NSNumber(value: ProjectActivity.maximumCommitCount)
        ) ?? "20,000"
        if activity.isTruncated {
            return L10n.format("Past 12 weeks · %@+ commits", formatted)
        }

        let count = Self.count.string(from: NSNumber(value: activity.commitCount)) ?? ""
        let key = activity.commitCount == 1
            ? "Past 12 weeks · %@ commit"
            : "Past 12 weeks · %@ commits"
        return L10n.format(key, count)
    }

    private func latestCommitLine(_ activity: ProjectActivity) -> String {
        guard let latest = activity.latestCommitAt else {
            return L10n.string("No commits yet")
        }
        return L10n.format(
            "Latest commit %@",
            Self.relativeDate.localizedString(for: latest, relativeTo: Date())
        )
    }

    private func activityAccessibilityLabel(_ activity: ProjectActivity) -> String {
        let values = activity.weeklyCommits
            .map { Self.count.string(from: NSNumber(value: $0)) ?? "0" }
            .joined(separator: ", ")
        return L10n.format(
            "Commits in each of the past 12 weeks, oldest to newest: %@",
            values
        )
    }
}

// MARK: - Legend Dot

/// The legend's colour swatch, resolving through the same table as the bar so the two cannot
/// disagree. Drawn, not a frozen layer colour, for the usual reason.
private final class CodeStatsLegendDot: NSView {

    private let segment: CodeStatsBar.Segment
    private var themeRedraw: ThemeRedraw?

    init(segment: CodeStatsBar.Segment) {
        self.segment = segment
        super.init(frame: .zero)
        themeRedraw = ThemeRedraw(self)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ProjectPopoverDefaults.dotSize, height: ProjectPopoverDefaults.dotSize)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        CodeStatsBarView.color(for: segment).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

// MARK: - Project Popover Defaults

enum ProjectPopoverDefaults {
    /// The session popover's width, on purpose: the two hang off neighbouring rows.
    static let width: CGFloat = SessionPopoverDefaults.width
    static let contentWidth = width - 2 * Design.Spacing.inset

    static let dotSize: CGFloat = 7
}
