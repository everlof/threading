#if os(Linux)
import AppKit
import NativeDiffAppKit
import NativeDiffCore
@testable import CoreSlice

/// Viewport data for the diagnostic's assistant blocks. The production grammar, block views
/// and conversation row host own presentation; this supplies only the cheap source ordering.
@MainActor
final class DocumentRowSource: NSTableViewDataSource, NSTableViewDelegate {
    private struct Entry {
        let id: Int
        let content: Content
    }
    private enum Content {
        case markdown(String)
        case diff([DiffLine])
    }
    private var entries: [Entry]
    private var nextID: Int
    private(set) var constructed = 0
    private(set) var configured = 0
    private(set) var released = 0
    private(set) var live: Set<Int> = []
    private var activeDiffs: [Int: DiffView] = [:]
    private let identifier = NSUserInterfaceItemIdentifier("ConversationDiagnosticRow")

    var appDiffViewCount: Int { activeDiffs.count }
    var contextReference: String? { activeDiffs.values.first?.contextAttachment(atDisplayedLine: 0)?.plainAnchor }
    var contextPreviewRows: Int { activeDiffs.values.first?.contextPreview(spanningDisplayedLines: 0...0)?.rows.count ?? 0 }

    init(sources: [String]) {
        entries = sources.enumerated().map { Entry(id: $0.offset, content: .markdown($0.element)) }
        nextID = sources.count
    }
    init(diffLines: [DiffLine]) {
        entries = [Entry(id: 0, content: .diff(diffLines))]
        nextID = 1
    }
    func refreshTheme() {
        NotificationCenter.default.post(AppThemeDidChange())
    }
    func insert(_ source: String, at row: Int, in table: NSTableView) {
        entries.insert(Entry(id: nextID, content: .markdown(source)), at: row)
        nextID += 1
        table.insertRows(at: IndexSet(integer: row), withAnimation: [])
    }
    func remove(at row: Int, in table: NSTableView) {
        entries.remove(at: row)
        table.removeRows(at: IndexSet(integer: row), withAnimation: [])
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let host: ConversationVirtualRowHost
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? ConversationVirtualRowHost {
            host = reused
        } else {
            host = ConversationVirtualRowHost()
            constructed += 1
        }
        host.identifier = identifier
        host.setColumnWidth(tableColumn?.width ?? tableView.bounds.width)
        let available = max(1, min(Design.Size.readableWidth, tableView.bounds.width - Design.Spacing.inset * 2))
        let entry = entries[row]
        let content: NSView
        switch entry.content {
        case .markdown(let source):
            content = Markdown.parse(source, style: .assistant).first.map {
                MarkdownView.blockView(for: $0, style: .assistant, availableWidth: available)
            } ?? MarkdownView(markdown: source)
        case .diff(let lines):
            let diff = DiffView(lines: lines, path: "greeting.swift")
            activeDiffs[entry.id] = diff
            content = diff
        }
        configured += 1
        live.insert(entry.id)
        host.install(content, topInset: MarkdownDefaults.blockSpacing, bottomInset: 0,
                     onRelease: { [weak self] in
                         self?.live.remove(entry.id)
                         self?.activeDiffs[entry.id] = nil
                         self?.released += 1
                     })
        return host
    }
}
#endif
