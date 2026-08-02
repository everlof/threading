import AppKit
import XCTest
@testable import Threading

/// The Theme submenu offered on a session row and a project row.
///
/// The menu is the *other* way a scope is chosen — the MCP tools are the first — and it is the
/// half that cannot be exercised from a script: a contextual menu is not reachable through the
/// accessibility API here, so without this the wiring between an item and the assignment it
/// makes would be checked by clicking it and looking.
@MainActor
final class ThemeMenuTests: XCTestCase {

    private func themeSubmenu(of entry: ThemedMenuEntry) throws -> [ThemedMenuEntry] {
        guard case .item(let item) = entry else {
            throw ThemeMenuTestError.expectedItem
        }
        XCTAssertEqual(item.title, "Theme")
        return try XCTUnwrap(item.submenu, "the Theme item has no submenu")
    }

    private func items(in entries: [ThemedMenuEntry]) -> [ThemedMenuItem] {
        entries.compactMap { entry in
            guard case .item(let item) = entry else { return nil }
            return item
        }
    }

    // MARK: - Shape

    func testSessionMenuOffersInheritThenEveryTheme() throws {
        let sidebar = ProjectSidebarViewController()
        let sessionID = SessionID()
        let submenu = try themeSubmenu(of: sidebar.sessionThemeEntry(for: sessionID))

        let titles = items(in: submenu).map(\.title)
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
        let submenu = try themeSubmenu(of: sidebar.projectThemeEntry(for: ProjectID()))

        let inherit = try XCTUnwrap(items(in: submenu).first)
        XCTAssertTrue(inherit.title.contains(ThemeAssignments.defaultTheme.name))
    }

    /// A session with nothing assigned is inheriting, so that is what carries the check.
    func testUnassignedSessionChecksInherit() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try themeSubmenu(of: sidebar.sessionThemeEntry(for: SessionID()))

        let checked = items(in: submenu).filter(\.isSelected)
        XCTAssertEqual(checked.count, 1, "exactly one item should be checked")
        XCTAssertTrue(checked.first?.title.hasPrefix("Inherit") == true)
    }

    func testEveryThemeItemCarriesItsSwatch() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try themeSubmenu(of: sidebar.sessionThemeEntry(for: SessionID()))

        for item in items(in: submenu) where item.representedValue is ThemeMenuChoice {
            guard (item.representedValue as? ThemeMenuChoice)?.themeID != nil else { continue }
            XCTAssertNotNil(item.image, "\(item.title) has no swatch")
        }
    }

    // MARK: - Wiring

    /// Each item carries its own target rather than reading whichever row was last clicked —
    /// the submenu is built from three places, and that ambient state goes stale between them.
    func testItemsCarryTheirOwnTarget() throws {
        let sidebar = ProjectSidebarViewController()
        let sessionID = SessionID()
        let terminalID = TerminalID()
        let projectID = ProjectID()

        let sessionMenu = try themeSubmenu(of: sidebar.sessionThemeEntry(for: sessionID))
        let terminalMenu = try themeSubmenu(of: sidebar.terminalThemeEntry(for: terminalID))
        let projectMenu = try themeSubmenu(of: sidebar.projectThemeEntry(for: projectID))

        let sessionChoice = try XCTUnwrap(
            items(in: sessionMenu).compactMap { $0.representedValue as? ThemeMenuChoice }.first
        )
        let projectChoice = try XCTUnwrap(
            items(in: projectMenu).compactMap { $0.representedValue as? ThemeMenuChoice }.first
        )
        let terminalChoice = try XCTUnwrap(
            items(in: terminalMenu).compactMap { $0.representedValue as? ThemeMenuChoice }.first
        )

        guard case .session(let id) = sessionChoice.target else {
            return XCTFail("session menu did not target a session")
        }
        guard case .project(let pid) = projectChoice.target else {
            return XCTFail("project menu did not target a project")
        }
        guard case .terminal(let tid) = terminalChoice.target else {
            return XCTFail("terminal menu did not target a terminal")
        }

        XCTAssertEqual(id, sessionID)
        XCTAssertEqual(tid, terminalID)
        XCTAssertEqual(pid, projectID)
    }

    /// Clearing is the nil `themeID`, which is why the handler needs no sentinel to tell
    /// "inherit" apart from a theme called something.
    func testInheritCarriesNoThemeName() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try themeSubmenu(of: sidebar.sessionThemeEntry(for: SessionID()))

        let inherit = try XCTUnwrap(
            items(in: submenu).first?.representedValue as? ThemeMenuChoice
        )
        XCTAssertNil(inherit.themeID)
    }

    /// End to end through the themed menu action: picking an item reaches the assignment layer.
    /// The session identifier is one no store knows, so the write itself is a no-op — what is
    /// under test is that the item, its target and its selector are connected at all.
    ///
    /// The action is carried by the row itself rather than routed through whichever sidebar row
    /// was last clicked, which is the themed-menu equivalent of AppKit's item target.
    func testChoosingAThemeFiresTheAssignmentEvent() throws {
        let sidebar = ProjectSidebarViewController()
        let submenu = try themeSubmenu(of: sidebar.sessionThemeEntry(for: SessionID()))

        let themeItem = try XCTUnwrap(
            items(in: submenu).first {
                ($0.representedValue as? ThemeMenuChoice)?.themeID != nil
            },
            "no theme item in the menu"
        )
        let action = try XCTUnwrap(themeItem.onChoose)

        let fired = expectation(description: "ThemeAssignmentsDidChange")
        let observations = AppEventObservations()
        observations.observe(ThemeAssignmentsDidChange.self) { _ in fired.fulfill() }

        action()

        wait(for: [fired], timeout: 1)
    }

    /// A choice remains bound to the scope it was built for even after another menu is built.
    func testAChoiceSurvivesAnotherMenuBuildWithoutChangingTarget() throws {
        let sidebar = ProjectSidebarViewController()
        let store = ProjectStore.shared
        let project = store.addProject(
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("theme-menu-\(UUID().uuidString)", isDirectory: true)
        )
        defer { store.removeProject(id: project.id) }
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let sessionID = session.id
        let item = items(in: try themeSubmenu(of: sidebar.sessionThemeEntry(for: sessionID)))
            .first { ($0.representedValue as? ThemeMenuChoice)?.themeID != nil }
        let themeItem = try XCTUnwrap(item, "no theme item in the menu")
        let choice = try XCTUnwrap(themeItem.representedValue as? ThemeMenuChoice)
        let action = try XCTUnwrap(themeItem.onChoose)

        autoreleasepool { _ = sidebar.projectThemeEntry(for: ProjectID()) }
        action()

        XCTAssertEqual(ThemeAssignments.themeID(forSession: sessionID), choice.themeID)
    }
}

private enum ThemeMenuTestError: Error {
    case expectedItem
}
