import Foundation

struct NavigationSearchIndexDidChange: AppEvent {
    static let name = Notification.Name("navigationSearchIndexDidChange")
}

/// Maintains the warm immutable navigation index for the process. Project mutations copy only
/// value metadata on the main actor, then cancel and replace an off-main index build.
@MainActor
final class NavigationSearchIndexStore {
    private let projectStore: ProjectStore
    private let events: AppEventObservations
    private var index = NavigationSearchIndex(records: [])
    private var recordsByProjectID: [
        ProjectID: [NavigationSearchRecord.Destination: NavigationSearchRecord]
    ] = [:]
    private var projectNames: [ProjectID: String] = [:]
    private var requestedRecordCount = 0
    private var generation: UInt64 = 0
    private var buildTask: Task<Void, Never>?

    init(
        projectStore: ProjectStore = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.projectStore = projectStore
        events = AppEventObservations(center: notificationCenter)
        events.observe(ProjectsDidChange.self) { [weak self] event in
            self?.projectsDidChange(event)
        }
        rebuildAll()
    }

    deinit {
        buildTask?.cancel()
    }

    func provider() -> NavigationSearchProvider {
        let coverage: SearchCoverage = buildTask == nil
            ? .complete
            : .indexing(indexed: index.recordCount, total: requestedRecordCount)
        return NavigationSearchProvider(index: index, coverage: coverage)
    }

    private func projectsDidChange(_ event: ProjectsDidChange) {
        switch event.sidebarImpact {
        case .structure:
            rebuildAll()
        case .projectRemoved(let projectID, _, _):
            let removedCount = recordsByProjectID.removeValue(forKey: projectID)?.count ?? 0
            projectNames.removeValue(forKey: projectID)
            requestedRecordCount -= removedCount
            scheduleBuild()
        case .projectStructure(let projectID):
            replaceProject(projectID)
        case .projectRow(let projectID):
            guard let project = projectStore.project(withID: projectID) else { return }
            guard projectNames[projectID] != project.name else { return }
            projectNames[projectID] = project.name
            scheduleBuild()
        case .sessionAdded(_, let sessionID), .sessionStructure(_, let sessionID),
             .sessionTitle(let sessionID, _), .sessionRow(let sessionID):
            replaceSession(sessionID)
        case .sessionRemoved(let projectID, let sessionID):
            removeSession(sessionID, from: projectID)
        case .terminalAdded(_, let terminalID), .terminalRow(let terminalID):
            replaceTerminal(terminalID)
        }
    }

    private func rebuildAll() {
        recordsByProjectID = Dictionary(uniqueKeysWithValues: projectStore.projects.map { project in
            (project.id, keyed(NavigationSearchProjection.records(project: project)))
        })
        projectNames = Dictionary(uniqueKeysWithValues: projectStore.projects.map {
            ($0.id, $0.name)
        })
        requestedRecordCount = recordsByProjectID.values.reduce(0) { $0 + $1.count }
        scheduleBuild()
    }

    private func replaceProject(_ projectID: ProjectID) {
        let previousCount = recordsByProjectID[projectID]?.count ?? 0
        if let project = projectStore.project(withID: projectID) {
            let replacement = keyed(NavigationSearchProjection.records(project: project))
            recordsByProjectID[projectID] = replacement
            projectNames[projectID] = project.name
            requestedRecordCount += replacement.count - previousCount
        } else {
            recordsByProjectID.removeValue(forKey: projectID)
            projectNames.removeValue(forKey: projectID)
            requestedRecordCount -= previousCount
        }
        scheduleBuild()
    }

    private func replaceSession(_ sessionID: SessionID) {
        guard let project = projectStore.project(forSessionID: sessionID),
              let session = projectStore.session(withID: sessionID) else { return }
        var records = recordsByProjectID[project.id] ?? [:]
        let previousCount = records.count
        records.removeValue(forKey: .session(projectID: project.id, sessionID: sessionID))
        records.removeValue(forKey: .archivedSession(
            projectID: project.id,
            sessionID: sessionID
        ))
        let record = NavigationSearchProjection.record(session: session, in: project)
        records[record.destination] = record
        recordsByProjectID[project.id] = records
        projectNames[project.id] = project.name
        requestedRecordCount += records.count - previousCount
        scheduleBuild()
    }

    private func removeSession(_ sessionID: SessionID, from projectID: ProjectID) {
        guard var records = recordsByProjectID[projectID] else { return }
        let previousCount = records.count
        records.removeValue(forKey: .session(projectID: projectID, sessionID: sessionID))
        records.removeValue(forKey: .archivedSession(
            projectID: projectID,
            sessionID: sessionID
        ))
        recordsByProjectID[projectID] = records
        requestedRecordCount += records.count - previousCount
        scheduleBuild()
    }

    private func replaceTerminal(_ terminalID: TerminalID) {
        guard let project = projectStore.homeProject(forTerminalID: terminalID),
              let terminal = projectStore.terminal(withID: terminalID) else { return }
        var records = recordsByProjectID[project.id] ?? [:]
        let record = NavigationSearchProjection.record(terminal: terminal, in: project)
        let wasNew = records.updateValue(record, forKey: record.destination) == nil
        recordsByProjectID[project.id] = records
        projectNames[project.id] = project.name
        if wasNew { requestedRecordCount += 1 }
        scheduleBuild()
    }

    private func scheduleBuild() {
        generation &+= 1
        let requestedGeneration = generation
        // Dictionary storage is copy-on-write. Capturing this value is constant-time; flattening
        // and indexing every standing destination happen together on the detached worker.
        let recordsByProjectID = recordsByProjectID
        let projectNames = projectNames
        buildTask?.cancel()
        buildTask = Task.detached(priority: .utility) { [weak self] in
            let records = recordsByProjectID.flatMap { projectID, records in
                let projectName = projectNames[projectID]
                return records.values.map { record in
                    projectName.map { record.replacingProjectName($0) } ?? record
                }
            }
            let built = NavigationSearchIndex(records: records)
            guard !Task.isCancelled else { return }
            await self?.accept(built, generation: requestedGeneration)
        }
    }

    private func keyed(
        _ records: [NavigationSearchRecord]
    ) -> [NavigationSearchRecord.Destination: NavigationSearchRecord] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.destination, $0) })
    }

    private func accept(_ built: NavigationSearchIndex, generation: UInt64) {
        guard generation == self.generation else { return }
        index = built
        buildTask = nil
        NotificationCenter.default.post(NavigationSearchIndexDidChange())
    }
}
