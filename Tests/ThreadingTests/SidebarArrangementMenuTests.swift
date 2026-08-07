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

    private func withDefault(_ value: Any?, forKey key: String, run: () throws -> Void) rethrows {
        UserDefaults.standard.set(value, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        try run()
    }

    // MARK: - Shape

    /// Grouping first, then a separator, then one item per order — how the list groups is a
    /// bigger rearrangement than how it sorts, so it reads first.
    func testMenuOffersGroupingThenEveryOrder() {
        let entries = ProjectSidebarViewController().arrangementMenuEntries()

        let titles = entries.map { $0.item?.title ?? "—" }
        XCTAssertEqual(
            titles,
            ["Group Sessions by Branch", "Headings for Lone Branches", "Compact Tree", "—"]
                + SidebarSessionOrder.allCases.map(\.menuTitle)
        )
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
        defer { UserDefaults.standard.removeObject(forKey: "sidebarSessionOrder") }

        let sidebar = ProjectSidebarViewController()
        let entries = sidebar.arrangementMenuEntries()
        let item = try XCTUnwrap(item(in: entries, titled: SidebarSessionOrder.name.menuTitle))

        item.onChoose?()

        XCTAssertEqual(AppSettings.shared.sidebarSessionOrder, .name)
    }

    // MARK: - Helpers

    private func item(in entries: [ThemedMenuEntry], titled title: String) -> ThemedMenuItem? {
        entries.compactMap(\.item).first { $0.title == title }
    }
}
