import AppKit
import Foundation

@MainActor
final class Rows: NSTableViewDataSource, NSTableViewDelegate {
    let count: Int
    var overrides: [Int: CGFloat] = [:]
    var heightReads = 0
    init(count: Int) { self.count = count }
    func numberOfRows(in tableView: NSTableView) -> Int { count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        heightReads += 1
        return overrides[row] ?? 20
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSView(frame: .zero)
    }
}

@main
@MainActor
enum Fixture {
    static func main() {
        verifyStructuralRows()
        verifyAutomaticRows()
        for count in [1_000, 10_000] {
            let rows = Rows(count: count)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 0))
            table.dataSource = rows
            table.delegate = rows
            scroll.documentView = table
            table.reloadData()
            let first = table.view(atColumn: 0, row: 0, makeIfNecessary: false)!
            precondition(table.row(for: first) == 0 && table.mountedViewCount <= 6)
            rows.heightReads = 0
            rows.overrides[3] = 50
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 3))
            precondition(rows.heightReads == 1, "one height change reread history")
            precondition(table.rect(ofRow: 4).minY == 110)
            precondition(table.rect(ofRow: count - 1).minY == CGFloat((count - 1) * 20 + 30))
            precondition(table.row(at: NSPoint(x: 10, y: 109)) == 3)
            precondition(table.row(at: NSPoint(x: 10, y: 110)) == 4)
            precondition(table.view(atColumn: 0, row: 0, makeIfNecessary: false) === first)

            let middle = count / 2
            rows.overrides[middle] = 31
            rows.heightReads = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: middle))
            precondition(rows.heightReads == 1)
            table.scrollRowToVisible(middle + 1)
            precondition(table.view(atColumn: 0, row: middle + 1, makeIfNecessary: false) != nil)
            precondition(table.mountedViewCount <= 6)
            let started = Date()
            for iteration in 0..<1_000 {
                rows.overrides[middle] = iteration.isMultiple(of: 2) ? 40 : 20
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: middle))
            }
            print("PASS \(count) indexed rows: changed-row reads, exact boundaries, recycled viewport; 1000 changes \(Date().timeIntervalSince(started) * 1000) ms")
        }
    }
}
