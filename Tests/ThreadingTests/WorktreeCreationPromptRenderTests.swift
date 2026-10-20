import AppKit
import XCTest
@testable import Threading

@MainActor
final class WorktreeCreationPromptRenderTests: HostedStoreTestCase {
    func testRendersNewWorktreePromptInTheShippingHostDialog() throws {
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

        let request = WorktreeCreation.promptRequest
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua),
                                       ("dark", .darkAqua)] {
            parent.appearance = NSAppearance(named: appearanceName)
            let field = ThemedTextField(frame: NSRect(origin: .zero, size: request.fieldSize))
            field.placeholderString = request.placeholder
            let alert = TextPromptAlert.makeAlert(request, field: field)
            alert.beginSheetModal(for: parent)
            let panel = try XCTUnwrap(alert.presentedWindow)
            panel.animationBehavior = .none
            panel.appearance = parent.appearance
            (field.currentEditor() as? NSTextView)?.insertionPointColor = .clear
            let content = try XCTUnwrap(panel.contentView)
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))

            let png = try XCTUnwrap(ShippingWindowCapture.pngData(for: panel))
            try png.write(to: output.appendingPathComponent("worktree-creation-prompt-\(name).png"))
            alert.dismiss()
        }
    }
}
