import AppKit

/// Owns one macOS Search presentation. It snapshots provider inputs for each query generation,
/// translates semantic snapshots into Design values, and activates typed locators through one
/// revalidating host closure.
@MainActor
final class UniversalSearchSessionController {
    typealias Catalog = @MainActor () -> [HostCommandDescriptor]
    typealias ProjectCatalog = @MainActor () -> [Project]
    typealias ProjectContext = @MainActor () -> ProjectID?
    typealias ViewContext = @MainActor () -> SearchViewContext?
    typealias WorkspaceMetadata = @MainActor () -> [WorkspaceMetadataSearchRecord]
    typealias Activator = @MainActor (SearchLocator) async -> Bool

    private let navigationIndex: NavigationSearchIndexStore
    private let transcriptIndex: TranscriptSearchIndexStore
    private let catalog: Catalog
    private let projects: ProjectCatalog
    private let projectContext: ProjectContext
    private let viewContext: ViewContext
    private let workspaceMetadata: WorkspaceMetadata
    private let activate: Activator
    private let events = AppEventObservations()
    private let workspaceFileIndex = WorkspaceFileIndex()

    private var overlayController: UniversalSearchOverlayViewController?
    private var presentation: InWindowOverlay.Presentation?
    private weak var presentationWindow: NSWindow?
    private weak var focusReturnTarget: NSResponder?
    private var searchTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var coordinator: UniversalSearchCoordinator?
    private var queryGeneration: UInt64 = 0
    private var query = ""
    private var scope: SearchScope = .everywhere
    private var latestSnapshot: SearchSnapshot?
    private var hitByID: [SearchHitID: SearchHit] = [:]
    private var queryError: String?
    private var activationStatus: String?
    private var workspaceMetadataSnapshot: [WorkspaceMetadataSearchRecord] = []

    init(
        navigationIndex: NavigationSearchIndexStore,
        transcriptIndex: TranscriptSearchIndexStore,
        catalog: @escaping Catalog,
        projects: @escaping ProjectCatalog,
        projectContext: @escaping ProjectContext,
        viewContext: @escaping ViewContext,
        workspaceMetadata: @escaping WorkspaceMetadata,
        activate: @escaping Activator
    ) {
        self.navigationIndex = navigationIndex
        self.transcriptIndex = transcriptIndex
        self.catalog = catalog
        self.projects = projects
        self.projectContext = projectContext
        self.viewContext = viewContext
        self.workspaceMetadata = workspaceMetadata
        self.activate = activate
        events.observe(NavigationSearchIndexDidChange.self) { [weak self] _ in
            guard self?.overlayController != nil else { return }
            self?.runQuery()
        }
        events.observe(TranscriptSearchIndexDidChange.self) { [weak self] _ in
            guard self?.overlayController != nil else { return }
            self?.runQuery()
        }
        events.observe(SessionAttachmentsDidChange.self) { [weak self] _ in
            guard let self, self.overlayController != nil else { return }
            self.workspaceMetadataSnapshot = self.workspaceMetadata()
            self.runQuery()
        }
    }

    deinit {
        searchTask?.cancel()
        activationTask?.cancel()
        let activeCoordinator = coordinator
        Task { await activeCoordinator?.cancel() }
    }

    func present(in window: NSWindow, preferredScope: SearchScope) {
        if overlayController != nil {
            scope = resolvedScope(preferredScope)
            runQuery()
            overlayController?.focusQuery(selectingAll: false)
            return
        }

        query = ""
        queryError = nil
        activationStatus = nil
        scope = resolvedScope(preferredScope)
        workspaceMetadataSnapshot = workspaceMetadata()
        presentationWindow = window
        focusReturnTarget = window.firstResponder

        let controller = UniversalSearchOverlayViewController()
        controller.onQueryChange = { [weak self] value in
            self?.query = value
            self?.activationStatus = nil
            self?.runQuery()
        }
        controller.onScopeChange = { [weak self] identifier in
            guard let self, let scope = self.scope(for: identifier) else { return }
            self.scope = scope
            self.activationStatus = nil
            self.runQuery()
        }
        controller.onSelectionChange = { [weak self] hitID in
            guard let coordinator = self?.coordinator else { return }
            Task { await coordinator.select(hitID) }
        }
        controller.onActivate = { [weak self] hitID in self?.activate(hitID: hitID) }
        controller.onDismiss = { [weak self] in self?.dismiss() }
        overlayController = controller
        presentation = InWindowOverlay.install(controller.view, in: window) { [weak self] in
            self?.dismiss()
        }
        runQuery()
        controller.focusQuery()
    }

