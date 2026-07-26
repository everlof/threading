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
    }

    // MARK: - Properties

    /// Called with the stable page ID the user picked. Not fired by `select(id:)`, so the owner can set
    /// the initial page without re-entrancy.
    var onSelect: ((String) -> Void)?

    private var items: [Item] = []
    private var rows: [ThemedTabItemView] = []
    private(set) var selectedID: String?

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
            row.isSelected = items[offset].id == selectedID
        }
    }

    func rebuild(items: [Item], selecting selectedID: String?) {
        subviews.forEach { $0.removeFromSuperview() }
        build(items)
        if let selectedID {
            select(id: selectedID)
        }
    }

    // MARK: - Private Methods

    private func build(_ items: [Item]) {
        self.items = items
        rows = items.map { item in
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

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])

        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}
