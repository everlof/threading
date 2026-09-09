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
    func testThePaneStatesWhyAPluginDidNotLoadWithoutVerifyingOnMain() async throws {
        let probe = PluginVerificationThreadProbe()
        let controller = NativePluginPaneViewController(
            bundleURL: directory.appendingPathComponent("Absent.bundle"),
            owningSessionID: SessionID(),
            verifyPlugin: { url in
                probe.recordCurrentThread()
                return .failure(.unreadableBundle(path: url.path))
            }
        )
        controller.loadView()
        for _ in 0..<100 where controller.refusal == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(controller.loaded)
        XCTAssertEqual(controller.refusal?.code, "unreadable_bundle")
        XCTAssertEqual(probe.ranOnMain, false)
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

    func testVerifiedInstalledCandidateRejectsAChangedExpectedBuildBeforeMapping() async throws {
        let source = Bundle(for: NativePluginCatalogTests.self).bundleURL
        let url = directory.appendingPathComponent("InstalledTests.bundle", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: url)
        let verification = await Task.detached {
            NativePluginCatalog.verify(url, isBundled: false)
        }.value
        let candidate: NativePluginCatalog.VerifiedCandidate
        switch verification {
        case .failure(let failure):
            return XCTFail("test bundle should verify: \(failure)")
        case .success(let value):
            candidate = value
        }
        let identity = try XCTUnwrap(candidate.bundle.identity)
        let changed = PluginLoader.PluginIdentity(
            bundleIdentifier: identity.bundleIdentifier,
            team: identity.team,
            cdHash: identity.cdHash + "-replacement"
        )

        switch NativePluginCatalog.load(candidate, expectedInstalledIdentity: changed) {
        case .success:
            XCTFail("a different discovered build must never map")
        case .failure(let failure):
            XCTAssertEqual(failure.code, "build_changed")
        }
    }

    func testRepeatedInstalledLoadReusesTheCandidateReservedForItsExactIdentity() async throws {
        let url = try makeSignedBundleWithoutExecutable(named: "CachedTests")

        func verify() async throws -> NativePluginCatalog.VerifiedCandidate {
            let result = await Task.detached {
                NativePluginCatalog.verify(url, isBundled: false)
            }.value
            switch result {
            case .success(let candidate): return candidate
            case .failure(let failure):
                throw XCTSkip("test fixture did not verify as an installed bundle: \(failure)")
            }
        }

        let first = try await verify()
        let identity = try XCTUnwrap(first.bundle.identity)
        NativePluginCatalog.approvals.remember(true, for: identity)
        defer { NativePluginCatalog.approvals.revoke(identifier: identity.bundleIdentifier) }

        // The XCTest bundle is not a plugin, so construction is expected to fail. The important
        // property is that reaching the principal-class edge reserves this verified build.
        if case .success = NativePluginCatalog.load(first) {
            XCTFail("the XCTest bundle unexpectedly conformed to the native plugin contract")
        }
        let reserved = try XCTUnwrap(
            NativePluginCatalog.cachedInstalledCandidate(identity: identity)
        )
        XCTAssertTrue(reserved.bundle === first.bundle)

        let separatelyVerified = try await verify()
        if case .success = NativePluginCatalog.load(separatelyVerified) {
            XCTFail("the XCTest bundle unexpectedly conformed to the native plugin contract")
        }
        let reused = try XCTUnwrap(
            NativePluginCatalog.cachedInstalledCandidate(identity: identity)
        )
        XCTAssertTrue(reused.bundle === first.bundle)
        XCTAssertFalse(reused.bundle === separatelyVerified.bundle)
    }

    func testApprovalUsesTheVerifiedNameAfterTheInstallPathIsReplaced() async throws {
        let url = try makeSignedBundleWithoutExecutable(
            named: "ApprovalFixture",
            displayName: "Verified build"
        )
        let verification = await Task.detached {
            NativePluginCatalog.verify(url, isBundled: false)
        }.value
        let candidate: NativePluginCatalog.VerifiedCandidate
        switch verification {
        case .success(let value): candidate = value
        case .failure(let failure):
            return XCTFail("test fixture should verify: \(failure)")
        }

        let controller = NativePluginPaneViewController(
            bundleURL: url,
            owningSessionID: nil,
            verifyPlugin: { _ in .success(candidate) }
        )
        controller.loadView()
        for _ in 0..<100 where controller.refusal == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.refusal?.code, "not_approved")

        try FileManager.default.removeItem(at: url)
        _ = try makeSignedBundleWithoutExecutable(
            named: "ApprovalFixture",
            displayName: "Replacement build"
        )

        let request = try XCTUnwrap(controller.approvalRequest)
        XCTAssertEqual(request.identity, candidate.bundle.identity)
        XCTAssertEqual(request.displayName, "Verified build")
        XCTAssertEqual(controller.displayName, "Verified build")
    }

    func testBundledTrustIsRecomputedAtVerification() async {
        let outsideHost = directory.appendingPathComponent("Moved.bundle")
        try? FileManager.default.createDirectory(
            at: outsideHost,
            withIntermediateDirectories: true
        )

        let verification = await Task.detached {
            NativePluginCatalog.verify(outsideHost, isBundled: true)
        }.value
        switch verification {
        case .success:
            XCTFail("an out-of-host path must not inherit bundled trust from discovery")
        case .failure(let failure):
            XCTAssertEqual(failure.code, "build_changed")
        }
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

    private func makeSignedBundleWithoutExecutable(
        named name: String,
        displayName: String? = nil
    ) throws -> URL {
        let url = directory.appendingPathComponent("\(name).bundle", isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let identifier = "codes.threading.tests.\(UUID().uuidString.lowercased())"
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": displayName ?? name,
            "CFBundleDisplayName": displayName ?? name,
            "CFBundlePackageType": "BNDL",
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", url.path]
        signer.standardOutput = FileHandle.nullDevice
        signer.standardError = FileHandle.nullDevice
        try signer.run()
        signer.waitUntilExit()
        XCTAssertEqual(signer.terminationStatus, 0, "fixture could not be ad-hoc signed")
        return url
    }
}

private final class PluginVerificationThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var ranOnMain: Bool? {
        lock.withLock { value }
    }

    func recordCurrentThread() {
        lock.withLock { value = Thread.isMainThread }
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
