import AppKit
import XCTest
import ThreadingPluginKit
@testable import Threading

/// Loading a real, signed plugin bundle from the place a user would put it.
///
/// This is the end-to-end the unit tests cannot reach: the loader's policy, the Objective-C
/// principal-class match, the shared-framework identity that two copies of an `@objc` protocol
/// would break, and the theme crossing into a view built by another binary.
///
/// It skips when no bundle is installed, because the bundle is built by `scripts/build_plugin.sh`
/// and signed with a Developer ID this machine may not have. A skip says so rather than passing
/// quietly, so a green run on a machine without the plugin is not mistaken for coverage.
@MainActor
final class NativePluginLoadingTests: XCTestCase {

    private var installed: URL {
        get throws {
            let bundle = NativePluginCatalog.directory
                .appendingPathComponent("DeviceLogsPlugin.bundle")
            guard FileManager.default.fileExists(atPath: bundle.path) else {
                throw XCTSkip("no plugin installed — run scripts/build_plugin.sh Plugins/DeviceLogsPlugin --install")
            }
            return bundle
        }
    }

    func testTheSignedPluginLoadsAndBuildsAPaneThatFollowsTheHostTheme() throws {
        let bundle = try installed
        let plugin: ThreadingNativePlugin
        switch NativePluginCatalog.load(bundle) {
        case .success(let loaded): plugin = loaded
        case .failure(let failure): return XCTFail("the plugin was refused: \(failure)")
        }

        XCTAssertEqual(plugin.pluginIdentifier, "codes.threading.plugin.devicelogs")
        XCTAssertEqual(type(of: plugin).pluginAPIVersion, ThreadingPluginAPI.version)

        let view = plugin.makePaneView(context: PluginContext(
            theme: NativePluginCatalog.theme(),
            arguments: [:]
        ))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        view.layoutSubtreeIfNeeded()

        // The pane is drawn by the plugin's own copy of the design system, so what proves the
        // theme crossed is that its ground matches the host's — not that it drew something.
        let painted = try XCTUnwrap(view.layer?.backgroundColor)
        let actual = try XCTUnwrap(NSColor(cgColor: painted)?.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(Design.Surface.ground.usingColorSpace(.sRGB))
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 1.0 / 255.0)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 1.0 / 255.0)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 1.0 / 255.0)
    }

    /// Draws the loaded plugin's pane with real rows in it.
    ///
    /// A rendered picture is how appearance is reviewed here, and this is the one surface where
    /// the thing being checked is that a *different binary* drew something that belongs: the pane
    /// is built by the plugin's own copy of the design system, resolving the theme the host sent.
    func testRendersTheLoadedPluginsPaneWithLiveRows() throws {
        let bundle = try installed
        guard case .success(let plugin) = NativePluginCatalog.load(bundle) else {
            throw XCTSkip("the plugin was refused")
        }
        let view = plugin.makePaneView(context: PluginContext(
            theme: NativePluginCatalog.theme(),
            arguments: [:]
        ))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 460)

        // The stream is a real child process, so the rows arrive on their own schedule. Spin the
        // run loop rather than sleeping: the pane drains on a timer that needs it to turn.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        view.layoutSubtreeIfNeeded()

        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("native-plugin-pane.png")
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: target)
        print("RENDERED \(target.path)")
    }

    /// The allowlist is the whole policy, so a run with nothing trusted must refuse the same
    /// bundle that loads a moment earlier.
    func testTheSameBundleIsRefusedWhenNoTeamIsTrusted() throws {
        let bundle = try installed
        let trusted = NativePluginCatalog.allowedTeams
        NativePluginCatalog.allowedTeams = []
        defer { NativePluginCatalog.allowedTeams = trusted }
        switch NativePluginCatalog.load(bundle) {
        case .success: XCTFail("an empty allowlist loaded a plugin")
        case .failure(let failure):
            XCTAssertTrue(failure.code == "untrusted_team" || failure.code == "signature_invalid",
                          "refused for the wrong reason: \(failure.code)")
        }
    }
}
