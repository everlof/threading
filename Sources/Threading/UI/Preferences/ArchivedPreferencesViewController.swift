import AppKit

/// Sendable search material for the unbounded archive. Filtering runs off the main actor and
/// returns only source offsets; the AppKit/controller side keeps owning the actual session values.
struct ArchivedSessionSearchRecord: Sendable, Equatable {
    let sourceIndex: Int
    let title: String
    let projectName: String
}

enum ArchivedSessionSearch {
    static func matchingIndexes(
        in records: [ArchivedSessionSearchRecord],
        query: String
    ) -> [Int] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records.map(\.sourceIndex) }
        var matches: [Int] = []
        matches.reserveCapacity(min(records.count, ArchivedDefaults.recentLimit))
        for record in records {
            if Task.isCancelled { return [] }
            if record.title.localizedCaseInsensitiveContains(query)
                || record.projectName.localizedCaseInsensitiveContains(query) {
                matches.append(record.sourceIndex)
            }
        }
        return matches
    }
}

/// Archived-sessions preferences: the conversations filed away out of the sidebar.
///
/// Archiving keeps a session's conversation but takes it off the sidebar, so this is where the
/// archived ones live — to be restored to the sidebar or deleted for good. Nothing is created
/// here; the list only reflects what has been archived.
///
/// Each archived conversation is a flat card row carrying its own Restore and Delete actions,
/// so there is no selection state and no footer button bar. The complete archive is a value-row
/// model; AppKit constructs only the rows intersecting the viewport.
final class ArchivedPreferencesViewController: NSViewController {
    typealias Entry = (project: Project, session: AgentSession)

    private enum PresentationRow {
        case note
        case empty
        case session(Int)
        case olderDisclosure(Int)
        case extensionCaption(Int)
        case extensionField(section: Int, field: Int)
    }

    // MARK: - Properties

    private let rowsProvider: @MainActor () -> [Entry]
    private var allRows: [Entry] = []
    private var rows: [Entry] = []
    private var searchRecords: [ArchivedSessionSearchRecord] = []
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private let appEvents = AppEventObservations()
    private var extensionSections: [ExtensionSettingsSectionModel] = []
    private var presentationRows: [PresentationRow] = []
    private var pageView: SettingsPageView?

