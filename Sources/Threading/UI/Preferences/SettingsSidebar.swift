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
        /// The section this page sits under, already localized. Consecutive items sharing a
        /// group draw one quiet caption above their run; nil rows stand on their own.
        var group: String?

        init(id: String, title: String, symbol: String, searchText: String, group: String? = nil) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.searchText = searchText
            self.group = group
        }
    }

    // MARK: - Properties

    /// Called with the stable page ID the user picked. Not fired by `select(id:)`, so the owner can set
    /// the initial page without re-entrancy.
    var onSelect: ((String) -> Void)?

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

        // Search changes which destinations are offered; it never changes the shape of one
        // destination into a miniature results tree. Broad queries used to add several term
        // rows beneath every page, overflowing this non-scrolling sidebar until it appeared to
        // vanish. The page's full searchable vocabulary still decides whether the row remains.
        rows = displayedItems.map { item in
            makeRow(title: item.title, symbol: item.symbol, opens: item.id)
        }

        // Rows interleaved with their group captions: one caption per surviving run, so a
        // filtered list keeps only the sections it still has rows for. Deliberately compact —
        // this sidebar does not scroll, so a caption costs one small line, not a band.
        var resultViews: [NSView] = []
        var lastGroup: String?
        for (offset, item) in displayedItems.enumerated() {
            if let group = item.group, group != lastGroup {
                resultViews.append(groupCaption(group, isFirst: resultViews.isEmpty))
            }
            lastGroup = item.group
            resultViews.append(rows[offset])
        }

        let noResults = NSTextField(
            wrappingLabelWithString: L10n.string("No settings found.")
        )
        noResults.applyFont(.subheading)
        noResults.textColor = Design.Text.secondary
        noResults.alignment = .center
        noResults.isHidden = !rows.isEmpty

        if rows.isEmpty { resultViews = [noResults] }
        let stack = NSStackView(views: resultViews)
        stack.orientation = .vertical
        stack.alignment = rows.isEmpty ? .centerX : .leading
        stack.spacing = Design.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        if searchField.superview == nil {
            addSubview(searchField)
            NSLayoutConstraint.activate([
                searchField.topAnchor.constraint(equalTo: topAnchor),
                searchField.leadingAnchor.constraint(equalTo: leadingAnchor),
                searchField.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
        }
        addSubview(stack)

        NSLayoutConstraint.activate([
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

    /// A section's quiet caption: the settings pages' own caption voice, indented to the rows'
    /// title line, with its separation carried as padding so the stack's row spacing stays one
    /// value.
    private func groupCaption(_ title: String, isFirst: Bool) -> NSView {
        let label = NSTextField(labelWithString: title.localizedUppercase)
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: isFirst ? Design.Spacing.tight : Design.Spacing.medium
            ),
            label.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -Design.Spacing.tight
            ),
            label.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor)
        ])
        return container
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

}

// MARK: - NSTextFieldDelegate

extension SettingsSidebar: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        rebuildResults()
    }
}
