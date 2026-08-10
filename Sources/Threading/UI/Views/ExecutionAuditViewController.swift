import AppKit

/// A provider-neutral viewer for the exact execution ledger.
///
/// The left rail is always the audit source of truth. Its right side is either the selected
/// record's complete JSON envelope or the session's live browser; browser split mode pins the
/// category filter to browser events so page and tool history can be reviewed together.
@MainActor
final class ExecutionAuditViewController: NSViewController {
    enum Mode: String, Codable {
        case audit
        case browserSplit = "browser_split"
    }

    let sessionID: SessionID
    let browser: BrowserViewController
    private let store: ExecutionAuditStore

    var onModeChange: ((Mode) -> Void)?

    private(set) var mode: Mode = .audit
    private var records: [ExecutionAuditRecord] = []
    private var filteredRecords: [ExecutionAuditRecord] = []
    private var integrity: ExecutionAuditIntegrity = .verified
    private var malformedLineCount = 0
    private var selectedCategory: ExecutionAuditRecord.Category?
    private var categoryBeforeBrowserSplit: ExecutionAuditRecord.Category?
    private var selectedSource: ExecutionAuditRecord.Source?
    private var selectedRecordID: UUID?
    private var positionedInitialDivider = false

    private let appEvents = AppEventObservations()
    private let root = ThemedSurfaceView()
    private let titleLabel = NSTextField(labelWithString: L10n.string("Execution audit"))
    private let statusLabel = NSTextField(labelWithString: "")
    private let integrityLabel = NSTextField(labelWithString: "")
    private let categoryChip = ChipView()
    private let sourceChip = ChipView()
    private let searchField = ThemedSearchField()
    private let modeControl = ThemedSegmentedControl()
    private let eventCountLabel = NSTextField(labelWithString: "")
    private let tableView = ThemedTableView()
    private let tableScroll = ThemedScrollView()
    private let emptyLabel = NSTextField(
        labelWithString: L10n.string("No execution events match these filters.")
    )
    private let splitView = ThemedSplitView()
    private let detailPane = ThemedSurfaceView()
    private let detailTitleLabel = NSTextField(labelWithString: L10n.string("Select an event"))
    private let detailMetadataLabel = NSTextField(
        labelWithString: L10n.string("Exact payloads appear here.")
    )
    private let detailScroll = ThemedTextView.scrolling()
    private let rightHost = NSView()

    private var detailTextView: ThemedTextView { detailScroll.textView }

