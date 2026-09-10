import AppKit
import XCTest
@testable import Threading

/// The panel's toggle is one control with two homes — the pane header's group while the panel is
/// shut, the panel's own corner while it is open — and the two land on the same point so the pane
/// arrives underneath a button that never moved. Which means the *point* is the control, and the
/// gesture that has to keep working is pressing that one point over and over.
///
/// It stopped working after one press, and came back the moment the pointer moved. **AppKit sends
/// every click after the first of a chain to the view that took the first one**, so a control that
/// removes itself as part of its own press throws away every press that follows: measured in an
/// isolated harness, click 1 arrived and clicks 2…n were delivered to nobody at all — not to the
/// view that had left, and not to the one standing in its place. Moving the pointer far enough
/// ends the chain, which is the whole of "it works again if I wiggle the mouse".
///
/// So the two homes hold one view between them, and these tests pin the property that fixes it:
/// pressing the toggle leaves the same view under the pointer.
@MainActor
final class DisplayPanelTogglePressTests: HostedStoreTestCase {

    // MARK: - Fixture

    private struct Fixture {
        let controller: MainWindowController
        let window: NSWindow
        let displayItem: NSSplitViewItem
        let teardown: () -> Void
    }

    private static let windowSize = NSSize(width: 1400, height: 800)

    private func makeFixture() throws -> Fixture {
        let store = ProjectStore.shared
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("threading-panel-toggle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try XCTUnwrap(store.addProject(folderURL: folder))
        let session = try XCTUnwrap(
            store.addSession(to: project.id, kind: .claude, usesNativeUI: false, title: "Toggle")
        )
        XCTAssertTrue(store.update(sessionID: session.id) {
            // The motion assertion needs the terminal fixture allocated in this process. It is
            // not a background-host integration and must not inherit the developer's setting.
            $0.backgroundHost = false
        }.succeeded)

        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(Self.windowSize)
        window.contentView?.layoutSubtreeIfNeeded()
        settle()

        // The sidebar's own delegate call, which is what selecting a session row makes.
        controller.projectSidebar(ProjectSidebarViewController(), didSelectSession: session.id)
        settle()
        window.contentView?.layoutSubtreeIfNeeded()

        let displayItem = try XCTUnwrap(controller.splitViewController.splitViewItems.last)
        return Fixture(controller: controller, window: window, displayItem: displayItem) {
            store.removeProject(id: project.id)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: Design.Motion.standard))
    }

    /// What a click at `point` would reach: the button AppKit would hand the press to, found the
    /// way a press finds it rather than by asking the window controller which button it thinks is
    /// on screen.
    private func button(at point: NSPoint, in window: NSWindow) -> ThemedIconButton? {
        var view = window.contentView?.hitTest(point)
        while let candidate = view {
            if let button = candidate as? ThemedIconButton { return button }
            view = candidate.superview
        }
        return nil
    }

