import AppKit

// MARK: - Surface

/// What one transcript surface adds to the shared table.
///
/// The main conversation and a child's transcript draw the same rows through `ConversationRowView`,
/// and for a while each also carried its own copy of everything around those rows: the cheap
/// ordering list, the tool-run disclosures, the disclosure sets that outlive a recycled row, and
/// the host that recycles it. Two copies of one mechanism drift — the child grew a block-level
/// Markdown split the parent did not have, the parent grew row wrappers the child could not reach,
/// and a fold or spacing fix landed in one of them. The mechanism now lives once, in
/// `ConversationTranscriptTable`; a surface supplies only what is genuinely its own.
@MainActor
protocol ConversationTranscriptSurface: AnyObject {
    /// The identity of an item only this surface presents — a turn fold, a retained card, the
    /// child navigator — alongside the shared timeline, divider and tool-fold identities.
    associatedtype SurfaceItemID: Hashable
    /// What such an item holds.
    associatedtype SurfaceItemContent

    /// The canonical rows every `.timeline` and `.markdown` item points into.
    var transcriptRows: [ConversationTimeline.Row] { get }

    /// The view for one of the surface's own items, asked for each time a host materializes it.
    func transcriptView(for content: SurfaceItemContent, id: SurfaceItemID) -> NSView

    /// Wraps a row `ConversationRowView` built in whatever the surface adds around it — a speaker
    /// wrapper, an extension host, contextual actions. The default adds nothing.
    func transcriptRowView(
        _ view: NSView,
        decorating row: ConversationTimeline.Row,
        at index: Int
    ) -> NSView

    /// The vertical rhythm of one of the surface's own items. The default is a piece of chrome.
    func transcriptRhythm(for content: SurfaceItemContent, id: SurfaceItemID) -> Design.Chat.Rhythm
}

extension ConversationTranscriptSurface {
    func transcriptRowView(
        _ view: NSView,
        decorating row: ConversationTimeline.Row,
        at index: Int
    ) -> NSView {
        view
    }

    func transcriptRhythm(for content: SurfaceItemContent, id: SurfaceItemID) -> Design.Chat.Rhythm {
        .chrome
    }
}

enum ConversationTranscriptDefaults {
    /// Parsed Markdown blocks kept for rows the viewport recently asked for. Sixty-four covers a
    /// screen of blocks either side of the visible ones without retaining a long answer's worth.
    static let markdownBlockCacheLimit = 64
    static let columnIdentifier = "ConversationTranscriptContent"
    static let rowReuseIdentifier = "ConversationTranscriptRow"
}

#if DEBUG
/// Where a row mount spends its time, summed since the last reload. Read by the opt-in stress
/// sweeps, which cannot attribute a slow first paint from the outside.
struct ConversationTranscriptMaterializationDurations {
    var count = 0
    var markdownCount = 0
    var totalNanoseconds: UInt64 = 0
    var hostNanoseconds: UInt64 = 0
    var contentNanoseconds: UInt64 = 0
    var markdownContentNanoseconds: UInt64 = 0
    var installNanoseconds: UInt64 = 0
}
#endif

// MARK: - Table