    func dismiss() {
        searchTask?.cancel()
        searchTask = nil
        activationTask?.cancel()
        activationTask = nil
        if let coordinator { Task { await coordinator.cancel() } }
        coordinator = nil
        presentation?.remove()
        presentation = nil
        overlayController = nil
        if let presentationWindow, let focusReturnTarget {
            presentationWindow.makeFirstResponder(focusReturnTarget)
        }
        presentationWindow = nil
        focusReturnTarget = nil
        query = ""
        workspaceMetadataSnapshot = []
        hitByID = [:]
        latestSnapshot = nil
    }

    /// Command-G keeps its platform meaning while Search owns the window. The result order is
    /// already stable and bounded, so cycling changes only selection and never starts providers.
    func repeatSelection(backwards: Bool) -> Bool {
        guard overlayController != nil,
              let snapshot = latestSnapshot,
              !snapshot.hits.isEmpty else { return false }
        let hits = snapshot.hits
        let current = snapshot.selectedHitID.flatMap { selected in
            hits.firstIndex { $0.id == selected }
        } ?? (backwards ? 0 : -1)
        let next = backwards
            ? (current - 1 + hits.count) % hits.count
            : (current + 1) % hits.count
        let selected = hits[next].id
        latestSnapshot = SearchSnapshot(
            queryGeneration: snapshot.queryGeneration,
            groups: snapshot.groups,
            selectedHitID: selected,
            isComplete: snapshot.isComplete
        )
        render()
        if let coordinator { Task { await coordinator.select(selected) } }
        return true
    }

