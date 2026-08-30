import Foundation

/// Projects Threading's live model into the canonical navigator fact inputs.
///
/// Full snapshots are linear in projects, sessions and terminals. Exact session and terminal
/// edges use the store's identity indexes, scheduled/control state is materialized only when its
/// own event moves, and account-scoped usage edges use an index maintained alongside projection.
@MainActor
final class LiveHostFactProjectionSource {
    struct ScheduledStartState: Equatable {
        let exists: Bool
        let dueAt: Date?
    }

    struct ControlState: Equatable {
        let managerSessionIDs: Set<SessionID>
        let managerIDByChildSessionID: [SessionID: SessionID]
    }

    struct RepositoryState: Equatable {
        let identity: HostFactRepositoryIdentity?
        let branch: String?
    }

    struct Dependencies {
        let now: () -> Date
        let projects: () -> [Project]
        let project: (ProjectID) -> Project?
        let session: (SessionID) -> AgentSession?
        let projectForSession: (SessionID) -> Project?
        let terminal: (TerminalID) -> ProjectTerminal?
        let projectForTerminal: (TerminalID) -> Project?
        let activity: (SessionID) -> SessionActivity
        let scheduledStarts: () -> [SessionID: ScheduledStartState]
        let controlState: () -> ControlState
        let repositoryState: (String) -> RepositoryState
        let terminalTitle: (ProjectTerminal, String?) -> String
        let customLimitHold: (AccountID, Date) -> CustomLimitHold
        let hasCustomConduct: (AgentSession, Project?, CustomLimitHold, Date) -> Bool
    }

    private struct ProjectionContext {
        let now: Date
        var customLimitHoldByAccountID: [AccountID: CustomLimitHold] = [:]
    }

    private let dependencies: Dependencies
    private var scheduledStartBySessionID: [SessionID: ScheduledStartState] = [:]
    private var managerSessionIDs: Set<SessionID> = []
    private var managerIDByChildSessionID: [SessionID: SessionID] = [:]
    private var accountIDBySessionID: [SessionID: AccountID] = [:]
    private var sessionIDsByAccountID: [AccountID: Set<SessionID>] = [:]
    private var projectIDBySessionID: [SessionID: ProjectID] = [:]
    private var sessionIDsByProjectID: [ProjectID: Set<SessionID>] = [:]
    private var manualOrderBySessionID: [SessionID: Int] = [:]

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    static func live(
        projectStore: ProjectStore = .shared,
        agentRuntime: AgentRuntime = .shared,
        scheduledMessages: ScheduledMessageStore = .shared,
        stateManager: StateManager = .shared,
        now: @escaping () -> Date = Date.init
    ) -> LiveHostFactProjectionSource {
        LiveHostFactProjectionSource(dependencies: Dependencies(
            now: now,
            projects: { projectStore.projects },
            project: { projectStore.project(withID: $0) },
            session: { projectStore.session(withID: $0) },
            projectForSession: { projectStore.project(forSessionID: $0) },
            terminal: { projectStore.terminal(withID: $0) },
            projectForTerminal: { projectStore.homeProject(forTerminalID: $0) },
            activity: { agentRuntime.activity(sessionID: $0) },
            scheduledStarts: {
                var result: [SessionID: ScheduledStartState] = [:]
                for message in scheduledMessages.all {
                    guard case .newSession(let plan) = message.target,
                          let sessionID = plan.reservedSessionID else { continue }
                    result[sessionID] = ScheduledStartState(
                        exists: true,
                        dueAt: message.dueAt
                    )
                }
                return result
            },
            controlState: {
                let managers = stateManager.activeManagerSessionIDs() ?? []
                var managerByChild: [SessionID: SessionID] = [:]
                for supervision in stateManager.supervisions() ?? []
                where supervision.state == .active {
                    // StateManager returns assignment order; the last active relationship is
                    // the same winner ControlGrantStore exposes for one child.
                    managerByChild[supervision.childID] = supervision.managerID
                }
                return ControlState(
                    managerSessionIDs: managers,
                    managerIDByChildSessionID: managerByChild
                )
            },
            repositoryState: { path in
                RepositoryState(
                    identity: GitInfo.remoteOriginURL(for: path)
                        .flatMap(HostFactRepositoryIdentity.init(remote:)),
                    branch: GitInfo.currentBranch(for: path)
                )
            },
            terminalTitle: { terminal, projectRoot in
                ProjectTerminalTitle.displayTitle(for: terminal, projectRoot: projectRoot)
            },
            customLimitHold: { accountID, date in
                guard let account = AgentAccountDiscovery.account(
                    for: accountID.provider,
                    handle: accountID.handle
                ) else { return .clear }
                return CustomLimitParkPolicy.hold(account: account, at: date)
            },
            hasCustomConduct: { session, project, park, date in
                RowConductSummary.forSession(
                    session,
                    project: project,
                    park: park,
                    now: date
                ) != nil
            }
        ))
    }