    init(
        sessionID: SessionID,
        browser: BrowserViewController,
        initialMode: Mode = .audit,
        store: ExecutionAuditStore = .shared
    ) {
        self.sessionID = sessionID
        self.browser = browser
        self.store = store
        self.mode = initialMode
        if initialMode == .browserSplit { self.selectedCategory = .browser }
        super.init(nibName: nil, bundle: nil)
        addChild(browser)

        appEvents.observe(ExecutionAuditDidChange.self) { [weak self] event in
            guard let self, event.sessionID == self.sessionID else { return }
            self.reloadAudit()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        root.applySurface(
            fill: Design.Surface.ground,
            radius: .fixed(0),
            pattern: .backdrop
        )
        root.frame = NSRect(x: 0, y: 0, width: 960, height: 680)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
        setupContent()
        reloadAudit()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !positionedInitialDivider, splitView.bounds.width > 0 else { return }
        // Give the factual timeline enough room to scan without making the live page feel like
        // a preview strip. This runs after Auto Layout establishes the real width, then gets out
        // of the way so the user remains free to drag the divider.
        let desired = min(520, max(360, splitView.bounds.width * 0.43))
        splitView.setPosition(desired, ofDividerAt: 0)
        positionedInitialDivider = true
    }

    func setMode(_ mode: Mode, notify: Bool = false) {
        guard self.mode != mode else {
            modeControl.selectedIndex = mode == .audit ? 0 : 1
            return
        }

        if mode == .browserSplit {
            categoryBeforeBrowserSplit = selectedCategory
            selectedCategory = .browser
        } else {
            selectedCategory = categoryBeforeBrowserSplit
            categoryBeforeBrowserSplit = nil
        }
        self.mode = mode
        modeControl.selectedIndex = mode == .audit ? 0 : 1
        browser.view.isHidden = mode != .browserSplit
        detailPane.isHidden = mode == .browserSplit
        configureCategoryChip()
        applyFilters()
        if notify { onModeChange?(mode) }
    }

    /// Used by persistence after a page change without exposing the browser's internal view.
    var restoredURL: String? {
        get { browser.currentURL?.absoluteString ?? browser.restoredURL }
        set { browser.restoredURL = newValue }
    }

    // MARK: Setup

    private func setupHeader() {
        titleLabel.applyFont(.heading)
        titleLabel.textColor = Design.Text.label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.applyFont(.caption)
        statusLabel.textColor = Design.Text.secondary
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        integrityLabel.applyFont(.caption)
        integrityLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView(views: [titleLabel, statusLabel, integrityLabel])
        titleStack.orientation = .horizontal
        titleStack.alignment = .firstBaseline
        titleStack.spacing = Design.Spacing.medium
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        modeControl.configure(
            titles: [L10n.string("Audit"), L10n.string("Browser split")],
            selectedIndex: mode == .audit ? 0 : 1
        )
        modeControl.onSelect = { [weak self] index in
            self?.setMode(index == 0 ? .audit : .browserSplit, notify: true)
        }
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [titleStack, NSView(), modeControl])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = Design.Spacing.medium
        topRow.translatesAutoresizingMaskIntoConstraints = false

        configureCategoryChip()
        categoryChip.heightStyle = .field
        categoryChip.itemsProvider = { [weak self] in self?.categoryItems() ?? [] }
        categoryChip.translatesAutoresizingMaskIntoConstraints = false
        categoryChip.setAccessibilityIdentifier("executionAudit.categoryFilter")

        configureSourceChip()
        sourceChip.heightStyle = .field
        sourceChip.itemsProvider = { [weak self] in self?.sourceItems() ?? [] }
        sourceChip.translatesAutoresizingMaskIntoConstraints = false
        sourceChip.setAccessibilityIdentifier("executionAudit.sourceFilter")

        searchField.placeholderString = L10n.string("Search exact records")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel(L10n.string("Search execution audit"))
        searchField.setAccessibilityIdentifier("executionAudit.search")

        let filterRow = NSStackView(views: [categoryChip, sourceChip, searchField])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = Design.Spacing.small
        filterRow.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [topRow, filterRow])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = Design.Spacing.small
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        let separator = SeparatorView()
        root.addSubview(separator)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Design.Spacing.large),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Design.Spacing.large),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: Design.Spacing.medium),
            topRow.widthAnchor.constraint(equalTo: header.widthAnchor),
            filterRow.widthAnchor.constraint(equalTo: header.widthAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 188),
            categoryChip.widthAnchor.constraint(equalToConstant: 142),
            sourceChip.widthAnchor.constraint(equalToConstant: 136),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.Spacing.medium),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])

        separator.setAccessibilityIdentifier("executionAudit.headerSeparator")
        splitView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    private func setupContent() {
        let listPane = ThemedSurfaceView()
        listPane.applySurface(
            fill: Design.Surface.ground,
            radius: .fixed(0),
            pattern: .backdrop
        )
        listPane.translatesAutoresizingMaskIntoConstraints = false

        let listTitle = NSTextField(labelWithString: L10n.string("EVENTS"))
        listTitle.applyFont(.caption)
        listTitle.textColor = Design.Text.tertiary
        listTitle.translatesAutoresizingMaskIntoConstraints = false

        eventCountLabel.applyFont(.numericDetail())
        eventCountLabel.textColor = Design.Text.tertiary
        eventCountLabel.translatesAutoresizingMaskIntoConstraints = false

        let listHeader = NSStackView(views: [listTitle, NSView(), eventCountLabel])
        listHeader.orientation = .horizontal
        listHeader.alignment = .firstBaseline
        listHeader.translatesAutoresizingMaskIntoConstraints = false
        listPane.addSubview(listHeader)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ExecutionAuditEvent"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 78
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(L10n.string("Execution events"))

        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        listPane.addSubview(tableScroll)

        emptyLabel.applyFont(.body)
        emptyLabel.textColor = Design.Text.tertiary
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        listPane.addSubview(emptyLabel)

        let listSeparator = SeparatorView()
        listPane.addSubview(listSeparator)

        NSLayoutConstraint.activate([
            listHeader.topAnchor.constraint(equalTo: listPane.topAnchor, constant: Design.Spacing.medium),
            listHeader.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: Design.Spacing.medium),
            listHeader.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -Design.Spacing.medium),
            listSeparator.topAnchor.constraint(equalTo: listHeader.bottomAnchor, constant: Design.Spacing.small),
            listSeparator.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            listSeparator.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: listSeparator.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: listPane.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: listPane.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listPane.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: listPane.leadingAnchor, constant: Design.Spacing.large),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: listPane.trailingAnchor, constant: -Design.Spacing.large)
        ])

        setupDetailPane()
        rightHost.translatesAutoresizingMaskIntoConstraints = false
        rightHost.addSubview(detailPane)
        rightHost.addSubview(browser.view)
        browser.view.translatesAutoresizingMaskIntoConstraints = false
        browser.view.isHidden = mode != .browserSplit
        detailPane.isHidden = mode == .browserSplit
        NSLayoutConstraint.activate([
            detailPane.topAnchor.constraint(equalTo: rightHost.topAnchor),
            detailPane.leadingAnchor.constraint(equalTo: rightHost.leadingAnchor),
            detailPane.trailingAnchor.constraint(equalTo: rightHost.trailingAnchor),
            detailPane.bottomAnchor.constraint(equalTo: rightHost.bottomAnchor),
            browser.view.topAnchor.constraint(equalTo: rightHost.topAnchor),
            browser.view.leadingAnchor.constraint(equalTo: rightHost.leadingAnchor),
            browser.view.trailingAnchor.constraint(equalTo: rightHost.trailingAnchor),
            browser.view.bottomAnchor.constraint(equalTo: rightHost.bottomAnchor)
        ])

        splitView.addArrangedSubview(listPane)
        splitView.addArrangedSubview(rightHost)
        listPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        rightHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
    }

    private func setupDetailPane() {
        detailPane.applySurface(fill: Design.Surface.panel, radius: .fixed(0))
        detailPane.translatesAutoresizingMaskIntoConstraints = false

        detailTitleLabel.applyFont(.subheading)
        detailTitleLabel.textColor = Design.Text.label
        detailTitleLabel.lineBreakMode = .byTruncatingMiddle
        detailTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailMetadataLabel.applyFont(.caption)
        detailMetadataLabel.textColor = Design.Text.tertiary
        detailMetadataLabel.lineBreakMode = .byTruncatingTail
        detailMetadataLabel.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSStackView(views: [detailTitleLabel, detailMetadataLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = Design.Spacing.tight
        heading.translatesAutoresizingMaskIntoConstraints = false
        detailPane.addSubview(heading)

        let separator = SeparatorView()
        detailPane.addSubview(separator)

        detailTextView.isEditable = false
        detailTextView.isSelectable = true
        detailTextView.applyFont(.compactCode)
        detailTextView.textContainerInset = NSSize(
            width: Design.Spacing.large,
            height: Design.Spacing.large
        )
        detailTextView.setAccessibilityLabel(L10n.string("Exact execution record"))
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailPane.addSubview(detailScroll)

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: detailPane.topAnchor, constant: Design.Spacing.medium),
            heading.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor, constant: Design.Spacing.large),
            heading.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor, constant: -Design.Spacing.large),
            separator.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: Design.Spacing.medium),
            separator.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor),
            detailScroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            detailScroll.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: detailPane.bottomAnchor)
        ])
    }

    // MARK: Data

    private func reloadAudit() {
        let result = store.read(sessionID: sessionID)
        records = result.records.sorted { lhs, rhs in lhs.sequence > rhs.sequence }
        integrity = result.integrity
        malformedLineCount = result.malformedLineCount
        updateHeaderStatus()
        applyFilters()
    }

    private func applyFilters() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filteredRecords = records.filter { record in
            guard selectedCategory.map({ record.category == $0 }) ?? true else { return false }
            guard selectedSource.map({ record.source == $0 }) ?? true else { return false }
            guard !query.isEmpty else { return true }
            return searchableText(record).contains(query)
        }

        eventCountLabel.stringValue = L10n.format(
            "%lld of %lld",
            Int64(filteredRecords.count),
            Int64(records.count)
        )
        emptyLabel.isHidden = !filteredRecords.isEmpty
        tableScroll.isHidden = filteredRecords.isEmpty

        tableView.reloadData()

        if let selectedRecordID,
           let index = filteredRecords.firstIndex(where: { $0.id == selectedRecordID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            showDetail(filteredRecords[index])
        } else if let first = filteredRecords.first {
            selectedRecordID = first.id
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showDetail(first)
        } else {
            selectedRecordID = nil
            showDetail(nil)
        }
    }

    private func searchableText(_ record: ExecutionAuditRecord) -> String {
        let payload = [record.input?.encodedText(), record.output?.encodedText()]
            .compactMap { $0 }
            .joined(separator: " ")
        return [
            record.operation,
            record.summary,
            record.category.rawValue,
            record.phase.rawValue,
            record.source.rawValue,
            record.provider ?? "",
            record.fidelity.rawValue,
            payload
        ].joined(separator: " ").lowercased()
    }

    private func showDetail(_ record: ExecutionAuditRecord?) {
        guard let record else {
            detailTitleLabel.stringValue = L10n.string("Select an event")
            detailMetadataLabel.stringValue = L10n.string("Exact payloads appear here.")
            detailTextView.string = ""
            return
        }

        detailTitleLabel.stringValue = record.operation
        let redaction: String
        if record.redactions.isEmpty {
            redaction = L10n.string("no redactions")
        } else if record.redactions.count == 1 {
            redaction = L10n.string("1 explicit redaction")
        } else {
            redaction = L10n.format("%lld explicit redactions", Int64(record.redactions.count))
        }
        detailMetadataLabel.stringValue = L10n.format(
            "#%lld · %@ · %@ · SHA-256 linked",
            Int64(record.sequence),
            record.fidelity.displayName,
            redaction
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        detailTextView.string = (try? encoder.encode(record))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? L10n.string("Record could not be encoded.")
        detailTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func updateHeaderStatus() {
        statusLabel.stringValue = records.count == 1
            ? L10n.string("1 retained event")
            : L10n.format("%lld retained events", Int64(records.count))
        switch integrity {
        case .verified:
            integrityLabel.stringValue = L10n.string("Verified chain")
            integrityLabel.textColor = Design.Status.positive
        case .partial:
            integrityLabel.stringValue = L10n.string("Verified retained suffix")
            integrityLabel.textColor = Design.Status.warning
        case .broken:
            integrityLabel.stringValue = malformedLineCount > 0
                ? L10n.format("Integrity failure · %lld malformed", Int64(malformedLineCount))
                : L10n.string("Integrity failure")
            integrityLabel.textColor = Design.Status.negative
        }
    }

    // MARK: Filters

    private func configureCategoryChip() {
        if mode == .browserSplit {
            categoryChip.configure(symbolName: "globe", title: L10n.string("Browser only"))
            categoryChip.isEnabled = false
        } else if let selectedCategory {
            categoryChip.configure(
                symbolName: selectedCategory.symbolName,
                title: selectedCategory.displayName
            )
            categoryChip.isEnabled = true
        } else {
            categoryChip.configure(
                symbolName: "line.3.horizontal.decrease.circle",
                title: L10n.string("All categories")
            )
            categoryChip.isEnabled = true
        }
    }

    private func configureSourceChip() {
        if let selectedSource {
            sourceChip.configure(symbolName: "point.3.connected.trianglepath.dotted", title: selectedSource.displayName)
        } else {
            sourceChip.configure(
                symbolName: "point.3.connected.trianglepath.dotted",
                title: L10n.string("All sources")
            )
        }
    }

    private func categoryItems() -> [ThemedMenuEntry] {
        let all = ThemedMenuItem(
            title: L10n.string("All categories"),
            image: NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil),
            isSelected: selectedCategory == nil,
            onChoose: { [weak self] in
                self?.selectedCategory = nil
                self?.configureCategoryChip()
                self?.applyFilters()
            }
        )
        return [.item(all)] + ExecutionAuditRecord.Category.allCases.map { category in
            .item(ThemedMenuItem(
                title: category.displayName,
                image: NSImage(systemSymbolName: category.symbolName, accessibilityDescription: nil),
                isSelected: selectedCategory == category,
                onChoose: { [weak self] in
                    self?.selectedCategory = category
                    self?.configureCategoryChip()
                    self?.applyFilters()
                }
            ))
        }
    }

    private func sourceItems() -> [ThemedMenuEntry] {
        let all = ThemedMenuItem(
            title: L10n.string("All sources"),
            isSelected: selectedSource == nil,
            onChoose: { [weak self] in
                self?.selectedSource = nil
                self?.configureSourceChip()
                self?.applyFilters()
            }
        )
        return [.item(all)] + ExecutionAuditRecord.Source.allCases.map { source in
            .item(ThemedMenuItem(
                title: source.displayName,
                isSelected: selectedSource == source,
                onChoose: { [weak self] in
                    self?.selectedSource = source
                    self?.configureSourceChip()
                    self?.applyFilters()
                }
            ))
        }
    }
}

extension ExecutionAuditViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filteredRecords.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard filteredRecords.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ExecutionAuditCell")
        let cell: ExecutionAuditTableCell
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
            as? ExecutionAuditTableCell {
            cell = reused
        } else {
            cell = ExecutionAuditTableCell()
            cell.identifier = identifier
        }
        cell.eventView.configure(
            record: filteredRecords[row],
            isSelected: selectedRecordID == filteredRecords[row].id
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedRecordID = filteredRecords.indices.contains(row) ? filteredRecords[row].id : nil
        tableView.reloadData()
        showDetail(filteredRecords.indices.contains(row) ? filteredRecords[row] : nil)
    }
}

extension ExecutionAuditViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilters()
    }
}

private final class ExecutionAuditTableCell: NSTableCellView {
    let eventView = ExecutionAuditEventView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        eventView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(eventView)
        NSLayoutConstraint.activate([
            eventView.topAnchor.constraint(equalTo: topAnchor),
            eventView.leadingAnchor.constraint(equalTo: leadingAnchor),
            eventView.trailingAnchor.constraint(equalTo: trailingAnchor),
            eventView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