/// A conversation's virtualized transcript: the complete cheap ordering, the viewport-sized set of
/// row hosts AppKit recycles, and the disclosure state that has to outlive them.
///
/// The table decides placement — which item goes where, what space it gets above it, when a run
/// of tool calls becomes one disclosure — and materializes a row only when a host asks for it.
/// What a row *is* stays in `ConversationTimeline`; what one *looks like* stays in
/// `ConversationRowView`; what a surface adds around it arrives through
/// `ConversationTranscriptSurface`.
@MainActor
final class ConversationTranscriptTable<Surface: ConversationTranscriptSurface>: NSObject,
    NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Items

    enum ItemID: Hashable {
        case timeline(Int)
        case markdown(row: Int, block: Int)
        case divider(turnStart: Int)
        case toolFold(firstIndex: Int)
        case surface(Surface.SurfaceItemID)
    }

    struct Item {
        enum Content {
            case timeline(Int)
            /// One block of an assistant row, when the surface splits long answers.
            case markdown(row: Int, block: Int, source: String)
            case divider
            case toolFold(indices: [Int])
            case surface(Surface.SurfaceItemContent)

            /// The timeline row this item stands for, if any.
            var timelineIndex: Int? {
                switch self {
                case .timeline(let index): return index
                case .markdown(let row, _, _): return row
                case .divider, .toolFold, .surface: return nil
                }
            }
        }

        let id: ItemID
        let content: Content

        init(id: ItemID, content: Content) {
            self.id = id
            self.content = content
        }

        /// The timeline row this item is the first presentation of — the row itself, or the
        /// first block of a split answer — which is where a jump to that row lands.
        var leadingTimelineIndex: Int? {
            switch content {
            case .timeline(let index): return index
            case .markdown(let row, let block, _): return block == 0 ? row : nil
            case .divider, .toolFold, .surface: return nil
            }
        }
    }

    // MARK: - Properties

    let tableView: ThemedTableView
    let scrollView: ThemedScrollView

    weak var surface: Surface?

    /// Complete ordering without a complete view tree. Timeline rows carry only their stable
    /// integer identity; expensive Markdown/tool views are constructed when the table requests
    /// a viewport row and released when that host is reused.
    private(set) var items: [Item] = []

    /// Currently materialized timeline rows. This is intentionally viewport-sized; it exists
    /// for live result delivery and diagnostics, not as the transcript's ownership graph.
    private(set) var rowViews: [Int: NSView] = [:]

    /// Every item a host currently holds, timeline or not.
    private(set) var materializedItemIDs: Set<ItemID> = []

    /// Disclosure state belongs outside recyclable views, so scrolling a row away and back does
    /// not collapse something the user opened.
    var expandedToolGroups: Set<Int> = []
    var expandedToolRows: Set<Int> = []
    var expandedUserRows: Set<Int> = []

    /// Whether a long assistant answer is presented block by block, so revealing one near the
    /// bottom of a narrow pane does not attach a document-sized constraint tree at once. The
    /// main conversation keeps one row per answer — its wrappers and contextual actions belong
    /// to the message, and `MarkdownView` already pages inside it.
    var splitsAssistantMarkdown = false

    /// True once the surface's view exists, so structural edits reach AppKit from then on.
    private(set) var isLive = false

    /// While true, mutations touch only the model; `reload(force:)` ends the batch. Replay
    /// sets it, because telling AppKit about every replayed row makes construction quadratic.
    var suspendsUpdates = false

    /// Exact timeline identity → table row lookup. A batch leaves it alone and rebuilds it once
    /// at the reload that ends the batch; a live structural edit rebuilds it at once.
    private var rowsByTimelineIndex: [Int: Int] = [:]

    /// Tool rows whose result may still arrive while they are on screen.
    private var pendingToolViews: [Int: ToolCallView] = [:]

    /// The consecutive tool run at the presentation tail. Keeping this tiny bit of reduction
    /// state makes extending a 500-call run O(1) instead of repeatedly walking its whole turn.
    private var activeToolGroupIndices: [Int] = []

    /// The readable width at which AppKit last owned valid automatic row heights. One scalar is
    /// enough to invalidate its cache after wrapping changes.
    private var automaticHeightWidth: CGFloat = 0

    private var isRebuilding = false

    private struct CachedMarkdownBlock {
        let source: String
        let block: MarkdownBlock
    }
    private var markdownBlockCache: [ItemID: CachedMarkdownBlock] = [:]
    private var markdownBlockRecency: [ItemID] = []
    private var cachedMarkdownStyle: MarkdownStyle?

#if DEBUG
    private(set) var rowMaterializationDurations = ConversationTranscriptMaterializationDurations()
