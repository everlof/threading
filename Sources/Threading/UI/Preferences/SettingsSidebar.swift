import AppKit

// MARK: - Settings Sidebar

/// The vertical list of pages down the left of Settings — a quiet source-list-style nav in the
/// app's own design language, so choosing a page feels like the rest of the app rather than a
/// system dialog.
///
/// While a search is typed it becomes the results list: each surviving page keeps its row, and
/// beneath it the individual settings the query landed on, each carrying its section as a quiet
/// path line. Choosing a setting opens its page *and scrolls to the row* — a result that only
/// named a page made the reader run their own search inside it. The results live in a scroll
/// view because settings-level results outgrow a fixed column, which is exactly how an earlier
/// version of per-term rows died (it overflowed this then-non-scrolling sidebar until it
/// appeared to vanish).
final class SettingsSidebar: NSView {

    enum Defaults {
        /// The most rows a *search* builds. The results are a retained stack rebuilt per
        /// keystroke, and pages are externally sized — 256 installed packages may contribute
        /// eight pages each — so construction is capped **before** views exist and the cut is
        /// said out loud in an overflow line, never taken silently. Deep enough that a real
        /// query is never cut; the resting page list is the app's own fixed catalogue and
        /// stays uncapped.
        static let maximumResultRows = 48
    }

    // MARK: - Item

    struct Item {
        /// One of the page's own settings, as the search sees it: the row's title (which is
        /// also its anchor — see `SettingsRowAnchor`), the section caption over it, and the
        /// text a query is matched against.
        struct Entry {
            let title: String
            let section: String?
            let searchText: String
        }

        let id: String
        let title: String
        let symbol: String
        let searchText: String
        /// The section this page sits under, already localized. Consecutive items sharing a
        /// group draw one quiet caption above their run; nil rows stand on their own.
        var group: String?
        /// The page's static rows, for results that name a setting rather than a page.
        var entries: [Entry]

