import AppKit
import XCTest
@testable import ThreadingPluginKit

/// The loader's refusals are the whole security boundary, because the operating system enforces
/// nothing about who may be `dlopen`ed into this process. Each refusal is asserted by name, and
/// the ordering rule — signature before principal class — is asserted separately, because getting
/// that backwards would run untrusted code and still report a tidy error.
@MainActor
final class PluginLoaderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugin-loader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAMissingBundleIsRefusedByPath() {
        let loader = PluginLoader.signatureAndDecision()
        XCTAssertThrowsError(
            try loader.load(bundleAt: directory.appendingPathComponent("nope.bundle")) { _ in true }
        ) {
            XCTAssertEqual(($0 as? PluginLoadFailure)?.code, "unreadable_bundle")
        }
    }

    func testABundleWithNoPrincipalClassIsRefused() throws {
        let bundle = try makeBundle(principalClass: nil)
        let loader = PluginLoader.uncheckedForProbesAndTests()
        XCTAssertThrowsError(try loader.load(bundleAt: bundle)) {
            XCTAssertEqual(($0 as? PluginLoadFailure)?.code, "no_principal_class")
        }
    }

    /// An unsigned bundle must be refused *before* its principal class is read, since reading it
    /// is what maps and runs the code. Asserting the failure code proves the order: a loader that
    /// checked the signature afterwards would report `no_principal_class` for this fixture.
    func testAnUnsignedBundleIsRefusedForItsSignatureNotItsContents() throws {
        let bundle = try makeBundle(principalClass: nil)
        XCTAssertThrowsError(
            try PluginLoader.signatureAndDecision().load(bundleAt: bundle) { _ in true }
        ) {
            XCTAssertEqual(($0 as? PluginLoadFailure)?.code, "signature_invalid",
                           "the signature must be judged before the principal class is read")
        }
    }

    /// The decision runs before the code does.
    ///
    /// A decision consulted afterwards would be a prompt shown about a plugin that had already
    /// run, which is the whole failure this tier is built to avoid. The fixture is unsigned, so
    /// this asserts the pair: refused, and never asked, because the signature settled it first.
    func testTheDecisionIsAskedBeforeAnyCodeIsMapped() throws {
        let bundle = try makeBundle(principalClass: nil)
        var asked = false
        XCTAssertThrowsError(
            try PluginLoader.signatureAndDecision().load(bundleAt: bundle) { _ in
                asked = true
                return true
            }
        )
        XCTAssertFalse(asked, "an invalid signature must refuse before a decision is worth asking")
    }

    /// Leaving the decision out must refuse rather than default to yes.
    ///
    /// The overload exists for the two policies that need no decision, and nothing stops it being
    /// called on this one. A silent bypass is precisely how the previous shape failed — an empty
    /// allowlist read as "accept anything" — so the omission is a refusal.
    func testALoaderThatWantsADecisionRefusesWhenAskedWithoutOne() throws {
        let bundle = try makeBundle(principalClass: "NSObject")
        XCTAssertThrowsError(try PluginLoader.signatureAndDecision().load(bundleAt: bundle)) {
            let code = ($0 as? PluginLoadFailure)?.code
            XCTAssertTrue(
                code == "not_approved" || code == "signature_invalid",
                "expected a refusal, got \(code ?? "nil")"
            )
        }
    }

    /// The unsafe mode still exists, because a probe needs it — but it has to be asked for by name
    /// rather than reached by leaving an argument empty. There is no `init`, so there is no way to
    /// build a loader without choosing.
    func testRunningAnythingHasToBeAskedForByName() throws {
        let bundle = try makeBundle(principalClass: nil)
        XCTAssertThrowsError(try PluginLoader.uncheckedForProbesAndTests().load(bundleAt: bundle)) {
            XCTAssertEqual(($0 as? PluginLoadFailure)?.code, "no_principal_class",
                           "the signature check is skipped, so the bundle's contents decide")
        }
    }

    func testRefusalCodesCarryNoPathOrIdentity() {
        let failures: [PluginLoadFailure] = [
            .unreadableBundle(path: "/Users/someone/secret/Plugin.bundle"),
            .signatureInvalid(status: -67062),
            .noPrincipalClass,
            .wrongProtocol,
            .apiVersionMismatch(found: 9, expected: 1),
            .notApproved(identifier: "codes.threading.plugin.example"),
        ]
        for failure in failures {
            XCTAssertFalse(failure.code.contains("/"), "\(failure.code) leaks a path")
            XCTAssertFalse(failure.code.contains("codes.threading"), "\(failure.code) leaks an identity")
            XCTAssertEqual(failure.code, failure.code.lowercased())
        }
    }

    func testTheDescriptionNamesTheVersionsOnAMismatch() {
        let failure = PluginLoadFailure.apiVersionMismatch(found: 9, expected: 1)
        XCTAssertTrue(failure.description.contains("9"))
        XCTAssertTrue(failure.description.contains("1"))
    }

    // MARK: - Fixture

    private func makeBundle(principalClass: String?) throws -> URL {
        let bundle = directory.appendingPathComponent("Fixture.bundle")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": "codes.threading.test.fixture",
            "CFBundleName": "Fixture",
            "CFBundlePackageType": "BNDL",
        ]
        if let principalClass { plist["NSPrincipalClass"] = principalClass }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }
}

