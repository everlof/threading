import Foundation
import ThreadingExtensionKit
import XCTest
@testable import Threading

@MainActor
final class LiveHostFactProjectionSourceTests: XCTestCase {
    func testFullProjectionMapsLiveStateAndKeepsUndatedScheduledStart() throws {
        let managerID = SessionID()
        var project = Project(
            name: "Workspace",
            folderURL: URL(fileURLWithPath: "/tmp/threading-live-facts")
        )
        project.isScratchpad = true
        var session = AgentSession(
            kind: .claude,
            title: "Original",
            accountHandle: .named("work"),
            model: "opus",
            usesNativeUI: true
        )
        session.customTitle = "Chosen title"
        session.branch = "release/2"
        session.isPinned = true
        session.snoozedAt = Date(timeIntervalSinceReferenceDate: 400)
        session.snoozedUntil = Date(timeIntervalSinceReferenceDate: 600)
        session.wake = SessionWake(
            reason: .approvalRequested,
            wokeAt: Date(timeIntervalSinceReferenceDate: 450)
        )
        session.lastActiveAt = Date(timeIntervalSinceReferenceDate: 300)
        session.lastTurnAt = Date(timeIntervalSinceReferenceDate: 350)
        session.lastWorkAt = Date(timeIntervalSinceReferenceDate: 375)
        var terminal = ProjectTerminal(
            currentDirectory: project.folderPath,
            title: "Stored terminal"
        )
        terminal.branch = "terminal-branch"
        project.sessions = [session]
        project.terminals = [terminal]

        let harness = Harness(projects: [project])
        harness.activities[session.id] = .awaitingUser
        harness.scheduledStarts[session.id] = .init(exists: true, dueAt: nil)
        harness.controlState = .init(
            managerSessionIDs: [session.id],
            managerIDByChildSessionID: [session.id: managerID]
        )
        harness.repositoryState = .init(
            identity: try XCTUnwrap(HostFactRepositoryIdentity(
                remote: "https://github.com/acme/threading.git"
            )),
            branch: "main"
        )
        harness.reportsCustomConduct = true
        let source = LiveHostFactProjectionSource(dependencies: harness.dependencies)

        source.refreshScheduledState()
        source.refreshControlState()
        let projections = source.allProjections()

        XCTAssertEqual(projections.count, 3)
        let projectFacts = try XCTUnwrap(projections.compactMap(Self.projectFacts).first)
        XCTAssertEqual(projectFacts.id, project.id.uuidString.lowercased())
        XCTAssertEqual(projectFacts.name, "Workspace")
        XCTAssertEqual(projectFacts.manualOrder, 0)
        XCTAssertTrue(projectFacts.isScratchpad)
        XCTAssertEqual(projectFacts.repository?.host, "github.com")
        XCTAssertEqual(projectFacts.repository?.path, "acme/threading")
        XCTAssertEqual(projectFacts.branch, "main")

        let sessionFacts = try XCTUnwrap(projections.compactMap(Self.sessionFacts).first)
        XCTAssertEqual(sessionFacts.projectID, project.id.uuidString.lowercased())
        XCTAssertEqual(sessionFacts.title, "Chosen title")
        XCTAssertEqual(sessionFacts.providerID, "claude")
        XCTAssertEqual(sessionFacts.accountID, "claude:work")
        XCTAssertEqual(sessionFacts.activity, .awaitingUser)
        XCTAssertEqual(sessionFacts.lastWorkAt, session.lastWorkAt)
        XCTAssertEqual(sessionFacts.branch, "release/2")
        XCTAssertTrue(sessionFacts.usesNativeUI)
        XCTAssertTrue(sessionFacts.isPinned)
        XCTAssertTrue(sessionFacts.isSnoozed)
        XCTAssertEqual(sessionFacts.model, "opus")
        XCTAssertEqual(sessionFacts.managerID, managerID.uuidString.lowercased())
        XCTAssertTrue(sessionFacts.isManager)
        XCTAssertTrue(sessionFacts.hasCustomConduct)
        XCTAssertTrue(sessionFacts.hasScheduledStart)
        XCTAssertNil(sessionFacts.scheduledStartAt)

        let terminalFacts = try XCTUnwrap(projections.compactMap(Self.terminalFacts).first)
        XCTAssertEqual(terminalFacts.projectID, project.id.uuidString.lowercased())
        XCTAssertEqual(terminalFacts.title, "Live terminal")
        XCTAssertEqual(terminalFacts.branch, "terminal-branch")
        XCTAssertEqual(terminalFacts.manualOrder, 0)

        XCTAssertEqual(harness.projectsCalls, 1)
        XCTAssertEqual(harness.repositoryCalls, 1)
        XCTAssertEqual(harness.activityCalls, 1)
        XCTAssertEqual(harness.customLimitHoldCalls, 1)
        XCTAssertEqual(harness.customConductCalls, 1)
        XCTAssertEqual(harness.scheduledStateCalls, 1)
        XCTAssertEqual(harness.controlStateCalls, 1)
    }