    /// Whether the fold past the recent slice is open. A view state, kept for the session.
    private var showsOlder = false

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private lazy var tableView: ThemedGroupedTableView = {
        let table = ThemedGroupedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("ArchivedSettingsContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = ArchivedDefaults.estimatedRowHeight
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
        return scroll
    }()

    private lazy var searchField: ThemedSearchField = {
        let field = ThemedSearchField()
        field.placeholderString = ArchivedPreferencesStrings.searchPlaceholder
        field.setAccessibilityLabel(ArchivedPreferencesStrings.searchAccessibilityLabel)
        field.setAccessibilityIdentifier("settings.archived.search")
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    /// Search remains available while the archive scrolls. The table stays the sole scroll
    /// owner, preserving its viewport-bound row construction.
    private lazy var listBody: NSView = {
        let body = NSView()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(searchField)
        body.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(
                equalTo: body.topAnchor,
                constant: Design.Spacing.large
            ),
            searchField.leadingAnchor.constraint(
                equalTo: body.leadingAnchor,
                constant: Design.Size.glowGutter
            ),
            searchField.trailingAnchor.constraint(
                equalTo: body.trailingAnchor,
                constant: -Design.Size.glowGutter
            ),
            scrollView.topAnchor.constraint(
                equalTo: searchField.bottomAnchor,
                constant: Design.Spacing.medium
            ),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        return body
    }()

    init(rowsProvider: (@MainActor () -> [Entry])? = nil) {
        self.rowsProvider = rowsProvider ?? { ProjectStore.shared.archivedSessions() }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        let page = SettingsUI.listPage(
            title: "Archived",
            summary: ArchivedPreferencesStrings.count(0),
            body: listBody
        )
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        pageView = page
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.reload()
        }
        appEvents.observe(ExtensionSettingsRegistryDidChange.self) { [weak self] _ in
            self?.reload()
        }
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

    // MARK: - Build

    /// Refreshes the cheap value model. An unchanged event recycles only the viewport and keeps
    /// its scroll position; no project notification rebuilds the page header or the full archive.
    private func reload() {
        allRows = rowsProvider()
        searchRecords = allRows.enumerated().map { index, entry in
            ArchivedSessionSearchRecord(
                sourceIndex: index,
                title: entry.session.displayTitle,
                projectName: entry.project.name
            )
        }
        extensionSections = ExtensionSettingsRenderer.hostSectionModels(for: .archived)
        pageView?.updateSummary(ArchivedPreferencesStrings.count(allRows.count))
        applySearchQuery(searchField.stringValue)
    }

    private var isFiltering: Bool {
        !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Filters value records away from the main actor. Search frequency comes from typing and
    /// archive cardinality is user-owned, so a cancelled scan checks cancellation per record and
    /// only its final offset list crosses back into presentation.
    private func applySearchQuery(_ query: String) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            applyFilteredRows(allRows)
            return
        }

        let records = searchRecords
        let worker = Task.detached(priority: .userInitiated) {
            ArchivedSessionSearch.matchingIndexes(in: records, query: trimmed)
        }
        searchTask = Task { [weak self] in
            let indexes = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, generation == searchGeneration else { return }
            let matches = indexes.compactMap { index in
                self.allRows.indices.contains(index) ? self.allRows[index] : nil
            }
            applyFilteredRows(matches)
        }
    }

    private func applyFilteredRows(_ filteredRows: [Entry]) {
        rows = filteredRows
        presentationRows = makePresentationRows()
        updateCardDecorations()
        tableView.reloadData()
    }

    private func makePresentationRows() -> [PresentationRow] {
        var result: [PresentationRow] = [.note]
        if rows.isEmpty {
            result.append(.empty)
        } else {
            let visibleCount = isFiltering || showsOlder
                ? rows.count
                : min(rows.count, ArchivedDefaults.recentLimit)
            result.append(contentsOf: (0 ..< visibleCount).map(PresentationRow.session))
            let older = isFiltering ? 0 : max(rows.count - ArchivedDefaults.recentLimit, 0)
            if older > 0 { result.append(.olderDisclosure(older)) }
        }
        for (sectionIndex, section) in extensionSections.enumerated() {
            if section.visibleTitle != nil {
                result.append(.extensionCaption(sectionIndex))
            }
            result.append(contentsOf: section.fields.indices.map {
                .extensionField(section: sectionIndex, field: $0)
            })
        }
        return result
    }

    /// One archived conversation: a title over a "<project> · <archived when>" caption, with
    /// trailing Restore and Delete actions. The buttons carry the row's index in their tag, so
    /// an action maps straight back to its session in `rows`.
    private func makeRow(entry: (project: Project, session: AgentSession), index: Int) -> NSView {
        let titleLabel = NSTextField(labelWithString: entry.session.displayTitle)
        titleLabel.applyFont(.body)
        titleLabel.textColor = Design.Text.label
        titleLabel.lineBreakMode = .byTruncatingTail
        // Truncates rather than pushing: an incompressible row title's width travels out
        // through the stacks and breaks the page's own pins — see SettingsUI.disclosureRow.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let archivedAt = entry.session.archivedAt ?? entry.session.lastActiveAt
        let when = Self.relativeDate.localizedString(for: archivedAt, relativeTo: Date())
        let manager = ControlGrantStore.shared.supervisions(forChild: entry.session.id)
            .last(where: { $0.state == .archived })
            .flatMap { ProjectStore.shared.session(withID: $0.managerID)?.displayTitle }
        let caption = manager.map {
            L10n.format("%1$@ · %2$@ · by %3$@", entry.project.name, when, $0)
        } ?? "\(entry.project.name) · \(when)"
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.applyFont(.subheading)
        captionLabel.textColor = Design.Text.secondary
        captionLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [titleLabel, captionLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let restore = SettingsUI.button("Restore", target: self, action: #selector(restoreSession(_:)))
        restore.tag = index
        restore.setContentHuggingPriority(.required, for: .horizontal)

        let delete = SettingsUI.button("Delete…", target: self, action: #selector(deleteSession(_:)))
        delete.tag = index
        delete.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [labels, spacer, restore, delete])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small

        return padded(row)
    }

    /// Wraps a row's content with the card's standard insets and minimum height.
    private func padded(_ content: NSView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Design.Spacing.medium),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Design.Spacing.medium),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Design.Spacing.inset),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsUIDefaults.rowHeight),
        ])

        return container
    }

    // MARK: - Actions

    private func session(for sender: ThemedButton) -> (project: Project, session: AgentSession)? {
        guard sender.tag >= 0, sender.tag < rows.count else { return nil }
        return rows[sender.tag]
    }

    /// Puts the session back on the sidebar, where selecting it resumes the conversation.
    @objc private func restoreSession(_ sender: ThemedButton) {
        guard let entry = session(for: sender) else { return }
        sender.isEnabled = false
        ProviderArchiveSync.shared.setArchived(false, for: entry.session.id) { [weak self, weak sender] result in
            switch result {
            case .success:
                self?.reload()
            case let .failure(failure):
                sender?.isEnabled = true
                NoticeAlert.show(NoticeRequest(
                    title: L10n.format("Couldn’t restore “%@”", entry.session.displayTitle),
                    message: failure.localizedDescription,
                    style: .critical
                ), in: self?.view.window)
            }
        }
    }

    /// Deletes the session for good, after confirming — its conversation cannot be recovered
    /// from the sidebar afterwards, though the CLI's own transcript on disk is untouched.
    @objc private func deleteSession(_ sender: ThemedButton) {
        guard let entry = session(for: sender) else { return }

        let request = ConfirmationRequest(
            prompt: .deleteArchivedSession,
            title: L10n.format("Delete “%@”?", entry.session.displayTitle),
            message: L10n.string(
                "It is removed from Threading. The saved conversation on disk is not deleted, "
                    + "so it could still be imported again later."
            ),
            confirmTitle: L10n.string("Delete")
        )

        guard ConfirmationAlert.ask(request) else { return }

        guard ProjectStore.shared.removeSession(id: entry.session.id) == .applied else {
            NoticeAlert.show(NoticeRequest(
                title: L10n.format("Couldn’t delete “%@”", entry.session.displayTitle),
                message: L10n.string("The project data could not be saved."),
                style: .critical
            ), in: view.window)
            return
        }
        // This route bypasses the sidebar delegate, so it owns the same exact permanent-delete
        // cleanup. Archived sessions have no installed panel or drawer surfaces to release first.
        let sessionID = entry.session.id
        AgentRuntime.shared.discardDeletedSession(sessionID)
        SessionAttachmentStore.shared.removeSession(sessionID)
        DisplayPaneStore.shared.removeSession(sessionID)
        MCPSessionRegistry.remove(sessionID: sessionID)
        GitTurnBaselineStore.shared.remove(sessionID: sessionID)
        BrowserAutoCaptureRing.shared.clear(for: sessionID)
        reload()
    }

    /// Stress-fixture observability: the complete cheap model versus the live AppKit viewport.
    var virtualRowCountForTesting: Int { presentationRows.count }
    var filteredArchiveCountForTesting: Int { rows.count }
    var searchFieldForTesting: ThemedSearchField { searchField }

    /// The disclosure can sit just below a short viewport now that search is pinned above it.
    /// Stress and behavior fixtures use the table's real scrolling path before activating it.
    func revealOlderDisclosureForTesting() {
        guard let row = presentationRows.firstIndex(where: {
            if case .olderDisclosure = $0 { return true }
            return false
        }) else { return }
        tableView.scrollRowToVisible(row)
    }

    var materializedRowCountForTesting: Int {
        var count = 0
        tableView.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }
}

