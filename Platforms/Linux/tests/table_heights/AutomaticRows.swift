import AppKit
import Foundation

@MainActor
final class AutomaticRows: NSTableViewDataSource, NSTableViewDelegate {
    let count: Int
    var live: Set<Int> = []
    var configured = 0
    var created = 0
    var heightReads = 0
    var overrides: [Int: String] = [:]
    let identifier = NSUserInterfaceItemIdentifier("AutomaticRow")

    init(count: Int) { self.count = count }
    func numberOfRows(in tableView: NSTableView) -> Int { count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        heightReads += 1
        return 48
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let host: ConversationVirtualRowHost
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? ConversationVirtualRowHost {
            host = reused
        } else {
            host = ConversationVirtualRowHost()
            created += 1
        }
        configured += 1
        host.identifier = identifier
        host.setColumnWidth(tableColumn?.width ?? tableView.bounds.width)
        let label = NSTextField(wrappingLabelWithString: overrides[row]
            ?? "Row \(row): Unicode é 👩🏽‍🚀 remains readable while the shared conversation cell wraps to its column.")
        label.isSelectable = true
        label.font = .systemFont(ofSize: 13)
        live.insert(row)
        host.install(label, topInset: 12, bottomInset: 4, onRelease: { [weak self] in self?.live.remove(row) })
        return host
    }
}

@MainActor
func verifyAutomaticRows() {
    for count in [1_000, 10_000] {
        let source = AutomaticRows(count: count)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 0))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Content"))
        column.width = 240
        table.addTableColumn(column)
        table.usesAutomaticRowHeights = true
        table.dataSource = source
        table.delegate = source
        scroll.documentView = table
        let owner = NSWindow(backingScaleFactor: 2)
        owner.contentView = scroll
        table.reloadData()
        precondition(source.heightReads == 0 && source.configured < 8, "automatic height eagerly measured history")
        precondition(table.rect(ofRow: 0).height > 48, "wrapped row kept its estimate")
        precondition(source.live.count == table.mountedViewCount, "recycled row retained its content")
        let before = table.rect(ofRow: 0).height
        column.width = 160
        table.frame.size.width = 160
        ConversationVirtualRowHost.stateColumnWidth(in: table)
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<count))
        precondition(table.rect(ofRow: 0).height > before, "narrow row did not reflow")

        let configured = source.configured
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: count - 1))
        precondition(source.configured == configured, "offscreen invalidation constructed a cell")
        let middle = count / 2
        table.scrollRowToVisible(middle)
        precondition(table.view(atColumn: 0, row: middle, makeIfNecessary: false) != nil)
        precondition(source.live.count == table.mountedViewCount && source.created < 8)
        source.overrides[middle] = "Short replacement"
        table.reloadData(forRowIndexes: IndexSet(integer: middle), columnIndexes: IndexSet(integer: 0))
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: middle))
        precondition(table.rect(ofRow: middle).height < before, "changed row retained its old height")
        precondition(source.heightReads == 0)
        print("PASS \(count) automatic rows: production host, lazy measurements, width reflow, changed height and released content; \(source.created) cells")
    }
}
