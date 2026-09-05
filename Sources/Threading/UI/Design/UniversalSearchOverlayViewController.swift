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
        /// How far the list may grow before it scrolls instead of the panel getting taller.
        static let preferredListHeight: CGFloat = 470
        /// The floor a *cramped window* may squeeze the list to — never a floor on a short
        /// result set, which is the mistake it used to be: a query with three matches drew a
        /// hundred and eighty points of empty panel below them because the list was a fixed
        /// 470 and this was a required 160 under it. A palette is the size of its answer.
        static let minimumListHeight: CGFloat = 160
        @MainActor static var resultHeight: CGFloat {
            SearchResultRowView.preferredTableRowHeight
        }
        /// A group name is a section start, so its row carries the air *above* it and sets the
        /// label on its own baseline at the bottom. Given the same 10 points as the gap between
        /// two results, "Conversations" read as another row of the list rather than as the
        /// heading of what follows it.
        static let groupHeight: CGFloat = 38
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
    private var listFittedHeight: NSLayoutConstraint?
    private var listCrushFloor: NSLayoutConstraint?
    private let appEvents = AppEventObservations()

    override func loadView() {
        let root = UniversalSearchOverlayRootView()
        root.onDismiss = { [weak self] in self?.onDismiss?() }
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

        // A mark rather than a control: `Emphasis.tertiary` is what the vocabulary says a close
        // button is, and it was drawing a bordered button's plate beside a field and a scope run
        // that both already carry one — three surfaces across a row that asks one question.
        closeButton.emphasis = .tertiary
        closeButton.target = self
        closeButton.action = #selector(dismissSearch)

        // A row, not a stack: the field, the scope run and the ✕ each used to state their own
        // height — 32, 26 and 26 — so the two controls beside the query floated three points
        // clear of its top and bottom edges, and the mismatch changed with the theme because
        // only one of the three numbers was the theme's. The row owns the height and every
        // member takes it, and the query takes the slack rather than the air after it.
        let header = ControlRowView(
            scale: .field,
            leading: [searchField],
            trailing: [scopeControl, closeButton],
            stretching: searchField
        )
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
            // The panel is the size of those rows, so the sweep that re-measures them has to
            // re-measure the panel as well.
            self.applyListHeight()
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

        // The list is as tall as its answer, up to the point where it scrolls instead. Both
        // constants are written by `apply(_:)`; these are the shapes, not the numbers.
        let fittedHeight = scroll.heightAnchor.constraint(equalToConstant: Layout.preferredListHeight)
        // A covering surface may consume the room the window already has, never resize the
        // window to satisfy its preferred result count.
        fittedHeight.priority = .init(rawValue: 499)
        listFittedHeight = fittedHeight
        let crushFloor = scroll.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Layout.minimumListHeight
        )
        listCrushFloor = crushFloor
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
            crushFloor,
            fittedHeight,
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        applyListHeight()
    }

    /// Sizes the list to what it is showing.
    ///
    /// The table is asked rather than told: `tile()` re-derives the document view's height from
    /// the rows it is currently holding, which is the same O(rows) pass over the same capped
    /// array `reloadData` already makes, and is the *table's* arithmetic rather than a second
    /// copy of it — a sum written here would be a few points out the moment a style added an
    /// inset, and a list a few points short of its own content scrolls. Re-derived on every
    /// apply and on a theme change, because a row's height is a live type measure.
    private func applyListHeight() {
        tableView.tile()
        let content = tableView.frame.height + listVerticalInset
        listFittedHeight?.constant = min(content, Layout.preferredListHeight)
        // The floor is the window running out of room, not the query running out of matches:
        // a list already shorter than the floor is asking for nothing and must not be padded
        // up to it.
        listCrushFloor?.constant = min(content, Layout.minimumListHeight)
    }

    /// How tall each kind of row stands. The table asks; the panel does not, because it asks
    /// the table for the total instead — one owner of this arithmetic, and a list sized from a
    /// second copy of it is a list a few points short of its own last row.
    private func height(ofRow row: Int) -> CGFloat {
        guard state.rows.indices.contains(row) else { return Layout.messageHeight }
        switch state.rows[row] {
        case .group: return Layout.groupHeight
        case .result: return Layout.resultHeight
        case .message: return Layout.messageHeight
        }
    }

    /// The room the scroll view needs beyond its rows — its own content insets and the rule it
    /// is drawn with. Read from the scroll view rather than accumulated from its current height,
    /// which would make the answer a function of the constant it is being used to write.
    private var listVerticalInset: CGFloat {
        guard let scroll = tableView.enclosingScrollView else { return 0 }
        return scroll.contentInsets.top + scroll.contentInsets.bottom
            + Design.Radius.border * 2
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
        applyListHeight()
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
    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat { height(ofRow: row) }

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
            let header = (tableView.makeView(withIdentifier: Layout.group, owner: self)
                as? SearchListLabelRow)
                ?? SearchListLabelRow(alignment: .sectionName)
            header.identifier = Layout.group
            header.show(title, font: .detail(weight: .semibold), ink: Design.Text.secondary)
            return header

        case let .message(_, text):
            let row = (tableView.makeView(withIdentifier: Layout.message, owner: self)
                as? SearchListLabelRow)
                ?? SearchListLabelRow(alignment: .centred)
            row.identifier = Layout.message
            row.show(text, font: .caption, ink: Design.Text.tertiary)
            return row

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

// MARK: - List Labels

/// A row of the results list that is words rather than a result: a section name, or the note
/// saying the group was capped.
///
/// It exists because a bare `NSTextField` returned as a cell view is centred in its row by
/// AppKit, and both of these rows want something else. A section name wants the air *above* it,
/// so that "Conversations" reads as the heading of what follows rather than as another entry
/// between two results — given equal air it read as the latter, which is what the list looked
/// like. Both want their ink on the same leading edge as a result's title, which a label pinned
/// to the row's own edge misses by `SearchResultRowView`'s inset.
private final class SearchListLabelRow: NSView {

    /// Where the words sit in the row's height.
    enum Alignment {
        /// On the bottom, so the row's spare height becomes the section's air above.
        case sectionName
        /// In the middle, for a line that belongs to the rows around it equally.
        case centred
    }

    private let label = NSTextField(labelWithString: "")

    init(alignment: Alignment) {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        addSubview(label)

        let vertical: NSLayoutConstraint
        switch alignment {
        case .sectionName:
            vertical = label.lastBaselineAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -SearchListLabelRowLayout.baselineFromBottom
            )
        case .centred:
            vertical = label.centerYAnchor.constraint(equalTo: centerYAnchor)
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SearchListLabelRowLayout.leadingInset
            ),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Design.Spacing.medium
            ),
            vertical
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ text: String, font: Design.FontRole, ink: NSColor) {
        label.applyFont(font)
        label.textColor = ink
        label.stringValue = text
    }
}