// MARK: - Search

extension ArchivedPreferencesViewController: NSTextFieldDelegate {
    func controlTextDidChange(_: Notification) {
        applySearchQuery(searchField.stringValue)
    }

    /// Escape clears a filled archive query and keeps the caret in the field. An empty query
    /// leaves Escape to the surrounding Settings surface.
    func control(
        _: NSControl,
        textView _: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
              !searchField.stringValue.isEmpty else { return false }
        searchField.clear()
        return true
    }
}

// MARK: - Virtualized Page

extension ArchivedPreferencesViewController: NSTableViewDataSource, NSTableViewDelegate {
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
        let identifier = NSUserInterfaceItemIdentifier("ArchivedSettingsVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier
        host.install(
            content(for: presentationRows[tableRow]),
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            horizontalInset: Design.Size.glowGutter,
            topInset: topInset(forRowAt: tableRow),
            bottomInset: bottomInset(forRowAt: tableRow)
        )
        return host
    }

    private func content(for row: PresentationRow) -> NSView {
        switch row {
        case .note:
            return SettingsUI.note(ArchivedPreferencesStrings.explanation)
        case .empty:
            return SettingsUI.note(
                isFiltering ? ArchivedPreferencesStrings.noMatches : ArchivedPreferencesStrings.empty
            )
        case let .session(index):
            guard rows.indices.contains(index) else { return NSView() }
            return makeRow(entry: rows[index], index: index)
        case let .olderDisclosure(older):
            return SettingsUI.disclosureRow(
                title: ArchivedPreferencesStrings.older(older),
                isExpanded: showsOlder,
                localizes: false,
                accessibilityIdentifier: "settings.archived.older",
                onToggle: { [weak self] nowOpen in
                    self?.setShowsOlder(nowOpen)
                }
            )
        case let .extensionCaption(sectionIndex):
            guard extensionSections.indices.contains(sectionIndex),
                  let title = extensionSections[sectionIndex].visibleTitle else { return NSView() }
            let caption = SettingsUI.caption(title, localizes: false)
            caption.setAccessibilityIdentifier(
                extensionSections[sectionIndex].accessibilityIdentifier
            )
            return caption
        case let .extensionField(sectionIndex, fieldIndex):
            guard extensionSections.indices.contains(sectionIndex) else { return NSView() }
            return ExtensionSettingsRenderer.fieldRow(
                in: extensionSections[sectionIndex],
                fieldIndex: fieldIndex
            )
        }
    }

