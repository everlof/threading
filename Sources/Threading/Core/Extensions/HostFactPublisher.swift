import Foundation
import ThreadingExtensionKit

enum HostFactPublisherError: Error, Equatable, LocalizedError {
    case duplicateSubject(ExtensionFactSubject)
    case projectionExceedsFactLimit(subject: ExtensionFactSubject, maximum: Int)
    case projectionOutsideProject(subject: ExtensionFactSubject, projectID: String)

    var errorDescription: String? {
        switch self {
        case .duplicateSubject(let subject):
            "The host fact snapshot contains duplicate subject \(subject)."
        case .projectionExceedsFactLimit(let subject, let maximum):
            "The host fact projection for \(subject) exceeds the \(maximum)-fact limit."
        case .projectionOutsideProject(let subject, let projectID):
            "The host fact projection for \(subject) is outside project \(projectID)."
        }
    }
}

/// Keeps the host-owned fact registry aligned with durable and live navigator state.
///
/// The render path only reads `ExtensionFactRegistry`. This publisher does the comparatively
/// expensive projection work on model events, and every replacement is partitioned below the
/// registry's hard transaction limits. An activity edge projects exactly one session.
@MainActor
final class HostFactPublisher {
    struct Dependencies {
        let notificationCenter: NotificationCenter
        let now: () -> Date
        let allProjections: () -> [HostFactProjection]
        let allSessionProjections: () -> [HostFactProjection]
        let sessionProjectionsForAccount: (AccountID) -> [HostFactProjection]
        let projectionsInProject: (ProjectID) -> [HostFactProjection]
        let projectProjection: (ProjectID) -> HostFactProjection?
        let sessionProjection: (SessionID) -> HostFactProjection?
        let terminalProjection: (TerminalID) -> HostFactProjection?
        let prepareScheduledState: () -> Void
        let prepareControlState: () -> Void
        let didPublishBatch: (_ factCount: Int, _ subjectCount: Int) -> Void

        init(
            notificationCenter: NotificationCenter = .default,
            now: @escaping () -> Date = Date.init,
            allProjections: @escaping () -> [HostFactProjection],
            allSessionProjections: @escaping () -> [HostFactProjection],
            sessionProjectionsForAccount: @escaping (AccountID) -> [HostFactProjection],
            projectionsInProject: @escaping (ProjectID) -> [HostFactProjection],
            projectProjection: @escaping (ProjectID) -> HostFactProjection? = { _ in nil },
            sessionProjection: @escaping (SessionID) -> HostFactProjection?,
            terminalProjection: @escaping (TerminalID) -> HostFactProjection?,
            prepareScheduledState: @escaping () -> Void = {},
            prepareControlState: @escaping () -> Void = {},
            didPublishBatch: @escaping (_ factCount: Int, _ subjectCount: Int) -> Void = { _, _ in }
        ) {
            self.notificationCenter = notificationCenter
            self.now = now
            self.allProjections = allProjections
            self.allSessionProjections = allSessionProjections
            self.sessionProjectionsForAccount = sessionProjectionsForAccount
            self.projectionsInProject = projectionsInProject
            self.projectProjection = projectProjection
            self.sessionProjection = sessionProjection
            self.terminalProjection = terminalProjection
            self.prepareScheduledState = prepareScheduledState
            self.prepareControlState = prepareControlState
            self.didPublishBatch = didPublishBatch
        }
    }

    private struct ProjectionRow {
        let projection: HostFactProjection
        let facts: [ExtensionFact]

        var subject: ExtensionFactSubject { projection.subject }
        var projectID: String { projection.projectID }
    }

    private let registry: ExtensionFactRegistry
    private let dependencies: Dependencies
    private let observations: AppEventObservations
    private var publishedSubjects: Set<ExtensionFactSubject> = []
    private var projectIDBySubject: [ExtensionFactSubject: String] = [:]
    private var subjectsByProjectID: [String: Set<ExtensionFactSubject>] = [:]
    private var hasStarted = false

    init(registry: ExtensionFactRegistry, dependencies: Dependencies) {
        self.registry = registry
        self.dependencies = dependencies
        observations = AppEventObservations(center: dependencies.notificationCenter)
    }

    func start() throws {
        guard !hasStarted else { return }
        try registry.replaceHostDefinitions(HostFactCatalog.definitions)
        dependencies.prepareScheduledState()
        dependencies.prepareControlState()
        try refreshAll()
        installObservers()
        hasStarted = true
    }

    func refreshAll() throws {
        let projections = dependencies.allProjections()
        let currentSubjects = Set(projections.map(\.subject))
        try replace(
            projections,
            removing: publishedSubjects.subtracting(currentSubjects)
        )
        publishedSubjects = currentSubjects
        projectIDBySubject = Dictionary(uniqueKeysWithValues: projections.map {
            ($0.subject, $0.projectID)
        })
        subjectsByProjectID = Dictionary(grouping: projections, by: \.projectID).mapValues {
            Set($0.map(\.subject))
        }
    }

