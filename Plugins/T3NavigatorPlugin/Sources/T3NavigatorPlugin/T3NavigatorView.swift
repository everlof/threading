import AppKit
import ThreadingDesignKit
import ThreadingPluginKit

/// T3's information architecture expressed with Threading's public native component grammar.
///
/// This is the reference lane for a native navigator that wants to look at home: the extension
/// owns grouping and composition, while the design kit owns pane bands, fields, table chrome,
/// selection, controls, typography, spacing, radii, and the active palette. Rows stay virtual —
/// workspace size is host data, so only the table's viewport may own views.
@MainActor
final class T3NavigatorView: NSView, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    private enum Item {
        case section(T3NavigatorSection, count: Int)
        case row(T3NavigatorRow)
    }

    private enum AgeRefresh {
        static let interval: TimeInterval = 60
        static let tolerance: TimeInterval = 10
    }

    private enum Reuse {
        static let row = NSUserInterfaceItemIdentifier("t3.navigator.thread-row")
        static let section = NSUserInterfaceItemIdentifier("t3.navigator.section-row")
        static let column = NSUserInterfaceItemIdentifier("t3.navigator.column")
    }

    private let store: T3NavigatorStore
    private var items: [Item] = []
    private var collapsedSections = Set<T3NavigatorSection>()
    private var isSynchronizingSelection = false
    private var projectPicker: T3ProjectPickerViewController?
    private let projectPopover = ThemedPopover()
    private var contextMenuSession: AnyObject?
    /// Quiet rows carry their age ("5m", "2h"); this re-reads the clock for the rows on screen
    /// so a card does not say "now" an hour later. Bounded to the viewport, and stopped while the
    /// navigator is off any window.
    private var ageRefreshTimer: Timer?

    private let headingLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Threads")
        label.applyFont(.heading)
        label.textColor = Design.Text.label
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("t3.navigator.title")
        return label
    }()

    private lazy var projectButton: ThemedButton = {
        let button = ThemedButton(
            symbol: "folder",
            accessibility: "Filter threads by project",
            target: self,
            action: #selector(showProjectPicker)
        )
        button.emphasis = .tertiary
        button.contentAlignment = .leading
        button.showsSubmenuIndicator = true
        button.setAccessibilityIdentifier("t3.navigator.project-picker")
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }()

    private lazy var header = PaneHeaderView(
        leading: [headingLabel],
        trailing: [projectButton],
        margin: .paneEdge
    )

    private let searchField: ThemedSearchField = {
        let field = ThemedSearchField()
        field.placeholderString = "Search threads"
        field.setAccessibilityLabel("Search threads")
        field.setAccessibilityIdentifier("t3.navigator.search")
        return field
    }()

    private lazy var searchRow = ControlRowView(
        scale: .field,
        leading: [searchField],
        stretching: searchField
    )
    private let searchSeparator = SeparatorView()

    private let table: ThemedTableView = {
        let table = ThemedTableView()
        table.headerView = nil
        table.style = .inset
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Threads")
        table.setAccessibilityIdentifier("t3.navigator.thread-list")
        return table
    }()

    private lazy var scroll: ThemedScrollView = {
        let scroll = ThemedScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.surfaceRole = .sidebarNavigator
        scroll.contentBreathing = NSEdgeInsets(
            top: Design.Spacing.tight,
            left: Design.Spacing.tight,
            bottom: Design.Spacing.small,
            right: Design.Spacing.tight
        )
        return scroll
    }()

    private let emptyState = T3NavigatorEmptyStateView()

    init(store: T3NavigatorStore) {
        self.store = store
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        setAccessibilityIdentifier("t3.navigator")
        setupViews()
        bindStore()
        rebuildItems()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: AppThemeDidChange.name,
            object: nil
        )
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        applyThemeMetrics()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Design.Surface.background.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        reportVisibleRows()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            store.reportVisibleRows([])
            ageRefreshTimer?.invalidate()
            ageRefreshTimer = nil
        } else if ageRefreshTimer == nil {
            // The timer holds the navigator weakly and retires itself once the navigator is
            // gone, so a torn-down pane leaves no tick behind and `deinit` never has to reach
            // a main-actor timer from its nonisolated context.
            let timer = Timer(timeInterval: AgeRefresh.interval, repeats: true) { [weak self] timer in
                guard self != nil else {
                    timer.invalidate()
                    return
                }
                MainActor.assumeIsolated { self?.refreshVisibleRowPresentation() }
            }
            timer.tolerance = AgeRefresh.tolerance
            RunLoop.main.add(timer, forMode: .common)
            ageRefreshTimer = timer
        }
    }

    private func refreshVisibleRowPresentation() {
        for row in visibleTableRows() {
            updateVisibleRow(at: row)
        }
    }

    private func setupViews() {
        searchField.delegate = self
        table.dataSource = self
        table.delegate = self
        table.onContextMenu = { [weak self] row, anchor in
            self?.showContextMenu(forTableRow: row, anchor: anchor) ?? false
        }
        table.addTableColumn(NSTableColumn(identifier: Reuse.column))

        for child in [header, searchRow, searchSeparator, scroll, emptyState] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),

            searchRow.topAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: Design.Spacing.small
            ),
            searchRow.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Spacing.medium
            ),
            searchRow.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.medium
            ),

            searchSeparator.topAnchor.constraint(
                equalTo: searchRow.bottomAnchor,
                constant: Design.Spacing.small
            ),
            searchSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: searchSeparator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
        ])
    }

    private func bindStore() {
        store.onPresentationChange = { [weak self] change in
            guard let self else { return }
            switch change {
            case .reloadAll:
                self.rebuildItems()
            case .reloadRow(let row):
                self.reload(row)
            case .selection:
                self.synchronizeSelection()
            }
        }
    }

    private func rebuildItems() {
        var next: [Item] = []
        for section in T3NavigatorSection.allCases {
            let rows = store.visibleRows(in: section)
            guard !rows.isEmpty else { continue }
            next.append(.section(section, count: rows.count))
            if !collapsedSections.contains(section) {
                next.append(contentsOf: rows.map(Item.row))
            }
        }
        items = next
        applyTableRowMetric()
        table.reloadData()
        projectButton.title = store.selectedProjectTitle
        projectButton.setAccessibilityValue(store.selectedProjectTitle)
        emptyState.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        synchronizeSelection()
        DispatchQueue.main.async { [weak self] in self?.reportVisibleRows() }
    }

    private func reload(_ model: T3NavigatorRow) {
        guard let index = index(of: model) else { return }
        table.reloadData(
            forRowIndexes: IndexSet(integer: index),
            columnIndexes: IndexSet(integer: 0)
        )
        updateVisibleRow(at: index)
    }

    private func index(of model: T3NavigatorRow) -> Int? {
        items.firstIndex {
            guard case .row(let candidate) = $0 else { return false }
            return candidate === model
        }
    }

    private func synchronizeSelection() {
        let selectedIndex = items.firstIndex {
            guard case .row(let row) = $0 else { return false }
            return row.isSelected
        }
        isSynchronizingSelection = true
        if let selectedIndex {
            table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        isSynchronizingSelection = false
        for row in visibleTableRows() {
            updateVisibleRow(at: row)
        }
    }

    private func updateVisibleRow(at index: Int) {
        guard index >= 0, index < items.count,
              case .row = items[index],
              let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false)
                as? T3NavigatorRowCell
        else { return }
        cell.updatePresentation()
    }

    private func visibleTableRows() -> Range<Int> {
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return 0..<0 }
        return visible.location..<NSMaxRange(visible)
    }

    private func reportVisibleRows() {
        let rows = visibleTableRows().compactMap { index -> T3NavigatorRow? in
            guard index >= 0, index < items.count, case .row(let row) = items[index] else {
                return nil
            }
            return row
        }
        store.reportVisibleRows(rows)
    }

    /// T3's thread card is a stable three-band row: project with status or age, title, then
    /// branch and source-control receipt. The title is the row's one strong reading; metadata
    /// stays quiet, and neither a status edge nor a receipt ever changes the row's geometry, so
    /// neighbouring threads never jump. Ten points above and below is T3's card padding plus
    /// the gap it keeps between cards.
    private func rowHeight() -> CGFloat {
        ceil(
            Design.Typography.lineHeight(of: Design.Typography.detail())
                + Design.Spacing.tight
                + Design.Typography.lineHeight(of: Design.Typography.emphasizedBody())
                + Design.Spacing.hairline
                + Design.Typography.lineHeight(of: Design.Typography.detail())
                + Design.Spacing.medium * 2
        )
    }

    private func sectionHeight() -> CGFloat {
        max(SidebarDefaults.rowHeight, Design.Size.choiceHeight)
    }

    private func applyThemeMetrics() {
        applyTableRowMetric()
        projectButton.title = store.selectedProjectTitle
        projectPicker?.applyTheme()
    }

    private func applyTableRowMetric() {
        table.rowHeight = rowHeight()
    }

    @objc private func themeDidChange() {
        applyThemeMetrics()
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
        for row in visibleTableRows() {
            updateVisibleRow(at: row)
        }
        if let projectPicker {
            AppThemeRefresh.repaint(projectPicker.view)
        }
    }

    @objc private func visibleBoundsDidChange() {
        reportVisibleRows()
    }

    @objc private func showProjectPicker() {
        if projectPopover.isShown {
            projectPopover.close()
            return
        }
        let picker = T3ProjectPickerViewController(store: store)
        picker.onSelect = { [weak self] identifier in
            guard let self else { return }
            self.store.selectProject(identifier)
            self.projectPopover.close()
        }
        picker.onCancel = { [weak self] in self?.projectPopover.close() }
        projectPicker = picker
        projectPopover.behavior = .transient
        projectPopover.contentViewController = picker
        projectPopover.initialFirstResponder = picker.searchFieldForPresentation
        projectPopover.onClose = { [weak self] in self?.projectPicker = nil }
        projectPopover.show(
            relativeTo: projectButton.bounds,
            of: projectButton,
            preferredEdge: .maxY
        )
    }

    @objc private func toggleSection(_ sender: ThemedButton) {
        guard let value = sender.identifier?.rawValue,
              let section = T3NavigatorSection(rawValue: value) else { return }
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
        rebuildItems()
    }

    @objc private func openSelectedThread() {
        let index = table.selectedRow
        guard index >= 0, index < items.count, case .row(let row) = items[index] else { return }
        if !store.activate(row) { synchronizeSelection() }
    }

    private func showContextMenu(forTableRow index: Int, anchor: ThemedMenuAnchor) -> Bool {
        guard index >= 0, index < items.count,
              case .row(let row) = items[index],
              !row.isArchived,
              let source = table.rowView(atRow: index, makeIfNecessary: false)
        else { return false }

        var entries: [ThemedMenuEntry] = []
        if let request = row.changeRequest {
            entries.append(.item(ThemedMenuItem(
                title: "Open \(request.changeRequestName) #\(request.number)",
                image: ThemedMenuIcon.symbol("arrow.up.forward.app"),
                onChoose: { [weak self, weak row] in
                    guard let row else { return }
                    _ = self?.store.openChangeRequest(row)
                }
            )))
            entries.append(.separator)
        }
        entries.append(contentsOf: [
            .item(ThemedMenuItem(
                title: row.isPinned ? "Unpin" : "Pin",
                image: ThemedMenuIcon.symbol(row.isPinned ? "pin.slash" : "pin"),
                onChoose: { [weak self, weak row] in
                    guard let row else { return }
                    self?.store.togglePin(row)
                }
            )),
            .item(ThemedMenuItem(
                title: "Archive",
                image: ThemedMenuIcon.symbol("archivebox"),
                onChoose: { [weak self, weak row] in
                    guard let row else { return }
                    self?.store.archive(row)
                }
            )),
        ])
        contextMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: SidebarDefaults.menuWidth),
            from: source,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.contextMenuSession = nil }
        )
        return contextMenuSession != nil
    }

    func controlTextDidChange(_ notification: Notification) {
        store.searchText = searchField.stringValue
    }

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

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row index: Int
    ) -> NSView? {
        guard index >= 0, index < items.count else { return nil }
        switch items[index] {
        case .section(let section, let count):
            let host = (tableView.makeView(withIdentifier: Reuse.section, owner: self)
                as? ThemedVirtualTableCell) ?? ThemedVirtualTableCell()
            host.identifier = Reuse.section
            let symbol = collapsedSections.contains(section) ? "chevron.right" : "chevron.down"
            let button = ThemedButton(
                symbol: symbol,
                accessibility: "\(section.rawValue), \(count) threads",
                target: self,
                action: #selector(toggleSection(_:))
            )
            button.title = "\(section.rawValue.uppercased())  \(count)"
            button.emphasis = .tertiary
            button.contentAlignment = .leading
            button.identifier = NSUserInterfaceItemIdentifier(section.rawValue)
            button.setAccessibilityIdentifier(
                "t3.navigator.section.\(section.rawValue.lowercased())"
            )
            host.install(
                button,
                columnWidth: tableView.bounds.width,
                horizontalInset: Design.Spacing.tight
            )
            return host

        case .row(let row):
            let cell = (tableView.makeView(withIdentifier: Reuse.row, owner: self)
                as? T3NavigatorRowCell) ?? T3NavigatorRowCell()
            cell.identifier = Reuse.row
            cell.configure(
                row: row,
                projectTitle: store.projectTitle(for: row.projectIdentifier),
                onPin: { [weak self] row in self?.store.togglePin(row) },
                onArchive: { [weak self] row in self?.store.archive(row) },
                onOpenChangeRequest: { [weak self] row in
                    _ = self?.store.openChangeRequest(row)
                }
            )
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < items.count else { return rowHeight() }
        switch items[row] {
        case .section: return sectionHeight()
        case .row: return rowHeight()
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < items.count else { return false }
        if case .row = items[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSynchronizingSelection else { return }
        openSelectedThread()
    }

    func tableView(
        _ tableView: NSTableView,
        rowViewForRow row: Int
    ) -> NSTableRowView? {
        ThemedTableRowView()
    }

    // Test seams prove composition and viewport ownership without exposing implementation to the
    // plugin ABI.
    var tableForTesting: ThemedTableView { table }
    var searchFieldForTesting: ThemedSearchField { searchField }
    var headerForTesting: PaneHeaderView { header }
}

/// How long ago a quiet thread was last active, the way T3 dates a card: a bare count of
/// minutes, hours or days, and "now" under a minute. There is no "ago" because the label sits
/// at the far edge of a narrow band and the reader already knows what a trailing age means.
enum T3ThreadAge {
    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400
    static let nowLabel = "now"

    static func label(since date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= minute else { return nowLabel }
        if elapsed < hour { return "\(Int(elapsed / minute))m" }
        if elapsed < day { return "\(Int(elapsed / hour))h" }
        return "\(Int(elapsed / day))d"
    }

    static func accessibilityValue(since date: Date, now: Date = Date()) -> String {
        let label = label(since: date, now: now)
        return label == nowLabel ? "Last active just now" : "Last active \(label) ago"
    }
}

/// One thread in T3's card silhouette.
///
/// Three bands: a quiet project line whose far edge carries either a live status or the thread's
/// age, the title as the row's one strong reading, and a quiet metadata line with the branch and
/// one source-control receipt. Colour is spent only on words that change what the reader does
/// next — a working, ready, input, attention or limit state, and the change request's number —
/// and everything else sits on the chrome's ink ramp so the title stays the loudest thing in the
/// row. There are no decorative glyphs beside the branch or the receipt: T3's card reads as text,
/// and every mark it does draw is carrying a state.
@MainActor
private final class T3NavigatorRowCell: NSTableCellView, ThemeDerivedContent {
    /// What the trailing slot of the project band says while the pointer is elsewhere.
    private enum Status {
        enum Tone {
            case accent, positive, warning, negative
        }

        /// The mark beside a live word: the working spinner, a symbol, or nothing.
        enum Mark {
            case spinner, symbol(String), none
        }

        /// A live state worth a coloured word, with the mark that belongs beside it.
        case live(label: String, mark: Mark, tone: Tone)
        /// A quiet thread, dated by how long since it was active.
        case age(Date)
        case none
    }

    private enum Strings {
        static let untitled = "Untitled thread"
        static let working = "Working"
        static let ready = "Ready"
        static let input = "Input"
        static let attention = "Attention"
        static let limit = "Limit"
    }

    private enum Symbols {
        static let project = "folder.fill"
        static let ready = "checkmark.circle.fill"
        static let changeRequest = "arrow.triangle.pull"
    }

    private weak var model: T3NavigatorRow?
    private var onPin: ((T3NavigatorRow) -> Void)?
    private var onArchive: ((T3NavigatorRow) -> Void)?
    private var onOpenChangeRequest: ((T3NavigatorRow) -> Void)?
    private var isHovered = false

    /// AppKit changes this when the table's selection moves between the active accent and its
    /// quiet inactive presentation. The controls inside the row have to follow the ground the row
    /// actually painted, just as Threading's built-in session rows do.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updatePresentation() }
    }

    private let projectGlyph = GlyphView()
    private let projectLabel = NSTextField(labelWithString: "")
    private let statusSlot = NSView()
    private let activitySlot = NSView()
    private let activityGlyph = GlyphView()
    private let spinner = ThemedSpinner()
    private let activityLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let changeRequestGlyph = GlyphView()
    private let changeRequestLabel = NSTextField(labelWithString: "")
    private let pinButton = ThemedIconButton(
        symbolName: "pin",
        accessibility: "Pin thread",
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )
    private let archiveButton = ThemedIconButton(
        symbolName: "archivebox",
        accessibility: "Archive thread",
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )
    private let openChangeRequestButton = ThemedIconButton(
        symbolName: "arrow.up.forward.app",
        accessibility: "Open change request",
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )
    private lazy var actionStack = NSStackView(
        views: [openChangeRequestButton, pinButton, archiveButton]
    )
    private lazy var activityStack = NSStackView(views: [activitySlot, activityLabel])
    private lazy var projectStack = NSStackView(views: [projectGlyph, projectLabel])
    private lazy var changeRequestStack = NSStackView(
        views: [changeRequestGlyph, changeRequestLabel]
    )
    private var statusWidthConstraint: NSLayoutConstraint?
    private var areActionsPresented = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidUpdate(_:)),
            name: NSWindow.didUpdateNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupViews() {
        projectGlyph.setSymbol(
            Symbols.project,
            slot: Design.Size.extensionIconImage,
            role: .control,
            weight: .medium
        )
        projectLabel.applyFont(.detail(weight: .medium))
        projectLabel.lineBreakMode = .byTruncatingTail
        projectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        activityLabel.applyFont(.detail(weight: .medium))
        activityLabel.lineBreakMode = .byClipping
        activityLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        activityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.applyFont(.emphasizedBody)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        branchLabel.applyFont(.detail())
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        changeRequestGlyph.setSymbol(
            Symbols.changeRequest,
            slot: Design.Size.extensionDecorationImage,
            role: .control,
            weight: .medium
        )
        changeRequestLabel.applyFont(.numericDetail(weight: .medium))
        changeRequestLabel.lineBreakMode = .byTruncatingTail
        changeRequestLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        changeRequestLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        activityGlyph.translatesAutoresizingMaskIntoConstraints = false
        activitySlot.translatesAutoresizingMaskIntoConstraints = false
        activitySlot.addSubview(spinner)
        activitySlot.addSubview(activityGlyph)
        NSLayoutConstraint.activate([
            activitySlot.widthAnchor.constraint(equalToConstant: Design.Size.extensionIconImage),
            activitySlot.heightAnchor.constraint(equalToConstant: Design.Size.extensionIconImage),
            spinner.centerXAnchor.constraint(equalTo: activitySlot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: activitySlot.centerYAnchor),
            activityGlyph.centerXAnchor.constraint(equalTo: activitySlot.centerXAnchor),
            activityGlyph.centerYAnchor.constraint(equalTo: activitySlot.centerYAnchor),
        ])

        for stack in [activityStack, projectStack] {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = Design.Spacing.tight
        }
        projectStack.setHuggingPriority(.defaultLow, for: .horizontal)
        projectStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        changeRequestStack.orientation = .horizontal
        changeRequestStack.alignment = .centerY
        changeRequestStack.spacing = Design.Spacing.hairline
        changeRequestStack.setHuggingPriority(.defaultHigh, for: .horizontal)
        changeRequestStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = Design.Spacing.hairline
        statusSlot.translatesAutoresizingMaskIntoConstraints = false
        activityStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        statusSlot.addSubview(activityStack)
        statusSlot.addSubview(actionStack)
        NSLayoutConstraint.activate([
            activityStack.leadingAnchor.constraint(greaterThanOrEqualTo: statusSlot.leadingAnchor),
            activityStack.trailingAnchor.constraint(equalTo: statusSlot.trailingAnchor),
            activityStack.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
            actionStack.leadingAnchor.constraint(greaterThanOrEqualTo: statusSlot.leadingAnchor),
            actionStack.trailingAnchor.constraint(equalTo: statusSlot.trailingAnchor),
            actionStack.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
        ])
        statusWidthConstraint = statusSlot.widthAnchor.constraint(equalTo: activityStack.widthAnchor)
        statusWidthConstraint?.isActive = true

        let topRow = NSStackView(views: [projectStack, statusSlot])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = Design.Spacing.small
        projectStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusSlot.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let bottomRow = NSStackView(views: [branchLabel, changeRequestStack])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .firstBaseline
        bottomRow.spacing = Design.Spacing.small

        let content = NSStackView(views: [topRow, titleLabel, bottomRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Design.Spacing.hairline
        content.setCustomSpacing(Design.Spacing.tight, after: topRow)
        content.setHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.medium),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.medium),
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Spacing.medium
            ),
            content.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.medium
            ),
            topRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            topRow.heightAnchor.constraint(
                greaterThanOrEqualToConstant: Design.Typography.lineHeight(
                    of: Design.Typography.detail()
                )
            ),
            bottomRow.heightAnchor.constraint(
                greaterThanOrEqualToConstant: Design.Typography.lineHeight(
                    of: Design.Typography.detail()
                )
            ),
        ])

        pinButton.onPress = { [weak self] in
            guard let self, let model = self.model else { return }
            self.onPin?(model)
        }
        archiveButton.onPress = { [weak self] in
            guard let self, let model = self.model else { return }
            self.onArchive?(model)
        }
        openChangeRequestButton.onPress = { [weak self] in
            guard let self, let model = self.model else { return }
            self.onOpenChangeRequest?(model)
        }

        updateActions()
    }

    func configure(
        row: T3NavigatorRow,
        projectTitle: String,
        onPin: @escaping (T3NavigatorRow) -> Void,
        onArchive: @escaping (T3NavigatorRow) -> Void,
        onOpenChangeRequest: @escaping (T3NavigatorRow) -> Void
    ) {
        model = row
        self.onPin = onPin
        self.onArchive = onArchive
        self.onOpenChangeRequest = onOpenChangeRequest
        titleLabel.stringValue = row.title.isEmpty ? Strings.untitled : row.title
        projectLabel.stringValue = projectTitle
        let branch = row.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        branchLabel.stringValue = branch
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(titleLabel.stringValue)
        configureStatus(status(for: row))
        configureChangeRequest(row.changeRequest)
        setAccessibilityValue([
            statusAccessibilityValue(status(for: row)),
            projectLabel.stringValue,
            branch.isEmpty ? nil : "Branch \(branch)",
            changeRequestAccessibilityValue(row.changeRequest)
        ].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityIdentifier("t3.navigator.row.\(row.identity.identifier)")

        let pinTitle = row.isPinned ? "Unpin \(titleLabel.stringValue)" : "Pin \(titleLabel.stringValue)"
        pinButton.setSymbol(row.isPinned ? "pin.slash" : "pin", accessibility: pinTitle)
        pinButton.toolTip = row.isPinned ? "Unpin thread" : "Pin thread"
        pinButton.setAccessibilityIdentifier("t3.navigator.pin.\(row.identity.identifier)")
        archiveButton.setSymbol("archivebox", accessibility: "Archive \(titleLabel.stringValue)")
        archiveButton.toolTip = "Archive thread"
        archiveButton.setAccessibilityIdentifier("t3.navigator.archive.\(row.identity.identifier)")
        openChangeRequestButton.setSymbol(
            "arrow.up.forward.app",
            accessibility: row.changeRequest.map {
                "Open \($0.changeRequestName) #\($0.number)"
            } ?? "Open change request"
        )
        openChangeRequestButton.toolTip = row.changeRequest.map {
            "Open \($0.changeRequestName) #\($0.number)"
        }
        openChangeRequestButton.setAccessibilityIdentifier(
            "t3.navigator.change-request.\(row.identity.identifier)"
        )
        updatePresentation()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        enclosingRow?.setInteractionHighlight(false, from: self, inkSource: .chrome)
        model = nil
        onPin = nil
        onArchive = nil
        onOpenChangeRequest = nil
        isHovered = false
        areActionsPresented = false
        spinner.isAnimating = false
        statusWidthConstraint?.isActive = false
        statusWidthConstraint = statusSlot.widthAnchor.constraint(equalTo: activityStack.widthAnchor)
        statusWidthConstraint?.isActive = true
        updateActions()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        enclosingRow?.setInteractionHighlight(true, from: self, inkSource: .chrome)
        updateActions()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        enclosingRow?.setInteractionHighlight(false, from: self, inkSource: .chrome)
        updateActions()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isHovered = false
            enclosingRow?.setInteractionHighlight(false, from: self, inkSource: .chrome)
        }
        updateActions()
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        updateActions()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        guard actionStack.alphaValue == 0,
              let target,
              target === pinButton || target === archiveButton
                || target === openChangeRequestButton
        else { return target }
        return self
    }

    /// Re-derives every colour and the age label from the row's current ground. Called for the
    /// selection moving, a theme change, a status edge, and the navigator's minute tick, so it
    /// touches only this row's labels and never reads beyond the model it was given.
    func updatePresentation() {
        let ink = enclosingRow?.contentInk ?? (model?.isSelected == true ? .selection : .chrome)
        let isEmphasized = backgroundStyle == .emphasized
        // A dormant thread has nothing running and nothing waiting: it recedes the way T3 dims
        // a read card, so the rows that can still surprise the reader are the ones that stand out.
        let recedes = model?.activity == .dormant && !isEmphasized
        titleLabel.textColor = recedes ? ink.secondary : ink.label
        projectGlyph.tint = ink.secondary
        projectLabel.textColor = ink.secondary
        branchLabel.textColor = ink.tertiary

        let status = model.map(status(for:)) ?? .none
        switch status {
        case .live(let label, _, let tone):
            activityLabel.stringValue = label
            let statusInk = isEmphasized ? ink.label : color(for: tone)
            activityGlyph.tint = statusInk
            activityLabel.textColor = statusInk
        case .age(let date):
            activityLabel.stringValue = T3ThreadAge.label(since: date)
            activityLabel.textColor = isEmphasized ? ink.secondary : ink.tertiary
        case .none:
            activityLabel.stringValue = ""
        }

        presentChangeRequest(model?.changeRequest, ink: ink, isEmphasized: isEmphasized)

        // `.selection` describes the active accent fill. An inactive row paints a quiet wash and
        // keeps chrome ink; choosing active-selection ink there makes System's white symbols fade
        // into its pale grey row.
        let selectionGround: InkSource? = isEmphasized ? .selection : nil
        pinButton.hostGround = selectionGround
        archiveButton.hostGround = selectionGround
        openChangeRequestButton.hostGround = selectionGround
        spinner.hostGround = selectionGround
        updateActions()
    }

    func rederiveThemedContent() {
        updatePresentation()
    }

    private var enclosingRow: ThemedTableRowView? {
        var ancestor = superview
        while let view = ancestor {
            if let row = view as? ThemedTableRowView { return row }
            ancestor = view.superview
        }
        return nil
    }

    private func updateActions() {
        let firstResponder = window?.firstResponder as? NSView
        let actionsHaveFocus = firstResponder?.isDescendant(of: actionStack) == true
        let presented = model != nil
            && (isHovered || actionsHaveFocus)
            && model?.isArchived != true
        if presented {
            pinButton.materializeGlyphIfNeeded()
            archiveButton.materializeGlyphIfNeeded()
            if model?.changeRequest != nil { openChangeRequestButton.materializeGlyphIfNeeded() }
        }
        if areActionsPresented != presented {
            areActionsPresented = presented
            statusWidthConstraint?.isActive = false
            let visibleStack = presented ? actionStack : activityStack
            statusWidthConstraint = statusSlot.widthAnchor.constraint(equalTo: visibleStack.widthAnchor)
            statusWidthConstraint?.isActive = true
        }
        openChangeRequestButton.isHidden = model?.changeRequest == nil
        actionStack.alphaValue = presented ? 1 : 0
        activityStack.alphaValue = presented ? 0 : 1
    }

    // MARK: - Status

    private func status(for row: T3NavigatorRow) -> Status {
        switch row.activity {
        case .working:
            return .live(label: Strings.working, mark: .spinner, tone: .accent)
        case .readyWithBackgroundWork:
            return .live(label: Strings.ready, mark: .symbol(Symbols.ready), tone: .positive)
        case .awaitingUser:
            return .live(label: Strings.input, mark: .none, tone: .warning)
        case .needsAttention:
            return .live(label: Strings.attention, mark: .none, tone: .negative)
        case .limitReached:
            return .live(label: Strings.limit, mark: .none, tone: .negative)
        case .none, .dormant, .idle:
            guard let date = row.lastActiveAt else { return .none }
            return .age(date)
        @unknown default:
            return .none
        }
    }

    private func configureStatus(_ status: Status) {
        switch status {
        case .live(_, let mark, _):
            activityLabel.applyFont(.detail(weight: .medium))
            activityStack.isHidden = false
            switch mark {
            case .spinner:
                activitySlot.isHidden = false
                spinner.isHidden = false
                spinner.isAnimating = true
                activityGlyph.isHidden = true
            case .symbol(let symbol):
                activitySlot.isHidden = false
                spinner.isHidden = true
                spinner.isAnimating = false
                activityGlyph.isHidden = false
                activityGlyph.setSymbol(
                    symbol,
                    slot: Design.Size.extensionDecorationImage,
                    role: .control,
                    weight: .medium
                )
            case .none:
                activitySlot.isHidden = true
                spinner.isHidden = true
                spinner.isAnimating = false
                activityGlyph.isHidden = true
            }
        case .age:
            activityLabel.applyFont(.numericDetail())
            activityStack.isHidden = false
            activitySlot.isHidden = true
            spinner.isHidden = true
            spinner.isAnimating = false
            activityGlyph.isHidden = true
        case .none:
            activityStack.isHidden = true
            activitySlot.isHidden = true
            spinner.isHidden = true
            spinner.isAnimating = false
            activityGlyph.isHidden = true
        }
    }

    private func statusAccessibilityValue(_ status: Status) -> String? {
        switch status {
        case .live(let label, _, _): return label
        case .age(let date): return T3ThreadAge.accessibilityValue(since: date)
        case .none: return nil
        }
    }

    private func color(for tone: Status.Tone) -> NSColor {
        switch tone {
        case .accent: return Design.Surface.accent
        case .positive: return Design.Status.positive
        case .warning: return Design.Status.warning
        case .negative: return Design.Status.negative
        }
    }

    // MARK: - Change request

    private func configureChangeRequest(_ request: PluginWorkspaceChangeRequest?) {
        guard let request else {
            changeRequestStack.isHidden = true
            changeRequestGlyph.isHidden = true
            changeRequestLabel.isHidden = true
            changeRequestLabel.stringValue = ""
            changeRequestStack.toolTip = nil
            changeRequestLabel.toolTip = nil
            changeRequestGlyph.toolTip = nil
            return
        }
        changeRequestStack.isHidden = false
        changeRequestGlyph.isHidden = false
        changeRequestLabel.isHidden = false
        changeRequestLabel.stringValue = "\(request.number)"
        let detail = changeRequestAccessibilityValue(request)
        changeRequestStack.toolTip = detail
        changeRequestGlyph.toolTip = detail
        changeRequestLabel.toolTip = detail
    }

    /// Match T3's row receipt: one semantic pull-request mark and its number. Lifecycle, checks,
    /// and reviews still choose the colour, but their complete provider-neutral reading belongs
    /// in the tooltip and accessibility value rather than competing with the branch in every row.
    private func presentChangeRequest(
        _ request: PluginWorkspaceChangeRequest?,
        ink: Design.Ink,
        isEmphasized: Bool
    ) {
        guard let request else { return }
        let color = isEmphasized ? ink.label : changeRequestColor(request, ink: ink)
        changeRequestGlyph.tint = color
        changeRequestLabel.textColor = color
    }

    private func changeRequestAccessibilityValue(
        _ request: PluginWorkspaceChangeRequest?
    ) -> String? {
        guard let request else { return nil }
        var parts = [
            "\(request.providerName) \(request.changeRequestName) #\(request.number)",
            changeRequestLifecycleLabel(request.lifecycle)
        ]
        let completedChecks = request.successfulChecks + request.nonBlockingChecks
        let knownChecks = completedChecks + request.activeChecks + request.checksNeedingAttention
            + request.unknownChecks
        if knownChecks > 0 {
            parts.append("\(completedChecks) of \(knownChecks) checks passed")
        }
        if request.activeChecks > 0 { parts.append("\(request.activeChecks) checks running") }
        if request.checksNeedingAttention > 0 {
            parts.append("\(request.checksNeedingAttention) checks need attention")
        }
        if request.approvals > 0 { parts.append("\(request.approvals) approved") }
        if request.changesRequested > 0 {
            parts.append("\(request.changesRequested) changes requested")
        }
        if request.reviewsRequested > 0 {
            parts.append("\(request.reviewsRequested) review requested")
        }
        return parts.joined(separator: ", ")
    }

    private func changeRequestLifecycleLabel(
        _ lifecycle: PluginWorkspaceChangeRequestLifecycle
    ) -> String {
        switch lifecycle {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        @unknown default: "Unknown"
        }
    }

    private func changeRequestColor(
        _ request: PluginWorkspaceChangeRequest,
        ink: Design.Ink
    ) -> NSColor {
        if request.checksNeedingAttention > 0 || request.changesRequested > 0 {
            return Design.Status.negative
        }
        if request.activeChecks > 0 || request.lifecycle == .draft {
            return Design.Status.warning
        }
        switch request.lifecycle {
        case .open, .merged: return Design.Status.positive
        case .draft: return Design.Status.warning
        case .closed: return ink.tertiary
        @unknown default: return ink.tertiary
        }
    }
}

