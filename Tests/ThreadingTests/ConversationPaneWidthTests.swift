import AppKit
import SwiftTerm
import XCTest
@testable import Threading

@MainActor
final class ConversationPaneWidthTests: HostedStoreTestCase {
    private let title = "Investigate the browser workspace and conversation layout"

    func testNativeAndTerminalSessionsReachTheMinimumBesideABrowser() throws {
        let restore = prepareWindowPreferences()
        defer { restore() }
        for native in [false, true] {
            let fixture = try makeSessionFixture(native: native)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let window = try XCTUnwrap(controller.window)
            let originalSize = window.frame.size
            let split = controller.contentSplitController.splitView
            var narrowTitleWidth: CGFloat = 0

            for requested in [CGFloat(600), 400, MainWindowDefaults.minContentWidth, 900, 480] {
                split.setPosition(requested, ofDividerAt: 0)
                window.layoutIfNeeded()
                let actual = controller.containerViewController.view.bounds.width
                print("Conversation divider native=\(native) requested=\(requested) actual=\(actual)")
                if requested == MainWindowDefaults.minContentWidth, abs(actual - requested) > 1 {
                    print(controller.containerViewController.view.constraintsAffectingLayout(for: .horizontal))
                }
                XCTAssertEqual(actual, requested,
                               accuracy: 1, "native=\(native)")
                XCTAssertEqual(window.frame.size, originalSize)
                assertHeaderControlsFit(controller)
                if requested == MainWindowDefaults.minContentWidth {
                    narrowTitleWidth = controller.pageTitleView.bounds.width
                }
            }
            XCTAssertGreaterThan(controller.pageTitleView.bounds.width, narrowTitleWidth,
                                 "the title did not reclaim space when the pane widened")

            controller.setDisplayPaneVisible(false, animated: false)
            controller.setDisplayPaneVisible(true, animated: false)
            settle()
            window.layoutIfNeeded()
            XCTAssertEqual(controller.containerViewController.view.bounds.width, 480, accuracy: 1,
                           "reopening the browser lost the chosen divider width")

            // The toolbar moves into the conversation header when its sidebar is hidden.
            // It must still yield the rest of the workspace at a width that holds both runs.
            controller.splitViewController.setCollapsed(
                true, on: controller.splitViewController.splitViewItems[0], animated: false
            )
            window.layoutIfNeeded()
            split.setPosition(520, ofDividerAt: 0)
            window.layoutIfNeeded()
            XCTAssertEqual(controller.containerViewController.view.bounds.width, 520, accuracy: 1)
            assertHeaderControlsFit(controller)

            controller.containerViewController.showComposer(projectID: fixture.projectID)
            XCTAssertTrue(controller.containerViewController.composerViewController === fixture.composer)
            XCTAssertNotNil(fixture.composer.view.superview)
            XCTAssertEqual(fixture.composer.promptView.stringValue, "A draft kept while browsing the conversation.")
        }
    }

