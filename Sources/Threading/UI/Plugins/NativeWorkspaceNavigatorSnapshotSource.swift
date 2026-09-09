import Foundation
import ThreadingPluginKit

/// Projects host state into the bounded, typed contract a native navigator receives.
///
/// Full replacements stop after `maximumItems`; a session activity/title edge looks up and emits
/// only that session. The source never hands a plugin a store, path, runtime, or model object.
@MainActor
final class NativeWorkspaceNavigatorSnapshotSource {
    static let maximumItems = 2_000
    static let maximumStringScalars = 512

    private struct ItemKey: Hashable {
        let kind: PluginWorkspaceItemKind
        let identifier: String
    }

    private let projectStore: ProjectStore
    private let activity: (SessionID) -> SessionActivity
    private var revision: UInt64 = 0
    private var publishedKeys = Set<ItemKey>()
    private var selectedKey: ItemKey?

    init(
        projectStore: ProjectStore = .shared,
        activity: @escaping (SessionID) -> SessionActivity = {
            AgentRuntime.shared.activity(sessionID: $0)
        }
    ) {
        self.projectStore = projectStore
        self.activity = activity
    }

    func initialSnapshot(
        selectedItemIdentity: PluginWorkspaceItemIdentity?
    ) -> PluginWorkspaceSnapshot {
        revision &+= 1
        let items = boundedItems()
        publishedKeys = Set(items.map { key(for: $0.identity) })
        let publishedSelection = publishedSelection(selectedItemIdentity)
        selectedKey = publishedSelection.map(key)
        return PluginWorkspaceSnapshot(
            revision: revision,
            items: items,
            selectedItemIdentity: publishedSelection
        )
    }

    func replacement(
        selectedItemIdentity: PluginWorkspaceItemIdentity?
    ) -> PluginWorkspaceUpdate {
        revision &+= 1
        let items = boundedItems()
        publishedKeys = Set(items.map { key(for: $0.identity) })
        let publishedSelection = publishedSelection(selectedItemIdentity)
        selectedKey = publishedSelection.map(key)
        return PluginWorkspaceUpdate(
            revision: revision,
            isReplacement: true,
            items: items,
            selectionChanged: true,
            selectedItemIdentity: publishedSelection
        )
    }

    /// Produces a bounded one-row delta. A newly added session can enter only while its parent was
    /// published and the initial cap has room; otherwise a later structural replacement decides
    /// which rows fit rather than letting incremental traffic grow the context without bound.
    func sessionUpdate(_ sessionID: SessionID) -> PluginWorkspaceUpdate? {
        let identity = PluginWorkspaceItemIdentity(
            kind: .session,
            identifier: sessionID.uuidString.lowercased()
        )
        let itemKey = key(for: identity)

        guard let session = projectStore.session(withID: sessionID),
              let project = projectStore.project(forSessionID: sessionID) else {
            guard publishedKeys.remove(itemKey) != nil else { return nil }
            let removedSelection = selectedKey == itemKey
            if removedSelection { selectedKey = nil }
            revision &+= 1
            return PluginWorkspaceUpdate(
                revision: revision,
                items: [],
                removedItems: [identity],
                selectionChanged: removedSelection,
                selectedItemIdentity: nil
            )
        }

        if !publishedKeys.contains(itemKey) {
            let parent = ItemKey(
                kind: .project,
                identifier: project.id.uuidString.lowercased()
            )
            guard publishedKeys.contains(parent), publishedKeys.count < Self.maximumItems else {
                return nil
            }
            publishedKeys.insert(itemKey)
        }

        revision &+= 1
        return PluginWorkspaceUpdate(
            revision: revision,
            items: [sessionItem(session, project: project)]
        )
    }

    func selectionUpdate(
        _ identity: PluginWorkspaceItemIdentity?
    ) -> PluginWorkspaceUpdate? {
        let nextIdentity = publishedSelection(identity)
        let nextKey = nextIdentity.map(key)
        guard nextKey != selectedKey else { return nil }
        selectedKey = nextKey
        revision &+= 1
        return PluginWorkspaceUpdate(
            revision: revision,
            items: [],
            selectionChanged: true,
            selectedItemIdentity: nextIdentity
        )
    }

    private func boundedItems() -> [PluginWorkspaceItem] {
        var items: [PluginWorkspaceItem] = []
        items.reserveCapacity(min(Self.maximumItems, projectStore.projects.count))

        outer: for project in projectStore.projects {
            guard items.count < Self.maximumItems else { break }
            items.append(projectItem(project))

            for session in project.sessions {
                guard items.count < Self.maximumItems else { break outer }
                items.append(sessionItem(session, project: project))
            }
            for terminal in project.terminals {
                guard items.count < Self.maximumItems else { break outer }
                items.append(terminalItem(terminal, project: project))
            }
        }
        return items
    }

    private func projectItem(_ project: Project) -> PluginWorkspaceItem {
        PluginWorkspaceItem(
            identity: PluginWorkspaceItemIdentity(
                kind: .project,
                identifier: project.id.uuidString.lowercased()
            ),
            title: bounded(project.name),
            lastActiveAt: project.createdAt
        )
    }

    private func sessionItem(_ session: AgentSession, project: Project) -> PluginWorkspaceItem {
        PluginWorkspaceItem(
            identity: PluginWorkspaceItemIdentity(
                kind: .session,
                identifier: session.id.uuidString.lowercased()
            ),
            parentIdentity: PluginWorkspaceItemIdentity(
                kind: .project,
                identifier: project.id.uuidString.lowercased()
            ),
            title: bounded(session.displayTitle),
            detail: bounded(session.kind.displayName),
            branch: session.branch.map(bounded),
            activity: pluginActivity(activity(session.id)),
            isPinned: session.isPinned,
            isArchived: session.isArchived,
            lastActiveAt: session.lastUsedAt
        )
    }

    private func terminalItem(_ terminal: ProjectTerminal, project: Project) -> PluginWorkspaceItem {
        PluginWorkspaceItem(
            identity: PluginWorkspaceItemIdentity(
                kind: .terminal,
                identifier: terminal.id.uuidString.lowercased()
            ),
            parentIdentity: PluginWorkspaceItemIdentity(
                kind: .project,
                identifier: project.id.uuidString.lowercased()
            ),
            title: bounded(ProjectTerminalTitle.displayTitle(
                for: terminal,
                projectRoot: project.folderPath
            )),
            detail: bounded(L10n.string("Terminal")),
            branch: terminal.branch.map(bounded),
            lastActiveAt: terminal.createdAt
        )
    }

    private func pluginActivity(_ value: SessionActivity) -> PluginWorkspaceActivity {
        switch value {
        case .dormant: return .dormant
        case .idle: return .idle
        case .working: return .working
        case .readyWithBackgroundWork: return .readyWithBackgroundWork
        case .awaitingUser: return .awaitingUser
        case .needsAttention: return .needsAttention
        case .limitReached: return .limitReached
        }
    }

    private func key(for identity: PluginWorkspaceItemIdentity) -> ItemKey {
        ItemKey(kind: identity.kind, identifier: identity.identifier)
    }

    private func publishedSelection(
        _ identity: PluginWorkspaceItemIdentity?
    ) -> PluginWorkspaceItemIdentity? {
        guard let identity, publishedKeys.contains(key(for: identity)) else { return nil }
        return identity
    }

    private func bounded(_ value: String) -> String {
        String(value.unicodeScalars.prefix(Self.maximumStringScalars))
    }
}
