import AppKit

/// The attachment chronology's one table and scroll owner. Hosts provide values and actions;
/// this component keeps the column, selection capacity and viewport the same on both desktops.
final class SessionAttachmentListView: ThemedScrollView {
    let tableView: ThemedTableView

    override init(frame frameRect: NSRect) {
        let table = ThemedTableView()
        table.headerView = nil
        table.rowSizeStyle = .default
        // A completely folded chronology has headers but no selectable file row.
        table.allowsEmptySelection = true
        // One drag may carry a selected batch into a composer or terminal.
        table.allowsMultipleSelection = true
        let column = NSTableColumn(identifier: SessionAttachmentListMetrics.columnIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        tableView = table

        super.init(frame: frameRect)
        documentView = table
        hasVerticalScroller = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum SessionAttachmentListMetrics {
    static let columnIdentifier = NSUserInterfaceItemIdentifier("SessionAttachmentsColumn")
    static let rowHeight: CGFloat = 42
    @MainActor static var turnHeaderHeight: CGFloat {
        ThemedDisclosureRow.Density.compact.minimumHeight + Design.Radius.border
    }
}
