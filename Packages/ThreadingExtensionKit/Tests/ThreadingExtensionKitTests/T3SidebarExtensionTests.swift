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

    func testNavigatorDeclaresT3InspiredLifecycleSectionsAndOnlyHostOwnedIntents() throws {
        let navigator = T3SidebarExtensionContract.navigator
        let pipeline = try XCTUnwrap(navigator.pipeline)
        let pinned = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionIsPinned
        )
        let archived = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionIsArchived
        )
        let snoozed = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionIsSnoozed
        )
        let isPinned = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(pinned, fallback: .boolean(false)),
            .equal,
            .boolean(true)
        )
        let isArchived = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(archived, fallback: .boolean(false)),
            .equal,
            .boolean(true)
        )
        let isSnoozed = ExtensionWorkspaceNavigatorPredicate.comparison(
            .init(snoozed, fallback: .boolean(false)),
            .equal,
            .boolean(true)
        )

        XCTAssertEqual(navigator.id, "t3-sidebar")
        XCTAssertEqual(navigator.title, "T3 Code Threads POC")
        XCTAssertNil(navigator.loadActionID)
        XCTAssertNil(navigator.eventActionID)
        XCTAssertEqual(navigator.preferredWidth, 400)
        XCTAssertEqual(navigator.intents, [.pin, .unpin, .archive])
        XCTAssertEqual(navigator.validationIssues(path: "navigator"), [])
        XCTAssertEqual(pipeline.source, .sessions)
        XCTAssertEqual(pipeline.consumes, [
            .init(key: ExtensionHostFactKey.sessionTitle, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionProjectID, requirement: .required),
            .init(key: ExtensionHostFactKey.projectName, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionDetailedActivity, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionManualOrder, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionBranch, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionIsPinned, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionIsArchived, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionIsSnoozed, requirement: .required),
            .init(key: ExtensionHostFactKey.sessionHasScheduledStart, requirement: .required),
        ])
        XCTAssertEqual(pipeline.output.activation, .sourceSession)
        XCTAssertEqual(pipeline.output.collectionID, "t3-sessions")
        XCTAssertEqual(pipeline.output.windowing, .hostVirtualized)
        XCTAssertEqual(navigator.options, [])
        XCTAssertEqual(pipeline.registeredFactOptions, [])
        XCTAssertEqual(pipeline.filters, [])
        XCTAssertEqual(pipeline.sort, [
            .init(
                operand: .init(.init(ExtensionHostFactKey.sessionManualOrder)),
                direction: .ascending
            ),
        ])
        XCTAssertEqual(pipeline.search, .init(
            placeholder: "Search",
            accessibilityLabel: "Search threads",
            fields: [.init(ExtensionHostFactKey.sessionTitle)]
        ))
        XCTAssertEqual(templateIntents(in: pipeline.output.rowTemplate), [
            .pin, .unpin, .archive,
        ])
        XCTAssertEqual(literalStatuses(in: pipeline.output.rowTemplate), [
            "Dormant", "Waiting", "Working", "Idle", "Ready", "Attention", "Limit", "Unknown",
        ])
        XCTAssertEqual(templateFacts(in: pipeline.output.rowTemplate), Set([
            .init(ExtensionHostFactKey.sessionTitle),
            .init(ExtensionHostFactKey.sessionDetailedActivity),
            .init(ExtensionHostFactKey.sessionBranch),
            .init(ExtensionHostFactKey.projectName, scope: .project),
            .init(ExtensionHostFactKey.sessionIsPinned),
            .init(ExtensionHostFactKey.sessionIsArchived),
            .init(ExtensionHostFactKey.sessionHasScheduledStart),
        ]))

        guard case let .rules(rules, unmatched) = pipeline.buckets.first?.strategy else {
            return XCTFail("T3 POC must declare lifecycle rules in display order")
        }
        XCTAssertEqual(rules.map(\.id), ["pinned", "active", "snoozed"])
        XCTAssertEqual(rules.map(\.title), ["Pinned", "Active", "Snoozed"])
        XCTAssertEqual(rules[0].predicate, .all([
            isPinned,
            .not(isSnoozed),
            .not(isArchived),
        ]))
        XCTAssertEqual(rules[1].predicate, .all([
            .not(isSnoozed),
            .not(isArchived),
        ]))
        XCTAssertEqual(rules[2].predicate, isSnoozed)
        XCTAssertEqual(unmatched, .bucket(id: "archived", title: "Archived"))

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

    private func literalStatuses(
        in node: ExtensionWorkspaceNavigatorTemplateNode
    ) -> [String] {
        switch node {
        case let .status(.literal(value), _):
            [value]
        case let .conditional(_, content):
            literalStatuses(in: content)
        case let .stack(_, _, children):
            children.flatMap(literalStatuses(in:))
        case .text, .image, .status, .activityIndicator, .intent, .divider, .spacer,
             .flexibleSpacer:
            []
        }
    }

    private func templateFacts(
        in node: ExtensionWorkspaceNavigatorTemplateNode
    ) -> Set<ExtensionWorkspaceNavigatorFactReference> {
        switch node {
        case let .text(binding, _):
            textFacts(in: binding)
        case let .image(binding, _, _):
            switch binding {
            case .literal:
                []
            case let .factIcon(fact, _):
                [fact]
            }
        case let .status(binding, role):
            textFacts(in: binding).union(statusFacts(in: role))
        case .activityIndicator, .intent, .divider, .spacer, .flexibleSpacer:
            []
        case let .conditional(predicate, content):
            predicateFacts(in: predicate).union(templateFacts(in: content))
        case let .stack(_, _, children):
            children.reduce(into: []) { result, child in
                result.formUnion(templateFacts(in: child))
            }
        }
    }

    private func textFacts(
        in binding: ExtensionWorkspaceNavigatorTextBinding
    ) -> Set<ExtensionWorkspaceNavigatorFactReference> {
        switch binding {
        case .literal:
            []
        case let .fact(fact, _, _):
            [fact]
        }
    }

    private func statusFacts(
        in binding: ExtensionWorkspaceNavigatorStatusBinding
    ) -> Set<ExtensionWorkspaceNavigatorFactReference> {
        switch binding {
        case .literal:
            []
        case let .factStatus(fact, _):
            [fact]
        }
    }

    private func predicateFacts(
        in predicate: ExtensionWorkspaceNavigatorPredicate
    ) -> Set<ExtensionWorkspaceNavigatorFactReference> {
        switch predicate {
        case let .comparison(operand, _, _), let .relativeDate(operand, _):
            [operand.fact]
        case let .isPresent(fact):
            [fact]
        case let .all(predicates), let .any(predicates):
            predicates.reduce(into: []) { result, predicate in
                result.formUnion(predicateFacts(in: predicate))
            }
        case let .not(predicate):
            predicateFacts(in: predicate)
        }
    }
}