    func testRendersNarrowConversationsInTheMainWindow() throws {
        let restore = prepareWindowPreferences()
        defer { restore() }
        let directory = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousTheme = AppThemePalette.current
        let previousTerminalTheme = ThemeAssignments.defaultTheme
        let previousAppearance = NSApp.appearance
        let previousBackdrop = WindowBackdrop.ground
        defer {
            AppThemePalette.set(previousTheme)
            ThemeAssignments.setDefaultTheme(previousTerminalTheme)
            NSApp.appearance = previousAppearance
            WindowBackdrop.set(previousBackdrop)
        }
        let themes: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("threading-light", AppThemeStyles.threading, .aqua),
            ("threading-dark", AppThemeStyles.threading, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua)
        ]
        for (name, theme, appearanceName) in themes {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            // Native chats inherit their session's terminal ground. Set both halves before
            // building the window, so a light capture does not put light-mode ink on a stale
            // dark terminal palette or bake dark layer colours into the new subtree.
            NSApp.appearance = appearance
            AppThemePalette.set(theme)
            let terminalTheme = theme.terminalPalette(for: appearance)
            ThemeAssignments.setDefaultTheme(terminalTheme)
            WindowBackdrop.set(.terminal(terminalTheme.background))
            for native in [false, true] {
                let fixture = try makeSessionFixture(native: native)
                defer { fixture.cleanup() }
                let window = try XCTUnwrap(fixture.controller.window)
                window.appearance = appearance
                let root = try XCTUnwrap(window.contentView)
                AppThemeRefresh.repaint(root)
                fixture.controller.accountUsageItemView.show(usage: usage, limits: [], at: fixtureDate)
                fixture.controller.accountUsageItemView.isHidden = false
                fixture.controller.contentSplitController.splitView.setPosition(
                    MainWindowDefaults.minContentWidth, ofDividerAt: 0
                )
                window.layoutIfNeeded()
                if fixture.controller.containerViewController.view.bounds.width > MainWindowDefaults.minContentWidth + 1 {
                    print("Narrow capture \(name) native=\(native)")
                    print(fixture.controller.containerViewController.view.constraintsAffectingLayout(for: .horizontal))
                }
                XCTAssertEqual(fixture.controller.containerViewController.view.bounds.width,
                               MainWindowDefaults.minContentWidth, accuracy: 1)
                assertHeaderControlsFit(fixture.controller)
                if let terminal = fixture.controller.containerViewController.activeTerminalSession?.terminalView {
                    terminal.prepareFrameForSnapshot()
                }
                let frame = try XCTUnwrap(root.superview)
                let rep = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                // AppKit cannot copy a CAMetalLayer; use SwiftTerm's capture path over the
                // same terminal snapshot while caching the complete product window.
                TerminalView.drawingForBitmapCapture {
                    appearance.performAsCurrentDrawingAppearance {
                        frame.cacheDisplay(in: frame.bounds, to: rep)
                        frame.cacheDisplay(in: frame.bounds, to: rep)
                        if let terminal = fixture.controller.containerViewController.activeTerminalSession?.terminalView {
                            captureTerminal(terminal, in: frame, bitmap: rep)
                        }
                    }
                }
                let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                let mode = native ? "native" : "terminal"
                try data.write(to: directory.appendingPathComponent(
                    "conversation-width-\(mode)-\(name).png"
                ))
            }
        }
    }

    /// Caching a terminal's parent can omit the Metal-backed text. Capture the live terminal
    /// directly, as the theme preview does, and place it at its actual window coordinates.
    private func captureTerminal(_ terminal: TerminalView, in frame: NSView, bitmap: NSBitmapImageRep) {
        guard let terminalBitmap = terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            XCTFail("Could not capture the terminal")
            return
        }
        terminal.cacheDisplay(in: terminal.bounds, to: terminalBitmap)
        terminal.cacheDisplay(in: terminal.bounds, to: terminalBitmap)
        let image = NSImage(size: terminal.bounds.size)
        image.addRepresentation(terminalBitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let target = terminal.convert(terminal.bounds, to: frame)
        // The text capture is transparent where the Metal-backed parent cached black.
        terminal.nativeBackgroundColor.setFill()
        target.fill()
        image.draw(in: target, from: .zero,
                   operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func prepareWindowPreferences() -> () -> Void {
        let previousSidebarWidth = SidebarWidth.stored
        let previousDisplayWidth = DisplayPaneWidth.stored
        let previousFrame = UserDefaults.standard.object(forKey: "NSWindow Frame ThreadingMainWindow")
        let previousReduceMotion = Design.Motion.reduceMotionOverrideForTesting
        Design.Motion.reduceMotionOverrideForTesting = true
        SidebarWidth.record(SidebarDefaults.defaultWidth)
        DisplayPaneWidth.stored = DisplayPaneDefaults.defaultWidth
        return {
            if let previousSidebarWidth { SidebarWidth.record(previousSidebarWidth) }
            else { SidebarWidth.reset() }
            DisplayPaneWidth.stored = previousDisplayWidth
            Design.Motion.reduceMotionOverrideForTesting = previousReduceMotion
            if let previousFrame {
                UserDefaults.standard.set(previousFrame, forKey: "NSWindow Frame ThreadingMainWindow")
            } else {
                UserDefaults.standard.removeObject(forKey: "NSWindow Frame ThreadingMainWindow")
            }
        }
    }

    private func settle() {
        let settled = expectation(description: "window layout settled")
        DispatchQueue.main.async {
            DispatchQueue.main.async { DispatchQueue.main.async { settled.fulfill() } }
        }
        wait(for: [settled], timeout: 5)
    }

    private func assertHeaderControlsFit(_ controller: MainWindowController,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let pane: NSView = controller.containerViewController.view
        let controls: [NSView?] = [controller.pageTitleView, controller.accountUsageItemView,
                                  controller.openInSplitControl, controller.sessionActionsGroup]
        for control in controls.compactMap({ $0 }) {
            let frame = control.convert(control.bounds, to: pane)
            XCTAssertGreaterThanOrEqual(frame.minX, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, pane.bounds.width, file: file, line: line)
        }
        XCTAssertEqual(controller.pageTitleView.accessibilityTitle(), title, file: file, line: line)
        XCTAssertEqual(controller.accountUsageItemView.accessibilityValue() as? String,
                       controller.accountUsageItemView.summaryForTesting.string, file: file, line: line)
    }

    private func makeSessionFixture(native: Bool) throws
        -> (controller: MainWindowController, composer: SessionComposerViewController,
            projectID: ProjectID, cleanup: () -> Void) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-width-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: folder))
        let session = try XCTUnwrap(store.addSession(
            to: project.id, kind: .claude, usesNativeUI: native, title: title
        ))

        // Retain the actual surface before selection so the shipping attach path finds it
        // already allocated and does not launch a provider or a PTY.
        if native {
            let conversation = try XCTUnwrap(AgentRuntime.shared.makeConversation(for: session, in: project))
            let events: [StreamEvent] = [
                .userMessage("Keep the browser beside this conversation while we work."),
                .assistantMessage(blocks: [.text("The browser has room to show the page. The chat remains available beside it.")]),
                .turnFinished(text: nil, outcome: .completed, metrics: TurnMetrics())
            ]
            for event in events {
                for change in conversation.timeline.apply(event) { conversation.apply(change) }
            }
        } else {
            _ = AgentRuntime.shared.makeController(for: session)
        }

        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1_400, height: 800))
        let restored = expectation(description: "session divider restoration")
        DispatchQueue.main.async { restored.fulfill() }
        wait(for: [restored], timeout: 2)
        controller.containerViewController.showComposer(projectID: project.id)
        let composer = controller.containerViewController.composerViewController
        composer.promptView.stringValue = "A draft kept while browsing the conversation."
        controller.projectSidebar(controller.sidebarViewController, didSelectSession: session.id)
        XCTAssertNil(composer.view.superview, "the hidden composer still constrains the chat pane")
        controller.displayPaneController.showSession(session.id)
        _ = try XCTUnwrap(controller.displayPaneController.addBrowserTab(for: session.id, contextKind: .private))
        controller.setDisplayPaneVisible(true, animated: false)
        settle()
        controller.openInSplitControl?.isHidden = false
        controller.accountUsageItemView.show(usage: usage, limits: [], at: fixtureDate)
        controller.accountUsageItemView.isHidden = false
        window.layoutIfNeeded()
        if let terminal = controller.containerViewController.activeTerminalSession?.terminalView {
            terminal.suspendsRenderingWhenNotVisible = false
            terminal.prepareFrameForSnapshot()
            terminal.feed(text: "Browser workspace\r\n\r\nKeep this chat beside the page.\r\n> ")
            XCTAssertTrue(terminal.terminalStateSnapshot().visibleRows.contains {
                $0.text.contains("Browser workspace")
            })
        }
        return (controller, composer, project.id, {
            controller.containerViewController.show(sessionID: nil)
            AgentRuntime.shared.discard(sessionID: session.id)
            store.removeProject(id: project.id)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    private let fixtureDate = Date(timeIntervalSince1970: 1_770_000_000)
    private var usage: AccountUsage {
        AccountUsage(windows: [
            .init(id: UsageDefaults.fiveHourWindowID, label: UsageDefaults.fiveHourLabel,
                  fraction: 0.43, resetsAt: fixtureDate.addingTimeInterval(3_600),
                  windowDuration: UsageDefaults.fiveHourSeconds),
            .init(id: UsageDefaults.weeklyWindowID, label: UsageDefaults.weeklyLabel,
                  fraction: 0.73, resetsAt: fixtureDate.addingTimeInterval(86_400),
                  windowDuration: UsageDefaults.sevenDaySeconds)
        ], planLabel: "Plus", observedAt: fixtureDate, source: .api)
    }
}
