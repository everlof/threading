import ThreadingExtensionKit
import XCTest
@testable import Threading

@MainActor
final class HostFactPipelineTests: XCTestCase {
    func testStartIsDeferredAndScheduledOnlyOnce() throws {
        var scheduled: (@MainActor @Sendable () -> Void)?
        var scheduleCalls = 0
        let pipeline = HostFactPipeline(
            publisherDependencies: Self.emptyDependencies,
            schedule: { operation in
                scheduleCalls += 1
                scheduled = operation
            }
        )

        pipeline.startAfterFirstWindowVisible()
        pipeline.startAfterFirstWindowVisible()

        XCTAssertEqual(scheduleCalls, 1)
        XCTAssertNil(pipeline.registry.definition(for: ExtensionHostFactKey.sessionTitle))

        try XCTUnwrap(scheduled)()

        XCTAssertNotNil(pipeline.registry.definition(for: ExtensionHostFactKey.sessionTitle))
    }

    func testFailedStartWaitsForAProjectRepairBeforeRetrying() throws {
        let center = NotificationCenter()
        let registry = ExtensionFactRegistry(notificationCenter: center)
        let projectID = "project-1"
        var projectName = String(
            repeating: "x",
            count: ExtensionFactValue.maximumStringBytes + 1
        )
        var projectionCalls = 0
        var scheduled: (@MainActor @Sendable () -> Void)?
        var scheduleCalls = 0
        let pipeline = HostFactPipeline(
            registry: registry,
            publisherDependencies: Self.dependencies(
                notificationCenter: center,
                allProjections: {
                    projectionCalls += 1
                    return [.project(NativeSidebarProjectFacts(
                        id: projectID,
                        name: projectName,
                        manualOrder: 0,
                        isScratchpad: false,
                        createdAt: Date(timeIntervalSinceReferenceDate: 1),
                        repository: nil,
                        branch: nil
                    ))]
                }
            ),
            schedule: { operation in
                scheduleCalls += 1
                scheduled = operation
            }
        )

        pipeline.startAfterFirstWindowVisible()
        let refusedStart = try XCTUnwrap(scheduled)
        scheduled = nil
        refusedStart()

        let subject = ExtensionFactSubject.project(projectID)
        XCTAssertNil(registry.fact(ExtensionHostFactKey.projectName, for: subject))
        XCTAssertEqual(scheduleCalls, 1)
        XCTAssertEqual(projectionCalls, 1)

        projectName = "Repaired"
        center.post(ProjectsDidChange())

        XCTAssertEqual(scheduleCalls, 2)
        let repairedStart = try XCTUnwrap(scheduled)
        scheduled = nil
        repairedStart()

        XCTAssertEqual(
            registry.fact(ExtensionHostFactKey.projectName, for: subject)?.fact.value,
            .string("Repaired")
        )
        XCTAssertEqual(projectionCalls, 2)

        center.post(ProjectsDidChange())
        XCTAssertEqual(scheduleCalls, 2, "the retry observer survived a successful start")
    }

    private static var emptyDependencies: HostFactPublisher.Dependencies {
        dependencies(notificationCenter: .default, allProjections: { [] })
    }

    private static func dependencies(
        notificationCenter: NotificationCenter,
        allProjections: @escaping () -> [HostFactProjection]
    ) -> HostFactPublisher.Dependencies {
        HostFactPublisher.Dependencies(
            notificationCenter: notificationCenter,
            allProjections: allProjections,
            allSessionProjections: { [] },
            sessionProjectionsForAccount: { _ in [] },
            projectionsInProject: { _ in [] },
            sessionProjection: { _ in nil },
            terminalProjection: { _ in nil }
        )
    }
}
