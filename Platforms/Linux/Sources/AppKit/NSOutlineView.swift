import Foundation

@MainActor
public protocol NSOutlineViewDataSource: AnyObject {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool
}

@MainActor
public protocol NSOutlineViewDelegate: AnyObject {
    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?, item: Any) -> NSView?
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool
    func outlineViewSelectionDidChange(_ notification: Notification)
}

public extension NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }
    func outlineViewSelectionDidChange(_ notification: Notification) {}
}

public extension Notification.Name {
    static let NSOutlineViewSelectionDidChange = Notification.Name("NSOutlineViewSelectionDidChange")
}

/// AppKit's tree data source and row/selection vocabulary over the virtual NSTableView document.
/// Item identity is reference identity for class instances or value identity for Hashable values.
/// Expanded branches are projected into cheap row records; only clipped rows ask the delegate for
/// an NSView. Explicit reload/expansion may traverse the tree, never a scroll or resize callback.
@MainActor
open class NSOutlineView: NSTableView {
    private enum ItemIdentity: Hashable {
        case reference(ObjectIdentifier)
        case value(AnyHashable)
    }

    private struct OutlineRow {
        let item: Any
        let identity: ItemIdentity
        let level: Int
    }

    private var rows: [OutlineRow] = []
    private var rowForItemIdentity: [ItemIdentity: Int] = [:]
    private var expanded: Set<ItemIdentity> = []

    open var outlineTableColumn: NSTableColumn?
    open var indentationPerLevel: CGFloat = 16

    open override func reloadData() {
        guard let source = dataSource as? NSOutlineViewDataSource else {
            rows = []
            rowForItemIdentity = [:]
            setRowCount(0)
            return
        }

        var projected: [OutlineRow] = []
        var seen: Set<ItemIdentity> = []
        func appendChildren(of parent: Any?, level: Int) {
            let count = source.outlineView(self, numberOfChildrenOfItem: parent)
            precondition(count >= 0, "negative outline child count")
            for index in 0..<count {
                let item = source.outlineView(self, child: index, ofItem: parent)
                let identity = identity(of: item)
                precondition(seen.insert(identity).inserted,
                             "outline data source returned a duplicate item identity")
                projected.append(OutlineRow(item: item, identity: identity, level: level))
                if expanded.contains(identity), source.outlineView(self, isItemExpandable: item) {
                    appendChildren(of: item, level: level + 1)
                }
            }
        }
        appendChildren(of: nil, level: 0)

        rows = projected
        rowForItemIdentity = Dictionary(uniqueKeysWithValues:
            projected.enumerated().map { ($0.element.identity, $0.offset) })
        setRowCount(projected.count)
    }

    open func item(atRow row: Int) -> Any? {
        guard rows.indices.contains(row) else { return nil }
        return rows[row].item
    }

    open func row(forItem item: Any?) -> Int {
        guard let item else { return -1 }
        return rowForItemIdentity[identity(of: item)] ?? -1
    }

    open func level(forItem item: Any?) -> Int {
        let index = row(forItem: item)
        return index >= 0 ? rows[index].level : -1
    }

    open func isItemExpanded(_ item: Any) -> Bool { expanded.contains(identity(of: item)) }

    open func isExpandable(_ item: Any) -> Bool {
        (dataSource as? NSOutlineViewDataSource)?.outlineView(self, isItemExpandable: item) ?? false
    }

    open func expandItem(_ item: Any) {
        guard isExpandable(item), expanded.insert(identity(of: item)).inserted else { return }
        reloadData()
    }

    open func collapseItem(_ item: Any) {
        guard expanded.remove(identity(of: item)) != nil else { return }
        reloadData()
    }

    /// Value changes refresh one visible row. A changed branch structure must request children,
    /// which rebuilds the cheap row projection on this explicit edit path.
    open func reloadItem(_ item: Any, reloadChildren: Bool = false) {
        if reloadChildren {
            reloadData()
        } else if let row = rowForItemIdentity[identity(of: item)] {
            reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
    }

    open override func rowIdentity(at row: Int) -> AnyHashable {
        AnyHashable(rows[row].identity)
    }

    open override func viewForRow(_ row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let column = outlineTableColumn ?? tableColumns.first
        return (delegate as? NSOutlineViewDelegate)?.outlineView(self, viewFor: column,
                                                                  item: rows[row].item)
    }

    open override func shouldSelectRow(_ row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        return (delegate as? NSOutlineViewDelegate)?.outlineView(self,
                                                                  shouldSelectItem: rows[row].item) ?? true
    }

    open override func selectionDidChange() {
        (delegate as? NSOutlineViewDelegate)?.outlineViewSelectionDidChange(
            Notification(name: .NSOutlineViewSelectionDidChange, object: self))
    }

    open override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        guard index >= 0 else { return }
        let item = rows[index].item
        let disclosureEdge = CGFloat(rows[index].level) * indentationPerLevel + indentationPerLevel
        if point.x < disclosureEdge, isExpandable(item) {
            if isItemExpanded(item) { collapseItem(item) } else { expandItem(item) }
            return
        }
        super.mouseDown(with: event)
    }

    private func identity(of item: Any) -> ItemIdentity {
        if Mirror(reflecting: item).displayStyle == .class {
            return .reference(ObjectIdentifier(item as AnyObject))
        }
        guard let hashable = item as? AnyHashable else {
            preconditionFailure("outline items must be reference objects or Hashable values")
        }
        return .value(hashable)
    }
}
