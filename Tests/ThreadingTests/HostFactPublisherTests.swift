import Foundation
import ThreadingExtensionKit
import XCTest
@testable import Threading

@MainActor
final class HostFactPublisherTests: XCTestCase {
    func testStartPublishesDefinitionsAndEveryProjectionKind() throws {
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
        let projectID = ProjectID()
        let sessionID = SessionID()
        let terminalID = TerminalID()
        let harness = Harness(center: center, projections: [
            Self.makeProject(id: projectID),
            Self.makeSession(id: sessionID, projectID: projectID),
            Self.makeTerminal(id: terminalID, projectID: projectID),
        ])
        let publisher = HostFactPublisher(registry: registry, dependencies: harness.dependencies)

        try publisher.start()

        XCTAssertEqual(registry.definition(for: ExtensionHostFactKey.sessionTitle)?.valueType, .string)
        XCTAssertEqual(registry.exactFacts(for: .session(Self.opaque(sessionID))).count, 19)
        XCTAssertEqual(registry.exactFacts(for: .project(Self.opaque(projectID))).count, 4)
        XCTAssertEqual(registry.exactFacts(for: .terminal(Self.opaque(terminalID))).count, 4)
        XCTAssertEqual(harness.allProjectionCalls, 1)
        XCTAssertEqual(harness.prepareScheduledCalls, 1)
        XCTAssertEqual(harness.prepareControlCalls, 1)
    }

    func testFiveThousandSessionsStayBoundedAndActivityRefreshIsConstantWork() throws {
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
        let projectID = ProjectID()
        let sessionIDs = (0..<5_000).map { _ in SessionID() }
        let harness = Harness(
            center: center,
            projections: sessionIDs.enumerated().map { offset, sessionID in
                Self.makeSession(id: sessionID, projectID: projectID, manualOrder: offset)
            }
        )
        let publisher = HostFactPublisher(registry: registry, dependencies: harness.dependencies)

        try publisher.start()

        XCTAssertGreaterThan(harness.batches.count, 1)
        XCTAssertTrue(harness.batches.allSatisfy {
            $0.facts <= ExtensionFactRegistry.maximumFactsPerReplacement
                && $0.subjects <= ExtensionFactRegistry.maximumSubjectsPerReplacement
        })
        XCTAssertEqual(harness.batches.reduce(0) { $0 + $1.facts }, 5_000 * 19)
        XCTAssertEqual(registry.exactFacts(for: .session(Self.opaque(sessionIDs.last!))).count, 19)

        harness.batches.removeAll()
        harness.sessionProjectionCalls = 0
        let allCallsBeforeEdge = harness.allProjectionCalls
        harness.store(Self.makeSession(
            id: sessionIDs[2_500],
            projectID: projectID,
            activity: .working,
            manualOrder: 2_500
        ))
        center.post(SessionActivityDidChange(sessionID: sessionIDs[2_500]))

        XCTAssertEqual(harness.sessionProjectionCalls, 1)
        XCTAssertEqual(harness.allProjectionCalls, allCallsBeforeEdge)
        XCTAssertEqual(harness.batches, [Batch(facts: 19, subjects: 1)])
        XCTAssertEqual(
            registry.exactFact(
                ExtensionHostFactKey.sessionDetailedActivity,
                for: .session(Self.opaque(sessionIDs[2_500]))
            )?.fact.value,
            .string("working")
        )

        harness.projections.removeAll()
        harness.batches.removeAll()
        try publisher.refreshAll()
        XCTAssertEqual(harness.batches, [
            Batch(facts: 0, subjects: 2_048),
            Batch(facts: 0, subjects: 2_048),
            Batch(facts: 0, subjects: 904),
        ])
        XCTAssertTrue(registry.exactFacts(for: .session(Self.opaque(sessionIDs[2_500]))).isEmpty)
    }