    func refreshAllSessions() throws {
        try refreshAllSessions(using: dependencies.allSessionProjections())
    }

    func refreshProject(_ projectID: ProjectID) throws {
        let key = Self.opaqueID(projectID)
        let projections = dependencies.projectionsInProject(projectID)
        guard projections.allSatisfy({ $0.projectID == key }) else {
            let invalid = projections.first { $0.projectID != key }!
            throw HostFactPublisherError.projectionOutsideProject(
                subject: invalid.subject,
                projectID: key
            )
        }
        let previous = subjectsByProjectID[key] ?? []
        let current = Set(projections.map(\.subject))
        try replace(projections, removing: previous.subtracting(current))
        removeFromIndex(previous)
        addToIndex(projections)
    }

    func refreshSessions(_ sessionIDs: Set<SessionID>) throws {
        let subjects = Set(sessionIDs.map { ExtensionFactSubject.session(Self.opaqueID($0)) })
        let projections = sessionIDs.compactMap(dependencies.sessionProjection)
        let current = Set(projections.map(\.subject))
        try replace(projections, removing: subjects.subtracting(current))
        removeFromIndex(subjects)
        addToIndex(projections)
    }

    func refreshProjectRecord(_ projectID: ProjectID) throws {
        let subject = ExtensionFactSubject.project(Self.opaqueID(projectID))
        let projections = dependencies.projectProjection(projectID).map { [$0] } ?? []
        try replace(projections, removing: projections.isEmpty ? Set([subject]) : [])
        removeFromIndex([subject])
        addToIndex(projections)
    }

    func removeSession(_ sessionID: SessionID) throws {
        let subject = ExtensionFactSubject.session(Self.opaqueID(sessionID))
        try replace([], removing: [subject])
        removeFromIndex([subject])
    }

    func refreshTerminal(_ terminalID: TerminalID) throws {
        let subject = ExtensionFactSubject.terminal(Self.opaqueID(terminalID))
        let projections = dependencies.terminalProjection(terminalID).map { [$0] } ?? []
        let current = Set(projections.map(\.subject))
        try replace(projections, removing: Set([subject]).subtracting(current))
        removeFromIndex([subject])
        addToIndex(projections)
    }

    private func refreshAllSessions(using projections: [HostFactProjection]) throws {
        let previous = Set(publishedSubjects.filter { $0.kind == .session })
        let current = Set(projections.map(\.subject))
        try replace(projections, removing: previous.subtracting(current))
        removeFromIndex(previous)
        addToIndex(projections)
    }

    private func replace(
        _ projections: [HostFactProjection],
        removing removedSubjects: Set<ExtensionFactSubject>
    ) throws {
        let observedAt = dependencies.now()
        var seen: Set<ExtensionFactSubject> = []
        var rows: [ProjectionRow] = []
        rows.reserveCapacity(projections.count + removedSubjects.count)
        for projection in projections {
            guard seen.insert(projection.subject).inserted else {
                throw HostFactPublisherError.duplicateSubject(projection.subject)
            }
            let facts = HostFactCatalog.facts(from: projection, observedAt: observedAt)
            guard facts.count <= ExtensionFactRegistry.maximumFactsPerReplacement else {
                throw HostFactPublisherError.projectionExceedsFactLimit(
                    subject: projection.subject,
                    maximum: ExtensionFactRegistry.maximumFactsPerReplacement
                )
            }
            rows.append(ProjectionRow(projection: projection, facts: facts))
        }

        rows.sort { Self.subjectSortKey($0.subject) < Self.subjectSortKey($1.subject) }
        var pendingFacts: [ExtensionFact] = []
        var pendingSubjects: Set<ExtensionFactSubject> = []
        var replacements: [ExtensionHostFactReplacement] = []

        func stagePendingReplacement() {
            guard !pendingSubjects.isEmpty else { return }
            replacements.append(.init(facts: pendingFacts, subjects: pendingSubjects))
            pendingFacts.removeAll(keepingCapacity: true)
            pendingSubjects.removeAll(keepingCapacity: true)
        }

        for row in rows {
            if !pendingSubjects.isEmpty,
               pendingFacts.count + row.facts.count
                   > ExtensionFactRegistry.maximumFactsPerReplacement {
                stagePendingReplacement()
            }
            pendingFacts.append(contentsOf: row.facts)
            pendingSubjects.insert(row.subject)
        }

        for subject in removedSubjects.subtracting(seen).sorted(by: {
            Self.subjectSortKey($0) < Self.subjectSortKey($1)
        }) {
            if pendingSubjects.count == ExtensionFactRegistry.maximumSubjectsPerReplacement {
                stagePendingReplacement()
            }
            pendingSubjects.insert(subject)
        }
        stagePendingReplacement()
        try registry.replaceHostFacts(replacements)
        for replacement in replacements {
            dependencies.didPublishBatch(replacement.facts.count, replacement.subjects.count)
        }
    }

