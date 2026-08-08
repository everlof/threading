import AppKit

/// Picks conversations found on disk to adopt into a project.
///
/// Presented as a sheet rather than a chip menu: a busy project has hundreds of past
/// conversations, which is far past what a menu can be scanned in, so the list is searchable
/// and shows enough of each conversation to tell them apart.
final class SessionImportViewController: NSViewController {

    // MARK: - Properties

    /// Every conversation offered, before the search field narrows it.
    private let sessions: [ImportableSession]
    private var visible: [ImportableSession] = []
    /// The trimmed query the visible rows were built for, so a row can show what it was found on.
    private var query = ""

    /// What will be adopted, by `ImportableSession.id`, held apart from the table's own
    /// selection because it has to outlive a search.
    ///
    /// Picking several conversations out of hundreds means searching, taking what matched,
    /// searching again — and a selection that lived on the table would be discarded by each of
    /// those searches, since `reloadData` selects nothing. So the ids are the truth and the
    /// table mirrors them: what is chosen and out of view is still chosen, and the Import
    /// button carries the count so that is never a surprise.
    private var selection: Set<String> = []

    /// Set while the list is being rebuilt or its selection written to match `selection`, so the
    /// delegate callbacks that causes are not read back as the user's own choice.
    ///
    /// `reloadData` is inside this and not only `selectRowIndexes`: reloading *clears* the
    /// table's selection and says so through the same delegate method, which read as the user
    /// deselecting everything the new query still shows — one keystroke into a search, the rows
    /// that matched were quietly dropped from what would be adopted.
    private var isRewritingList = false

    private let headingLabel = NSTextField(labelWithString: ImportStrings.heading)
    private let subheadingLabel = NSTextField(labelWithString: "")
    private let searchField = ThemedSearchField()
    private let tableView = ThemedTableView()
    private let importButton = ThemedButton()

    /// Called with the chosen conversations, newest first, or empty when the sheet is
    /// dismissed without adopting anything. Import cannot send an empty list: the button is
    /// disabled while nothing is chosen.
    var onPick: (([ImportableSession]) -> Void)?

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Initialization

    init(sessions: [ImportableSession]) {
        self.sessions = sessions
        self.visible = sessions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(
            x: 0, y: 0,
            width: ImportLayout.sheetWidth,
            height: ImportLayout.sheetHeight
        ))
        setupViews()
        updateSubheading()
        rewritingList {
            tableView.reloadData()
            restoreSelection()
        }
        refreshImportButton()
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        // Typing should narrow the list straight away, which is the only thing to do here
        // when the list is long.
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Setup

