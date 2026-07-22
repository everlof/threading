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
        let submenu = try themeSubmenu(of: sidebar.makeSessionThemeItem(for: SessionID()))

        let titles = submenu.items.map(\.title)
        let names = ThemeManager.shared.allThemes.map(\.name)

        // Inherit, separator, one item per theme, separator, the door to Settings.
        XCTAssertEqual(titles.first, "Inherit (\(ThemeAssignments.defaultTheme.name))")
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
            guard (item.representedObject as? ThemeMenuChoice)?.themeName != nil else { continue }
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

    /// Clearing is the nil `themeName`, which is why the handler needs no sentinel to tell
    /// "inherit" apart from a theme called something.
    func testInheritCarriesNoThemeName() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try themeSubmenu(of: sidebar.makeSessionThemeItem(for: SessionID()))

        let inherit = try XCTUnwrap(submenu.items.first?.representedObject as? ThemeMenuChoice)
        XCTAssertNil(inherit.themeName)
    }

    /// End to end through AppKit's own dispatch: picking an item reaches the assignment layer.
    /// The session identifier is one no store knows, so the write itself is a no-op — what is
    /// under test is that the item, its target and its selector are connected at all.
    func testChoosingAThemeFiresTheAssignmentEvent() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try themeSubmenu(of: sidebar.makeSessionThemeItem(for: SessionID()))

        let themeItem = try XCTUnwrap(
            submenu.items.first { ($0.representedObject as? ThemeMenuChoice)?.themeName != nil },
            "no theme item in the menu"
        )
        let action = try XCTUnwrap(themeItem.action)
        XCTAssertTrue(sidebar.responds(to: action), "the sidebar does not implement \(action)")
        XCTAssertTrue(themeItem.target === sidebar)

        let fired = expectation(description: "ThemeAssignmentsDidChange")
        let observations = AppEventObservations()
        observations.observe(ThemeAssignmentsDidChange.self) { _ in fired.fulfill() }

        _ = sidebar.perform(action, with: themeItem)

        wait(for: [fired], timeout: 1)
    }
}
