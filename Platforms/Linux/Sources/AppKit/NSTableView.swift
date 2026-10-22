import Foundation

@MainActor
public final class NSTableColumn {
    public struct ResizingOptions: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let autoresizingMask = Self(rawValue: 1)
        public static let userResizingMask = Self(rawValue: 2)
    }
    public let identifier: NSUserInterfaceItemIdentifier
    public var width: CGFloat = 100
    public var resizingMask: ResizingOptions = []

    public init(identifier: NSUserInterfaceItemIdentifier) {
        self.identifier = identifier
    }
}

@MainActor
open class NSTableCellView: NSView {
    private var statedBackgroundStyle: BackgroundStyle = .normal
    open var backgroundStyle: BackgroundStyle {
        get {
            guard let row = superview as? NSTableRowView else { return statedBackgroundStyle }
            return row.isSelected && row.isEmphasized ? .emphasized : .normal
        }
        set { statedBackgroundStyle = newValue; needsDisplay = true }
    }
    open func prepareForReuse() {}
}

/// AppKit's row chrome sits behind a cell, and owns selection/hover drawing independently of
/// the cell's content. Subclasses can override either drawing hook without recreating cells.
@MainActor
open class NSTableRowView: NSView {
    open var isSelected = false { didSet { needsDisplay = true } }
    open var isEmphasized = true { didSet { needsDisplay = true } }

    open override var isFlipped: Bool { true }

    open func drawBackground(in dirtyRect: NSRect) {}
    open func drawSelection(in dirtyRect: NSRect) {}

    open override func draw(_ dirtyRect: NSRect) {
        drawBackground(in: dirtyRect)
        if isSelected { drawSelection(in: dirtyRect) }
    }
}

@MainActor
public protocol NSTableViewDataSource: AnyObject {
    func numberOfRows(in tableView: NSTableView) -> Int
}

@MainActor
public protocol NSTableViewDelegate: AnyObject {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView?
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool
    func tableViewSelectionDidChange(_ notification: Notification)
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int)
}

public extension NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { tableView.rowHeight }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
    func tableViewSelectionDidChange(_ notification: Notification) {}
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {}
}

public extension Notification.Name {
    static let NSTableViewSelectionDidChange = Notification.Name("NSTableViewSelectionDidChange")
}

/// A view-based table document. The data source owns values; the table owns
/// viewport cells. Reloads may enumerate the source, but scroll and resize only touch mounted
/// rows. Row offsets are indexed during reload, not during scroll. A table is normally the
/// direct documentView of an NSScrollView.
@MainActor
open class NSTableView: NSView, NSClipViewDocumentObserver {
    open var backgroundColor: NSColor = .clear {
        didSet { precondition(backgroundColor.alphaComponent == 0,
                              "Linux table rows own their surface") }
    }
    public enum Style { case fullWidth, inset }
    public enum SelectionHighlightStyle { case regular, none }
    public enum ColumnAutoresizingStyle { case noColumnAutoresizing, uniformColumnAutoresizingStyle }
    public enum FocusRingType { case none }

    /// A transcript has no table header. A nonnil header needs its own document geometry.
    open var headerView: NSView? {
        didSet { precondition(headerView == nil, "table header layout is unavailable") }
    }
    open var selectionHighlightStyle: SelectionHighlightStyle = .regular
    open var focusRingType: FocusRingType = .none
    open var columnAutoresizingStyle: ColumnAutoresizingStyle = .noColumnAutoresizing {
        didSet { resizeColumnsToFit() }
    }

    /// The inset table's ten-point document breathing scrolls with its rows. Hosts still
    /// own cell content and row chrome; this is table geometry, not an outer viewport gap.
    open var style: Style = .fullWidth {
        didSet { if style != oldValue { finishDocumentGeometry() } }
    }
    private var verticalRowInset: CGFloat { style == .inset ? 10 : 0 }