    private func setupViews() {
        headingLabel.applyFont(.heading)
        headingLabel.textColor = Design.Text.label

        subheadingLabel.applyFont(.subheading)
        subheadingLabel.textColor = Design.Text.secondary

        let headings = NSStackView(views: [headingLabel, subheadingLabel])
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = Design.Spacing.hairline

        searchField.placeholderString = ImportStrings.searchPlaceholder
        searchField.applyFont(.body)

        // Filtering is driven by the delegate rather than the field's action, leaving Return
        // to confirm the selection: the field holds focus, so its action would otherwise
        // swallow the key that is meant to import.
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(confirm)

        let stack = NSStackView(views: [headings, searchField, makeTable(), makeFooter()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.setCustomSpacing(Design.Spacing.large, after: headings)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.pane),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.pane),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.pane)
        ])

        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makeTable() -> NSView {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.rowHeight = ImportLayout.rowHeight
        tableView.style = .inset
        tableView.doubleAction = #selector(confirm)
        tableView.target = self
        // Adopting conversations is the plural job: a project that has lost track of its
        // history offers hundreds at once, and one round trip through this sheet per
        // conversation is not a way to get them back.
        tableView.allowsMultipleSelection = true
        tableView.addTableColumn(NSTableColumn(identifier: ImportColumn.session))

        let scrollView = ThemedScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )

        // The list is the content of this sheet, so it takes whatever height is left over.
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.heightAnchor
            .constraint(greaterThanOrEqualToConstant: ImportLayout.minimumListHeight)
            .isActive = true

        return scrollView
    }

    private func makeFooter() -> NSView {
        importButton.title = ImportStrings.importTitle(count: 0)
        importButton.isProminent = true
        importButton.keyEquivalent = "\r"
        importButton.target = self
        importButton.action = #selector(confirm)

        let cancelButton = ThemedButton(
            title: ImportStrings.cancelTitle,
            target: self,
            action: #selector(cancel)
        )
        cancelButton.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [spacer, cancelButton, importButton])
        footer.orientation = .horizontal
        footer.spacing = Design.Spacing.small

        return footer
    }

    // MARK: - Public Methods

    /// Updates the live filter. Kept separate from the delegate callback so a test exercises the
    /// exact same matching path as typing — the seam `SettingsSidebar` keeps for the same reason.
    func updateSearchQuery(_ query: String) {
        searchField.stringValue = query
        applySearch()
    }

    /// The identifiers currently offered, in the order they are read down the list.
    var visibleSessionIDs: [String] {
        visible.map(\.agentSessionID.rawValue)
    }

    /// The conversations Import would adopt, newest first — including any the current search
    /// has hidden.
    var selectedSessions: [ImportableSession] {
        sessions.filter { selection.contains($0.id) }
    }

    /// Chooses rows the way a click does, for tests and for anything driving the sheet other
    /// than the pointer.
    func selectSessions(withIDs identifiers: [String]) {
        let wanted = Set(identifiers)
        selection = Set(sessions.filter { wanted.contains($0.agentSessionID.rawValue) }.map(\.id))
        rewritingList { restoreSelection() }
        refreshImportButton()
    }

    /// What the Import button reads, so a test asserts on the sheet's own answer rather than
    /// re-deriving the count beside it.
    var importButtonTitleForTesting: String { importButton.title }

    /// What the *table* believes is chosen, and how each of those rows is drawn. Held choices
    /// that nothing marks on screen would be the whole bug this selection model could have, so
    /// a test asks the list rather than only asking the controller.
    func drawnSelectionForTesting() -> (rows: IndexSet, marked: [Bool]) {
        let rows = tableView.selectedRowIndexes
        let marked = rows.map { row in
            tableView.rowView(atRow: row, makeIfNecessary: true)?.isSelected ?? false
        }
        return (rows, marked)
    }

    /// The view a row builds, so a test asserts on what a row *says* rather than on what the
    /// list happens to hold — the two came apart once already, in a sidebar row whose buttons
    /// were unreachable in the container they shipped in.
    func rowViewForTesting(_ index: Int) -> NSView? {
        guard visible.indices.contains(index) else { return nil }
        return makeRow(for: visible[index])
    }

    // MARK: - Actions

    /// Narrows the list by title, agent, or the conversation's own identifier.
    ///
    /// The identifier is here because it is the one thing about a past conversation that is
    /// *exact*. Titles are the agent's summary of itself and several of them read alike; when
    /// something else already named the conversation — a hook's log, a `--resume` in a shell's
    /// history, another Threading window — the reader is holding an id and nothing else, and
    /// before this the sheet had no way to accept it.
    ///
    /// Matching is `contains` over the whole id rather than a prefix, so a fragment copied out
    /// of the middle of a path finds its row too.
    private func applySearch() {
        query = searchField.stringValue.trimmingCharacters(in: .whitespaces)

        visible = query.isEmpty ? sessions : sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.kind.displayName.localizedCaseInsensitiveContains(query)
                || $0.agentSessionID.rawValue.localizedCaseInsensitiveContains(query)
        }

        rewritingList {
            tableView.reloadData()
            updateSubheading()
            restoreSelection()
        }
        refreshImportButton()
    }

    /// Not private: the two answers this sheet exists to give, asserted by
    /// `SessionImportActivityTests` through the same path the button and Return take.
    @objc func confirm() {
        let chosen = selectedSessions
        guard !chosen.isEmpty else { return }
        onPick?(chosen)
    }

    @objc func cancel() {
        onPick?([])
    }

    // MARK: - Private Methods

    /// Puts the table's selection back where `selection` says it is, and starts one on the
    /// first row when there is none — Return always has something to act on, and a search that
    /// narrows to the row somebody was looking for can be taken with the keyboard alone.
    private func restoreSelection() {
        if selection.isEmpty, let first = visible.first {
            selection.insert(first.id)
        }

        let rows = visible.indices.filter { selection.contains(visible[$0].id) }
        tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    /// Runs a rebuild of the list, ignoring the selection changes it causes.
    private func rewritingList(_ work: () -> Void) {
        isRewritingList = true
        work()
        isRewritingList = false
    }

    /// Takes the table's selection as the user's answer *for the rows it can see*, leaving
    /// choices the search has hidden alone.
    private func readSelectionFromTable() {
        let shown = Set(visible.map(\.id))
        let chosen = Set(tableView.selectedRowIndexes.compactMap { row in
            visible.indices.contains(row) ? visible[row].id : nil
        })

        selection = selection.subtracting(shown).union(chosen)
    }

    private func refreshImportButton() {
        importButton.isEnabled = !selection.isEmpty
        importButton.title = ImportStrings.importTitle(count: selection.count)
    }

    private func updateSubheading() {
        subheadingLabel.stringValue = visible.count == sessions.count
            ? ImportStrings.subheading(count: sessions.count)
            : ImportStrings.filteredSubheading(shown: visible.count, of: sessions.count)
    }
}

// MARK: - NSSearchFieldDelegate

extension SessionImportViewController: NSSearchFieldDelegate {

    func controlTextDidChange(_ notification: Notification) {
        applySearch()
    }
}

// MARK: - NSTableViewDataSource

extension SessionImportViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        visible.count
    }
}

// MARK: - NSTableViewDelegate

