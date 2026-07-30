import AppKit

// MARK: - Usage Preferences

/// The Usage page: where the tokens went.
///
/// This is the question the toolbar's pill provokes and cannot answer. The pill says the week is
/// 85% spent; only the transcripts say *what spent it*, and only Threading can attribute them —
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
            sections.append(contentsOf: windowSections(report))
            sections.append(checkoutSection(report))
            if report.accounts.count > 1 {
                sections.append(accountSection(report))
            }
            sections.append(daySection(report))
            sections.append(modelSection(report))
        } else if !TranscriptUsageService.shared.isBuilding {
            sections.append(SettingsUI.note(UsageStrings.empty))
        }

        sections.append(SettingsUI.note(UsageStrings.footnote))

        let page = SettingsUI.page(sections, hostPage: .usage)
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
        total.applyFont(.heading)
        total.textColor = report == nil ? Design.Text.secondary : Design.Text.label

        let caption = NSTextField(labelWithString: summaryCaption(report))
        caption.applyFont(.subheading)
        caption.textColor = Design.Text.secondary

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

        var parts = [UsageStrings.turns(Self.number.string(from: NSNumber(value: report.turns)) ?? "")]

        if report.turns > 0 {
            parts.append(UsageStrings.perTurn(
                UsageFormat.tokens(report.billedTokens / Int64(report.turns))
            ))
        }

        // The cache ratio is the one number that says whether the spend was *avoidable*: reads
        // are the cheap path, and a high ratio means the conversation was mostly served from
        // cache rather than re-sent.
        if report.cachedTokens > 0 {
            let served = Double(report.cachedTokens)
                / Double(report.cachedTokens + report.billedTokens)
            parts.append(UsageStrings.cached(Int((served * 100).rounded())))
        }

        parts.append(UsageStrings.measured(
            Self.relativeDate.localizedString(for: report.builtAt, relativeTo: Date())
        ))

        return parts.joined(separator: " · ")
    }

    /// The windows the account is actually metered on, with what each has cost.
    ///
    /// This is the join the page existed without: the pill says a window is 85% spent, and the
    /// transcripts say what 85% *was* — 42.3M tokens over 1,204 turns. Neither source can state
    /// that alone, since the rate-limit API reports no tokens and the transcripts know nothing
    /// about windows.
    ///
    /// Per account, because windows are per account, and only for accounts that report any.
    private func windowSections(_ report: TranscriptUsageReport) -> [NSView] {
        AgentAccountDiscovery.accounts(for: .claude).compactMap { account in
            guard let usage = AccountUsageService.shared.usage(for: account),
                  !usage.windows.isEmpty else { return nil }

            let rows = usage.windows.compactMap { window -> NSView? in
                guard let started = windowStart(of: window) else { return nil }

                let spend = report.spend(since: started)
                let percent = window.percent.map { "\($0)%" } ?? UsageDefaults.unknownValue
                let resets = window.resetsAt.map { UsageFormat.resets(until: $0) } ?? ""

                return UsageBarRow(
                    title: "\(window.label) · \(percent)",
                    detail: [
                        UsageStrings.turns(
                            Self.number.string(from: NSNumber(value: spend.turns)) ?? ""
                        ),
                        resets
                    ]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                    value: UsageFormat.tokens(spend.billedTokens),
                    fraction: window.fraction ?? 0
                )
            }

            guard !rows.isEmpty else { return nil }

            return SettingsUI.section(
                UsageStrings.windows(AccountName.display(for: account)),
                SettingsCard(rows: rows)
            )
        }
    }

    /// When a window opened, worked back from its reset and its length — the reset is reported,
    /// the start is not.
    private func windowStart(of window: AccountUsage.Window) -> Date? {
        guard let resetsAt = window.resetsAt, let duration = window.windowDuration else {
            return nil
        }
        return resetsAt.addingTimeInterval(-duration)
    }

    private func accountSection(_ report: TranscriptUsageReport) -> NSView {
        let largest = report.accounts.first?.billedTokens ?? 1

        let rows = report.accounts.map { account in
            UsageBarRow(
                title: account.name,
                detail: nil,
                value: UsageFormat.tokens(account.billedTokens),
                fraction: Double(account.billedTokens) / Double(max(largest, 1))
            )
        }

        return SettingsUI.section(UsageStrings.byAccount, SettingsCard(rows: rows))
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
    static var title: String { L10n.string("Usage") }

    static var explanation: String {
        L10n.string("""
            What your conversations have cost, read from the agents' own transcripts. Grouped by \
            checkout, since a repository's worktrees are separate places doing separate work.
            """)
    }

    static var footnote: String {
        L10n.string("""
            Counts input, output and cache writes — the tokens a plan is charged for. Cache reads \
            are excluded: they are the cheap path and would drown everything else. A turn copied \
            forward by a resume, a compaction or a side chat is counted once, and subagent threads \
            are counted too, since their tokens appear in no other file. Claude only; Codex records \
            its usage differently.
            """)
    }

    static var empty: String { L10n.string("No usage recorded yet.") }
    static var notBuilt: String { L10n.string("Not measured yet") }
    static var building: String { L10n.string("Reading transcripts…") }
    static var rebuild: String { L10n.string("Rebuild") }

    static var byCheckout: String { L10n.string("By checkout") }
    static var byAccount: String { L10n.string("By account") }

    static func windows(_ account: String) -> String {
        L10n.format("Rate limits · %@", account)
    }
    static var byDay: String { L10n.string("By day") }
    static var byModel: String { L10n.string("By model") }

    static let checkoutLimit = 12
    static let modelLimit = 8

    static func turns(_ count: String) -> String { L10n.format("%@ turns", count) }
    static func perTurn(_ tokens: String) -> String { L10n.format("%@/turn", tokens) }
    static func cached(_ percent: Int) -> String {
        L10n.format("%lld%% served from cache", Int64(percent))
    }
    static func measured(_ relative: String) -> String {
        L10n.format("measured %@", relative)
    }
}
