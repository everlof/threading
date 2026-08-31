import ThreadingExtensionKit
import XCTest
@testable import Threading

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

        guard case .choice(_, let orders) = declarations[0].control else {
            return XCTFail("session-order must be a bounded choice")
        }
        XCTAssertEqual(
            orders.map(\.id),
            ["order-added", "recent-activity", "name", "type"]
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
}
