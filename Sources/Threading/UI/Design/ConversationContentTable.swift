import AppKit

/// Automatic-height content hosting for the native conversation rows. The surface supplies its
/// data/delegate; the Design layer owns construction and the initial geometry estimate.
@MainActor
enum ConversationContentTable {
    static func make() -> NSTableView {
        let table = ThemedTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ConversationTranscriptContent"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.rowHeight = 48
        table.usesAutomaticRowHeights = true
        table.autoresizingMask = [.width]
        return table
    }
}
