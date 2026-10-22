#if os(Linux)
import AppKit
import Foundation

/// Exercises AppKit's default row vending path, where the delegate supplies cells but no row.
@MainActor
enum ThemedTableRowFixture {
    private final class Source: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { 2 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            let label = NSTextField(labelWithString: row == 0 ? "Selected" : "Other")
            label.textColor = Design.Text.label
            return label
        }
    }

    static func run(output: String) throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        root.appearance = LinuxTheme.appearance
        let owner = NSWindow(backingScaleFactor: 1)
        owner.contentView = root
        owner.isKeyWindow = true

        let source = Source()
        let table = ThemedTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fixture"))
        column.width = 320
        table.addTableColumn(column)
        table.rowHeight = 44
        table.dataSource = source
        table.delegate = source

        let scroll = ThemedScrollView()
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        owner.layoutIfNeeded()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        guard table.rowView(atRow: 0, makeIfNecessary: true) is ThemedTableRowView,
              table.rowView(atRow: 1, makeIfNecessary: true) is ThemedTableRowView else {
            fatalError("default table rows did not use the shared themed row")
        }

        let bitmap = Bitmap(width: 320, height: 120,
                            background: LinuxTheme.components("ground"))
        root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
        let path = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try PNGWriter.write(bitmap, to: path)
        print("PASS shared themed table row default vending and render")
    }
}
#endif
