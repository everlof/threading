import AppKit
import XCTest
@testable import Threading

@MainActor
final class NavigatorProjectRowPresentationTests: XCTestCase {
    func testRolePresentsProjectCheckoutAndHeadingsWithoutMovingHostAuthority() throws {
        let project = Project(name: "Threading", folderURL: URL(fileURLWithPath: "/tmp/Threading"))
        let row = ProjectRowView(customizationLookup: { _ in .empty })
        let title = try XCTUnwrap(descendant("sidebar.project.title", in: row) as? MorphingTitleLabel)
        let icon = try XCTUnwrap(descendant("sidebar.project.identity", in: row) as? NSImageView)

        row.configure(with: project)
        XCTAssertEqual(title.stringValue, "Threading")
        XCTAssertFalse(icon.isHidden)
        XCTAssertEqual(title.font, Design.FontRole.emphasizedBody.resolved())

        row.configure(with: project, style: .checkout)
        let checkout = NavigatorProjectRowPresentation.checkout(
            branch: GitInfo.currentBranch(for: project.folderPath),
            fallbackName: project.name,
            abbreviatedPath: PathAbbreviation.abbreviatingHome(in: project.folderPath)
        )
        let path = try XCTUnwrap(descendant("sidebar.project.worktree-path", in: row)
                                 as? MorphingTitleLabel)
        XCTAssertEqual(title.stringValue, checkout.title)
        XCTAssertEqual(path.stringValue, checkout.secondaryPath)
        XCTAssertFalse(path.isHidden)
        XCTAssertTrue(icon.isHidden)
        XCTAssertEqual(title.font, Design.FontRole.emphasizedBody.resolved())

        row.configureAsRepository(named: "Repository", representing: project)
        XCTAssertEqual(title.stringValue, "Repository")
        XCTAssertFalse(icon.isHidden)
        XCTAssertTrue(path.isHidden)
        XCTAssertEqual(title.font, Design.FontRole.emphasizedBody.resolved())

        row.configureAsBranch(named: "main")
        XCTAssertEqual(title.stringValue, "main")
        XCTAssertTrue(icon.isHidden)
        XCTAssertEqual(title.font, Design.FontRole.caption.resolved())

        row.configure(with: project)
        XCTAssertEqual(title.stringValue, "Threading")
        XCTAssertFalse(icon.isHidden)
        XCTAssertTrue(path.isHidden)
        XCTAssertEqual(title.font, Design.FontRole.emphasizedBody.resolved())
    }

    func testSharedPresentationNamesBranchAndQuietRepository() {
        let checkout = NavigatorProjectRowPresentation.checkout(
            branch: "fix/sidebar", fallbackName: "Threading", abbreviatedPath: "~/repo/sidebar")
        XCTAssertEqual(checkout.title, "fix/sidebar")
        XCTAssertEqual(checkout.secondaryPath, "[~/repo/sidebar]")
        XCTAssertFalse(checkout.showsIdentityMark)
        XCTAssertEqual(checkout.titleRole, .emphasizedBody)

        let quiet = NavigatorProjectRowPresentation.repository(
            name: "Archived", hasRepresentative: false)
        XCTAssertEqual(quiet.titleRole, .caption)
        XCTAssertTrue(quiet.isQuietHeading)
        XCTAssertFalse(quiet.showsIdentityMark)
    }

    private func descendant(_ identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let found = descendant(identifier, in: child) { return found }
        }
        return nil
    }
}