    private func runQuery() {
        activationTask?.cancel()
        activationTask = nil
        searchTask?.cancel()
        if let coordinator { Task { await coordinator.cancel() } }
        let selectedHitID = latestSnapshot?.selectedHitID
        queryGeneration &+= 1
        queryError = nil
        latestSnapshot = nil
        hitByID = [:]

        let parsed = SearchQueryParser.parse(query, scope: scope, generation: queryGeneration)
        guard case let .success(searchQuery) = parsed else {
            if case let .failure(error) = parsed { queryError = message(for: error) }
            render()
            return
        }

        let workspaceProjects = WorkspaceFileSearchProjection.projects(projects())
        let coordinator = UniversalSearchCoordinator(providers: [
            navigationIndex.provider(),
            transcriptIndex.provider(),
            WorkspaceMetadataSearchProvider(records: workspaceMetadataSnapshot),
            WorkspaceFileSearchProvider(
                projects: workspaceProjects,
                index: workspaceFileIndex
            ),
            ProjectTextSearchProvider(projects: workspaceProjects),
            RegistrySearchProvider(descriptors: catalog()),
        ])
        self.coordinator = coordinator
        render()
        searchTask = Task { [weak self] in
            let stream = await coordinator.start(
                query: searchQuery,
                clientCapabilities: .macOS,
                selectedHitID: selectedHitID
            )
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                self?.latestSnapshot = snapshot
                self?.hitByID = Dictionary(uniqueKeysWithValues: snapshot.hits.map { ($0.id, $0) })
                self?.render()
            }
        }
    }

    private func render() {
        guard let overlayController else { return }
        var rows: [UniversalSearchOverlayRow] = []
        if let snapshot = latestSnapshot {
            for group in snapshot.groups where !group.hits.isEmpty {
                rows.append(.group(id: "group:\(group.group.rawValue)", title: title(for: group.group)))
                rows += group.hits.map { hit in
                    .result(UniversalSearchResultRow(
                        id: hit.id,
                        title: hit.title,
                        detail: detail(for: hit)
                    ))
                }
                if group.isCapped {
                    rows.append(.message(
                        id: "cap:\(group.group.rawValue)",
                        text: L10n.string("More matches are available — refine the query.")
                    ))
                }
            }
            if rows.isEmpty, snapshot.isComplete, queryError == nil {
                rows.append(.message(
                    id: "empty",
                    text: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? L10n.string("No recent destinations")
                        : L10n.string("No matches")
                ))
            }
        }

        overlayController.apply(UniversalSearchOverlayState(
            query: query,
            scopes: scopeOptions(),
            selectedScopeID: identifier(for: scope),
            rows: rows,
            selectedHitID: latestSnapshot?.selectedHitID,
            status: activationStatus ?? coverageStatus(),
            queryError: queryError
        ))
    }

    private func activate(hitID: SearchHitID) {
        guard let hit = hitByID[hitID] else { return }
        activationTask?.cancel()
        activationStatus = L10n.string("Opening result…")
        render()
        activationTask = Task { [weak self] in
            guard let self else { return }
            let opened = await self.activate(hit.locator)
            guard !Task.isCancelled else { return }
            self.activationTask = nil
            if opened {
                self.dismiss()
            } else {
                self.activationStatus = L10n.string("That result is no longer available.")
                self.runQuery()
            }
        }
    }

    private func scopeOptions() -> [UniversalSearchScopeOption] {
        var options: [UniversalSearchScopeOption] = []
        if viewContext() != nil {
            options.append(UniversalSearchScopeOption(id: "view", title: L10n.string("View")))
        }
        if projectContext() != nil {
            options.append(UniversalSearchScopeOption(id: "project", title: L10n.string("Project")))
        }
        options.append(UniversalSearchScopeOption(id: "everywhere", title: L10n.string("Everywhere")))
        return options
    }

    private func resolvedScope(_ requested: SearchScope) -> SearchScope {
        switch requested {
        case let .project(projectID) where projectContext() == projectID:
            return requested
        case let .view(view) where view == viewContext():
            return requested
        case .everywhere:
            return .everywhere
        case .project, .view:
            return projectContext().map(SearchScope.project) ?? .everywhere
        }
    }

    private func scope(for identifier: String) -> SearchScope? {
        switch identifier {
        case "view": return viewContext().map(SearchScope.view)
        case "project": return projectContext().map(SearchScope.project)
        case "everywhere": return .everywhere
        default: return nil
        }
    }

    private func identifier(for scope: SearchScope) -> String {
        if case .view = scope { return "view" }
        if case .project = scope { return "project" }
        return "everywhere"
    }

    private func coverageStatus() -> String? {
        guard let snapshot = latestSnapshot else { return L10n.string("Searching…") }
        for group in snapshot.groups {
            for provider in group.providers {
                switch provider.coverage {
                case let .indexing(indexed, total):
                    if let total {
                        return L10n.format("Indexing %lld of %lld destinations…", Int64(indexed), Int64(total))
                    }
                    return L10n.format("Indexing %lld destinations…", Int64(indexed))
                case let .partial(reason), let .unavailable(reason):
                    return reason
                case .complete:
                    break
                }
            }
        }
        return snapshot.isComplete ? nil : L10n.string("Searching…")
    }

    private func detail(for hit: SearchHit) -> String? {
        var values: [String] = []
        if let project = hit.provenance.projectName { values.append(project) }
        if let provider = hit.provenance.provider, provider != "Threading" { values.append(provider) }
        if let branch = hit.provenance.branch { values.append(branch) }
        if hit.provenance.isArchived { values.append(L10n.string("Archived")) }
        if values.isEmpty, let snippet = hit.snippet?.text { return snippet }
        if let snippet = hit.snippet?.text, !snippet.isEmpty { values.append(snippet) }
        return values.isEmpty ? nil : values.joined(separator: " › ")
    }

    private func title(for group: SearchResultGroup) -> String {
        switch group {
        case .destinations: return L10n.string("Destinations")
        case .currentView: return L10n.string("Current View")
        case .conversations: return L10n.string("Conversations")
        case .files: return L10n.string("Files")
        case .settings: return L10n.string("Settings")
        case .archived: return L10n.string("Archived")
        }
    }

    private func message(for error: SearchQueryError) -> String {
        switch error {
        case let .queryTooLarge(maximum):
            return L10n.format("Search is limited to %lld bytes.", Int64(maximum))
        case let .tooManyFilters(maximum):
            return L10n.format("Search supports up to %lld filters.", Int64(maximum))
        case .unterminatedQuote:
            return L10n.string("Close the quoted phrase to search.")
        case .danglingEscape:
            return L10n.string("The final backslash must escape a character.")
        case let .missingFilterValue(name):
            return L10n.format("%@ needs a value.", name)
        case let .unknownFilter(name):
            return L10n.format("Unknown search filter: %@", name)
        case let .invalidFilterValue(name, value):
            return L10n.format("%@ is not a valid value for %@.", value, name)
        }
    }
}