    func testLateBatchFailureIsAtomicAndARepairedStartCanRetry() throws {
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
        let projectID = ProjectID()
        let validIDs = (0..<108).map { Self.orderedSessionID(UInt32($0)) }
        let invalidID = Self.orderedSessionID(UInt32.max)
        let harness = Harness(
            center: center,
            projections: validIDs.enumerated().map { offset, sessionID in
                Self.makeSession(id: sessionID, projectID: projectID, manualOrder: offset)
            } + [Self.makeSession(
                id: invalidID,
                projectID: projectID,
                title: String(repeating: "x", count: ExtensionFactValue.maximumStringBytes + 1),
                manualOrder: validIDs.count
            )]
        )
        let publisher = HostFactPublisher(registry: registry, dependencies: harness.dependencies)

        XCTAssertThrowsError(try publisher.start())
        XCTAssertTrue(harness.batches.isEmpty)
        XCTAssertTrue(registry.exactFacts(for: .session(Self.opaque(validIDs[0]))).isEmpty)
        XCTAssertTrue(registry.exactFacts(for: .session(Self.opaque(validIDs[107]))).isEmpty)

        harness.remove(.session(Self.opaque(invalidID)))
        try publisher.start()
        XCTAssertEqual(harness.batches.count, 2)
        XCTAssertEqual(harness.batches.reduce(0) { $0 + $1.facts }, validIDs.count * 19)
        XCTAssertEqual(registry.exactFacts(for: .session(Self.opaque(validIDs[107]))).count, 19)
        XCTAssertTrue(registry.exactFacts(for: .session(Self.opaque(invalidID))).isEmpty)

        let allProjectionCallsAfterSuccess = harness.allProjectionCalls
        try publisher.start()
        XCTAssertEqual(harness.allProjectionCalls, allProjectionCallsAfterSuccess)
    }

    func testRemovalEventRefreshesTheProjectAndDeletesTheNamedSession() throws {
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
        let projectID = ProjectID()
        let removedID = SessionID()
        let standingID = SessionID()
        let harness = Harness(center: center, projections: [
            Self.makeSession(id: removedID, projectID: projectID),
            Self.makeSession(id: standingID, projectID: projectID),
        ])
        let publisher = HostFactPublisher(registry: registry, dependencies: harness.dependencies)
        try publisher.start()

        harness.remove(.session(Self.opaque(removedID)))
        harness.store(Self.makeSession(
            id: standingID,
            projectID: projectID,
            manualOrder: 0
        ))
        harness.batches.removeAll()
        center.post(ProjectsDidChange(sidebarImpact: .sessionRemoved(
            projectID: projectID,
            sessionID: removedID
        )))

        XCTAssertTrue(registry.exactFacts(for: .session(Self.opaque(removedID))).isEmpty)
        XCTAssertEqual(registry.exactFacts(for: .session(Self.opaque(standingID))).count, 19)
        XCTAssertEqual(harness.batches, [Batch(facts: 19, subjects: 2)])
    }

    func testProjectRowEventDoesNotReprojectItsSessions() throws {
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
        let projectID = ProjectID()
        let sessionIDs = (0..<5_000).map { _ in SessionID() }
        let harness = Harness(center: center, projections: [Self.makeProject(id: projectID)]
            + sessionIDs.enumerated().map { offset, sessionID in
                Self.makeSession(id: sessionID, projectID: projectID, manualOrder: offset)
            })
        let publisher = HostFactPublisher(registry: registry, dependencies: harness.dependencies)
        try publisher.start()

        harness.store(Self.makeProject(id: projectID, name: "Renamed"))
        harness.batches.removeAll()
        let allCalls = harness.allProjectionCalls
        center.post(ProjectsDidChange(sidebarImpact: .projectRow(projectID)))

        XCTAssertEqual(harness.projectProjectionCalls, 1)
        XCTAssertEqual(harness.allProjectionCalls, allCalls)
        XCTAssertEqual(harness.batches, [Batch(facts: 4, subjects: 1)])
        XCTAssertEqual(
            registry.exactFact(
                ExtensionHostFactKey.projectName,
                for: .project(Self.opaque(projectID))
            )?.fact.value,
            .string("Renamed")
        )
    }

    func testDuplicateSubjectRefusesTheWholeRefresh() throws {
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
        let projectID = ProjectID()
        let sessionID = SessionID()
        let duplicate = Self.makeSession(id: sessionID, projectID: projectID)
        let harness = Harness(center: center, projections: [duplicate, duplicate])
        let publisher = HostFactPublisher(registry: registry, dependencies: harness.dependencies)

        XCTAssertThrowsError(try publisher.start()) { error in
            XCTAssertEqual(
                error as? HostFactPublisherError,
                .duplicateSubject(.session(Self.opaque(sessionID)))
            )
        }
        XCTAssertTrue(registry.exactFacts(for: .session(Self.opaque(sessionID))).isEmpty)
        XCTAssertTrue(harness.batches.isEmpty)
    }

    private struct Batch: Equatable {
        let facts: Int
        let subjects: Int
    }

    private final class Harness {
        let center: NotificationCenter
        var projections: [HostFactProjection]
        var batches: [Batch] = []
        var allProjectionCalls = 0
        var allSessionProjectionCalls = 0
        var projectProjectionCalls = 0
        var sessionProjectionCalls = 0
        var prepareScheduledCalls = 0
        var prepareControlCalls = 0

