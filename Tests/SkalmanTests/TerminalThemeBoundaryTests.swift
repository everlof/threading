import XCTest
import SwiftTerm
@testable import Skalman

/// The terminal is a SwiftTerm rendering surface that brings its own `NSScroller`. The runtime
/// theme audit fatals on a raw scroller in app-owned content, so `EmojiFixedTerminalView`
/// declares itself a system-chrome boundary. These pin that the exemption covers the scroller
/// and nothing more — a debug build fatals the moment either half is wrong.
final class TerminalThemeBoundaryTests: XCTestCase {

    private func terminal() -> EmojiFixedTerminalView {
        EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testRemoteGridRestoresLatestNaturalMacGrid() {
        let view = terminal()
        let original = view.getTerminal().getDims()

        view.setRemoteGrid(cols: 42, rows: 20)
        XCTAssertEqual(view.getTerminal().getDims().cols, 42)
        XCTAssertEqual(view.getTerminal().getDims().rows, 20)

        view.frame.size = NSSize(width: 700, height: 500)
        XCTAssertEqual(view.getTerminal().getDims().cols, 42)
        XCTAssertEqual(view.getTerminal().getDims().rows, 20)

        view.clearRemoteGrid()
        let restored = view.getTerminal().getDims()
        XCTAssertGreaterThan(restored.cols, original.cols)
        XCTAssertGreaterThan(restored.rows, original.rows)
    }

    // MARK: - The permission contract

    func testTerminalPermitsAScrollerButNotAnArbitraryControl() {
        let terminal = terminal()
        XCTAssertTrue(terminal.permitsSystemChrome(NSScroller()), "the terminal's own scroller must pass")
        XCTAssertFalse(terminal.permitsSystemChrome(NSButton()), "the exemption must not cover a stray control")
    }

    // MARK: - The audit over the real tree

    /// A scroller inside the terminal is what fataled the app at launch; the audit must now let
    /// it through.
    func testAuditPassesAScrollerInsideTheTerminal() {
        let terminal = terminal()
        terminal.addSubview(NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 300)))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: terminal), [])
    }

    /// The exemption is scoped: a control that is *not* the terminal's chrome still fails, so the
    /// boundary cannot be used to smuggle unthemed UI into the terminal subtree.
    func testAuditStillFlagsAForeignControlInsideTheTerminal() {
        let terminal = terminal()
        terminal.addSubview(NSButton(title: "x", target: nil, action: nil))

        let violations = ThemeBoundaryAudit.violations(in: terminal)
        XCTAssertTrue(violations.contains { $0.className == "NSButton" }, "a raw button rode the scroller exemption")
    }
}