@MainActor
private final class T3NavigatorEmptyStateView: NSView, ThemeDerivedContent {
    private let glyph = GlyphView()
    private let titleLabel = NSTextField(labelWithString: "No threads")
    private let detailLabel = NSTextField(labelWithString: "Try another search or project.")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.setSymbol(
            "text.magnifyingglass",
            slot: Design.Size.extensionIdentityImage,
            role: .toolbar
        )
        titleLabel.applyFont(.emphasizedBody)
        detailLabel.applyFont(.detail())
        titleLabel.alignment = .center
        detailLabel.alignment = .center

        let stack = NSStackView(views: [glyph, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Placeholder.line
        stack.setCustomSpacing(Design.Placeholder.afterIcon, after: glyph)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: Design.Spacing.large
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Design.Spacing.large
            ),
        ])
        setAccessibilityElement(false)
        setAccessibilityIdentifier("t3.navigator.empty")
        rederiveThemedContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func rederiveThemedContent() {
        glyph.tint = Design.Text.tertiary
        titleLabel.textColor = Design.Text.secondary
        detailLabel.textColor = Design.Text.tertiary
    }
}

@MainActor
private final class T3ProjectPickerViewController: NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate
{
    private enum Reuse {
        static let row = NSUserInterfaceItemIdentifier("t3.navigator.project-row")
        static let column = NSUserInterfaceItemIdentifier("t3.navigator.project-column")
    }

