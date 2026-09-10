import AppKit
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
    typealias SummaryReader = @Sendable (
        URL,
        ChangeRequestProviderRegistry
    ) async -> ChangeRequestSummaryStore.Reading

    private struct ItemKey: Hashable {
        let kind: PluginWorkspaceItemKind
        let identifier: String
    }

    private let projectStore: ProjectStore
    private let activity: (SessionID) -> SessionActivity
    private let summaryReader: SummaryReader
    private let appEvents = AppEventObservations()
    private var revision: UInt64 = 0
    private var publishedKeys = Set<ItemKey>()
    private var selectedKey: ItemKey?
    private var visibleSessionIDs = Set<SessionID>()
    private var loadedSummarySessionIDs = Set<SessionID>()
    private var summaries: [SessionID: PluginWorkspaceChangeRequest] = [:]
    private var summaryTasks: [SessionID: Task<Void, Never>] = [:]
    private lazy var changeRequestProviders = ChangeRequestProviderRegistry.live()
    var onSessionSummaryChange: ((SessionID) -> Void)?

    init(
        projectStore: ProjectStore = .shared,
        activity: @escaping (SessionID) -> SessionActivity = {
            AgentRuntime.shared.activity(sessionID: $0)
        },
        summaryReader: @escaping SummaryReader = { root, providers in
            await ChangeRequestSummaryStore.shared.read(root: root, providers: providers)
        }
    ) {
        self.projectStore = projectStore
        self.activity = activity
        self.summaryReader = summaryReader
        appEvents.observe(SourceControlProviderConnectionsDidChange.self) { [weak self] _ in
            self?.reloadVisibleSummaries()
        }
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
            summaryTasks[sessionID]?.cancel()
            summaryTasks[sessionID] = nil
            loadedSummarySessionIDs.remove(sessionID)
            summaries[sessionID] = nil
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

    /// Applies the plugin's realized-row interest set to the expensive provider pipeline.
    /// Project and terminal identities were already removed by PluginKit; validate UUIDs again at
    /// the host boundary and cancel consumers which scrolled out of view.
    func visibleItemsDidChange(_ identities: [PluginWorkspaceItemIdentity]) {
        let next = Set(identities.compactMap { identity -> SessionID? in
            guard identity.kind == .session else { return nil }
            return SessionID(uuidString: identity.identifier)
        })
        for sessionID in visibleSessionIDs.subtracting(next) {
            summaryTasks[sessionID]?.cancel()
            summaryTasks[sessionID] = nil
            loadedSummarySessionIDs.remove(sessionID)
        }
        visibleSessionIDs = next
        for sessionID in next where !loadedSummarySessionIDs.contains(sessionID) {
            loadSummary(for: sessionID)
        }
    }

    /// Opens only the URL already validated and published by Threading for this current session.
    func openChangeRequest(sessionID: SessionID) -> Bool {
        guard projectStore.session(withID: sessionID) != nil,
              let url = summaries[sessionID]?.webURL else { return false }
        return NSWorkspace.shared.open(url)
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
            lastActiveAt: session.lastUsedAt,
            changeRequest: summaries[session.id]
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

    private func loadSummary(for sessionID: SessionID) {
        guard summaryTasks[sessionID] == nil,
              let rootPath = projectStore.workingDirectory(forSessionID: sessionID) else {
            return
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let providers = changeRequestProviders
        let reader = summaryReader
        summaryTasks[sessionID] = Task { [weak self] in
            let reading = await reader(root, providers)
            guard let self, !Task.isCancelled,
                  self.visibleSessionIDs.contains(sessionID),
                  self.projectStore.session(withID: sessionID) != nil else { return }
            self.summaryTasks[sessionID] = nil
            self.loadedSummarySessionIDs.insert(sessionID)
            let next = reading.repositoryStatus?.changeRequest.map {
                self.pluginSummary(
                    $0,
                    provider: reading.repositoryStatus?.repository.provider
                )
            }
            guard !self.sameSummary(self.summaries[sessionID], next) else { return }
            self.summaries[sessionID] = next
            self.onSessionSummaryChange?(sessionID)
        }
    }

    private func reloadVisibleSummaries() {
        for sessionID in visibleSessionIDs {
            summaryTasks[sessionID]?.cancel()
            summaryTasks[sessionID] = nil
            loadedSummarySessionIDs.remove(sessionID)
            loadSummary(for: sessionID)
        }
    }

    private func pluginSummary(
        _ summary: ChangeRequestSummary,
        provider: SourceControlProvider?
    ) -> PluginWorkspaceChangeRequest {
        let unknown = summary.checks.unknown
        let unknownActive = summary.checks.unknownCount(disposition: .active)
        let unknownAttention = summary.checks.unknownCount(disposition: .needsAttention)
        let lifecycle: PluginWorkspaceChangeRequestLifecycle = switch summary.lifecycle {
        case .open: .open
        case .draft: .draft
        case .merged: .merged
        case .closed: .closed
        }
        return PluginWorkspaceChangeRequest(
            providerName: bounded(provider?.displayName ?? L10n.string("Source control")),
            changeRequestName: bounded(
                provider?.changeRequestName ?? L10n.string("change request")
            ),
            number: summary.number,
            title: bounded(summary.title),
            webURL: summary.url,
            lifecycle: lifecycle,
            successfulChecks: summary.checks.count(disposition: .successful),
            nonBlockingChecks: summary.checks.count(disposition: .nonBlocking),
            activeChecks: max(0, summary.checks.count(disposition: .active) - unknownActive),
            checksNeedingAttention: max(
                0,
                summary.checks.count(disposition: .needsAttention) - unknownAttention
            ),
            unknownChecks: unknown,
            checksAreIncomplete: summary.checks.coverage.isPartial
                || summary.checks.coverage.isCapped,
            approvals: summary.reviews.approvals,
            changesRequested: summary.reviews.changesRequested,
            reviewsRequested: summary.reviews.requested
        )
    }

    private func sameSummary(
        _ lhs: PluginWorkspaceChangeRequest?,
        _ rhs: PluginWorkspaceChangeRequest?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?):
            lhs.providerName == rhs.providerName
                && lhs.changeRequestName == rhs.changeRequestName
                && lhs.number == rhs.number
                && lhs.title == rhs.title
                && lhs.webURL == rhs.webURL
                && lhs.lifecycle == rhs.lifecycle
                && lhs.successfulChecks == rhs.successfulChecks
                && lhs.nonBlockingChecks == rhs.nonBlockingChecks
                && lhs.activeChecks == rhs.activeChecks
                && lhs.checksNeedingAttention == rhs.checksNeedingAttention
                && lhs.unknownChecks == rhs.unknownChecks
                && lhs.checksAreIncomplete == rhs.checksAreIncomplete
                && lhs.approvals == rhs.approvals
                && lhs.changesRequested == rhs.changesRequested
                && lhs.reviewsRequested == rhs.reviewsRequested
        default: false
        }
    }
}
