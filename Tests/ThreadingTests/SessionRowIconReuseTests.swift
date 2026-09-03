import AppKit
import XCTest
@testable import Threading

/// A row is reconfigured on every title, activity and loading edge of a working agent. Each pass
/// used to size and plate the agent's mark afresh and hand `NSImageView` the new copy, and the
/// view answered every new object by enumerating the asset catalogue's renditions — a second of
/// main thread per minute with ten agents working. The mark's inputs are two facts about the
/// session; while they hold, the view keeps the image it has.
@MainActor
final class SessionRowIconReuseTests: XCTestCase {

    func testATitleOrActivityEdgeKeepsTheMarkImageObject() throws {
        let row = sessionRow()
        var session = AgentSession(kind: .claude, title: "Land the fix")
        row.configure(with: session, activity: .idle)
        let icon = try identityImageView(in: row)
        let mark = try XCTUnwrap(icon.image)

        session.customTitle = "Land the other fix"
        row.configure(with: session, activity: .idle)
        XCTAssertTrue(icon.image === mark, "a rename must not rebuild the mark")

        row.configure(with: session, activity: .dormant)
        XCTAssertTrue(icon.image === mark, "dormancy dims through tint and alpha, not a new image")
        row.configure(with: session, activity: .idle, isLoading: true)
        XCTAssertTrue(icon.image === mark)
    }

    func testAnotherAgentMakesANewMark() throws {
        let row = sessionRow()
        row.configure(with: AgentSession(kind: .claude, title: "First"), activity: .idle)
        let icon = try identityImageView(in: row)
        let claude = try XCTUnwrap(icon.image)

        row.configure(with: AgentSession(kind: .codex, title: "Second"), activity: .idle)
        let codex = try XCTUnwrap(icon.image)
        XCTAssertFalse(codex === claude)

        row.configure(with: AgentSession(kind: .claude, title: "Third"), activity: .idle)
        XCTAssertFalse(icon.image === codex)
    }

    /// Selection moves the ground under the mark, which is one of the three moments the plate
    /// is decided again — and a reconfigure while selected keeps that decision.
    func testASelectionChangeReplatesAndAReconfigureKeepsThePlate() throws {
        let row = sessionRow()
        let session = AgentSession(kind: .claude, title: "Selected")
        row.configure(with: session, activity: .idle)
        let icon = try identityImageView(in: row)
        let unselected = try XCTUnwrap(icon.image)

        row.backgroundStyle = .emphasized
        let selected = try XCTUnwrap(icon.image)
        XCTAssertFalse(selected === unselected)
        XCTAssertTrue(selected.isTemplate, "the selected mark becomes selection ink")

        row.configure(with: session, activity: .dormant)
        XCTAssertTrue(icon.image === selected)

        row.backgroundStyle = .normal
        XCTAssertFalse(icon.image === selected)
    }

    // MARK: - Helpers

    private func sessionRow() -> SessionRowView {
        let row = SessionRowView(customizationLookup: { _ in .empty })
        row.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func identityImageView(in root: NSView) throws -> NSImageView {
        func walk(_ node: NSView) -> NSImageView? {
            if node.accessibilityIdentifier() == "sidebar.session.identity",
               let found = node as? NSImageView {
                return found
            }
            for child in node.subviews {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return try XCTUnwrap(walk(root))
    }
}
