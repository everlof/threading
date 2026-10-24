import AppKit
import XCTest
@testable import Threading

/// The sidebar's Option alternates: the fast path for an act a person already knows they want.
///
/// The ones that skip a confirmation are the ones worth pinning. Each runs synchronously on the
/// test's own thread, so an alternate that still asked would put a modal up here and the test
/// would not come back — a hang is the failure, and it is loud.
@MainActor
final class SidebarMenuAlternateTests: HostedStoreTestCase {

    // MARK: - Project Row

    func testRemoveProjectOffersRemovingWithoutAsking() throws {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: scratchFolder()))
        let sidebar = mountedSidebar()

        let remove = try item(titled: L10n.string("Remove Project"), in: sidebar.projectMenuEntries(row: 0))
        XCTAssertEqual(remove.alternate?.modifiers, .option)
        XCTAssertEqual(
            remove.resolved(holding: .option).title,
            L10n.string("Remove Project Without Asking")
        )

        try XCTUnwrap(remove.resolved(holding: .option).onChoose)()

        XCTAssertNil(
            ProjectStore.shared.project(withID: project.id),
            "the project is still there after removing it without asking"
        )
    }

    /// Finder's own Option alternate beside its reveal, and it copies the folder rather than
    /// anything the menu happened to capture as it opened.
    func testRevealInFinderOffersCopyingThePath() throws {
        let folder = try scratchFolder()
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
        let sidebar = mountedSidebar()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("threading-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let reveal = try item(
            titled: L10n.string("Reveal in Finder"),
            in: sidebar.projectMenuEntries(row: 0, pasteboard: pasteboard)
        )
        let copy = reveal.resolved(holding: .option)
        XCTAssertEqual(copy.title, L10n.string("Copy Path"))

        try XCTUnwrap(copy.onChoose)()

        XCTAssertEqual(pasteboard.string(forType: .string), project.folderPath)
    }

    // MARK: - Session Row

    func testDeleteSessionOffersDeletingWithoutAsking() throws {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: scratchFolder()))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude))
        let sidebar = mountedSidebar()

        let delete = try item(
            titled: L10n.string("Delete Session"),
            in: sidebar.sessionActionEntries(for: session)
        )
        XCTAssertEqual(
            delete.resolved(holding: .option).title,
            L10n.string("Delete Session Without Asking")
        )

        try XCTUnwrap(delete.resolved(holding: .option).onChoose)()

        XCTAssertNil(
            ProjectStore.shared.session(withID: session.id),
            "the session is still there after deleting it without asking"
        )
    }

    // MARK: - Helpers

    private func mountedSidebar() -> ProjectSidebarViewController {
        let sidebar = ProjectSidebarViewController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        sidebar.view.layoutSubtreeIfNeeded()
        sidebar.mountInitialTreeIfNeeded()
        return sidebar
    }

    private func item(titled title: String, in entries: [ThemedMenuEntry]) throws -> ThemedMenuItem {
        try XCTUnwrap(
            entries.compactMap(\.item).first { $0.title == title },
            "the menu has no “\(title)”"
        )
    }

    private func scratchFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-menu-alternate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