        init(center: NotificationCenter, projections: [HostFactProjection]) {
            self.center = center
            self.projections = projections
        }

        var dependencies: HostFactPublisher.Dependencies {
            HostFactPublisher.Dependencies(
                notificationCenter: center,
                now: { Date(timeIntervalSinceReferenceDate: 500) },
                allProjections: { [unowned self] in
                    allProjectionCalls += 1
                    return projections
                },
                allSessionProjections: { [unowned self] in
                    allSessionProjectionCalls += 1
                    return projections.filter { $0.subject.kind == .session }
                },
                sessionProjectionsForAccount: { [unowned self] accountID in
                    projections.filter { projection in
                        guard case .session(let facts) = projection else { return false }
                        return facts.accountID == accountID.rawValue
                    }
                },
                projectionsInProject: { [unowned self] projectID in
                    let key = HostFactPublisherTests.opaque(projectID)
                    return projections.filter { HostFactPublisherTests.projectID(of: $0) == key }
                },
                projectProjection: { [unowned self] projectID in
                    projectProjectionCalls += 1
                    let subject = ExtensionFactSubject.project(
                        HostFactPublisherTests.opaque(projectID)
                    )
                    return projections.first { $0.subject == subject }
                },
                sessionProjection: { [unowned self] sessionID in
                    sessionProjectionCalls += 1
                    let subject = ExtensionFactSubject.session(
                        HostFactPublisherTests.opaque(sessionID)
                    )
                    return projections.first { $0.subject == subject }
                },
                terminalProjection: { [unowned self] terminalID in
                    let subject = ExtensionFactSubject.terminal(
                        HostFactPublisherTests.opaque(terminalID)
                    )
                    return projections.first { $0.subject == subject }
                },
                prepareScheduledState: { [unowned self] in prepareScheduledCalls += 1 },
                prepareControlState: { [unowned self] in prepareControlCalls += 1 },
                didPublishBatch: { [unowned self] facts, subjects in
                    batches.append(.init(facts: facts, subjects: subjects))
                }
            )
        }

        func store(_ projection: HostFactProjection) {
            remove(projection.subject)
            projections.append(projection)
        }

        func remove(_ subject: ExtensionFactSubject) {
            projections.removeAll { $0.subject == subject }
        }
    }

    private static func makeSession(
        id: SessionID,
        projectID: ProjectID,
        activity: SessionActivity = .idle,
        title: String? = nil,
        manualOrder: Int = 0
    ) -> HostFactProjection {
        .session(NativeSidebarSessionFacts(
            id: opaque(id),
            projectID: opaque(projectID),
            title: title ?? "Session \(manualOrder)",
            providerID: "claude",
            accountID: "claude:standard",
            activity: activity,
            branch: nil,
            parentID: nil,
            isArchived: false,
            usesNativeUI: false,
            isPinned: false,
            isSnoozed: false,
            snoozedAt: nil,
            snoozedUntil: nil,
            wake: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            lastActiveAt: Date(timeIntervalSinceReferenceDate: 2),
            lastTurnAt: nil,
            manualOrder: manualOrder,
            model: nil,
            managerID: nil,
            isManager: false,
            hasCustomConduct: false,
            hasScheduledStart: false,
            scheduledStartAt: nil
        ))
    }

    private static func makeProject(
        id: ProjectID,
        name: String = "Project"
    ) -> HostFactProjection {
        .project(NativeSidebarProjectFacts(
            id: opaque(id),
            name: name,
            manualOrder: 0,
            isScratchpad: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            repository: nil,
            branch: nil
        ))
    }

    private static func makeTerminal(
        id: TerminalID,
        projectID: ProjectID
    ) -> HostFactProjection {
        .terminal(NativeSidebarTerminalFacts(
            id: opaque(id),
            projectID: opaque(projectID),
            title: "Terminal",
            branch: nil,
            manualOrder: 0,
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        ))
    }

    nonisolated private static func projectID(of projection: HostFactProjection) -> String {
        switch projection {
        case .session(let facts): facts.projectID
        case .project(let facts): facts.id
        case .terminal(let facts): facts.projectID
        }
    }

    nonisolated private static func opaque<ID>(_ id: ID) -> String
    where ID: CustomStringConvertible {
        id.description.lowercased()
    }

    nonisolated private static func orderedSessionID(_ prefix: UInt32) -> SessionID {
        SessionID(UUID(uuidString: String(
            format: "%08X-0000-0000-0000-000000000000",
            prefix
        ))!)
    }
}
