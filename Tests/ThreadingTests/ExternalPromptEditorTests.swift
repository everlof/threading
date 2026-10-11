import AppKit
import XCTest
@testable import Threading

@MainActor
final class ExternalPromptEditorTests: XCTestCase {
    func testEditorFallbackRespectsBothStandardOverrides() {
        let path = "/tmp/Threading Test.app/Contents/MacOS/Threading"
        XCTAssertEqual(
            AgentLauncher.defaultPromptEditorEnvironment(inherited: [:], executablePath: path),
            ["EDITOR": "'/tmp/Threading Test.app/Contents/MacOS/Threading' '--prompt-editor'"]
        )
        XCTAssertEqual(
            AgentLauncher.defaultPromptEditorEnvironment(
                inherited: ["EDITOR": "nvim"], executablePath: path
            ),
            [:]
        )
        XCTAssertEqual(
            AgentLauncher.defaultPromptEditorEnvironment(
                inherited: ["VISUAL": "code --wait"], executablePath: path
            ),
            ["EDITOR": "'/tmp/Threading Test.app/Contents/MacOS/Threading' '--prompt-editor'"]
        )
    }

    func testEditorModeRequiresOneFileArgument() {
        XCTAssertEqual(
            ExternalPromptEditor.requestedFile(
                arguments: ["Threading", "--prompt-editor", "/tmp/a draft.md"]
            )?.path,
            "/tmp/a draft.md"
        )
        XCTAssertNil(ExternalPromptEditor.requestedFile(arguments: ["Threading", "--prompt-editor"]))
        XCTAssertNil(ExternalPromptEditor.requestedFile(arguments: ["Threading", "--other", "/tmp/a"]))
    }

    func testTerminalPlanPassesEditorToItsPTYChild() {
        let plan = AgentLaunchPlan(
            executable: "/bin/sh", arguments: ["-l", "-c", "codex"],
            resumeState: .unavailable,
            environmentOverrides: ["EDITOR": "threading --prompt-editor"]
        )
        let entries = plan.environmentEntries(on: ["PATH=/usr/bin", "EDITOR=old"])
        XCTAssertEqual(entries.filter { $0.hasPrefix("EDITOR=") }, ["EDITOR=threading --prompt-editor"])
        XCTAssertTrue(entries.contains("PATH=/usr/bin"))
    }

    func testDraftRoundTripsAndRefusesAnExternalChange() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-prompt-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("First draft\n".utf8).write(to: file)
        let store = ExternalPromptEditorFileStore()
        let original = try await store.read(file)
        XCTAssertEqual(original.text, "First draft\n")

        try await store.write("Edited draft\n", to: file, replacing: original.bytes)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Edited draft\n")

        do {
            try await store.write("Stale edit", to: file, replacing: original.bytes)
            XCTFail("An older editor must not replace the current draft")
        } catch ExternalPromptEditorFileStore.Failure.changed {
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Edited draft\n")
        }
    }

    func testRendersDraftInTheShippingWindow() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-prompt-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("A longer draft for the prompt editor.\n\n- First item\n- Second item\n\nThis stays in the draft until sent.".utf8)
            .write(to: file)
        let directory = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory()
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        let variants: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua)
        ]
        for (name, theme, appearance) in variants {
            AppThemePalette.set(theme)
            let controller = ExternalPromptEditorWindowController(file: file)
            let window = try XCTUnwrap(controller.window)
            window.appearance = NSAppearance(named: appearance)
            await controller.waitForDraft()
            XCTAssertTrue(controller.source.textView.string.contains("First item"))
            let root = try XCTUnwrap(window.contentView)
            window.appearance?.performAsCurrentDrawingAppearance {
                AppThemeRefresh.repaint(root)
                root.layoutSubtreeIfNeeded()
            }
            XCTAssertGreaterThan(controller.source.bounds.width, 450)
            XCTAssertGreaterThan(controller.source.bounds.height, 250)
            // The cache helper follows the active screen's backing scale. Pin evidence to 1×
            // so moving the test host between Retina and non-Retina displays changes no pixels.
            let bounds = root.bounds.integral
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: max(1, Int(bounds.width)),
                pixelsHigh: max(1, Int(bounds.height)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            bitmap.size = bounds.size
            window.appearance?.performAsCurrentDrawingAppearance {
                root.cacheDisplay(in: bounds, to: bitmap)
            }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("external-prompt-editor-\(name).png"))
        }
    }
}