    func publisherDependencies(
        notificationCenter: NotificationCenter = .default,
        didPublishBatch: @escaping (_ factCount: Int, _ subjectCount: Int) -> Void = { _, _ in }
    ) -> HostFactPublisher.Dependencies {
        HostFactPublisher.Dependencies(
            notificationCenter: notificationCenter,
            now: dependencies.now,
            allProjections: { [self] in allProjections() },
            allSessionProjections: { [self] in allSessionProjections() },
            sessionProjectionsForAccount: { [self] in sessionProjections(for: $0) },
            projectionsInProject: { [self] in projections(in: $0) },
            sessionProjection: { [self] in sessionProjection(for: $0) },
            terminalProjection: { [self] in terminalProjection(for: $0) },
            prepareScheduledState: { [self] in refreshScheduledState() },
            prepareControlState: { [self] in refreshControlState() },
            didPublishBatch: didPublishBatch
        )
    }

    func refreshScheduledState() {
        scheduledStartBySessionID = dependencies.scheduledStarts()
    }

    func refreshControlState() {
        let state = dependencies.controlState()
        managerSessionIDs = state.managerSessionIDs
        managerIDByChildSessionID = state.managerIDByChildSessionID
    }

    func allProjections() -> [HostFactProjection] {
        let projects = dependencies.projects()
        rebuildSessionIndexes(from: projects)
        var context = ProjectionContext(now: dependencies.now())
        var result: [HostFactProjection] = []
        result.reserveCapacity(projects.reduce(0) {
            $0 + 1 + $1.sessions.count + $1.terminals.count
        })
        for (projectOrder, project) in projects.enumerated() {
            result.append(projectProjection(project, manualOrder: projectOrder))
            result.append(contentsOf: project.sessions.enumerated().map { sessionOrder, session in
                sessionProjection(
                    session,
                    project: project,
                    manualOrder: sessionOrder,
                    context: &context
                )
            })
            result.append(contentsOf: project.terminals.enumerated().map {
                terminalOrder, terminal in
                terminalProjection(
                    terminal,
                    project: project,
                    manualOrder: terminalOrder
                )
            })
        }
        return result
    }

    func allSessionProjections() -> [HostFactProjection] {
        let projects = dependencies.projects()
        rebuildSessionIndexes(from: projects)
        var context = ProjectionContext(now: dependencies.now())
        var result: [HostFactProjection] = []
        result.reserveCapacity(projects.reduce(0) { $0 + $1.sessions.count })
        for project in projects {
            result.append(contentsOf: project.sessions.enumerated().map { order, session in
                sessionProjection(
                    session,
                    project: project,
                    manualOrder: order,
                    context: &context
                )
            })
        }
        return result
    }