    func testFiveThousandSnapshotIsLinearAndExactAndAccountReadsStayTargeted() throws {
        var project = Project(
            name: "Large",
            folderURL: URL(fileURLWithPath: "/tmp/threading-large-live-facts")
        )
        var sessions: [AgentSession] = []
        sessions.reserveCapacity(5_000)
        for offset in 0..<4_999 {
            var session = AgentSession(kind: .claude, title: "Session \(offset)")
            session.customTitle = "Session \(offset)"
            sessions.append(session)
        }
        var work = AgentSession(
            kind: .claude,
            title: "Work",
            accountHandle: .named("work")
        )
        work.customTitle = "Work"
        sessions.append(work)
        project.sessions = sessions

        let harness = Harness(projects: [project])
        let source = LiveHostFactProjectionSource(dependencies: harness.dependencies)
        source.refreshScheduledState()
        source.refreshControlState()

        let all = source.allProjections()

        XCTAssertEqual(all.count, 5_001)
        XCTAssertEqual(harness.projectsCalls, 1)
        XCTAssertEqual(harness.repositoryCalls, 1)
        XCTAssertEqual(harness.activityCalls, 5_000)
        XCTAssertEqual(harness.customLimitHoldCalls, 2)
        XCTAssertEqual(harness.customConductCalls, 5_000)

        harness.resetProjectionCounters()
        let exact = try XCTUnwrap(source.sessionProjection(for: work.id))
        XCTAssertEqual(Self.sessionFacts(exact)?.manualOrder, 4_999)
        XCTAssertEqual(harness.projectsCalls, 0)
        XCTAssertEqual(harness.sessionCalls, 1)
        XCTAssertEqual(harness.projectForSessionCalls, 1)
        XCTAssertEqual(harness.activityCalls, 1)
        XCTAssertEqual(harness.customLimitHoldCalls, 1)
        XCTAssertEqual(harness.customConductCalls, 1)

        harness.resetProjectionCounters()
        let accountID = AccountID(provider: .claude, handle: .named("work"))
        let account = source.sessionProjections(for: accountID)
        XCTAssertEqual(account.count, 1)
        XCTAssertEqual(Self.sessionFacts(account[0])?.id, work.id.uuidString.lowercased())
        XCTAssertEqual(harness.projectsCalls, 0)
        XCTAssertEqual(harness.sessionCalls, 1)
        XCTAssertEqual(harness.projectForSessionCalls, 1)
        XCTAssertEqual(harness.activityCalls, 1)
    }

    func testSessionRemovalRepublishesShiftedManualOrder() throws {
        var project = Project(
            name: "Ordered",
            folderURL: URL(fileURLWithPath: "/tmp/threading-ordered-live-facts")
        )
        var first = AgentSession(kind: .claude, title: "First")
        first.customTitle = "First"
        var second = AgentSession(kind: .claude, title: "Second")
        second.customTitle = "Second"
        project.sessions = [first, second]

        let harness = Harness(projects: [project])
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
        let source = LiveHostFactProjectionSource(dependencies: harness.dependencies)
        let publisher = HostFactPublisher(
            registry: registry,
            dependencies: source.publisherDependencies(notificationCenter: center)
        )
        try publisher.start()

        let secondSubject = ExtensionFactSubject.session(second.id.uuidString.lowercased())
        XCTAssertEqual(
            registry.exactFact(
                ExtensionHostFactKey.sessionManualOrder,
                for: secondSubject
            )?.fact.value,
            .integer(1)
        )

        project.sessions.removeFirst()
        harness.replaceProjects([project])
        center.post(ProjectsDidChange(sidebarImpact: .sessionRemoved(
            projectID: project.id,
            sessionID: first.id
        )))

        let firstSubject = ExtensionFactSubject.session(first.id.uuidString.lowercased())
        XCTAssertTrue(registry.exactFacts(for: firstSubject).isEmpty)
        XCTAssertEqual(
            registry.exactFact(
                ExtensionHostFactKey.sessionManualOrder,
                for: secondSubject
            )?.fact.value,
            .integer(0)
        )
    }

