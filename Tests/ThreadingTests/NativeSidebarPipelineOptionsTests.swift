@testable import Threading
import ThreadingExtensionKit
import XCTest

@MainActor
final class NativeSidebarPipelineOptionsTests: XCTestCase {
    func testDeclaresTheExactNativeOptionVocabularyWithValidDefaults() {
        let declarations = NativeSidebarPipelineOptions.declarations

        XCTAssertEqual(
            declarations.map(\.id),
            [
                "session-order",
                "session-order-reversed",
                "branch-grouping",
                "lone-branch-headings",
                "compact-tree",
            ]
        )
        XCTAssertTrue(
            declarations.enumerated().flatMap { offset, declaration in
                declaration.validationIssues(path: "options[\(offset)]")
            }.isEmpty
        )
        XCTAssertEqual(
            declarations.map(\.control.defaultValue),
            [
                .string("order-added"),
                .bool(false),
                .bool(true),
                .bool(true),
                .bool(false),
            ]
        )

        guard case let .choice(_, orders) = declarations[0].control else {
            return XCTFail("session-order must be a bounded choice")
        }
        XCTAssertEqual(
            orders.map(\.id),
            ["order-added", "recent-activity", "name", "type"]
        )

        XCTAssertEqual(
            NativeSidebarPipelineOptions.registeredFactDeclarations.map(\.id),
            ["group-by-fact", "sort-by-fact"]
        )
        let title = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionTitle
        )
        let navigator = ExtensionWorkspaceNavigator(
            id: "native-contract-probe",
            title: "Native",
            root: .content(.status("Native", role: .neutral)),
            options: declarations,
            pipeline: .init(
                consumes: [.init(key: title.key, requirement: .required)],
                registeredFactOptions: NativeSidebarPipelineOptions.registeredFactDeclarations,
                output: .init(
                    collectionID: "sessions",
                    rowTemplate: .text(
                        .fact(title, facet: .value, fallback: "Untitled"),
                        role: .body
                    )
                )
            )
        )
        XCTAssertTrue(
            navigator.validationIssues(path: "navigator").filter {
                $0.path.contains(".registeredFactOptions")
            }.isEmpty
        )
    }

    func testEveryNativeDependencyHasOnePublicOptionOwner() {
        let ownership = NativeSidebarParity.publicOptionOwnership

        XCTAssertEqual(Set(ownership.keys), Set(NativeSidebarOptionDependency.allCases))
        XCTAssertEqual(Set(ownership.values), Set(NativeSidebarPipelineOptionID.allCases))
        XCTAssertEqual(ownership.count, NativeSidebarPipelineOptionID.allCases.count)
    }

    func testEveryLegacySessionOrderHasAStablePublicRoundTrip() {
        let expected: [SidebarSessionOrder: NativeSidebarPipelineSessionOrderValue] = [
            .manual: .orderAdded,
            .recentActivity: .recentActivity,
            .name: .name,
            .type: .type,
        ]

        for order in SidebarSessionOrder.allCases {
            let publicValue = NativeSidebarPipelineOptions.publicValue(for: order)
            XCTAssertEqual(publicValue, expected[order])
            XCTAssertEqual(NativeSidebarPipelineOptions.sessionOrder(for: publicValue), order)
        }
    }

    func testTypedSnapshotProjectsOnlyValuesAcceptedByItsDeclarations() throws {
        let values = NativeSidebarPipelineOptionValues(
            sessionOrder: .recentActivity,
            sessionOrderReversed: true,
            branchGrouping: false,
            loneBranchHeadings: true,
            compactTree: true
        )

        XCTAssertEqual(
            values.jsonValues,
            [
                "session-order": .string("recent-activity"),
                "session-order-reversed": .bool(true),
                "branch-grouping": .bool(false),
                "lone-branch-headings": .bool(true),
                "compact-tree": .bool(true),
            ]
        )
        for declaration in NativeSidebarPipelineOptions.declarations {
            let value = try XCTUnwrap(values.jsonValues[declaration.id])
            XCTAssertTrue(declaration.control.accepts(value), declaration.id)
        }
    }

    func testRecentActivityKeepsItsLegacyPersistenceWire() {
        let defaults = UserDefaults.standard
        let key = "sidebarSessionOrder"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        NativeSidebarPipelineOptions.setSessionOrder(.recentActivity)

        XCTAssertEqual(defaults.string(forKey: key), "recentActivity")
        XCTAssertEqual(NativeSidebarPipelineOptions.current.sessionOrder, .recentActivity)
        XCTAssertEqual(
            NativeSidebarPipelineOptions.current.jsonValues["session-order"],
            .string("recent-activity")
        )
    }

    func testRegisteredFactSelectionHasAValidatedStableRoundTrip() {
        let valid = ExtensionFactKey(id: "gitlab.mr.state", version: 1)
        XCTAssertEqual(NativeSidebarPipelineOptions.registeredFactWire(valid), "gitlab.mr.state@1")
        XCTAssertEqual(
            NativeSidebarPipelineOptions.selectedRegisteredFact(from: "gitlab.mr.state@1"),
            valid
        )
        XCTAssertNil(NativeSidebarPipelineOptions.selectedRegisteredFact(from: "invalid"))
        XCTAssertNil(NativeSidebarPipelineOptions.selectedRegisteredFact(from: "GitLab@1"))
        XCTAssertNil(NativeSidebarPipelineOptions.selectedRegisteredFact(from: "gitlab.mr.state@0"))
    }
}