        init(
            id: String,
            title: String,
            symbol: String,
            searchText: String,
            group: String? = nil,
            entries: [Entry] = []
        ) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.searchText = searchText
            self.group = group
            self.entries = entries
        }
    }

    // MARK: - Properties

    /// Called with the stable page ID the user picked. Not fired by `select(id:)`, so the owner can set
    /// the initial page without re-entrancy.
    var onSelect: ((String) -> Void)?

    /// Called when a result that names a *setting* is picked: the page ID and the row title the
    /// pane should scroll to and mark.
    var onOpenSetting: ((String, String) -> Void)?

    /// Called with the trimmed query when the user asks the AI search to interpret it.
    var onAskAI: ((String) -> Void)?

    /// Whether the Ask AI affordance is offered at all — false when no eligible agent login
    /// exists. Set once by the owner; the affordance itself still appears only with a query,
    /// because with nothing typed there is nothing to interpret.
    var isAskAIAvailable = false {
        didSet {
            guard isAskAIAvailable != oldValue else { return }
            installAskAIIfNeeded()
            rebuildResults()
        }
    }

    /// The Ask AI button while it is on offer, nil while hidden — the contract the owner and
    /// the tests have always had, kept even though the button now lives inside the field and
    /// merely hides between queries.
    var askAIButton: ThemedButton? {
        searchField.isTrailingActionVisible ? searchField.trailingActionButton : nil
    }

    /// The field's ✕ while there is a query to clear, nil while hidden. For the tests.
    var clearSearchButton: ThemedIconButton? {
        searchField.clearButton.isHidden ? nil : searchField.clearButton
    }

    /// The field itself, so a test can drive the delegate seam the way the field editor does.
    var searchFieldForTesting: ThemedSearchField { searchField }

    private var items: [Item] = []
    private var displayedItems: [Item] = []
    private var rows: [ThemedTabItemView] = []
    /// The setting-level result rows on screen, one run per displayed page, for the tests.
    private(set) var hitRows: [SearchResultRowView] = []
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

    /// The results scroll: transparent, so the resting page list looks exactly as it did when
    /// the sidebar held its rows directly.
    private lazy var scrollView: ThemedScrollView = {
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = documentView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    private let documentView = SettingsFlippedView()
    private var resultsStack: NSStackView?

    /// Where a setting row's title starts: the page rows' own title column, so a result reads
    /// as belonging to the page above it.
    private var entryLeadingInset: CGFloat {
        ThemedTabItemView.Placement.sidebar.horizontalInset
            + Design.Size.tabIconSlot
            + Design.Spacing.small
    }

    // MARK: - Initialization

    init(items: [Item]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupChrome()
        build(items)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupChrome() {
        addSubview(searchField)
        addSubview(scrollView)
        documentView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(
                equalTo: searchField.bottomAnchor,
                constant: Design.Spacing.medium
            ),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])
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

    /// The setting-level results on screen, in order, for the tests.
    var visibleEntryTitles: [String] {
        hitRows.compactMap { $0.accessibilityTitle() }
    }

    // MARK: - Private Methods

    private func build(_ items: [Item]) {
        self.items = items
        rebuildResults()
    }

    private func installAskAIIfNeeded() {
        guard isAskAIAvailable else { return }
        searchField.installTrailingAction(
            title: L10n.string("Ask AI"),
            accessibilityLabel: L10n.string("Ask AI about settings"),
            accessibilityIdentifier: "settings.search.ask-ai",
            target: self,
            action: #selector(askAIClicked)
        )
    }

    private func rebuildResults() {
        resultsStack?.removeFromSuperview()
        rows = []
        hitRows = []

        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        displayedItems = query.isEmpty ? items : items.filter {
            SettingsSearch.matches(query: query, text: $0.searchText)
        }

        // Offered whenever there is a query to interpret, not only when the filter came up
        // empty: the filter matches words, and the page the user *means* is often not among
        // the pages their words matched. It rides inside the field so it is always in the same
        // place, however many results stand below.
        searchField.isTrailingActionVisible = !query.isEmpty && isAskAIAvailable

        var resultViews: [NSView] = []

        if query.isEmpty {
            // The resting list: rows interleaved with their group captions, one caption per
            // run, exactly as the sidebar has always drawn its geography.
            var lastGroup: String?
            for item in displayedItems {
                if let group = item.group, group != lastGroup {
                    resultViews.append(groupCaption(group, isFirst: resultViews.isEmpty))
                }
                lastGroup = item.group
                let row = makeRow(title: item.title, symbol: item.symbol, opens: item.id)
                rows.append(row)
                resultViews.append(row)
            }
        } else {
            // The results: each surviving page's row, then the settings the query landed on
            // inside it, each carrying its section as the path. Group captions stand down —
            // a result's geography is the page row above it, not the sidebar's sections.
            var overflowPageCount = 0
            for item in displayedItems {
                guard resultViews.count < Defaults.maximumResultRows else {
                    overflowPageCount += 1
                    continue
                }
                let row = makeRow(title: item.title, symbol: item.symbol, opens: item.id)
                rows.append(row)
                resultViews.append(row)

                for entry in item.entries where SettingsSearch.matches(
                    query: query,
                    text: entry.searchText
                ) {
                    guard resultViews.count < Defaults.maximumResultRows else { break }
                    let hit = makeEntryRow(entry, opens: item.id, matching: query)
                    hitRows.append(hit)
                    resultViews.append(hit)
                }
            }
            if overflowPageCount > 0 {
                resultViews.append(overflowLine(pageCount: overflowPageCount))
            }
        }

        if displayedItems.isEmpty {
            let noResults = NSTextField(
                wrappingLabelWithString: L10n.string("No settings found.")
            )
            noResults.applyFont(.subheading)
            noResults.textColor = Design.Text.secondary
            noResults.alignment = .center
            resultViews = [noResults]
        }

        let stack = NSStackView(views: resultViews)
        stack.orientation = .vertical
        stack.alignment = displayedItems.isEmpty ? .centerX : .leading
        stack.spacing = Design.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        resultsStack = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
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

    /// The cap saying what it cut: how many matching pages the capped list is not showing.
    /// A caption, not a control — narrowing the query is the way to reach them, and Ask AI
    /// rides the field above for exactly this situation.
    private func overflowLine(pageCount: Int) -> NSView {
        let label = NSTextField(
            labelWithString: pageCount == 1
                ? L10n.format("%lld more page matches", pageCount)
                : L10n.format("%lld more pages match", pageCount)
        )
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary
        label.lineBreakMode = .byTruncatingTail

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: Design.Spacing.medium
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

    @objc private func askAIClicked() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        onAskAI?(query)
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

    private func makeEntryRow(
        _ entry: Item.Entry,
        opens pageID: String,
        matching query: String
    ) -> SearchResultRowView {
        let row = SearchResultRowView(
            title: entry.title,
            path: entry.section,
            matching: query,
            leadingInset: entryLeadingInset,
            inkSource: .chrome
        )
        row.onSelect = { [weak self] in
            self?.select(id: pageID)
            self?.onOpenSetting?(pageID, entry.title)
        }
        return row
    }

}

// MARK: - NSTextFieldDelegate

extension SettingsSidebar: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        rebuildResults()
    }

    /// Escape clears a filled query and keeps the caret — Spotlight's contract, bound here
    /// because what Escape means belongs to the surface (`ThemedSearchField.clear` says why).
    /// An empty field lets the command travel on, exactly as before.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
              !searchField.stringValue.isEmpty else { return false }
        searchField.clear()
        return true
    }
}
