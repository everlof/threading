import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// The host-owned Extensions group at the end of a sidebar row's menu.
///
/// Same technique as `SidebarArrangementMenuTests`: a popped menu is modal and unreachable
/// from a script, so the built menu is asserted directly — its shape, and the row identity
/// each item carries as its invocation context.
@MainActor
final class RowExtensionCommandMenuTests: XCTestCase {

    private let extensionIdentifier = "com.example.rowmenu"

    override func tearDown() {
        CommandRegistry.shared.replaceExtensionCommands(
            extensionIdentifier: extensionIdentifier,
            extensionName: "Row Menu",
            commands: []
        )
        super.tearDown()
    }

    func testSessionRowMenuCarriesTheRowsOwnContext() throws {
        CommandRegistry.shared.replaceExtensionCommands(
            extensionIdentifier: extensionIdentifier,
            extensionName: "Row Menu",
            commands: [
                .init(
                    id: "inspect",
                    title: "Inspect Session",
                    scope: .session,
                    menuPlacements: [.sessionRow]
                ),
                .init(
                    id: "elsewhere",
                    title: "Elsewhere",
                    menuPlacements: [.extensions]
                )
            ]
        )

        let sidebar = ProjectSidebarViewController()
        let session = AgentSession(kind: .claude, title: "Fixture")
        let entries = sidebar.sessionActionEntries(for: session)

        let extensionsItem = try XCTUnwrap(entries.last?.item)
        XCTAssertEqual(extensionsItem.title, "Extensions")
        let group = try XCTUnwrap(extensionsItem.submenu?.first?.item)
        XCTAssertEqual(group.title, "Row Menu")
        XCTAssertEqual(
            group.submenu?.compactMap { $0.item?.title },
            ["Inspect Session"],
            "a menu-bar-only command stays out of the row"
        )

        let command = try XCTUnwrap(group.submenu?.first?.item)
        let reference = try XCTUnwrap(
            command.representedValue
                as? ProjectSidebarViewController.RowExtensionCommandReference
        )
        XCTAssertEqual(reference.commandID, "extension.com.example.rowmenu.inspect")
        XCTAssertEqual(
            reference.context.sessionID,
            session.id.uuidString.lowercased(),
            "the context names the row, not the selection"
        )
    }

    func testNoEnabledCommandsMeansNoGroupAtAll() {
        let sidebar = ProjectSidebarViewController()
        let session = AgentSession(kind: .claude, title: "Fixture")
        let entries = sidebar.sessionActionEntries(for: session)

        XCTAssertEqual(
            entries.last?.item?.title,
            "Delete Session",
            "an empty Extensions group would be noise on every row"
        )
    }

    func testProjectRowOmitsCommandsItsContextCannotSatisfy() throws {
        let registry = CommandRegistry(builtInCommands: [])
        registry.replaceExtensionCommands(
            extensionIdentifier: extensionIdentifier,
            extensionName: "Row Menu",
            commands: [
                .init(
                    id: "audit",
                    title: "Audit Project",
                    scope: .project,
                    menuPlacements: [.projectRow]
                ),
                .init(
                    id: "inspect",
                    title: "Inspect Session",
                    scope: .session,
                    menuPlacements: [.sessionRow]
                )
            ]
        )

        let sidebar = ProjectSidebarViewController()
        let entries = sidebar.extensionCommandEntries(
            placement: .projectRow,
            context: ExtensionCommandContext(projectID: "p-1"),
            commands: registry.extensionCommands
        )

        let extensionsItem = try XCTUnwrap(entries.last?.item)
        let group = try XCTUnwrap(extensionsItem.submenu?.first?.item)
        XCTAssertEqual(
            group.submenu?.compactMap { $0.item?.title },
            ["Audit Project"],
            "a project row never names a session, so a session command has nothing to say"
        )
    }
}