    private final class Harness {
        private(set) var projectsValue: [Project] = []
        private(set) var projectByID: [ProjectID: Project] = [:]
        private(set) var sessionByID: [SessionID: AgentSession] = [:]
        private(set) var projectBySessionID: [SessionID: Project] = [:]
        private(set) var terminalByID: [TerminalID: ProjectTerminal] = [:]
        private(set) var projectByTerminalID: [TerminalID: Project] = [:]
        var activities: [SessionID: SessionActivity] = [:]
        var scheduledStarts: [
            SessionID: LiveHostFactProjectionSource.ScheduledStartState
        ] = [:]
        var controlState = LiveHostFactProjectionSource.ControlState(
            managerSessionIDs: [],
            managerIDByChildSessionID: [:]
        )
        var repositoryState = LiveHostFactProjectionSource.RepositoryState(
            identity: nil,
            branch: nil
        )
        var reportsCustomConduct = false

        var projectsCalls = 0
        var projectCalls = 0
        var sessionCalls = 0
        var projectForSessionCalls = 0
        var terminalCalls = 0
        var projectForTerminalCalls = 0
        var activityCalls = 0
        var scheduledStateCalls = 0
        var controlStateCalls = 0
        var repositoryCalls = 0
        var terminalTitleCalls = 0
        var customLimitHoldCalls = 0
        var customConductCalls = 0

        init(projects: [Project]) {
            replaceProjects(projects)
        }

        func replaceProjects(_ projects: [Project]) {
            projectsValue = projects
            projectByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
            sessionByID = Dictionary(uniqueKeysWithValues: projects.flatMap { project in
                project.sessions.map { ($0.id, $0) }
            })
            projectBySessionID = Dictionary(uniqueKeysWithValues: projects.flatMap { project in
                project.sessions.map { ($0.id, project) }
            })
            terminalByID = Dictionary(uniqueKeysWithValues: projects.flatMap { project in
                project.terminals.map { ($0.id, $0) }
            })
            projectByTerminalID = Dictionary(uniqueKeysWithValues: projects.flatMap { project in
                project.terminals.map { ($0.id, project) }
            })
        }

        var dependencies: LiveHostFactProjectionSource.Dependencies {
            LiveHostFactProjectionSource.Dependencies(
                now: { Date(timeIntervalSinceReferenceDate: 500) },
                projects: { [unowned self] in
                    projectsCalls += 1
                    return projectsValue
                },
                project: { [unowned self] id in
                    projectCalls += 1
                    return projectByID[id]
                },
                session: { [unowned self] id in
                    sessionCalls += 1
                    return sessionByID[id]
                },
                projectForSession: { [unowned self] id in
                    projectForSessionCalls += 1
                    return projectBySessionID[id]
                },
                terminal: { [unowned self] id in
                    terminalCalls += 1
                    return terminalByID[id]
                },
                projectForTerminal: { [unowned self] id in
                    projectForTerminalCalls += 1
                    return projectByTerminalID[id]
                },
                activity: { [unowned self] id in
                    activityCalls += 1
                    return activities[id] ?? .dormant
                },
                scheduledStarts: { [unowned self] in
                    scheduledStateCalls += 1
                    return scheduledStarts
                },
                controlState: { [unowned self] in
                    controlStateCalls += 1
                    return controlState
                },
                repositoryState: { [unowned self] _ in
                    repositoryCalls += 1
                    return repositoryState
                },
                terminalTitle: { [unowned self] _, _ in
                    terminalTitleCalls += 1
                    return "Live terminal"
                },
                customLimitHold: { [unowned self] _, _ in
                    customLimitHoldCalls += 1
                    return .clear
                },
                hasCustomConduct: { [unowned self] _, _, _, _ in
                    customConductCalls += 1
                    return reportsCustomConduct
                }
            )
        }

        func resetProjectionCounters() {
            projectsCalls = 0
            projectCalls = 0
            sessionCalls = 0
            projectForSessionCalls = 0
            terminalCalls = 0
            projectForTerminalCalls = 0
            activityCalls = 0
            repositoryCalls = 0
            terminalTitleCalls = 0
            customLimitHoldCalls = 0
            customConductCalls = 0
        }
    }

    nonisolated private static func projectFacts(
        _ projection: HostFactProjection
    ) -> NativeSidebarProjectFacts? {
        guard case .project(let facts) = projection else { return nil }
        return facts
    }

    nonisolated private static func sessionFacts(
        _ projection: HostFactProjection
    ) -> NativeSidebarSessionFacts? {
        guard case .session(let facts) = projection else { return nil }
        return facts
    }

    nonisolated private static func terminalFacts(
        _ projection: HostFactProjection
    ) -> NativeSidebarTerminalFacts? {
        guard case .terminal(let facts) = projection else { return nil }
        return facts
    }
}
