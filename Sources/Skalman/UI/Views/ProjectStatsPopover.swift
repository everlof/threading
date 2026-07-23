import AppKit

// MARK: - Project Stats Popover

/// The hover popover for a project row: what the project's code is made of.
///
/// The session popover answers "what is this conversation"; this one answers "what is this
/// codebase" — the composition bar, the languages behind it, and how big the whole thing is.
///
/// With scc known to be absent it answers with the install hint instead: a feature whose
/// only trace is a popover that never appears cannot be discovered, so the one moment the
/// user is already asking the question is where the answer "install scc" belongs. A project
/// merely not counted *yet* still shows nothing — "not looked" is not "not installed".
final class ProjectStatsPopoverViewController: NSViewController {

    // MARK: - Content

    /// What the popover has to say: a reading, or how to get one.
    private enum Content {
        case stats(Info)
        case missingTool(projectName: String)
    }

    // MARK: - Info

    @MainActor
    struct Info {
        let projectName: String
        let stats: CodeStats
        let bar: CodeStatsBar
        let measuredAt: Date

        /// Built from the service's cache; nil when there is nothing to show, which is the
        /// row's cue not to present at all.
        init?(project: Project) {
            guard let stats = CodeStatsService.shared.stats(for: project.id),
                  !stats.isEmpty,
                  let measuredAt = CodeStatsService.shared.measuredAt(for: project.id)
            else { return nil }

            self.init(projectName: project.name, stats: stats, measuredAt: measuredAt)
        }

        /// The direct form, which is what lets the render tests feed a synthetic reading.
        init(projectName: String, stats: CodeStats, measuredAt: Date) {
            self.projectName = projectName
            self.stats = stats
            self.bar = CodeStatsBar.make(from: stats)
            self.measuredAt = measuredAt
        }
    }

    // MARK: - Properties

    private let content: Content

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

    init(info: Info) {
        self.content = .stats(info)
        super.init(nibName: nil, bundle: nil)
    }

    init(missingToolFor projectName: String) {
        self.content = .missingTool(projectName: projectName)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let rows = NSStackView(views: makeRows())
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Design.Spacing.small
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.inset, left: Design.Spacing.inset,
            bottom: Design.Spacing.inset, right: Design.Spacing.inset
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
            container.widthAnchor.constraint(equalToConstant: ProjectPopoverDefaults.width)
        ])

        view = container
    }

    // MARK: - Private Methods

    private func makeRows() -> [NSView] {
        switch content {
        case .stats(let info): return makeStatsRows(info)
        case .missingTool(let projectName): return makeMissingToolRows(projectName)
        }
    }

    private func makeStatsRows(_ info: Info) -> [NSView] {
        let summary = NSTextField(labelWithString: summaryLine(for: info))
        summary.font = Design.Typography.subheading()
        summary.textColor = Design.Text.secondary

        let bar = CodeStatsBarView(bar: info.bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(
            equalToConstant: ProjectPopoverDefaults.width - 2 * Design.Spacing.inset
        ).isActive = true
        bar.heightAnchor.constraint(equalToConstant: CodeStatsBarDefaults.height).isActive = true

        var rows: [NSView] = [nameLabel(info.projectName), summary, bar]
        rows.append(contentsOf: info.bar.segments.map(legendRow(for:)))

        let age = NSTextField(labelWithString: agedLine(for: info))
        age.font = Design.Typography.subheading()
        age.textColor = Design.Text.tertiary
        rows.append(age)

        return rows
    }

    /// The install hint: what would be here, the one command that gets it, and that nothing
    /// more is needed afterwards — the service re-probes on its own, so there is no button.
    private func makeMissingToolRows(_ projectName: String) -> [NSView] {
        let explains = NSTextField(wrappingLabelWithString: ProjectPopoverDefaults.missingToolExplanation)
        explains.font = Design.Typography.subheading()
        explains.textColor = Design.Text.secondary
        explains.preferredMaxLayoutWidth = ProjectPopoverDefaults.width - 2 * Design.Spacing.inset
        explains.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let command = NSTextField(labelWithString: ProjectPopoverDefaults.installCommand)
        command.font = Design.Typography.code()
        command.textColor = Design.Text.label

        let heals = NSTextField(labelWithString: ProjectPopoverDefaults.missingToolPromise)
        heals.font = Design.Typography.subheading()
        heals.textColor = Design.Text.tertiary

        return [nameLabel(projectName), explains, command, heals]
    }

    private func nameLabel(_ projectName: String) -> NSTextField {
        let name = NSTextField(labelWithString: projectName)
        name.font = Design.Typography.control()
        name.textColor = Design.Text.label
        name.lineBreakMode = .byTruncatingTail
        return name
    }

    /// One legend row: the segment's dot, its name, and its share pushed to the far edge.
    private func legendRow(for segment: CodeStatsBar.Segment) -> NSView {
        let dot = CodeStatsLegendDot(segment: segment)

        let name = NSTextField(labelWithString: segment.name)
        name.font = Design.Typography.subheading()
        name.textColor = Design.Text.secondary
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The one view that absorbs the row's slack, so the values sit at the trailing edge
        // and read as a column down the legend.
        name.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let value = NSTextField(labelWithString: valueLine(for: segment))
        value.font = Design.Typography.numericDetail()
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
        "Counted \(Self.relativeDate.localizedString(for: info.measuredAt, relativeTo: Date()))"
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

    static let dotSize: CGFloat = 7

    /// The install hint, in three lines: what is absent, the command, the promise. The
    /// command is Homebrew's because that is the one package manager a macOS user can be
    /// assumed a single line away from.
    static let missingToolExplanation = "Code statistics are counted by scc, which is not installed."
    static let installCommand = "brew install scc"
    static let missingToolPromise = "Counts appear on their own once it is."
}
