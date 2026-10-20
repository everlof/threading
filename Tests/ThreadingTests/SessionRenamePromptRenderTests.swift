import AppKit
import XCTest
@testable import Threading

@MainActor
final class SessionRenamePromptRenderTests: HostedStoreTestCase {
    func testRendersRenameAndClearInTheShippingMacDialog() throws {
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        AppThemePalette.set(AppThemeStyles.threading)

        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let controller = makeMainWindowController()
        let parent = try XCTUnwrap(controller.window)
        parent.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 760), display: true)
        parent.animationBehavior = .none
        parent.makeKeyAndOrderFront(nil)
        defer { parent.orderOut(nil) }

        let request = TextPromptRequest(title: "Rename Session", confirmTitle: "Rename",
            clearTitle: "Use Agent's Name", current: "Renamed café 日本語",
            placeholder: "Seed conversation", allowsEmpty: true)
        let field = ThemedTextField(frame: NSRect(origin: .zero, size: request.fieldSize))
        field.stringValue = request.current
        field.placeholderString = request.placeholder
        let alert = TextPromptAlert.makeAlert(request, field: field)
        alert.beginSheetModal(for: parent)
        defer { alert.dismiss() }
        let panel = try XCTUnwrap(alert.presentedWindow)
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .aqua)
        (field.currentEditor() as? NSTextView)?.insertionPointColor = .clear
        let content = try XCTUnwrap(panel.contentView)
        AppThemeRefresh.repaint(content)
        content.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let png = try XCTUnwrap(ShippingWindowCapture.pngData(for: panel))
        try png.write(to: output.appendingPathComponent("session-rename-prompt-mac.png"))
    }

    func testRendersCloseConfirmationInTheShippingMacDialog() throws {
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        AppThemePalette.set(AppThemeStyles.threading)

        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let controller = makeMainWindowController()
        let parent = try XCTUnwrap(controller.window)
        parent.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 760), display: true)
        parent.animationBehavior = .none
        parent.makeKeyAndOrderFront(nil)
        defer { parent.orderOut(nil) }

        let session = AgentSession(kind: .codex, title: "Renamed live session")
        let alert = ConfirmationAlert.makeAlert(SessionCoordinator.closeConfirmation(for: session))
        alert.beginSheetModal(for: parent)
        defer { alert.dismiss() }
        let panel = try XCTUnwrap(alert.presentedWindow)
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .aqua)
        let content = try XCTUnwrap(panel.contentView)
        AppThemeRefresh.repaint(content)
        content.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let png = try XCTUnwrap(ShippingWindowCapture.pngData(for: panel))
        try png.write(to: output.appendingPathComponent("session-close-prompt-mac.png"))
    }

    func testRendersClosedSessionInTheShippingMacPane() throws {
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        AppThemePalette.set(AppThemeStyles.threading)

        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-dormant-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id, kind: .codex, title: ""
        ))
        ProjectStore.shared.update(sessionID: session.id) {
            $0.customTitle = "Renamed live session"
        }

        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1_120, height: 720))
        window.animationBehavior = .none
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        // The hosted seam selects the real pane without launching a CLI process. Close then
        // crosses the same dormant presentation path as the live Close Session action.
        controller.containerViewController.setCurrentSessionForTesting(session.id)
        controller.containerViewController.closeTerminal(for: session.id)
        let content = try XCTUnwrap(window.contentView)
        AppThemeRefresh.repaint(content)
        content.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let png = try XCTUnwrap(ShippingWindowCapture.pngData(for: window))
        try png.write(to: output.appendingPathComponent("session-close-dormant-mac.png"))
    }
}