#endif

    // MARK: - Initialization

    override init() {
        let table = ThemedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier(ConversationTranscriptDefaults.columnIdentifier)
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = ConversationDefaults.estimatedRowHeight
        table.usesAutomaticRowHeights = true
        table.autoresizingMask = [.width]
        tableView = table

        let clip = FlippedClipView()
        clip.drawsBackground = false
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = clip
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        scrollView = scroll

        super.init()
        table.delegate = self
        table.dataSource = self
    }

    // MARK: - Lifecycle

    /// Tells the table its surface's view exists. Until then the model may change freely and
    /// AppKit is told nothing; from here on structural edits reach the table as they happen.
    func activate() {
        guard !isLive else { return }
        isLive = true
        rebuildRowIndex()
        tableView.reloadData()
    }

    /// States the column to every visible cell and invalidates automatic heights once the
    /// readable width has moved. Called from the surface's `viewDidLayout`, because a cell AppKit
    /// does not rebuild would otherwise keep centring itself in a column that no longer exists.
    func layoutColumn() {
        let column = ConversationVirtualRowHost.stateColumnWidth(in: tableView)
        let width = min(
            Design.Size.readableWidth,
            max(0, column - Design.Spacing.inset * 2)
        )
        guard width > 0 else { return }
        if automaticHeightWidth == 0 {
            automaticHeightWidth = width
            return
        }
        guard abs(width - automaticHeightWidth) > 0.5 else { return }
        automaticHeightWidth = width
        if tableView.numberOfRows > 0 {
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows)
            )
        }
    }

    // MARK: - Mutation

    private var notifies: Bool { isLive && !suspendsUpdates && !isRebuilding }

    /// Replaces the whole ordering and reloads once. The materialized working set is dropped;
    /// AppKit asks again for the handful of rows that are actually visible.
    func replaceItems(_ newItems: [Item]) {
        items = newItems
        activeToolGroupIndices.removeAll(keepingCapacity: true)
        reload()
    }

    /// Appends an item of the surface's own. Ends any tool run at the tail: whatever follows a
    /// card or a placeholder is no longer adjacent to the calls before it.
    func append(_ item: Item) {
        appendItem(item, endsToolRun: true)
    }

    /// Ends the tool run at the tail without appending anything, for a surface that has just
    /// folded or removed the calls it was made of.
    func endToolRun() {
        activeToolGroupIndices.removeAll(keepingCapacity: true)
    }

    func insert(_ newItems: [Item], at position: Int) {
        guard !newItems.isEmpty else { return }
        let position = min(max(0, position), items.count)
        let appendsAtTail = position == items.count
        items.insert(contentsOf: newItems, at: position)
        if !suspendsUpdates, !isRebuilding {
            if appendsAtTail {
                for (offset, item) in newItems.enumerated() {
                    if let index = item.leadingTimelineIndex {
                        rowsByTimelineIndex[index] = position + offset
                    }
                }
            } else {
                rebuildRowIndex()
            }
        }
        guard notifies else { return }
        tableView.insertRows(
            at: IndexSet(integersIn: position..<(position + newItems.count)),
            withAnimation: []
        )
    }

    /// Inserts directly after the item with `anchor`, or at the end when it is gone. The
    /// position is remembered as an identity rather than an index because the caller may have
    /// been waiting on a diff while the conversation moved on underneath it.
    func insert(_ newItems: [Item], after anchor: ItemID?) {
        let position = anchor.flatMap { index(of: $0) }.map { $0 + 1 } ?? items.count
        insert(newItems, at: position)
    }

    func remove(at positions: IndexSet) {
        guard !positions.isEmpty, let first = positions.first else { return }
        var removedLeadingIndices: [Int] = []
        for position in positions.reversed() where items.indices.contains(position) {
            let item = items[position]
            forget(item)
            if let index = item.leadingTimelineIndex { removedLeadingIndices.append(index) }
            items.remove(at: position)
        }
        if !suspendsUpdates, !isRebuilding {
            if first >= items.count {
                for index in removedLeadingIndices { rowsByTimelineIndex[index] = nil }
            } else {
                rebuildRowIndex()
            }
        }
        guard notifies else { return }
        tableView.removeRows(at: positions, withAnimation: [])
    }

    func remove(_ id: ItemID) {
        guard let position = index(of: id) else { return }
        remove(at: IndexSet(integer: position))
    }

    /// Reloads the table from the model. Nothing happens before `activate()`, and nothing
    /// happens inside a suspended batch unless `force` ends it.
    func reload(force: Bool = false) {
        guard isLive, force || !suspendsUpdates else { return }
        rebuildRowIndex()
        rowViews.removeAll(keepingCapacity: true)
        pendingToolViews.removeAll(keepingCapacity: true)
        materializedItemIDs.removeAll(keepingCapacity: true)
#if DEBUG
        rowMaterializationDurations = ConversationTranscriptMaterializationDurations()
#endif
        tableView.reloadData()
    }

    private func appendItem(_ item: Item, endsToolRun: Bool) {
        if endsToolRun { activeToolGroupIndices.removeAll(keepingCapacity: true) }
        let position = items.count
        items.append(item)
        if !suspendsUpdates, !isRebuilding, let index = item.leadingTimelineIndex {
            rowsByTimelineIndex[index] = position
        }
        guard notifies else { return }
        tableView.insertRows(at: IndexSet(integer: position), withAnimation: [])
    }

    private func replaceItem(at position: Int, with item: Item) {
        guard items.indices.contains(position) else { return }
        forget(items[position])
        items[position] = item
        guard notifies, position < tableView.numberOfRows else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: position),
            columnIndexes: IndexSet(integer: 0)
        )
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: position))
    }

    /// Drops what the table remembers about an item that is leaving the ordering. AppKit may
    /// discard rather than recycle its host, so the release handler is not guaranteed to run.
    private func forget(_ item: Item) {
        materializedItemIDs.remove(item.id)
        if case .timeline(let index) = item.content {
            rowViews[index] = nil
            pendingToolViews[index] = nil
        }
    }

    private func rebuildRowIndex() {
        rowsByTimelineIndex.removeAll(keepingCapacity: true)
        rowsByTimelineIndex.reserveCapacity(items.count)
        for (row, item) in items.enumerated() {
            if let index = item.leadingTimelineIndex {
                rowsByTimelineIndex[index] = row
            }
        }
    }

    // MARK: - Lookup

    /// The table row a timeline row leads, whether or not it has a materialized view.
    func row(forTimelineIndex index: Int) -> Int? {
        if let row = rowsByTimelineIndex[index],
           items.indices.contains(row),
           items[row].leadingTimelineIndex == index {
            return row
        }
        // From the tail: the row being asked about is almost always recent, and during a
        // replay batch the index is deliberately empty, so a scan from the front would make
        // every fold walk the whole transcript.
        return items.lastIndex { $0.leadingTimelineIndex == index }
    }

    func index(of id: ItemID) -> Int? {
        if case .timeline(let index) = id,
           let row = row(forTimelineIndex: index),
           items[row].id == id {
            return row
        }
        // The tail is where a streaming placeholder lives and is asked about on every token, so
        // it is answered before any walk.
        if items.last?.id == id { return items.count - 1 }
        return items.lastIndex { $0.id == id }
    }

    /// Whether the presentation contains a row for this timeline index.
    func presents(timelineIndex index: Int) -> Bool {
        row(forTimelineIndex: index) != nil
    }

    // MARK: - Heights

    func noteHeightChanged(of id: ItemID) {
        guard isLive, !suspendsUpdates,
              let row = index(of: id),
              row < tableView.numberOfRows else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    func noteHeightChanged(ofTimelineRow index: Int) {
        guard isLive, !suspendsUpdates,
              let row = row(forTimelineIndex: index),
              row < tableView.numberOfRows else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    // MARK: - Timeline Rows

    /// Presents the row the timeline just appended, under the placement rules both surfaces
    /// share: a rule before every exchange but the first, a lone tool call as its own row, a
    /// second adjacent call turning the pair into one disclosure that later calls extend in
    /// O(1), and — when the surface asks — an answer split at its block boundaries.
    func appendTimelineRow(at index: Int) {
        guard let rows = surface?.transcriptRows else { return }
        appendTimelineRow(at: index, rows: rows)
    }

    private func appendTimelineRow(at index: Int, rows: [ConversationTimeline.Row]) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        var startsTurn = false
        if case .userMessage = row { startsTurn = true }

        // Not before the first turn: a rule at the very top of the pane separates the
        // conversation from nothing.
        if startsTurn, index > 0 {
            appendItem(
                Item(id: .divider(turnStart: index), content: .divider),
                endsToolRun: true
            )
        }

        if case .toolCall(let call) = row, call.chart == nil {
            appendToolCall(at: index, rows: rows)
            return
        }

        if splitsAssistantMarkdown, case .assistant(let markdown) = row {
            let sources = Markdown.sourceBlocks(markdown)
            if !sources.isEmpty {
                for (block, source) in sources.enumerated() {
                    appendItem(
                        Item(
                            id: .markdown(row: index, block: block),
                            content: .markdown(row: index, block: block, source: source)
                        ),
                        endsToolRun: true
                    )
                }
                return
            }
        }

        appendItem(Item(id: .timeline(index), content: .timeline(index)), endsToolRun: true)
    }

    /// Rebuilds the whole presentation from the surface's rows behind `prefix`, then reloads
    /// once. Live rows and rebuilt rows therefore take the same shape, because they are built by
    /// the same append.
    func rebuild(prefix: [Item] = []) {
        isRebuilding = true
        items = prefix
        activeToolGroupIndices.removeAll(keepingCapacity: true)
        let rows = surface?.transcriptRows ?? []
        for index in rows.indices {
            appendTimelineRow(at: index, rows: rows)
        }
        isRebuilding = false
        reload()
    }

    /// Reduces a consecutive tool run to one disclosure as it arrives. The canonical rows remain
    /// in the timeline; only the viewport-sized presentation changes. A lone call stays visible,
    /// while the second turns the pair into a group and later calls extend it.
    private func appendToolCall(at index: Int, rows: [ConversationTimeline.Row]) {
        let plain = Item(id: .timeline(index), content: .timeline(index))

        if activeToolGroupIndices.isEmpty {
            guard index > 0,
                  case .toolCall(let previousCall) = rows[index - 1],
                  previousCall.chart == nil,
                  items.last?.id == .timeline(index - 1)
            else {
                appendItem(plain, endsToolRun: false)
                return
            }

            let indices = [index - 1, index]
            activeToolGroupIndices = indices
            rowsByTimelineIndex[index - 1] = nil
            replaceItem(
                at: items.count - 1,
                with: Item(
                    id: .toolFold(firstIndex: index - 1),
                    content: .toolFold(indices: indices)
                )
            )
            // A rebuilt transcript can form a group the reader already had open.
            if expandedToolGroups.contains(index - 1) {
                for member in indices {
                    appendItem(
                        Item(id: .timeline(member), content: .timeline(member)),
                        endsToolRun: false
                    )
                }
            }
            return
        }

        let previousCount = activeToolGroupIndices.count
        guard activeToolGroupIndices.last == index - 1,
              let first = activeToolGroupIndices.first else {
            activeToolGroupIndices.removeAll(keepingCapacity: true)
            appendItem(plain, endsToolRun: false)
            return
        }

        let foldPosition = expandedToolGroups.contains(first)
            ? items.count - previousCount - 1
            : items.count - 1
        guard items.indices.contains(foldPosition),
              items[foldPosition].id == .toolFold(firstIndex: first) else {
            activeToolGroupIndices.removeAll(keepingCapacity: true)
            appendItem(plain, endsToolRun: false)
            return
        }

        activeToolGroupIndices.append(index)
        replaceItem(
            at: foldPosition,
            with: Item(
                id: .toolFold(firstIndex: first),
                content: .toolFold(indices: activeToolGroupIndices)
            )
        )
        if expandedToolGroups.contains(first) {
            appendItem(plain, endsToolRun: false)
        }
    }

    // MARK: - Disclosures

    /// Puts hidden timeline rows back after a fold, or takes them out again: the one mechanism
    /// behind tool-run disclosures and whatever folds a surface adds of its own.
    func setRows(_ indices: [Int], expanded: Bool, after foldID: ItemID) {
        guard let foldPosition = index(of: foldID) else { return }
        if expanded {
            insert(
                indices.map { Item(id: .timeline($0), content: .timeline($0)) },
                at: foldPosition + 1
            )
        } else {
            let hidden = Set(indices)
            remove(at: IndexSet(items.indices.filter { position in
                guard let index = items[position].content.timelineIndex else { return false }
                return hidden.contains(index)
            }))
        }
    }

    func setToolGroup(_ indices: [Int], expanded: Bool) {
        guard let first = indices.first,
              index(of: .toolFold(firstIndex: first)) != nil else { return }
        if expanded {
            guard expandedToolGroups.insert(first).inserted else { return }
        } else {
            guard expandedToolGroups.remove(first) != nil else { return }
        }
        setRows(indices, expanded: expanded, after: .toolFold(firstIndex: first))
    }

    /// Makes an exact tool target addressable without giving up compact groups by default.
    /// Keyboard navigation, minimap jumps and deep links all pass through the same reveal path.
    func revealToolGroup(containing timelineIndex: Int) {
        for item in items {
            guard case .toolFold(let indices) = item.content,
                  indices.contains(timelineIndex) else { continue }
            setToolGroup(indices, expanded: true)
            return
        }
    }

    /// Forgets what the reader had open, for a transcript that is being swapped for another.
    func forgetDisclosures() {
        expandedToolGroups.removeAll(keepingCapacity: true)
        expandedToolRows.removeAll(keepingCapacity: true)
        expandedUserRows.removeAll(keepingCapacity: true)
        clearMarkdownBlockCache()
    }

    /// Font and colour resolution is pane state, not row state. A theme event invalidates the
    /// style snapshot together with the parsed-block cache.
    func invalidateStyleCaches() {
        cachedMarkdownStyle = nil
        clearMarkdownBlockCache()
    }

    // MARK: - Results

    /// Hands a result that arrived after its row was materialized to that row. An interrupted
    /// row keeps its view reference: the real result can still arrive after the turn ends, and
    /// it should land on the row rather than be lost.
    func applyToolResult(at index: Int) {
        guard let rows = surface?.transcriptRows, rows.indices.contains(index),
              case .toolCall(let call) = rows[index],
              let result = call.result else { return }
        pendingToolViews[index]?.setResult(result.text, outcome: result.outcome)
        if result.outcome != .interrupted { pendingToolViews[index] = nil }
        noteHeightChanged(ofTimelineRow: index)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row tableRow: Int
    ) -> NSView? {
        guard items.indices.contains(tableRow) else { return nil }
        let item = items[tableRow]
#if DEBUG
        let mountStarted = DispatchTime.now().uptimeNanoseconds
#endif
        let identifier = NSUserInterfaceItemIdentifier(
            ConversationTranscriptDefaults.rowReuseIdentifier
        )
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ConversationVirtualRowHost ?? ConversationVirtualRowHost()
        host.identifier = identifier
        host.setColumnWidth(ConversationVirtualRowHost.columnWidth(of: tableView))
#if DEBUG
        let hostEnded = DispatchTime.now().uptimeNanoseconds
#endif

        let content = makeView(for: item)
        materializedItemIDs.insert(item.id)
#if DEBUG
        let contentEnded = DispatchTime.now().uptimeNanoseconds
#endif

        let bottomInset = tableRow == items.count - 1 ? Design.Spacing.inset : 0
        host.install(
            content,
            topInset: topInset(at: tableRow),
            bottomInset: bottomInset,
            onRelease: releaseHandler(for: item, content: content)
        )
#if DEBUG
        let installEnded = DispatchTime.now().uptimeNanoseconds
        rowMaterializationDurations.count += 1
        rowMaterializationDurations.totalNanoseconds += installEnded &- mountStarted
        rowMaterializationDurations.hostNanoseconds += hostEnded &- mountStarted
        rowMaterializationDurations.contentNanoseconds += contentEnded &- hostEnded
        rowMaterializationDurations.installNanoseconds += installEnded &- contentEnded
        if case .markdown = item.content {
            rowMaterializationDurations.markdownCount += 1
            rowMaterializationDurations.markdownContentNanoseconds += contentEnded &- hostEnded
        }
#endif
        return host
    }

    // MARK: - Materialization

    private func makeView(for item: Item) -> NSView {
        switch item.content {
        case .timeline(let index):
            return materializeRow(at: index)

        case .markdown(_, _, let source):
            return markdownBlockView(id: item.id, source: source)

        case .divider:
            return ConversationRowView.turnDivider()

        case .toolFold(let indices):
            let count = indices.count
            let label = count == 1
                ? L10n.string("1 tool call")
                : L10n.format("%lld tool calls", Int64(count))
            let first = indices[0]
            return TurnFoldView(
                label: label,
                folding: [],
                expanded: expandedToolGroups.contains(first)
            ) { [weak self] _, expanded in
                self?.setToolGroup(indices, expanded: expanded)
            }

        case .surface(let content):
            guard case .surface(let id) = item.id, let surface else { return NSView() }
            return surface.transcriptView(for: content, id: id)
        }
    }

    /// Creates one viewport instance. The timeline owns result data and this table owns
    /// disclosure state, so recycling and later reconstruction produce the same row without
    /// retaining its constraint tree.
    private func materializeRow(at index: Int) -> NSView {
        guard let surface else { return NSView() }
        let rows = surface.transcriptRows
        guard rows.indices.contains(index) else { return NSView() }
        let row = rows[index]
        let (nativeView, _) = ConversationRowView.make(for: row)
        configureDisclosureState(in: nativeView, rowIndex: index)
        let view = surface.transcriptRowView(nativeView, decorating: row, at: index)
        rowViews[index] = view

        // A missing or interrupted result may still arrive while this instance is visible.
        if case .toolCall(let call) = row,
           call.result == nil || call.result?.outcome == .interrupted {
            pendingToolViews[index] = nativeView as? ToolCallView
        }
        return view
    }

    private func markdownBlockView(id: ItemID, source: String) -> NSView {
        guard let block = markdownBlock(id: id, source: source) else {
            return MarkdownView(markdown: source)
        }
        let availableWidth = min(
            Design.Size.readableWidth,
            max(
                1,
                ConversationVirtualRowHost.columnWidth(of: tableView) - Design.Spacing.inset * 2
            )
        )
        return MarkdownView.blockView(
            for: block,
            style: markdownStyle,
            availableWidth: availableWidth
        )
    }

    private func markdownBlock(id: ItemID, source: String) -> MarkdownBlock? {
        if let cached = markdownBlockCache[id], cached.source == source {
            touchMarkdownBlock(id)
            return cached.block
        }

        guard let block = Markdown.parse(source, style: markdownStyle).first else { return nil }
        markdownBlockCache[id] = CachedMarkdownBlock(source: source, block: block)
        touchMarkdownBlock(id)
        while markdownBlockRecency.count > ConversationTranscriptDefaults.markdownBlockCacheLimit {
            let evicted = markdownBlockRecency.removeFirst()
            markdownBlockCache.removeValue(forKey: evicted)
        }
        return block
    }

    var cachedMarkdownBlockCount: Int { markdownBlockCache.count }

    private var markdownStyle: MarkdownStyle {
        if let cachedMarkdownStyle { return cachedMarkdownStyle }
        let resolved = MarkdownStyle.assistant
        cachedMarkdownStyle = resolved
        return resolved
    }

    private func touchMarkdownBlock(_ id: ItemID) {
        if let existing = markdownBlockRecency.firstIndex(of: id) {
            markdownBlockRecency.remove(at: existing)
        }
        markdownBlockRecency.append(id)
    }

    private func clearMarkdownBlockCache() {
        markdownBlockCache.removeAll(keepingCapacity: true)
        markdownBlockRecency.removeAll(keepingCapacity: true)
    }

    private func releaseHandler(for item: Item, content: NSView) -> (() -> Void)? {
        let id = item.id
        guard case .timeline(let index) = item.content else {
            return { [weak self] in self?.materializedItemIDs.remove(id) }
        }
        return { [weak self, weak content] in
            guard let self else { return }
            self.materializedItemIDs.remove(id)
            guard let content else { return }
            if self.rowViews[index] === content {
                self.rowViews[index] = nil
            }
            if let tool = Self.firstDescendant(ToolCallView.self, in: content),
               self.pendingToolViews[index] === tool {
                self.pendingToolViews[index] = nil
            }
        }
    }

    private func configureDisclosureState(in view: NSView, rowIndex: Int) {
        if let tool = Self.firstDescendant(ToolCallView.self, in: view) {
            tool.onExpansionChanged = { [weak self] expanded in
                guard let self else { return }
                if expanded {
                    self.expandedToolRows.insert(rowIndex)
                } else {
                    self.expandedToolRows.remove(rowIndex)
                }
                self.noteHeightChanged(ofTimelineRow: rowIndex)
            }
            tool.setExpanded(expandedToolRows.contains(rowIndex), notifying: false)
        }

        if let bubble = Self.firstDescendant(UserMessageBubbleView.self, in: view) {
            bubble.onExpansionChanged = { [weak self] expanded in
                guard let self else { return }
                if expanded {
                    self.expandedUserRows.insert(rowIndex)
                } else {
                    self.expandedUserRows.remove(rowIndex)
                }
                self.noteHeightChanged(ofTimelineRow: rowIndex)
            }
            bubble.setExpanded(expandedUserRows.contains(rowIndex), notifying: false)
        }
    }

    // MARK: - Spacing

    /// What separates an item from the one above it: the pane's inset at the top, and below
    /// that the two rows' own rhythms composed by `Design.Chat.Rhythm.gap(between:and:)`.
    /// Nothing here knows about pairs; a row that wants more or less room declares it once.
    private func topInset(at row: Int) -> CGFloat {
        guard row > 0 else { return Design.Spacing.inset }
        return Design.Chat.Rhythm.gap(between: rhythm(of: items[row - 1]), and: rhythm(of: items[row]))
    }

    /// The gap the table lays out above a row, for tests that measure the rhythm.
    func gap(above row: Int) -> CGFloat {
        guard items.indices.contains(row) else { return 0 }
        return topInset(at: row)
    }

    func rhythm(of item: Item) -> Design.Chat.Rhythm {
        switch item.content {
        case .timeline(let index):
            guard let rows = surface?.transcriptRows, rows.indices.contains(index) else {
                return .chrome
            }
            return ConversationRowView.rhythm(for: rows[index])
        case .markdown:
            return .answer
        case .divider:
            return .boundary
        case .toolFold:
            return .work
        case .surface(let content):
            guard case .surface(let id) = item.id, let surface else { return .chrome }
            return surface.transcriptRhythm(for: content, id: id)
        }
    }

    private static func firstDescendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = firstDescendant(type, in: child) { return match }
        }
        return nil
    }
}

