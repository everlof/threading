import Foundation
import ThreadingExtensionKit
import XCTest
@testable import Threading

final class HostFactCatalogTests: XCTestCase {
    private struct ExpectedDefinition: Equatable {
        let type: ExtensionFactValueType
        let subject: ExtensionFactSubjectKind
    }

    private let observedAt = Date(timeIntervalSinceReferenceDate: 999)

    func testCatalogIsTheExactValidHostVocabulary() throws {
        let definitions = HostFactCatalog.definitions
        XCTAssertEqual(definitions.count, 41)
        XCTAssertEqual(definitions.count, ExtensionHostFactKey.all.count)
        XCTAssertEqual(Set(definitions.map(\.key)), Set(ExtensionHostFactKey.all))
        XCTAssertEqual(Set(definitions.map(\.key)).count, definitions.count)

        let actual = Dictionary(uniqueKeysWithValues: definitions.map { definition in
            (
                definition.key,
                ExpectedDefinition(
                    type: definition.valueType,
                    subject: try! XCTUnwrap(definition.subjectKinds.first)
                )
            )
        })
        XCTAssertEqual(actual, expectedDefinitions)

        for definition in definitions {
            XCTAssertTrue(ExtensionHostFactKey.isReserved(definition.key))
            XCTAssertNoThrow(try definition.validate(), definition.key.id)
            XCTAssertEqual(definition.subjectKinds.count, 1, definition.key.id)
        }
    }

    func testEveryNativeDependencyHasExactlyOneDescriptor() {
        let owners = Dictionary(grouping: HostFactCatalog.all.flatMap { descriptor in
            descriptor.nativeDependencies.map { ($0, descriptor.definition.key) }
        }, by: \.0)

        XCTAssertEqual(NativeSidebarFactDependency.allCases.count, 31)
        XCTAssertEqual(Set(owners.keys), Set(NativeSidebarFactDependency.allCases))
        for dependency in NativeSidebarFactDependency.allCases {
            XCTAssertEqual(
                owners[dependency]?.count,
                1,
                "\(dependency.rawValue) must have exactly one public fact owner"
            )
        }
    }