    /// The fold changes only cheap row identities. Existing page/header/scroll owners survive,
    /// and AppKit constructs the newly intersecting archive cells on demand.
    private func setShowsOlder(_ expanded: Bool) {
        guard showsOlder != expanded,
              !isFiltering,
              rows.count > ArchivedDefaults.recentLimit else { return }
        let firstOlder = 1 + ArchivedDefaults.recentLimit
        let olderCount = rows.count - ArchivedDefaults.recentLimit
        showsOlder = expanded

        if expanded {
            presentationRows.insert(
                contentsOf: (ArchivedDefaults.recentLimit ..< rows.count).map(
                    PresentationRow.session
                ),
                at: firstOlder
            )
            tableView.insertRows(
                at: IndexSet(integersIn: firstOlder ..< (firstOlder + olderCount)),
                withAnimation: []
            )
        } else {
            let range = firstOlder ..< (firstOlder + olderCount)
            presentationRows.removeSubrange(range)
            tableView.removeRows(at: IndexSet(integersIn: range), withAnimation: [])
        }

        updateCardDecorations()
        let disclosureRow = firstOlder + (expanded ? olderCount : 0)
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: disclosureRow),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    private func updateCardDecorations() {
        var archiveBounds: (first: Int, last: Int)?
        var extensionBounds: [Int: (first: Int, last: Int)] = [:]
        for (index, row) in presentationRows.enumerated() {
            switch row {
            case .session, .olderDisclosure:
                if var bounds = archiveBounds {
                    bounds.last = index
                    archiveBounds = bounds
                } else {
                    archiveBounds = (index, index)
                }
            case let .extensionField(sectionIndex, _):
                if var bounds = extensionBounds[sectionIndex] {
                    bounds.last = index
                    extensionBounds[sectionIndex] = bounds
                } else {
                    extensionBounds[sectionIndex] = (index, index)
                }
            case .note, .empty, .extensionCaption:
                break
            }
        }

        var decorations: [ThemedTableCardDecoration] = []
        if let archiveBounds {
            decorations.append(ThemedTableCardDecoration(
                rows: archiveBounds.first ... archiveBounds.last,
                topInset: Design.Spacing.large,
                bottomInset: archiveBounds.last == presentationRows.count - 1
                    ? Design.Spacing.large
                    : 0
            ))
        }
        decorations.append(contentsOf: extensionBounds.sorted { $0.key < $1.key }.map {
            let section = extensionSections[$0.key]
            return ThemedTableCardDecoration(
                rows: $0.value.first ... $0.value.last,
                topInset: section.visibleTitle == nil ? Design.Spacing.large : 0,
                bottomInset: $0.value.last == presentationRows.count - 1
                    ? Design.Spacing.large
                    : 0
            )
        })
        tableView.cardDecorations = decorations
    }

