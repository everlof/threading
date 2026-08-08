import AppKit
import XCTest
@testable import Threading

/// The menu behind the sidebar header's arrangement control.
///
/// Same reasoning as `ThemeMenuTests`: a presented menu is unreachable from a script, so the
/// built entries are asserted directly — the rows, their checks, and the one line that is
/// conditional (the lone-branch refinement disables while grouping is off).
@MainActor
final class SidebarArrangementMenuTests: XCTestCase {

    /// Restores what was there rather than removing the key: the bundle is hosted in the app,
    /// so these writes land in the developer's own preferences.
    private func withDefault(_ value: Any?, forKey key: String, run: () throws -> Void) rethrows {
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(value, forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try run()
    }

    // MARK: - Shape

    /// Grouping first, then a separator, then one item per order, then a separator and the two
    /// directions — how the list groups is a bigger rearrangement than how it sorts, so it
    /// reads first, and a direction only means anything once an order is named.
    func testMenuOffersGroupingThenEveryOrderThenBothDirections() throws {
        try withDefault(SidebarSessionOrder.manual.rawValue, forKey: "sidebarSessionOrder") {
            let entries = ProjectSidebarViewController().arrangementMenuEntries()

            let titles = entries.map { $0.item?.title ?? "—" }
            XCTAssertEqual(
                titles,
                ["Group Sessions by Branch", "Headings for Lone Branches", "Compact Tree", "—"]
                    + SidebarSessionOrder.allCases.map(\.menuTitle)
                    + ["—", "Oldest First", "Newest First"]
            )
        }
    }

    /// The direction rows are worded for whichever order is chosen: "Descending" describes a
    /// comparator, where these have to describe a list of sessions.
    func testDirectionWordingFollowsTheChosenOrder() throws {
        try withDefault(SidebarSessionOrder.name.rawValue, forKey: "sidebarSessionOrder") {
            let titles = ProjectSidebarViewController().arrangementMenuEntries()
                .compactMap(\.item?.title)

            XCTAssertTrue(titles.contains("A to Z"))
            XCTAssertTrue(titles.contains("Z to A"))
            XCTAssertFalse(titles.contains("Oldest First"))
        }
    }

    /// The seeded defaults: both grouping toggles on, the store's own order chosen.
    func testDefaultsCarryTheirChecks() throws {
        let entries = ProjectSidebarViewController().arrangementMenuEntries()

        XCTAssertEqual(item(in: entries, titled: "Group Sessions by Branch")?.isSelected, true)
        XCTAssertEqual(item(in: entries, titled: "Headings for Lone Branches")?.isSelected, true)
        // Opt-in: the compact tree ships off.
        XCTAssertEqual(item(in: entries, titled: "Compact Tree")?.isSelected, false)

        let orderTitles = Set(SidebarSessionOrder.allCases.map(\.menuTitle))
        let checkedOrders = entries.compactMap(\.item)
            .filter { $0.isSelected && orderTitles.contains($0.title) }
        XCTAssertEqual(
            checkedOrders.map(\.title),
            [SidebarSessionOrder.manual.menuTitle],
            "exactly the chosen order should carry the check"
        )
    }

    /// The refinement refines the grouping rule, so without grouping it has nothing to say —
    /// disabled, not hidden, because a control that vanishes explains less than one that waits.
    func testLoneBranchItemDisablesWhileGroupingIsOff() throws {
        try withDefault(false, forKey: "groupsSessionsByBranch") {
            let entries = ProjectSidebarViewController().arrangementMenuEntries()
            let lone = try XCTUnwrap(item(in: entries, titled: "Headings for Lone Branches"))
            XCTAssertFalse(lone.isEnabled)
        }
    }

    // MARK: - Wiring

    /// Choosing an order writes the setting the tree builder reads. Performed through the
    /// row's own closure, which is the route the menu takes.
    func testChoosingAnOrderWritesTheSetting() throws {
        defer {
            UserDefaults.standard.removeObject(forKey: "sidebarSessionOrder")
            UserDefaults.standard.removeObject(forKey: "sidebarSessionOrderIsReversed")
        }

        let sidebar = ProjectSidebarViewController()
        let entries = sidebar.arrangementMenuEntries()
        let item = try XCTUnwrap(item(in: entries, titled: SidebarSessionOrder.name.menuTitle))

        item.onChoose?()

        XCTAssertEqual(AppSettings.shared.sidebarSessionOrder, .name)
    }

    /// Each order ships in its natural direction, and exactly one of the pair carries the check.
    func testTheNaturalDirectionCarriesTheCheckByDefault() throws {
        try withDefault(SidebarSessionOrder.recentActivity.rawValue, forKey: "sidebarSessionOrder") {
            try withDefault(false, forKey: "sidebarSessionOrderIsReversed") {
                let entries = ProjectSidebarViewController().arrangementMenuEntries()

                XCTAssertEqual(item(in: entries, titled: "Most Recent First")?.isSelected, true)
                XCTAssertEqual(item(in: entries, titled: "Least Recent First")?.isSelected, false)
            }
        }
    }

    func testChoosingTheReversedDirectionWritesTheSetting() throws {
        try withDefault(SidebarSessionOrder.recentActivity.rawValue, forKey: "sidebarSessionOrder") {
            try withDefault(false, forKey: "sidebarSessionOrderIsReversed") {
                let sidebar = ProjectSidebarViewController()
                let row = try XCTUnwrap(
                    item(in: sidebar.arrangementMenuEntries(), titled: "Least Recent First")
                )

                row.onChoose?()

                XCTAssertTrue(AppSettings.shared.sidebarSessionOrderIsReversed)
            }
        }
    }

    /// A direction is a statement about one order's field, so the next order chosen starts at
    /// its own natural end rather than inheriting a reversal made about something else.
    func testChoosingADifferentOrderResetsTheDirection() throws {
        try withDefault(SidebarSessionOrder.name.rawValue, forKey: "sidebarSessionOrder") {
            try withDefault(true, forKey: "sidebarSessionOrderIsReversed") {
                let sidebar = ProjectSidebarViewController()
                let row = try XCTUnwrap(
                    item(
                        in: sidebar.arrangementMenuEntries(),
                        titled: SidebarSessionOrder.recentActivity.menuTitle
                    )
                )

                row.onChoose?()

                XCTAssertFalse(AppSettings.shared.sidebarSessionOrderIsReversed)
            }
        }
    }

    /// Re-choosing the order already checked is not a change, so it must not quietly undo a
    /// flip the user just made.
    func testRechoosingTheSameOrderKeepsItsDirection() throws {
        try withDefault(SidebarSessionOrder.name.rawValue, forKey: "sidebarSessionOrder") {
            try withDefault(true, forKey: "sidebarSessionOrderIsReversed") {
                let sidebar = ProjectSidebarViewController()
                let row = try XCTUnwrap(
                    item(
                        in: sidebar.arrangementMenuEntries(),
                        titled: SidebarSessionOrder.name.menuTitle
                    )
                )

                row.onChoose?()

                XCTAssertTrue(AppSettings.shared.sidebarSessionOrderIsReversed)
            }
        }
    }

    // MARK: - Helpers

    private func item(in entries: [ThemedMenuEntry], titled title: String) -> ThemedMenuItem? {
        entries.compactMap(\.item).first { $0.title == title }
    }
}