    func testSessionProjectionPublishesExactTypedValues() throws {
        let projection = HostFactProjection.session(makeSession(activity: .awaitingUser))
        let facts = HostFactCatalog.facts(from: projection, observedAt: observedAt)
        let values = Dictionary(uniqueKeysWithValues: facts.map { ($0.key, $0.value) })

        XCTAssertEqual(facts.count, 29)
        XCTAssertLessThanOrEqual(
            facts.count,
            ExtensionFactRegistry.maximumFactsPerSourceSubject
        )
        XCTAssertEqual(values[ExtensionHostFactKey.sessionProjectID], .string("project-1"))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionCheckoutID], .string("project-1"))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionTitle], .string("A title"))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionProviderID], .string("claude"))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionAccountID], .string("claude:work"))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionActivity], .string("needs-attention"))
        XCTAssertEqual(
            values[ExtensionHostFactKey.sessionDetailedActivity],
            .string("awaiting-user")
        )
        XCTAssertEqual(values[ExtensionHostFactKey.sessionBranch], .string("release/1"))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionParentID], .string("parent-1"))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionIsSideChat], .boolean(true))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionIsArchived], .boolean(false))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionUsesNativeUI], .boolean(true))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionIsPinned], .boolean(true))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionIsSnoozed], .boolean(true))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionWakeReason], .string("input-requested"))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionManualOrder], .integer(7))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionModel], .string("opus"))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionManagerID], .string("manager-1"))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionIsManager], .boolean(true))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionHasCustomConduct], .boolean(true))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionHasScheduledStart], .boolean(true))

        for fact in facts {
            XCTAssertEqual(fact.subject, .session("session-1"))
            XCTAssertEqual(fact.observedAt, observedAt)
            XCTAssertNoThrow(try fact.validate(), fact.key.id)
            XCTAssertEqual(
                HostFactCatalog.definitions.first { $0.key == fact.key }?.valueType,
                fact.value.type
            )
        }
    }

    func testOptionalSessionValuesAreAbsentWhileBooleanStateRemainsQueryable() {
        var session = makeSession(activity: .idle)
        session = NativeSidebarSessionFacts(
            id: session.id,
            projectID: session.projectID,
            title: session.title,
            providerID: session.providerID,
            accountID: session.accountID,
            activity: session.activity,
            branch: nil,
            parentID: nil,
            isArchived: false,
            usesNativeUI: false,
            isPinned: false,
            isSnoozed: false,
            snoozedAt: nil,
            snoozedUntil: nil,
            wake: nil,
            createdAt: session.createdAt,
            lastActiveAt: session.lastActiveAt,
            lastTurnAt: nil,
            manualOrder: session.manualOrder,
            model: nil,
            managerID: nil,
            isManager: false,
            hasCustomConduct: false,
            scheduledStartAt: nil
        )
        let values = values(for: .session(session))

        for key in [
            ExtensionHostFactKey.sessionBranch,
            ExtensionHostFactKey.sessionParentID,
            ExtensionHostFactKey.sessionSnoozedAt,
            ExtensionHostFactKey.sessionSnoozedUntil,
            ExtensionHostFactKey.sessionWakeReason,
            ExtensionHostFactKey.sessionWokeAt,
            ExtensionHostFactKey.sessionLastTurnAt,
            ExtensionHostFactKey.sessionModel,
            ExtensionHostFactKey.sessionManagerID,
            ExtensionHostFactKey.sessionScheduledStartAt,
        ] {
            XCTAssertNil(values[key], key.id)
        }
        XCTAssertEqual(values[ExtensionHostFactKey.sessionIsSideChat], .boolean(false))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionIsSnoozed], .boolean(false))
        XCTAssertEqual(values[ExtensionHostFactKey.sessionHasScheduledStart], .boolean(false))
    }

    func testActivityVocabulariesRemainVersionedSideBySide() {
        let cases: [(SessionActivity, String, String)] = [
            (.dormant, "dormant", "dormant"),
            (.idle, "idle", "idle"),
            (.working, "working", "working"),
            (.awaitingUser, "needs-attention", "awaiting-user"),
            (.needsAttention, "needs-attention", "needs-attention"),
            (.limitReached, "needs-attention", "limit-reached"),
        ]

        for (activity, legacy, detailed) in cases {
            let values = values(for: .session(makeSession(activity: activity)))
            XCTAssertEqual(values[ExtensionHostFactKey.sessionActivity], .string(legacy))
            XCTAssertEqual(
                values[ExtensionHostFactKey.sessionDetailedActivity],
                .string(detailed)
            )
        }
    }

    func testWakeReasonVocabularyIsStableAndWakeFactsStayPaired() {
        let wokeAt = Date(timeIntervalSinceReferenceDate: 321)
        let cases: [(SessionWakeReason, String)] = [
            (.timeReached, "time-reached"),
            (.approvalRequested, "approval-requested"),
            (.inputRequested, "input-requested"),
            (.failed, "failed"),
            (.turnCompleted, "turn-completed"),
            (.requestedUpdate, "requested-update"),
        ]

        for (reason, spelling) in cases {
            var session = makeSession(activity: .idle)
            session = replacingWake(in: session, with: SessionWake(reason: reason, wokeAt: wokeAt))
            let values = values(for: .session(session))
            XCTAssertEqual(values[ExtensionHostFactKey.sessionWakeReason], .string(spelling))
            XCTAssertEqual(values[ExtensionHostFactKey.sessionWokeAt], .date(wokeAt))
        }
    }

    func testProjectAndTerminalProjectionsNeverPublishLocalPaths() throws {
        let project = NativeSidebarProjectFacts(
            id: "project-1",
            name: "Threading",
            manualOrder: 2,
            isScratchpad: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            repository: try XCTUnwrap(
                HostFactRepositoryIdentity(remote: "git@github.com:owner/threading.git")
            ),
            branch: "main"
        )
        let terminal = NativeSidebarTerminalFacts(
            id: "terminal-1",
            projectID: "project-1",
            title: "Server",
            branch: "main",
            manualOrder: 4,
            createdAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        let projectFacts = HostFactCatalog.facts(
            from: .project(project),
            observedAt: observedAt
        )
        let terminalFacts = HostFactCatalog.facts(
            from: .terminal(terminal),
            observedAt: observedAt
        )
        let projectValues = Dictionary(
            uniqueKeysWithValues: projectFacts.map { ($0.key, $0.value) }
        )
        let terminalValues = Dictionary(
            uniqueKeysWithValues: terminalFacts.map { ($0.key, $0.value) }
        )

        XCTAssertEqual(projectFacts.count, 7)
        XCTAssertEqual(projectValues[ExtensionHostFactKey.projectRepositoryHost], .string("github.com"))
        XCTAssertEqual(
            projectValues[ExtensionHostFactKey.projectRepositoryPath],
            .string("owner/threading")
        )
        XCTAssertFalse(projectFacts.contains { fact in
            if case .string(let value) = fact.value { return value.hasPrefix("/") }
            return false
        })
        XCTAssertEqual(terminalFacts.count, 5)
        XCTAssertEqual(terminalValues[ExtensionHostFactKey.terminalProjectID], .string("project-1"))
        XCTAssertEqual(terminalValues[ExtensionHostFactKey.terminalManualOrder], .integer(4))

        for fact in projectFacts + terminalFacts {
            XCTAssertNoThrow(try fact.validate(), fact.key.id)
        }

        XCTAssertNil(HostFactRepositoryIdentity(remote: "/Users/example/private.git"))
        XCTAssertNil(HostFactRepositoryIdentity(remote: "../private.git"))
    }

    private func values(
        for projection: HostFactProjection
    ) -> [ExtensionFactKey: ExtensionFactValue] {
        Dictionary(uniqueKeysWithValues: HostFactCatalog.facts(
            from: projection,
            observedAt: observedAt
        ).map { ($0.key, $0.value) })
    }

    private func makeSession(activity: SessionActivity) -> NativeSidebarSessionFacts {
        NativeSidebarSessionFacts(
            id: "session-1",
            projectID: "project-1",
            title: "A title",
            providerID: "claude",
            accountID: "claude:work",
            activity: activity,
            branch: "release/1",
            parentID: "parent-1",
            isArchived: false,
            usesNativeUI: true,
            isPinned: true,
            isSnoozed: true,
            snoozedAt: Date(timeIntervalSinceReferenceDate: 100),
            snoozedUntil: Date(timeIntervalSinceReferenceDate: 200),
            wake: SessionWake(
                reason: .inputRequested,
                wokeAt: Date(timeIntervalSinceReferenceDate: 300)
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            lastActiveAt: Date(timeIntervalSinceReferenceDate: 2),
            lastTurnAt: Date(timeIntervalSinceReferenceDate: 3),
            manualOrder: 7,
            model: "opus",
            managerID: "manager-1",
            isManager: true,
            hasCustomConduct: true,
            scheduledStartAt: Date(timeIntervalSinceReferenceDate: 400)
        )
    }


    private func replacingWake(
        in session: NativeSidebarSessionFacts,
        with wake: SessionWake?
    ) -> NativeSidebarSessionFacts {
        NativeSidebarSessionFacts(
            id: session.id,
            projectID: session.projectID,
            title: session.title,
            providerID: session.providerID,
            accountID: session.accountID,
            activity: session.activity,
            branch: session.branch,
            parentID: session.parentID,
            isArchived: session.isArchived,
            usesNativeUI: session.usesNativeUI,
            isPinned: session.isPinned,
            isSnoozed: session.isSnoozed,
            snoozedAt: session.snoozedAt,
            snoozedUntil: session.snoozedUntil,
            wake: wake,
            createdAt: session.createdAt,
            lastActiveAt: session.lastActiveAt,
            lastTurnAt: session.lastTurnAt,
            manualOrder: session.manualOrder,
            model: session.model,
            managerID: session.managerID,
            isManager: session.isManager,
            hasCustomConduct: session.hasCustomConduct,
            scheduledStartAt: session.scheduledStartAt
        )
    }

    private var expectedDefinitions: [ExtensionFactKey: ExpectedDefinition] {
        func expected(
            _ type: ExtensionFactValueType,
            _ subject: ExtensionFactSubjectKind
        ) -> ExpectedDefinition {
            ExpectedDefinition(type: type, subject: subject)
        }

        return [
            ExtensionHostFactKey.sessionProjectID: expected(.string, .session),
            ExtensionHostFactKey.sessionCheckoutID: expected(.string, .session),
            ExtensionHostFactKey.sessionTitle: expected(.string, .session),
            ExtensionHostFactKey.sessionProviderID: expected(.string, .session),
            ExtensionHostFactKey.sessionAccountID: expected(.string, .session),
            ExtensionHostFactKey.sessionActivity: expected(.string, .session),
            ExtensionHostFactKey.sessionDetailedActivity: expected(.string, .session),
            ExtensionHostFactKey.sessionBranch: expected(.string, .session),
            ExtensionHostFactKey.sessionParentID: expected(.string, .session),
            ExtensionHostFactKey.sessionIsSideChat: expected(.boolean, .session),
            ExtensionHostFactKey.sessionIsArchived: expected(.boolean, .session),
            ExtensionHostFactKey.sessionUsesNativeUI: expected(.boolean, .session),
            ExtensionHostFactKey.sessionIsPinned: expected(.boolean, .session),
            ExtensionHostFactKey.sessionIsSnoozed: expected(.boolean, .session),
            ExtensionHostFactKey.sessionSnoozedAt: expected(.date, .session),
            ExtensionHostFactKey.sessionSnoozedUntil: expected(.date, .session),
            ExtensionHostFactKey.sessionWakeReason: expected(.string, .session),
            ExtensionHostFactKey.sessionWokeAt: expected(.date, .session),
            ExtensionHostFactKey.sessionCreatedAt: expected(.date, .session),
            ExtensionHostFactKey.sessionLastActiveAt: expected(.date, .session),
            ExtensionHostFactKey.sessionLastTurnAt: expected(.date, .session),
            ExtensionHostFactKey.sessionLastUsedAt: expected(.date, .session),
            ExtensionHostFactKey.sessionManualOrder: expected(.integer, .session),
            ExtensionHostFactKey.sessionModel: expected(.string, .session),
            ExtensionHostFactKey.sessionManagerID: expected(.string, .session),
            ExtensionHostFactKey.sessionIsManager: expected(.boolean, .session),
            ExtensionHostFactKey.sessionHasCustomConduct: expected(.boolean, .session),
            ExtensionHostFactKey.sessionHasScheduledStart: expected(.boolean, .session),
            ExtensionHostFactKey.sessionScheduledStartAt: expected(.date, .session),
            ExtensionHostFactKey.projectName: expected(.string, .project),
            ExtensionHostFactKey.projectManualOrder: expected(.integer, .project),
            ExtensionHostFactKey.projectIsScratchpad: expected(.boolean, .project),
            ExtensionHostFactKey.projectCreatedAt: expected(.date, .project),
            ExtensionHostFactKey.projectRepositoryHost: expected(.string, .project),
            ExtensionHostFactKey.projectRepositoryPath: expected(.string, .project),
            ExtensionHostFactKey.projectBranch: expected(.string, .project),
            ExtensionHostFactKey.terminalProjectID: expected(.string, .terminal),
            ExtensionHostFactKey.terminalTitle: expected(.string, .terminal),
            ExtensionHostFactKey.terminalBranch: expected(.string, .terminal),
            ExtensionHostFactKey.terminalManualOrder: expected(.integer, .terminal),
            ExtensionHostFactKey.terminalCreatedAt: expected(.date, .terminal),
        ]
    }
}
