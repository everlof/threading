import AppKit
import XCTest
@testable import Threading

/// The context menu on a sidebar branch heading.
///
/// Same reasoning as `SidebarArrangementMenuTests`: a presented menu is unreachable from a
/// script, so the built entries are asserted directly. Copy is chosen through the row's own
/// closure against a private pasteboard — the bundle is hosted in the app, and the general
/// pasteboard is the developer's own clipboard.
@MainActor
final class SidebarBranchHeadingMenuTests: XCTestCase {

    private let branch = "feature/copy-branch-name"
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("threading-tests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
        try await super.tearDown()
    }

    /// The copy leads, set apart from the grouping toggles that were the whole menu before.
    func testHeadingLeadsWithCopyBranchNameThenTheGroupingToggles() {
        let entries = ProjectSidebarViewController()
            .branchHeadingMenuEntries(for: branch, pasteboard: pasteboard)

        XCTAssertEqual(
            entries.map { $0.item?.title ?? "—" },
            ["Copy Branch Name", "—", "Group Sessions by Branch", "Headings for Lone Branches"]
        )
    }

    /// Choosing it replaces whatever was on the pasteboard with exactly the heading's branch.
    func testCopyBranchNameWritesTheBranchToThePasteboard() throws {
        pasteboard.clearContents()
        pasteboard.setString("previous clipboard", forType: .string)

        let entries = ProjectSidebarViewController()
            .branchHeadingMenuEntries(for: branch, pasteboard: pasteboard)
        let copy = try XCTUnwrap(entries.first?.item)
        copy.onChoose?()

        XCTAssertEqual(pasteboard.string(forType: .string), branch)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }
}
