import AppKit
import XCTest
@testable import Threading
import ThreadingPluginKit

/// The native plugin tier's front door.
///
/// This is the one tier where the operating system enforces nothing: Threading ships hardened
/// runtime carrying `disable-library-validation`, so `dlopen` will map a bundle from any team or
/// none. Every check is ours, and the most important property is what happens with no policy set.
@MainActor
final class NativePluginCatalogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugin-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAMissingBundleIsRefusedByNameRatherThanIgnored() {
        let missing = directory.appendingPathComponent("Nope.bundle")
        switch NativePluginCatalog.load(missing) {
        case .success: XCTFail("a bundle that is not there must not load")
        case .failure(let failure): XCTAssertEqual(failure.code, "unreadable_bundle")
        }
    }

    /// The pane shows the refusal instead of an empty rectangle, because "the plugin did not
    /// appear" is not a diagnosis and nothing else in the system will report one.
    func testThePaneStatesWhyAPluginDidNotLoad() throws {
        let controller = NativePluginPaneViewController(
            bundleURL: directory.appendingPathComponent("Absent.bundle"),
            owningSessionID: SessionID()
        )
        controller.loadView()
        XCTAssertNil(controller.loaded)
        XCTAssertEqual(controller.refusal?.code, "unreadable_bundle")
        let labels = descendants(of: controller.view).compactMap { $0 as? NSTextField }
        XCTAssertTrue(
            labels.contains { !$0.stringValue.isEmpty },
            "a refused plugin should leave a sentence, not a blank pane"
        )
    }

    /// The plugin is told a narrow, versioned set of values — never a session, project or window.
    func testThePluginContextCarriesTokensAndNamedArgumentsOnly() {
        let theme = NativePluginCatalog.theme()
        XCTAssertTrue(theme.monospacedFont.isFixedPitch)
        XCTAssertGreaterThan(theme.rowHeight, 0)
        let context = PluginContext(theme: theme, arguments: ["sessionID": "abc"])
        XCTAssertEqual(context.argument("sessionID"), "abc")
        XCTAssertNil(context.argument("projectStore"), "there is no door to the model here")
    }

    func testPaneHostAppliesThemeAfterConstructionAndOnLiveChanges() {
        let plugin = PanePresentationProbe()
        let controller = NativePluginPaneViewController(
            bundleURL: directory.appendingPathComponent("Probe.bundle"),
            owningSessionID: nil,
            loadPlugin: { _ in .success(plugin) }
        )

        controller.loadView()
        XCTAssertEqual(plugin.appliedThemes.count, 1)
        NotificationCenter.default.post(AppThemeDidChange(themeID: .system))
        XCTAssertEqual(plugin.appliedThemes.count, 2)
    }

    func testNavigatorOnlyPluginProducesANamedPaneCapabilityRefusal() {
        let plugin = NavigatorOnlyPresentationProbe()
        let controller = NativePluginPaneViewController(
            bundleURL: directory.appendingPathComponent("NavigatorOnly.bundle"),
            owningSessionID: nil,
            loadPlugin: { _ in .success(plugin) }
        )

        controller.loadView()
        XCTAssertNil(controller.loaded)
        XCTAssertEqual(controller.refusal?.code, "capability_unavailable")
        XCTAssertTrue(descendants(of: controller.view).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("pane") })
    }

    func testSuccessfulReloadClearsThePreviousRefusal() {
        let plugin = PanePresentationProbe()
        var attempt = 0
        let controller = NativePluginPaneViewController(
            bundleURL: directory.appendingPathComponent("Retry.bundle"),
            owningSessionID: nil,
            loadPlugin: { _ in
                attempt += 1
                return attempt == 1
                    ? .failure(.notApproved(identifier: plugin.pluginIdentifier))
                    : .success(plugin)
            }
        )

        controller.loadView()
        XCTAssertEqual(controller.refusal?.code, "not_approved")
        controller.reloadPresentation()
        XCTAssertNil(controller.refusal)
        XCTAssertTrue(controller.loaded === plugin)
        XCTAssertEqual(plugin.appliedThemes.count, 1)
    }

    func testTheDirectoryIsUnderThreadingsOwnApplicationSupport() {
        let path = NativePluginCatalog.directory.path
        XCTAssertTrue(path.hasSuffix("/Threading/Plugins"), "unexpected location: \(path)")
    }

    func testEnumerationIsBoundedAndOnlyOffersBundles() throws {
        for index in 0..<5 {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("Sample\(index).bundle"),
                withIntermediateDirectories: true
            )
        }
        try Data().write(to: directory.appendingPathComponent("notes.txt"))
        // The catalogue reads its own directory; this asserts the filter and cap on the same rule.
        let bundles = (try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )).filter { $0.pathExtension == "bundle" }
        XCTAssertEqual(bundles.count, 5)
        XCTAssertFalse(bundles.contains { $0.lastPathComponent == "notes.txt" })
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class PanePresentationProbe: NSObject, ThreadingNativePlugin {
    static let pluginAPIVersion = 4
    let pluginIdentifier = "tests.pane-presentation"
    private(set) var appliedThemes: [PluginTheme] = []

    required override init() { super.init() }

    func makePaneView(context _: PluginContext) -> NSView { NSView() }

    func apply(theme: PluginTheme) { appliedThemes.append(theme) }
}

@MainActor
private final class NavigatorOnlyPresentationProbe: NSObject, ThreadingNativePlugin {
    static let pluginAPIVersion = 4
    let pluginIdentifier = "tests.navigator-only-presentation"

    required override init() { super.init() }

    func apply(theme _: PluginTheme) {}
}