    private func press(_ button: ThemedIconButton, at point: NSPoint, in window: NSWindow) {
        button.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: window))
        button.mouseUp(with: mouseEvent(.leftMouseUp, at: point, in: window))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in window: NSWindow
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        )!
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    // MARK: - Tests

    /// **The press must not take its own view out from under the pointer.** This is the whole bug:
    /// AppKit routes the rest of a click chain to the view that took the first click, so the view
    /// standing at the toggle's point before a press has to be the same object standing there
    /// after it — in both directions.
    func testPressingTheToggleLeavesTheSameViewUnderThePointer() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let window = fixture.window
        let toggle = try XCTUnwrap(fixture.controller.displayPaneToolbarButton)
        XCTAssertTrue(fixture.displayItem.isCollapsed, "the fixture came up with the panel open")

        let box = toggle.convert(toggle.bounds, to: nil)
        let point = NSPoint(x: box.midX, y: box.midY)

        for step in 1...4 {
            let before = try XCTUnwrap(
                button(at: point, in: window),
                "nothing was under the pointer before press \(step)"
            )
            press(before, at: point, in: window)
            settle()
            window.contentView?.layoutSubtreeIfNeeded()

            let after = try XCTUnwrap(
                button(at: point, in: window),
                "press \(step) left nothing under the pointer — a chain of clicks stops here"
            )
            XCTAssertTrue(
                before === after,
                "press \(step) swapped the view under the pointer for another one, so every"
                    + " click after it in the same chain is delivered to the view that left"
            )
            XCTAssertTrue(
                after === toggle,
                "the toggle under the pointer is not the window's own — there are two again"
            )
            XCTAssertNotNil(after.window, "the toggle left the window on press \(step)")
        }
    }

    /// And the panel really does open and shut on those presses — the property above would also
    /// hold for a button that did nothing at all.
    func testPressingTheTogglesPointRepeatedlyKeepsTogglingThePanel() throws {
        for cadence in [0, Design.Motion.standard / 3, Design.Motion.standard * 2] {
            let fixture = try makeFixture()
            defer { fixture.teardown() }
            let window = fixture.window
            let toggle = try XCTUnwrap(fixture.controller.displayPaneToolbarButton)
            XCTAssertTrue(toggle.isEnabled, "the toggle came up unpressable")

            // Where the pointer sits: the middle of the toggle, in window coordinates, read once
            // and never re-read — the pointer does not move between these presses.
            let box = toggle.convert(toggle.bounds, to: nil)
            let point = NSPoint(x: box.midX, y: box.midY)

            var trace: [String] = []
            var states: [Bool] = []
            for step in 1...8 {
                let hit = button(at: point, in: window)
                let before = fixture.displayItem.isCollapsed
                if let hit { press(hit, at: point, in: window) }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: cadence))
                window.contentView?.layoutSubtreeIfNeeded()
                let after = fixture.displayItem.isCollapsed
                states.append(after)
                trace.append(
                    "  press \(step): \(before ? "shut" : "open") -> \(after ? "shut" : "open")"
                        + " | hit \(hit?.accessibilityTitle() ?? "nothing")"
                )
            }

            XCTAssertEqual(
                states,
                (1...8).map { $0 % 2 == 0 },
                "the panel stopped answering a press on the point its toggle occupies"
                    + " (cadence \(cadence))\n"
                    + trace.joined(separator: "\n")
            )
        }
    }

    /// Both edge panes share one motion policy. A terminal-backed workspace takes the measured
    /// immediate route at either edge; leaving the sidebar on the default animated route while
    /// only the display panel consulted the terminal was the visible mismatch this guards.
    func testTerminalWorkspaceUsesTheSameImmediateTransitionAtBothEdges() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let splitController = fixture.controller.splitViewController
        let content = try XCTUnwrap(
            splitController.splitViewItems[1].viewController
                as? TerminalContainerViewController
        )
        XCTAssertNotNil(
            content.activeTerminalSession,
            "the fixture is not exercising the terminal-backed motion policy"
        )

        fixture.controller.setDisplayPaneVisible(true)
        XCTAssertFalse(
            splitController.lastCollapseUsedAnimatedGeometry,
            "the display panel animated beside a live terminal"
        )

        fixture.controller.toggleSidebar()
        XCTAssertFalse(
            splitController.lastCollapseUsedAnimatedGeometry,
            "the sidebar did not use the display panel's immediate terminal route"
        )
    }

    /// One control, drawn once: the window must never hold two views offering this switch, in
    /// either state. The corner is a *slot* the one toggle moves into, so a second button
    /// appearing here would be the old arrangement coming back.
    func testThereIsOnlyEverOneToggleInTheWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let toggle = try XCTUnwrap(fixture.controller.displayPaneToolbarButton)

        for panelIsOpen in [false, true, false] {
            fixture.controller.setDisplayPaneVisible(panelIsOpen, animated: false)
            settle()
            fixture.window.contentView?.layoutSubtreeIfNeeded()

            let offered = descendants(of: try XCTUnwrap(fixture.window.contentView))
                .compactMap { $0 as? ThemedIconButton }
                .filter { $0.accessibilityTitle() == DisplayPanelToggle.accessibility }
            XCTAssertEqual(
                offered.count,
                1,
                "the panel \(panelIsOpen ? "open" : "shut") offers the same switch"
                    + " \(offered.count) times"
            )
            XCTAssertTrue(offered.first === toggle, "the one on screen is not the window's own")
            XCTAssertEqual(
                toggle.isSelected,
                panelIsOpen,
                "the toggle does not say whether the panel it acts on is on screen"
            )
        }
    }

    /// The corner it moves into is the same point the header's slot occupies, which is the reason
    /// the swap is invisible: the pane arrives underneath a control that never moved.
    func testTheToggleStandsAtTheSamePointInBothHomes() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let toggle = try XCTUnwrap(fixture.controller.displayPaneToolbarButton)

        fixture.controller.setDisplayPaneVisible(false, animated: false)
        settle()
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let shut = toggle.convert(toggle.bounds, to: nil)

        fixture.controller.setDisplayPaneVisible(true, animated: false)
        settle()
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        let open = toggle.convert(toggle.bounds, to: nil)

        XCTAssertEqual(shut.midX, open.midX, accuracy: 0.5, "the toggle moved sideways")
        XCTAssertEqual(shut.midY, open.midY, accuracy: 0.5, "the toggle moved vertically")
        XCTAssertEqual(shut.size, open.size, "the toggle changed size between its two homes")
    }
}
