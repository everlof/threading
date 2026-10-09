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
        /// A reply still arriving. It can span several blocks, so it renders as a whole page.
        case streaming(String)
        case user(String)
    }
    private var entries: [Entry]
    private var nextID: Int
    /// The live stream's tail row, kept last so settled rows insert above it.
    private(set) var streamingIndex: Int?
    private(set) var constructed = 0
    private(set) var configured = 0
    private(set) var released = 0
    private(set) var live: Set<Int> = []
    private var activeDiffs: [Int: DiffView] = [:]
    private var expandedUsers: Set<Int> = []
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
    init(userMessage: String) {
        entries = [Entry(id: 0, content: .user(userMessage))]
        nextID = 1
    }
    /// An empty transcript a live stream fills.
    init() {
        entries = []
        nextID = 0
    }
    var markdownBlocks: Int {
        entries.filter { if case .markdown = $0.content { return true } else { return false } }.count
    }
    var diffRows: Int {
        entries.filter { if case .diff = $0.content { return true } else { return false } }.count
    }
    /// Settled content goes above the streaming tail, one table row per Markdown block.
    func appendBlocks(_ sources: [String], in table: NSTableView) {
        appendSettled(sources.map(Content.markdown), in: table)
    }
    func appendUser(_ text: String, in table: NSTableView) {
        appendSettled([.user(text)], in: table)
    }
    func appendDiff(_ lines: [DiffLine], in table: NSTableView) {
        appendSettled([.diff(lines)], in: table)
    }
    /// Shows, updates or retires the one streaming row. An update reloads only that row.
    func setStreaming(_ text: String?, in table: NSTableView) {
        switch (text, streamingIndex) {
        case (let text?, nil):
            entries.append(Entry(id: nextID, content: .streaming(text)))
            nextID += 1
            streamingIndex = entries.count - 1
            table.insertRows(at: IndexSet(integer: entries.count - 1), withAnimation: [])
        case (let text?, let index?):
            entries[index] = Entry(id: entries[index].id, content: .streaming(text))
            table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        case (nil, let index?):
            entries.remove(at: index)
            streamingIndex = nil
            table.removeRows(at: IndexSet(integer: index), withAnimation: [])
        case (nil, nil):
            break
        }
    }
    private func appendSettled(_ contents: [Content], in table: NSTableView) {
        guard !contents.isEmpty else { return }
        let start = streamingIndex ?? entries.count
        for (offset, content) in contents.enumerated() {
            entries.insert(Entry(id: nextID, content: content), at: start + offset)
            nextID += 1
        }
        if streamingIndex != nil { streamingIndex = start + contents.count }
        table.insertRows(at: IndexSet(integersIn: start..<(start + contents.count)), withAnimation: [])
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
        case .streaming(let text):
            content = MarkdownView(markdown: text)
        case .user(let text):
            content = ConversationUserRow.make(text, expanded: expandedUsers.contains(entry.id), onExpansionChanged: { [weak self, weak tableView, weak host] expanded in
                guard let self else { return }
                if expanded { expandedUsers.insert(entry.id) } else { expandedUsers.remove(entry.id) }
                guard let tableView, let host else { return }
                let row = tableView.row(for: host)
                if row >= 0 { tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row)) }
            })
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
