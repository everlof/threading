import AppKit
import Foundation
import Dispatch
@testable import CoreSlice
@testable import TerminalRuntime
#if os(Linux)
import Glibc
import LinuxWindowBridge
#endif

// Diagnostic platform harness, not a second product sidebar. It reuses the existing specimen
// drawing and the production font while the native window/event transport is brought up.
struct ProjectSnapshot: Sendable {
    struct SavedRuntime: Sendable {
        let id: String
        let title: String
        var kind: AgentKind? = nil
        var account: String? = nil
        var attention: AgentSessionRowPresentation.Attention? = nil

        var snoozedUntil: Date? = nil

        func attention(at date: Date) -> AgentSessionRowPresentation.Attention? {
            AgentSessionRowPresentation.Attention.resolve(
                isScheduled: attention == .scheduled, hasWoken: attention == .woke,
                isSnoozed: snoozedUntil.map { date < $0 } ?? false)
        }

        func attentionTitle(at date: Date) -> String? {
            switch attention(at: date) {
            case .scheduled: return "Scheduled"
            case .woke: return "Woke"
            case .snoozed: return "Snoozed"
            case nil: return nil
            }
        }

        var identityTitle: String {
            let provider = kind.map { "[\($0.displayName)] " } ?? ""
            let suffix = account.map { " [\($0)]" } ?? ""
            return provider + title + suffix
        }
    }
    let id: String
    let name: String
    let path: String
    let isScratchpad: Bool
    var sessions: Int
    var terminalCount: Int
    var recentAgents: [SavedRuntime]
    var recentTerminals: [SavedRuntime]
}
struct WindowSnapshot: Sendable {
    let projects: [ProjectSnapshot]
    let selectedProjectIndex: Int
    let restoreAgentID: String?
    let restoreAgentActivity: Date?
    let restoreAgentProjectID: ProjectID?
    let restoreTerminalID: String?
}
struct WindowFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

@MainActor
private final class NavigatorMouseEvent: NSEvent {
    private let point: NSPoint
    init(locationInWindow point: NSPoint) {
        self.point = point
        super.init()
    }
    override var locationInWindow: NSPoint { point }
}

@MainActor
private final class NavigatorKeyEvent: NSEvent {
    private let code: UInt16
    init(keyCode: UInt16) {
        code = keyCode
        super.init()
    }
    nonisolated override var type: NSEvent.EventType { .keyDown }
    override var keyCode: UInt16 { code }
    override var charactersIgnoringModifiers: String? {
        String(UnicodeScalar(code == 126 ? 0xF700 : 0xF701)!)
    }
}

/// Stable outline identity survives a project reorder or a newly prepended saved runtime.
/// Position is carried only to avoid searching the catalogue while mounting visible cells.
private struct NavigatorOutlineItem: Hashable {
    enum Kind: Hashable { case project, agent, terminal }
    let kind: Kind
    let projectID: String
    let id: String
    let projectIndex: Int
    let childIndex: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.projectID == rhs.projectID && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(projectID)
        hasher.combine(id)
    }

    init(projectID: String, projectIndex: Int) {
        kind = .project
        self.projectID = projectID
        id = projectID
        self.projectIndex = projectIndex
        childIndex = -1
    }

    init(kind: Kind, projectID: String, id: String, projectIndex: Int, childIndex: Int) {
        self.kind = kind
        self.projectID = projectID
        self.id = id
        self.projectIndex = projectIndex
        self.childIndex = childIndex
    }

    init(_ row: SidebarVisibleRows.Row, projects: [ProjectSnapshot]) {
        switch row {
        case .project(let projectIndex, let id):
            self.init(projectID: id, projectIndex: projectIndex)
        case .agent(let projectIndex, let childIndex, let id):
            self.init(kind: .agent, projectID: projects[projectIndex].id, id: id,
                      projectIndex: projectIndex, childIndex: childIndex)
        case .terminal(let projectIndex, let childIndex, let id):
            self.init(kind: .terminal, projectID: projects[projectIndex].id, id: id,
                      projectIndex: projectIndex, childIndex: childIndex)
        }
    }

    func resolvedRow(in projects: [ProjectSnapshot], indexes: [String: Int])
        -> SidebarVisibleRows.Row? {
        guard let projectIndex = indexes[projectID], projects.indices.contains(projectIndex),
              projects[projectIndex].id == projectID else { return nil }
        let project = projects[projectIndex]
        switch kind {
        case .project: return .project(projectIndex: projectIndex, id: projectID)
        case .agent:
            let children = project.recentAgents.prefix(SidebarVisibleRows.maximumChildrenPerKind)
            let current = children.indices.contains(childIndex) && children[childIndex].id == id
                ? childIndex : children.firstIndex(where: { $0.id == id })
            guard let childIndex = current else { return nil }
            return .agent(projectIndex: projectIndex, childIndex: childIndex, id: id)
        case .terminal:
            let children = project.recentTerminals.prefix(SidebarVisibleRows.maximumChildrenPerKind)
            let current = children.indices.contains(childIndex) && children[childIndex].id == id
                ? childIndex : children.firstIndex(where: { $0.id == id })
            guard let childIndex = current else { return nil }
            return .terminal(projectIndex: projectIndex, childIndex: childIndex, id: id)
        }
    }
}

@MainActor
private final class NavigatorOutlineSource: NSOutlineViewDataSource, NSOutlineViewDelegate {
    var projects: [ProjectSnapshot] = []
    var projectIndexes: [String: Int] = [:]
    var makeRow: ((NSOutlineView, NavigatorOutlineItem) -> NSView?)?
    var makeChrome: ((NSOutlineView, NavigatorOutlineItem) -> NSTableRowView?)?

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return projects.count }
        guard let item = item as? NavigatorOutlineItem, item.kind == .project,
              let index = projectIndexes[item.projectID], projects.indices.contains(index)
        else { return 0 }
        let project = projects[index]
        return min(project.recentAgents.count, SidebarVisibleRows.maximumChildrenPerKind)
            + min(project.recentTerminals.count, SidebarVisibleRows.maximumChildrenPerKind)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else {
            return NavigatorOutlineItem(projectID: projects[index].id, projectIndex: index)
        }
        let parent = item as! NavigatorOutlineItem
        let projectIndex = projectIndexes[parent.projectID]!
        let project = projects[projectIndex]
        let agentCount = min(project.recentAgents.count, SidebarVisibleRows.maximumChildrenPerKind)
        if index < agentCount {
            return NavigatorOutlineItem(kind: .agent, projectID: parent.projectID,
                id: project.recentAgents[index].id, projectIndex: projectIndex, childIndex: index)
        }
        let childIndex = index - agentCount
        return NavigatorOutlineItem(kind: .terminal, projectID: parent.projectID,
            id: project.recentTerminals[childIndex].id,
            projectIndex: projectIndex, childIndex: childIndex)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? NavigatorOutlineItem, item.kind == .project,
              let index = projectIndexes[item.projectID], projects.indices.contains(index)
        else { return false }
        let project = projects[index]
        return !project.recentAgents.isEmpty || !project.recentTerminals.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? NavigatorOutlineItem else { return nil }
        return makeRow?(outlineView, item)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any)
        -> NSTableRowView? {
        guard let item = item as? NavigatorOutlineItem else { return nil }
        return makeChrome?(outlineView, item)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? NavigatorOutlineItem else { return SidebarDefaults.rowHeight }
        return item.kind == .project
            ? SidebarDefaults.projectCompactRowHeight : SidebarDefaults.rowHeight
    }
}

@MainActor
func render(_ root: NSView, scale: CGFloat = 2, background: NSColor, to path: String) throws {
    let bitmap = Bitmap(width: Int(root.frame.width * scale), height: Int(root.frame.height * scale),
                        background: background.components)
    let context = NSGraphicsContext(bitmap: bitmap, scale: scale)
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.current = nil }
    root.render(in: context)
    try PNGWriter.write(bitmap, to: URL(fileURLWithPath: path))
}

@main
struct WindowHarness {
    @MainActor private static let terminalMark: NSImage = {
        guard let image = Design.Symbol.image("terminal", slot: SidebarRowDefaults.iconSlotWidth,
                                              pointSize: SidebarRowDefaults.iconSize,
                                              weight: .regular)
        else { preconditionFailure("terminal identity glyph is unavailable") }
        return image
    }()

    private static let maximumOpenRuntimes = 8
    private static let maximumSelectableAgentsPerProject = 512
    private static let maximumSelectableTerminalsPerProject = 512
    private static let maximumPersistedRuntimeTitleScalars = 256
    private static let navigatorRowHeight: CGFloat = 22
    private static let navigatorRowStride: CGFloat = 24
    @MainActor private static var navigatorHeaderHeight: CGFloat { PaneHeaderView.bandHeight }
    @MainActor private static var navigatorRowsTop: Int32 { Int32((navigatorHeaderHeight + 2) * 2) }
    #if os(Linux)
    static let terminalCellWidth = Int(TW_TERMINAL_CELL_WIDTH)
    static let terminalCellHeight = Int(TW_TERMINAL_CELL_HEIGHT)
    #endif

    @MainActor private static func navigatorRowRect(_ index: Int, width: Int, height: Int,
                                                    indent: CGFloat = 0) -> NSRect {
        let top = navigatorHeaderHeight + 2 + CGFloat(index) * navigatorRowStride
        // The diagnostic root uses integer half-size bounds, even for an odd SDL pixel size.
        return NSRect(x: 6 + indent, y: CGFloat(height / 2) - top - navigatorRowHeight,
                      width: CGFloat(width / 2) - 12 - indent, height: navigatorRowHeight)
    }
    @MainActor private static func navigatorRowPixels(_ index: Int, width: Int, height: Int,
                                                      indent: CGFloat = 0)
        -> (x: Int32, y: Int32, width: Int32, height: Int32) {
        let row = navigatorRowRect(index, width: width, height: height, indent: indent)
        return (Int32(row.minX * 2), Int32((CGFloat(height / 2) - row.maxY) * 2),
                Int32(row.width * 2), Int32(row.height * 2))
    }

    @MainActor private static func menuRowPixels(_ slot: Int, in root: Specimen.Window,
                                                   scale: CGFloat)
        -> (x: Int32, y: Int32, width: Int32, height: Int32)? {
        guard let view = root.mountedMenuRow(at: slot) else { return nil }
        let row = view.convert(view.bounds, to: root)
        return (Int32(row.minX * scale), Int32((root.bounds.height - row.maxY) * scale),
                Int32(row.width * scale), Int32(row.height * scale))
    }

    private struct NavigatorTextRow {
        let text: String
        let x: Int32
        let y: Int32
        let width: Int32
        let height: Int32
        let inset: Int32
        let ink: NSColor
        var trailingInset: Int32 = 12
        var isDetail = false
        var isEmphasized = false
        var isCount = false
    }

