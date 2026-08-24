import AppKit
@testable import SwiftTerm
import XCTest
@testable import Threading

/// Draws the Codex terminal pane at the exact edge that used to expose an empty live-screen tail.
///
/// The fixture enters through `AgentSessionViewController`, not a separately configured terminal,
/// so the image proves the provider capability reaches the product renderer. History is longer
/// than the pane, then Codex-shaped inline content repaints only three live rows. At the scroll end
/// the history above should fill the viewport and the status line should touch its final row.
@MainActor
final class AgentTerminalScrollbackRenderTests: XCTestCase {
    private enum Fixture {
        static let size = NSSize(width: 760, height: 560)
        static let escape = "\u{1b}"
        static var outputDirectory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    func testRendersCodexInlineViewportWithoutAnEmptyTail() throws {
        let controller = AgentSessionViewController(
            agentSession: AgentSession(kind: .codex, title: "Inline scroll end")
        )
        _ = controller.view
        var profile = TerminalProfile.default
        profile.theme = .systemDark
        controller.session.updateProfile(profile)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        self.window = window
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = controller.paneBackgroundColor
        window.contentViewController = controller
        window.setContentSize(Fixture.size)
        controller.view.frame = NSRect(origin: .zero, size: Fixture.size)
        controller.view.layoutSubtreeIfNeeded()

        let terminal = controller.session.terminalView
        terminal.suspendsRenderingWhenNotVisible = false
        terminal.cursorStyle = .steadyBlock
        settle(terminal)

        let rows = terminal.terminalDimensions.rows
        XCTAssertGreaterThan(rows, 8, "the product pane never established a useful terminal grid")
        for index in 0..<(rows * 3) {
            terminal.feed(text: "Review note \(index + 1): preserved transcript\r\n")
        }
        terminal.feed(text: """
        \(Fixture.escape)[2J\(Fixture.escape)[H› Explain this codebase\r\n\r\n• Ready for another prompt
        """)
        settle(terminal)

        let visible = terminal.terminalStateSnapshot().visibleRows.map {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(visible.last, "• Ready for another prompt")
        XCTAssertTrue(
            visible.dropLast(3).contains { $0.contains("preserved transcript") },
            "the compact live end did not pull retained transcript into the formerly empty rows"
        )
        XCTAssertEqual(terminal.scrollPosition, 1)
        let scroller = try XCTUnwrap(
            terminal.subviews.compactMap { $0 as? NSScroller }.first
        )
        XCTAssertTrue(scroller.isEnabled)
        XCTAssertEqual(scroller.doubleValue, 1, accuracy: 0.001)
        XCTAssertLessThan(
            scroller.knobProportion,
            0.75,
            "retained transcript was not reflected in the scroll thumb"
        )
        // Capture the resting pane rather than freezing the transient overlay
        // thumb that output just revealed. Its geometry is asserted above.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))

        let representation = try XCTUnwrap(
            terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds)
        )
        terminal.cacheDisplay(in: terminal.bounds, to: representation)
        terminal.cacheDisplay(in: terminal.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000, "the Codex terminal evidence rendered blank")

        try FileManager.default.createDirectory(
            at: Fixture.outputDirectory,
            withIntermediateDirectories: true
        )
        try png.write(
            to: Fixture.outputDirectory
                .appendingPathComponent("codex-inline-scrollback-end-dark.png"),
            options: .atomic
        )
    }

    /// Exercises the real terminal surface's second half of the lease handoff. Registry tests
    /// prove that an explicit mobile leave now sends `nil`; this render proves that mutation
    /// returns SwiftTerm to the desktop-sized grid and exposes the Mac's final row again.
    func testRendersMacGridAfterMobileViewportLeaves() throws {
        let controller = AgentSessionViewController(
            agentSession: AgentSession(kind: .codex, title: "Desktop grid restoration")
        )
        _ = controller.view
        var profile = TerminalProfile.default
        profile.theme = .systemDark
        controller.session.updateProfile(profile)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        self.window = window
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = controller.paneBackgroundColor
        window.contentViewController = controller
        window.setContentSize(Fixture.size)
        controller.view.frame = NSRect(origin: .zero, size: Fixture.size)
        controller.view.layoutSubtreeIfNeeded()

        let terminal = controller.session.terminalView
        terminal.suspendsRenderingWhenNotVisible = false
        terminal.cursorStyle = .steadyBlock
        settle(terminal)
        let macGrid = terminal.terminalDimensions
        XCTAssertGreaterThan(macGrid.cols, 40)
        XCTAssertGreaterThan(macGrid.rows, 16)

        controller.session.setRemoteViewport(
            cols: max(20, macGrid.cols - 24),
            rows: max(4, macGrid.rows - 10)
        )
        XCTAssertNotEqual(terminal.terminalDimensions.cols, macGrid.cols)
        XCTAssertNotEqual(terminal.terminalDimensions.rows, macGrid.rows)

        controller.session.clearRemoteViewport()
        settle(terminal)
        XCTAssertEqual(terminal.terminalDimensions.cols, macGrid.cols)
        XCTAssertEqual(terminal.terminalDimensions.rows, macGrid.rows)
        XCTAssertNil(controller.session.remoteViewport)

        terminal.feed(text: "\(Fixture.escape)[2J\(Fixture.escape)[H")
        for row in 1...macGrid.rows {
            let label = row == macGrid.rows
                ? "macOS owns the full \(macGrid.cols)×\(macGrid.rows) grid again"
                : "Desktop row \(row): restored after the iPhone left the chat"
            terminal.feed(text: "\(Fixture.escape)[\(row);1H\(label)")
        }
        settle(terminal)

        let visible = terminal.terminalStateSnapshot().visibleRows.map {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(
            visible.last,
            "macOS owns the full \(macGrid.cols)×\(macGrid.rows) grid again"
        )

        let representation = try XCTUnwrap(
            terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds)
        )
        terminal.cacheDisplay(in: terminal.bounds, to: representation)
        terminal.cacheDisplay(in: terminal.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000, "the restored Mac terminal evidence rendered blank")

        try FileManager.default.createDirectory(
            at: Fixture.outputDirectory,
            withIntermediateDirectories: true
        )
        try png.write(
            to: Fixture.outputDirectory
                .appendingPathComponent("remote-terminal-macos-grid-restored-dark.png"),
            options: .atomic
        )
    }

    private func settle(_ terminal: EmojiFixedTerminalView) {
        terminal.frameTick()
        controllerLayout(terminal)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        terminal.frameTick()
        controllerLayout(terminal)
    }

    private func controllerLayout(_ terminal: EmojiFixedTerminalView) {
        terminal.superview?.layoutSubtreeIfNeeded()
        terminal.layoutSubtreeIfNeeded()
    }
}
