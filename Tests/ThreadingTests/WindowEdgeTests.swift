import AppKit
import XCTest
@testable import Threading

/// The window's own silhouette: what is drawn at its edges, and therefore what its rounded
/// corners are cut out of.
///
/// This exists because of a bug that was invisible in every assertion in the suite and obvious
/// in a photograph. The display panel starts collapsed, and `NSSplitViewController` keeps a
/// collapsed item's divider so it can be dragged back — which put a `Design.Radius.border`-thick
/// seam, in the theme's rule ink, hard against the *window's* trailing edge. Sampled off the
/// running window it was RGB (16, 16, 16) for two to three points down the full height, byte for
/// byte the same ink as the sidebar's own divider. Nothing about that is a divider: there is no
/// second pane on the far side of it. What it did instead was cut a straight dark bar through
/// the window's rounded corners, which is how it was reported — the top-right corner "isn't
/// really rounded, it's cut off and turns black".
///
/// So the assertion is on pixels, at the edge, from a real split-view controller: the trailing
/// column of a window whose trailing pane is collapsed must be that pane's neighbour, not a rule.
/// Confirmed to have teeth by stubbing the fix out — the seam reappears in the last column.
@MainActor
final class WindowEdgeTests: XCTestCase {

    private struct ResizeSweepResult {
        let samples: [UInt64]
        let gridChanges: Int
    }

    private enum Fixture {
        static let size = NSSize(width: 400, height: 200)
        /// The panes fill themselves, so "is this pixel a pane or the seam" has one answer.
        /// Saturated green because no theme's rule ink is anywhere near it — a failure then
        /// names the divider rather than a near-miss on some surface.
        static let paneFill = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        /// Wide enough that an open trailing pane is genuinely on screen, so the seam this
        /// test looks for is *between* the panes rather than at the window's edge again.
        static let openTrailingWidth: CGFloat = 120
    }

    private final class FilledPane: NSViewController {
        override func loadView() {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = Fixture.paneFill.cgColor
            self.view = view
        }
    }

    // MARK: - Helpers

    /// A two-pane controller in a real (never shown) window, with the trailing pane optionally
    /// collapsed. The window is what makes this real: a split view lays its dividers out against
    /// the window's content view, which is where the seam met the corner.
    private func render(collapsingTrailingPane collapse: Bool) throws -> NSBitmapImageRep {
        let controller = SidebarSplitViewController()

        let leading = NSSplitViewItem(viewController: FilledPane())
        let trailing = NSSplitViewItem(viewController: FilledPane())
        trailing.canCollapse = true
        trailing.minimumThickness = Fixture.openTrailingWidth
        controller.addSplitViewItem(leading)
        controller.addSplitViewItem(trailing)
        trailing.isCollapsed = collapse

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(Fixture.size)
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let view = controller.view
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Compares **every** channel. The first version of this compared green alone and passed
    /// against a white divider, which shares the pane's green exactly — a test that could not
    /// see the thing it was written for.
    private func matchesPane(_ colour: NSColor, reference: NSColor) -> Bool {
        abs(colour.redComponent - reference.redComponent) < 0.1
            && abs(colour.greenComponent - reference.greenComponent) < 0.1
            && abs(colour.blueComponent - reference.blueComponent) < 0.1
    }

    private func colour(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(XCTUnwrap(rep.colorAt(x: x, y: y)).usingColorSpace(.sRGB))
    }

    // MARK: - Tests

    /// The bug: with the trailing pane collapsed, the window's trailing column was the seam.
    func testACollapsedTrailingPaneLeavesNoSeamAtTheWindowsEdge() throws {
        let rep = try render(collapsingTrailingPane: true)
        let middleRow = rep.pixelsHigh / 2
        // Cached AppKit views may be tagged with the active display profile after a test-host
        // restart, so even an sRGB source does not necessarily round-trip to its literal source
        // components. Compare the edge to the pane as actually rendered; the divider is still
        // deliberately nowhere near this saturated reference.
        let pane = try colour(rep, x: rep.pixelsWide / 2, y: middleRow)

        // Every column, not just the last: the seam is thicker than a pixel under a heavy
        // ruling theme, and the point is that there is no rule anywhere in a one-pane window.
        for x in 0..<rep.pixelsWide {
            let sampled = try colour(rep, x: x, y: middleRow)
            XCTAssertTrue(
                matchesPane(sampled, reference: pane),
                "a collapsed pane left its divider drawn at x=\(x) of \(rep.pixelsWide): \(sampled)"
            )
        }
    }

    /// And the seam is not simply gone: two open panes still have one between them, or this
    /// would be a fix that deleted the divider rather than the bar at the edge.
    func testTwoOpenPanesStillHaveASeamBetweenThem() throws {
        let rep = try render(collapsingTrailingPane: false)
        let middleRow = rep.pixelsHigh / 2
        let pane = try colour(rep, x: 0, y: middleRow)

        let seam = try (0..<rep.pixelsWide).first { x in
            try !matchesPane(colour(rep, x: x, y: middleRow), reference: pane)
        }
        let found = try XCTUnwrap(seam, "the two panes run together with no seam between them")
        XCTAssertLessThan(
            found,
            rep.pixelsWide - 1,
            "the seam is at the window's edge rather than between the panes"
        )
    }

    // MARK: - Stress profiling

    /// A deterministic bottom-right window drag for separating three costs which look identical
    /// to a person holding the pointer: the window's ordinary AppKit hierarchy, SwiftTerm's
    /// synchronous grid/buffer resize, and the full-screen repaint an agent sends after SIGWINCH.
    ///
    /// The frozen passes use the terminal's existing remote-grid ownership gate. That leaves the
    /// exact same terminal and constraints in the window but refuses frame-derived emulator and
    /// PTY resizes, so the natural/frozen delta is the cost a resize debounce could avoid.
    ///
    /// Opt-in because the scrollback fixture and hundreds of forced display passes are profiling
    /// work rather than a correctness assertion. Run the test bundle directly so Xcode does not
    /// sanitize the environment:
    ///
    /// `THREADING_WINDOW_RESIZE_STRESS=1 xcrun xctest -XCTest
    /// ThreadingTests.WindowEdgeTests/testStressWholeWindowResizeWhenEnabled <test-bundle>`
    func testStressWholeWindowResizeWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_WINDOW_RESIZE_STRESS"] == "1",
            "Set THREADING_WINDOW_RESIZE_STRESS=1 to run the whole-window resize sweep."
        )

