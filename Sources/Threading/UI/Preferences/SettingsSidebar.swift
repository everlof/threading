import AppKit

// MARK: - Settings Sidebar

/// The vertical list of pages down the left of Settings — a quiet source-list-style nav in the
/// app's own design language, so choosing a page feels like the rest of the app rather than a
/// system dialog.
final class SettingsSidebar: NSView {

    // MARK: - Item

    struct Item {
        let id: String
        let title: String
        let symbol: String
        let searchText: String
        /// The page's own vocabulary, shown beneath it while a search is running. See
        /// `SettingsSearchMatch`.
        var terms: [String] = []
    }

    // MARK: - Geometry

    private enum Layout {
        /// How far a match sits inboard of the page it belongs to. One step of the sidebar's
        /// own indentation, so a match reads as *under* its section the way a session reads as
        /// under its project.
        static let matchIndent: CGFloat = SidebarDefaults.indentationPerLevel
        /// The mark on a match row. A magnifier rather than a chevron: the row exists because
        /// the query found it, and it opens the same page its parent does.
        static let matchSymbol = "text.magnifyingglass"
    }

    // MARK: - Properties

    /// Called with the stable page ID the user picked. Not fired by `select(id:)`, so the owner can set
    /// the initial page without re-entrancy.
    var onSelect: ((String) -> Void)?

    /// Called whenever the query changes, with the trimmed query. The list narrows itself; this
    /// is how the *pane* beside it learns to show the results page instead of a settings page.
    var onSearch: ((String) -> Void)?

    private var items: [Item] = []
    private var displayedItems: [Item] = []
    private var rows: [ThemedTabItemView] = []
    private(set) var selectedID: String?
    private lazy var searchField: ThemedSearchField = {
        let field = ThemedSearchField()
        field.placeholderString = L10n.string("Search Settings")
        field.setAccessibilityLabel(L10n.string("Search Settings"))
        field.setAccessibilityIdentifier("settings.search")
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    // MARK: - Initialization

    init(items: [Item]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(items)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Selects a page without notifying, for setting the initial state.
    func select(id: String) {
        selectedID = items.contains { $0.id == id } ? id : nil
        for (offset, row) in rows.enumerated() {
            row.isSelected = displayedItems[offset].id == selectedID
        }
    }

    func rebuild(items: [Item], selecting selectedID: String?) {
        subviews.forEach { $0.removeFromSuperview() }
        build(items)
        if let selectedID {
            select(id: selectedID)
        }
    }

    /// Updates the live filter. Kept separate from the delegate callback so restored Settings
    /// windows and tests exercise the exact same matching path as typing.
    func updateSearchQuery(_ query: String) {
        searchField.stringValue = query
        rebuildResults()
    }

    var visibleItemIDs: [String] {
        displayedItems.map(\.id)
    }

    // MARK: - Private Methods

    private func build(_ items: [Item]) {
        self.items = items
        rebuildResults()
    }

    private func rebuildResults() {
        rows.forEach { $0.removeFromSuperview() }
        subviews
            .filter { $0 !== searchField }
            .forEach { $0.removeFromSuperview() }

        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        displayedItems = query.isEmpty ? items : items.filter {
            SettingsSearch.matches(query: query, text: $0.searchText)
        }

        // Page rows and the matches under them, in reading order. `rows` stays the *pages*
        // alone — it is what `select(id:)` walks in step with `displayedItems`, and a match row
        // is never the selected page, it only opens one.
        var listed: [NSView] = []
        rows = displayedItems.map { item in
            let row = makeRow(title: item.title, symbol: item.symbol, opens: item.id)
            listed.append(row)
            guard !query.isEmpty else { return row }
            for term in SettingsSearch.terms(in: item.terms, touchedBy: query) {
                listed.append(indented(
                    makeRow(title: term, symbol: Layout.matchSymbol, opens: item.id)
                ))
            }
            return row
        }

        let noResults = NSTextField(
            wrappingLabelWithString: L10n.string("No settings found.")
        )
        noResults.applyFont(.subheading)
        noResults.textColor = Design.Text.secondary
        noResults.alignment = .center
        noResults.isHidden = !rows.isEmpty

        let resultViews: [NSView] = rows.isEmpty ? [noResults] : listed
        let stack = NSStackView(views: resultViews)
        stack.orientation = .vertical
        stack.alignment = rows.isEmpty ? .centerX : .leading
        stack.spacing = Design.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        if searchField.superview == nil {
            addSubview(searchField)
        }
        addSubview(stack)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(
                equalTo: searchField.bottomAnchor,
                constant: Design.Spacing.medium
            ),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])

        for view in resultViews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        select(id: selectedID ?? "")
    }

    private func makeRow(title: String, symbol: String, opens pageID: String) -> ThemedTabItemView {
        let row = ThemedTabItemView(
            title: title,
            symbolName: symbol,
            placement: .sidebar,
            inkSource: .chrome
        )
        row.onSelect = { [weak self] in
            self?.select(id: pageID)
            self?.onSelect?(pageID)
        }
        return row
    }

    /// A match, held one indentation step inboard of its page. The wrapper is what makes the
    /// step possible: a vertical stack pins every arranged view to its own leading edge, so an
    /// offset has to belong to a view of its own rather than to the row.
    private func indented(_ view: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Layout.matchIndent
            ),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        return container
    }
}

// MARK: - NSTextFieldDelegate

extension SettingsSidebar: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        rebuildResults()
        onSearch?(searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
