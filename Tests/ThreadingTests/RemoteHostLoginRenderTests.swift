import AppKit
import XCTest
@testable import Threading

@MainActor
final class RemoteHostLoginRenderTests: HostedStoreTestCase {
    func testRendersLoginConsentInTheShippingHostDialog() throws {
        let previous = AppThemePalette.current
        defer { AppThemePalette.set(previous) }
        AppThemePalette.set(.system)
        let controller = makeMainWindowController()
        let parent = try XCTUnwrap(controller.window)
        parent.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 760), display: true)
        NSApp.activate(ignoringOtherApps: true)
        parent.makeKeyAndOrderFront(nil)
        defer { parent.orderOut(nil) }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            parent.appearance = NSAppearance(named: appearance)
            let record = RemoteHostRecord(label: "Windows PC", destination: "threading-wsl",
                sshConfigFile: "/Users/me/.ssh/threading-windows/config", defaultDirectory: "/home/threading/projects",
                reusesLocalCredentials: true)
            let alert = RemoteHostRecordPromptAlert.makeAlert(editing: record)
            alert.beginSheetModal(for: parent)
            defer { alert.dismiss() }
            let panel = try XCTUnwrap(alert.presentedWindow)
            panel.animationBehavior = .none
            let root = try XCTUnwrap(panel.contentView)
            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let image = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow,
                CGWindowID(panel.windowNumber), [.boundsIgnoreFraming, .nominalResolution]))
            let bitmap = NSBitmapImageRep(cgImage: image)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("remote-host-login-\(name).png"))
            alert.dismiss()
        }
    }
}