    private func topInset(forRowAt index: Int) -> CGFloat {
        guard presentationRows.indices.contains(index) else { return 0 }
        switch presentationRows[index] {
        case let .session(sourceIndex):
            return sourceIndex == 0 ? Design.Spacing.large : 0
        case .olderDisclosure:
            return rows.isEmpty ? Design.Spacing.large : 0
        case let .extensionField(sectionIndex, fieldIndex):
            guard fieldIndex == 0, extensionSections.indices.contains(sectionIndex) else {
                return 0
            }
            return extensionSections[sectionIndex].visibleTitle == nil
                ? Design.Spacing.large
                : 0
        case .note:
            return Design.Spacing.medium
        case .empty, .extensionCaption:
            return Design.Spacing.large
        }
    }

    private func bottomInset(forRowAt index: Int) -> CGFloat {
        guard presentationRows.indices.contains(index) else { return 0 }
        if case .extensionCaption = presentationRows[index] {
            return Design.Spacing.small
        }
        return index == presentationRows.count - 1 ? Design.Spacing.large : 0
    }
}

// MARK: - Archived Preferences Strings

private enum ArchivedPreferencesStrings {
    static var explanation: String {
        L10n.string(
            "Archived conversations are kept but taken off the sidebar. Restore one to put it "
                + "back where selecting it resumes the conversation, or delete it to remove it "
                + "from Threading."
        )
    }

    static var empty: String {
        L10n.string("No archived conversations.")
    }

    static var noMatches: String {
        L10n.string("No archived conversations match your search.")
    }

    static var searchPlaceholder: String {
        L10n.string("Search archived conversations")
    }

    static var searchAccessibilityLabel: String {
        L10n.string("Archived conversation search")
    }

    static func count(_ count: Int) -> String {
        count == 1
            ? L10n.string("1 archived conversation")
            : L10n.format("%lld archived conversations", Int64(count))
    }

    static func older(_ count: Int) -> String {
        count == 1
            ? L10n.string("1 older conversation")
            : L10n.format("%lld older conversations", Int64(count))
    }
}

// MARK: - Archived Defaults

private enum ArchivedDefaults {
    /// How many conversations show before the rest fold — restoring reaches for something
    /// recent, and a long archive should cost one row, not the page's whole height.
    static let recentLimit = 10
    static let estimatedRowHeight: CGFloat = 64
}
