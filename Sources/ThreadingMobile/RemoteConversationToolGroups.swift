import ThreadingRemoteKit

/// A presentation projection, never a replacement for the canonical transcript.
///
/// Expected runs contain 2–20 tools; stress coverage uses 5,000. A collapsed run owns one
/// collection identity and no member views. Appends touch only the tail, result updates touch
/// their indexed group, and a disclosure inserts ordinary reusable rows into the collection.
struct RemoteConversationToolGroups {
    /// Classify only known tool identities. Command text and model prose are not evidence of
    /// the operation's outcome (a Bash command mentioning tests does not mean tests passed).
    enum Activity: CaseIterable {
        case read, edit, search, command, browser, other

        init(toolName: String?) {
            switch toolName?.lowercased() {
            case "read", "read_file", "readfile": self = .read
            case "edit", "write", "apply_patch", "edit_file", "write_file", "multiedit": self = .edit
            case "grep", "glob", "search", "file_search", "web_search": self = .search
            case "bash", "exec_command", "shell", "run_terminal_cmd", "terminal": self = .command
            case "browser", "browser_navigate", "browser_snapshot", "browser_screenshot": self = .browser
            default: self = .other
            }
        }

        func label(count: Int) -> String {
            if count == 1 {
                switch self {
                case .read: return MobileL10n.string("1 file read")
                case .edit: return MobileL10n.string("1 edit")
                case .search: return MobileL10n.string("1 search")
                case .command: return MobileL10n.string("1 command")
                case .browser: return MobileL10n.string("1 browser action")
                case .other: return MobileL10n.string("1 tool call")
                }
            }
            return switch self {
            case .read: MobileL10n.string("%lld file reads", count)
            case .edit: MobileL10n.string("%lld edits", count)
            case .search: MobileL10n.string("%lld searches", count)
            case .command: MobileL10n.string("%lld commands", count)
            case .browser: MobileL10n.string("%lld browser actions", count)
            case .other: MobileL10n.string("%lld tool calls", count)
            }
        }
    }

    enum Item: Hashable {
        case row(String)
        case group(String)
    }

    struct Group {
        let id: String
        var rowIDs: [String]
        var failureCount: Int
        var pendingCount: Int
        var activities: [Activity: Int] = [:]
        var pendingActivities: [Activity: Int] = [:]

        var summary: String {
            let labels = Activity.allCases.compactMap { activity -> String? in
                guard let count = activities[activity], count > 0 else { return nil }
                return activity.label(count: count)
            }
            return labels.isEmpty ? MobileL10n.string("%lld tool calls", rowIDs.count) : labels.joined(separator: " · ")
        }

        var runningSummary: String? {
            let labels = Activity.allCases.compactMap { activity -> String? in
                guard let count = pendingActivities[activity], count > 0 else { return nil }
                return activity.label(count: count)
            }
            if labels.isEmpty { return pendingCount > 0 ? MobileL10n.string("%lld running", pendingCount) : nil }
            return MobileL10n.string("Running: %@", labels.joined(separator: " · "))
        }

        fileprivate mutating func account(_ state: RowState, multiplier: Int = 1) {
            activities[state.activity, default: 0] += multiplier
            if state.pending { pendingActivities[state.activity, default: 0] += multiplier }
        }
    }

    fileprivate struct RowState {
        let kind: RemoteConversationRowKind
        let failed: Bool
        let pending: Bool
        let activity: Activity

        init(_ row: RemoteConversationRowDTO) {
            kind = row.kind
            failed = row.isError
            pending = row.result == nil && !row.isError
            activity = Activity(toolName: row.toolName)
        }
    }

    private(set) var roots: [Item] = []
    private(set) var groups: [String: Group] = [:]
    private(set) var expanded: Set<String> = []
    private var states: [String: RowState] = [:]
    private var groupByRow: [String: String] = [:]
    private var lastRowID: String?

