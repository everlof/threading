import AppKit
import Foundation

@MainActor
private final class StructuralCell: NSTableCellView {
    var representedID = -1
    var contentHeight: CGFloat = 20
    var released: (() -> Void)?
    override var intrinsicContentSize: NSSize { NSSize(width: 100, height: contentHeight) }
    override func prepareForReuse() { released?(); released = nil }
}

@MainActor
private final class StructuralRows: NSTableViewDataSource, NSTableViewDelegate {
    var ids: [Int]
    var heights: [Int: CGFloat] = [:]
    var heightReads = 0
    var configured = 0
    var released = 0
    var selectionChanges = 0
    let identifier = NSUserInterfaceItemIdentifier("StructuralRow")
    init(count: Int) { ids = Array(0..<count) }
    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        heightReads += 1
        return heights[ids[row]] ?? 20
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? StructuralCell
            ?? StructuralCell(frame: .zero)
        cell.identifier = identifier
        cell.representedID = ids[row]
        cell.contentHeight = heights[ids[row]] ?? 20
        cell.released = { [weak self] in self?.released += 1 }
        configured += 1
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanges += 1 }
}

@MainActor
private final class StructuralTable: NSTableView {
    var source: StructuralRows!
    var stableIdentity = false
    var identityReads = 0
    override func rowIdentity(at row: Int) -> AnyHashable {
        identityReads += 1
        return AnyHashable(stableIdentity ? source.ids[row] : row)
    }
}

@MainActor
func verifyStructuralRows() {
    for count in [1_000, 10_000] {
        for automatic in [false, true] {
            for stable in [false, true] {
                let source = StructuralRows(count: count)
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
                let table = StructuralTable(frame: NSRect(x: 0, y: 0, width: 200, height: 0))
                table.source = source
                table.stableIdentity = stable
                table.rowHeight = 20
                table.usesAutomaticRowHeights = automatic
                table.dataSource = source
                table.delegate = source
                scroll.documentView = table
                table.reloadData()
                let first = table.view(atColumn: 0, row: 0, makeIfNecessary: false)!
                let configured = source.configured
                source.heightReads = 0
                table.identityReads = 0
                source.ids.append(count)
                table.insertRows(at: IndexSet(integer: count), withAnimation: [])
                precondition(table.numberOfRows == count + 1)
                precondition(table.view(atColumn: 0, row: 0, makeIfNecessary: false) === first)
                precondition(source.configured == configured && table.identityReads < 30,
                             "tail append enumerated or rebuilt history")
                precondition(source.heightReads == (automatic ? 0 : 1))
                precondition(table.rect(ofRow: count).minY == CGFloat(count * 20))
                table.identityReads = 0
                source.ids.removeLast()
                table.removeRows(at: IndexSet(integer: count), withAnimation: [])
                precondition(table.identityReads < 30 && source.configured == configured,
                             "tail removal enumerated or rebuilt history")

                var expectedTail = CGFloat(count * 20)
                for addition in 0..<40 {
                    let row = source.ids.count
                    let id = count + addition
                    let height = CGFloat(21 + addition % 7)
                    source.ids.append(id)
                    source.heights[id] = height
                    source.heightReads = 0
                    table.identityReads = 0
                    table.insertRows(at: IndexSet(integer: row), withAnimation: [])
                    precondition(table.rect(ofRow: row).minY == expectedTail,
                                 "extended prefix tree lost a preceding extent")
                    precondition(table.identityReads < 30 && source.configured == configured)
                    precondition(source.heightReads == (automatic ? 0 : 1))
                    expectedTail += automatic ? 20 : height
                }
                source.ids.removeLast(40)
                table.removeRows(at: IndexSet(integersIn: count..<(count + 40)), withAnimation: [])
                precondition(table.frame.height == CGFloat(count * 20))

                let middle = count / 2
                table.scrollRowToVisible(middle)
                table.selectRowIndexes(IndexSet(integer: middle), byExtendingSelection: false)
                let held = table.view(atColumn: 0, row: middle, makeIfNecessary: false) as! StructuralCell
                let relativeY = table.rect(ofRow: middle).minY - scroll.contentView.bounds.minY
                let oldHeight = table.rect(ofRow: middle).height
                source.heightReads = 0
                let beforeInsert = source.configured
                source.ids.insert(-1, at: 2)
                source.heights[-1] = 35
                table.insertRows(at: IndexSet(integer: 2), withAnimation: [])
                precondition(table.selectedRow == middle + 1)
                precondition(table.view(atColumn: 0, row: middle + 1, makeIfNecessary: false) === held)
                precondition(source.configured == beforeInsert && held.representedID == middle)
                precondition(table.rect(ofRow: middle + 1).height == oldHeight)
                precondition(table.rect(ofRow: middle + 1).minY - scroll.contentView.bounds.minY == relativeY,
                             "insertion above viewport moved the reading anchor")
                precondition(source.heightReads == (automatic ? 0 : 1))

                source.ids.remove(at: 2)
                table.removeRows(at: IndexSet(integer: 2), withAnimation: [])
                precondition(table.selectedRow == middle)
                precondition(table.view(atColumn: 0, row: middle, makeIfNecessary: false) === held)
                precondition(table.rect(ofRow: middle).minY - scroll.contentView.bounds.minY == relativeY)
                let positions = IndexSet([0, middle - 10, source.ids.count + 2])
                for (offset, row) in positions.enumerated() {
                    source.ids.insert(-10 - offset, at: row)
                }
                source.heightReads = 0
                table.insertRows(at: positions, withAnimation: [])
                precondition(source.heightReads == (automatic ? 0 : 3))
                precondition(table.view(atColumn: 0, row: middle + 2, makeIfNecessary: false) === held)
                precondition(table.selectedRow == middle + 2)
                for row in positions.reversed() { source.ids.remove(at: row) }
                table.removeRows(at: positions, withAnimation: [])
                precondition(table.view(atColumn: 0, row: middle, makeIfNecessary: false) === held)
                precondition(table.selectedRow == middle)
                let released = source.released
                source.ids.remove(at: middle)
                table.removeRows(at: IndexSet(integer: middle), withAnimation: [])
                precondition(table.selectedRow == -1 && source.released > released)
                precondition(table.mountedViewCount <= 6 && table.reusableViewCount <= 8)
                for row in table.visibleRowIndexes {
                    let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as! StructuralCell
                    precondition(cell.representedID == source.ids[row], "structural edit left stale row content")
                    precondition(table.row(for: cell) == row)
                }
                print("PASS \(count) structural rows: automatic=\(automatic), stable=\(stable); tail scope, retained cells/heights, anchored insertion/removal and selection")
            }
        }
    }
}