    private func addToIndex(_ projections: [HostFactProjection]) {
        for projection in projections {
            publishedSubjects.insert(projection.subject)
            projectIDBySubject[projection.subject] = projection.projectID
            subjectsByProjectID[projection.projectID, default: []].insert(projection.subject)
        }
    }

    private func removeFromIndex(_ subjects: Set<ExtensionFactSubject>) {
        publishedSubjects.subtract(subjects)
        for subject in subjects {
            guard let projectID = projectIDBySubject.removeValue(forKey: subject) else { continue }
            subjectsByProjectID[projectID]?.remove(subject)
            if subjectsByProjectID[projectID]?.isEmpty == true {
                subjectsByProjectID.removeValue(forKey: projectID)
            }
        }
    }

    private func installObservers() {
        observations.observe(ProjectsDidChange.self) { [weak self] event in
            self?.projectsDidChange(event)
        }
        observations.observe(SessionActivityDidChange.self) { [weak self] event in
            self?.refreshSessionsSafely([event.sessionID])
        }
        observations.observe(ScheduledMessagesDidChange.self) { [weak self] _ in
            guard let self else { return }
            dependencies.prepareScheduledState()
            refreshAllSessionsSafely()
        }
        observations.observe(AppSettingsDidChange.self) { [weak self] _ in
            self?.refreshAllSafely()
        }
        observations.observe(ControlGrantsDidChange.self) { [weak self] event in
            guard let self else { return }
            dependencies.prepareControlState()
            refreshSessionsSafely([event.sessionID])
        }
        observations.observe(SupervisionDidChange.self) { [weak self] event in
            guard let self else { return }
            dependencies.prepareControlState()
            refreshSessionsSafely([event.managerID, event.childID])
        }
        observations.observe(CurfewDidChange.self) { [weak self] event in
            self?.refreshSessionsSafely([event.sessionID])
        }
        observations.observe(CustomLimitsDidChange.self) { [weak self] _ in
            self?.refreshAllSessionsSafely()
        }
        observations.observe(CustomLimitDidFire.self) { [weak self] event in
            self?.refreshAccountSessionsSafely(event.accountID)
        }
        observations.observe(AccountUsageDidChange.self) { [weak self] event in
            self?.refreshAccountSessionsSafely(event.accountID)
        }
    }

    private func projectsDidChange(_ event: ProjectsDidChange) {
        switch event.sidebarImpact {
        case .structure:
            refreshAllSafely()
        case .projectRemoved(let projectID, _, _):
            refreshProjectSafely(projectID)
        case .projectStructure(let projectID):
            refreshProjectSafely(projectID)
        case .projectRow(let projectID):
            do { try refreshProjectRecord(projectID) }
            catch { report(error) }
        case .sessionAdded(_, let sessionID), .sessionStructure(_, let sessionID),
             .sessionTitle(let sessionID, _),
             .sessionRow(let sessionID):
            refreshSessionsSafely([sessionID])
        case .sessionRemoved(let projectID, _):
            // Removing one array element changes every following sibling's manual-order fact.
            // The project is the smallest correct replacement boundary for that edge.
            refreshProjectSafely(projectID)
        case .terminalAdded(_, let terminalID), .terminalRow(let terminalID):
            do { try refreshTerminal(terminalID) }
            catch { report(error) }
        }
    }

    private func refreshAllSafely() {
        do { try refreshAll() }
        catch { report(error) }
    }

    private func refreshAllSessionsSafely() {
        do { try refreshAllSessions() }
        catch { report(error) }
    }

    private func refreshAccountSessionsSafely(_ accountID: AccountID) {
        do {
            let projections = dependencies.sessionProjectionsForAccount(accountID)
            try replace(projections, removing: [])
            removeFromIndex(Set(projections.map(\.subject)))
            addToIndex(projections)
        }
        catch { report(error) }
    }

    private func refreshProjectSafely(_ projectID: ProjectID) {
        do { try refreshProject(projectID) }
        catch { report(error) }
    }

    private func refreshSessionsSafely(_ sessionIDs: Set<SessionID>) {
        do { try refreshSessions(sessionIDs) }
        catch { report(error) }
    }

    private func report(_ error: Error) {
        ThreadingLogger.extensions.error(
            "Could not publish host navigator facts: \(error.localizedDescription, privacy: .private(mask: .hash))"
        )
    }

    private static func opaqueID<ID>(_ id: ID) -> String where ID: CustomStringConvertible {
        id.description.lowercased()
    }

    private static func subjectSortKey(_ subject: ExtensionFactSubject) -> String {
        switch subject {
        case .session(let id): "0:\(id)"
        case .project(let id): "1:\(id)"
        case .terminal(let id): "2:\(id)"
        case .repository(let repository): "3:\(repository.host)/\(repository.path)"
        case .repositoryBranch(let repository, let branch):
            "4:\(repository.host)/\(repository.path)#\(branch)"
        }
    }
}

private extension HostFactProjection {
    var projectID: String {
        switch self {
        case .session(let facts): facts.projectID
        case .project(let facts): facts.id
        case .terminal(let facts): facts.projectID
        }
    }
}
