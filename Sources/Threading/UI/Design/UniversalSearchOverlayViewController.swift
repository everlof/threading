import AppKit

struct UniversalSearchScopeOption: Equatable {
    let id: String
    let title: String
}

struct UniversalSearchResultRow: Equatable {
    let id: SearchHitID
    let title: String
    let detail: String?
}

enum UniversalSearchOverlayRow: Equatable {
    case group(id: String, title: String)
    case result(UniversalSearchResultRow)
    case message(id: String, text: String)
}

struct UniversalSearchOverlayState: Equatable {
    let query: String
    let scopes: [UniversalSearchScopeOption]
    let selectedScopeID: String
    let rows: [UniversalSearchOverlayRow]
    let selectedHitID: SearchHitID?
    let status: String?
    let queryError: String?
}

/// The theme-owned, virtualized macOS shell for universal search. It knows display values and
/// callbacks only; parsing, providers, ranking, locators and activation stay outside Design.
@MainActor
final class UniversalSearchOverlayViewController: NSViewController {
    private enum Layout {
        static let width: CGFloat = 720
        static let preferredListHeight: CGFloat = 470
        static let minimumListHeight: CGFloat = 160
        @MainActor static var resultHeight: CGFloat {
            SearchResultRowView.preferredTableRowHeight
        }
        static let groupHeight: CGFloat = 30
        static let messageHeight: CGFloat = 36
        static let column = NSUserInterfaceItemIdentifier("universalSearch.column")
        static let result = NSUserInterfaceItemIdentifier("universalSearch.result")
        static let group = NSUserInterfaceItemIdentifier("universalSearch.group")
        static let message = NSUserInterfaceItemIdentifier("universalSearch.message")
    }

    var onQueryChange: ((String) -> Void)?
    var onScopeChange: ((String) -> Void)?
    var onSelectionChange: ((SearchHitID?) -> Void)?
    var onActivate: ((SearchHitID) -> Void)?
    var onDismiss: (() -> Void)?

    private let searchField = ThemedSearchField()
    private let scopeControl = ThemedSegmentedControl()
    private let tableView = ThemedTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let closeButton = ThemedButton(
        symbol: "xmark",
        accessibility: L10n.string("Close Search"),
        target: nil,
        action: nil
    )
    private var state = UniversalSearchOverlayState(
        query: "",
        scopes: [],
        selectedScopeID: "",
        rows: [],
        selectedHitID: nil,
        status: nil,
        queryError: nil
    )
    private var isApplyingState = false
    private let appEvents = AppEventObservations()

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let surface = ThemedSurfaceView()
        surface.applySurface(
            fill: Design.Surface.background,
            radius: .panel,
            border: Design.Surface.border
        )
        surface.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(surface)

        searchField.placeholderString = L10n.string("Search Threading")
        searchField.setAccessibilityLabel(L10n.string("Search Threading"))
        searchField.delegate = self

        scopeControl.setAccessibilityLabel(L10n.string("Search scope"))
        scopeControl.onSelect = { [weak self] index in
            guard let self, self.state.scopes.indices.contains(index) else { return }
            self.onScopeChange?(self.state.scopes[index].id)
        }

        closeButton.target = self
        closeButton.action = #selector(dismissSearch)

