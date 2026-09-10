import Combine
import Foundation
import ThreadingPluginKit

struct T3NavigatorItemKey: Hashable {
    let kind: Int
    let identifier: String

    init(_ identity: PluginWorkspaceItemIdentity) {
        kind = identity.kind.rawValue
        identifier = identity.identifier
    }
}

enum T3NavigatorSection: String, CaseIterable, Identifiable {
    case pinned = "Pinned"
    case active = "Active"
    case archived = "Archived"

    var id: String { rawValue }
}

enum T3NavigatorPresentationChange {
    case reloadAll
    case reloadRow(T3NavigatorRow)
    case selection(previous: T3NavigatorRow?, current: T3NavigatorRow?)
}

struct T3NavigatorProject: Identifiable, Equatable {
    let id: String
    let title: String
}

@MainActor
final class T3NavigatorRow: ObservableObject, Identifiable {
    let id: T3NavigatorItemKey
    let ordinal: Int

    private(set) var identity: PluginWorkspaceItemIdentity
    @Published private(set) var projectIdentifier: String?
    @Published private(set) var title: String
    @Published private(set) var detail: String?
    @Published private(set) var branch: String?
    @Published private(set) var activity: PluginWorkspaceActivity
    @Published private(set) var isPinned: Bool
    @Published private(set) var isArchived: Bool
    @Published private(set) var lastActiveAt: Date?
    @Published private(set) var isSelected: Bool

    init(item: PluginWorkspaceItem, ordinal: Int, isSelected: Bool) {
        id = T3NavigatorItemKey(item.identity)
        self.ordinal = ordinal
        identity = item.identity
        projectIdentifier = Self.projectIdentifier(for: item)
        title = item.title
        detail = item.detail
        branch = item.branch
        activity = item.activity
        isPinned = item.isPinned
        isArchived = item.isArchived
        lastActiveAt = item.lastActiveAt
        self.isSelected = isSelected
    }

    func apply(_ item: PluginWorkspaceItem) {
        identity = item.identity
        projectIdentifier = Self.projectIdentifier(for: item)
        title = item.title
        detail = item.detail
        branch = item.branch
        activity = item.activity
        isPinned = item.isPinned
        isArchived = item.isArchived
        lastActiveAt = item.lastActiveAt
    }

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
    }

    private static func projectIdentifier(for item: PluginWorkspaceItem) -> String? {
        guard item.parentIdentity?.kind == .project else { return nil }
        return item.parentIdentity?.identifier
    }
}