// MARK: - Row Host

/// Reusable shell around a conversation row. The host, not the content, is what AppKit recycles;
/// replacing its child releases offscreen Markdown and tool constraint trees while AppKit keeps
/// automatic height ownership for the presentation table.
final class ConversationVirtualRowHost: NSTableCellView {
    private var releaseContent: (() -> Void)?

    /// The width of the column this cell sits in, which has to be *stated* — see
    /// `setColumnWidth`. Held on the cell rather than the content so it survives recycling.
    private lazy var columnWidth: NSLayoutConstraint = {
        // Above the content's own compression resistance and below required: a row too narrow
        // for what is in it gives way in the words, never by growing past the pane. Required
        // would make the same choice by breaking someone else's required constraint and
        // logging it as a failure.
        let constraint = widthAnchor.constraint(equalToConstant: 0)
        constraint.priority = ConversationDefaults.columnWidthPriority
        return constraint
    }()

    /// States how wide the cell's column is, because AppKit does not.
    ///
    /// **A cell is not given its column's width.** Under `usesAutomaticRowHeights` the table
    /// solves the cell from the constraints inside it, and a width nothing determines settles on
    /// the smallest that satisfies them. So a row capped at the readable measure came out
    /// `readableWidth` plus its insets — 644pt — sitting at the column's leading edge, and the
    /// `centerXAnchor` below centred the content inside *that* rather than in the pane. The
    /// column the whole pane is designed around was therefore flush left in every window wider
    /// than 644, which is most of them: prose and bubbles hugged the sidebar with several
    /// hundred points of empty pane beside them, and the turn rail — placed for a column that
    /// is *centred* — landed on the first character of every paragraph.
    ///
    /// Stating the width is what makes `centerXAnchor` mean the pane's centre. It also closes
    /// the older fault the other way round: with the cell pinned to its column it can no longer
    /// grow past the clip in a pane narrower than the column.
    func setColumnWidth(_ width: CGFloat) {
        guard width > 0 else {
            columnWidth.isActive = false
            return
        }
        guard !columnWidth.isActive || abs(columnWidth.constant - width) > 0.5 else { return }
        columnWidth.constant = width
        columnWidth.isActive = true
    }

