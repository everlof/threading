import AppKit

// MARK: - Usage Preferences

/// The Usage page: where the tokens went.
///
/// This is the question the toolbar's pill provokes and cannot answer. The pill says the week is
/// 85% spent; only the transcripts say *what spent it*, and only Skalman can attribute them —
/// no API knows which conversation ran in which of a repository's worktrees.
///
/// Checkouts lead, for the same reason they lead on the Storage page: a repository's worktrees
/// are separate places doing separate work, and "sonda" alone hides which of six it was.
final class UsagePreferencesViewController: NSViewController {

    // MARK: - Properties

    private let appEvents = AppEventObservations()

    private static let number: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        appEvents.observe(TranscriptUsageDidChange.self) { [weak self] _ in
            self?.rebuild()
        }
    }

    /// Draws the cached report, then rebuilds it if it has aged out. Never blocks on the walk:
    /// it takes the better part of a minute over a few thousand transcripts.
    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()
        TranscriptUsageService.shared.refresh()
    }

    // MARK: - Build

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }

        let report = TranscriptUsageService.shared.report

        var sections: [NSView] = [
            SettingsUI.heading(UsageStrings.title),
            SettingsUI.note(UsageStrings.explanation),
            summarySection(report)
        ]

        if let report, !report.checkouts.isEmpty {
            sections.append(checkoutSection(report))
            sections.append(daySection(report))
            sections.append(modelSection(report))
        } else if !TranscriptUsageService.shared.isBuilding {
            sections.append(SettingsUI.note(UsageStrings.empty))
        }

        sections.append(SettingsUI.note(UsageStrings.footnote))

        let page = SettingsUI.page(sections)
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func summarySection(_ report: TranscriptUsageReport?) -> NSView {
        let total = NSTextField(labelWithString: UsageFormat.tokens(report?.billedTokens ?? 0))
        total.font = Design.Typography.heading()
        total.textColor = report == nil ? .secondaryLabelColor : .labelColor

        let caption = NSTextField(labelWithString: summaryCaption(report))
        caption.font = Design.Typography.subheading()
        caption.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [total, caption])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.addArrangedSubview(labels)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(
            SettingsUI.button(UsageStrings.rebuild, target: self, action: #selector(rebuildClicked))
        )

        return SettingsUI.section(nil, SettingsCard(rows: [SettingsUI.fullRow(row)]))
    }

    private func summaryCaption(_ report: TranscriptUsageReport?) -> String {
        if TranscriptUsageService.shared.isBuilding { return UsageStrings.building }
        guard let report else { return UsageStrings.notBuilt }

        return UsageStrings.turns(Self.number.string(from: NSNumber(value: report.turns)) ?? "")
            + " · "
            + UsageStrings.measured(
                Self.relativeDate.localizedString(for: report.builtAt, relativeTo: Date())
            )
    }

    /// Checkouts, largest first, each with a bar so the shares read without arithmetic.
    private func checkoutSection(_ report: TranscriptUsageReport) -> NSView {
        let top = report.checkouts.prefix(UsageStrings.checkoutLimit)
        let largest = top.first?.billedTokens ?? 1

        let rows = top.map { checkout in
            UsageBarRow(
                title: checkout.label,
                detail: UsageStrings.turns(
                    Self.number.string(from: NSNumber(value: checkout.turns)) ?? ""
                ),
                value: UsageFormat.tokens(checkout.billedTokens),
                fraction: Double(checkout.billedTokens) / Double(max(largest, 1))
            )
        }

        return SettingsUI.section(UsageStrings.byCheckout, SettingsCard(rows: rows))
    }

    private func daySection(_ report: TranscriptUsageReport) -> NSView {
        let days = report.recentDays
        let largest = days.map(\.billedTokens).max() ?? 1

        let rows = days.reversed().map { day in
            UsageBarRow(
                title: day.name,
                detail: nil,
                value: UsageFormat.tokens(day.billedTokens),
                fraction: Double(day.billedTokens) / Double(max(largest, 1))
            )
        }

        return SettingsUI.section(UsageStrings.byDay, SettingsCard(rows: rows))
    }

    private func modelSection(_ report: TranscriptUsageReport) -> NSView {
        let largest = report.models.first?.billedTokens ?? 1

        let rows = report.models.prefix(UsageStrings.modelLimit).map { model in
            UsageBarRow(
                title: model.name,
                detail: nil,
                value: UsageFormat.tokens(model.billedTokens),
                fraction: Double(model.billedTokens) / Double(max(largest, 1))
            )
        }

        return SettingsUI.section(UsageStrings.byModel, SettingsCard(rows: rows))
    }

    // MARK: - Actions

    @objc private func rebuildClicked() {
        TranscriptUsageService.shared.refresh(force: true)
    }
}

// MARK: - Usage Strings

private enum UsageStrings {
    static let title = "Usage"

    static let explanation = """
        What your conversations have cost, read from the agents' own transcripts. Grouped by \
        checkout, since a repository's worktrees are separate places doing separate work.
        """

    static let footnote = """
        Counts input, output and cache writes — the tokens a plan is charged for. Cache reads \
        are excluded: they are the cheap path and would drown everything else. A turn copied \
        forward by a resume, a compaction or a side chat is counted once, and subagent threads \
        are counted too, since their tokens appear in no other file. Claude only; Codex records \
        its usage differently.
        """

    static let empty = "No usage recorded yet."
    static let notBuilt = "Not measured yet"
    static let building = "Reading transcripts…"
    static let rebuild = "Rebuild"

    static let byCheckout = "By checkout"
    static let byDay = "By day"
    static let byModel = "By model"

    static let checkoutLimit = 12
    static let modelLimit = 8

    static func turns(_ count: String) -> String { "\(count) turns" }
    static func measured(_ relative: String) -> String { "measured \(relative)" }
}
