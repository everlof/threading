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
        case thinking(String)
        case native(ConversationTimeline.Row)
        case nativeStreaming(String)
        /// A host-owned decision card. The card is retained here, so scrolling it out of the
        /// viewport releases only its row host, never the pending decision.
        case decision(NSView)
    }
    private var entries: [Entry]
    private var nextID: Int
    /// The live stream's tail row, kept last so settled rows insert above it.
    private(set) var streamingIndex: Int?
    /// Pending decision cards, after everything else in arrival order, as the Mac transcript
    /// appends them. Hosts bound how many can wait, so the block stays small.
    private var decisionCount = 0
    private var decisionStart: Int { entries.count - decisionCount }
    private(set) var constructed = 0
    private(set) var configured = 0
    private(set) var released = 0
    private(set) var live: Set<Int> = []
    private var activeDiffs: [Int: DiffView] = [:]
    private var expandedUsers: Set<Int> = []
    /// Tool rows the reader opened. A recycled host rebuilds the row closed unless it is here.
    private(set) var expandedTools: Set<Int> = []
    private var nativeLocations: [Int: (start: Int, count: Int)] = [:]
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
    /// Stable timeline identity survives a tool result replacing its pending row. Markdown
    /// partitions arrive from the host's worker, and only viewport cells become views.
    func updateNativeRow(_ row: ConversationTimeline.Row, at index: Int,
                         blocks: [String]?, in table: NSTableView) {
        let contents: [Content]
        switch row {
        case .assistant(let text): contents = (blocks ?? [text]).map(Content.markdown)
        case .thinking(let text): contents = (blocks ?? [text]).map(Content.thinking)
        case .userMessage(let message): contents = [.user(message.text)]
        default: contents = [.native(row)]
        }
        if let location = nativeLocations[index] {
            let start = location.start, count = location.count
            if count == contents.count {
                for offset in 0..<count {
                    entries[start + offset] = Entry(id: entries[start + offset].id, content: contents[offset])
                }
                table.reloadData(forRowIndexes: IndexSet(integersIn: start..<(start + count)), columnIndexes: IndexSet(integer: 0))
                return
            }
            // Only pending tool results update a settled native row. Its one-row anatomy is
            // stable; do not search/reindex the transcript on each streamed tool update.
            preconditionFailure("native result update changed its settled row anatomy")
        }
        let start = settledInsertionPoint
        appendSettled(contents, in: table)
        nativeLocations[index] = (start, contents.count)
    }
    /// Shows, updates or retires the one streaming row. An update reloads only that row.
    func setStreaming(_ text: String?, in table: NSTableView, native: Bool = false) {
        func content(_ value: String) -> Content { native ? .nativeStreaming(value) : .streaming(value) }
        switch (text, streamingIndex) {
        case (let text?, nil):
            let index = decisionStart
            entries.insert(Entry(id: nextID, content: content(text)), at: index)
            nextID += 1
            streamingIndex = index
            table.insertRows(at: IndexSet(integer: index), withAnimation: [])
        case (let text?, let index?):
            entries[index] = Entry(id: entries[index].id, content: content(text))
            table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        case (nil, let index?):
            entries.remove(at: index)
            streamingIndex = nil
            table.removeRows(at: IndexSet(integer: index), withAnimation: [])
        case (nil, nil):
            break
        }
    }
    /// Makes the trailing block exactly `cards`. A card already shown keeps its row; a retired
    /// one leaves; a new one appends. No other row is reloaded.
    func setDecisions(_ cards: [NSView], in table: NSTableView) {
        for index in (decisionStart..<entries.count).reversed() {
            guard case .decision(let card) = entries[index].content,
                  !cards.contains(where: { $0 === card }) else { continue }
            entries.remove(at: index)
            decisionCount -= 1
            table.removeRows(at: IndexSet(integer: index), withAnimation: [])
        }
        let shown = entries[decisionStart...].compactMap { entry -> NSView? in
            if case .decision(let card) = entry.content { return card } else { return nil }
        }
        for card in cards where !shown.contains(where: { $0 === card }) {
            entries.append(Entry(id: nextID, content: .decision(card)))
            nextID += 1
            decisionCount += 1
            table.insertRows(at: IndexSet(integer: entries.count - 1), withAnimation: [])
        }
    }
    private var settledInsertionPoint: Int { streamingIndex ?? decisionStart }
    private func appendSettled(_ contents: [Content], in table: NSTableView) {
        guard !contents.isEmpty else { return }
        let start = settledInsertionPoint
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
        case .nativeStreaming(let text): content = ConversationRowView.streaming(text)
        case .thinking(let source): content = MarkdownView(markdown: source, style: .thinking)
        case .decision(let card): content = card
        case .native(let row):
            switch row {
            case .turnOutcome(let outcome): content = ConversationRowView.turnOutcome(outcome)
            case .notice(let text, let kind): content = ConversationRowView.notice(text, kind: kind)
            case .toolCall(let call):
                // The production row, collapsed to its one line until opened. Charts have no
                // Linux card yet, so a chart call shows as its tool row.
                let tool = ToolCallView(tool: call.tool, summary: call.summary, diff: call.diff)
                if let result = call.result { tool.setResult(result.text, outcome: result.outcome) }
                tool.setExpanded(expandedTools.contains(entry.id), notifying: false)
                tool.onExpansionChanged = { [weak self, weak tableView, weak host] expanded in
                    guard let self else { return }
                    if expanded { expandedTools.insert(entry.id) } else { expandedTools.remove(entry.id) }
                    guard let tableView, let host else { return }
                    let row = tableView.row(for: host)
                    if row >= 0 { tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row)) }
                }
                content = tool
            default: preconditionFailure("native row has a dedicated content case")
            }
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