        let header = NSStackView(views: [searchField, scopeControl, closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Design.Spacing.small
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.style = .inset
        tableView.intercellSpacing = .zero
        tableView.target = self
        tableView.doubleAction = #selector(activateSelected)
        tableView.setAccessibilityLabel(L10n.string("Search results"))
        tableView.addTableColumn(NSTableColumn(identifier: Layout.column))

        // Result height is the component's live type measure. Re-ask it when a theme, typeface,
        // or semantic text scale changes instead of leaving the table on the cached height from
        // the theme under which the overlay opened.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            guard let self, !self.state.rows.isEmpty else { return }
            self.tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0 ..< self.state.rows.count)
            )
        }

        let scroll = ThemedScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)

        errorLabel.applyFont(.caption)
        errorLabel.textColor = Design.Status.negative
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true

        statusLabel.applyFont(.caption)
        statusLabel.textColor = Design.Text.tertiary
        statusLabel.lineBreakMode = .byTruncatingTail

        let footerHint = NSTextField(labelWithString: L10n.string("Return to open · Escape to close"))
        footerHint.applyFont(.caption)
        footerHint.textColor = Design.Text.tertiary
        footerHint.alignment = .right
        let footer = NSStackView(views: [statusLabel, footerHint])
        footer.orientation = .horizontal
        footer.alignment = .firstBaseline
        footer.distribution = .fill
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, errorLabel, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)

        let preferredHeight = scroll.heightAnchor.constraint(equalToConstant: Layout.preferredListHeight)
        // A covering surface may consume the room the window already has, never resize the
        // window to satisfy its preferred result count.
        preferredHeight.priority = .init(rawValue: 499)
        let preferredWidth = surface.widthAnchor.constraint(equalToConstant: Layout.width)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: root.topAnchor, constant: Design.Spacing.pane),
            surface.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            surface.leadingAnchor.constraint(
                greaterThanOrEqualTo: root.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            surface.trailingAnchor.constraint(
                lessThanOrEqualTo: root.trailingAnchor,
                constant: -Design.Spacing.pane
            ),
            surface.bottomAnchor.constraint(
                lessThanOrEqualTo: root.bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            preferredWidth,
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -Design.Spacing.pane),
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: Design.Spacing.pane),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -Design.Spacing.pane),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumListHeight),
            preferredHeight,
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    func apply(_ state: UniversalSearchOverlayState) {
        _ = view
        isApplyingState = true
        self.state = state
        if searchField.stringValue != state.query { searchField.stringValue = state.query }

        let selectedScope = state.scopes.firstIndex { $0.id == state.selectedScopeID } ?? 0
        if scopeControl.titles != state.scopes.map(\.title) {
            scopeControl.configure(titles: state.scopes.map(\.title), selectedIndex: selectedScope)
        } else {
            scopeControl.selectedIndex = selectedScope
        }

        errorLabel.stringValue = state.queryError ?? ""
        errorLabel.isHidden = state.queryError == nil
        statusLabel.stringValue = state.status ?? ""
        tableView.reloadData()
        restoreSelection(state.selectedHitID)
        isApplyingState = false
    }

    func focusQuery(selectingAll: Bool = false) {
        _ = view
        view.window?.makeFirstResponder(searchField)
        guard selectingAll, let editor = searchField.currentEditor() else { return }
        editor.selectedRange = NSRange(location: 0, length: searchField.stringValue.utf16.count)
    }

    private func restoreSelection(_ hitID: SearchHitID?) {
        let row = state.rows.firstIndex {
            guard case let .result(result) = $0 else { return false }
            return result.id == hitID
        }
        if let row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
    }

    @objc private func dismissSearch() { onDismiss?() }

    @objc private func activateSelected() {
        let row = tableView.selectedRow
        guard state.rows.indices.contains(row), case let .result(result) = state.rows[row] else { return }
        onActivate?(result.id)
    }
}

extension UniversalSearchOverlayViewController: NSTextFieldDelegate {
    func controlTextDidChange(_: Notification) {
        guard !isApplyingState else { return }
        onQueryChange?(searchField.stringValue)
    }

    func control(
        _: NSControl,
        textView _: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelected()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(by offset: Int) {
        let selectable = state.rows.indices.filter {
            if case .result = state.rows[$0] { return true }
            return false
        }
        guard !selectable.isEmpty else { return }
        let current = selectable.firstIndex(of: tableView.selectedRow)
        let next: Int
        if let current {
            next = min(max(current + offset, 0), selectable.count - 1)
        } else {
            next = offset < 0 ? selectable.count - 1 : 0
        }
        tableView.selectRowIndexes(IndexSet(integer: selectable[next]), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectable[next])
    }
}

extension UniversalSearchOverlayViewController: NSTableViewDataSource {
    func numberOfRows(in _: NSTableView) -> Int { state.rows.count }
}

extension UniversalSearchOverlayViewController: NSTableViewDelegate {
    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard state.rows.indices.contains(row) else { return Layout.messageHeight }
        switch state.rows[row] {
        case .group: return Layout.groupHeight
        case .result: return Layout.resultHeight
        case .message: return Layout.messageHeight
        }
    }

    func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard state.rows.indices.contains(row) else { return false }
        if case .result = state.rows[row] { return true }
        return false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor _: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard state.rows.indices.contains(row) else { return nil }
        switch state.rows[row] {
        case let .group(_, title):
            let label = (tableView.makeView(withIdentifier: Layout.group, owner: self) as? NSTextField)
                ?? NSTextField(labelWithString: "")
            label.identifier = Layout.group
            label.applyFont(.detail(weight: .semibold))
            label.textColor = Design.Text.secondary
            label.stringValue = title
            return label

        case let .message(_, text):
            let label = (tableView.makeView(withIdentifier: Layout.message, owner: self) as? NSTextField)
                ?? NSTextField(labelWithString: "")
            label.identifier = Layout.message
            label.applyFont(.caption)
            label.textColor = Design.Text.tertiary
            label.stringValue = text
            return label

        case let .result(result):
            let resultView: SearchResultRowView
            if let reused = tableView.makeView(withIdentifier: Layout.result, owner: self)
                as? SearchResultRowView
            {
                resultView = reused
                resultView.show(title: result.title, path: result.detail, matching: state.query)
            } else {
                resultView = SearchResultRowView(
                    title: result.title,
                    path: result.detail,
                    matching: state.query,
                    leadingInset: Design.Spacing.small,
                    inkSource: .chrome
                )
                resultView.identifier = Layout.result
            }
            resultView.onSelect = { [weak self] in self?.onActivate?(result.id) }
            return resultView
        }
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !isApplyingState else { return }
        let row = tableView.selectedRow
        guard state.rows.indices.contains(row), case let .result(result) = state.rows[row] else {
            onSelectionChange?(nil)
            return
        }
        onSelectionChange?(result.id)
    }
}
