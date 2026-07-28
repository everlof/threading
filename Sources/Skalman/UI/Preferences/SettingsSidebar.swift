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
            Self.matches(query: query, text: $0.searchText)
        }

        rows = displayedItems.map { item in
            let row = ThemedTabItemView(
                title: item.title,
                symbolName: item.symbol,
                placement: .sidebar,
                inkSource: .chrome
            )
            row.onSelect = { [weak self] in
                self?.select(id: item.id)
                self?.onSelect?(item.id)
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

        let resultViews: [NSView] = rows.isEmpty ? [noResults] : rows
        let stack = NSStackView(views: resultViews)
        stack.orientation = .vertical
        stack.alignment = .leading
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

        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if rows.isEmpty {
            noResults.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        select(id: selectedID ?? "")
    }

    private static func matches(query: String, text: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let tokens = query.split(whereSeparator: \.isWhitespace)
        return tokens.allSatisfy { token in
            text.range(of: String(token), options: options, locale: .current) != nil
        }
    }
}

// MARK: - NSTextFieldDelegate

extension SettingsSidebar: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        rebuildResults()
    }
}