/// The state adapter between Threading's bounded workspace stream and its virtual native table.
///
/// Ordinary activity and title edges mutate one retained row object. Published section arrays
/// change only for structural edges (new, removed, pinned, or archived), so a busy session asks
/// the table to repaint one viewport row instead of rebuilding a large workspace.
@MainActor
final class T3NavigatorStore: ObservableObject {
    @Published private(set) var pinned: [T3NavigatorRow] = []
    @Published private(set) var active: [T3NavigatorRow] = []
    @Published private(set) var archived: [T3NavigatorRow] = []
    @Published private(set) var projects: [T3NavigatorProject] = []
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            onPresentationChange?(.reloadAll)
        }
    }
    @Published var selectedProjectIdentifier: String? {
        didSet {
            guard selectedProjectIdentifier != oldValue else { return }
            onPresentationChange?(.reloadAll)
        }
    }
    @Published private(set) var filterRevision: UInt64 = 0

    private let context: PluginWorkspaceNavigatorContext
    private var revision: UInt64 = 0
    private var rowsByKey: [T3NavigatorItemKey: T3NavigatorRow] = [:]
    private var selectedKey: T3NavigatorItemKey?
    private var projectOrder: [String] = []
    private var projectNames: [String: String] = [:]
    private var nextRowOrdinal = 0

    /// One main-actor presentation sink. Content edges identify the exact retained row; only a
    /// structural/filter edge asks the virtual table to rebuild its lightweight index.
    var onPresentationChange: ((T3NavigatorPresentationChange) -> Void)?

    init(context: PluginWorkspaceNavigatorContext) {
        self.context = context
        let snapshot = context.snapshot
        replace(with: snapshot)
        context.observeUpdates { [weak self] update in
            self?.receive(update)
        }
    }

    func rows(in section: T3NavigatorSection) -> [T3NavigatorRow] {
        switch section {
        case .pinned: return pinned
        case .active: return active
        case .archived: return archived
        }
    }

    func visibleRows(in section: T3NavigatorSection) -> [T3NavigatorRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows(in: section).filter { row in
            if let selectedProjectIdentifier,
               row.projectIdentifier != selectedProjectIdentifier {
                return false
            }
            guard !query.isEmpty else { return true }
            return row.title.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    func projectTitle(for identifier: String?) -> String {
        guard let identifier else { return "No project" }
        return projectNames[identifier] ?? "No project"
    }

    func visibleProjects(matching searchText: String) -> [T3NavigatorProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projects }
        return projects.filter {
            $0.title.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    var selectedProjectTitle: String {
        guard let selectedProjectIdentifier else { return "All projects" }
        return projectNames[selectedProjectIdentifier] ?? "All projects"
    }

    func selectProject(_ identifier: String?) {
        selectedProjectIdentifier = identifier
    }

    @discardableResult
    func activate(_ row: T3NavigatorRow) -> Bool {
        context.activate(identity: row.identity)
    }

    func togglePin(_ row: T3NavigatorRow) {
        guard !row.isArchived else { return }
        _ = context.perform(
            action: row.isPinned ? .unpin : .pin,
            identity: row.identity
        )
    }

    func archive(_ row: T3NavigatorRow) {
        guard !row.isArchived else { return }
        _ = context.perform(action: .archive, identity: row.identity)
    }

    private func replace(with snapshot: PluginWorkspaceSnapshot) {
        revision = snapshot.revision
        rowsByKey.removeAll(keepingCapacity: true)
        projectOrder.removeAll(keepingCapacity: true)
        projectNames.removeAll(keepingCapacity: true)
        nextRowOrdinal = 0
        selectedKey = snapshot.selectedItemIdentity.map(T3NavigatorItemKey.init)

        var nextPinned: [T3NavigatorRow] = []
        var nextActive: [T3NavigatorRow] = []
        var nextArchived: [T3NavigatorRow] = []
        for item in snapshot.items {
            switch item.identity.kind {
            case .project:
                updateProject(item)
            case .session:
                let key = T3NavigatorItemKey(item.identity)
                let row = T3NavigatorRow(
                    item: item,
                    ordinal: nextRowOrdinal,
                    isSelected: key == selectedKey
                )
                nextRowOrdinal += 1
                rowsByKey[key] = row
                switch section(for: row) {
                case .pinned: nextPinned.append(row)
                case .active: nextActive.append(row)
                case .archived: nextArchived.append(row)
                }
            case .terminal:
                break
            @unknown default:
                break
            }
        }
        pinned = nextPinned
        active = nextActive
        archived = nextArchived
        publishProjects()
        onPresentationChange?(.reloadAll)
    }

    private func receive(_ update: PluginWorkspaceUpdate) {
        guard update.revision > revision else { return }
        if update.isReplacement {
            // A replacement owns the item collection, while selection remains independently
            // explicit. The context has already applied both pieces, so its coherent snapshot
            // preserves an unchanged selection when `selectionChanged` is false.
            replace(with: context.snapshot)
            return
        }

        var projectsChanged = false
        for identity in update.removedItems {
            let key = T3NavigatorItemKey(identity)
            switch identity.kind {
            case .project:
                projectOrder.removeAll { $0 == identity.identifier }
                projectsChanged = projectNames.removeValue(forKey: identity.identifier) != nil
                    || projectsChanged
            case .session:
                removeRow(for: key)
            case .terminal:
                break
            @unknown default:
                break
            }
        }

        for item in update.items {
            switch item.identity.kind {
            case .project:
                updateProject(item)
                projectsChanged = true
            case .session:
                updateSession(item)
            case .terminal:
                break
            @unknown default:
                break
            }
        }

        if projectsChanged {
            publishProjects()
            onPresentationChange?(.reloadAll)
        }
        if update.selectionChanged {
            setSelection(update.selectedItemIdentity)
        }
        revision = update.revision
    }

    private func updateSession(_ item: PluginWorkspaceItem) {
        let key = T3NavigatorItemKey(item.identity)
        if let row = rowsByKey[key] {
            let oldSection = section(for: row)
            let oldTitle = row.title
            let oldProject = row.projectIdentifier
            row.apply(item)
            let newSection = section(for: row)
            if oldSection != newSection {
                remove(row, from: oldSection)
                insert(row, into: newSection)
                onPresentationChange?(.reloadAll)
            } else if (!searchText.isEmpty && oldTitle != row.title)
                        || (selectedProjectIdentifier != nil
                            && oldProject != row.projectIdentifier) {
                filterRevision &+= 1
                onPresentationChange?(.reloadAll)
            } else {
                onPresentationChange?(.reloadRow(row))
            }
            return
        }

        let row = T3NavigatorRow(
            item: item,
            ordinal: nextRowOrdinal,
            isSelected: key == selectedKey
        )
        nextRowOrdinal += 1
        rowsByKey[key] = row
        insert(row, into: section(for: row))
        onPresentationChange?(.reloadAll)
    }

    private func removeRow(for key: T3NavigatorItemKey) {
        guard let row = rowsByKey.removeValue(forKey: key) else { return }
        remove(row, from: section(for: row))
        if selectedKey == key { selectedKey = nil }
        onPresentationChange?(.reloadAll)
    }

    private func setSelection(_ identity: PluginWorkspaceItemIdentity?) {
        let next = identity.map(T3NavigatorItemKey.init)
        guard next != selectedKey else { return }
        let previousRow = selectedKey.flatMap { rowsByKey[$0] }
        previousRow?.setSelected(false)
        selectedKey = next
        let currentRow = next.flatMap { rowsByKey[$0] }
        currentRow?.setSelected(true)
        onPresentationChange?(.selection(previous: previousRow, current: currentRow))
    }

    private func updateProject(_ item: PluginWorkspaceItem) {
        let identifier = item.identity.identifier
        if projectNames[identifier] == nil { projectOrder.append(identifier) }
        projectNames[identifier] = item.title
    }

    private func publishProjects() {
        projects = projectOrder.compactMap { identifier in
            projectNames[identifier].map { T3NavigatorProject(id: identifier, title: $0) }
        }
        if let selectedProjectIdentifier,
           projectNames[selectedProjectIdentifier] == nil {
            self.selectedProjectIdentifier = nil
        }
    }

    private func section(for row: T3NavigatorRow) -> T3NavigatorSection {
        if row.isArchived { return .archived }
        if row.isPinned { return .pinned }
        return .active
    }

    private func remove(_ row: T3NavigatorRow, from section: T3NavigatorSection) {
        switch section {
        case .pinned: pinned.removeAll { $0 === row }
        case .active: active.removeAll { $0 === row }
        case .archived: archived.removeAll { $0 === row }
        }
    }

    private func insert(_ row: T3NavigatorRow, into section: T3NavigatorSection) {
        switch section {
        case .pinned: insert(row, into: &pinned)
        case .active: insert(row, into: &active)
        case .archived: insert(row, into: &archived)
        }
    }

    private func insert(_ row: T3NavigatorRow, into rows: inout [T3NavigatorRow]) {
        let insertionIndex = rows.firstIndex { $0.ordinal > row.ordinal } ?? rows.endIndex
        rows.insert(row, at: insertionIndex)
    }
}
