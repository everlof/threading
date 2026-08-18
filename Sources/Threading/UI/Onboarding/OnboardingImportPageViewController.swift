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

    /// A value row is all that survives outside the viewport. AppKit constructs the checkbox,
    /// icon and age only while this row intersects the scroll view.
    private struct ConversationEntry {
        let session: ImportableSession
    }

    private enum PresentationRow: Equatable {
        case failures
        case conversation(Int)
    }

    private var groups: [DiscoveredProjectImports] = []
    private var conversations: [ConversationEntry] = []
    private var presentationRows: [PresentationRow] = []
    private var selectedConversationIDs: Set<String> = []
    private var relativeDateReference = Date()
    private var scanResult: GlobalScanResult?
    /// The enabled logins the current scan covered. The accounts page sits *before* this one
    /// and can now switch logins off, so a cached result is only current while that set is —
    /// coming forward again after a toggle rescans instead of showing the stale list.
    private var scannedAccountIDs: Set<AccountID>?
    private var scanGeneration = 0
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let listHost = NSView()

    private lazy var tableView: ThemedGroupedTableView = {
        let table = ThemedGroupedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("OnboardingImportContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = Design.Size.fieldHeight
        table.usesAutomaticRowHeights = true
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self
        return table
    }()

    private lazy var scrollView: ThemedScrollView = {
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

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
        let conversationCount = result.groups.reduce(0) { $0 + $1.conversations.count }
        let span = PerformanceRecorder.shared.begin(
            "onboarding.import-list.rebuild",
            category: "ui",
            metadata: [
                "groups": String(result.groups.count),
                "conversations": String(conversationCount),
                "failures": String(result.totalFailureCount)
            ]
        )
        defer { span.end() }
        scanResult = result
        rebuildList()
    }

    /// The import itself. On the main actor throughout: `addProject` dedups by path, and the
    /// batch adoption saves once per group rather than once per conversation.
    func pageWillContinue() {
        for group in groups {
            let selected = group.conversations.filter {
                selectedConversationIDs.contains($0.id)
            }
            guard !selected.isEmpty else { continue }

            guard let project = ProjectStore.shared.addProject(
                folderURL: URL(fileURLWithPath: group.folder)
            ) else { continue }
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

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                (cell as? ThemedVirtualTableCell)?.setColumnWidth(width)
            }
        }
    }

    // MARK: - List

    private func rebuildList() {
        listHost.subviews.forEach { $0.removeFromSuperview() }
        groups = []
        conversations = []
        presentationRows = []
        selectedConversationIDs = []
        tableView.cardDecorations = []
        tableView.reloadData()

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
        relativeDateReference = now
        groups = result.groups

        guard !groups.isEmpty || result.totalFailureCount > 0 else {
            summaryLabel.stringValue = L10n.string(
                "No conversations to import. Everything starts fresh."
            )
            return
        }

        if result.totalFailureCount > 0 {
            presentationRows.append(.failures)
        }

        // One flat card, newest first across every folder — the folder is import bookkeeping,
        // not something the user has to triage by. The array is value-only: converting all of
        // it to controls is the exact scaling failure this table boundary prevents.
        conversations = groups
            .flatMap { group in
                group.conversations.map {
                    ConversationEntry(session: $0)
                }
            }
            .sorted { $0.session.lastActiveAt > $1.session.lastActiveAt }
        selectedConversationIDs = Set(conversations.compactMap { entry in
            GlobalSessionScan.isPrechecked(entry.session, now: now) ? entry.session.id : nil
        })
        presentationRows.append(contentsOf: conversations.indices.map(PresentationRow.conversation))
        updateCardDecorations()
        tableView.reloadData()

        listHost.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: listHost.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listHost.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: listHost.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listHost.trailingAnchor)
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

    private func conversationRow(for session: ImportableSession, now: Date) -> NSView {
        let sessionID = session.id
        let checkbox = ThemedCheckbox(
            title: session.title,
            state: selectedConversationIDs.contains(sessionID) ? .on : .off
        ) { [weak self] state in
            self?.setSelected(state == .on, conversationID: sessionID)
        }

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

    private func setSelected(_ isSelected: Bool, conversationID: String) {
        if isSelected {
            selectedConversationIDs.insert(conversationID)
        } else {
            selectedConversationIDs.remove(conversationID)
        }
        refreshSummary()
    }

    private func updateCardDecorations() {
        guard let first = presentationRows.firstIndex(where: {
            if case .conversation = $0 { return true }
            return false
        }), let last = presentationRows.lastIndex(where: {
            if case .conversation = $0 { return true }
            return false
        }) else {
            tableView.cardDecorations = []
            return
        }

        tableView.cardDecorations = [ThemedTableCardDecoration(
            rows: first ... last,
            bottomInset: Design.Size.glowGutter
        )]
    }

    private func refreshSummary() {
        guard let result = scanResult else { return }

        let total = conversations.count
        let selected = selectedConversationIDs.count

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
            let failureSummary = result.totalFailureCount == 1
                ? L10n.string("1 conversation folder could not be read; these results are incomplete.")
                : L10n.format(
                    "%lld conversation folders could not be read; these results are incomplete.",
                    Int64(result.totalFailureCount)
                )
            summary += " " + failureSummary
        }
        summaryLabel.stringValue = summary
    }
}

// MARK: - Virtualized Conversation List

extension OnboardingImportPageViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in _: NSTableView) -> Int {
        presentationRows.count
    }

    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
        false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor _: NSTableColumn?,
        row tableRow: Int
    ) -> NSView? {
        guard presentationRows.indices.contains(tableRow) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("OnboardingImportVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier

        let row = presentationRows[tableRow]
        let topInset: CGFloat
        let bottomInset: CGFloat
        let content: NSView
        switch row {
        case .failures:
            content = scanResult.flatMap { failureCard(for: $0) } ?? NSView()
            topInset = 0
            bottomInset = Design.Spacing.inset
        case let .conversation(index):
            guard conversations.indices.contains(index) else { return nil }
            content = conversationRow(
                for: conversations[index].session,
                now: relativeDateReference
            )
            topInset = 0
            bottomInset = tableRow == presentationRows.count - 1
                ? Design.Size.glowGutter
                : 0
        }
        host.install(
            content,
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            horizontalInset: Design.Size.glowGutter,
            topInset: topInset,
            bottomInset: bottomInset
        )
        return host
    }
}
