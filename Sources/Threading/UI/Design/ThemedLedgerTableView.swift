import AppKit

/// A ledger: a named first column and measured columns set against the trailing edge, in
/// tabular figures, under headings. The Usage breakdown's anatomy, as a reusable component for
/// tables whose columns a caller states (a worker's spend by day, by task, by trigger).
///
/// Virtualized for the breakdown's reason: rows are externally sized, so only visible rows
/// become views. It grows to fit its rows up to `visibleRows` and scrolls past that, handing a
/// vertical flick that has reached its end back to the page (`verticalScrollHandoff`).
final class ThemedLedgerTableView: NSView, ThemedComponent, NSTableViewDataSource, NSTableViewDelegate {
    struct Column: Equatable {
        enum Alignment: Equatable { case leading, trailing }
        let title: String
        /// The fixed width of a measured column, or the minimum of the flexible first one.
        let width: CGFloat
        var alignment: Alignment = .trailing
    }

    struct Row: Equatable {
        let values: [String]
        /// Column indices drawn in the warning role — a value that says something is missing,
        /// such as a partial receipt. The words carry the meaning; the ink makes it findable.
        var warningColumns: Set<Int> = []
        /// Spoken after the values: a reason a cell alone cannot hold.
        var accessibilityDetail: String? = nil
    }

    private let scrollView = ThemedScrollView()
    private let table = ThemedTableView()
    private var columns: [Column] = []
    private var rows: [Row] = []
    private let visibleRows: Int
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    var visibleCellCount: Int { table.visibleRect.isEmpty ? 0 : table.rows(in: table.visibleRect).length }
    var columnTitlesForTesting: [String] { table.tableColumns.map(\.title) }
    var rowsForTesting: [Row] { rows }

    init(visibleRows: Int = Design.UsageDashboard.breakdownVisibleRows) {
        self.visibleRows = visibleRows
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)
        table.headerView = ThemedTableHeaderView(frame: NSRect(
            x: 0, y: 0, width: 0, height: Design.UsageDashboard.breakdownHeaderHeight
        ))
        table.rowHeight = Design.UsageDashboard.breakdownRowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        // Flush for the breakdown's reason: `.inset` shifts columns after they were fit.
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityRole(.table)
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.verticalScrollHandoff = .atContentEnds
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            heightConstraint,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.tight),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.tight),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.tight)
        ])
        applyHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Replaces the columns (when they changed) and the rows. O(columns) views plus a reload;
    /// rows become views only as they scroll into sight.
    func show(columns: [Column], rows: [Row], accessibilityLabel: String) {
        if columns != self.columns {
            self.columns = columns
            table.tableColumns.forEach(table.removeTableColumn)
            for (index, column) in columns.enumerated() {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Ledger.\(index)"))
                tableColumn.title = column.title
                tableColumn.width = column.width
                tableColumn.minWidth = column.width
                if index == 0 {
                    tableColumn.maxWidth = .greatestFiniteMagnitude
                } else {
                    tableColumn.maxWidth = column.width
                }
                tableColumn.headerCell.alignment = column.alignment == .trailing ? .right : .left
                table.addTableColumn(tableColumn)
            }
        }
        self.rows = rows
        table.setAccessibilityLabel(accessibilityLabel)
        table.headerView?.needsDisplay = true
        table.reloadData()
        applyHeight()
        needsLayout = true
    }

    private func applyHeight() {
        let visible = min(max(rows.count, 1), visibleRows)
        heightConstraint.constant = Design.UsageDashboard.breakdownHeaderHeight
            + CGFloat(visible) * Design.UsageDashboard.breakdownRowHeight
            + Design.Spacing.tight * 2
    }

    override func layout() {
        super.layout()
        fitFirstColumn()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        fitFirstColumn()
    }

    /// The first column takes what the measured ones leave.
    private func fitFirstColumn() {
        let available = scrollView.contentView.bounds.width
        guard available > 0, let first = table.tableColumns.first else { return }
        let fixed = table.tableColumns.dropFirst().reduce(0) { $0 + $1.width }
        let width = max(available - fixed, columns.first?.width ?? 0)
        guard abs(first.width - width) > 0.5 else { return }
        first.width = width
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = tableView.tableColumns.firstIndex(of: tableColumn),
              rows.indices.contains(row), columns.indices.contains(index) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("LedgerCell.\(columns[index].alignment)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LedgerCellView
            ?? LedgerCellView(alignment: columns[index].alignment)
        cell.identifier = identifier
        let value = rows[row].values.indices.contains(index) ? rows[row].values[index] : ""
        cell.show(value, label: columns[index].title, isWarning: rows[row].warningColumns.contains(index),
                  detail: index == 0 ? rows[row].accessibilityDetail : nil)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AppThemeRefresh.repaint(self)
    }
}

/// One value: a name read from the leading edge, or a measure set against the trailing one.
private final class LedgerCellView: NSTableCellView, ThemedComponent {
    private let field = NSTextField(labelWithString: "")
    private var isWarning = false

    init(alignment: ThemedLedgerTableView.Column.Alignment) {
        super.init(frame: .zero)
        field.applyFont(alignment == .trailing ? .numericBody : .body)
        field.alignment = alignment == .trailing ? .right : .left
        field.lineBreakMode = alignment == .trailing ? .byTruncatingTail : .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        applyColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ value: String, label: String, isWarning: Bool, detail: String?) {
        field.stringValue = value
        self.isWarning = isWarning
        applyColor()
        setAccessibilityLabel(label)
        setAccessibilityValue(detail.map { "\(value), \($0)" } ?? value)
    }

    private func applyColor() {
        field.textColor = isWarning ? Design.Status.warning : Design.Text.label
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }
}