    private static func readableNavigatorText(_ text: String) -> String {
        text.unicodeScalars.prefix(256).map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) ||
                scalar.properties.generalCategory == .format { return "�" }
            return String(scalar)
        }.joined()
    }

    @MainActor private static func addNavigatorRow(
        _ text: String, index: Int, width: Int, height: Int,
        accent: NSColor, selected: Bool, selectedInk: Specimen.Ink, root: Specimen.Window,
        textRows: inout [NavigatorTextRow], image: NSImage? = nil,
        projectPresentation: NavigatorProjectRowPresentation? = nil,
        imageSide: CGFloat = 13, trailingCount: Int = 0, indent: CGFloat = 0,
        projectActionID: String? = nil, revealsProjectAction: Bool = false,
        projectActionEnabled: Bool = true
    ) {
        let frame = navigatorRowRect(index, width: width, height: height, indent: indent)
        let ink = selected ? selectedInk : root.bodyInk
        root.mountNavigatorRow(frame: frame, accent: accent, selected: selected,
                               ink: ink, image: image,
                               showsMark: projectPresentation?.showsIdentityMark ?? true,
                               imageSide: imageSide,
                               projectActionID: projectActionID,
                               revealsProjectAction: revealsProjectAction,
                               projectActionEnabled: projectActionEnabled)
        let pixels = navigatorRowPixels(index, width: width, height: height, indent: indent)
        let role = projectPresentation?.titleRole
        // Bound the optional count slot to the mounted row and leave a gap for the title.
        let countText = trailingCount > 0 && !revealsProjectAction ? String(trailingCount) : ""
        let trailingInset: CGFloat = 6
        let minimumTitleWidth: CGFloat = 32
        let countWidth = countText.isEmpty ? 0 : min(max(20, CGFloat(countText.count) * 6),
                                                     max(0, frame.width - Specimen.navigatorRowGeometry.titleLeadingOffset
                                                         - trailingInset - Specimen.navigatorRowGeometry.contentGap
                                                         - minimumTitleWidth))
        let titleTrailing = max(projectActionID == nil ? trailingInset :
            (revealsProjectAction ? 48 : 26),
            trailingInset + (countText.isEmpty ? 0 : countWidth + Specimen.navigatorRowGeometry.contentGap))
        let titleRect = Specimen.navigatorRowGeometry.titleRect(in: frame, trailingInset: titleTrailing)
        let titleTrailingPixels = pixels.x + pixels.width - Int32(titleRect.maxX * 2)
        textRows.append(NavigatorTextRow(text: readableNavigatorText(text), x: pixels.x, y: pixels.y,
                                         width: pixels.width, height: pixels.height,
                                         inset: Int32(Specimen.navigatorRowGeometry.titleLeadingOffset * 2),
                                         ink: ink.label,
                                         trailingInset: titleTrailingPixels,
                                         isDetail: role == .caption,
                                         isEmphasized: role != nil))
        if !countText.isEmpty, countWidth > 0 {
            textRows.append(NavigatorTextRow(text: countText,
                x: Int32((frame.maxX - trailingInset - countWidth) * 2), y: pixels.y,
                width: Int32(countWidth * 2), height: pixels.height,
                inset: 0, ink: selected ? selectedInk.secondary : root.bodyInk.secondary,
                trailingInset: 0, isCount: true))
        }
    }

    /// The production session content draws the title and provider mark in a bounded row slot.
    /// The host keeps identity, retained/attention status and its complete accessible label.
    @MainActor private static func addSavedAgentRow(
        _ runtime: ProjectSnapshot.SavedRuntime, retained: Bool, at date: Date,
        index: Int, width: Int, height: Int, accent: NSColor, selected: Bool,
        selectedInk: Specimen.Ink, root: Specimen.Window, textRows: inout [NavigatorTextRow], image: NSImage?,
        indent: CGFloat = 0
    ) {
        let frame = navigatorRowRect(index, width: width, height: height, indent: indent)
        let ink = selected ? selectedInk : root.bodyInk
        root.mountNavigatorRow(frame: frame, accent: accent,
                               selected: selected, ink: ink, showsMark: image == nil)
        let pixels = navigatorRowPixels(index, width: width, height: height, indent: indent)
        let status = runtime.attentionTitle(at: date) ?? (retained ? "Retained" : nil)
        let regions = SavedAgentRowLayout(
            row: CGRect(x: Int(pixels.x), y: Int(pixels.y),
                        width: Int(pixels.width), height: Int(pixels.height)),
            showsStatus: status != nil,
            titleLeadingInset: Specimen.navigatorRowGeometry.titleLeadingOffset * 2
        )
        let contentTrailingInset = CGFloat(pixels.x + pixels.width - Int32(regions.title.maxX)) / 2
        root.mountSessionContent(title: readableNavigatorText(runtime.title), icon: image,
                                 selected: selected, trailingInset: contentTrailingInset)
        if let status, regions.status.width > 0 {
            textRows.append(NavigatorTextRow(text: readableNavigatorText(status),
                x: Int32(regions.status.minX), y: Int32(regions.status.minY),
                width: Int32(regions.status.width), height: Int32(regions.status.height),
                inset: 0, ink: ink.secondary, trailingInset: 0, isDetail: true))
        }
    }

    /// A visible saved shell uses the Mac terminal row's icon and title composition. The
    /// host retains exact runtime identity, selection, activation and accessibility labels.
    @MainActor private static func addSavedTerminalRow(
        _ runtime: ProjectSnapshot.SavedRuntime, running: Bool, index: Int,
        width: Int, height: Int, accent: NSColor, selected: Bool,
        selectedInk: Specimen.Ink, root: Specimen.Window, indent: CGFloat = 0
    ) {
        let frame = navigatorRowRect(index, width: width, height: height, indent: indent)
        let ink = selected ? selectedInk : root.bodyInk
        root.mountNavigatorRow(frame: frame, accent: accent, selected: selected,
                               ink: ink, showsMark: false)
        root.mountTerminalContent(title: readableNavigatorText(runtime.title), icon: terminalMark,
                                  selected: selected, running: running)
    }

    /// Mount only the shaped text in the current viewport. Selection and commands still belong
    /// to the native host, while the AppKit shim now owns the same label leaf as other UI views.
    @MainActor private static func mountNavigatorText(_ rows: [NavigatorTextRow],
                                                      in root: Specimen.Window) throws {
        guard rows.count <= Int(TW_NAVIGATOR_MAX_LABELS) else {
            throw WindowFailure("navigator text exceeds mounted-row fragment budget")
        }
        var byteCount = 0
        for (index, row) in rows.enumerated() {
            let encodedCount = row.text.utf8.count
            guard encodedCount <= 1024, byteCount <= 32768 - encodedCount else {
                throw WindowFailure("navigator label exceeds text budget")
            }
            byteCount += encodedCount
            let contentWidth = row.width - row.inset - row.trailingInset
            guard row.x >= 0, row.y >= 0, row.width > 0, row.height > 0,
                  row.x + row.width <= Int32(root.bounds.width * 2),
                  row.y + row.height <= Int32(root.bounds.height * 2),
                  row.inset >= 0, row.trailingInset >= 0, contentWidth > 0 else {
                throw WindowFailure("navigator label escaped its mounted rectangle")
            }
            let label = root.navigatorLabel(at: index)
            if label.stringValue != row.text { label.stringValue = row.text }
            let frame = NSRect(x: CGFloat(row.x + row.inset) / 2,
                               y: root.bounds.height - CGFloat(row.y + row.height) / 2,
                               width: CGFloat(contentWidth) / 2,
                               height: CGFloat(row.height) / 2)
            if label.frame != frame { label.frame = frame }
            let size: CGFloat = row.isCount ? 8 : row.isDetail ? 7 : 9
            let weight: NSFont.Weight = row.isEmphasized ? .semibold : .regular
            let family = row.isCount ? "System-Mono" : row.isEmphasized ? "System-Semibold" : "System"
            if label.font?.pointSize != size || label.font?.weight != weight ||
                label.font?.familyName != family {
                label.font = row.isCount ? NSFont.monospacedSystemFont(ofSize: size)
                    : NSFont.systemFont(ofSize: size, weight: weight)
            }
            let alignment: NSTextAlignment = row.isCount ? .right : .left
            if label.alignment != alignment { label.alignment = alignment }
            if label.textColor != row.ink { label.textColor = row.ink }
            if label.isHidden { label.isHidden = false }
        }
        root.finishNavigatorRows()
        root.finishNavigatorLabels(visibleCount: rows.count)
    }

    private enum SavedPicker {
        case agents(Int)
        case terminals(Int)

        var projectIndex: Int {
            switch self { case .agents(let index), .terminals(let index): return index }
        }
        var isAgent: Bool {
            if case .agents = self { return true }
            return false
        }
    }

    private enum SavedRuntimeKey: Hashable {
        case agent(String)
        case terminal(String)
    }
    private enum RuntimeOwner {
        case project(String)
        case saved(SavedRuntimeKey)
    }

    private static func savedAgent(_ session: AgentSession) -> ProjectSnapshot.SavedRuntime {
        var saved = savedAgent(agentRow(session))
        // Retain durable facts, not a clock-derived state which can expire while the picker
        // stays open. Invalid/archived snooze records follow AgentSession.isSnoozed semantics.
        if !session.isArchived, let start = session.snoozedAt,
           let end = session.snoozedUntil, start < end {
            saved.snoozedUntil = end
        }
        return saved
    }

    private static func agentRow(_ session: AgentSession) -> AgentSessionRowPresentation {
        // The preview has no title preference yet; follow agent titles, as the Mac default does.
        AgentSessionRowPresentation(session: session, usesAgentTitle: true,
            untitledTitle: AgentDefaults.untitledSessionName,
            attention: AgentSessionRowPresentation.Attention.resolve(
                // The preview has no scheduler. Snooze is resolved from the snapshot deadline at paint.
                isScheduled: false, hasWoken: session.wake != nil,
                isSnoozed: false
            ))
    }

    private static func savedAgent(_ row: AgentSessionRowPresentation) -> ProjectSnapshot.SavedRuntime {
        .init(id: row.id.uuidString,
              title: String(row.title.unicodeScalars.prefix(maximumPersistedRuntimeTitleScalars)),
              kind: row.kind,
              account: row.accountHandle.isStandard ? nil : String(row.accountHandle.name.unicodeScalars.prefix(64)),
              attention: row.attention)
    }

    @MainActor static func main() async {
        do {
            try await run()
        } catch {
            #if os(Linux)
            await GraphicalTerminal.waitForPendingStops()
            #endif
            FileHandle.standardError.write(Data("WindowHarness: \(error)\n".utf8))
            exit(1)
        }
        #if os(Linux)
        await GraphicalTerminal.waitForPendingStops()
        #endif
    }

    @MainActor private static func run() async throws {
        #if os(Linux)
        let decodedMarks = await Task.detached(priority: .utility) { ProviderMarks.decode() }.value
        ProviderMarks.install(decodedMarks)
        let mode = CommandLine.arguments.dropFirst().first
        if mode == "--project-row-layout-fixture" {
            ProjectRowLayoutFixture.run()
            return
        }
        if mode == "--session-row-layout-fixture" {
            SessionRowLayoutFixture.run()
            return
        }
        if mode == "--terminal-row-layout-fixture" {
            TerminalRowLayoutFixture.run()
            return
        }
        if mode == "--attach" {
            let args = Array(CommandLine.arguments.dropFirst(2))
            guard args.count == 3 else { throw WindowFailure("usage: WindowHarness --attach STORE SOCKET TERMINAL_UUID") }
            try showAttachment(args)
            return
        }
        if mode == "--attach-agent" {
            let args = Array(CommandLine.arguments.dropFirst(2))
            guard args.count == 3 else { throw WindowFailure("usage: WindowHarness --attach-agent STORE SOCKET SESSION_UUID") }
            try showAttachment(args, agent: true)
            return
        }
        if mode == "--terminal" {
            try showTerminal(Array(CommandLine.arguments.dropFirst(2)))
            return
        }
        if mode == "--app" || mode == "--app-project" {
            let args = Array(CommandLine.arguments.dropFirst(2))
            let targeted = mode == "--app-project"
            guard (targeted ? args.count == 4 : args.count >= 3), args[2].hasPrefix("/") else {
                throw WindowFailure("usage: WindowHarness --app EXISTING_STORE SOCKET ABS_SHELL [ARG ...] | --app-project EXISTING_STORE SOCKET ABS_SHELL PROJECT")
            }
            let requestedProject = targeted ? args[3] : nil
            let snapshot = try await Task.detached {
                try loadSnapshot(args[0], selectingProjectAt: requestedProject, socket: args[1])
            }.value
            try show(snapshot, launch: targeted ? Array(args.prefix(3)) : args)
            return
        }
        if mode == "--app-codex" || mode == "--app-codex-project"
            || mode == "--app-claude" || mode == "--app-claude-project"
            || mode == "--app-agents" || mode == "--app-agents-project" {
            let args = Array(CommandLine.arguments.dropFirst(2))
            let targeted = mode!.hasSuffix("-project")
            let combined = mode!.hasPrefix("--app-agents")
            guard args.count == (combined ? (targeted ? 6 : 5) : (targeted ? 5 : 4)),
                  args[2].hasPrefix("/") else {
                throw WindowFailure("usage: WindowHarness --app-{codex|claude} STORE SOCKET ABS_SHELL ABS_AGENT [PROJECT] | --app-agents STORE SOCKET ABS_SHELL CODEX_OR_- CLAUDE_OR_- [PROJECT]")
            }
            let codex = combined ? (args[3] == "-" ? nil : args[3])
                : (mode!.hasPrefix("--app-codex") ? args[3] : nil)
            let claude = combined ? (args[4] == "-" ? nil : args[4])
                : (mode!.hasPrefix("--app-claude") ? args[3] : nil)
            guard (codex != nil || claude != nil),
                  codex.map({ $0.hasPrefix("/") }) ?? true,
                  claude.map({ $0.hasPrefix("/") }) ?? true else {
                throw WindowFailure("configured agent executables must be absolute paths")
            }
            let requestedProject = targeted ? args.last : nil
            let prepared = try await Task.detached {
                (try loadSnapshot(args[0], selectingProjectAt: requestedProject, socket: args[1]),
                 codex == nil ? [.standard] : discoverAccounts(for: .codex),
                 claude == nil ? [.standard] : discoverAccounts(for: .claude))
            }.value
            try show(prepared.0, launch: Array(args.prefix(3)), agentExecutable: codex,
                     claudeExecutable: claude, codexAccounts: prepared.1,
                     claudeAccounts: prepared.2)
            return
        }
        guard CommandLine.arguments.count == 2 else { throw WindowFailure("usage: WindowHarness EXISTING_STORE") }
        let path = CommandLine.arguments[1]
        // Database open, recovery and graph decoding never run on the UI actor. Only immutable
        // values cross back. The snapshot is deliberately fixed for this window's lifetime.
        let snapshot = try await Task.detached { try loadSnapshot(path) }.value
        try show(snapshot)
        #else
        throw WindowFailure("WindowHarness requires Linux")
        #endif
    }

    #if os(Linux)
    /// Inspect the home once on a worker. The picker and input loop only touch this bounded
    /// value, and the shared resolver still validates the selected home at launch time.
    private static func discoverAccounts(for kind: AgentKind) -> [AccountHandle] {
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") else {
            return [.standard]
        }
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        guard let directory = Glibc.opendir(home) else { return [.standard] }
        defer { Glibc.closedir(directory) }
        let prefix = kind == .codex ? AgentAccountDefaults.codexDirectoryPrefix
            : AgentAccountDefaults.claudeDirectoryPrefix
        var names: [String] = []
        while let entry = Glibc.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            guard name.hasPrefix(prefix), name.utf8.count <= 129 else { continue }
            // Unverified directories must not consume the bound and hide a real login.
            let handle = AccountHandle.named(String(name.dropFirst()))
            let admitted = kind == .codex
                ? CodexAccountLocations.resolve(handle, home: homeURL) != nil
                : ClaudeAccountLocations.resolve(handle, home: homeURL) != nil
            guard admitted else { continue }
            // Keep 31 lexical accounts plus standard without building an unbounded home listing.
            names.append(name)
            names.sort()
            if names.count > 31 { names.removeLast() }
        }
        let candidates = names.map { homeURL.appendingPathComponent($0, isDirectory: true) }
        let found = kind == .codex
            ? CodexAccountLocations.discover(home: homeURL, candidates: candidates,
                                             verified: []).map(\.handle)
            : ClaudeAccountLocations.discover(home: homeURL, candidates: candidates,
                                              verified: []).map(\.handle)
        return [.standard] + found.filter { !$0.isStandard }
            .sorted { $0.name < $1.name }
    }

    /// SDL owns its renderer on the thread that opened it. Do not suspend the window loop across
    /// a store write: Swift's Linux main-actor executor can resume it on another native thread.
    /// The worker publishes one result, and the native loop polls only while that write is live.
    private final class SelectionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?

        func finish(_ value: Result<Void, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<Void, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    /// GIO may read the desktop registry; publish one immutable result back to SDL's owner.
    private final class OpenInCatalogueGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: LinuxExternalApps.Catalogue?

        func finish(_ catalogue: LinuxExternalApps.Catalogue) {
            lock.lock(); result = catalogue; lock.unlock()
        }

        func take() -> LinuxExternalApps.Catalogue? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    /// One selected desktop icon is decoded off SDL's thread. A completed miss is distinct
    /// from work still in flight, so an unavailable icon does not queue itself every frame.
    private final class OpenInIconGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: LinuxExternalApps.IconPixels??

        func finish(_ pixels: LinuxExternalApps.IconPixels?) {
            lock.lock(); result = .some(pixels); lock.unlock()
        }

        func take() -> LinuxExternalApps.IconPixels?? {
            lock.lock(); defer { lock.unlock() }
            let ready = result
            result = nil
            return ready
        }
    }

    /// SDL's owner keeps the small image cache and in-flight request together. The worker sees
    /// only a Sendable desktop entry and its result gate, never captured window-loop locals.
    @MainActor private final class OpenInIconState {
        private struct Pending {
            let id: String
            let hint: String
            let gate: OpenInIconGate
        }

        private struct Cached {
            let hint: String
            let image: NSImage?
        }

        private var pending: Pending?
        private var cache: [String: Cached] = [:]
        private var order: [String] = []

        var isLoading: Bool { pending != nil }

        func selectedImage(for app: LinuxExternalApp) -> NSImage? {
            guard let hint = app.iconHint else { return nil }
            if let cached = cache[app.id], cached.hint == hint { return cached.image }
            guard pending == nil else { return nil }
            let gate = OpenInIconGate()
            pending = Pending(id: app.id, hint: hint, gate: gate)
            DispatchQueue.global(qos: .utility).async {
                gate.finish(LinuxExternalApps.icon(for: app))
            }
            return nil
        }

        func retainAvailable(_ catalogue: LinuxExternalApps.Catalogue) {
            cache = cache.filter { id, cached in
                cached.image != nil && catalogue.apps.contains {
                    $0.id == id && $0.iconHint == cached.hint
                }
            }
            order.removeAll { cache[$0] == nil }
        }

        /// Nil means the worker has not finished. A completed missing icon is cached as a miss,
        /// so a failing desktop entry cannot launch another decode on every render poll.
        func takeCompleted() -> Bool {
            guard let pending, let pixels = pending.gate.take() else { return false }
            self.pending = nil
            let image = pixels.flatMap { decoded -> NSImage? in
                guard let image = NSImage(rgba: decoded.rgba, width: decoded.width,
                                          height: decoded.height) else { return nil }
                image.isTemplate = decoded.isTemplate
                return image
            }
            cache[pending.id] = Cached(hint: pending.hint, image: image)
            order.removeAll { $0 == pending.id }
            order.append(pending.id)
            if order.count > 4 { cache.removeValue(forKey: order.removeFirst()) }
            return true
        }
    }

    /// The GTK dialog and store import run away from SDL's owning thread. Only one bounded
    /// snapshot crosses back to the navigator; closing the window closes a pending dialog.
    private final class FolderImportGate: @unchecked Sendable {
        private let lock = NSLock()
        private var chooser: Process?
        private var cancelled = false
        private var result: Result<WindowSnapshot?, Error>?

        func opened(_ process: Process) {
            lock.lock()
            chooser = process
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel && process.isRunning { process.terminate() }
        }
        func closed() {
            lock.lock(); chooser = nil; lock.unlock()
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let process = chooser
            lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }
        func isCancelled() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func finish(_ value: Result<WindowSnapshot?, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<WindowSnapshot?, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private enum ProjectFolderChoice { case existing, new, scratchpad }

    private static func beginFolderImport(store: String, socket: String,
                                          choice: ProjectFolderChoice = .existing) -> FolderImportGate {
        let gate = FolderImportGate()
        DispatchQueue.global(qos: .userInitiated).async {
            gate.finish(Result { try importFolder(store: store, socket: socket,
                                                  choice: choice, gate: gate) })
        }
        return gate
    }

    private static func importFolder(store: String, socket: String, choice: ProjectFolderChoice,
                                     gate: FolderImportGate) throws -> WindowSnapshot? {
        var bytes = Data()
        var tooLong = false
        if choice != .scratchpad {
            let chooser = Process()
            chooser.executableURL = URL(fileURLWithPath: "/usr/bin/zenity")
            chooser.arguments = choice == .new
                ? ["--file-selection", "--save", "--filename=New Project",
                   "--title=New Project"]
                : ["--file-selection", "--directory", "--title=Add project folder"]
            let output = Pipe()
            // A launcher may be reading commands from stdin (including bash -s smoke runs).
            // Neither child may consume those commands while the window remains open.
            chooser.standardInput = FileHandle.nullDevice
            chooser.standardOutput = output
            chooser.standardError = FileHandle.nullDevice
            try chooser.run()
            gate.opened(chooser)
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if bytes.count + chunk.count > 4096 { tooLong = true }
                else if !tooLong { bytes.append(chunk) }
            }
            chooser.waitUntilExit()
            gate.closed()
            if gate.isCancelled() || chooser.terminationStatus == 1 { return nil }
            guard chooser.terminationStatus == 0 else { throw WindowFailure("folder picker failed") }
            guard !tooLong, bytes.last == 10 else { throw WindowFailure("folder picker returned an invalid path") }
            bytes.removeLast()
        }
        let folder: URL?
        if choice == .scratchpad { folder = nil }
        else {
            guard let path = String(data: bytes, encoding: .utf8), path.hasPrefix("/"),
                  path.utf8.count <= 4096, path != "/" else {
                throw WindowFailure("folder picker returned an invalid path")
            }
            guard !gate.isCancelled() else { return nil }
            if choice == .new {
                let destination = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: destination,
                                                        withIntermediateDirectories: true)
            }
            guard let existing = ProjectDirectory.existing(at: path) else {
                throw WindowFailure("selected project directory does not exist")
            }
            folder = existing
        }
        guard !gate.isCancelled() else { return nil }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("LinuxHost"),
            FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WindowFailure("LinuxHost executable is unavailable")
        }
        let host = Process()
        host.executableURL = executable
        host.arguments = choice == .scratchpad ? ["--ensure-scratchpad", store]
            : ["--add-project", store, folder!.path]
        let hostOutput = Pipe()
        host.standardInput = FileHandle.nullDevice
        host.standardOutput = hostOutput
        host.standardError = hostOutput
        try host.run()
        var hostBytes = Data()
        var hostTooLong = false
        while true {
            let chunk = hostOutput.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if hostBytes.count + chunk.count > 4096 { hostTooLong = true }
            else if !hostTooLong { hostBytes.append(chunk) }
        }
        host.waitUntilExit()
        guard host.terminationStatus == 0 else {
            let detail = String(data: hostBytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "project host failed"
            throw WindowFailure(hostTooLong ? "project host refusal exceeded its bound" : detail)
        }
        guard !hostTooLong, hostBytes.last == 10 else {
            throw WindowFailure("project host returned an invalid path")
        }
        hostBytes.removeLast()
        guard let hostPath = String(data: hostBytes, encoding: .utf8),
              hostPath.hasPrefix("/"), ProjectDirectory.existing(at: hostPath) != nil,
              choice == .scratchpad || hostPath == folder!.path else {
            throw WindowFailure("project host returned a mismatched path")
        }
        return try loadSnapshot(store, selectingProjectAt: hostPath, socket: socket)
    }

    private struct PendingSelection {
        let event: TWEvent
        let continuesOnRefusal: Bool
        let gate: SelectionGate
    }

    private static func recordSelection(_ agentID: String?, terminalID: String? = nil,
                                        terminalProjectID: String? = nil, store: String,
                                        after event: TWEvent,
                                        continuesOnRefusal: Bool = false) -> PendingSelection {
        let gate = SelectionGate()
        DispatchQueue.global(qos: .userInitiated).async {
            gate.finish(Result {
                try GraphicalTerminal.selectRuntime(store: store, agentID: agentID,
                                                    terminalID: terminalID,
                                                    terminalProjectID: terminalProjectID)
            })
        }
        return PendingSelection(event: event, continuesOnRefusal: continuesOnRefusal, gate: gate)
    }

    static func loadSnapshot(_ path: String, selectingProjectAt requestedPath: String? = nil,
                             socket: String? = nil) throws -> WindowSnapshot {
        let snapshot = try loadStoredSnapshot(path, selectingProjectAt: requestedPath)
        if let socket, let idText = snapshot.restoreTerminalID,
           let uuid = UUID(uuidString: idText) {
            switch GraphicalTerminal.terminalPresence(socket: socket, id: TerminalID(uuid)) {
            case .running, .unavailable: break
            case .absent, .exited:
                return WindowSnapshot(projects: snapshot.projects,
                    selectedProjectIndex: snapshot.selectedProjectIndex,
                    restoreAgentID: nil, restoreAgentActivity: nil,
                    restoreAgentProjectID: nil, restoreTerminalID: nil)
            }
        }
        guard let socket, let idText = snapshot.restoreAgentID,
              let uuid = UUID(uuidString: idText) else { return snapshot }
        switch GraphicalTerminal.agentPresence(socket: socket, id: SessionID(uuid)) {
        case .running, .unavailable: return snapshot
        case .absent: break
        case .exited(let status):
            do {
                try GraphicalTerminal.recordAgentExit(store: path, id: SessionID(uuid),
                    status: status, observedNow: false,
                    expectedActivity: snapshot.restoreAgentActivity,
                    expectedProject: snapshot.restoreAgentProjectID)
            } catch {
                FileHandle.standardError.write(Data("Agent exit reconciliation: \(error)\n".utf8))
            }
        }
        // No daemon-held live child means startup must not open an unavailable terminal. A
        // missing summary gives no exit status; explicit selection remains the resume route.
        return WindowSnapshot(projects: snapshot.projects,
            selectedProjectIndex: snapshot.selectedProjectIndex, restoreAgentID: nil,
            restoreAgentActivity: nil, restoreAgentProjectID: nil,
            restoreTerminalID: snapshot.restoreTerminalID)
    }

    private static func loadStoredSnapshot(_ path: String,
                                           selectingProjectAt requestedPath: String?) throws -> WindowSnapshot {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let file = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: file.path) else { throw WindowFailure("store does not exist") }
        let lock = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("store is already owned by another host") }
        let database = try ProjectDatabase(url: file)
        defer { database.close() }
        let catalog = try database.navigationSnapshot(
            recentSessionLimit: maximumSelectableAgentsPerProject,
            recentTerminalLimit: maximumSelectableTerminalsPerProject
        )
        // A normal relaunch follows the saved runtime to its owning project. Reuse a session in
        // the bounded navigator snapshot; one indexed read covers a selection older than that
        // window. Standalone terminals are already decoded with their owning project payload.
        // An explicit project argument remains authoritative.
        var selectedAgent: (projectID: ProjectID, session: AgentSession)?
        if let selectedID = catalog.selectedSessionID {
            for project in catalog.projects {
                if let session = project.recentSessions.first(where: { $0.id == selectedID }) {
                    selectedAgent = (project.id, session)
                    break
                }
            }
            if selectedAgent == nil, let record = try database.sessionRecord(id: selectedID) {
                selectedAgent = (record.project.id, record.session)
            }
        }
        let selectedIndex: Int
        if let requestedPath {
            guard let folder = ProjectDirectory.existing(at: requestedPath),
                  let index = catalog.projects.firstIndex(where: { $0.folderPath == folder.path }) else {
                throw WindowFailure("requested project is not in this store")
            }
            selectedIndex = index
        } else {
            selectedIndex = selectedAgent.flatMap { agent in
                catalog.projects.firstIndex(where: { $0.id == agent.projectID })
            } ?? catalog.selectedTerminal.flatMap { terminal in
                catalog.projects.firstIndex(where: { $0.id == terminal.projectID })
            } ?? 0
        }
        var projects = catalog.projects.map { project in
            let agents = project.recentSessions.map(savedAgent)
            let terminals = project.recentTerminals.map {
                ProjectSnapshot.SavedRuntime(id: String(describing: $0.id),
                    title: String($0.displayTitle.unicodeScalars.prefix(maximumPersistedRuntimeTitleScalars)))
            }
            return ProjectSnapshot(id: String(describing: project.id), name: project.name,
                path: project.folderPath, isScratchpad: project.isScratchpad,
                sessions: project.sessionCount,
                terminalCount: project.terminalCount, recentAgents: agents, recentTerminals: terminals)
        }
        // Restore only a selected live runtime in the chosen project. An older selected row
        // joins its bounded picker without increasing the mounted-row ceiling.
        let restoreAgentID: String?
        let restoreAgentActivity: Date?
        let restoreAgentProjectID: ProjectID?
        let restoreTerminalID: String?
        if let selectedAgent,
           catalog.projects.indices.contains(selectedIndex),
           selectedAgent.projectID == catalog.projects[selectedIndex].id {
            let selected = selectedAgent.session
            if selected.hasLaunched, !selected.isArchived,
               selected.lastExitCode == nil {
                if !projects[selectedIndex].recentAgents.contains(where: {
                    $0.id == selected.id.uuidString
                }) {
                    projects[selectedIndex].recentAgents.insert(savedAgent(selected), at: 0)
                    if projects[selectedIndex].recentAgents.count > maximumSelectableAgentsPerProject {
                        projects[selectedIndex].recentAgents.removeLast()
                    }
                }
                restoreAgentID = selected.id.uuidString
                restoreAgentActivity = selected.lastActiveAt
                restoreAgentProjectID = catalog.projects[selectedIndex].id
            } else {
                restoreAgentID = nil
                restoreAgentActivity = nil
                restoreAgentProjectID = nil
            }
        } else {
            restoreAgentID = nil
            restoreAgentActivity = nil
            restoreAgentProjectID = nil
        }
        if let selectedTerminal = catalog.selectedTerminal,
           catalog.projects.indices.contains(selectedIndex),
           selectedTerminal.projectID == catalog.projects[selectedIndex].id,
           restoreAgentID == nil {
            let id = selectedTerminal.terminal.id.uuidString
            if !projects[selectedIndex].recentTerminals.contains(where: { $0.id == id }) {
                let saved = ProjectSnapshot.SavedRuntime(id: id,
                    title: String(selectedTerminal.terminal.displayTitle.unicodeScalars.prefix(
                        maximumPersistedRuntimeTitleScalars)))
                projects[selectedIndex].recentTerminals.insert(saved, at: 0)
                if projects[selectedIndex].recentTerminals.count > maximumSelectableTerminalsPerProject {
                    projects[selectedIndex].recentTerminals.removeLast()
                }
            }
            restoreTerminalID = id
        } else {
            restoreTerminalID = nil
        }
        let selectedProjectID = projects.indices.contains(selectedIndex) ? projects[selectedIndex].id : nil
        // Mac pins the scratchpad above projects while preserving the user's remaining order.
        // Partition once per store snapshot; pointer and paint still touch only visible rows.
        let pinned = projects.filter(\.isScratchpad)
        let ordinary = projects.filter { !$0.isScratchpad }
        projects = pinned + ordinary
        let displayedSelectedIndex = selectedProjectID.flatMap { id in
            projects.firstIndex { $0.id == id }
        } ?? 0
        return WindowSnapshot(projects: projects, selectedProjectIndex: displayedSelectedIndex,
                              restoreAgentID: restoreAgentID,
                              restoreAgentActivity: restoreAgentActivity,
                              restoreAgentProjectID: restoreAgentProjectID,
                              restoreTerminalID: restoreTerminalID)
    }

    static func modifiers(_ event: TWEvent) -> PTYEmulator.Modifiers {
        var result: PTYEmulator.Modifiers = []
        if event.modifiers & 1 != 0 { result.insert(.shift) }
        if event.modifiers & 2 != 0 { result.insert(.alt) }
        if event.modifiers & 4 != 0 { result.insert(.ctrl) }
        if event.modifiers & 8 != 0 { result.insert(.super) }
        if event.modifiers & 16 != 0 { result.insert(.capsLock) }
        if event.modifiers & 32 != 0 { result.insert(.numLock) }
        return result
    }

    @MainActor static func sendFunctional(_ event: TWEvent, to session: GraphicalTerminal) {
        let key: PTYEmulator.Key
        switch event.key {
        case Int32(TW_KEY_ESCAPE): key = .escape
        case Int32(TW_KEY_ENTER): key = .enter
        case Int32(TW_KEY_TAB): key = .tab
        case Int32(TW_KEY_BACKSPACE): key = .backspace
        case Int32(TW_KEY_DELETE): key = .delete
        case Int32(TW_KEY_UP): key = .up
        case Int32(TW_KEY_DOWN): key = .down
        case Int32(TW_KEY_LEFT): key = .left
        case Int32(TW_KEY_RIGHT): key = .right
        case Int32(TW_KEY_HOME): key = .home
        case Int32(TW_KEY_END): key = .end
        case Int32(TW_KEY_PAGE_UP): key = .pageUp
        case Int32(TW_KEY_PAGE_DOWN): key = .pageDown
        case Int32(TW_KEY_F1): key = .f1
        case Int32(TW_KEY_F2): key = .f2
        case Int32(TW_KEY_F3): key = .f3
        case Int32(TW_KEY_F4): key = .f4
        case Int32(TW_KEY_F5): key = .f5
        case Int32(TW_KEY_F6): key = .f6
        case Int32(TW_KEY_F7): key = .f7
        case Int32(TW_KEY_F8): key = .f8
        case Int32(TW_KEY_F9): key = .f9
        case Int32(TW_KEY_F10): key = .f10
        case Int32(TW_KEY_F11): key = .f11
        case Int32(TW_KEY_F12): key = .f12
        default: return
        }
        guard let action = PTYEmulator.KeyAction(rawValue: Int(event.action)) else { return }
        session.key(key, modifiers: modifiers(event), action: action)
    }

    @MainActor static func pasteClipboard(into session: GraphicalTerminal, window: OpaquePointer) {
        var bytes = [UInt8](repeating: 0, count: GraphicalTerminal.maximumPasteBytes)
        let length = bytes.withUnsafeMutableBufferPointer {
            tw_clipboard_read($0.baseAddress, Int32($0.count))
        }
        guard length >= 0 else {
            let reason = length == -1 ? "clipboard exceeds 64 KiB" : "clipboard is unavailable"
            tw_title(window, "Threading terminal - \(reason)")
            print("CLIPBOARD_REFUSED \(reason)"); fflush(nil)
            return
        }
        guard length > 0 else { return }
        let payload = Data(bytes.prefix(Int(length)))
        guard String(data: payload, encoding: .utf8) != nil else {
            tw_title(window, "Threading terminal - clipboard is not UTF-8")
            print("CLIPBOARD_REFUSED invalid UTF-8"); fflush(nil)
            return
        }
        session.paste(payload)
    }

    @MainActor static func showTerminal(_ args: [String]) throws {
        guard args.count >= 4, args[3].hasPrefix("/") else {
            throw WindowFailure("usage: WindowHarness --terminal STORE SOCKET DIRECTORY ABS_EXECUTABLE [ARG ...]")
        }
        guard let window = tw_open("Threading terminal - starting", 800, 528) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(window) }
        let session = GraphicalTerminal()
        defer { session.stop() }
        session.start(store: args[0], socket: args[1], directory: args[2], executable: args[3], arguments: Array(args.dropFirst(4)))
        _ = try runTerminal(session, window: window, width: 800, height: 528, allowsProjects: false)
    }

    @MainActor static func showAttachment(_ args: [String], agent: Bool = false) throws {
        guard let window = tw_open("Threading terminal - attaching", 800, 528) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(window) }
        let session = GraphicalTerminal()
        defer { session.stop() }
        if agent { session.attachAgent(store: args[0], socket: args[1], sessionID: args[2]) }
        else { session.attach(store: args[0], socket: args[1], terminalID: args[2]) }
        _ = try runTerminal(session, window: window, width: 800, height: 528, allowsProjects: false)
    }

    // Reuses the native window and live emulator. Returning to projects does not detach a child.
    @MainActor static func runTerminal(_ session: GraphicalTerminal, window: OpaquePointer,
                                      width initialWidth: Int, height initialHeight: Int,
                                      allowsProjects: Bool) throws -> (Int, Int)? {
        tw_terminal_mode(window)
        tw_project_navigation(window, allowsProjects ? 1 : 0)
        tw_accessibility_show_terminal(window, "Terminal starting")
        tw_accessibility_terminal_text(window, nil, 0, -1, nil, 0)
        session.setPreedit(nil)
        defer { session.setPreedit(nil) }
        session.invalidateFrame()
        var width = initialWidth, height = initialHeight
        var nextFrame: UInt64 = 0
        var failure: String?
        var failureNeedsDisplay = false
        while true {
            if let copy = session.takeCopyResult() {
                switch copy {
                case .text(let bytes):
                    let wrote = bytes.withUnsafeBytes {
                        tw_clipboard_write($0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count))
                    }
                    if wrote == 0 { print("CLIPBOARD_COPIED \(bytes.count)") }
                    else { print("CLIPBOARD_REFUSED native write failed") }
                case .empty: print("CLIPBOARD_REFUSED no selection")
                case .oversized: print("CLIPBOARD_REFUSED selection exceeds 1 MiB")
                }
                fflush(nil)
            }
            if let size = session.takeInitialViewport() {
                width = size.0; height = size.1
                guard tw_resize(window, Int32(width), Int32(height)) == 0 else {
                    throw WindowFailure(String(cString: tw_error()))
                }
            }
            var prepared: GraphicalTerminal.Frame?
            if failure == nil {
                do { prepared = try session.takeFrame() }
                catch {
                    guard allowsProjects else { throw error }
                    failure = String(describing: error)
                    failureNeedsDisplay = true
                    session.stop()
                }
            }
            if let failure, failureNeedsDisplay {
                try showTerminalFailure(failure, window: window, width: width, height: height)
                failureNeedsDisplay = false
            }
            if let frame = prepared, frame.width == width && frame.height == height {
                let presentStarted = DispatchTime.now().uptimeNanoseconds
                let result = frame.pixels.withUnsafeBytes {
                    tw_present(window, $0.bindMemory(to: UInt8.self).baseAddress, Int32(width), Int32(height))
                }
                guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
                frame.title.withCString { tw_accessibility_show_terminal(window, $0) }
                let accessibleRuns = frame.accessibleRuns.map {
                    TWTextRun(offset: $0.offset, characters: $0.characters,
                              column: $0.column, row: $0.row, cells: $0.cells)
                }
                frame.accessibleText.withCString { text in
                    accessibleRuns.withUnsafeBufferPointer { runs in
                        tw_accessibility_terminal_text(window, text, Int32(frame.accessibleText.utf8.count),
                                                       Int32(frame.accessibleCaret), runs.baseAddress,
                                                       Int32(runs.count))
                    }
                }
                let caretX = frame.cursorColumn >= 0 ? frame.cursorColumn * terminalCellWidth : 8
                let caretY = frame.cursorColumn >= 0 ? frame.cursorRow * terminalCellHeight : height - terminalCellHeight
                tw_text_input_rect(window, Int32(max(0, min(width - terminalCellWidth, caretX))),
                                   Int32(max(0, min(height - terminalCellHeight, caretY))),
                                   Int32(terminalCellWidth), Int32(terminalCellHeight))
                tw_title(window, frame.title)
                print("TERMINAL_FRAME \(width)x\(height) \(frame.title) drawMs=\(frame.drawMilliseconds) presentMs=\(Double(DispatchTime.now().uptimeNanoseconds - presentStarted) / 1_000_000)"); fflush(nil)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if failure == nil && now >= nextFrame {
                session.requestFrame(width: width, height: height)
                nextFrame = now + 33_000_000
            }
            var event = TWEvent()
            if tw_next_timeout(window, &event, failure == nil ? 33 : -1) == 1 {
                if event.kind == 5 { return nil }
                if event.kind == 8 && allowsProjects { return (width, height) }
                if event.kind == 1 {
                    _ = tw_repaint(window)
                    width = max(320, min(1280, Int(event.width)))
                    height = max(180, min(900, Int(event.height)))
                    failureNeedsDisplay = failure != nil
                }
                guard failure == nil else { continue }
                if event.kind == 19 {
                    let value = String(validatingCString: tw_event_text(&event)) ?? "[invalid composition]"
                    session.setPreedit(value, cursor: Int(event.textCursor),
                                       selectionLength: Int(event.textSelectionLength))
                    print("IME_PREEDIT bytes=\(value.utf8.count)"); fflush(nil)
                }
                if event.kind == 6 {
                    session.setPreedit(nil)
                    if let value = String(validatingCString: tw_event_text(&event)) {
                        session.send(Data(value.utf8))
                        if event.action == 1 {
                            print("IME_COMMIT bytes=\(value.utf8.count)"); fflush(nil)
                        }
                    } else {
                        print("IME_REFUSED invalid UTF-8 commit"); fflush(nil)
                    }
                }
                if event.kind == 7 { sendFunctional(event, to: session) }
                if event.kind == 14 { pasteClipboard(into: session, window: window) }
                if event.kind == 15 {
                    session.mouseButton(x: Int(event.x), y: Int(event.y), button: Int(event.key),
                        release: event.action == 3, modifiers: modifiers(event))
                }
                if event.kind == 16 {
                    session.mouseWheel(x: Int(event.x), y: Int(event.y), steps: Int(event.key),
                        modifiers: modifiers(event))
                }
                if event.kind == 17 { session.mouseMotion(x: Int(event.x), y: Int(event.y)) }
                if event.kind == 18 { session.requestCopySelection() }
            }
        }
    }

    @MainActor static func showTerminalFailure(_ message: String, window: OpaquePointer,
                                              width: Int, height: Int, workspace: Bool = false,
                                              focused: Bool = true) throws {
        let accessible = "Terminal unavailable: \(boundedAccessibilityLabel(message))"
        accessible.withCString { tw_accessibility_show_terminal(window, $0) }
        tw_accessibility_terminal_text(window, nil, 0, -1, nil, 0)
        let root = Specimen.Window(frame: NSRect(x: 0, y: 0, width: width / 2, height: height / 2))
        root.title = "Terminal unavailable"
        root.addSubview(Specimen.Message(frame: NSRect(x: 12, y: 8,
            width: root.frame.width - 24, height: root.frame.height - 42),
            text: "Ctrl+Shift+P: projects\n\n" + message, ink: root.bodyInk.label))
        let bitmap = Bitmap(width: width, height: height, background: Specimen.bodyGround.components)
        let context = NSGraphicsContext(bitmap: bitmap, scale: 2)
        NSGraphicsContext.current = context
        root.render(in: context)
        NSGraphicsContext.current = nil
        let result = bitmap.pixels.withUnsafeBufferPointer {
            workspace ? tw_present_pane(window, $0.baseAddress, Int32(width), Int32(height), 0)
                : tw_present(window, $0.baseAddress, Int32(width), Int32(height))
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        if focused { tw_title(window, "Threading terminal - unavailable") }
        print("FAILURE_FRAME \(width)x\(height)"); fflush(nil)
    }

    @MainActor private static func reconcilePendingAgents(
        projects: inout [ProjectSnapshot],
        projectIndexes: [String: Int],
        runtimes: inout [SavedRuntimeKey: GraphicalTerminal],
        pending: inout [String: ProjectID],
        publishedCounts: inout [String: Int],
        retainedProjects: inout Set<String>,
        preserving selection: (projectID: String, agentID: String)? = nil
    ) -> Bool {
        var changed = false
        var admitted: [GraphicalTerminal.AgentCreation] = []
        publishedCounts = publishedCounts.filter { runtimes[.agent($0.key)] != nil }
        // At most eight runtime receipts; no store reads or archive walk on the UI actor.
        for id in Array(pending.keys) {
            let key = SavedRuntimeKey.agent(id)
            guard let runtime = runtimes[key] else { pending.removeValue(forKey: id); continue }
            if let receipt = runtime.takeAgentCreation() {
                admitted.append(receipt)
                pending.removeValue(forKey: id)
            } else if runtime.canReplace, !runtime.hasPendingAgentCreation {
                // A receipt can arrive between the take and the failure check. Never discard
                // a committed row just because its later spawn failed.
                runtime.stop()
                runtimes.removeValue(forKey: key)
                pending.removeValue(forKey: id)
                changed = true
            }
        }
        // Keep commit order across batches too: a worker can publish just after this iteration
        // inspected it, while a newer admission is already consumed from a different runtime.
        for receipt in admitted.sorted(by: { $0.sessionCount < $1.sessionCount }) {
            guard let index = projectIndexes[receipt.projectID.uuidString],
                  projects.indices.contains(index),
                  projects[index].id == receipt.projectID.uuidString else { continue }
            let id = receipt.row.id.uuidString
            publishedCounts[id] = receipt.sessionCount
            if !projects[index].recentAgents.contains(where: { $0.id == id }) {
                let newer = projects[index].recentAgents.lastIndex {
                    (publishedCounts[$0.id] ?? 0) > receipt.sessionCount
                }
                projects[index].recentAgents.insert(savedAgent(receipt.row), at: newer.map { $0 + 1 } ?? 0)
                if projects[index].recentAgents.count > maximumSelectableAgentsPerProject {
                    let last = projects[index].recentAgents.count - 1
                    let preservesLast = selection?.projectID == projects[index].id
                        && selection?.agentID == projects[index].recentAgents[last].id
                    projects[index].recentAgents.remove(at: preservesLast ? last - 1 : last)
                }
            }
            // Import may already include this admission, even outside its recent-row window.
            // Keep its newer row presentation/order and never count the same commit twice.
            projects[index].sessions = max(projects[index].sessions, receipt.sessionCount)
            retainedProjects.insert(receipt.projectID.uuidString)
            changed = true
        }
        return changed
    }

    /// At most eight creation receipts, with at most 512 value rows in each affected picker.
    /// A persisted count is authoritative even when selection or process admission then failed.
    @MainActor private static func reconcileCreatedTerminals(
        projects: inout [ProjectSnapshot], projectIndexes: [String: Int],
        runtimes: [String: GraphicalTerminal],
        preserving selection: (projectID: String, terminalID: String)?
    ) -> Bool {
        var changed = false
        for runtime in runtimes.values {
            guard let receipt = runtime.takeTerminalCreation(),
                  let index = projectIndexes[receipt.projectID.uuidString],
                  projects.indices.contains(index),
                  projects[index].id == receipt.projectID.uuidString else { continue }
            let id = receipt.terminalID.uuidString
            projects[index].recentTerminals.removeAll { $0.id == id }
            projects[index].recentTerminals.insert(.init(id: id, title: receipt.title), at: 0)
            if projects[index].recentTerminals.count > maximumSelectableTerminalsPerProject {
                let last = projects[index].recentTerminals.count - 1
                let preservesLast = selection?.projectID == projects[index].id
                    && selection?.terminalID == projects[index].recentTerminals[last].id
                projects[index].recentTerminals.remove(at: preservesLast ? last - 1 : last)
            }
            // A concurrent folder-import snapshot may already include this exact admission.
            projects[index].terminalCount = max(projects[index].terminalCount, receipt.terminalCount)
            changed = true
        }
        return changed
    }

    @MainActor static func show(_ snapshot: WindowSnapshot, launch: [String]? = nil,
                                agentExecutable: String? = nil,
                                claudeExecutable: String? = nil,
                                codexAccounts: [AccountHandle] = [],
                                claudeAccounts: [AccountHandle] = []) throws {
        var traceFirstFrame = ProcessInfo.processInfo.environment["THREADING_LINUX_STARTUP_TRACE"] == "1"
        let traceNavigation = ProcessInfo.processInfo.environment["THREADING_LINUX_NAVIGATION_TRACE"] == "1"
        let maximumTraceRecords = 256
        var traceRecords = 0
        let traceStarted = traceFirstFrame || traceNavigation ? DispatchTime.now().uptimeNanoseconds : 0
        func trace(_ stage: @autoclosure () -> String) {
            guard (traceFirstFrame || traceNavigation), traceRecords < maximumTraceRecords else { return }
            traceRecords += 1
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - traceStarted) / 1_000_000
            // Direct stderr writes survive a stall before the ordinary frame log is flushed.
            let label = traceFirstFrame ? "STARTUP_TRACE" : "NAVIGATION_TRACE"
            FileHandle.standardError.write(Data(
                "\(label) scope=navigator stage=\(stage()) elapsedMs=\(elapsed)\n".utf8))
        }
        trace("open.begin")
        var codexAccount = AccountHandle(storedName:
            ProcessInfo.processInfo.environment["THREADING_LINUX_CODEX_ACCOUNT"])
        var claudeAccount = AccountHandle(storedName:
            ProcessInfo.processInfo.environment["THREADING_LINUX_CLAUDE_ACCOUNT"])
        var projects = snapshot.projects
        var projectIndexes = Dictionary(uniqueKeysWithValues: projects.enumerated().map { ($0.element.id, $0.offset) })
        let sidebarWidth = 320
        let initialWidth = launch == nil ? 800 : 1120
        guard let window = tw_open("Threading Linux window experiment",
                                   Int32(initialWidth), 480) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        trace("open.end")
        defer { tw_close(window) }
        // The raster surface is two device pixels per AppKit point. Keep one content owner and
        // root for the native window's lifetime so attachment callbacks describe that lifetime.
        let contentWindow = NSWindow(backingScaleFactor: 2)
        contentWindow.isKeyWindow = tw_window_has_focus(window) != 0
        let navigatorRoot = Specimen.Window(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        contentWindow.contentView = navigatorRoot
        navigatorRoot.setThemeAppearance()
        navigatorRoot.headerHeight = navigatorHeaderHeight
        navigatorRoot.hasMountedHeader = true
        // Retain the real production pane band and its controls for the window lifetime.
        // The title yields before either action; the band owns margins, spacing and its rule.
        let headerTitle = NSTextField(labelWithString: "Projects")
        headerTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        headerTitle.textColor = navigatorRoot.headerInk.label
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        headerTitle.setAccessibilityElement(false)
        let addProjectButton = ThemedIconButton(
            symbolName: "plus", accessibility: "Add Project", target: .inline,
            inkSource: .chrome)
        addProjectButton.toolTip = "Add Project"
        addProjectButton.presentsMenu = true
        var addProjectActivated = false
        var addProjectControlVisualChanged = false
        addProjectButton.onPress = { addProjectActivated = true }
        addProjectButton.surfaceStateDidChange = { addProjectControlVisualChanged = true }
        let actionsButton = ThemedIconButton(
            symbolName: "ellipsis", accessibility: "Actions", target: .inline,
            inkSource: .chrome)
        actionsButton.toolTip = "Actions (Ctrl+Shift+Space)"
        var actionsActivated = false
        var actionsControlVisualChanged = false
        actionsButton.onPress = { actionsActivated = true }
        actionsButton.surfaceStateDidChange = { actionsControlVisualChanged = true }
        let header = PaneHeaderView(
            leading: [headerTitle], trailing: [addProjectButton, actionsButton], margin: .paneEdge)
        navigatorRoot.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: navigatorRoot.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: navigatorRoot.trailingAnchor),
            header.topAnchor.constraint(equalTo: navigatorRoot.topAnchor)
        ])
        let outlineSource = NavigatorOutlineSource()
        let outline = NSOutlineView(frame: .zero)
        outline.rowHeight = SidebarDefaults.rowHeight
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        let outlineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Projects"))
        outline.addTableColumn(outlineColumn)
        outline.outlineTableColumn = outlineColumn
        outline.dataSource = outlineSource
        outline.delegate = outlineSource
        let outlineScroll = NSScrollView(frame: .zero)
        outlineScroll.verticalLineScroll = SidebarDefaults.rowHeight
            + outline.intercellSpacing.height
        outlineScroll.documentView = outline
        navigatorRoot.setNavigatorOutline(outlineScroll, visible: false)
        func headerPixels(_ view: NSView) -> (x: Int32, y: Int32, width: Int32, height: Int32) {
            let rect = view.convert(view.bounds, to: navigatorRoot)
            let scale = contentWindow.backingScaleFactor
            return (Int32(rect.minX * scale),
                    Int32((navigatorRoot.bounds.height - rect.maxY) * scale),
                    Int32(rect.width * scale), Int32(rect.height * scale))
        }
        func projectControlPixels(_ rowIndex: Int, create: Bool)
            -> (x: Int32, y: Int32, width: Int32, height: Int32)? {
            guard let row = outline.view(atColumn: 0, row: rowIndex,
                                         makeIfNecessary: false) as? Specimen.Row,
                  let control = row.productionProjectControl(create: create) else {
                return nil
            }
            let viewport = outlineScroll.convert(outlineScroll.bounds, to: navigatorRoot)
            let rowBounds = row.convert(row.bounds, to: navigatorRoot).intersection(viewport)
            let visible = control.convert(control.bounds, to: navigatorRoot).intersection(rowBounds)
            guard !visible.isEmpty else { return nil }
            let scale = contentWindow.backingScaleFactor
            return (Int32(visible.minX * scale),
                    Int32((navigatorRoot.bounds.height - visible.maxY) * scale),
                    Int32(visible.width * scale), Int32(visible.height * scale))
        }
        func outlineRowPixels(_ rowIndex: Int, indent: CGFloat = 0)
            -> (x: Int32, y: Int32, width: Int32, height: Int32)? {
            guard let cell = outline.view(atColumn: 0, row: rowIndex,
                                          makeIfNecessary: false) else { return nil }
            let viewport = outlineScroll.convert(outlineScroll.bounds, to: navigatorRoot)
            var rect = cell.convert(cell.bounds, to: navigatorRoot).intersection(viewport)
            guard !rect.isEmpty else { return nil }
            rect.origin.x += indent
            rect.size.width = max(0, rect.width - indent)
            let scale = contentWindow.backingScaleFactor
            return (Int32(rect.minX * scale),
                    Int32((navigatorRoot.bounds.height - rect.maxY) * scale),
                    Int32(rect.width * scale), Int32(rect.height * scale))
        }
        func outlineRowIndex(at event: TWEvent) -> Int? {
            let scale = contentWindow.backingScaleFactor
            let point = NSPoint(x: CGFloat(event.x) / scale,
                                y: navigatorRoot.bounds.height - CGFloat(event.y) / scale)
            guard outlineScroll.convert(outlineScroll.bounds, to: navigatorRoot).contains(point)
            else { return nil }
            let index = outline.row(at: outline.convert(point, from: navigatorRoot))
            return index >= 0 ? index : nil
        }
        func publishOutlineAccessibleRow(_ rowIndex: Int, id: String, label: String,
                                         selected: Bool, indent: CGFloat = 0) throws {
            guard let bounds = outlineRowPixels(rowIndex, indent: indent) else {
                throw WindowFailure("accessible outline row has no mounted cell")
            }
            let result = id.withCString { identifier in
                label.withCString { name in
                    tw_accessibility_add_row(window, identifier, name, selected ? 1 : 0,
                        bounds.x, bounds.y, bounds.width, bounds.height)
                }
            }
            guard result == 0 else { throw WindowFailure("native outline row exceeds its bound") }
        }
        var laidOutHeaderSize: NSSize?
        var laidOutHeaderTitle: String?
        var laidOutAddProjectHidden: Bool?
        var laidOutActionsHidden: Bool?
        func publishHeaderGeometry() {
            // A recycled outline cell can invalidate its own constraints on every wheel tick.
            // The header's geometry changes only with its containing width, title, or control
            // visibility, so a scroll must not lay out the entire document to republish it.
            if laidOutHeaderSize != navigatorRoot.bounds.size ||
               laidOutHeaderTitle != headerTitle.stringValue ||
               laidOutAddProjectHidden != addProjectButton.isHidden ||
               laidOutActionsHidden != actionsButton.isHidden {
                contentWindow.layoutIfNeeded()
                laidOutHeaderSize = navigatorRoot.bounds.size
                laidOutHeaderTitle = headerTitle.stringValue
                laidOutAddProjectHidden = addProjectButton.isHidden
                laidOutActionsHidden = actionsButton.isHidden
            }
            let actionsRect = headerPixels(actionsButton)
            tw_actions_button(window, actionsButton.isSelected ? "Close actions" : "Actions",
                              actionsButton.isEnabled ? 1 : 0, actionsRect.x, actionsRect.y,
                              actionsRect.width, launch == nil ? 0 : actionsRect.height)
            let addRect = headerPixels(addProjectButton)
            tw_add_project_button(window, addProjectButton.isEnabled ? 1 : 0,
                                  addRect.x, addRect.y, addRect.width,
                                  launch == nil ? 0 : addRect.height)
        }
        tw_navigator_pointer_route(window, 1)
        defer { contentWindow.contentView = nil }
        var pendingMountedRowSlot: Int?
        func mountedRowPressed(by event: TWEvent) -> Int? {
            if let slot = pendingMountedRowSlot {
                pendingMountedRowSlot = nil
                return slot
            }
            activatedOutlineItem = nil
            let scale = contentWindow.backingScaleFactor
            let point = NSPoint(x: CGFloat(event.x) / scale,
                                y: navigatorRoot.bounds.height - CGFloat(event.y) / scale)
            guard let delivered = contentWindow.dispatch(NavigatorMouseEvent(locationInWindow: point))
            else { return nil }
            navigatorRoot.hitTest(point)?.mouseDown(with: delivered)
            if actions == nil, accountPicker == nil, savedPicker == nil,
               !projects.isEmpty, let index = outlineRowIndex(at: event),
               let activatedOutlineItem,
               outline.row(forItem: activatedOutlineItem) == index {
                return index - first
            }
            return navigatorRoot.takeActivatedRowSlot()
        }
        func navigatorStep(for event: TWEvent) -> Int? {
            let direction = event.kind == 3 ? -1 : 1
            if event.action == 1 {
                return actions == nil && accountPicker == nil && savedPicker == nil
                    ? nil : direction
            }
            guard sidebarFocused else { return nil }
            if actions == nil && accountPicker == nil && savedPicker == nil { return direction }
            if accountPicker != nil { return direction }
            _ = contentWindow.dispatchToContent(NavigatorKeyEvent(
                keyCode: event.kind == 3 ? 126 : 125))
            return navigatorRoot.takeNavigationStep()
        }
        var terminals: [String: GraphicalTerminal] = [:]
        var restoredRuntimes: [SavedRuntimeKey: GraphicalTerminal] = [:]
        var pendingAgentProjects: [String: ProjectID] = [:]
        // At most one commit count per retained agent runtime, within the shared eight-slot cap.
        var publishedAgentCounts: [String: Int] = [:]
        var restoredProjectIDs: Set<String> = []
        // A fresh project shell keeps one owner even when selected through its saved row.
        // These lookups never add aliases, so the sum of cache counts stays the eight-slot bound.
        func owner(of key: SavedRuntimeKey, projectID: String) -> RuntimeOwner {
            if case .terminal(let id) = key, terminals[projectID]?.terminalID == id {
                return .project(projectID)
            }
            return .saved(key)
        }
        func retainedRuntime(for owner: RuntimeOwner) -> GraphicalTerminal? {
            switch owner {
            case .project(let id): return terminals[id]
            case .saved(let key): return restoredRuntimes[key]
            }
        }
        func retain(_ runtime: GraphicalTerminal, for owner: RuntimeOwner) {
            switch owner {
            case .project(let id): terminals[id] = runtime
            case .saved(let key): restoredRuntimes[key] = runtime
            }
        }
        defer {
            for terminal in terminals.values { terminal.stop() }
            for terminal in restoredRuntimes.values { terminal.stop() }
        }
        var width = initialWidth, height = 480,
            selected = snapshot.selectedProjectIndex, first = 0
        var expandedProjectID: String?
        var inlineSelection: SidebarVisibleRows.Row?
        var savedPicker: SavedPicker?
        var savedSelected = 0, savedFirst = 0
        var accountPicker: AgentKind?
        var accountSelected = 0, accountFirst = 0
        var activatedAccountHandle: AccountHandle?
        var pendingSelection: PendingSelection?
        var pendingFolderImport: FolderImportGate?
        var actions: NavigatorActions.Presentation?
        var activatedMenuEntry: Int?
        var actionsEnabled = true
        var dismissedActionGesture: Int32?
        var hoveredProjectID: String?
        var outlineNeedsReload = true
        var outlineExpandedProjectID: String?
        var outlineScrollSelection = true
        var activatedOutlineItem: NavigatorOutlineItem?
        var activatedOutlineProjectActionID: String?
        var activatedOutlineProjectCreateID: String?
        var rowActionMenuGesture = false
        var rowActionMenuSource: NSRect = .zero
        var rowActionMenuEntered = false
        func actionState(for targetID: ProjectID? = nil) -> NavigatorActions.State {
            let project: ProjectSnapshot?
            if let targetID, let index = projectIndexes[targetID.uuidString],
               projects.indices.contains(index), projects[index].id == targetID.uuidString {
                project = projects[index]
            } else if targetID != nil {
                project = nil
            } else {
                project = projects.indices.contains(selected) ? projects[selected] : nil
            }
            let shell = project.flatMap { terminals[$0.id] }
            let runtimeCount = terminals.count + restoredRuntimes.count
            return .init(projectID: project.flatMap { ProjectID(uuidString: $0.id) },
                canOpenShell: shell != nil || runtimeCount < maximumOpenRuntimes,
                canCreateShell: (shell == nil || shell!.canReplace)
                    && runtimeCount - (shell == nil ? 0 : 1) < maximumOpenRuntimes,
                shellMayBeRunning: shell != nil && shell?.canReplace != true,
                canCreateAgent: runtimeCount < maximumOpenRuntimes,
                hasCodex: agentExecutable != nil, hasClaude: claudeExecutable != nil,
                hasAgents: project?.recentAgents.isEmpty == false,
                hasTerminals: project?.recentTerminals.isEmpty == false)
        }
        defer { pendingFolderImport?.cancel() }
        var dirty = true
        var nextVisibleAttentionExpiry: Date?
        func configureOutlineRow(_ row: Specimen.Row, item: NavigatorOutlineItem,
                                 frame: NSRect) {
            guard let model = item.resolvedRow(in: projects, indexes: projectIndexes) else {
                return
            }
            let accent = Design.Surface.selectionFill
            let selectedInk = LinuxTheme.neutralInk(on: accent, dark: LinuxTheme.isDark)
            let selectedItem = inlineSelection.map { NavigatorOutlineItem($0, projects: projects) }
                ?? (projects.indices.contains(selected)
                    ? NavigatorOutlineItem(projectID: projects[selected].id, projectIndex: selected) : nil)
            let isSelected = selectedItem == item
            let ink = isSelected ? selectedInk : navigatorRoot.bodyInk
            row.configure(frame: frame, accent: accent, selected: isSelected, ink: ink,
                          image: nil, showsMark: false, disclosure: nil,
                          preserveProductionContent: true)
            row.drawsSelectionBackground = false
            row.onPress = { activatedOutlineItem = item }
            row.onNavigation = nil
            row.onProjectAction = { activatedOutlineProjectActionID = $0 }
            row.onProjectCreate = { activatedOutlineProjectCreateID = $0 }
            row.onProjectControlVisualChange = { dirty = true }

            switch model {
            case .project(let projectIndex, _):
                let project = projects[projectIndex]
                let total = project.sessions.addingReportingOverflow(project.terminalCount)
                let totalRuntimes = total.overflow ? Int.max : total.partialValue
                let visibleChildren = min(project.recentAgents.count,
                    SidebarVisibleRows.maximumChildrenPerKind)
                    + min(project.recentTerminals.count, SidebarVisibleRows.maximumChildrenPerKind)
                let collapsedCount = expandedProjectID == project.id
                    ? max(0, totalRuntimes - visibleChildren) : totalRuntimes
                let hasChildren = !project.recentAgents.isEmpty || !project.recentTerminals.isEmpty
                let disclosure = hasChildren && launch != nil
                    ? (expandedProjectID == project.id ? "▾ " : "▸ ") : ""
                let title = disclosure + String(project.name.unicodeScalars.prefix(80))
                row.configureProductionProject(
                    presentation: .project(name: title),
                    icon: GeneratedProjectIcon.image(for: project.name), count: collapsedCount,
                    projectID: launch == nil ? nil : project.id,
                    revealed: hoveredProjectID == project.id, enabled: actionsEnabled)
                row.configureProductionStatus(nil, color: ink.secondary)
            case .agent(let projectIndex, let childIndex, _):
                let project = projects[projectIndex]
                let runtime = project.recentAgents[childIndex]
                let retained = retainedRuntime(for: owner(of: .agent(runtime.id),
                    projectID: project.id)) != nil
                let now = Date()
                let status = runtime.attentionTitle(at: now) ?? (retained ? "Retained" : nil)
                if runtime.attention(at: now) == .snoozed, let expiry = runtime.snoozedUntil {
                    nextVisibleAttentionExpiry = min(nextVisibleAttentionExpiry ?? expiry, expiry)
                }
                row.configureProductionSession(title: readableNavigatorText(runtime.title),
                    icon: ProviderMarks.image(for: runtime.kind, selected: isSelected),
                    selected: isSelected, trailingInset: status == nil ? 4 : 72,
                    leadingIndent: 16)
                row.configureProductionStatus(status, color: ink.secondary)
            case .terminal(let projectIndex, let childIndex, _):
                let project = projects[projectIndex]
                let runtime = project.recentTerminals[childIndex]
                let retained = retainedRuntime(for: owner(of: .terminal(runtime.id),
                    projectID: project.id)) != nil
                row.configureProductionTerminal(title: readableNavigatorText(runtime.title),
                    icon: terminalMark, selected: isSelected, running: retained,
                    leadingIndent: 16)
                row.configureProductionStatus(nil, color: ink.secondary)
            }
        }
        func configureOutlineChrome(_ row: SidebarHoverRowView, in view: NSOutlineView) {
            row.isHoverEnabled = true
            row.showsGroupRule = false
            row.applySidebarDensity(SidebarDensity(width: view.bounds.width,
                floor: min(SidebarDefaults.tightDensityWidth, view.bounds.width)))
            row.setActivityBeam(workload: .none)
        }
        outlineSource.makeRow = { view, item in
            let rowIndex = view.row(forItem: item)
            guard rowIndex >= 0 else { return nil }
            let frame = view.rect(ofRow: rowIndex)
            let identifier = NSUserInterfaceItemIdentifier("NavigatorOutlineRow")
            let row = (view.makeView(withIdentifier: identifier, owner: nil) as? Specimen.Row)
                ?? Specimen.Row(frame: frame, text: "", accent: .clear, selected: false,
                                ink: navigatorRoot.bodyInk, showsMark: false)
            row.identifier = identifier
            configureOutlineRow(row, item: item, frame: frame)
            return row
        }
        outlineSource.makeChrome = { view, _ in
            let identifier = NSUserInterfaceItemIdentifier("SidebarHoverRow")
            let row = (view.makeView(withIdentifier: identifier, owner: nil)
                as? SidebarHoverRowView) ?? SidebarHoverRowView(frame: .zero)
            row.identifier = identifier
            configureOutlineChrome(row, in: view)
            return row
        }
        var placeholderActionRequested = false
        var composerSubmitRequested = false
        var composerChoice: (projectID: String, identity: AccountID)?
        var pendingComposerProjectID: String?
        var idlePane = launch.map { _ in
            WorkspacePlaceholderPane(hasProjects: !projects.isEmpty,
                                     onAction: { placeholderActionRequested = true },
                                     onSubmit: { composerSubmitRequested = true })
        }
        idlePane?.setThemeAppearance()
        func refreshComposerChoices() {
            guard let choice = composerChoice, let pane = idlePane, pane.isComposing,
                  let projectIndex = projectIndexes[choice.projectID],
                  projects.indices.contains(projectIndex),
                  projects[projectIndex].id == choice.projectID else { return }
            let projectChoices = projects.map { (id: $0.id, name: $0.name) }
            var identityChoices: [ComposerIdentityChoice] = []
            var identityBindings: [(token: String, identity: AccountID)] = []
            for (kind, executable, accounts) in [
                (AgentKind.codex, agentExecutable, codexAccounts),
                (AgentKind.claude, claudeExecutable, claudeAccounts)
            ] where executable != nil {
                let mark = ProviderMarks.image(for: kind, selected: false)
                for (index, handle) in accounts.enumerated() {
                    let token = "\(kind.rawValue):\(index)"
                    let identity = AccountID(provider: kind, handle: handle)
                    identityBindings.append((token, identity))
                    identityChoices.append(ComposerIdentityChoice(
                        id: token, providerName: kind.displayName,
                        accountName: handle.isStandard ? "" : readableNavigatorText(handle.name),
                        icon: mark))
                }
            }
            let selectedToken = identityBindings.first { $0.identity == choice.identity }?.token ?? ""
            pane.configureComposerChoices(projects: projectChoices,
                selectedProjectID: choice.projectID,
                identities: identityChoices,
                selectedIdentityID: selectedToken,
                onProjectChoice: { projectID in
                    guard let current = composerChoice, pane.isComposing,
                          let index = projectIndexes[projectID], projects.indices.contains(index),
                          projects[index].id == projectID else { return }
                    selected = index
                    inlineSelection = .project(projectIndex: index, id: projectID)
                    outlineScrollSelection = true
                    composerChoice = (projectID, current.identity)
                    refreshComposerChoices()
                    dirty = true
                },
                onIdentityChoice: { token in
                    guard let current = composerChoice, pane.isComposing,
                          let identity = identityBindings.first(where: { $0.token == token })?.identity,
                          (identity.provider == .codex ? codexAccounts : claudeAccounts)
                            .contains(identity.handle),
                          (identity.provider == .codex ? agentExecutable : claudeExecutable) != nil
                    else { return }
                    composerChoice = (current.projectID, identity)
                    if identity.provider == .codex { codexAccount = identity.handle }
                    else { claudeAccount = identity.handle }
                    refreshComposerChoices()
                    dirty = true
                })
        }
        var activePane: WorkspaceTerminalPane?
        var activePageTarget: NavigatorOutlineItem?
        var pendingPageReveal: NavigatorOutlineItem?
        var openInCatalogue = LinuxExternalApps.Catalogue(apps: [], defaultID: nil)
        var pendingOpenInCatalogue: OpenInCatalogueGate?
        var pendingOpenInMenuPage: String?
        var pendingOpenInLaunch: (gate: SelectionGate, appID: String, remember: Bool)?
        let openInIcons = OpenInIconState()
        let openInPreferenceKey = "externalApp.preferred"
        func preferredOpenInID() -> String? {
            let stored = PreferenceStore.shared.string(forKey: openInPreferenceKey)
            if let stored, openInCatalogue.apps.contains(where: { $0.id == stored }) {
                return stored
            }
            if let fallback = openInCatalogue.defaultID,
               openInCatalogue.apps.contains(where: { $0.id == fallback }) {
                return fallback
            }
            return openInCatalogue.apps.first?.id
        }
        func configureOpenInPane() {
            guard let pane = activePane else { return }
            guard let target = activePageTarget, target.id == pane.pageIdentity,
                  let index = projectIndexes[target.projectID], projects.indices.contains(index),
                  projects[index].id == target.projectID else {
                pane.configureOpenIn(preferredID: nil, icon: nil, choices: [])
                return
            }
            let choices = openInCatalogue.apps.map {
                WorkspaceTerminalPane.OpenInChoice(id: $0.id, name: $0.name)
            }
            let preferredID = preferredOpenInID()
            let selected = openInCatalogue.apps.first { $0.id == preferredID }
            let icon = selected.flatMap { openInIcons.selectedImage(for: $0) }
            pane.configureOpenIn(preferredID: preferredID, icon: icon, choices: choices)
        }
        func startOpenInDiscovery() {
            guard pendingOpenInCatalogue == nil else { return }
            let gate = OpenInCatalogueGate()
            pendingOpenInCatalogue = gate
            DispatchQueue.global(qos: .userInitiated).async {
                gate.finish(LinuxExternalApps.discover())
            }
        }
        func launchOpenIn(_ appID: String, remember: Bool) {
            guard pendingOpenInLaunch == nil, let pane = activePane,
                  let target = activePageTarget, pane.pageIdentity == target.id,
                  let index = projectIndexes[target.projectID], projects.indices.contains(index),
                  projects[index].id == target.projectID,
                  openInCatalogue.apps.contains(where: { $0.id == appID }) else {
                print("OPEN_IN_REFUSED stale page or app"); fflush(nil)
                return
            }
            let directory = projects[index].path
            let gate = SelectionGate()
            pendingOpenInLaunch = (gate, appID, remember)
            DispatchQueue.global(qos: .userInitiated).async {
                gate.finish(Result {
                    guard let folder = ProjectDirectory.existing(at: directory) else {
                        throw LinuxExternalApps.LaunchFailure(message: "The checkout no longer exists.")
                    }
                    try LinuxExternalApps.launch(appID: appID, directory: folder.path)
                })
            }
        }
        func drainOpenInRequests(_ pane: WorkspaceTerminalPane) {
            if let appID = pane.takeOpenInPressRequest() {
                launchOpenIn(appID, remember: false)
            }
            if pane.takeOpenInChooserToggleRequest() {
                if pane.hasOpenInMenu {
                    pane.toggleOpenInMenu(window: window, paneWidth: terminalWidth)
                } else if pendingOpenInMenuPage == pane.pageIdentity {
                    pendingOpenInMenuPage = nil
                } else {
                    pendingOpenInMenuPage = pane.pageIdentity
                    startOpenInDiscovery()
                }
            }
            if let appID = pane.takeOpenInChoiceRequest() {
                launchOpenIn(appID, remember: true)
                pane.dismissMenu(window: window)
            }
        }
        startOpenInDiscovery()
        var sidebarFocused = true
        var navigatorTitle = "Threading Linux window experiment"
        var hasSplitPane: Bool { idlePane != nil || activePane != nil }
        var navigatorWidth: Int { hasSplitPane ? sidebarWidth : width }
        var terminalWidth: Int { hasSplitPane ? width - sidebarWidth : width }
        if idlePane != nil {
            tw_workspace_mode(window, Int32(sidebarWidth), 1)
            tw_workspace_placeholder_mode(window, 1)
        }
        func setNavigatorTitle(_ title: String) {
            navigatorTitle = title
            if sidebarFocused { tw_title(window, title) }
        }
        func focusSidebar(_ focus: Bool) {
            guard hasSplitPane else { return }
            // Native sidebar focus cancels terminal gestures, including their queued release.
            // Mirror that cancellation even if a native press moved focus before Swift saw it.
            if focus { dismissedActionGesture = nil }
            let changed = sidebarFocused != focus
            sidebarFocused = focus
            tw_workspace_focus(window, focus ? 1 : 0)
            if !focus { contentWindow.makeFirstResponder(nil) }
            guard changed else { return }
            activePane?.focus(!focus, window: window)
            if activePane == nil {
                idlePane?.focus(!focus)
                if !focus, idlePane?.isComposing == true {
                    idlePane?.focusEditor()
                    _ = tw_workspace_editor_focus(window, 1)
                }
            }
            if focus { tw_title(window, navigatorTitle) }
            dirty = true
        }
        func dismissActions(returnToParent: Bool = true) {
            guard let presentation = actions else { return }
            if returnToParent, presentation.kind == .chatProviders,
               let target = presentation.projectID,
               actionState(for: target).projectID == target {
                actions = .init(kind: .projectCreate, projectID: target,
                    returnToSidebar: presentation.returnToSidebar,
                    commands: NavigatorActions.projectCreateCommands(actionState(for: target)))
                dirty = true
                return
            }
            actions = nil
            rowActionMenuGesture = false
            rowActionMenuEntered = false
            focusSidebar(presentation.returnToSidebar)
            dirty = true
        }
        func openActions(for targetID: ProjectID?, returnToSidebar: Bool) {
            guard actionsEnabled else { return }
            let state = actionState(for: targetID)
            guard targetID == nil || state.projectID == targetID else { return }
            // Menu content replaces the project rows. A later keyboard dismissal must not
            // restore an old row's hover reveal at coordinates that may now mean something else.
            hoveredProjectID = nil
            rowActionMenuGesture = false
            rowActionMenuEntered = false
            actions = .init(kind: .projectActions, projectID: state.projectID,
                            returnToSidebar: returnToSidebar,
                            commands: NavigatorActions.projectCommands(state))
            focusSidebar(true)
            dirty = true
        }
        func openAddProjectMenu() {
            guard actionsEnabled, pendingFolderImport == nil, pendingSelection == nil,
                  addProjectButton.isEnabled else { return }
            if actions != nil { dismissActions(returnToParent: false) }
            hoveredProjectID = nil
            actions = .init(kind: .addProject, projectID: nil,
                            returnToSidebar: sidebarFocused,
                            commands: NavigatorActions.addProjectMenuCommands())
            focusSidebar(true)
            dirty = true
        }
        func openProjectCreateMenu(for targetID: ProjectID, returnToSidebar: Bool) {
            guard actionsEnabled, actionState(for: targetID).projectID == targetID else { return }
            hoveredProjectID = nil
            rowActionMenuGesture = false
            rowActionMenuEntered = false
            actions = .init(kind: .projectCreate, projectID: targetID,
                returnToSidebar: returnToSidebar,
                commands: NavigatorActions.projectCreateCommands(actionState(for: targetID)))
            focusSidebar(true)
            dirty = true
        }
        func openChatProvidersMenu(for targetID: ProjectID, returnToSidebar: Bool) {
            guard actionsEnabled, actionState(for: targetID).projectID == targetID else { return }
            actions = .init(kind: .chatProviders, projectID: targetID,
                returnToSidebar: returnToSidebar,
                commands: NavigatorActions.chatProviderCommands(actionState(for: targetID)))
            focusSidebar(true)
            dirty = true
        }
        func invokeSessionMenuCommand(_ command: SessionMenuCommand) {
            guard let pane = activePane, let target = activePageTarget,
                  target.kind == .agent, pane.pageIdentity == target.id,
                  let projectIndex = projectIndexes[target.projectID],
                  projects.indices.contains(projectIndex),
                  projects[projectIndex].id == target.projectID,
                  projects[projectIndex].recentAgents.contains(where: { $0.id == target.id })
            else {
                print("SESSION_ACTION_REFUSED stale page identity"); fflush(nil)
                return
            }
            let value: String
            switch command {
            case .copySessionID: value = target.id
            case .copyProjectPath: value = projects[projectIndex].path
            }
            let bytes = Data(value.utf8)
            guard !bytes.isEmpty, bytes.count <= 1_048_576 else {
                print("SESSION_ACTION_REFUSED clipboard payload exceeds bound"); fflush(nil)
                return
            }
            let result = bytes.withUnsafeBytes {
                tw_clipboard_write($0.bindMemory(to: UInt8.self).baseAddress, Int32(bytes.count))
            }
            if result == 0 {
                print("SESSION_ACTION_COPIED \(command.rawValue) \(target.id)")
            } else {
                print("SESSION_ACTION_REFUSED clipboard unavailable")
            }
            fflush(nil)
        }
        func routeTerminalInput(_ event: TWEvent) -> Bool {
            if event.kind == 50 || event.kind == 51 {
                guard activePane == nil, let idlePane, idlePane.isComposing,
                      let identity = idlePane.composerIdentity else { return true }
                var actionEvent = event
                let value = String(validatingCString: tw_event_text(&actionEvent)) ?? ""
                if event.kind == 50, value == identity {
                    _ = idlePane.pressComposerChoice(kind: Int(event.action), identity: identity)
                } else if event.kind == 51 {
                    _ = idlePane.chooseComposerChoice(kind: Int(event.action),
                        index: Int(event.key), id: value, identity: identity)
                }
                _ = tw_workspace_editor_focus(window,
                    idlePane.editorHasFocus || idlePane.hasOpenComposerChoice ? 1 : 0)
                dirty = true
                return true
            }
            if event.kind == 49 {
                var operation: Int32 = 0
                var start: Int32 = 0
                var end: Int32 = 0
                var identity = [CChar](repeating: 0, count: 128)
                var payload = [CChar](repeating: 0, count: 65_537)
                let count = tw_accessibility_take_composer_edit(window, event.key,
                    &operation, &start, &end, &identity, Int32(identity.count),
                    &payload, Int32(payload.count))
                guard count >= 0, activePane == nil, let idlePane, idlePane.isComposing,
                      let currentID = idlePane.composerIdentity,
                      let queuedID = String(bytes: identity.prefix(while: { $0 != 0 })
                          .map(UInt8.init(bitPattern:)), encoding: .utf8),
                      queuedID == currentID,
                      let value = String(bytes: payload.prefix(Int(count)).map(UInt8.init(bitPattern:)),
                                         encoding: .utf8)
                else { return true }
                _ = idlePane.applyAccessibilityEdit(operation: operation, start: start,
                                                     end: end, text: value)
                return true
            }
            if event.kind == 46 || event.kind == 47 || event.kind == 48 {
                guard activePane == nil, let idlePane, idlePane.isComposing else { return true }
                if event.kind == 46 {
                    var committed = event
                    if let value = String(validatingCString: tw_event_text(&committed)) {
                        if idlePane.hasOpenComposerChoice {
                            _ = idlePane.handleComposerChoiceKey(NSEvent(type: .keyDown,
                                charactersIgnoringModifiers: value))
                        } else {
                            idlePane.insertCommittedText(value)
                        }
                    }
                } else if event.kind == 47 {
                    var preedit = event
                    if let value = String(validatingCString: tw_event_text(&preedit)) {
                        let units = value.unicodeScalars.map { String($0).utf16.count }
                        let start = min(max(0, Int(event.textCursor)), units.count)
                        let end = min(start + max(0, Int(event.textSelectionLength)), units.count)
                        let range = NSRange(location: units.prefix(start).reduce(0, +),
                            length: units[start..<end].reduce(0, +))
                        idlePane.updatePreedit(value, selectedRange: range)
                    }
                } else if event.action != 3 {
                    if idlePane.hasOpenComposerChoice {
                        let keyCode: UInt16
                        switch Int(event.key) {
                        case TW_KEY_ESCAPE: keyCode = 53
                        case TW_KEY_UP: keyCode = 126
                        case TW_KEY_DOWN: keyCode = 125
                        case TW_KEY_ENTER: keyCode = 36
                        default: keyCode = 0
                        }
                        if keyCode != 0,
                           idlePane.handleComposerChoiceKey(NSEvent(type: .keyDown,
                               keyCode: keyCode, charactersIgnoringModifiers: "")) {
                            _ = tw_workspace_editor_focus(window,
                                idlePane.editorHasFocus || idlePane.hasOpenComposerChoice ? 1 : 0)
                            dirty = true
                            return true
                        }
                    }
                    if Int(event.key) == TW_KEY_ESCAPE {
                        if idlePane.cancelMarkedText() { return true }
                        composerChoice = nil
                        idlePane.configure(hasProjects: !projects.isEmpty)
                        _ = tw_workspace_editor_focus(window, 0)
                        focusSidebar(true)
                        return true
                    }
                    let modifierShortcut = event.modifiers & (4 | 8) != 0
                    if modifierShortcut, let letter = UnicodeScalar(Int(event.key)) {
                        switch letter {
                        case "a": idlePane.selectAllText(); return true
                        case "c", "x":
                            if let selected = idlePane.selectedText {
                                let bytes = Array(selected.utf8)
                                if bytes.count <= 1_048_576 {
                                    let wrote = bytes.withUnsafeBufferPointer {
                                        tw_clipboard_write($0.baseAddress, Int32($0.count))
                                    }
                                    if letter == "x", wrote == 0 { idlePane.deleteSelection() }
                                }
                            }
                            return true
                        case "v":
                            var bytes = [UInt8](repeating: 0, count: 65_536)
                            let count = bytes.withUnsafeMutableBufferPointer {
                                tw_clipboard_read($0.baseAddress, Int32($0.count))
                            }
                            if count > 0, let value = String(bytes: bytes.prefix(Int(count)), encoding: .utf8) {
                                idlePane.insertCommittedText(value)
                            }
                            return true
                        default: break
                        }
                    }
                    if Int(event.key) == TW_KEY_TAB {
                        idlePane.focusAction()
                        _ = tw_workspace_editor_focus(window, 0)
                    } else {
                        let keyCode: UInt16
                        let characters: String
                        switch Int(event.key) {
                        case TW_KEY_ENTER: keyCode = 36; characters = "\n"
                        case TW_KEY_BACKSPACE: keyCode = 51; characters = "\u{7f}"
                        case TW_KEY_DELETE: keyCode = 117; characters = "\u{7f}"
                        case TW_KEY_LEFT: keyCode = 123; characters = ""
                        case TW_KEY_RIGHT: keyCode = 124; characters = ""
                        case TW_KEY_DOWN: keyCode = 125; characters = ""
                        case TW_KEY_UP: keyCode = 126; characters = ""
                        default:
                            keyCode = 0
                            characters = UnicodeScalar(Int(event.key)).map(String.init) ?? ""
                        }
                        var modifiers: NSEvent.ModifierFlags = []
                        if event.modifiers & 1 != 0 { modifiers.insert(.shift) }
                        if event.modifiers & 4 != 0 { modifiers.insert(.control) }
                        if event.modifiers & 8 != 0 { modifiers.insert(.command) }
                        idlePane.handleEditorKey(NSEvent(type: .keyDown, modifierFlags: modifiers,
                            keyCode: keyCode, charactersIgnoringModifiers: characters))
                    }
                }
                return true
            }
            if event.kind == 41 || event.kind == 42 || event.kind == 43 {
                guard let pane = activePane else { return true }
                switch event.kind {
                case 41: pane.handleMenu(event, window: window)
                case 42:
                    _ = pane.pressSessionActions()
                default:
                    var identityEvent = event
                    let identity = String(validatingCString: tw_event_text(&identityEvent)) ?? ""
                    pane.chooseMenuRow(Int(event.key), identity: identity)
                }
                if pane.takeMenuToggleRequest() {
                    focusSidebar(false)
                    pane.toggleMenu(window: window, paneWidth: terminalWidth)
                }
                if let command = pane.takeMenuCommand() {
                    invokeSessionMenuCommand(command)
                    pane.dismissMenu(window: window)
                }
                drainOpenInRequests(pane)
                dirty = true
                return true
            }
            if event.kind == 2 { focusSidebar(true) }
            if event.kind == 15 && event.action == 1 { focusSidebar(false) }
            if event.kind == 39 || event.kind == 40 {
                guard activePane == nil, let idlePane else { return true }
                if event.kind == 39 {
                    if event.action == 1 { focusSidebar(false) }
                    idlePane.handle(event)
                    if idlePane.isComposing {
                        _ = tw_workspace_editor_focus(window,
                            idlePane.editorHasFocus || idlePane.hasOpenComposerChoice ? 1 : 0)
                    }
                } else {
                    _ = idlePane.pressAction()
                }
                if placeholderActionRequested {
                    placeholderActionRequested = false
                    if idlePane.isComposing {
                        composerSubmitRequested = true
                    } else if projects.isEmpty { openAddProjectMenu() }
                    else if projects.indices.contains(selected),
                            let id = ProjectID(uuidString: projects[selected].id) {
                        openProjectCreateMenu(for: id, returnToSidebar: false)
                    }
                }
                return true
            }
            if event.kind == 37 || event.kind == 38 {
                if event.kind == 37 {
                    if event.action == 1 { focusSidebar(false) }
                    activePane?.handleHeader(event)
                } else {
                    _ = activePane?.pressPageTitle()
                }
                if let pane = activePane, pane.takeMenuToggleRequest() {
                    focusSidebar(false)
                    pane.toggleMenu(window: window, paneWidth: terminalWidth)
                    dirty = true
                }
                if let pane = activePane { drainOpenInRequests(pane) }
                if let target = pendingPageReveal {
                    pendingPageReveal = nil
                    guard let projectIndex = projectIndexes[target.projectID],
                          projects.indices.contains(projectIndex) else { return true }
                    selected = projectIndex
                    if target.kind != .project {
                        expandedProjectID = target.projectID
                    }
                    inlineSelection = target.resolvedRow(in: projects, indexes: projectIndexes)
                        ?? .project(projectIndex: projectIndex, id: target.projectID)
                    savedPicker = nil
                    accountPicker = nil
                    actions = nil
                    outlineScrollSelection = true
                    focusSidebar(true)
                    dirty = true
                }
                return true
            }
            guard [6, 7, 14, 15, 16, 17, 18, 19].contains(event.kind) else { return false }
            activePane?.handle(event, window: window)
            return true
        }
        func activate(_ session: GraphicalTerminal, pageName: String,
                      pageIdentity: String, pageIcon: NSImage? = nil,
                      pageTarget: NavigatorOutlineItem) throws {
            // Standalone coordinates become a 320px sidebar when the terminal appears. Clear
            // any held control gesture and hover before those same pixels name another pane.
            contentWindow.cancelPointerGesture()
            hoveredProjectID = nil
            rowActionMenuGesture = false
            rowActionMenuEntered = false
            activePane?.focus(false, window: window)
            if !hasSplitPane {
                width += sidebarWidth
            }
            idlePane?.focus(false)
            idlePane = nil
            activePane = WorkspaceTerminalPane(session, pageName: pageName,
                pageIdentity: pageIdentity, icon: pageIcon,
                showsSessionActions: pageTarget.kind == .agent && pageTarget.childIndex >= 0,
                onReveal: { pendingPageReveal = pageTarget })
            activePane?.setThemeAppearance()
            activePageTarget = pageTarget
            configureOpenInPane()
            tw_workspace_placeholder_mode(window, 0)
            sidebarFocused = false
            contentWindow.makeFirstResponder(nil)
            tw_terminal_mode(window)
            tw_project_navigation(window, 1)
            tw_workspace_mode(window, Int32(sidebarWidth), 0)
            tw_workspace_terminal_top_inset(window,
                Int32(WorkspaceTerminalPane.headerPixelHeight))
            guard tw_workspace_reset_terminal(window) == 0 else {
                throw WindowFailure(String(cString: tw_error()))
            }
            guard tw_resize(window, Int32(width), Int32(height)) == 0 else {
                throw WindowFailure(String(cString: tw_error()))
            }
            tw_accessibility_show_terminal(window, "Terminal starting")
            tw_accessibility_terminal_text(window, nil, 0, -1, nil, 0)
            tw_title(window, "Threading terminal - starting")
            dirty = true
        }
        func beginAgent(_ kind: AgentKind, prompt: String?,
                        accountOverride: AccountHandle? = nil) throws {
            guard let launch, !projects.isEmpty else { return }
            let executable = kind == .codex ? agentExecutable : claudeExecutable
            guard let executable else { return }
            let accountHandle = accountOverride ?? (kind == .codex ? codexAccount : claudeAccount)
            guard terminals.count + restoredRuntimes.count < maximumOpenRuntimes else {
                tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                return
            }
            guard let projectID = ProjectID(uuidString: projects[selected].id) else {
                throw WindowFailure("invalid project identity")
            }
            let id = SessionID()
            let savedID = String(describing: id)
            let session = GraphicalTerminal()
            restoredRuntimes[.agent(savedID)] = session
            pendingAgentProjects[savedID] = projectID
            session.startAgent(store: launch[0], socket: launch[1], directory: projects[selected].path,
                               shell: launch[2], kind: kind, executable: executable,
                               accountHandle: accountHandle, id: id,
                               width: terminalWidth,
                               height: max(1, height - WorkspaceTerminalPane.headerPixelHeight),
                               prompt: prompt)
            try activate(session, pageName: kind.displayName, pageIdentity: savedID,
                pageIcon: ProviderMarks.image(for: kind, selected: false),
                pageTarget: NavigatorOutlineItem(kind: .agent,
                    projectID: projects[selected].id, id: savedID,
                    projectIndex: selected, childIndex: -1))
            composerChoice = nil
            dirty = true
        }
        func reconcileTerminals() -> Bool {
            let selection: (projectID: String, terminalID: String)?
            if let picker = savedPicker, !picker.isAgent,
               projects.indices.contains(picker.projectIndex),
               projects[picker.projectIndex].recentTerminals.indices.contains(savedSelected) {
                selection = (projects[picker.projectIndex].id,
                             projects[picker.projectIndex].recentTerminals[savedSelected].id)
            } else if case .some(.terminal(_, _, let id)) = inlineSelection,
                      let expandedProjectID {
                selection = (expandedProjectID, id)
            } else { selection = nil }
            let changed = reconcileCreatedTerminals(projects: &projects, projectIndexes: projectIndexes,
                                                    runtimes: terminals, preserving: selection)
            // Prepending changes positions, never the selected destination. The selected row
            // keeps a slot even at the 512 cap, including while its durable selection is pending.
            if changed, let selection, let index = projectIndexes[selection.projectID],
               projects.indices.contains(index), projects[index].id == selection.projectID,
               let row = projects[index].recentTerminals.firstIndex(where: { $0.id == selection.terminalID }) {
                savedSelected = row
            }
            return changed
        }
        func updateSurface(_ event: TWEvent) throws {
            let nextWidth = max(hasSplitPane ? 640 : 320,
                                min(hasSplitPane ? 1600 : 1280, Int(event.width)))
            let nextHeight = max(180, min(900, Int(event.height)))
            if nextWidth == width, nextHeight == height {
                // Exposure invalidates the native drawable, not the unchanged row models.
                // The initial frame and every terminal-to-project transition render before
                // this loop waits, so the retained texture already describes the current UI.
                trace("repaint.begin")
                guard tw_repaint(window) == 0 else {
                    throw WindowFailure(String(cString: tw_error()))
                }
                trace("repaint.end")
            } else {
                width = nextWidth
                height = nextHeight
                dirty = true
            }
        }
        if let id = snapshot.restoreAgentID, let launch,
           let row = projects[selected].recentAgents.firstIndex(where: { $0.id == id }) {
            let session = GraphicalTerminal()
            restoredRuntimes[.agent(id)] = session
            restoredProjectIDs.insert(projects[selected].id)
            savedPicker = .agents(selected)
            savedSelected = row
            session.attachAgent(store: launch[0], socket: launch[1], sessionID: id)
            let runtime = projects[selected].recentAgents[row]
            try activate(session, pageName: readableNavigatorText(runtime.title),
                pageIdentity: id, pageIcon: ProviderMarks.image(for: runtime.kind, selected: false),
                pageTarget: NavigatorOutlineItem(kind: .agent,
                    projectID: projects[selected].id, id: id, projectIndex: selected, childIndex: row))
        } else if let id = snapshot.restoreTerminalID, let launch,
                  projects.indices.contains(selected),
                  let row = projects[selected].recentTerminals.firstIndex(where: { $0.id == id }) {
            let session = GraphicalTerminal()
            restoredRuntimes[.terminal(id)] = session
            restoredProjectIDs.insert(projects[selected].id)
            savedPicker = .terminals(selected)
            savedSelected = row
            session.attach(store: launch[0], socket: launch[1], terminalID: id,
                           projectID: projects[selected].id)
            let runtime = projects[selected].recentTerminals[row]
            try activate(session, pageName: readableNavigatorText(runtime.title),
                pageIdentity: id,
                pageTarget: NavigatorOutlineItem(kind: .terminal,
                    projectID: projects[selected].id, id: id, projectIndex: selected, childIndex: row))
        }
        while true {
            if let gate = pendingOpenInCatalogue, let catalogue = gate.take() {
                pendingOpenInCatalogue = nil
                openInCatalogue = catalogue
                openInIcons.retainAvailable(catalogue)
                configureOpenInPane()
                if let requestedPage = pendingOpenInMenuPage {
                    pendingOpenInMenuPage = nil
                    if let pane = activePane, pane.pageIdentity == requestedPage {
                        pane.toggleOpenInMenu(window: window, paneWidth: terminalWidth)
                    }
                }
                dirty = true
            }
            if openInIcons.takeCompleted() {
                configureOpenInPane()
                dirty = true
            }
            if let pending = pendingOpenInLaunch, let result = pending.gate.take() {
                pendingOpenInLaunch = nil
                switch result {
                case .success:
                    if pending.remember {
                        PreferenceStore.shared.set(pending.appID, forKey: openInPreferenceKey)
                        configureOpenInPane()
                    }
                    print("OPEN_IN_OPENED \(pending.appID)")
                case .failure(let error):
                    print("OPEN_IN_REFUSED \(error.localizedDescription)")
                }
                fflush(nil)
                dirty = true
            }
            if composerSubmitRequested {
                composerSubmitRequested = false
                if let choice = composerChoice, let idlePane, idlePane.isComposing,
                   projects.indices.contains(selected), projects[selected].id == choice.projectID {
                    let prompt = idlePane.composedPrompt
                    if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        tw_title(window, "Threading composer - write a brief first")
                    } else {
                        let accounts = choice.identity.provider == .codex
                            ? codexAccounts : claudeAccounts
                        if accounts.contains(choice.identity.handle) {
                            try beginAgent(choice.identity.provider, prompt: prompt,
                                           accountOverride: choice.identity.handle)
                        } else {
                            tw_title(window, "Threading composer - account no longer available")
                        }
                    }
                } else {
                    tw_title(window, "Threading composer - selected project changed")
                }
            }
            if let choice = composerChoice,
               (!projects.indices.contains(selected) || projects[selected].id != choice.projectID) {
                composerChoice = nil
                idlePane?.configure(hasProjects: !projects.isEmpty)
                _ = tw_workspace_editor_focus(window, 0)
                dirty = true
            }
            if let activePane {
                if let adopted = activePane.session.takeInitialViewport() {
                    width = adopted.0 + sidebarWidth
                    height = min(900, adopted.1 + WorkspaceTerminalPane.headerPixelHeight)
                    guard tw_resize(window, Int32(width), Int32(height)) == 0 else {
                        throw WindowFailure(String(cString: tw_error()))
                    }
                    dirty = true
                }
                try activePane.refresh(window: window, width: terminalWidth, height: height,
                                       originX: sidebarWidth, focused: !sidebarFocused)
            } else if let idlePane {
                try idlePane.present(nativeWindow: window, width: terminalWidth,
                                     height: height, originX: sidebarWidth)
            }
            if let gate = pendingFolderImport, let result = gate.take() {
                pendingFolderImport = nil
                switch result {
                case .success(let imported?):
                    projects = imported.projects
                    projectIndexes = Dictionary(uniqueKeysWithValues: projects.enumerated().map { ($0.element.id, $0.offset) })
                    if activePane == nil {
                        composerChoice = nil
                        _ = tw_workspace_editor_focus(window, 0)
                        idlePane?.configure(hasProjects: !projects.isEmpty)
                    }
                    selected = imported.selectedProjectIndex
                    first = 0
                    inlineSelection = nil
                    expandedProjectID = nil
                    outlineNeedsReload = true
                    outlineScrollSelection = true
                    dirty = true
                    print("PROJECT_IMPORTED \(projects[selected].path)"); fflush(nil)
                case .success(nil):
                    print("PROJECT_IMPORT_CANCELLED"); fflush(nil)
                case .failure(let error):
                    print("PROJECT_IMPORT_REFUSED \(error)"); fflush(nil)
                    tw_title(window, "Threading experiment - project import failed")
                }
            }
            let pickerAccounts = accountPicker == .claude ? claudeAccounts : codexAccounts
            // Consume after import installs its snapshot, and after a pending selection has
            // replayed its committed action. Neither operation may observe shifted row indices.
            if pendingFolderImport == nil, pendingSelection == nil,
               reconcileTerminals() { outlineNeedsReload = true; dirty = true }
            if pendingFolderImport == nil, pendingSelection == nil {
                let selection: (projectID: String, agentID: String)?
                if let picker = savedPicker, picker.isAgent,
                   projects[picker.projectIndex].recentAgents.indices.contains(savedSelected) {
                    selection = (projects[picker.projectIndex].id,
                                 projects[picker.projectIndex].recentAgents[savedSelected].id)
                } else if case .some(.agent(_, _, let id)) = inlineSelection,
                          let expandedProjectID {
                    selection = (expandedProjectID, id)
                } else { selection = nil }
                if reconcilePendingAgents(projects: &projects, projectIndexes: projectIndexes,
                                          runtimes: &restoredRuntimes,
                                          pending: &pendingAgentProjects,
                                          publishedCounts: &publishedAgentCounts,
                                          retainedProjects: &restoredProjectIDs, preserving: selection) {
                    if let selection, let project = projectIndexes[selection.projectID],
                       let row = projects[project].recentAgents.firstIndex(where: { $0.id == selection.agentID }) {
                        savedSelected = row
                    }
                    outlineNeedsReload = true
                    dirty = true
                }
            }
            let enabled = pendingFolderImport == nil && pendingSelection == nil
            if actionsEnabled != enabled { actionsEnabled = enabled; dirty = true }
            let visibleRowHeight = actions == nil && accountPicker == nil
                ? navigatorRowStride : ThemedMenuMetrics.rowHeight
            let count = min(Int(TW_NAVIGATOR_MAX_ROWS),
                max(1, Int((CGFloat(height / 2) - navigatorHeaderHeight - 2) / visibleRowHeight)))
            let projectsMode = actions == nil && accountPicker == nil && savedPicker == nil
            if dirty {
                navigatorRoot.prepareNavigatorFrame(NSRect(x: 0, y: 0,
                    width: navigatorWidth / 2, height: height / 2))
                navigatorRoot.setNavigatorOutline(outlineScroll,
                    visible: projectsMode && !projects.isEmpty)
            }
            outlineSource.projects = projects
            outlineSource.projectIndexes = projectIndexes
            func actionMenuIndex(at x: Int32, y: Int32) -> Int? {
                guard let menu = actions, y >= navigatorRowsTop else { return nil }
                let stride = Int32(ThemedMenuMetrics.rowHeight * contentWindow.backingScaleFactor)
                let slot = Int((y - navigatorRowsTop) / stride)
                let index = menu.first + slot
                guard slot >= 0, slot < count, index < menu.commands.count else { return nil }
                guard let row = menuRowPixels(slot, in: navigatorRoot,
                                              scale: contentWindow.backingScaleFactor) else { return nil }
                return x >= row.x && x < row.x + row.width &&
                       y >= row.y && y < row.y + row.height ? index : nil
            }
            if var menu = actions {
                let commands: [HostCommandDescriptor]
                switch menu.kind {
                case .addProject:
                    commands = NavigatorActions.addProjectMenuCommands()
                case .projectActions:
                    commands = NavigatorActions.projectCommands(actionState(for: menu.projectID))
                case .projectCreate:
                    commands = NavigatorActions.projectCreateCommands(actionState(for: menu.projectID))
                case .chatProviders:
                    commands = NavigatorActions.chatProviderCommands(actionState(for: menu.projectID))
                }
                if menu.commands != commands { menu.commands = commands; dirty = true }
                menu.selected = max(0, min(menu.commands.count - 1, menu.selected))
                if menu.selected < menu.first { menu.first = menu.selected }
                if menu.selected >= menu.first + count { menu.first = menu.selected - count + 1 }
                actions = menu
            } else if accountPicker != nil {
                accountSelected = max(0, min(pickerAccounts.count - 1, accountSelected))
                if accountSelected < accountFirst { accountFirst = accountSelected }
                if accountSelected >= accountFirst + count { accountFirst = accountSelected - count + 1 }
            } else if let savedPicker {
                let project = projects[savedPicker.projectIndex]
                let savedCount = savedPicker.isAgent ? project.recentAgents.count : project.recentTerminals.count
                savedSelected = max(0, min(savedCount - 1, savedSelected))
                if savedSelected < savedFirst { savedFirst = savedSelected }
                if savedSelected >= savedFirst + count { savedFirst = savedSelected - count + 1 }
            } else {
                selected = max(0, min(projects.count - 1, selected))
                if let expandedID = expandedProjectID, projectIndexes[expandedID] == nil {
                    expandedProjectID = nil
                }
                let expanded = expandedProjectID.flatMap { projectIndexes[$0] }
                let projection = SidebarVisibleRows(projects: projects,
                    expandedProjectIndex: expanded, first: 0, count: 0)
                let selectedIndex = inlineSelection.flatMap { projection.index(of: $0) }
                    ?? projection.index(of: selected) ?? 0
                if let row = projection.row(at: selectedIndex) { inlineSelection = row }
                if outlineNeedsReload {
                    trace("outline.reload.begin")
                    outline.reloadData()
                    trace("outline.reload.end")
                    outlineNeedsReload = false
                }
                if outlineExpandedProjectID != expandedProjectID {
                    if let old = outlineExpandedProjectID {
                        outline.collapseItem(NavigatorOutlineItem(projectID: old,
                            projectIndex: projectIndexes[old] ?? -1))
                    }
                    if let expandedProjectID, let index = projectIndexes[expandedProjectID] {
                        outline.expandItem(NavigatorOutlineItem(projectID: expandedProjectID,
                            projectIndex: index))
                    }
                    outlineExpandedProjectID = expandedProjectID
                }
                if outline.numberOfRows > 0 {
                    trace("outline.selection.begin")
                    outline.selectRowIndexes(IndexSet(integer: selectedIndex),
                                             byExtendingSelection: false)
                    if outlineScrollSelection {
                        outline.scrollRowToVisible(selectedIndex)
                        outlineScrollSelection = false
                    }
                    trace("outline.selection.end")
                }
                first = outline.visibleRowIndexes.first ?? 0
            }
            let sidebarRows = SidebarVisibleRows(projects: projects,
                expandedProjectIndex: expandedProjectID.flatMap { projectIndexes[$0] },
                first: first, count: count)
            let selectedInlineIndex = inlineSelection.flatMap { sidebarRows.index(of: $0) }
                ?? sidebarRows.index(of: selected) ?? 0
            let presentationDate = Date()
            if let expiry = nextVisibleAttentionExpiry, presentationDate >= expiry {
                dirty = true
            }
            if dirty {
                nextVisibleAttentionExpiry = nil
                let width = navigatorWidth
                trace(traceFirstFrame ? "first-frame.begin" : "frame.begin")
                // At most viewport/count row objects, even for a large persisted catalogue.
                let root = navigatorRoot
                root.prepareNavigatorFrame(NSRect(x: 0, y: 0, width: width / 2, height: height / 2))
                root.separatesScratchpad = actions?.kind == .addProject
                let accent = NSColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 1)
                let selectedInk = Specimen.Ink(on: accent)
                var textRows: [NavigatorTextRow] = []
                textRows.reserveCapacity(count * 3 + 2)
                var menuRows: [NSView] = []
                let end: Int
                if let menu = actions {
                    end = min(menu.commands.count, menu.first + count)
                    let entries: [ThemedMenuEntry] = menu.commands.map { command in
                        .item(ThemedMenuItem(
                            title: readableNavigatorText(command.title),
                            help: command.availability.disabledReason,
                            representedValue: command.id,
                            isEnabled: command.availability.isAvailable
                        ))
                    }
                    let plan = ThemedMenuRowPlan(entries: entries)
                    var top = navigatorHeaderHeight + 2
                    for index in menu.first..<end {
                        guard let row = plan.row(at: index) else {
                            throw WindowFailure("host command was not a menu item")
                        }
                        let rowHeight = plan.heights[index]
                        row.frame = NSRect(x: 6, y: root.bounds.height - top - rowHeight,
                                           width: root.bounds.width - 12, height: rowHeight)
                        row.isKeyboardHighlighted = index == menu.selected
                        row.onChoose = { entry, _ in activatedMenuEntry = entry }
                        row.onHighlight = { entry in
                            guard var current = actions, current.commands.indices.contains(entry),
                                  current.selected != entry else { return }
                            current.selected = entry
                            actions = current
                            dirty = true
                        }
                        menuRows.append(row)
                        top += rowHeight
                    }
                } else if let accountPicker {
                    let provider = accountPicker == .claude ? "Claude" : "Codex"
                    let active = accountPicker == .claude ? claudeAccount : codexAccount
                    end = min(pickerAccounts.count, accountFirst + count)
                    // Discovery admits at most 32 handles. Measure the common check column
                    // once, then materialize only the visible page as native menu rows.
                    let entries: [ThemedMenuEntry] = pickerAccounts.map { handle in
                        let name = handle.isStandard ? "Default \(provider)" :
                            "\(provider) [\(readableNavigatorText(handle.name))]"
                        return .item(ThemedMenuItem(title: name, representedValue: handle,
                                                    isSelected: handle == active))
                    }
                    let plan = ThemedMenuRowPlan(entries: entries)
                    var top = navigatorHeaderHeight + 2
                    for index in accountFirst..<end {
                        guard let row = plan.row(at: index) else {
                            throw WindowFailure("account choice was not a menu item")
                        }
                        let rowHeight = plan.heights[index]
                        row.frame = NSRect(x: 6, y: root.bounds.height - top - rowHeight,
                                           width: root.bounds.width - 12, height: rowHeight)
                        row.isKeyboardHighlighted = index == accountSelected
                        row.onChoose = { _, item in
                            activatedAccountHandle = item.representedValue as? AccountHandle
                        }
                        row.onHighlight = { entry in
                            guard pickerAccounts.indices.contains(entry), accountSelected != entry
                            else { return }
                            accountSelected = entry
                            dirty = true
                        }
                        menuRows.append(row)
                        top += rowHeight
                    }
                } else if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let saved = savedPicker.isAgent ? project.recentAgents : project.recentTerminals
                    end = min(saved.count, savedFirst + count)
                    for index in savedFirst..<end {
                        let runtime = saved[index]
                        let key: SavedRuntimeKey = savedPicker.isAgent ? .agent(runtime.id) : .terminal(runtime.id)
                        let retained = retainedRuntime(for: owner(of: key, projectID: project.id)) != nil
                        if savedPicker.isAgent {
                            let mark = ProviderMarks.image(for: runtime.kind, selected: index == savedSelected)
                            if runtime.attention(at: presentationDate) == .snoozed,
                               let expiry = runtime.snoozedUntil {
                                nextVisibleAttentionExpiry = min(nextVisibleAttentionExpiry ?? expiry, expiry)
                            }
                            addSavedAgentRow(runtime, retained: retained, at: presentationDate,
                                index: index - savedFirst,
                                width: width, height: height, accent: accent,
                                selected: index == savedSelected, selectedInk: selectedInk, root: root,
                                textRows: &textRows, image: mark)
                        } else {
                            addSavedTerminalRow(runtime, running: retained, index: index - savedFirst,
                                width: width, height: height, accent: accent,
                                selected: index == savedSelected, selectedInk: selectedInk, root: root)
                        }
                    }
                } else {
                    if projects.isEmpty, launch != nil {
                        end = 1
                        addNavigatorRow("Add project folder…", index: 0, width: width,
                                        height: height, accent: accent, selected: true,
                                        selectedInk: selectedInk, root: root, textRows: &textRows)
                    } else {
                        // NSOutlineView owns and recycles the viewport's production row views.
                        end = (outline.visibleRowIndexes.last.map { $0 + 1 }) ?? first
                        trace("outline.configure.begin")
                        for index in outline.visibleRowIndexes {
                            guard let item = outline.item(atRow: index) as? NavigatorOutlineItem,
                                  let cell = outline.view(atColumn: 0, row: index,
                                    makeIfNecessary: false) as? Specimen.Row else { continue }
                            configureOutlineRow(cell, item: item, frame: outline.rect(ofRow: index))
                            if let chrome = outline.rowView(atRow: index,
                                makeIfNecessary: false) as? SidebarHoverRowView {
                                configureOutlineChrome(chrome, in: outline)
                            }
                        }
                        trace("outline.configure.end")
                    }
                }
                let nextHeaderTitle = actions.map { menu in
                    switch menu.kind {
                    case .addProject: return "Add Project"
                    case .projectActions: return "Actions"
                    case .projectCreate: return "New in Project"
                    case .chatProviders: return "New Chat"
                    }
                } ?? accountPicker.map { $0 == .claude ? "Claude login" : "Codex login" }
                    ?? savedPicker.map { $0.isAgent ? "Agents" : "Terminals" } ?? "Projects"
                if headerTitle.stringValue != nextHeaderTitle {
                    headerTitle.stringValue = nextHeaderTitle
                }
                root.title = ""
                if addProjectButton.isHidden != (launch == nil) {
                    addProjectButton.isHidden = launch == nil
                }
                addProjectButton.isEnabled = actionsEnabled && accountPicker == nil && savedPicker == nil
                if actionsButton.isHidden != (launch == nil) {
                    actionsButton.isHidden = launch == nil
                }
                actionsButton.isEnabled = actionsEnabled
                actionsButton.isSelected = actions != nil
                actionsButton.setAccessibilityTitle(actions == nil ? "Actions" : "Close actions")
                trace("header.layout.begin")
                publishHeaderGeometry()
                trace("header.layout.end")
                let titleRect = headerPixels(headerTitle)
                let addRect = headerPixels(addProjectButton)
                let actionsRect = headerPixels(actionsButton)
                trace("header bandHeight=\(navigatorHeaderHeight) title=\(titleRect) add=\(addRect) actions=\(actionsRect)")
                let mountStarted = DispatchTime.now().uptimeNanoseconds
                try mountNavigatorText(textRows, in: root)
                root.mountMenuRows(menuRows)
                let focusedSlot: Int
                if let menu = actions { focusedSlot = menu.selected - menu.first }
                else if accountPicker != nil { focusedSlot = accountSelected - accountFirst }
                else if savedPicker != nil { focusedSlot = savedSelected - savedFirst }
                else { focusedSlot = selectedInlineIndex - first }
                let focusedView: NSView?
                if projectsMode && !projects.isEmpty {
                    focusedView = outline.view(atColumn: 0, row: selectedInlineIndex,
                                               makeIfNecessary: false)
                } else {
                    focusedView = root.mountedRow(at: focusedSlot)
                }
                contentWindow.makeFirstResponder(sidebarFocused && accountPicker == nil
                    ? focusedView : nil)
                let mountMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - mountStarted) / 1_000_000
                trace("raster.begin")
                let bitmap = Bitmap(width: navigatorWidth, height: height,
                                    background: LinuxTheme.components("surface"))
                let context = NSGraphicsContext(bitmap: bitmap, scale: 2)
                NSGraphicsContext.current = context
                let renderStarted = DispatchTime.now().uptimeNanoseconds
                root.render(in: context)
                _ = root.takeProjectControlVisualChange()
                addProjectControlVisualChanged = false
                actionsControlVisualChanged = false
                let renderMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - renderStarted) / 1_000_000
                NSGraphicsContext.current = nil
                trace("raster.end")
                print("NAVIGATOR_TEXT mounted=\(textRows.count) mountMs=\(mountMilliseconds) renderMs=\(renderMilliseconds)")
                trace("present.begin")
                let result = bitmap.pixels.withUnsafeBufferPointer {
                    hasSplitPane
                        ? tw_present_pane(window, $0.baseAddress,
                                          Int32(navigatorWidth), Int32(height), 1)
                        : tw_present(window, $0.baseAddress, Int32(width), Int32(height))
                }
                trace("present.end")
                guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
                trace("accessibility-title.begin")
                if let menu = actions {
                    let listY = Int32(navigatorHeaderHeight * 2)
                    let listTitle: String
                    switch menu.kind {
                    case .addProject: listTitle = "Add Project"
                    case .projectActions: listTitle = "Project actions"
                    case .projectCreate: listTitle = "New in Project"
                    case .chatProviders: listTitle = "New Chat providers"
                    }
                    tw_accessibility_begin_list(window,
                        listTitle, Int32(menu.first),
                        Int32(menu.commands.count), 1, 0, listY, Int32(navigatorWidth), Int32(height) - listY)
                    for index in menu.first..<end {
                        let command = menu.commands[index]
                        let label = command.title + (command.availability.disabledReason.map { ". " + $0 } ?? "")
                        guard let bounds = menuRowPixels(index - menu.first, in: root,
                                                         scale: contentWindow.backingScaleFactor) else {
                            throw WindowFailure("accessible menu command has no mounted row")
                        }
                        let result = command.id.withCString { identifier in
                            label.withCString { name in
                                tw_accessibility_add_action_row(window, identifier, name,
                                    index == menu.selected ? 1 : 0, command.availability.isAvailable ? 1 : 0,
                                    bounds.x, bounds.y, bounds.width, bounds.height)
                            }
                        }
                        guard result == 0 else { throw WindowFailure("native action row exceeds its bound") }
                    }
                    tw_accessibility_end_list(window)
                    let target = menu.projectID.flatMap { projectIndexes[$0.uuidString] }
                    let targetPath = target.flatMap { projects.indices.contains($0) ? projects[$0].path : nil }
                        ?? "No project"
                    switch menu.kind {
                    case .addProject: setNavigatorTitle("Threading Add Project")
                    case .projectActions: setNavigatorTitle("Threading actions - " + targetPath)
                    case .projectCreate: setNavigatorTitle("Threading new in - " + targetPath)
                    case .chatProviders: setNavigatorTitle("Threading new chat - " + targetPath)
                    }
                    let frameLabel: String
                    switch menu.kind {
                    case .addProject: frameLabel = "ADD_PROJECT_MENU_FRAME"
                    case .projectActions: frameLabel = "ACTIONS_FRAME"
                    case .projectCreate: frameLabel = "PROJECT_CREATE_MENU_FRAME"
                    case .chatProviders: frameLabel = "CHAT_PROVIDER_MENU_FRAME"
                    }
                    print("\(frameLabel) mounted=\(end - menu.first) selected=\(menu.commands[menu.selected].id) total=\(menu.commands.count)")
                } else if let accountPicker {
                    let provider = accountPicker == .claude ? "Claude" : "Codex"
                    let active = accountPicker == .claude ? claudeAccount : codexAccount
                    let listY = Int32(navigatorHeaderHeight * 2)
                    tw_accessibility_begin_list(window, "\(provider) accounts", Int32(accountFirst),
                                                Int32(pickerAccounts.count), 1, 0, listY,
                                                Int32(navigatorWidth), Int32(height) - listY)
                    for index in accountFirst..<end {
                        let handle = pickerAccounts[index]
                        let name = handle.isStandard ? "Default \(provider)" : "\(provider) \(handle.name)"
                        let label = name + (handle == active ? " active" : "")
                        guard let bounds = menuRowPixels(index - accountFirst, in: root,
                                                         scale: contentWindow.backingScaleFactor)
                        else { throw WindowFailure("accessible account has no mounted row") }
                        let result = handle.name.withCString { identifier in
                            label.withCString { text in
                                tw_accessibility_add_row(window, identifier, text,
                                    index == accountSelected ? 1 : 0,
                                    bounds.x, bounds.y, bounds.width, bounds.height)
                            }
                        }
                        guard result == 0 else {
                            throw WindowFailure("native account row exceeds its bound")
                        }
                    }
                    tw_accessibility_end_list(window)
                    setNavigatorTitle("Threading \(provider) accounts - \(projects[selected].path)")
                    print("ACCOUNT_PICKER_FRAME \(width)x\(height) provider=\(provider.lowercased()) mounted=\(end - accountFirst) selected=\(pickerAccounts[accountSelected].name) total=\(pickerAccounts.count)")
                } else if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let saved = savedPicker.isAgent ? project.recentAgents : project.recentTerminals
                    let total = savedPicker.isAgent ? project.sessions : project.terminalCount
                    let listName = "Saved \(savedPicker.isAgent ? "agents" : "terminals") (\(saved.count) of \(total))"
                    let listY = Int32(navigatorHeaderHeight * 2)
                    listName.withCString {
                        tw_accessibility_begin_list(window, $0, Int32(savedFirst), Int32(saved.count),
                                                    launch == nil ? 0 : 1, 0, listY,
                                                    Int32(navigatorWidth), Int32(height) - listY)
                    }
                    for index in savedFirst..<end {
                        let runtime = saved[index]
                        let key: SavedRuntimeKey = savedPicker.isAgent ? .agent(runtime.id) : .terminal(runtime.id)
                        let retained = retainedRuntime(for: owner(of: key, projectID: project.id)) != nil
                        let provider = runtime.kind.map { "[\($0.displayName)] " } ?? ""
                        let account = runtime.account.map { " [\($0)]" } ?? ""
                        let title = boundedAccessibilityLabel(runtime.title,
                            maximumBytes: 400 - provider.utf8.count - account.utf8.count)
                        let label = "\(provider)\(title)\(account) [\(String(runtime.id.prefix(8)))]\(retained ? " retained" : "")"
                            + (runtime.attentionTitle(at: presentationDate).map { " " + $0 } ?? "")
                        try publishAccessibleRow(window, id: runtime.id, label: label,
                                                 selected: index == savedSelected,
                                                 visibleIndex: index - savedFirst, width: width, height: height)
                    }
                    tw_accessibility_end_list(window)
                    setNavigatorTitle("Threading \(savedPicker.isAgent ? "agents" : "terminals") - \(project.path)")
                    let selectedID = saved.isEmpty ? "none" : saved[savedSelected].id
                    let capped = total > saved.count ? 1 : 0
                    let label = savedPicker.isAgent ? "AGENT_PICKER_FRAME" : "TERMINAL_PICKER_FRAME"
                    print("\(label) \(width)x\(height) mounted=\(end - savedFirst) selected=\(selectedID) total=\(total) capped=\(capped)")
                } else {
                    let listY = Int32(navigatorHeaderHeight * 2)
                    let hasAddRow = projects.isEmpty && launch != nil
                    tw_accessibility_begin_list(window, "Projects", Int32(first),
                                                Int32(hasAddRow ? 1 : sidebarRows.totalCount),
                                                launch == nil ? 0 : 1, 0, listY,
                                                Int32(navigatorWidth), Int32(height) - listY)
                    if hasAddRow {
                        try publishAccessibleRow(window, id: "add-project", label: "Add project folder",
                                                 selected: true, visibleIndex: 0,
                                                 width: width, height: height)
                    } else {
                        for index in first..<end {
                            guard let item = outline.item(atRow: index) as? NavigatorOutlineItem,
                                  let row = item.resolvedRow(in: projects, indexes: projectIndexes)
                            else { continue }
                            let isSelected = index == selectedInlineIndex
                            switch row {
                            case .project(let projectIndex, _):
                                let project = projects[projectIndex]
                                let retained = terminals[project.id] != nil || restoredProjectIDs.contains(project.id)
                                let label = "\(boundedAccessibilityLabel(project.name)) [\(project.sessions) agents, \(project.terminalCount) terminals]\(retained ? " retained" : "")"
                                if launch == nil {
                                    try publishOutlineAccessibleRow(index, id: project.id,
                                        label: label, selected: isSelected)
                                } else {
                                    guard let bounds = outlineRowPixels(index) else {
                                        throw WindowFailure("mounted project row has no visible layout")
                                    }
                                    if let create = projectControlPixels(index, create: true),
                                       let action = projectControlPixels(index, create: false) {
                                        let result = project.id.withCString { identifier in
                                            label.withCString { name in
                                                tw_accessibility_add_project_row(window, identifier, name,
                                                    isSelected ? 1 : 0,
                                                    bounds.x, bounds.y, bounds.width, bounds.height,
                                                    create.x, create.y, create.width, create.height,
                                                    action.x, action.y, action.width, action.height,
                                                    actionsEnabled ? 1 : 0)
                                            }
                                        }
                                        guard result == 0 else {
                                            throw WindowFailure("native project action row exceeds its bound")
                                        }
                                    } else if bounds.height < Int32(SidebarDefaults.projectCompactRowHeight *
                                        contentWindow.backingScaleFactor) {
                                        // The clipped edge can show a sliver of the row before
                                        // either control is visible. Keep the row accessible.
                                        try publishOutlineAccessibleRow(index, id: project.id,
                                            label: label, selected: isSelected)
                                    } else {
                                        throw WindowFailure("mounted project controls have no layout")
                                    }
                                }
                            case .agent(let projectIndex, let childIndex, _):
                                let project = projects[projectIndex]
                                let runtime = project.recentAgents[childIndex]
                                let retained = retainedRuntime(for: owner(of: .agent(runtime.id),
                                    projectID: project.id)) != nil
                                let provider = runtime.kind.map { "[\($0.displayName)] " } ?? ""
                                let account = runtime.account.map { " [\($0)]" } ?? ""
                                let title = boundedAccessibilityLabel(runtime.title,
                                    maximumBytes: 400 - provider.utf8.count - account.utf8.count)
                                let label = "\(provider)\(title)\(account) [\(String(runtime.id.prefix(8)))]\(retained ? " retained" : "")"
                                    + (runtime.attentionTitle(at: presentationDate).map { " " + $0 } ?? "")
                                try publishOutlineAccessibleRow(index, id: runtime.id,
                                    label: label, selected: isSelected, indent: 16)
                            case .terminal(let projectIndex, let childIndex, _):
                                let project = projects[projectIndex]
                                let runtime = project.recentTerminals[childIndex]
                                let retained = retainedRuntime(for: owner(of: .terminal(runtime.id),
                                    projectID: project.id)) != nil
                                let label = "\(runtime.identityTitle) [\(String(runtime.id.prefix(8)))]\(retained ? " retained" : "")"
                                try publishOutlineAccessibleRow(index, id: runtime.id,
                                    label: label, selected: isSelected, indent: 16)
                            }
                        }
                    }
                    tw_accessibility_end_list(window)
                    let title = projects.isEmpty ? "Threading experiment - empty store" : "Threading experiment - \(projects[selected].path)"
                    setNavigatorTitle(title)
                    print("FRAME \(width)x\(height) mounted=\(end - first) selected=\(projects.isEmpty ? "none" : projects[selected].id) total=\(sidebarRows.totalCount)")
                    if !projects.isEmpty {
                        print("OUTLINE_FRAME total=\(outline.numberOfRows) first=\(first) visible=\(end - first) mounted=\(outline.mountedViewCount) reusable=\(outline.reusableViewCount) scrollY=\(outlineScroll.contentView.bounds.minY)")
                    }
                }
                trace("accessibility-title.end")
                traceFirstFrame = false
                fflush(nil)
                dirty = false
            }
            var event = TWEvent()
            var selectionWasCommitted = false
            var pointerActivatedRow = false
            if let pending = pendingSelection {
                if let result = pending.gate.take() {
                    pendingSelection = nil
                    switch result {
                    case .success:
                        event = pending.event
                        selectionWasCommitted = true
                    case .failure(let error):
                        print("SELECTION_REFUSED \(error)"); fflush(nil)
                        if !pending.continuesOnRefusal {
                            tw_title(window, "Threading experiment - could not save runtime selection")
                            continue
                        }
                        // A new shell still owns its launch result. It can report the store
                        // refusal on the existing unavailable surface instead of hiding it
                        // at the project picker. Reusing a runtime requires a durable clear.
                        event = pending.event
                        selectionWasCommitted = true
                    }
                } else {
                    if tw_next_timeout(window, &event, 33) == 1 {
                        if event.kind == 5 { return }
                        if event.kind == 1 {
                            try updateSurface(event)
                        }
                        if event.kind == 24 { focusSidebar(event.action == 1) }
                        // Persistence freezes navigation decisions, not the visible child's input.
                        _ = routeTerminalInput(event)
                    }
                    continue
                }
            } else if pendingFolderImport != nil {
                if tw_next_timeout(window, &event, 33) == 1 {
                    if event.kind == 5 { return }
                    if event.kind == 1 {
                        try updateSurface(event)
                    }
                    if event.kind == 24 { focusSidebar(event.action == 1) }
                    _ = routeTerminalInput(event)
                }
                continue
            } else {
                // A creation can finish after the user returned from its starting terminal.
                // Poll only while one of at most eight runtimes owes an admission publication.
                let awaitingCreation = terminals.values.contains { $0.hasPendingTerminalCreation }
                    || restoredRuntimes.values.contains { $0.hasPendingAgentCreation }
                let pollsRuntime = awaitingCreation || activePane?.needsPolling == true
                    || pendingOpenInCatalogue != nil || pendingOpenInLaunch != nil
                    || openInIcons.isLoading
                // A picker without a terminal still owes a deadline update. Sleep until that
                // expiry (at most one second to recheck wall-clock changes), while the bridge
                // keeps servicing accessibility without returning to the Swift loop every 33ms.
                let expiryWait = nextVisibleAttentionExpiry.map {
                    Int32(max(1, min(1_000, ceil($0.timeIntervalSinceNow * 1_000))))
                }
                let timeout: Int32? = pollsRuntime ? 33 : expiryWait
                let received = timeout.map { tw_next_timeout(window, &event, $0) }
                    ?? tw_next(window, &event)
                if timeout != nil, received == 0 { continue }
                guard received == 1 else {
                    throw WindowFailure(String(cString: tw_error()))
                }
            }
            trace("event kind=\(event.kind) action=\(event.action)")
            let windowIsKey = tw_window_has_focus(window) != 0
            if contentWindow.isKeyWindow != windowIsKey {
                contentWindow.isKeyWindow = windowIsKey
                if !windowIsKey { contentWindow.cancelPointerGesture() }
                for index in outline.visibleRowIndexes {
                    guard let chrome = outline.rowView(atRow: index,
                        makeIfNecessary: false) as? SidebarHoverRowView else { continue }
                    chrome.isEmphasized = windowIsKey
                }
                dirty = true
            }
            if event.kind == 45 { continue }
            if event.kind == 44 {
                if event.action == 0 {
                    LinuxTheme.setDark(!LinuxTheme.isDark)
                    navigatorRoot.setThemeAppearance()
                    headerTitle.textColor = navigatorRoot.headerInk.label
                    idlePane?.setThemeAppearance()
                    activePane?.setThemeAppearance()
                    dirty = true
                    print("THEME_APPEARANCE \(LinuxTheme.isDark ? "dark" : "light")")
                    fflush(nil)
                } else if let pane = activePane {
                    var identityEvent = event
                    let identity = String(validatingCString: tw_event_text(&identityEvent)) ?? ""
                    if identity == pane.pageIdentity {
                        focusSidebar(false)
                        if event.action == 1 { _ = pane.pressOpenInAction() }
                        if event.action == 2 { _ = pane.pressOpenInChooser() }
                        drainOpenInRequests(pane)
                        dirty = true
                    }
                }
                continue
            }
            if let button = dismissedActionGesture {
                if event.kind == 17 { continue }
                if event.kind == 15, event.key == button, event.action == 3 {
                    dismissedActionGesture = nil
                    continue
                }
            }
            if event.kind == 26 { continue }
            if event.kind == 25, launch != nil {
                contentWindow.cancelPointerGesture()
                if actions != nil { dismissActions() }
                else { openActions(for: nil, returnToSidebar: event.action == 1) }
                continue
            }
            if event.kind == 30, launch != nil {
                openAddProjectMenu()
                continue
            }
            if event.kind == 28, launch != nil {
                contentWindow.cancelPointerGesture()
                let slot = Int(event.key)
                let index = first + slot
                guard actions == nil, accountPicker == nil, savedPicker == nil,
                      slot >= 0, slot < outline.visibleRowIndexes.count,
                      case .some(.project(_, let projectID)) = sidebarRows.row(at: index),
                      let id = String(validatingCString: tw_event_text(&event)),
                      projectID == id, let target = ProjectID(uuidString: id)
                else { continue }
                openActions(for: target, returnToSidebar: true)
                continue
            }
            if event.kind == 33, launch != nil {
                contentWindow.cancelPointerGesture()
                let slot = Int(event.key)
                let index = first + slot
                guard actions == nil, accountPicker == nil, savedPicker == nil,
                      slot >= 0, slot < outline.visibleRowIndexes.count,
                      case .some(.project(let projectIndex, let projectID)) = sidebarRows.row(at: index),
                      let id = String(validatingCString: tw_event_text(&event)),
                      projectID == id, let target = ProjectID(uuidString: id)
                else { continue }
                selected = projectIndex
                openProjectCreateMenu(for: target, returnToSidebar: sidebarFocused)
                continue
            }
            if event.kind == 29, launch != nil {
                contentWindow.cancelPointerGesture()
                guard actions == nil, accountPicker == nil, savedPicker == nil,
                      projects.indices.contains(selected),
                      let target = ProjectID(uuidString: projects[selected].id)
                else { continue }
                openActions(for: target, returnToSidebar: true)
                continue
            }
            if event.kind == 27 {
                if event.action == 6 {
                    // One native motion leaves the idle pane and enters the navigator.
                    // Clear its retained hover before delivering that same motion to the row.
                    idlePane?.cancelHover()
                    dirty = true
                }
                if event.action == 4 {
                    contentWindow.cancelPointerGesture()
                    _ = navigatorRoot.takeActivatedRowSlot()
                    _ = navigatorRoot.takeActivatedProjectActionID()
                    _ = navigatorRoot.takeActivatedProjectCreateID()
                    activatedOutlineItem = nil
                    activatedOutlineProjectActionID = nil
                    activatedOutlineProjectCreateID = nil
                    activatedAccountHandle = nil
                    rowActionMenuGesture = false
                    rowActionMenuEntered = false
                    if hoveredProjectID != nil {
                        hoveredProjectID = nil; dirty = true
                    }
                    dirty = true
                    continue
                }
                // Row hover uses the outline's indexed offset lookup and one geometry check;
                // a pointer move never scans a stored catalogue or builds hidden controls.
                var pointerProjectID: String?
                if actions == nil, accountPicker == nil, savedPicker == nil,
                   launch != nil, let index = outlineRowIndex(at: event),
                   let item = outline.item(atRow: index) as? NavigatorOutlineItem,
                   item.kind == .project,
                   let row = outlineRowPixels(index) {
                    if event.x >= row.x, event.x < row.x + row.width,
                       event.y >= row.y, event.y < row.y + row.height {
                        pointerProjectID = item.projectID
                    }
                }
                if hoveredProjectID != pointerProjectID {
                    hoveredProjectID = pointerProjectID
                    dirty = true
                }
                let eventType: NSEvent.EventType
                switch event.action {
                case 1: eventType = .leftMouseDown
                case 2: eventType = .leftMouseDragged
                case 3: eventType = .leftMouseUp
                case 5: eventType = .rightMouseDown
                default: eventType = .mouseMoved
                }
                let point = NSPoint(x: CGFloat(event.x) / contentWindow.backingScaleFactor,
                    y: navigatorRoot.bounds.height - CGFloat(event.y) / contentWindow.backingScaleFactor)
                if event.action == 1 {
                    activatedOutlineItem = nil
                    activatedOutlineProjectActionID = nil
                    activatedOutlineProjectCreateID = nil
                }
                _ = contentWindow.dispatchToContent(NSEvent(type: eventType,
                                                              locationInWindow: point))
                if event.action == 3, let chosen = activatedMenuEntry,
                   var menu = actions, menu.commands.indices.contains(chosen) {
                    activatedMenuEntry = nil
                    menu.selected = chosen
                    actions = menu
                    dirty = true
                    event.kind = 8
                }
                if event.action == 3, let handle = activatedAccountHandle {
                    activatedAccountHandle = nil
                    if accountPicker != nil, let index = pickerAccounts.firstIndex(of: handle) {
                        accountSelected = index
                        dirty = true
                        event.kind = 8
                    }
                }
                if navigatorRoot.takeProjectControlVisualChange() { dirty = true }
                if addProjectControlVisualChanged {
                    addProjectControlVisualChanged = false
                    dirty = true
                }
                if actionsControlVisualChanged {
                    actionsControlVisualChanged = false
                    dirty = true
                }
                if addProjectActivated {
                    addProjectActivated = false
                    openAddProjectMenu()
                    continue
                }
                if actionsActivated {
                    actionsActivated = false
                    if actions != nil { dismissActions() }
                    else { openActions(for: nil, returnToSidebar: sidebarFocused) }
                    continue
                }
                let wasSidebarFocused = sidebarFocused
                let activatedCreate = activatedOutlineProjectCreateID
                    ?? navigatorRoot.takeActivatedProjectCreateID()
                let activatedProject = activatedOutlineProjectActionID
                    ?? navigatorRoot.takeActivatedProjectActionID()
                activatedOutlineProjectCreateID = nil
                activatedOutlineProjectActionID = nil
                let activatedRow = navigatorRoot.takeActivatedRowSlot()
                let activatedOutlineRow = activatedOutlineItem.flatMap {
                    let index = outline.row(forItem: $0)
                    return index >= 0 ? index : nil
                }
                let pointerPixel = NSPoint(x: CGFloat(event.x), y: CGFloat(event.y))
                if event.action == 5 {
                    // A project row and its trailing icon share one exact-target menu, as on
                    // Mac. The right press has no selection effect and Shift+F10 remains its
                    // keyboard route. Resolve only the visible row hit above, then recheck
                    // identity before opening the host-owned command surface.
                    guard let id = pointerProjectID,
                          let index = projectIndexes[id], projects.indices.contains(index),
                          projects[index].id == id, let target = ProjectID(uuidString: id)
                    else { continue }
                    openActions(for: target, returnToSidebar: sidebarFocused)
                    continue
                }
                if rowActionMenuGesture && event.action == 2 {
                    if !rowActionMenuSource.contains(pointerPixel),
                       let index = actionMenuIndex(at: event.x, y: event.y),
                       var menu = actions {
                        rowActionMenuEntered = true
                        if menu.selected != index {
                            menu.selected = index; actions = menu; dirty = true
                        }
                    }
                    continue
                }
                if rowActionMenuGesture && event.action == 3 {
                    let chosen = rowActionMenuEntered &&
                        !rowActionMenuSource.contains(pointerPixel)
                        ? actionMenuIndex(at: event.x, y: event.y) : nil
                    rowActionMenuGesture = false
                    rowActionMenuEntered = false
                    if let chosen, var menu = actions,
                       let target = menu.projectID,
                       let targetIndex = projectIndexes[target.uuidString],
                       projects.indices.contains(targetIndex),
                       projects[targetIndex].id == target.uuidString {
                        menu.selected = chosen
                        actions = menu
                        dirty = true
                        event.kind = 8 // Reuse the menu's exact-project command admission.
                    } else { continue }
                }
                if event.kind == 8 {
                    // A held press that entered the menu is completed by its release below.
                } else if event.action == 1 {
                    if activePane != nil { focusSidebar(true) }
                    if let activatedCreate, let target = ProjectID(uuidString: activatedCreate),
                       pointerProjectID == activatedCreate {
                        openProjectCreateMenu(for: target, returnToSidebar: wasSidebarFocused)
                        if actions?.projectID == target {
                            if let rowIndex = outlineRowIndex(at: event),
                               let source = projectControlPixels(rowIndex, create: true) {
                                rowActionMenuSource = NSRect(
                                    x: CGFloat(source.x), y: CGFloat(source.y),
                                    width: CGFloat(source.width), height: CGFloat(source.height))
                                rowActionMenuGesture = true
                            }
                        }
                        continue
                    }
                    if let activatedProject, let target = ProjectID(uuidString: activatedProject),
                       pointerProjectID == activatedProject {
                        openActions(for: target, returnToSidebar: true)
                        if actions?.projectID == target {
                            if let rowIndex = outlineRowIndex(at: event),
                               let source = projectControlPixels(rowIndex, create: false) {
                                rowActionMenuSource = NSRect(
                                    x: CGFloat(source.x), y: CGFloat(source.y),
                                    width: CGFloat(source.width), height: CGFloat(source.height))
                                rowActionMenuGesture = true
                            }
                        }
                        continue
                    }
                    if let pressedRow = activatedOutlineRow.map({ $0 - first }) ?? activatedRow {
                        pendingMountedRowSlot = pressedRow
                        pointerActivatedRow = true
                        event.kind = 2
                        event.action = 0
                    } else { continue }
                } else { continue }
            }
            if var menu = actions {
                switch event.kind {
                case 5: return
                case 1: try updateSurface(event); continue
                case 12, 11, 24:
                    dismissActions(); continue
                case 3, 4:
                    guard event.action == 1 || sidebarFocused else { continue }
                    let step = event.kind == 3 ? -1 : 1
                    menu.selected = max(0, min(menu.commands.count - 1, menu.selected + step))
                    actions = menu; dirty = true; continue
                case 2:
                    if let index = actionMenuIndex(at: event.x, y: event.y) {
                        menu.selected = index
                        actions = menu; dirty = true
                        if event.action == 1 { continue }
                    } else { dismissActions(); continue }
                case 8: break
                case 15:
                    if event.action == 1 { dismissedActionGesture = event.key; dismissActions() }
                    continue
                case 37, 38, 39, 40:
                    dismissActions(returnToParent: false)
                    _ = routeTerminalInput(event)
                    continue
                default: continue
                }
                guard let command = NavigatorActions.Command(rawValue: menu.commands[menu.selected].id) else { continue }
                switch NavigatorActions.invoke(command, projectID: menu.projectID,
                                               state: { actionState(for: menu.projectID) }) {
                case .refused(_, let reason):
                    tw_title(window, "Threading actions - " + reason)
                    print("ACTION_REFUSED \(command.rawValue) \(reason)"); fflush(nil)
                    continue
                case .invoked:
                    if menu.kind == .projectCreate, command == .newChat,
                       let target = menu.projectID {
                        openChatProvidersMenu(for: target,
                            returnToSidebar: menu.returnToSidebar)
                        continue
                    }
                    if menu.kind == .chatProviders, !menu.returnToSidebar,
                       (command == .newCodex || command == .newClaude) {
                        pendingComposerProjectID = menu.projectID?.uuidString
                    }
                    if ![.addProject, .newProject, .newScratchpad].contains(command),
                       let target = menu.projectID,
                       let targetIndex = projectIndexes[target.uuidString],
                       projects.indices.contains(targetIndex),
                       projects[targetIndex].id == target.uuidString {
                        // Opening a row menu leaves selection in place. Taking a project
                        // command then makes that exact project the existing operation target.
                        selected = targetIndex
                        inlineSelection = .project(projectIndex: targetIndex, id: projects[targetIndex].id)
                        dirty = true
                    }
                    dismissActions(returnToParent: false)
                    accountPicker = nil; savedPicker = nil
                    focusSidebar(true)
                    event = TWEvent(); event.kind = command.eventKind
                }
            }
            // Shortcut and menu entry points share the production availability gate before the
            // existing operation below owns persistence, exact identity and process launch.
            if !selectionWasCommitted, accountPicker == nil, savedPicker == nil,
               let command = (event.kind == 8 && projects.isEmpty ? NavigatorActions.Command.addProject
                    : NavigatorActions.Command.allCases.first(where: { $0.eventKind == event.kind })),
               launch != nil {
                switch NavigatorActions.invoke(command, projectID: actionState().projectID,
                                               state: { actionState() }) {
                case .invoked: break
                case .refused(_, let reason):
                    pendingComposerProjectID = nil
                    tw_title(window, "Threading experiment - " + reason)
                    print("ACTION_REFUSED \(command.rawValue) \(reason)"); fflush(nil)
                    continue
                }
            }
            if event.kind == 24 {
                // The same command first focuses navigation, then opens its folder action.
                // Preserve import access after a terminal occupies the adjacent pane.
                if event.action == 1, sidebarFocused, accountPicker == nil,
                   savedPicker == nil, let launch {
                    pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1])
                } else {
                    focusSidebar(event.action == 1)
                    if event.action == 0, idlePane?.isComposing == true {
                        idlePane?.focusEditor()
                        _ = tw_workspace_editor_focus(window, 1)
                    }
                }
                continue
            }
            if routeTerminalInput(event) { continue }
            switch event.kind {
            case 5: return
            case 12:
                if let idlePane, idlePane.hasOpenComposerChoice,
                   idlePane.handleComposerChoiceKey(NSEvent(type: .keyDown,
                       keyCode: 53, charactersIgnoringModifiers: "")) {
                    dirty = true
                    continue
                }
                if accountPicker != nil {
                    accountPicker = nil
                    dirty = true
                } else if savedPicker != nil {
                    savedPicker = nil
                    dirty = true
                } else if activePane != nil {
                    focusSidebar(false)
                } else if idlePane?.isComposing == true {
                    composerChoice = nil
                    idlePane?.configure(hasProjects: !projects.isEmpty)
                    _ = tw_workspace_editor_focus(window, 0)
                    focusSidebar(true)
                    dirty = true
                } else { return }
            case 1:
                try updateSurface(event)
            case 2:
                let listFirst = accountPicker != nil ? accountFirst : (savedPicker == nil ? first : savedFirst)
                let listCount: Int
                if accountPicker != nil {
                    listCount = pickerAccounts.count
                } else if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    listCount = savedPicker.isAgent ? project.recentAgents.count : project.recentTerminals.count
                } else { listCount = projects.isEmpty && launch != nil ? 1 : sidebarRows.totalCount }
                let visibleCount = projectsMode && !projects.isEmpty
                    ? outline.visibleRowIndexes.count : max(0, min(listCount - listFirst, count))
                let pressedSlot = event.action == 1 ? Int(event.key) : mountedRowPressed(by: event)
                activatedOutlineItem = nil
                if let mounted = pressedSlot, mounted >= 0, mounted < visibleCount {
                    if projects.isEmpty, let launch, accountPicker == nil, savedPicker == nil {
                        if event.action != 1 {
                            pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1])
                        }
                        break
                    }
                    let candidate = listFirst + mounted
                    if accountPicker != nil { accountSelected = candidate }
                    else if savedPicker != nil { savedSelected = candidate }
                    else if let row = sidebarRows.row(at: candidate) {
                        inlineSelection = row
                        switch row {
                        case .project(let projectIndex, let projectID):
                            selected = projectIndex
                            let project = projects[projectIndex]
                            let hasChildren = !project.recentAgents.isEmpty || !project.recentTerminals.isEmpty
                            // The disclosure is the first glyph in the shared project's title.
                            let disclosureX = Int32((6 + SidebarRowDefaults.leadingInset
                                + SidebarRowDefaults.iconSlotWidth + SidebarRowDefaults.horizontalSpacing) * 2)
                            if pointerActivatedRow, hasChildren,
                               event.x >= disclosureX, event.x < disclosureX + 20 {
                                expandedProjectID = expandedProjectID == projectID ? nil : projectID
                            }
                        case .agent(let projectIndex, _, _), .terminal(let projectIndex, _, _):
                            selected = projectIndex
                        }
                    }
                    trace("selection index=\(candidate)")
                    dirty = true
                }
            case 8:
                guard let launch else { break }
                if projects.isEmpty {
                    pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1])
                    break
                }
                if let pickerKind = accountPicker {
                    if pickerKind == .claude {
                        claudeAccount = pickerAccounts[accountSelected]
                    } else {
                        codexAccount = pickerAccounts[accountSelected]
                    }
                    accountPicker = nil
                    dirty = true
                    break
                }
                let inlineRuntime: (picker: SavedPicker, index: Int)?
                switch sidebarRows.row(at: selectedInlineIndex) {
                case .some(.agent(let projectIndex, let childIndex, _)):
                    inlineRuntime = (.agents(projectIndex), childIndex)
                case .some(.terminal(let projectIndex, let childIndex, _)):
                    inlineRuntime = (.terminals(projectIndex), childIndex)
                default:
                    inlineRuntime = nil
                }
                if let destination = savedPicker.map({ (picker: $0, index: savedSelected) }) ?? inlineRuntime {
                    let picker = destination.picker
                    let project = projects[picker.projectIndex]
                    let saved = picker.isAgent ? project.recentAgents : project.recentTerminals
                    guard saved.indices.contains(destination.index) else { break }
                    let runtime = saved[destination.index]
                    let key: SavedRuntimeKey = picker.isAgent ? .agent(runtime.id) : .terminal(runtime.id)
                    let session: GraphicalTerminal
                    let mayResume = picker.isAgent && (agentExecutable != nil || claudeExecutable != nil)
                    let mayStartAgain = mayResume || !picker.isAgent
                    let runtimeOwner = owner(of: key, projectID: project.id)
                    let existing = retainedRuntime(for: runtimeOwner)
                    let reuses = existing.map {
                        !(mayStartAgain && $0.canReplace)
                            && !(!picker.isAgent && $0.canReopenSavedTerminal)
                    } ?? false
                    guard reuses || existing != nil
                            || terminals.count + restoredRuntimes.count < maximumOpenRuntimes else {
                        tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                        break
                    }
                    if !selectionWasCommitted {
                        pendingSelection = recordSelection(picker.isAgent ? runtime.id : nil,
                                                           terminalID: picker.isAgent ? nil : runtime.id,
                                                           terminalProjectID: picker.isAgent ? nil : project.id,
                                                           store: launch[0], after: event)
                        break
                    }
                    if reuses, let existing { session = existing }
                    else {
                        existing?.stop()
                        session = GraphicalTerminal()
                        retain(session, for: runtimeOwner)
                        restoredProjectIDs.insert(project.id)
                        if picker.isAgent {
                            if mayResume {
                                session.openAgent(store: launch[0], socket: launch[1], sessionID: runtime.id,
                                    shell: launch[2], codex: agentExecutable, claude: claudeExecutable,
                                    width: terminalWidth,
                                    height: max(1, height - WorkspaceTerminalPane.headerPixelHeight))
                            } else {
                                session.attachAgent(store: launch[0], socket: launch[1], sessionID: runtime.id)
                            }
                        } else {
                            session.openTerminal(store: launch[0], socket: launch[1], terminalID: runtime.id,
                                projectID: project.id, executable: launch[2],
                                arguments: Array(launch.dropFirst(3)), width: terminalWidth,
                                height: max(1, height - WorkspaceTerminalPane.headerPixelHeight))
                        }
                    }
                    try activate(session, pageName: readableNavigatorText(runtime.title),
                        pageIdentity: runtime.id,
                        pageIcon: picker.isAgent
                            ? ProviderMarks.image(for: runtime.kind, selected: false) : nil,
                        pageTarget: NavigatorOutlineItem(kind: picker.isAgent ? .agent : .terminal,
                            projectID: project.id, id: runtime.id,
                            projectIndex: picker.projectIndex, childIndex: destination.index))
                    dirty = true
                    break
                }
                let project = projects[selected]
                guard terminals[project.id] != nil
                        || terminals.count + restoredRuntimes.count < maximumOpenRuntimes else {
                    tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                    break
                }
                if !selectionWasCommitted {
                    pendingSelection = recordSelection(nil,
                                                       terminalID: terminals[project.id]?.terminalID,
                                                       terminalProjectID: project.id,
                                                       store: launch[0], after: event,
                                                       continuesOnRefusal: terminals[project.id] == nil)
                    break
                }
                let session: GraphicalTerminal
                if let existing = terminals[project.id] { session = existing }
                else {
                    guard terminals.count + restoredRuntimes.count < maximumOpenRuntimes else {
                        tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                        break
                    }
                    session = GraphicalTerminal()
                    terminals[project.id] = session
                    session.start(store: launch[0], socket: launch[1], directory: project.path,
                                  executable: launch[2], arguments: Array(launch.dropFirst(3)))
                }
                try activate(session, pageName: project.name, pageIdentity: project.id,
                    pageTarget: NavigatorOutlineItem(projectID: project.id, projectIndex: selected))
                dirty = true
            case 9:
                guard accountPicker == nil, savedPicker == nil, let launch, !projects.isEmpty else { break }
                let project = projects[selected]
                if let existing = terminals[project.id], !existing.canReplace {
                    tw_title(window, "Threading experiment - terminal may still be running")
                    break
                }
                // A failed creation can have persisted just after this loop's reconciliation.
                // Its row must survive discarding the finished surface for an explicit new shell.
                if reconcileTerminals() { dirty = true }
                guard terminals.count + restoredRuntimes.count
                        - (terminals[project.id] == nil ? 0 : 1) < maximumOpenRuntimes else {
                    tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                    break
                }
                if !selectionWasCommitted {
                    pendingSelection = recordSelection(nil, store: launch[0], after: event,
                                                       continuesOnRefusal: true)
                    break
                }
                if let existing = terminals[project.id] {
                    existing.stop()
                    terminals.removeValue(forKey: project.id)
                }
                let session = GraphicalTerminal()
                terminals[project.id] = session
                session.start(store: launch[0], socket: launch[1], directory: project.path,
                              executable: launch[2], arguments: Array(launch.dropFirst(3)))
                try activate(session, pageName: project.name, pageIdentity: project.id,
                    pageTarget: NavigatorOutlineItem(projectID: project.id, projectIndex: selected))
                dirty = true
            case 23:
                guard accountPicker == nil, savedPicker == nil, let launch else { break }
                pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1])
            case 31, 32:
                guard accountPicker == nil, savedPicker == nil, let launch else { break }
                pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1],
                    choice: event.kind == 31 ? .new : .scratchpad)
            case 13, 21:
                let composerTargetID = pendingComposerProjectID
                pendingComposerProjectID = nil
                guard accountPicker == nil, savedPicker == nil, launch != nil,
                      !projects.isEmpty else { break }
                let kind: AgentKind = event.kind == 13 ? .codex : .claude
                if let targetID = composerTargetID,
                   targetID == projects[selected].id, let idlePane {
                    let accounts = kind == .codex ? codexAccounts : claudeAccounts
                    let preferred = kind == .codex ? codexAccount : claudeAccount
                    let handle = accounts.contains(preferred) ? preferred : .standard
                    composerChoice = (targetID, AccountID(provider: kind, handle: handle))
                    idlePane.showComposer(projectName: projects[selected].name,
                        providerName: kind.displayName)
                    refreshComposerChoices()
                    focusSidebar(false)
                    guard tw_workspace_editor_focus(window, 1) == 0 else {
                        throw WindowFailure("native editor focus unavailable")
                    }
                    dirty = true
                    break
                }
                try beginAgent(kind, prompt: nil)
            case 3, 4:
                if event.action == 1, accountPicker == nil, savedPicker == nil,
                   !projects.isEmpty {
                    let scroll = NSEvent(type: .scrollWheel,
                        scrollingDeltaY: event.kind == 3 ? 1 : -1)
                    outlineScroll.scrollWheel(with: scroll)
                    dirty = true
                    break
                }
                guard let step = navigatorStep(for: event) else { break }
                if accountPicker != nil {
                    let next = max(0, min(pickerAccounts.count - 1,
                                          accountSelected + step))
                    if next != accountSelected { accountSelected = next; dirty = true }
                } else if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let savedCount = savedPicker.isAgent ? project.recentAgents.count : project.recentTerminals.count
                    let next = max(0, min(savedCount - 1, savedSelected + step))
                    if next != savedSelected { savedSelected = next; dirty = true }
                } else {
                    let next = max(0, min(sidebarRows.totalCount - 1, selectedInlineIndex + step))
                    if next != selectedInlineIndex, let row = sidebarRows.row(at: next) {
                        inlineSelection = row
                        switch row {
                        case .project(let projectIndex, _),
                             .agent(let projectIndex, _, _),
                             .terminal(let projectIndex, _, _):
                            selected = projectIndex
                        }
                        outlineScrollSelection = true
                        dirty = true
                    }
                }
            case 36:
                guard accountPicker == nil, savedPicker == nil, launch != nil,
                      case .some(.project(let projectIndex, let projectID)) = sidebarRows.row(at: selectedInlineIndex)
                else { break }
                let project = projects[projectIndex]
                guard !project.recentAgents.isEmpty || !project.recentTerminals.isEmpty else { break }
                expandedProjectID = expandedProjectID == projectID ? nil : projectID
                dirty = true
            case 10:
                guard accountPicker == nil, savedPicker == nil, launch != nil,
                      !projects.isEmpty else { break }
                guard !projects[selected].recentTerminals.isEmpty else {
                    tw_title(window, "Threading experiment - no saved terminals")
                    break
                }
                savedPicker = .terminals(selected)
                savedSelected = 0
                savedFirst = 0
                dirty = true
            case 11:
                if accountPicker != nil {
                    accountPicker = nil
                    dirty = true
                } else if savedPicker != nil {
                    savedPicker = nil
                    dirty = true
                } else if launch != nil, !projects.isEmpty {
                    if reconcilePendingAgents(projects: &projects, projectIndexes: projectIndexes,
                                              runtimes: &restoredRuntimes,
                                              pending: &pendingAgentProjects,
                                              publishedCounts: &publishedAgentCounts,
                                              retainedProjects: &restoredProjectIDs) { dirty = true }
                    guard !projects[selected].recentAgents.isEmpty else {
                        let pending = pendingAgentProjects.values.contains {
                            $0.uuidString == projects[selected].id
                        }
                        tw_title(window, pending ? "Threading experiment - agent starting"
                                                 : "Threading experiment - no saved agents")
                        break
                    }
                    savedPicker = .agents(selected)
                    savedSelected = 0
                    savedFirst = 0
                    dirty = true
                }
            case 20, 22:
                let kind: AgentKind = event.kind == 20 ? .codex : .claude
                let available = kind == .codex ? codexAccounts : claudeAccounts
                let active = kind == .codex ? codexAccount : claudeAccount
                let executable = kind == .codex ? agentExecutable : claudeExecutable
                guard accountPicker == nil, savedPicker == nil, executable != nil,
                      !projects.isEmpty, !available.isEmpty else { break }
                accountPicker = kind
                accountSelected = available.firstIndex(of: active) ?? 0
                accountFirst = 0
                dirty = true
            default: break
            }
        }
    }

    // The accessibility bridge receives the same viewport rows as the renderer. Stop at a byte
    // boundary so a long grapheme or externally supplied title cannot expand its C projection.
    private static func boundedAccessibilityLabel(_ value: String, maximumBytes: Int = 400) -> String {
        var result = "", bytes = 0
        for scalar in value.unicodeScalars {
            let part = String(scalar)
            let length = part.utf8.count
            if bytes + length > maximumBytes { break }
            result.append(part)
            bytes += length
        }
        return result
    }

    @MainActor private static func publishAccessibleRow(_ window: OpaquePointer, id: String,
                                                         label: String, selected: Bool,
                                                         visibleIndex: Int, width: Int, height: Int,
                                                         indent: CGFloat = 0) throws {
        let bounds = navigatorRowPixels(visibleIndex, width: width, height: height, indent: indent)
        let result = id.withCString { identifier in
            label.withCString { name in
                tw_accessibility_add_row(window, identifier, name, selected ? 1 : 0,
                                         bounds.x, bounds.y, bounds.width, bounds.height)
            }
        }
        guard result == 0 else { throw WindowFailure("native accessibility row exceeds its bound") }
    }
    #endif
}
