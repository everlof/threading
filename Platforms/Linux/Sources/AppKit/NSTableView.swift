import Foundation

@MainActor
public final class NSTableColumn {
    public let identifier: NSUserInterfaceItemIdentifier
    public var width: CGFloat = 100

    public init(identifier: NSUserInterfaceItemIdentifier) {
        self.identifier = identifier
    }
}

@MainActor
open class NSTableCellView: NSView {}

@MainActor
public protocol NSTableViewDataSource: AnyObject {
    func numberOfRows(in tableView: NSTableView) -> Int
}

@MainActor
public protocol NSTableViewDelegate: AnyObject {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool
    func tableViewSelectionDidChange(_ notification: Notification)
}

public extension NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
    func tableViewSelectionDidChange(_ notification: Notification) {}
}

public extension Notification.Name {
    static let NSTableViewSelectionDidChange = Notification.Name("NSTableViewSelectionDidChange")
}

/// A uniform-height, view-based table document. The data source owns values; the table owns
/// viewport cells. Reloads may enumerate the source, but scroll and resize only touch mounted
/// rows. A table is normally the direct documentView of an NSScrollView.
@MainActor
open class NSTableView: NSView, NSClipViewDocumentObserver {
    private struct MountedRow {
        let identity: AnyHashable
        let view: NSView
    }

    open weak var dataSource: AnyObject?
    open weak var delegate: AnyObject?
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
            updateDocumentGeometry()
        }
    }
    open var allowsMultipleSelection = false
    public private(set) var numberOfRows = 0

    private var mounted: [Int: MountedRow] = [:]
    private var reusable: [NSUserInterfaceItemIdentifier: [NSView]] = [:]
    private var reusableCount = 0
    private var selectedIdentities: Set<AnyHashable> = []
    private var rowForIdentity: [AnyHashable: Int] = [:]
    private var changingDocumentGeometry = false

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

    open override var frame: NSRect {
        didSet {
            guard !changingDocumentGeometry, frame.size != oldValue.size else { return }
            reconcileVisibleRows()
        }
    }

    open func addTableColumn(_ column: NSTableColumn) {
        tableColumns.append(column)
    }

    open func removeTableColumn(_ column: NSTableColumn) {
        tableColumns.removeAll { $0 === column }
    }

    open func reloadData() {
        let count = (dataSource as? NSTableViewDataSource)?.numberOfRows(in: self) ?? 0
        setRowCount(count)
    }

    /// Reconfigures changed viewport cells without asking the data source for every row.
    open func reloadData(forRowIndexes rows: IndexSet, columnIndexes columns: IndexSet) {
        guard !columns.isEmpty else { return }
        for row in rows {
            guard let cell = mounted.removeValue(forKey: row) else { continue }
            cell.view.removeFromSuperview()
            recycle(cell.view)
        }
        reconcileVisibleRows()
    }

    /// Subclasses may derive rows from a hierarchical source before setting the count.
    func setRowCount(_ count: Int) {
        precondition(count >= 0, "negative table row count")
        // Reload must reconfigure even when an item's identity and row stay fixed. Recycle only
        // the current viewport; the value projection may contain thousands of other rows.
        for cell in mounted.values {
            cell.view.removeFromSuperview()
            recycle(cell.view)
        }
        mounted.removeAll()
        numberOfRows = count
        rowForIdentity = Dictionary(uniqueKeysWithValues:
            (0..<count).map { (rowIdentity(at: $0), $0) })
        updateDocumentGeometry()
        reconcileVisibleRows()
    }

    /// Stable identities let a subclass preserve the same selection as row indexes shift.
    open func rowIdentity(at row: Int) -> AnyHashable { AnyHashable(row) }

    open func rect(ofRow row: Int) -> NSRect {
        guard row >= 0, row < numberOfRows else { return .zero }
        return NSRect(x: 0, y: CGFloat(row) * rowStride,
                      width: frame.width, height: rowHeight)
    }

    open func row(at point: NSPoint) -> Int {
        guard point.y >= 0, point.y < frame.height, point.x >= 0,
              point.x < frame.width else { return -1 }
        let index = Int(point.y / rowStride)
        guard index < numberOfRows, point.y < rect(ofRow: index).maxY else { return -1 }
        return index
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

    open func scrollRowToVisible(_ row: Int) {
        guard row >= 0, row < numberOfRows, let clip = superview as? NSClipView else { return }
        let rect = rect(ofRow: row)
        let visible = clip.documentVisibleRect
        if rect.minY < visible.minY {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: rect.minY))
        } else if rect.maxY > visible.maxY {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: rect.maxY - visible.height))
        }
    }

    open func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier,
                       owner: Any?) -> NSView? {
        guard var stack = reusable[identifier], let view = stack.popLast() else { return nil }
        reusable[identifier] = stack.isEmpty ? nil : stack
        reusableCount -= 1
        return view
    }

    /// Offscreen requests do not eagerly create a cell. The viewport will ask its delegate when
    /// the row enters the clip, keeping view construction independent of total row count.
    open func view(atColumn column: Int, row: Int, makeIfNecessary: Bool) -> NSView? {
        guard row >= 0, row < numberOfRows, column >= 0,
              column < max(tableColumns.count, 1) else { return nil }
        if makeIfNecessary { reconcileVisibleRows() }
        return mounted[row]?.view
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

    open func shouldSelectRow(_ row: Int) -> Bool {
        (delegate as? NSTableViewDelegate)?.tableView(self, shouldSelectRow: row) ?? true
    }

    open func selectionDidChange() {
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

    private var rowStride: CGFloat { rowHeight + intercellSpacing.height }

    private func updateDocumentGeometry() {
        let height = CGFloat(numberOfRows) * rowStride
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
        let lower = max(0, min(numberOfRows, Int(floor(visible.minY / rowStride))))
        let upper = max(lower, min(numberOfRows, Int(ceil(visible.maxY / rowStride))))
        return lower..<upper
    }

    private func reconcileVisibleRows() {
        let visible = visibleRowRange()
        let visibleSet = Set(visible)
        for row in Array(mounted.keys) {
            guard let cell = mounted[row], !visibleSet.contains(row)
                || cell.identity != rowIdentity(at: row) else { continue }
            cell.view.removeFromSuperview()
            recycle(cell.view)
            mounted[row] = nil
        }
        trimReusableViews(to: max(8, visible.count + 2))

        for row in visible where mounted[row] == nil {
            guard let view = viewForRow(row) else { continue }
            view.frame = rect(ofRow: row)
            addSubview(view)
            mounted[row] = MountedRow(identity: rowIdentity(at: row), view: view)
        }
        for row in visible {
            guard let cell = mounted[row] else { continue }
            let rect = rect(ofRow: row)
            if cell.view.frame != rect { cell.view.frame = rect }
        }
        trimReusableViews(to: max(8, visible.count + 2))
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