    public struct AnimationOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let effectFade = Self(rawValue: 1)
        public static let effectGap = Self(rawValue: 2)
        public static let slideUp = Self(rawValue: 16)
        public static let slideDown = Self(rawValue: 32)
        public static let slideLeft = Self(rawValue: 64)
        public static let slideRight = Self(rawValue: 128)
    }
    open func row(for view: NSView) -> Int {
        mounted.first { view.isDescendant(of: $0.value.view) }?.key ?? -1
    }
    open func noteHeightOfRows(withIndexesChanged indexes: IndexSet) {
        if usesAutomaticRowHeights {
            measuredRows.subtract(indexes)
            reconcileVisibleRows()
            return
        }
        var changed = false
        for row in indexes where row >= 0 && row < numberOfRows {
            let height = heightOfRow(row)
            precondition(height.isFinite && height > 0, "table row height must be positive")
            let delta = height - rowHeights[row]
            guard delta != 0 else { continue }
            rowHeights[row] = height
            rowHeightIndex.add(delta, at: row)
            changed = true
        }
        if changed { finishDocumentGeometry() }
    }
    private struct MountedRow {
        let identity: AnyHashable
        let rowView: NSTableRowView
        let view: NSView
    }

    open weak var dataSource: AnyObject?
    open weak var delegate: AnyObject?
    open var usesAutomaticRowHeights = false {
        didSet {
            guard usesAutomaticRowHeights != oldValue else { return }
            measuredRows.removeAll()
            updateDocumentGeometry()
        }
    }
    public private(set) var tableColumns: [NSTableColumn] = []
    open var rowHeight: CGFloat = 44 {
        didSet {
            precondition(rowHeight.isFinite && rowHeight > 0, "rowHeight must be positive")
            updateDocumentGeometry()
        }
    }
    open var intercellSpacing: NSSize = .zero {
        didSet {
            precondition(intercellSpacing.height.isFinite && intercellSpacing.height >= 0,
                         "invalid intercell spacing")
            resizeColumnsToFit()
            updateDocumentGeometry()
        }
    }
    open var allowsMultipleSelection = false
    public private(set) var numberOfRows = 0

    private var mounted: [Int: MountedRow] = [:]
    private var reusable: [NSUserInterfaceItemIdentifier: [NSView]] = [:]
    private var reusableCount = 0
    private var reusableChrome: [NSUserInterfaceItemIdentifier: [NSTableRowView]] = [:]
    private var reusableChromeCount = 0
    private var reusableRows: [NSTableRowView] = []
    private var selectedIdentities: Set<AnyHashable> = []
    private var rowForIdentity: [AnyHashable: Int] = [:]
    private var rowIdentities: [AnyHashable] = []
    private var rowHeights: [CGFloat] = []
    private var rowHeightIndex = RowHeightIndex()
    private var changingDocumentGeometry = false
    private var reconcilingRows = false
    private var measuredRows: Set<Int> = []

    open override var isFlipped: Bool { true }
    open var enclosingScrollView: NSScrollView? { superview?.superview as? NSScrollView }
    open var selectedRowIndexes: IndexSet {
        var indexes = IndexSet()
        for identity in selectedIdentities {
            if let row = rowForIdentity[identity] { indexes.insert(row) }
        }
        return indexes
    }
    open var selectedRow: Int { selectedRowIndexes.first ?? -1 }
    open var visibleRowIndexes: IndexSet { IndexSet(integersIn: visibleRowRange()) }
    open var mountedViewCount: Int { mounted.count }
    open var reusableViewCount: Int { reusableCount }
    open var reusableRowViewCount: Int { reusableRows.count + reusableChromeCount }

    open override var frame: NSRect {
        didSet {
            guard !changingDocumentGeometry, frame.size != oldValue.size else { return }
            if frame.width != oldValue.width {
                resizeColumnsToFit()
                measuredRows.removeAll()
            }
            reconcileVisibleRows()
        }
    }

    open func addTableColumn(_ column: NSTableColumn) {
        tableColumns.append(column)
        resizeColumnsToFit()
    }

    private func resizeColumnsToFit() {
        guard columnAutoresizingStyle == .uniformColumnAutoresizingStyle else { return }
        let resizable = tableColumns.filter { $0.resizingMask.contains(.autoresizingMask) }
        guard !resizable.isEmpty else { return }
        let fixed = tableColumns.filter { !$0.resizingMask.contains(.autoresizingMask) }
            .reduce(CGFloat.zero) { $0 + $1.width }
        let gaps = CGFloat(max(0, tableColumns.count - 1)) * intercellSpacing.width
        let width = max(1, (bounds.width - fixed - gaps) / CGFloat(resizable.count))
        for column in resizable { column.width = width }
    }

    open func removeTableColumn(_ column: NSTableColumn) {
        tableColumns.removeAll { $0 === column }
    }

    open func reloadData() {
        let count = (dataSource as? NSTableViewDataSource)?.numberOfRows(in: self) ?? 0
        setRowCount(count)
    }

    /// Insert indexes describe the updated source. Tail appends extend the height index and
    /// identity map only for new rows; existing viewport cells retain their content.
    open func insertRows(at indexes: IndexSet, withAnimation animationOptions: AnimationOptions) {
        guard !indexes.isEmpty else { return }
        let oldCount = numberOfRows
        let newCount = oldCount + indexes.count
        precondition(indexes.first! >= 0 && indexes.last! < newCount, "invalid inserted rows")
        let appends = indexes.first == oldCount && indexes.last == newCount - 1
        let anchor = viewportAnchor()
        let selectedRows = selectedRowIndexes
        numberOfRows = newCount
        if appends {
            for row in indexes {
                let height = initialHeight(at: row)
                rowHeights.append(height)
                rowHeightIndex.append(height + intercellSpacing.height)
                let identity = rowIdentity(at: row)
                rowIdentities.append(identity)
                rowForIdentity[identity] = row
            }
        } else {
            var oldToNew: [Int] = []
            oldToNew.reserveCapacity(oldCount)
            var heights: [CGFloat] = []
            heights.reserveCapacity(newCount)
            var oldRow = 0
            for row in 0..<newCount {
                if indexes.contains(row) {
                    heights.append(initialHeight(at: row))
                } else {
                    heights.append(rowHeights[oldRow])
                    oldToNew.append(row)
                    oldRow += 1
                }
            }
            rowHeights = heights
            remapRetainedRows { oldToNew[$0] }
            rebuildIdentities(selecting: selectedRows.map { oldToNew[$0] })
            rowHeightIndex.reset(heights.map { $0 + intercellSpacing.height })
            finishStructuralChange(anchor: anchor.map { (oldToNew[$0.row], $0.offset) },
                                   previousSelection: selectedRows)
            return
        }
        finishStructuralChange(anchor: anchor, previousSelection: selectedRows)
    }

    /// Remove indexes describe the old source. Only removed mounted cells are released;
    /// surviving cells and measured heights move with their rows.
    open func removeRows(at indexes: IndexSet, withAnimation animationOptions: AnimationOptions) {
        guard !indexes.isEmpty else { return }
        let oldCount = numberOfRows
        precondition(indexes.first! >= 0 && indexes.last! < oldCount, "invalid removed rows")
        let newCount = oldCount - indexes.count
        let removesTail = indexes.first == newCount && indexes.last == oldCount - 1
        let anchor = viewportAnchor()
        let selectedRows = selectedRowIndexes
        numberOfRows = newCount
        if removesTail {
            for row in indexes {
                if let cell = mounted.removeValue(forKey: row) { recycle(cell) }
                measuredRows.remove(row)
            }
            for identity in rowIdentities.suffix(indexes.count) {
                rowForIdentity[identity] = nil
                selectedIdentities.remove(identity)
            }
            rowIdentities.removeLast(indexes.count)
            rowHeights.removeLast(indexes.count)
            rowHeightIndex.removeLast(indexes.count)
            finishStructuralChange(anchor: anchor.flatMap { $0.row < newCount ? $0 : nil },
                                   previousSelection: selectedRows)
            return
        }
        var oldToNew: [Int?] = []
        oldToNew.reserveCapacity(oldCount)
        var heights: [CGFloat] = []
        heights.reserveCapacity(newCount)
        for row in 0..<oldCount {
            if indexes.contains(row) {
                oldToNew.append(nil)
            } else {
                oldToNew.append(heights.count)
                heights.append(rowHeights[row])
            }
        }
        rowHeights = heights
        remapRetainedRows { oldToNew[$0] }
        rebuildIdentities(selecting: selectedRows.compactMap { oldToNew[$0] })
        rowHeightIndex.reset(heights.map { $0 + intercellSpacing.height })
        let retainedAnchor = anchor.flatMap { value in
            oldToNew[value.row].map { (row: $0, offset: value.offset) }
        }
        finishStructuralChange(anchor: retainedAnchor, previousSelection: selectedRows)
    }

    private func initialHeight(at row: Int) -> CGFloat {
        let height = usesAutomaticRowHeights ? rowHeight : heightOfRow(row)
        precondition(height.isFinite && height > 0, "table row height must be positive")
        return height
    }

    private func viewportAnchor() -> (row: Int, offset: CGFloat)? {
        guard let clip = superview as? NSClipView,
              let row = visibleRowRange().first else { return nil }
        return (row, clip.bounds.minY - rowOffset(row))
    }

    private func remapRetainedRows(_ position: (Int) -> Int?) {
        var retained: [Int: MountedRow] = [:]
        for (row, cell) in mounted {
            guard let newRow = position(row) else {
                recycle(cell)
                continue
            }
            retained[newRow] = MountedRow(identity: rowIdentity(at: newRow),
                rowView: cell.rowView, view: cell.view)
        }
        mounted = retained
        measuredRows = Set(measuredRows.compactMap(position))
    }

    private func rebuildIdentities(selecting rows: [Int]) {
        rowIdentities = (0..<numberOfRows).map { rowIdentity(at: $0) }
        rowForIdentity = Dictionary(uniqueKeysWithValues:
            rowIdentities.enumerated().map { ($0.element, $0.offset) })
        selectedIdentities = Set(rows.map { rowIdentities[$0] })
    }

    private func finishStructuralChange(anchor: (row: Int, offset: CGFloat)?,
                                        previousSelection: IndexSet) {
        // Keep clip notifications from mounting rows at the obsolete offset between resizing
        // the document and restoring the retained reading anchor.
        reconcilingRows = true
        finishDocumentGeometry()
        if let anchor, let clip = superview as? NSClipView {
            clip.scroll(to: NSPoint(x: clip.bounds.minX,
                y: rowOffset(anchor.row) + anchor.offset))
        }
        reconcilingRows = false
        reconcileVisibleRows()
        if selectedRowIndexes != previousSelection { selectionDidChange() }
    }

    /// Reconfigures changed viewport cells without asking the data source for every row.
    open func reloadData(forRowIndexes rows: IndexSet, columnIndexes columns: IndexSet) {
        guard !columns.isEmpty else { return }
        measuredRows.subtract(rows)
        for row in rows {
            guard let cell = mounted.removeValue(forKey: row) else { continue }
            recycle(cell)
        }
        reconcileVisibleRows()
    }

    /// Subclasses may derive rows from a hierarchical source before setting the count.
    func setRowCount(_ count: Int) {
        precondition(count >= 0, "negative table row count")
        // Reload must reconfigure even when an item's identity and row stay fixed. Recycle only
        // the current viewport; the value projection may contain thousands of other rows.
        for cell in mounted.values {
            recycle(cell)
        }
        mounted.removeAll()
        measuredRows.removeAll()
        numberOfRows = count
        rowIdentities = (0..<count).map { rowIdentity(at: $0) }
        rowForIdentity = Dictionary(uniqueKeysWithValues:
            rowIdentities.enumerated().map { ($0.element, $0.offset) })
        updateDocumentGeometry()
        reconcileVisibleRows()
    }

    /// Stable identities let a subclass preserve the same selection as row indexes shift.
    open func rowIdentity(at row: Int) -> AnyHashable { AnyHashable(row) }

    open func rect(ofRow row: Int) -> NSRect {
        guard row >= 0, row < numberOfRows else { return .zero }
        return NSRect(x: 0, y: rowOffset(row),
                      width: frame.width, height: rowHeights[row])
    }

    open func row(at point: NSPoint) -> Int {
        guard point.y >= 0, point.y < frame.height, point.x >= 0,
              point.x < frame.width else { return -1 }
        let index = firstOffset(after: point.y) - 1
        guard index >= 0, index < numberOfRows,
              point.y >= rowOffset(index),
              point.y < rowOffset(index) + rowHeights[index] else { return -1 }
        return index
    }

    open func rows(in rect: NSRect) -> NSRange {
        guard numberOfRows > 0, !rect.isEmpty else { return NSRange(location: 0, length: 0) }
        let lower = max(0, min(numberOfRows, firstOffset(after: rect.minY) - 1))
        let upper = max(lower, min(numberOfRows, firstOffset(atOrAfter: rect.maxY)))
        return NSRange(location: lower, length: upper - lower)
    }

    open func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        let valid = indexes.filter { $0 >= 0 && $0 < numberOfRows && shouldSelectRow($0) }
        let accepted = allowsMultipleSelection ? valid : Array(valid.prefix(1))
        var next = extend ? selectedIdentities : []
        next.formUnion(accepted.map { rowIdentity(at: $0) })
        guard next != selectedIdentities else { return }
        selectedIdentities = next
        selectionDidChange()
    }

    open func deselectAll(_ sender: Any?) {
        guard !selectedIdentities.isEmpty else { return }
        selectedIdentities.removeAll()
        selectionDidChange()
    }

    open func selectAll(_ sender: Any?) {
        guard allowsMultipleSelection else { return }
        selectRowIndexes(IndexSet(integersIn: 0..<numberOfRows), byExtendingSelection: false)
    }

    open func sizeLastColumnToFit() {
        guard tableColumns.count == 1 else { return }
        tableColumns[0].width = bounds.width
    }

    open func scrollRowToVisible(_ row: Int) {
        guard row >= 0, row < numberOfRows, let clip = superview as? NSClipView else { return }
        let rect = rect(ofRow: row)
        let visible = clip.documentVisibleRect
        if usesAutomaticRowHeights, rect.minY < visible.minY || rect.maxY > visible.maxY {
            // Land at the estimated row's start. Measuring a preceding partial row while
            // bottom-aligning the estimate could otherwise push the requested row offscreen.
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: rect.minY))
            return
        }
        if rect.minY < visible.minY {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: rect.minY))
        } else if rect.maxY > visible.maxY {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: rect.maxY - visible.height))
        }
    }

    open func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier,
                       owner: Any?) -> NSView? {
        if var stack = reusable[identifier], let view = stack.popLast() {
            reusable[identifier] = stack.isEmpty ? nil : stack
            reusableCount -= 1
            return view
        }
        guard var stack = reusableChrome[identifier], let row = stack.popLast() else {
            return nil
        }
        reusableChrome[identifier] = stack.isEmpty ? nil : stack
        reusableChromeCount -= 1
        return row
    }

    /// Offscreen requests do not eagerly create a cell. The viewport will ask its delegate when
    /// the row enters the clip, keeping view construction independent of total row count.
    open func view(atColumn column: Int, row: Int, makeIfNecessary: Bool) -> NSView? {
        guard row >= 0, row < numberOfRows, column >= 0,
              column < max(tableColumns.count, 1) else { return nil }
        if makeIfNecessary { reconcileVisibleRows() }
        return mounted[row]?.view
    }

    open func rowView(atRow row: Int, makeIfNecessary: Bool) -> NSTableRowView? {
        guard row >= 0, row < numberOfRows else { return nil }
        if makeIfNecessary { reconcileVisibleRows() }
        return mounted[row]?.rowView
    }

    open func enumerateAvailableRowViews(_ body: (NSTableRowView, Int) -> Void) {
        let cells = mounted.sorted { $0.key < $1.key }
        for (row, cell) in cells { body(cell.rowView, row) }
    }

    open override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        guard index >= 0 else { return }
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    /// A subclass supplies its own delegate callback while sharing viewport recycling.
    open func viewForRow(_ row: Int) -> NSView? {
        (delegate as? NSTableViewDelegate)?.tableView(self, viewFor: tableColumns.first, row: row)
    }

    open func rowViewForRow(_ row: Int) -> NSTableRowView? {
        (delegate as? NSTableViewDelegate)?.tableView(self, rowViewForRow: row)
    }

    /// Read on explicit reload or a row-metric change, never from a viewport callback.
    open func heightOfRow(_ row: Int) -> CGFloat {
        (delegate as? NSTableViewDelegate)?.tableView(self, heightOfRow: row) ?? rowHeight
    }

    open func shouldSelectRow(_ row: Int) -> Bool {
        (delegate as? NSTableViewDelegate)?.tableView(self, shouldSelectRow: row) ?? true
    }

    open func selectionDidChange() {
        for cell in mounted.values {
            cell.rowView.isSelected = selectedIdentities.contains(cell.identity)
        }
        (delegate as? NSTableViewDelegate)?.tableViewSelectionDidChange(
            Notification(name: .NSTableViewSelectionDidChange, object: self))
    }

    func clipViewViewportDidChange(_ clipView: NSClipView) {
        guard clipView.documentView === self else {
            reconcileVisibleRows()
            return
        }
        if frame.width != clipView.bounds.width {
            frame.size.width = clipView.bounds.width
        }
        reconcileVisibleRows()
    }

    private func updateDocumentGeometry() {
        measuredRows.removeAll()
        rowHeights.removeAll(keepingCapacity: true)
        rowHeights.reserveCapacity(numberOfRows)
        var extents: [CGFloat] = []
        extents.reserveCapacity(numberOfRows)
        for row in 0..<numberOfRows {
            let height = usesAutomaticRowHeights ? rowHeight : heightOfRow(row)
            precondition(height.isFinite && height > 0, "table row height must be positive")
            rowHeights.append(height)
            extents.append(height + intercellSpacing.height)
        }
        rowHeightIndex.reset(extents)
        finishDocumentGeometry()
    }

    private func finishDocumentGeometry() {
        let height = rowHeightIndex.offset(numberOfRows) + verticalRowInset * 2
        precondition(height.isFinite, "table document exceeds finite geometry")
        changingDocumentGeometry = true
        if frame.height != height { frame.size.height = height }
        changingDocumentGeometry = false
        if let clip = superview as? NSClipView { clip.scroll(to: clip.bounds.origin) }
        reconcileVisibleRows()
    }

    private func visibleRowRange() -> Range<Int> {
        guard let clip = superview as? NSClipView, clip.documentView === self,
              numberOfRows > 0 else { return 0..<0 }
        let visible = clip.documentVisibleRect
        guard !visible.isEmpty else { return 0..<0 }
        var lower = max(0, min(numberOfRows, firstOffset(after: visible.minY) - 1))
        if lower < numberOfRows,
           visible.minY >= rowOffset(lower) + rowHeights[lower] {
            lower += 1
        }
        let upper = max(lower, min(numberOfRows, firstOffset(atOrAfter: visible.maxY)))
        return lower..<upper
    }

    /// First prefix offset greater than `value` (upper bound).
    private func firstOffset(after value: CGFloat) -> Int {
        rowHeightIndex.firstOffset(value - verticalRowInset, strictlyAfter: true)
    }

    /// First prefix offset greater than or equal to `value` (lower bound).
    private func firstOffset(atOrAfter value: CGFloat) -> Int {
        rowHeightIndex.firstOffset(value - verticalRowInset, strictlyAfter: false)
    }

    private func rowOffset(_ row: Int) -> CGFloat {
        verticalRowInset + rowHeightIndex.offset(row)
    }

    private func reconcileVisibleRows() {
        guard !reconcilingRows else { return }
        reconcilingRows = true
        defer { reconcilingRows = false }
        while true {
            reconcileCurrentViewport()
            guard usesAutomaticRowHeights, measureVisibleRows() else { return }
            // New geometry can reveal another row. Every pass measures previously invalid
            // viewport cells; hidden history never constructs a measurement view.
            finishDocumentGeometry()
        }
    }

    private func measureVisibleRows() -> Bool {
        var changed = false
        for row in mounted.keys.sorted() where !measuredRows.contains(row) {
            guard let cell = mounted[row] else { continue }
            let height = max(1, cell.view.fittingSize.height)
            precondition(height.isFinite, "automatic table height must be finite")
            measuredRows.insert(row)
            let delta = height - rowHeights[row]
            guard abs(delta) > 0.001 else { continue }
            rowHeights[row] = height
            rowHeightIndex.add(delta, at: row)
            changed = true
        }
        return changed
    }

    private func reconcileCurrentViewport() {
        let visible = visibleRowRange()
        let visibleSet = Set(visible)
        for row in Array(mounted.keys) {
            guard let cell = mounted[row], !visibleSet.contains(row)
                || cell.identity != rowIdentity(at: row) else { continue }
            recycle(cell)
            mounted[row] = nil
        }
        trimReusableViews(to: max(8, visible.count + 2))
        trimReusableRows(to: visible.count + 2)

        for row in visible where mounted[row] == nil {
            guard let view = viewForRow(row) else { continue }
            let rowView = rowViewForRow(row) ?? reusableRows.popLast()
                ?? makeView(withIdentifier: NSUserInterfaceItemIdentifier("NSTableViewRowViewKey"),
                            owner: self) as? NSTableRowView
                ?? NSTableRowView(frame: .zero)
            let rect = rect(ofRow: row)
            rowView.frame = rect
            rowView.isSelected = selectedIdentities.contains(rowIdentity(at: row))
            view.frame = NSRect(origin: .zero, size: rect.size)
            rowView.addSubview(view)
            addSubview(rowView)
            mounted[row] = MountedRow(identity: rowIdentity(at: row), rowView: rowView, view: view)
            (delegate as? NSTableViewDelegate)?.tableView(self, didAdd: rowView, forRow: row)
        }
        for row in visible {
            guard let cell = mounted[row] else { continue }
            let rect = rect(ofRow: row)
            if cell.rowView.frame != rect { cell.rowView.frame = rect }
            let contentRect = NSRect(origin: .zero, size: rect.size)
            if cell.view.frame != contentRect { cell.view.frame = contentRect }
        }
        trimReusableViews(to: max(8, visible.count + 2))
        trimReusableRows(to: visible.count + 2)
    }

    private func recycle(_ cell: MountedRow) {
        cell.rowView.removeFromSuperview()
        cell.view.removeFromSuperview()
        (cell.view as? NSTableCellView)?.prepareForReuse()
        recycle(cell.view)
        // A delegate-owned row may be reused through makeView(withIdentifier:owner:), just as
        // its cell is. The default shell has no identifier and uses its own small reuse pool.
        if type(of: cell.rowView) == NSTableRowView.self,
           cell.rowView.identifier == nil {
            reusableRows.append(cell.rowView)
        } else if let identifier = cell.rowView.identifier {
            reusableChrome[identifier, default: []].append(cell.rowView)
            reusableChromeCount += 1
        }
    }

    private func trimReusableRows(to limit: Int) {
        if reusableRows.count > limit {
            reusableRows.removeFirst(reusableRows.count - limit)
        }
        guard reusableRowViewCount > limit else { return }
        for identifier in Array(reusableChrome.keys) {
            while reusableRowViewCount > limit,
                  var stack = reusableChrome[identifier], !stack.isEmpty {
                stack.removeLast()
                reusableChromeCount -= 1
                reusableChrome[identifier] = stack.isEmpty ? nil : stack
            }
            if reusableRowViewCount <= limit { break }
        }
    }

    private func recycle(_ view: NSView) {
        guard let identifier = view.identifier else { return }
        reusable[identifier, default: []].append(view)
        reusableCount += 1
    }

    private func trimReusableViews(to limit: Int) {
        guard reusableCount > limit else { return }
        for identifier in Array(reusable.keys) {
            while reusableCount > limit, var stack = reusable[identifier], !stack.isEmpty {
                stack.removeLast()
                reusableCount -= 1
                reusable[identifier] = stack.isEmpty ? nil : stack
            }
            if reusableCount <= limit { break }
        }
    }
}
