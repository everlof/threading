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

    /// The plugin Threading ships inside itself. No install step, and no skip: if this is missing
    /// the app has lost its Device Logs pane, which is a failure rather than an absence.
    private var installed: URL {
        get throws {
            try XCTUnwrap(
                NativePluginCatalog.deviceLogsBundle,
                "Threading ships no Device Logs plugin — Contents/PlugIns is empty"
            )
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

        // The pane is drawn by the plugin's own copy of the design system. What proves that
        // crossed the boundary is the components: these types exist only in ThreadingDesignKit,
        // and the app never handed the plugin one — it compiled its own and resolved the theme
        // Threading sent. Appearance itself is covered by the plugin package's render tests.
        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants(of:))
        }
        let kinds = Set(descendants(of: view).map { String(describing: type(of: $0)) })
        for expected in ["ThemedScrollView", "ThemedTableView", "ThemedPopUp"] {
            XCTAssertTrue(kinds.contains(expected), "\(expected) is missing; found \(kinds.sorted())")
        }
    }

    /// A bundled plugin is trusted by *location*: it is sealed by the app's own signature, so the
    /// team allowlist has nothing to add. Emptying the allowlist must not take Threading's own
    /// pane away.
    func testTheBundledPluginLoadsEvenWithNoTeamTrusted() throws {
        let bundle = try installed
        let trusted = NativePluginCatalog.allowedTeams
        NativePluginCatalog.allowedTeams = []
        defer { NativePluginCatalog.allowedTeams = trusted }
        switch NativePluginCatalog.load(bundle) {
        case .success: break
        case .failure(let failure):
            XCTFail("the app's own plugin was refused: \(failure)")
        }
    }

    /// The allowlist still governs everything *outside* the app bundle, which is the whole policy
    /// for the third-party tier.
    func testAnInstalledBundleIsStillRefusedWhenNoTeamIsTrusted() throws {
        let installedByHand = NativePluginCatalog.directory
            .appendingPathComponent("DeviceLogsPlugin.bundle")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: installedByHand.path),
            "no hand-installed bundle to check the allowlist against"
        )
        let trusted = NativePluginCatalog.allowedTeams
        NativePluginCatalog.allowedTeams = []
        defer { NativePluginCatalog.allowedTeams = trusted }
        switch NativePluginCatalog.load(installedByHand) {
        case .success: XCTFail("an empty allowlist loaded a plugin from outside the app")
        case .failure(let failure):
            XCTAssertTrue(failure.code == "untrusted_team" || failure.code == "signature_invalid",
                          "refused for the wrong reason: \(failure.code)")
        }
    }
}