    /// Cold open, a changed ordering, or an older page. Reuse a retained group's identity even
    /// when the newly loaded page extends its beginning; keep the reader's disclosure choice.
    mutating func rebuild(_ rows: [RemoteConversationRowDTO], openedRows: Set<String> = []) {
        let oldGroups = groupByRow
        let oldExpanded = expanded
        roots.removeAll(keepingCapacity: true)
        groups.removeAll(keepingCapacity: true)
        states.removeAll(keepingCapacity: true)
        groupByRow.removeAll(keepingCapacity: true)
        expanded.removeAll(keepingCapacity: true)
        lastRowID = rows.last?.id

        var index = rows.startIndex
        while index < rows.endIndex {
            let start = index
            let row = rows[index]
            states[row.id] = RowState(row)
            index += 1
            guard row.kind == .tool else {
                roots.append(.row(row.id))
                continue
            }
            while index < rows.endIndex, rows[index].kind == .tool {
                states[rows[index].id] = RowState(rows[index])
                index += 1
            }
            let members = rows[start..<index]
            guard members.count > 1 else {
                roots.append(.row(row.id))
                continue
            }
            var id = members.lazy.compactMap { oldGroups[$0.id] }
                .first(where: { groups[$0] == nil }) ?? row.id
            // A kind correction can split a formerly contiguous run around its old anchor.
            while groups[id] != nil { id += ".split" }
            var group = Group(id: id, rowIDs: [], failureCount: 0, pendingCount: 0)
            group.rowIDs.reserveCapacity(members.count)
            for member in members {
                group.rowIDs.append(member.id)
                group.failureCount += member.isError ? 1 : 0
                group.pendingCount += member.result == nil && !member.isError ? 1 : 0
                group.account(RowState(member))
                groupByRow[member.id] = id
                let wasExpanded = oldGroups[member.id].map(oldExpanded.contains)
                    ?? openedRows.contains(member.id)
                if wasExpanded {
                    expanded.insert(id)
                }
            }
            groups[id] = group
            roots.append(.group(id))
        }
    }

    /// Returns the changed group headers so the collection refreshes counts on existing cells.
    mutating func append(_ rows: [RemoteConversationRowDTO], openedRows: Set<String>) -> Set<String> {
        var changed: Set<String> = []
        for row in rows {
            let previous = lastRowID
            let state = RowState(row)
            states[row.id] = state
            lastRowID = row.id
            guard row.kind == .tool, let previous, let previousState = states[previous],
                  previousState.kind == .tool else {
                roots.append(.row(row.id))
                continue
            }
            if let id = groupByRow[previous] {
                groups[id]?.rowIDs.append(row.id)
                groups[id]?.failureCount += state.failed ? 1 : 0
                groups[id]?.pendingCount += state.pending ? 1 : 0
                groups[id]?.account(state)
                groupByRow[row.id] = id
                changed.insert(id)
            } else {
                let id = previous
                groups[id] = Group(
                    id: id, rowIDs: [previous, row.id],
                    failureCount: (previousState.failed ? 1 : 0) + (state.failed ? 1 : 0),
                    pendingCount: (previousState.pending ? 1 : 0) + (state.pending ? 1 : 0)
                )
                groups[id]?.account(previousState)
                groups[id]?.account(state)
                groupByRow[previous] = id
                groupByRow[row.id] = id
                roots[roots.count - 1] = .group(id)
                if openedRows.contains(previous) { expanded.insert(id) }
                changed.insert(id)
            }
        }
        return changed
    }

    func needsRebuild(for rows: [RemoteConversationRowDTO]) -> Bool {
        rows.contains { states[$0.id]?.kind != $0.kind }
    }

    mutating func update(_ rows: [RemoteConversationRowDTO]) -> Set<String> {
        var changed: Set<String> = []
        for row in rows {
            guard let previous = states[row.id] else { continue }
            let state = RowState(row)
            states[row.id] = state
            guard let id = groupByRow[row.id] else { continue }
            groups[id]?.failureCount += (state.failed ? 1 : 0) - (previous.failed ? 1 : 0)
            groups[id]?.pendingCount += (state.pending ? 1 : 0) - (previous.pending ? 1 : 0)
            groups[id]?.account(previous, multiplier: -1)
            groups[id]?.account(state)
            changed.insert(id)
        }
        return changed
    }

    mutating func toggle(_ id: String) {
        guard groups[id] != nil else { return }
        if !expanded.insert(id).inserted { expanded.remove(id) }
    }

    func visibleItems() -> [Item] {
        var items: [Item] = []
        items.reserveCapacity(roots.count)
        for item in roots {
            items.append(item)
            guard case .group(let id) = item, expanded.contains(id), let group = groups[id]
            else { continue }
            items.append(contentsOf: group.rowIDs.map(Item.row))
        }
        return items
    }

    func visibleItem(forRow id: String) -> Item {
        guard let group = groupByRow[id], !expanded.contains(group) else { return .row(id) }
        return .group(group)
    }
}
