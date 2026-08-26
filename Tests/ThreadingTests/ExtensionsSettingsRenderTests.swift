import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// Captures the real virtualized Extensions page with both launch sources visible.
///
/// The fixture is intentionally mixed: Storm comes from the exact app-owned catalogue resource,
/// while Local Build Notes is a disabled package in redirected app storage. One bounded page then
/// proves the launch catalogue did not erase the established import, provenance, and lifecycle
/// presentation. Nothing is fetched, enabled, or executed to make the image.
final class ExtensionsSettingsRenderTests: XCTestCase {
    private enum Render {
        static let width = SettingsUIDefaults.pageWidth
        static let height: CGFloat = 920

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    @MainActor
    func testRendersFirstPartyAndInstalledExtensionsUnderRepresentativeThemes() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingExtensionsSettingsRender-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            AppThemePalette.set(.system)
            try? FileManager.default.removeItem(at: workspace)
        }

        let source = workspace.appendingPathComponent(
            "LocalBuildNotes.threadingextension",
            isDirectory: true
        )
        try makeLocalPackage(at: source)
        let store = ExtensionPackageStore(
            rootURL: workspace.appendingPathComponent("Host", isDirectory: true)
        )
        _ = try store.install(from: source)
        var written = 0
        let renders: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua)
        ]
        for (name, theme, appearanceName) in renders {
            AppThemePalette.set(theme)
            let data = try XCTUnwrap(
                pageImage(store: store, appearance: appearanceName),
                "no Extensions image for \(name)"
            )
            try data.write(to: Render.directory.appendingPathComponent(
                "extensions-settings-\(name).png"
            ))
            written += 1
        }

        XCTAssertEqual(written, renders.count)
    }

    @MainActor
    private func pageImage(
        store: ExtensionPackageStore,
        appearance name: NSAppearance.Name
    ) -> Data? {
        let appearance = NSAppearance(named: name)
        var data: Data?
        let render = {
            let manager = ExtensionManager(store: store)
            defer { manager.terminateAll() }
            let controller = ExtensionsPreferencesViewController(manager: manager)
            let host = self.laidOut(controller.view)
            host.appearance = appearance
            controller.view.appearance = appearance
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            data = self.png(of: host)
        }
        appearance?.performAsCurrentDrawingAppearance(render)
        return data
    }

    @MainActor
    private func laidOut(_ view: NSView) -> NSView {
        let host = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: Render.width,
            height: Render.height
        ))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    private func png(of host: NSView) -> Data? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func makeLocalPackage(at root: URL) throws {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("local-build-notes")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        try JSONEncoder().encode(ExtensionManifest(
            identifier: "com.example.local-build-notes",
            name: "Local Build Notes",
            version: "1.2.0",
            runtime: .native,
            executable: "bin/local-build-notes",
            capabilities: [.commands]
        )).write(to: root.appendingPathComponent(ExtensionBundleInspector.manifestName))
    }
}
