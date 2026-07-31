import AppKit

/// Picks a conversation found on disk to adopt into a project.
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

    private let headingLabel = NSTextField(labelWithString: ImportStrings.heading)
    private let subheadingLabel = NSTextField(labelWithString: "")
    private let searchField = ThemedSearchField()
    private let tableView = ThemedTableView()
    private let importButton = ThemedButton()

    /// Called with the chosen conversation, or nil when the sheet is dismissed.
    var onPick: ((ImportableSession?) -> Void)?

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
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        // Typing should narrow the list straight away, which is the only thing to do here
        // when the list is long.
        view.window?.makeFirstResponder(searchField)
        selectFirstRow()
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
        importButton.title = ImportStrings.importTitle
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

        tableView.reloadData()
        updateSubheading()
        selectFirstRow()
    }

    @objc private func confirm() {
        let row = tableView.selectedRow
        guard row >= 0, row < visible.count else { return }
        onPick?(visible[row])
    }

    @objc private func cancel() {
        onPick?(nil)
    }

    // MARK: - Private Methods

    /// Keeps a row selected so Return always has something to act on.
    private func selectFirstRow() {
        guard !visible.isEmpty else {
            importButton.isEnabled = false
            return
        }

        tableView.selectRowIndexes([0], byExtendingSelection: false)
        importButton.isEnabled = true
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
        importButton.isEnabled = tableView.selectedRow >= 0
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
    static var importTitle: String { L10n.string("Import") }
    static var cancelTitle: String { L10n.string("Cancel") }

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
