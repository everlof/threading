import Foundation
import XCTest
@testable import ActivityInboxExtensionSupport
import ThreadingExtensionKit

final class ActivityInboxExtensionTests: XCTestCase {
    func testManifestAndRegistrationAreTheCompletePublicBoundary() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/ActivityInboxExtension/threading-extension.json")
        let decoded = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(decoded, ActivityInboxExtensionContract.manifest)
        XCTAssertEqual(decoded.capabilities, [.workspaceNavigation])
        XCTAssertEqual(decoded.factDefinitions, [])
        XCTAssertEqual(decoded.networkGrants, [])
        XCTAssertEqual(
            ActivityInboxExtensionContract.registration.workspaceNavigators,
            [ActivityInboxExtensionContract.navigator]
        )
        try decoded.validate()
        try ActivityInboxExtensionContract.registration.validate(for: decoded)
    }

    func testNavigatorPinsTheInboxSectionsAndHostOwnedLiveBehavior() throws {
        let navigator = ActivityInboxExtensionContract.navigator
        let pipeline = try XCTUnwrap(navigator.pipeline)

        XCTAssertEqual(navigator.id, "activity-inbox")
        XCTAssertNil(navigator.loadActionID)
        XCTAssertNil(navigator.eventActionID)
        XCTAssertEqual(navigator.preferredWidth, 280)
        XCTAssertEqual(navigator.validationIssues(path: "navigator"), [])
        XCTAssertEqual(pipeline.source, .sessions)
        XCTAssertEqual(pipeline.consumes, [
            .init(key: ExtensionHostFactKey.sessionTitle, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionDetailedActivity, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionLastUsedAt, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionIsArchived, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionIsSnoozed, requirement: .required),
        ])
        XCTAssertEqual(pipeline.output.activation, .sourceSession)
        XCTAssertEqual(pipeline.output.collectionID, "activity-sessions")
        XCTAssertEqual(pipeline.output.windowing, .hostVirtualized)
        XCTAssertEqual(navigator.options.map(\.id), ["sort-order"])
        XCTAssertEqual(pipeline.registeredFactOptions, [
            .init(
                id: "group-by-fact",
                title: "Group by",
                application: .bucket(direction: .ascending, unknownTitle: "Unknown")
            ),
            .init(
                id: "sort-by-fact",
                title: "Sort by",
                application: .sort(direction: .ascending)
            ),
        ])

        guard case let .rules(rules, unmatched) = pipeline.buckets.first?.strategy else {
            return XCTFail("Activity Inbox must use ordered host-evaluated rule buckets")
        }
        XCTAssertEqual(rules.map(\.id), [
            "priority", "today", "yesterday", "last-seven-days",
        ])
        XCTAssertEqual(rules.map(\.title), [
            "Priority", "Today", "Yesterday", "Last 7 days",
        ])
        XCTAssertEqual(unmatched, .omit)

        let encoded = try JSONEncoder().encode(navigator)
        XCTAssertEqual(
            try JSONDecoder().decode(ExtensionWorkspaceNavigator.self, from: encoded),
            navigator
        )
    }
}
