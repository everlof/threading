import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// The inspected package metadata in the same confirmation sheet used by both installation paths.
@MainActor
final class ExtensionInstallConfirmationRenderTests: HostedStoreTestCase {
    func testRendersAgentFacingToolDisclosureInTheShippingInstallSheet() throws {
        let savedTheme = AppThemePalette.current
        Design.Motion.reduceMotionOverrideForTesting = true
        defer {
            AppThemePalette.set(savedTheme)
            Design.Motion.reduceMotionOverrideForTesting = nil
        }

        let directory = renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let cyberpunk = try XCTUnwrap(AppThemeLibrary.stock.first { $0.name == "Cyberpunk" })
        let fixtures: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("cyberpunk-dark", cyberpunk, .darkAqua),
        ]

        for (name, theme, appearanceName) in fixtures {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for agentTrust in [false, true] {
                let png = try XCTUnwrap(renderSheet(
                    theme: theme, appearance: appearance, agentTrust: agentTrust
                ))
                let suffix = agentTrust ? "-agent" : ""
                try png.write(to: directory.appendingPathComponent(
                    "extension-install-confirmation-\(name)\(suffix).png"
                ))
            }
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
        theme: AppTheme, appearance: NSAppearance, agentTrust: Bool
    ) -> Data? {
        AppThemePalette.set(theme)

        let shell = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        guard let parent = shell.window else { return nil }
        parent.setContentSize(NSSize(width: 1100, height: 800))
        parent.appearance = appearance
        parent.isReleasedWhenClosed = false
        parent.animationBehavior = .none
        parent.makeKeyAndOrderFront(nil)
        defer { parent.orderOut(nil) }

        let request = ExtensionInstallConfirmation.request(
            for: proposal(),
            prompt: agentTrust ? .approveAgentExtensionInstall : .installUnsignedExtension
        )
        let alert = agentTrust
            ? ConfirmationAlert.makeAlert(AgentExtensionInstallConfirmation.request(
                from: request, agentName: "Build Tools development"
            ))
            : ConfirmationAlert.makeAlert(request)
        XCTAssertEqual(alert.buttons.count, agentTrust ? 3 : 2)
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertNotEqual(alert.buttons[1].keyEquivalent, "\r")
        XCTAssertFalse(alert.showsSuppressionButton)
        alert.beginSheetModal(for: parent)
        defer { alert.dismiss() }

        guard let panel = alert.presentedWindow,
              let content = panel.contentView else { return nil }
        panel.appearance = appearance
        content.appearance = appearance
        AppThemeRefresh.repaint(content)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            return nil
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func proposal() -> ExtensionInstallProposal {
        let root = URL(fileURLWithPath: "/Users/example/Downloads/BuildTools.threadingextension")
        let manifest = ExtensionManifest(
            identifier: "com.example.build-tools",
            name: "Build Tools",
            version: "1.4.0",
            runtime: .webAssembly,
            executable: "bin/build-tools.wasm",
            capabilities: [.mcpTools],
            mcpTools: [
                .init(
                    id: "lookup",
                    title: "Lookup Build",
                    description: "Find a build by its identifier."
                ),
                .init(
                    id: "publish",
                    title: "Publish Build",
                    description: "Publish the selected build to the configured channel."
                )
            ]
        )
        return ExtensionInstallProposal(bundle: ThreadingExtensionBundle(
            rootURL: root,
            executableURL: root.appendingPathComponent("bin/build-tools.wasm"),
            sourceURL: nil,
            manifest: manifest
        ))
    }
}