extension SessionImportViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visible.count else { return nil }
        return makeRow(for: visible[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRewritingList else { return }

        readSelectionFromTable()
        refreshImportButton()
    }

    /// A row shows the agent it belongs to, what the conversation was about, when it was last
    /// touched, and its identifier — which together are what distinguishes one past conversation
    /// from another.
    ///
    /// The identifier sits in a column of its own down the trailing edge rather than at the end
    /// of the detail line. It is the row's least interesting fact until it is the only one that
    /// matters, and a column is what lets the eye skip it entirely and then, when a query is an
    /// id, read straight down it.
    private func makeRow(for session: ImportableSession) -> NSView {
        let icon = NSImageView()
        icon.image = session.kind.icon
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control)
        icon.contentTintColor = Design.Text.secondary

        let title = SearchMatchLabel(role: .body)
        title.show(session.title, matching: query)

        let detail = SearchMatchLabel(role: .subheading, ink: { Design.Text.tertiary })
        detail.show(detailText(for: session), matching: query)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Design.Spacing.hairline
        // The title column absorbs the row's slack; the identifier keeps its width and the
        // titles truncate, which is the right way round — one is a summary and the other is
        // the exact thing somebody may have pasted in to find this row.
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let identifier = SearchMatchLabel(role: .code(), ink: { Design.Text.quaternary })
        identifier.show(identifierText(for: session), matching: query)
        identifier.setContentHuggingPriority(.required, for: .horizontal)
        identifier.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [icon, text, identifier])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        row.edgeInsets = NSEdgeInsets(
            top: 0, left: Design.Spacing.small,
            bottom: 0, right: Design.Spacing.small
        )

        return row
    }

    /// As much of the conversation's identifier as a row can carry, always including whatever
    /// the query landed on.
    ///
    /// A fixed prefix is the obvious answer and is wrong on its own: a reader who pasted a
    /// fragment from the *middle* of an id would get their row back with nothing lit up in it,
    /// which reads as the sheet having matched on something else. So the window slides — the
    /// leading ellipsis is the row saying there is more id in front of what you are looking at.
    private func identifierText(for session: ImportableSession) -> String {
        let identifier = session.agentSessionID.rawValue
        let shown = ImportLayout.identifierLength
        guard identifier.count > shown else { return identifier }

        guard let match = SearchTextMatch.ranges(in: identifier, matching: query).first,
              identifier.distance(from: identifier.startIndex, to: match.lowerBound) >= shown
        else { return String(identifier.prefix(shown)) }

        let end = identifier.index(match.lowerBound, offsetBy: shown, limitedBy: identifier.endIndex)
        return ImportStrings.elision + identifier[match.lowerBound..<(end ?? identifier.endIndex)]
    }

    /// Names the account only when it is not the default one, matching the sidebar.
    private func detailText(for session: ImportableSession) -> String {
        let when = Self.relativeDate.localizedString(for: session.lastActiveAt, relativeTo: Date())

        guard !session.accountHandle.isStandard,
              let account = AgentAccountDiscovery.account(
                  for: session.kind,
                  handle: session.accountHandle
              )
        else { return when }

        return "\(account.displayName) · \(when)"
    }
}

// MARK: - Import Column

enum ImportColumn {
    static let session = NSUserInterfaceItemIdentifier("ImportSessionColumn")
}

// MARK: - Import Layout

enum ImportLayout {
    static let sheetWidth: CGFloat = 520
    static let sheetHeight: CGFloat = 460
    static let rowHeight: CGFloat = 44
    static let minimumListHeight: CGFloat = 240

    /// How much of a conversation's identifier a row shows. Eight, the length git settled on for
    /// the same problem: enough that two of them are never confused by eye, short enough to sit
    /// in the margin of a row without becoming the row.
    static let identifierLength = 8
}

// MARK: - Import Strings

enum ImportStrings {
    static var heading: String { L10n.string("Import Conversation") }
    static var searchPlaceholder: String { L10n.string("Search conversations or paste an ID") }
    static var cancelTitle: String { L10n.string("Cancel") }

    /// Counted past one, because the count is the only thing that says a choice the search has
    /// scrolled or filtered out of sight is still going to be adopted. The bare word stands
    /// while nothing is chosen, where a number would be noise.
    static func importTitle(count: Int) -> String {
        switch count {
        case ...0: return L10n.string("Import")
        case 1: return L10n.string("Import 1 conversation")
        default: return L10n.format("Import %lld conversations", Int64(count))
        }
    }

    /// Not localized: a single ellipsis, standing for the characters of an identifier that are
    /// in front of the ones the row is showing.
    static let elision = "…"

    static func subheading(count: Int) -> String {
        count == 1
            ? L10n.string("1 conversation found in this folder")
            : L10n.format(
                "%lld conversations found in this folder",
                Int64(count)
            )
    }

    static func filteredSubheading(shown: Int, of total: Int) -> String {
        L10n.format(
            "%lld of %lld conversations",
            Int64(shown),
            Int64(total)
        )
    }
}