        let environment = ProcessInfo.processInfo.environment
        let tickCount = environment["THREADING_WINDOW_RESIZE_STRESS_TICKS"]
            .flatMap(Int.init)
            .flatMap { $0 >= 12 ? $0 : nil }
            ?? 120
        let historyLines = environment["THREADING_WINDOW_RESIZE_STRESS_HISTORY_LINES"]
            .flatMap(Int.init)
            .flatMap { $0 >= 0 ? $0 : nil }
            ?? 0

        let store = ProjectStore.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-window-resize-stress-\(UUID().uuidString)",
            isDirectory: true
        )
        let project = store.addProject(folderURL: folder)
        let agentSession = try XCTUnwrap(
            store.addSession(to: project.id, kind: .claude, title: "Window resize stress")
        )
        let terminalController = AgentRuntime.shared.makeController(for: agentSession)
        defer {
            AgentRuntime.shared.discard(sessionID: agentSession.id)
            store.removeProject(id: project.id)
        }

        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        let sizes = Self.resizeSizes(tickCount: tickCount)
        let chrome = resizeSweep(window: window, sizes: sizes)
        Self.printResizeResult(
            chrome,
            surface: "chrome",
            grid: "none",
            repaint: false,
            historyLines: historyLines
        )

        // Pre-allocating the runtime controller above is load-bearing: selecting it installs the
        // production terminal hierarchy without scheduling a real Claude launch on the next run
        // loop turn. The benchmark owns every byte fed to the terminal.
        controller.projectSidebar(
            ProjectSidebarViewController(),
            didSelectSession: agentSession.id
        )
        window.contentView?.layoutSubtreeIfNeeded()

        let terminal = terminalController.session.terminalView
        Self.seedClaudeScreen(terminal, historyLines: historyLines)
        window.contentView?.displayIfNeeded()
        let repaint = Self.claudeLikeRepaint()

        let natural = resizeSweep(window: window, sizes: sizes, terminal: terminal)
        Self.printResizeResult(
            natural,
            surface: "claude",
            grid: "natural",
            repaint: false,
            historyLines: historyLines
        )

        terminal.setRemoteGrid(
            cols: terminal.getTerminal().getDims().cols,
            rows: terminal.getTerminal().getDims().rows
        )
        let frozen = resizeSweep(window: window, sizes: sizes, terminal: terminal)
        Self.printResizeResult(
            frozen,
            surface: "claude",
            grid: "frozen",
            repaint: false,
            historyLines: historyLines
        )
        terminal.clearRemoteGrid()

        let naturalWithRepaint = resizeSweep(
            window: window,
            sizes: sizes,
            terminal: terminal,
            repaint: repaint
        )
        Self.printResizeResult(
            naturalWithRepaint,
            surface: "claude",
            grid: "natural",
            repaint: true,
            historyLines: historyLines
        )

        terminal.setRemoteGrid(
            cols: terminal.getTerminal().getDims().cols,
            rows: terminal.getTerminal().getDims().rows
        )
        let frozenWithRepaint = resizeSweep(
            window: window,
            sizes: sizes,
            terminal: terminal,
            repaint: repaint
        )
        Self.printResizeResult(
            frozenWithRepaint,
            surface: "claude",
            grid: "frozen",
            repaint: true,
            historyLines: historyLines
        )
        terminal.clearRemoteGrid()

        let normalBufferReturnStarted = DispatchTime.now().uptimeNanoseconds
        terminal.feed(text: "\u{1b}[?1049l")
        window.contentView?.displayIfNeeded()
        let normalBufferReturnElapsed = DispatchTime.now().uptimeNanoseconds
            - normalBufferReturnStarted
        print(
            "THREADING_PERF window-resize-normal-buffer-return "
                + "history_lines=\(historyLines) "
                + "elapsed_ms=\(Self.milliseconds(normalBufferReturnElapsed))"
        )

        XCTAssertGreaterThan(natural.gridChanges, 0)
        XCTAssertEqual(frozen.gridChanges, 0)
        XCTAssertEqual(frozenWithRepaint.gridChanges, 0)
        XCTAssertFalse(terminal.getTerminal().isCurrentBufferAlternate)
    }

    private func resizeSweep(
        window: NSWindow,
        sizes: [NSSize],
        terminal: EmojiFixedTerminalView? = nil,
        repaint: String? = nil
    ) -> ResizeSweepResult {
        // Keep mode switches and first-layout work out of the recorded drag.
        for size in sizes.prefix(8) {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            if let repaint { terminal?.feed(text: repaint) }
            window.contentView?.displayIfNeeded()
        }

        var samples: [UInt64] = []
        samples.reserveCapacity(sizes.count)
        var gridChanges = 0

        for size in sizes {
            let previousGrid = terminal?.getTerminal().getDims()
            let started = DispatchTime.now().uptimeNanoseconds
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            if let repaint { terminal?.feed(text: repaint) }
            window.contentView?.displayIfNeeded()
            samples.append(DispatchTime.now().uptimeNanoseconds - started)

            if let previousGrid, let terminal {
                let currentGrid = terminal.getTerminal().getDims()
                if previousGrid.cols != currentGrid.cols || previousGrid.rows != currentGrid.rows {
                    gridChanges += 1
                }
            }
        }

        return ResizeSweepResult(samples: samples, gridChanges: gridChanges)
    }

    private static func resizeSizes(tickCount: Int) -> [NSSize] {
        let narrow = NSSize(width: 900, height: 620)
        let wide = NSSize(width: 1_520, height: 980)
        let half = max(2, tickCount / 2)

        return (0..<tickCount).map { tick in
            let index = tick < half ? tick : tickCount - tick - 1
            let fraction = CGFloat(max(0, index)) / CGFloat(half - 1)
            return NSSize(
                width: narrow.width + ((wide.width - narrow.width) * fraction),
                height: narrow.height + ((wide.height - narrow.height) * fraction)
            )
        }
    }

    private static func seedClaudeScreen(
        _ terminal: EmojiFixedTerminalView,
        historyLines: Int
    ) {
        if historyLines > 0 {
            let history = (0..<historyLines).map { index in
                let marker = String(format: "%05d", index)
                return "history \(marker) │ "
                    + String(repeating: "wrapped terminal output \(index % 10) ", count: 7)
            }.joined(separator: "\r\n")
            terminal.feed(text: history + "\r\n")
        }

        // Claude's interactive surface uses the alternate buffer. Keep any seeded normal
        // scrollback alive behind it: SwiftTerm resizes both buffers even though only this one
        // is visible.
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[2J\u{1b}[H" + claudeLikeRepaint())
    }

    private static func claudeLikeRepaint() -> String {
        let rows = (0..<48).map { row in
            let colour = 33 + (row % 6)
            return "\u{1b}[38;5;\(colour)m│\u{1b}[0m "
                + "Claude task \(row): inspect → edit → verify  "
                + String(repeating: "status ", count: 9)
        }
        return "\u{1b}[H" + rows.joined(separator: "\r\n") + "\u{1b}[J"
    }

    private static func printResizeResult(
        _ result: ResizeSweepResult,
        surface: String,
        grid: String,
        repaint: Bool,
        historyLines: Int
    ) {
        let ordered = result.samples.sorted()
        let total = result.samples.reduce(0, +)
        let missed60Hz = result.samples.filter { $0 > 16_667_000 }.count
        let missed30Hz = result.samples.filter { $0 > 33_333_000 }.count

        print(
            "THREADING_PERF window-resize "
                + "surface=\(surface) grid=\(grid) repaint=\(repaint ? 1 : 0) "
                + "history_lines=\(historyLines) ticks=\(result.samples.count) "
                + "grid_changes=\(result.gridChanges) "
                + "total_ms=\(milliseconds(total)) "
                + "p50_ms=\(milliseconds(percentile(0.50, in: ordered))) "
                + "p95_ms=\(milliseconds(percentile(0.95, in: ordered))) "
                + "max_ms=\(milliseconds(ordered.last ?? 0)) "
                + "over_16_7_ms=\(missed60Hz) over_33_3_ms=\(missed30Hz)"
        )
    }

    private static func percentile(_ percentile: Double, in ordered: [UInt64]) -> UInt64 {
        guard !ordered.isEmpty else { return 0 }
        let index = Int((Double(ordered.count - 1) * percentile).rounded(.up))
        return ordered[min(max(index, 0), ordered.count - 1)]
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }
}