    /// The column a table's cells stand in — the table's own, not its pane's, because the table
    /// insets the column and a cell centred on the pane's width would sit off that centre by
    /// half the inset.
    static func columnWidth(of tableView: NSTableView) -> CGFloat {
        tableView.tableColumns.first?.width ?? tableView.bounds.width
    }

    /// Tells every cell currently on screen how wide its column is, and answers with it.
    ///
    /// Called from the host's `viewDidLayout`, because a cell AppKit does not rebuild would
    /// otherwise go on centring itself in a column that no longer exists — the pane can be
    /// dragged wider without a single row being recycled.
    @discardableResult
    static func stateColumnWidth(in tableView: NSTableView) -> CGFloat {
        let width = columnWidth(of: tableView)
        guard width > 0 else { return width }
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                (cell as? ConversationVirtualRowHost)?.setColumnWidth(width)
            }
        }
        return width
    }

    func install(
        _ content: NSView,
        topInset: CGFloat,
        bottomInset: CGFloat,
        onRelease: (() -> Void)?
    ) {
        releaseInstalledContent()
        releaseContent = onRelease

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let sideInset = Design.Spacing.inset

        // The pane's width leads and the readable column is a cap, never the other way round.
        //
        // A cell is not pinned to its column: under automatic row heights the table solves the
        // cell's own width from the constraints inside it, so a row that *asks* for the readable
        // measure gets it even where there is no room — the cell grows past the clip, taking the
        // words with it. Nothing announces that; the pane has no horizontal scroller, so the
        // sentences are simply cut mid-word at its edge. This shipped as a child transcript in
        // the display pane, which is routinely narrower than the column, rendering as clipped
        // paragraphs with an untouched gutter of pane behind them. Ordering the two the other
        // way had the same intent and only worked while the pane was wide enough to hide it.
        //
        // The cell's own width is stated by `setColumnWidth`; without it neither this nor the
        // centring below has a column to be a fraction of.
        let paneWidth = content.widthAnchor.constraint(
            equalTo: widthAnchor,
            constant: -sideInset * 2
        )
        paneWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: sideInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -sideInset),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: Design.Size.readableWidth),
            paneWidth
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseInstalledContent()
    }

    private func releaseInstalledContent() {
        releaseContent?()
        releaseContent = nil
        subviews.forEach { $0.removeFromSuperview() }
    }
}