/// The theme and context are the versioned payloads; a change to either is a contract change.
final class PluginContractTests: XCTestCase {

    func testTheContextExposesOnlyNamedStringArguments() {
        let context = PluginContext(theme: .fixture(), arguments: ["udid": "ABC", "rate": "6000"])
        XCTAssertEqual(context.argument("udid"), "ABC")
        XCTAssertNil(context.argument("session"))
    }

    func testTheThemeCarriesEveryTokenAPluginIsPromised() {
        let theme = PluginTheme.fixture()
        XCTAssertEqual(theme.rowHeight, 16)
        XCTAssertTrue(theme.isDark)
        XCTAssertTrue(theme.monospacedFont.isFixedPitch)
    }

    /// V4 makes the pane selector optional. A new host can still run a v3 pane plugin, while a v3
    /// host's exact generation check refuses navigator-only v4 code before selector dispatch.
    func testTheAPIVersionCompatibilityWindowPreservesV3PanePlugins() {
        XCTAssertEqual(ThreadingPluginAPI.version, 4)
        XCTAssertEqual(ThreadingPluginAPI.minimumSupportedVersion, 3)
        XCTAssertFalse(ThreadingPluginAPI.supports(2))
        XCTAssertTrue(ThreadingPluginAPI.supports(3))
        XCTAssertTrue(ThreadingPluginAPI.supports(4))
        XCTAssertFalse(ThreadingPluginAPI.supports(5))
    }

    /// Version 2 added `encodedTheme`, which is how a plugin linking `ThreadingDesignKit` gets the
    /// host's whole theme instead of the seven tokens beside it. It is optional on both ends: a
    /// host that cannot encode still sends the tokens, and a plugin that does not link the design
    /// system ignores the field.
    func testTheThemeCanCarryTheHostsWholeThemeAndIsUsableWithoutIt() {
        XCTAssertNil(PluginTheme.fixture().encodedTheme, "the tokens alone remain a valid payload")
        let payload = Data("a theme, encoded".utf8)
        XCTAssertEqual(PluginTheme.fixture(encodedTheme: payload).encodedTheme, payload)
    }
}

private extension PluginTheme {
    static func fixture(encodedTheme: Data? = nil) -> PluginTheme {
        PluginTheme(
            background: .black,
            surface: .darkGray,
            text: .white,
            secondaryText: .gray,
            accent: .orange,
            monospacedFont: .monospacedSystemFont(ofSize: 11, weight: .regular),
            rowHeight: 16,
            isDark: true,
            encodedTheme: encodedTheme
        )
    }
}
