import AppKit

/// The walkthrough's third page: every conversation the discovered accounts hold, one flat
/// list newest first, with the last two days pre-checked.
///
/// The folders a conversation ran in are deliberately not shown — a wall of checkout paths is
/// project bookkeeping the user has not opted into yet. Continue performs the import: each
/// checked conversation's folder becomes (or reuses) a project implicitly, and the checked
/// conversations are adopted resumable, the same records `ProjectStore.importSessions` writes
/// for the import sheet. Skip performs nothing; every conversation stays importable later from
/// its project's composer.
final class OnboardingImportPageViewController: NSViewController, OnboardingPage {

    private enum Layout {
        static let contentWidth: CGFloat = 620
        static let iconSide: CGFloat = 16
    }

    var pageTitle: String { L10n.string("Conversations") }
    var skipTitle: String? { L10n.string("Skip for now") }

    private static let relativeDate = RelativeDateTimeFormatter()

    /// One folder's live selection state — invisible in the list, but still the unit the
    /// import creates projects from.
    @MainActor
    private final class Group {
        let data: DiscoveredProjectImports
        var rows: [(session: ImportableSession, checkbox: ThemedCheckbox)] = []

        init(data: DiscoveredProjectImports) {
            self.data = data
        }

        var selected: [ImportableSession] {
            rows.filter { $0.checkbox.state == .on }.map(\.session)
        }
    }

    private var groups: [Group] = []
    private var scanResult: GlobalScanResult?
    /// The enabled logins the current scan covered. The accounts page sits *before* this one
    /// and can now switch logins off, so a cached result is only current while that set is —
    /// coming forward again after a toggle rescans instead of showing the stale list.
    private var scannedAccountIDs: Set<AccountID>?
    private var scanGeneration = 0
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let listHost = NSView()

    override func loadView() {
        view = NSView()
        setupViews()
    }

    func pageWillAppear() {
        let enabled = Set(
            (AgentAccountDiscovery.accounts(for: .claude)
                + AgentAccountDiscovery.accounts(for: .codex)).map(\.id)
        )
        guard scanResult == nil || enabled != scannedAccountIDs else { return }

        scannedAccountIDs = enabled
        scanResult = nil
        rebuildList()

        scanGeneration += 1
        let generation = scanGeneration
        GlobalSessionScan.discover { [weak self] result in
            guard let self, self.scanGeneration == generation else { return }
            self.apply(result: result)
        }
    }

    /// The scan's landing point — internal so a render test can put a known result on screen
    /// without a disk full of fixtures.
    func apply(result: GlobalScanResult) {
        scanResult = result
        rebuildList()
    }

    /// The import itself. On the main actor throughout: `addProject` dedups by path, and the
    /// batch adoption saves once per group rather than once per conversation.
    func pageWillContinue() {
        for group in groups {
            let selected = group.selected
            guard !selected.isEmpty else { continue }

            let project = ProjectStore.shared.addProject(
                folderURL: URL(fileURLWithPath: group.data.folder)
            )
            ProjectStore.shared.importSessions(selected, into: project.id)
        }
    }