    func sessionProjections(for accountID: AccountID) -> [HostFactProjection] {
        let sessionIDs = sessionIDsByAccountID[accountID] ?? []
        var context = ProjectionContext(now: dependencies.now())
        var result: [HostFactProjection] = []
        result.reserveCapacity(sessionIDs.count)
        for sessionID in sessionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let session = dependencies.session(sessionID),
                  let project = dependencies.projectForSession(sessionID) else {
                removeSessionFromIndexes(sessionID)
                continue
            }
            let manualOrder = manualOrderBySessionID[sessionID]
                ?? project.sessions.firstIndex(where: { $0.id == sessionID })
            guard let manualOrder else { continue }
            indexSession(session, projectID: project.id, manualOrder: manualOrder)
            guard Self.accountID(for: session) == accountID,
                  accountIDBySessionID[sessionID] == accountID else { continue }
            result.append(sessionProjection(
                session,
                project: project,
                manualOrder: manualOrder,
                context: &context
            ))
        }
        return result
    }

    func projections(in projectID: ProjectID) -> [HostFactProjection] {
        guard let project = dependencies.project(projectID) else {
            removeProjectFromIndexes(projectID)
            return []
        }
        reindexSessions(in: project)
        var context = ProjectionContext(now: dependencies.now())
        var result = [projectProjection(project, manualOrder: manualOrder(of: projectID))]
        result.reserveCapacity(1 + project.sessions.count + project.terminals.count)
        result.append(contentsOf: project.sessions.enumerated().map { order, session in
            sessionProjection(
                session,
                project: project,
                manualOrder: order,
                context: &context
            )
        })
        result.append(contentsOf: project.terminals.enumerated().map { order, terminal in
            terminalProjection(terminal, project: project, manualOrder: order)
        })
        return result
    }

    func sessionProjection(for sessionID: SessionID) -> HostFactProjection? {
        guard let session = dependencies.session(sessionID),
              let project = dependencies.projectForSession(sessionID) else {
            removeSessionFromIndexes(sessionID)
            return nil
        }
        let manualOrder = manualOrderBySessionID[sessionID]
            ?? project.sessions.firstIndex(where: { $0.id == sessionID })
        guard let manualOrder else {
            removeSessionFromIndexes(sessionID)
            return nil
        }
        indexSession(session, projectID: project.id, manualOrder: manualOrder)
        var context = ProjectionContext(now: dependencies.now())
        return sessionProjection(
            session,
            project: project,
            manualOrder: manualOrder,
            context: &context
        )
    }

    func terminalProjection(for terminalID: TerminalID) -> HostFactProjection? {
        guard let terminal = dependencies.terminal(terminalID),
              let project = dependencies.projectForTerminal(terminalID),
              let manualOrder = project.terminals.firstIndex(where: { $0.id == terminalID })
        else { return nil }
        return terminalProjection(terminal, project: project, manualOrder: manualOrder)
    }

    private func projectProjection(
        _ project: Project,
        manualOrder: Int
    ) -> HostFactProjection {
        let repository = dependencies.repositoryState(project.folderPath)
        return .project(NativeSidebarProjectFacts(
            id: Self.opaqueID(project.id),
            name: project.name,
            manualOrder: manualOrder,
            isScratchpad: project.isTheScratchpad,
            createdAt: project.createdAt,
            repository: repository.identity,
            branch: repository.branch
        ))
    }

    private func sessionProjection(
        _ session: AgentSession,
        project: Project,
        manualOrder: Int,
        context: inout ProjectionContext
    ) -> HostFactProjection {
        let accountID = Self.accountID(for: session)
        let park: CustomLimitHold
        if let cached = context.customLimitHoldByAccountID[accountID] {
            park = cached
        } else {
            park = dependencies.customLimitHold(accountID, context.now)
            context.customLimitHoldByAccountID[accountID] = park
        }
        let scheduledStart = scheduledStartBySessionID[session.id]
        return .session(NativeSidebarSessionFacts(
            id: Self.opaqueID(session.id),
            projectID: Self.opaqueID(project.id),
            title: session.displayTitle,
            providerID: session.kind.rawValue,
            accountID: accountID.rawValue,
            activity: dependencies.activity(session.id),
            branch: session.branch,
            parentID: session.forkedFrom.map { Self.opaqueID($0) },
            isArchived: session.isArchived,
            usesNativeUI: session.usesNativeUI,
            isPinned: session.isPinned,
            isSnoozed: session.isSnoozed(at: context.now),
            snoozedAt: session.snoozedAt,
            snoozedUntil: session.snoozedUntil,
            wake: session.wake,
            createdAt: session.createdAt,
            lastActiveAt: session.lastActiveAt,
            lastTurnAt: session.lastTurnAt,
            manualOrder: manualOrder,
            model: session.model,
            managerID: managerIDByChildSessionID[session.id].map { Self.opaqueID($0) },
            isManager: managerSessionIDs.contains(session.id),
            hasCustomConduct: dependencies.hasCustomConduct(
                session,
                project,
                park,
                context.now
            ),
            hasScheduledStart: scheduledStart?.exists == true,
            scheduledStartAt: scheduledStart?.dueAt
        ))
    }

    private func terminalProjection(
        _ terminal: ProjectTerminal,
        project: Project,
        manualOrder: Int
    ) -> HostFactProjection {
        .terminal(NativeSidebarTerminalFacts(
            id: Self.opaqueID(terminal.id),
            projectID: Self.opaqueID(project.id),
            title: dependencies.terminalTitle(terminal, project.folderPath),
            branch: terminal.branch,
            manualOrder: manualOrder,
            createdAt: terminal.createdAt
        ))
    }

    private func manualOrder(of projectID: ProjectID) -> Int {
        dependencies.projects().firstIndex(where: { $0.id == projectID }) ?? 0
    }

    private func rebuildSessionIndexes(from projects: [Project]) {
        accountIDBySessionID.removeAll(keepingCapacity: true)
        sessionIDsByAccountID.removeAll(keepingCapacity: true)
        projectIDBySessionID.removeAll(keepingCapacity: true)
        sessionIDsByProjectID.removeAll(keepingCapacity: true)
        manualOrderBySessionID.removeAll(keepingCapacity: true)
        for project in projects {
            for (manualOrder, session) in project.sessions.enumerated() {
                indexSession(session, projectID: project.id, manualOrder: manualOrder)
            }
        }
    }

    private func reindexSessions(in project: Project) {
        let current = Set(project.sessions.map(\.id))
        for removed in (sessionIDsByProjectID[project.id] ?? []).subtracting(current) {
            removeSessionFromIndexes(removed)
        }
        for (manualOrder, session) in project.sessions.enumerated() {
            indexSession(session, projectID: project.id, manualOrder: manualOrder)
        }
    }

    private func indexSession(
        _ session: AgentSession,
        projectID: ProjectID,
        manualOrder: Int
    ) {
        manualOrderBySessionID[session.id] = manualOrder
        let accountID = Self.accountID(for: session)
        if let previous = accountIDBySessionID.updateValue(accountID, forKey: session.id),
           previous != accountID {
            sessionIDsByAccountID[previous]?.remove(session.id)
            if sessionIDsByAccountID[previous]?.isEmpty == true {
                sessionIDsByAccountID.removeValue(forKey: previous)
            }
        }
        sessionIDsByAccountID[accountID, default: []].insert(session.id)

        if let previous = projectIDBySessionID.updateValue(projectID, forKey: session.id),
           previous != projectID {
            sessionIDsByProjectID[previous]?.remove(session.id)
            if sessionIDsByProjectID[previous]?.isEmpty == true {
                sessionIDsByProjectID.removeValue(forKey: previous)
            }
        }
        sessionIDsByProjectID[projectID, default: []].insert(session.id)
    }

    private func removeProjectFromIndexes(_ projectID: ProjectID) {
        for sessionID in sessionIDsByProjectID[projectID] ?? [] {
            removeSessionFromIndexes(sessionID)
        }
        sessionIDsByProjectID.removeValue(forKey: projectID)
    }

    private func removeSessionFromIndexes(_ sessionID: SessionID) {
        manualOrderBySessionID.removeValue(forKey: sessionID)
        if let accountID = accountIDBySessionID.removeValue(forKey: sessionID) {
            sessionIDsByAccountID[accountID]?.remove(sessionID)
            if sessionIDsByAccountID[accountID]?.isEmpty == true {
                sessionIDsByAccountID.removeValue(forKey: accountID)
            }
        }
        if let projectID = projectIDBySessionID.removeValue(forKey: sessionID) {
            sessionIDsByProjectID[projectID]?.remove(sessionID)
            if sessionIDsByProjectID[projectID]?.isEmpty == true {
                sessionIDsByProjectID.removeValue(forKey: projectID)
            }
        }
    }

    private static func accountID(for session: AgentSession) -> AccountID {
        AccountID(provider: session.kind, handle: session.accountHandle)
    }

    private static func opaqueID<ID>(_ id: ID) -> String where ID: CustomStringConvertible {
        id.description.lowercased()
    }
}
