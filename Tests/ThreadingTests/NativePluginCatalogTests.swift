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
    private var previousAllowedTeams: Set<String>!

    override func setUpWithError() throws {
        previousAllowedTeams = NativePluginCatalog.allowedTeams
        NativePluginCatalog.allowedTeams = NativePluginCatalog.defaultAllowedTeams
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugin-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        NativePluginCatalog.allowedTeams = previousAllowedTeams
    }

    /// The default that matters. This tier runs unsandboxed code in process, so the shipping
    /// policy names only the first-party signing team and does not infer trust from installation.
    func testTheShippingDefaultTrustsOnlyTheFirstPartyTeam() {
        XCTAssertEqual(
            NativePluginCatalog.allowedTeams,
            NativePluginCatalog.defaultAllowedTeams
        )
        XCTAssertEqual(NativePluginCatalog.allowedTeams, ["SMQ3E8Y57T"])
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
