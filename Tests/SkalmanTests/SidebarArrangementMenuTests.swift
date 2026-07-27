import AppKit
import XCTest
@testable import Skalman

/// The menu behind the sidebar header's arrangement control.
///
/// Same reasoning as `ThemeMenuTests`: a popped menu is modal and unreachable from a script,
/// so the built menu is asserted directly — the items, their checks, and the one line that is
/// conditional (the lone-branch refinement disables while grouping is off).
@MainActor
final class SidebarArrangementMenuTests: XCTestCase {

    private func withDefault(_ value: Any?, forKey key: String, run: () throws -> Void) rethrows {
        UserDefaults.standard.set(value, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        try run()
    }

    // MARK: - Shape

    /// Grouping first, then a separator, then one item per order — how the list groups is a
    /// bigger rearrangement than how it sorts, so it reads first.
    func testMenuOffersGroupingThenEveryOrder() {
        let menu = ProjectSidebarViewController().makeArrangementMenu()

        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        XCTAssertEqual(
            titles,
            ["Group Sessions by Branch", "Headings for Lone Branches", "—"]
                + SidebarSessionOrder.allCases.map(\.menuTitle)
        )
    }

    /// The seeded defaults: both grouping toggles on, the store's own order chosen.
    func testDefaultsCarryTheirChecks() throws {
        let menu = ProjectSidebarViewController().makeArrangementMenu()

        XCTAssertEqual(menu.item(withTitle: "Group Sessions by Branch")?.state, .on)
        XCTAssertEqual(menu.item(withTitle: "Headings for Lone Branches")?.state, .on)

        let checkedOrders = menu.items.filter { $0.state == .on && $0.representedObject != nil }
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
            let menu = ProjectSidebarViewController().makeArrangementMenu()
            let lone = try XCTUnwrap(menu.item(withTitle: "Headings for Lone Branches"))
            XCTAssertFalse(lone.isEnabled)
            XCTAssertFalse(menu.autoenablesItems, "autoenable would re-enable the disabled item")
        }
    }

    // MARK: - Wiring

    /// Choosing an order writes the setting the tree builder reads. Performed through the
    /// item's own target and action, which is the route the menu takes.
    func testChoosingAnOrderWritesTheSetting() throws {
        defer { UserDefaults.standard.removeObject(forKey: "sidebarSessionOrder") }

        let sidebar = ProjectSidebarViewController()
        let menu = sidebar.makeArrangementMenu()
        let item = try XCTUnwrap(menu.item(withTitle: SidebarSessionOrder.name.menuTitle))
        let action = try XCTUnwrap(item.action)

        _ = (item.target as? NSObject)?.perform(action, with: item)

        XCTAssertEqual(AppSettings.sidebarSessionOrder, .name)
    }
}
