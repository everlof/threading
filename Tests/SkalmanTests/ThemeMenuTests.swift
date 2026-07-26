import AppKit
import XCTest
@testable import Skalman

/// The Theme submenu offered on a session row and a project row.
///
/// The menu is the *other* way a scope is chosen — the MCP tools are the first — and it is the
/// half that cannot be exercised from a script: a contextual menu is not reachable through the
/// accessibility API here, so without this the wiring between an item and the assignment it
/// makes would be checked by clicking it and looking.
@MainActor
final class ThemeMenuTests: XCTestCase {

    private func themeSubmenu(of item: NSMenuItem) throws -> NSMenu {
        XCTAssertEqual(item.title, "Theme")
        return try XCTUnwrap(item.submenu, "the Theme item has no submenu")
    }

    // MARK: - Shape

    func testSessionMenuOffersInheritThenEveryTheme() throws {
        let sidebar = ProjectSidebarViewController()
        let sessionID = SessionID()
        let submenu = try themeSubmenu(of: sidebar.makeSessionThemeItem(for: sessionID))

        let titles = submenu.items.map(\.title)
        let names = ThemeManager.shared.allThemes.map(\.name)

        // Inherit, separator, one item per theme, separator, the door to Settings.
        XCTAssertEqual(
            titles.first,
            "Inherit (\(ThemeAssignments.inheritedName(forSession: sessionID)))"
        )
        XCTAssertEqual(titles.last, "Edit Themes…")
        for name in names {
            XCTAssertTrue(titles.contains(name), "\(name) is missing from the menu")
        }
    }

    /// "Inherit" names what it inherits — otherwise it is the one choice in the list whose
    /// result cannot be seen before picking it.
    func testInheritNamesTheThemeItWouldFallBackTo() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try themeSubmenu(of: sidebar.makeProjectThemeItem(for: ProjectID()))

        let inherit = try XCTUnwrap(submenu.items.first)
        XCTAssertTrue(inherit.title.contains(ThemeAssignments.defaultTheme.name))
    }

    /// A session with nothing assigned is inheriting, so that is what carries the check.
    func testUnassignedSessionChecksInherit() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try themeSubmenu(of: sidebar.makeSessionThemeItem(for: SessionID()))

        let checked = submenu.items.filter { $0.state == .on }
        XCTAssertEqual(checked.count, 1, "exactly one item should be checked")
        XCTAssertTrue(checked.first?.title.hasPrefix("Inherit") == true)
    }

    func testEveryThemeItemCarriesItsSwatch() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try themeSubmenu(of: sidebar.makeSessionThemeItem(for: SessionID()))

        for item in submenu.items where item.representedObject is ThemeMenuChoice {
            guard (item.representedObject as? ThemeMenuChoice)?.themeID != nil else { continue }
            XCTAssertNotNil(item.image, "\(item.title) has no swatch")
        }
    }

    // MARK: - Wiring

    /// Each item carries its own target rather than reading whichever row was last clicked —
    /// the submenu is built from three places, and that ambient state goes stale between them.
    func testItemsCarryTheirOwnTarget() throws {
        let sidebar = ProjectSidebarViewController()
        let sessionID = SessionID()
        let projectID = ProjectID()

        let sessionMenu = try themeSubmenu(of: sidebar.makeSessionThemeItem(for: sessionID))
        let projectMenu = try themeSubmenu(of: sidebar.makeProjectThemeItem(for: projectID))

        let sessionChoice = try XCTUnwrap(
            sessionMenu.items.compactMap { $0.representedObject as? ThemeMenuChoice }.first
        )
        let projectChoice = try XCTUnwrap(
            projectMenu.items.compactMap { $0.representedObject as? ThemeMenuChoice }.first
        )

        guard case .session(let id) = sessionChoice.target else {
            return XCTFail("session menu did not target a session")
        }
        guard case .project(let pid) = projectChoice.target else {
            return XCTFail("project menu did not target a project")
        }

        XCTAssertEqual(id, sessionID)
        XCTAssertEqual(pid, projectID)
    }

    /// Clearing is the nil `themeID`, which is why the handler needs no sentinel to tell
    /// "inherit" apart from a theme called something.
    func testInheritCarriesNoThemeName() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try themeSubmenu(of: sidebar.makeSessionThemeItem(for: SessionID()))

        let inherit = try XCTUnwrap(submenu.items.first?.representedObject as? ThemeMenuChoice)
        XCTAssertNil(inherit.themeID)
    }

    /// End to end through AppKit's own dispatch: picking an item reaches the assignment layer.
    /// The session identifier is one no store knows, so the write itself is a no-op — what is
    /// under test is that the item, its target and its selector are connected at all.
    ///
    /// Dispatch goes through the item's *own* target rather than through the sidebar, which is
    /// what AppKit does when the menu fires. The handler lives on `ThemeMenuBuilder`, since the
    /// submenu is built from four places and the items need one stable target between them —
    /// asserting the sidebar handles it pins the owner rather than the connection, and this
    /// test failed for exactly that reason once the builder was extracted.
    func testChoosingAThemeFiresTheAssignmentEvent() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try themeSubmenu(of: sidebar.makeSessionThemeItem(for: SessionID()))

        let themeItem = try XCTUnwrap(
            submenu.items.first { ($0.representedObject as? ThemeMenuChoice)?.themeID != nil },
            "no theme item in the menu"
        )
        let action = try XCTUnwrap(themeItem.action)
        let target = try XCTUnwrap(themeItem.target as? NSObject, "the item carries no target")
        XCTAssertTrue(target.responds(to: action), "the target does not implement \(action)")

        let fired = expectation(description: "ThemeAssignmentsDidChange")
        let observations = AppEventObservations()
        observations.observe(ThemeAssignmentsDidChange.self) { _ in fired.fulfill() }

        _ = target.perform(action, with: themeItem)

        wait(for: [fired], timeout: 1)
    }

    /// `NSMenuItem.target` is a *weak* reference, so a builder owned by nothing leaves every
    /// item in the submenu pointing at nil and the menu silently does nothing when clicked.
    /// The sidebar therefore has to hold its builder, which is invisible at the call site —
    /// `sidebarThemeBuilder()` returning a fresh instance would read identically and be dead.
    func testTheSidebarKeepsTheBuilderItsItemsTargetAlive() throws {
        let sidebar = ProjectSidebarViewController()
        let item = try themeSubmenu(of: sidebar.makeSessionThemeItem(for: SessionID()))
            .items
            .first { ($0.representedObject as? ThemeMenuChoice)?.themeID != nil }
        let themeItem = try XCTUnwrap(item, "no theme item in the menu")

        // Anything transient would already be gone by the time the menu is shown.
        autoreleasepool { _ = sidebar.makeProjectThemeItem(for: ProjectID()) }

        XCTAssertNotNil(themeItem.target, "the items' target was not retained by the sidebar")
        XCTAssertTrue(themeItem.target as? ThemeMenuBuilder === sidebar.themeMenuBuilder,
                      "the items point at a builder the sidebar does not own")
    }
}
