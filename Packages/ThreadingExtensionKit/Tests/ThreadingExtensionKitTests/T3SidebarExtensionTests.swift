import Foundation
import XCTest
@testable import T3SidebarExtensionSupport
import ThreadingExtensionKit

final class T3SidebarExtensionTests: XCTestCase {
    func testManifestAndRegistrationAreTheCompletePublicBoundary() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/T3SidebarExtension/threading-extension.json")
        let decoded = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(decoded, T3SidebarExtensionContract.manifest)
        XCTAssertEqual(decoded.capabilities, [.workspaceNavigation])
        XCTAssertEqual(decoded.factDefinitions, [])
        XCTAssertEqual(decoded.networkGrants, [])
        XCTAssertEqual(
            T3SidebarExtensionContract.registration.workspaceNavigators,
            [T3SidebarExtensionContract.navigator]
        )
        try decoded.validate()
        try T3SidebarExtensionContract.registration.validate(for: decoded)
    }

    func testNavigatorPinsSessionsAndDeclaresOnlyHostOwnedRowIntents() throws {
        let navigator = T3SidebarExtensionContract.navigator
        let pipeline = try XCTUnwrap(navigator.pipeline)

        XCTAssertEqual(navigator.id, "t3-sidebar")
        XCTAssertNil(navigator.loadActionID)
        XCTAssertNil(navigator.eventActionID)
        XCTAssertEqual(navigator.intents, [.pin, .unpin, .archive])
        XCTAssertEqual(navigator.validationIssues(path: "navigator"), [])
        XCTAssertEqual(pipeline.source, .sessions)
        XCTAssertEqual(pipeline.consumes, [
            .init(key: ExtensionHostFactKey.sessionTitle, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionProjectID, requirement: .required),
            .init(key: ExtensionHostFactKey.projectName, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionIsPinned, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionIsArchived, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionLastUsedAt, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionHasScheduledStart, requirement: .required),
        ])
        XCTAssertEqual(pipeline.output.activation, .sourceSession)
        XCTAssertEqual(pipeline.output.collectionID, "t3-sessions")
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
        XCTAssertEqual(templateIntents(in: pipeline.output.rowTemplate), [
            .pin, .unpin, .archive,
        ])

        guard case let .rules(rules, unmatched) = pipeline.buckets.first?.strategy else {
            return XCTFail("T3 Sidebar must put the pinned rule before the remaining sessions")
        }
        XCTAssertEqual(rules.map(\.id), ["pinned"])
        XCTAssertEqual(rules.map(\.title), ["Pinned"])
        XCTAssertEqual(unmatched, .bucket(id: "sessions", title: "Sessions"))

        let encoded = try JSONEncoder().encode(navigator)
        XCTAssertEqual(
            try JSONDecoder().decode(ExtensionWorkspaceNavigator.self, from: encoded),
            navigator
        )
    }

    private func templateIntents(
        in node: ExtensionWorkspaceNavigatorTemplateNode
    ) -> [ExtensionWorkspaceNavigatorIntent] {
        switch node {
        case let .intent(intent):
            [intent]
        case let .conditional(_, content):
            templateIntents(in: content)
        case let .stack(_, _, children):
            children.flatMap(templateIntents(in:))
        case .text, .image, .status, .activityIndicator, .divider, .spacer, .flexibleSpacer:
            []
        }
    }
}
