import AppKit

enum SettingsSearchDefaults {
    /// Between the terms on a result's second line. A middle dot rather than a comma: the terms
    /// are separate labels, several of which contain commas' worth of words already.
    static let termSeparator = " · "
}

// MARK: - Settings Search Results

/// What the settings pane shows while a search is running: every section the query landed in,
/// each with the terms it landed on and a way into the page.
///
/// The sidebar narrows to the same set, so this could have been left out — and was, which is
/// exactly what made searching feel like nothing had happened. Narrowing a list of fifteen
/// names to two is a change most of the window does not report: the pane goes on showing
/// whichever page was open before the query, so the one surface the reader is looking at says
/// nothing about what was found. This is that answer, in the place their eyes already are.
///
/// It is not a settings *page*: it has no ID, is never cached, and is rebuilt from the query on
/// every keystroke — there is no state in it worth keeping between two different searches.
@MainActor
final class SettingsSearchResultsViewController: NSViewController {

    // MARK: - Properties

    /// The page a result row was asked to open.
    var onOpen: ((String) -> Void)?

    private var query: String
    private var matches: [SettingsSearchMatch]

    private enum PresentationRow {
        case empty
        case caption
        case match(Int)
    }

    private var presentationRows: [PresentationRow] = []

    private lazy var tableView: ThemedGroupedTableView = {
        let table = ThemedGroupedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("SettingsSearchResultsContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = SettingsUIDefaults.rowHeight
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

    // MARK: - Initialization

    init(query: String, matches: [SettingsSearchMatch]) {
        self.query = query
        self.matches = matches
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Restates the page for a new query. The pane keeps one results controller across a whole
    /// typing run, so the reader's scroll position and the pane's own transition survive the
    /// letters rather than restarting at each one.
    func update(query: String, matches: [SettingsSearchMatch]) {
        guard query != self.query || matches != self.matches else { return }
        let identitiesAreUnchanged = matches == self.matches
        self.query = query
        self.matches = matches
        guard isViewLoaded else { return }
        if identitiesAreUnchanged {
            reloadVisibleRows()
        } else {
            reloadRows()
        }
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        reloadRows()
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

    // MARK: - Private Methods

    private func reloadRows() {
        if matches.isEmpty {
            presentationRows = [.empty]
            tableView.cardDecorations = [ThemedTableCardDecoration(
                rows: 0...0,
                topInset: Design.Spacing.large
            )]
        } else {
            presentationRows = [.caption]
            presentationRows.append(contentsOf: matches.indices.map(PresentationRow.match))
            tableView.cardDecorations = [ThemedTableCardDecoration(
                rows: 1...matches.count
            )]
        }
        tableView.reloadData()
    }

    /// Highlighting and the caption depend on the query, but neither changes row height. When a
    /// keystroke leaves the result identities alone, update the existing visible labels in place.
    /// Rebuilding even those cells spends a frame recreating buttons and constraints that did not
    /// change; reloading the whole table also discards AppKit's offscreen height discoveries.
    private func reloadVisibleRows() {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return }
        if NSLocationInRange(0, range) {
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: 0),
                columnIndexes: IndexSet(integer: 0)
            )
        }
        tableView.enumerateAvailableRowViews { [weak self] rowView, rowIndex in
            guard let self, self.presentationRows.indices.contains(rowIndex),
                  case .match(let matchIndex) = self.presentationRows[rowIndex],
                  self.matches.indices.contains(matchIndex) else { return }
            let match = self.matches[matchIndex]
            let labels = self.searchLabels(in: rowView)
            labels.first?.show(match.title, matching: self.query)
            if labels.count > 1 {
                labels[1].show(
                    match.terms.joined(separator: SettingsSearchDefaults.termSeparator),
                    matching: self.query
                )
            }
        }
    }

    private func searchLabels(in root: NSView) -> [SearchMatchLabel] {
        var result: [SearchMatchLabel] = []
        if let label = root as? SearchMatchLabel { result.append(label) }
        for child in root.subviews {
            result.append(contentsOf: searchLabels(in: child))
        }
        return result
    }

    /// One matched section: what it is called, what the query touched inside it, and the way in.
    ///
    /// The terms are the row's *subtitle* rather than rows of their own, because a term does not
    /// name a destination — nothing here can scroll a page to the word "mute". Saying which
    /// words matched is the useful half; pretending each is separately reachable is not.
    ///
    /// Both lines are handed the query. Listing the terms said *that* the search landed here and
    /// left the reader to find the word themselves — which, on a row reading
    /// "Notifications · Mute · Sound", is the row asking them to run their own search inside the
    /// answer to their search. The highlight is the rest of that sentence.
    private func row(for match: SettingsSearchMatch, index: Int) -> NSView {
        let open = SettingsUI.button(
            L10n.string("Open"),
            target: self,
            action: #selector(openClicked)
        )
        open.tag = index
        open.setAccessibilityLabel(L10n.format("Open %@", match.title))

        // No subtitle when the query only touched the section's own name: an empty second line
        // would be a row explaining that it has nothing to explain.
        return SettingsUI.row(
            title: match.title,
            subtitle: match.terms.isEmpty
                ? nil
                : match.terms.joined(separator: SettingsSearchDefaults.termSeparator),
            control: open,
            localizes: false,
            highlighting: query
        )
    }

    @objc private func openClicked(_ sender: NSControl) {
        guard matches.indices.contains(sender.tag) else { return }
        onOpen?(matches[sender.tag].pageID)
    }
}

// MARK: - Virtualized Results

extension SettingsSearchResultsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        presentationRows.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row tableRow: Int
    ) -> NSView? {
        guard presentationRows.indices.contains(tableRow) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SettingsSearchResultVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier
        let row = presentationRows[tableRow]
        host.install(
            content(for: row),
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            horizontalInset: Design.Size.glowGutter,
            topInset: topInset(for: row),
            bottomInset: bottomInset(forRowAt: tableRow)
        )
        return host
    }

    private func content(for row: PresentationRow) -> NSView {
        switch row {
        case .empty:
            return SettingsUI.fullRow(SettingsUI.note(L10n.string("No settings found.")))
        case .caption:
            return SettingsUI.caption(
                L10n.format("Matches for “%@”", query),
                localizes: false
            )
        case .match(let index):
            guard matches.indices.contains(index) else { return NSView() }
            return self.row(for: matches[index], index: index)
        }
    }

    private func topInset(for row: PresentationRow) -> CGFloat {
        switch row {
        case .empty, .caption: return Design.Spacing.large
        case .match: return 0
        }
    }

    private func bottomInset(forRowAt row: Int) -> CGFloat {
        guard presentationRows.indices.contains(row) else { return 0 }
        switch presentationRows[row] {
        case .caption: return Design.Spacing.small
        case .empty: return Design.Spacing.large
        case .match: return row == presentationRows.count - 1 ? Design.Spacing.large : 0
        }
    }

    var virtualRowCountForTesting: Int { presentationRows.count }

    var materializedRowCountForTesting: Int {
        var count = 0
        tableView.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }
}