    private func setupViews() {
        let heading = NSTextField(
            labelWithString: L10n.string("Bring your conversations along")
        )
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label
        heading.alignment = .center

        summaryLabel.applyFont(.body)
        summaryLabel.textColor = Design.Text.secondary
        summaryLabel.alignment = .center

        listHost.translatesAutoresizingMaskIntoConstraints = false
        // The list takes the page's slack, so the scroll clips at the footer's separator the
        // way every settings pane does — a fixed height clipped a row mid-air above dead space.
        listHost.setContentHuggingPriority(.defaultLow, for: .vertical)

        let stack = NSStackView(views: [heading, summaryLabel, listHost])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Spacing.inset
        stack.setCustomSpacing(Design.Spacing.large, after: summaryLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            summaryLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.contentWidth),
            listHost.widthAnchor.constraint(equalToConstant: Layout.contentWidth)
        ])

        rebuildList()
    }

    // MARK: - List

    private func rebuildList() {
        listHost.subviews.forEach { $0.removeFromSuperview() }

        guard let result = scanResult else {
            summaryLabel.stringValue = L10n.string("Looking through your past conversations…")
            // The scan reads every transcript each login holds, which can take long enough to
            // read as "stuck" against a blank page — the working orb says otherwise.
            let orb = WorkingOrbView()
            orb.selectRandomVariant()
            listHost.addSubview(orb)
            NSLayoutConstraint.activate([
                orb.centerXAnchor.constraint(equalTo: listHost.centerXAnchor),
                orb.centerYAnchor.constraint(equalTo: listHost.centerYAnchor)
            ])
            return
        }

        let now = Date()
        groups = result.groups.map(Group.init)

        guard !groups.isEmpty || result.totalFailureCount > 0 else {
            summaryLabel.stringValue = L10n.string(
                "No conversations to import. Everything starts fresh."
            )
            return
        }

        var cards: [NSView] = []
        if let failureCard = failureCard(for: result) {
            cards.append(failureCard)
        }

        // One flat card, newest first across every folder — the folder is import bookkeeping,
        // not something the user has to triage by.
        let ordered: [(session: ImportableSession, group: Group)] = groups
            .flatMap { group in group.data.conversations.map { (session: $0, group: group) } }
            .sorted { $0.session.lastActiveAt > $1.session.lastActiveAt }
        if !ordered.isEmpty {
            cards.append(SettingsCard(rows: ordered.map { entry in
                conversationRow(for: entry.session, in: entry.group, now: now)
            }))
        }

        let column = NSStackView(views: cards)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.inset
        column.translatesAutoresizingMaskIntoConstraints = false
        cards.forEach { $0.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }

        // The settings-page scroll shape: a flipped document so the first group sits at the
        // top, themed scrollers, no background of its own.
        let document = SettingsFlippedView()
        document.addSubview(column)

        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        listHost.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listHost.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: listHost.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: listHost.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listHost.trailingAnchor),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.leadingAnchor.constraint(
                equalTo: document.leadingAnchor,
                constant: Design.Size.glowGutter
            ),
            column.trailingAnchor.constraint(
                equalTo: document.trailingAnchor,
                constant: -Design.Size.glowGutter
            ),
            // The same halo gutter below, so the card's glow survives scrolling to the end.
            column.bottomAnchor.constraint(
                equalTo: document.bottomAnchor,
                constant: -Design.Size.glowGutter
            )
        ])

        refreshSummary()
    }

    /// A partial scan is useful, but never looks like a complete empty inventory. The bounded
    /// failure card leaves the readable conversations actionable and names the paths whose
    /// permissions or on-disk state need attention.
    private func failureCard(for result: GlobalScanResult) -> SettingsCard? {
        guard result.totalFailureCount > 0 else { return nil }

        var rows = result.failures.map { failure -> NSView in
            let path = NSTextField(labelWithString: failure.path)
            path.applyFont(.body)
            path.textColor = Design.Text.label
            path.lineBreakMode = .byTruncatingMiddle

            let reason = NSTextField(wrappingLabelWithString: failure.reason)
            reason.applyFont(.caption)
            reason.textColor = Design.Text.secondary

            let labels = NSStackView(views: [path, reason])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = Design.Spacing.tight
            return SettingsUI.fullRow(labels)
        }
        if result.additionalFailureCount > 0 {
            let omitted = NSTextField(labelWithString: L10n.format(
                "%lld more unreadable folders were omitted.",
                Int64(result.additionalFailureCount)
            ))
            omitted.applyFont(.caption)
            omitted.textColor = Design.Text.secondary
            rows.append(SettingsUI.fullRow(omitted))
        }
        return SettingsCard(rows: rows)
    }

    private func conversationRow(
        for session: ImportableSession,
        in group: Group,
        now: Date
    ) -> NSView {
        let checkbox = ThemedCheckbox(
            title: session.title,
            state: GlobalSessionScan.isPrechecked(session, now: now) ? .on : .off
        ) { [weak self] _ in
            self?.refreshSummary()
        }
        group.rows.append((session, checkbox))

        let icon = NSImageView()
        icon.image = session.kind.icon
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Layout.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Layout.iconSide)
        ])

        let when = NSTextField(
            labelWithString: Self.relativeDate.localizedString(
                for: session.lastActiveAt,
                relativeTo: now
            )
        )
        when.applyFont(.caption)
        when.textColor = Design.Text.tertiary

        checkbox.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [checkbox, icon, when])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small
        // `.fill` hands the row's slack to the low-hugging checkbox column, so the icon and
        // the age read as one trailing-aligned column down the card.
        content.distribution = .fill

        return SettingsUI.fullRow(content)
    }

    private func refreshSummary() {
        guard let result = scanResult else { return }

        let total = groups.reduce(0) { $0 + $1.data.conversations.count }
        let selected = groups.reduce(0) { $0 + $1.selected.count }

        if total == 0, result.totalFailureCount > 0 {
            summaryLabel.stringValue = L10n.string(
                "Some conversation folders could not be read. The results are incomplete."
            )
            return
        }

        var summary = L10n.format(
            "%lld conversations found. %lld selected to import.",
            Int64(total),
            Int64(selected)
        )
        if result.missingFolderConversations > 0 {
            summary += " " + L10n.format(
                "%lld more ran in folders that no longer exist and were left out.",
                Int64(result.missingFolderConversations)
            )
        }
        if result.totalFailureCount > 0 {
            summary += " " + L10n.format(
                "%lld conversation folders could not be read; these results are incomplete.",
                Int64(result.totalFailureCount)
            )
        }
        summaryLabel.stringValue = summary
    }
}