@MainActor
private enum SearchListLabelRowLayout {
    /// The same inset `SearchResultRowView` gives its own labels, so a heading and the titles
    /// under it stand on one edge.
    static let leadingInset: CGFloat = Design.Spacing.small

    /// How far a section name's baseline sits above the results that follow it — the gap a
    /// result row already keeps between its own two lines, so the heading joins the rhythm of
    /// the list instead of setting a second one.
    static let baselineFromBottom: CGFloat = Design.Spacing.small
}

// MARK: - Escape

@MainActor
private enum UniversalSearchOverlayKeys {
    static let escape: UInt16 = 53
}

/// The surface's own root, which is where Escape is answered.
///
/// Universal Search bound Escape on the query field's `control(_:textView:doCommandBy:)` seam
/// and nowhere else, so the key closed the palette from the one place the palette had put the
/// caret and from none of the others: click a result, tab to the scope run, or let anything else
/// in the window take the keyboard, and Escape reached a responder that had never heard of the
/// surface covering it. The three overrides are the same set `CompareInspectorView` arrived at,
/// for the same reason — a plain Escape is not a key equivalent, so it is offered to the first
/// responder as `keyDown` and turned into `cancelOperation(_:)` only by whatever calls
/// `interpretKeyEvents`. `cancelOperation` is the one that carries in the app; `keyDown` catches
/// a control that passed the key up itself; `performKeyEquivalent` is what a fixture pressing
/// Escape by hand goes through. Escape belongs to the transient surface, not to whichever child
/// happens to hold focus inside it.
private final class UniversalSearchOverlayRootView: NSView {

    var onDismiss: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == UniversalSearchOverlayKeys.escape else {
            super.keyDown(with: event)
            return
        }
        onDismiss?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.keyCode == UniversalSearchOverlayKeys.escape else {
            return super.performKeyEquivalent(with: event)
        }
        onDismiss?()
        return true
    }
}
