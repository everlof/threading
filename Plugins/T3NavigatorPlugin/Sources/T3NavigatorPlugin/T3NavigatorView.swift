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
        table.reloadData()
        projectButton.title = store.selectedProjectTitle
        projectButton.setAccessibilityValue(store.selectedProjectTitle)
        emptyState.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        synchronizeSelection()
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

    private func rowHeight() -> CGFloat {
        ceil(
            Design.Typography.lineHeight(of: Design.Typography.subheading())
                + Design.Spacing.hairline
                + Design.Typography.lineHeight(of: Design.Typography.detail())
                + Design.Spacing.small * 2
        )
    }

    private func sectionHeight() -> CGFloat {
        max(SidebarDefaults.rowHeight, Design.Size.choiceHeight)
    }

    private func applyThemeMetrics() {
        table.rowHeight = rowHeight()
        projectButton.title = store.selectedProjectTitle
        projectPicker?.applyTheme()
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

        let entries: [ThemedMenuEntry] = [
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
        ]
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
                onArchive: { [weak self] row in self?.store.archive(row) }
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

@MainActor
private final class T3NavigatorRowCell: NSTableCellView, ThemeDerivedContent {
    private weak var model: T3NavigatorRow?
    private var onPin: ((T3NavigatorRow) -> Void)?
    private var onArchive: ((T3NavigatorRow) -> Void)?
    private var isHovered = false

    /// AppKit changes this when the table's selection moves between the active accent and its
    /// quiet inactive presentation. The controls inside the row have to follow the ground the row
    /// actually painted, just as Threading's built-in session rows do.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updatePresentation() }
    }

    private let activitySlot = NSView()
    private let activityGlyph = GlyphView()
    private let spinner = ThemedSpinner()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
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
    private lazy var actionStack = NSStackView(views: [pinButton, archiveButton])

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        titleLabel.applyFont(.subheading)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metadataLabel.applyFont(.detail())
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        activityGlyph.translatesAutoresizingMaskIntoConstraints = false
        activitySlot.translatesAutoresizingMaskIntoConstraints = false
        activitySlot.addSubview(spinner)
        activitySlot.addSubview(activityGlyph)
        NSLayoutConstraint.activate([
            activitySlot.widthAnchor.constraint(equalToConstant: Design.Size.extensionIconImage),
            spinner.centerXAnchor.constraint(equalTo: activitySlot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: activitySlot.centerYAnchor),
            activityGlyph.centerXAnchor.constraint(equalTo: activitySlot.centerXAnchor),
            activityGlyph.centerYAnchor.constraint(equalTo: activitySlot.centerYAnchor),
        ])

        let labels = NSStackView(views: [titleLabel, metadataLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = Design.Spacing.hairline

        let content = NSStackView(views: [activitySlot, labels, actionStack])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: Design.Spacing.small
            ),
            content.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -Design.Spacing.small
            ),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Spacing.inset
            ),
            content.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.small
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

        updateActions()
    }

    func configure(
        row: T3NavigatorRow,
        projectTitle: String,
        onPin: @escaping (T3NavigatorRow) -> Void,
        onArchive: @escaping (T3NavigatorRow) -> Void
    ) {
        model = row
        self.onPin = onPin
        self.onArchive = onArchive
        titleLabel.stringValue = row.title.isEmpty ? "Untitled thread" : row.title
        metadataLabel.stringValue = metadata(for: row, projectTitle: projectTitle)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(titleLabel.stringValue)
        setAccessibilityValue(metadataLabel.stringValue)
        setAccessibilityIdentifier("t3.navigator.row.\(row.identity.identifier)")

        let pinTitle = row.isPinned ? "Unpin \(titleLabel.stringValue)" : "Pin \(titleLabel.stringValue)"
        pinButton.setSymbol(row.isPinned ? "pin.slash" : "pin", accessibility: pinTitle)
        pinButton.toolTip = row.isPinned ? "Unpin thread" : "Pin thread"
        pinButton.setAccessibilityIdentifier("t3.navigator.pin.\(row.identity.identifier)")
        archiveButton.setSymbol("archivebox", accessibility: "Archive \(titleLabel.stringValue)")
        archiveButton.toolTip = "Archive thread"
        archiveButton.setAccessibilityIdentifier("t3.navigator.archive.\(row.identity.identifier)")
        configureActivity(row.activity)
        updatePresentation()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        enclosingRow?.setInteractionHighlight(false, from: self, inkSource: .chrome)
        model = nil
        onPin = nil
        onArchive = nil
        isHovered = false
        spinner.isAnimating = false
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        guard actionStack.alphaValue == 0,
              let target,
              target === pinButton || target === archiveButton
        else { return target }
        return self
    }

    func updatePresentation() {
        let ink = enclosingRow?.contentInk ?? (model?.isSelected == true ? .selection : .chrome)
        titleLabel.textColor = ink.label
        metadataLabel.textColor = ink.tertiary
        activityGlyph.tint = activityColor(for: model?.activity, ink: ink)
        // `.selection` describes the active accent fill. An inactive row paints a quiet wash and
        // keeps chrome ink; choosing active-selection ink there makes System's white symbols fade
        // into its pale grey row.
        let selectionGround: InkSource? = backgroundStyle == .emphasized ? .selection : nil
        pinButton.hostGround = selectionGround
        archiveButton.hostGround = selectionGround
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
        let presented = isHovered || enclosingRow?.isSelected == true || model?.isSelected == true
        if presented {
            pinButton.materializeGlyphIfNeeded()
            archiveButton.materializeGlyphIfNeeded()
        }
        actionStack.alphaValue = presented && model?.isArchived != true ? 1 : 0
    }

    private func configureActivity(_ activity: PluginWorkspaceActivity) {
        let isWorking = activity == .working
        spinner.isHidden = !isWorking
        spinner.isAnimating = isWorking
        activityGlyph.isHidden = isWorking
        activityGlyph.setSymbol(
            activitySymbol(for: activity),
            slot: Design.Size.extensionDecorationImage,
            role: .control,
            weight: activity == .needsAttention || activity == .limitReached ? .semibold : .medium
        )
    }

    private func metadata(for row: T3NavigatorRow, projectTitle: String) -> String {
        var parts = [activityLabel(for: row.activity), projectTitle]
        if let branch = row.branch, !branch.isEmpty { parts.append("⌘ \(branch)") }
        return parts.joined(separator: "  ·  ")
    }

    private func activityLabel(for activity: PluginWorkspaceActivity) -> String {
        switch activity {
        case .none: return "Thread"
        case .dormant: return "Dormant"
        case .idle: return "Idle"
        case .working: return "Working"
        case .readyWithBackgroundWork: return "Ready"
        case .awaitingUser: return "Waiting"
        case .needsAttention: return "Attention"
        case .limitReached: return "Limit"
        @unknown default: return "Unknown"
        }
    }

    private func activitySymbol(for activity: PluginWorkspaceActivity) -> String {
        switch activity {
        case .awaitingUser: return "person.crop.circle.badge.questionmark"
        case .needsAttention: return "exclamationmark.circle.fill"
        case .limitReached: return "gauge.with.needle.fill"
        case .readyWithBackgroundWork: return "checkmark.circle.fill"
        case .working: return "circle"
        case .none, .dormant, .idle: return "circle.fill"
        @unknown default: return "circle"
        }
    }

    private func activityColor(
        for activity: PluginWorkspaceActivity?,
        ink: Design.Ink
    ) -> NSColor {
        switch activity {
        case .working, .readyWithBackgroundWork:
            return Design.Status.positive
        case .awaitingUser:
            return Design.Status.warning
        case .needsAttention, .limitReached:
            return Design.Status.negative
        case .some(.none), .dormant, .idle, nil:
            return ink.quaternary
        @unknown default:
            return ink.quaternary
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