    private struct Choice {
        let identifier: String?
        let title: String
    }

    private let store: T3NavigatorStore
    private var choices: [Choice] = []
    private var isInstallingSelection = false
    private let surface = T3PaletteSurfaceView(fill: { Design.Surface.elevated })
    private let searchField = ThemedSearchField()
    private let separator = SeparatorView()
    private let table = ThemedTableView()

    var onSelect: ((String?) -> Void)?
    var onCancel: (() -> Void)?

    init(store: T3NavigatorStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 320, height: 320)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        surface.frame = NSRect(origin: .zero, size: preferredContentSize)
        view = surface

        searchField.placeholderString = "Search projects"
        searchField.setAccessibilityLabel("Search projects")
        searchField.setAccessibilityIdentifier("t3.navigator.project-search")
        searchField.delegate = self

        table.headerView = nil
        table.style = .inset
        table.intercellSpacing = .zero
        table.rowHeight = SidebarDefaults.projectCompactRowHeight
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: Reuse.column))
        table.setAccessibilityLabel("Projects")
        table.setAccessibilityIdentifier("t3.navigator.project-list")

        let scroll = ThemedScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for child in [searchField, separator, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(child)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(
                equalTo: surface.topAnchor,
                constant: Design.Spacing.medium
            ),
            searchField.leadingAnchor.constraint(
                equalTo: surface.leadingAnchor,
                constant: Design.Spacing.medium
            ),
            searchField.trailingAnchor.constraint(
                equalTo: surface.trailingAnchor,
                constant: -Design.Spacing.medium
            ),

            separator.topAnchor.constraint(
                equalTo: searchField.bottomAnchor,
                constant: Design.Spacing.medium
            ),
            separator.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: surface.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
        ])
        rebuildChoices()
    }

    func applyTheme() {
        guard isViewLoaded else { return }
        table.noteHeightOfRows(
            withIndexesChanged: IndexSet(integersIn: 0..<choices.count)
        )
    }

    var searchFieldForPresentation: ThemedSearchField {
        _ = view
        return searchField
    }

    private func rebuildChoices() {
        choices = [Choice(identifier: nil, title: "All projects")]
        choices += store.visibleProjects(matching: searchField.stringValue).map {
            Choice(identifier: $0.id, title: $0.title)
        }
        table.reloadData()
        if let index = choices.firstIndex(where: {
            $0.identifier == store.selectedProjectIdentifier
        }) {
            isInstallingSelection = true
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            isInstallingSelection = false
            table.scrollRowToVisible(index)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        rebuildChoices()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !searchField.stringValue.isEmpty {
                searchField.clear()
            } else {
                onCancel?()
            }
            return true
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { choices.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row index: Int
    ) -> NSView? {
        guard index >= 0, index < choices.count else { return nil }
        let cell = (tableView.makeView(withIdentifier: Reuse.row, owner: self)
            as? T3ProjectRowCell) ?? T3ProjectRowCell()
        cell.identifier = Reuse.row
        let choice = choices[index]
        cell.configure(
            title: choice.title,
            selected: choice.identifier == store.selectedProjectIdentifier,
            accessibilityIdentifier: "t3.navigator.project.\(choice.identifier ?? "all")"
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isInstallingSelection else { return }
        let index = table.selectedRow
        guard index >= 0, index < choices.count else { return }
        onSelect?(choices[index].identifier)
    }

    func tableView(
        _ tableView: NSTableView,
        rowViewForRow row: Int
    ) -> NSTableRowView? {
        ThemedTableRowView()
    }
}

@MainActor
private final class T3ProjectRowCell: NSTableCellView, ThemeDerivedContent {
    private let glyph = GlyphView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var isChoiceSelected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.setSymbol("folder", role: .control)
        titleLabel.applyFont(.body)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [glyph, titleLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Spacing.inset
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Design.Spacing.inset
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, selected: Bool, accessibilityIdentifier: String) {
        titleLabel.stringValue = title
        isChoiceSelected = selected
        glyph.setSymbol(selected ? "checkmark" : "folder", role: .control)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(accessibilityIdentifier)
        rederiveThemedContent()
    }

    func rederiveThemedContent() {
        let ink = enclosingRow?.contentInk ?? (isChoiceSelected ? .selection : .chrome)
        glyph.tint = ink.secondary
        titleLabel.textColor = ink.label
    }

    private var enclosingRow: ThemedTableRowView? {
        var ancestor = superview
        while let view = ancestor {
            if let row = view as? ThemedTableRowView { return row }
            ancestor = view.superview
        }
        return nil
    }
}

/// A custom extension surface is still palette-bound: it resolves a semantic role every draw.
@MainActor
private final class T3PaletteSurfaceView: NSView, ThemedComponent {
    private let fill: @MainActor () -> NSColor

    init(fill: @escaping @MainActor () -> NSColor) {
        self.fill = fill
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        fill().setFill()
        dirtyRect.fill()
    }
}
