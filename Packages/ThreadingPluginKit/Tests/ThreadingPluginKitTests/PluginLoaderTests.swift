import AppKit
import XCTest
@testable import ThreadingPluginKit

/// The loader's refusals are the whole security boundary, because the operating system enforces
/// nothing about who may be `dlopen`ed into this process. Each refusal is asserted by name, and
/// the ordering rule — signature before principal class — is asserted separately, because getting
/// that backwards would run untrusted code and still report a tidy error.
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
        let loader = PluginLoader(allowedTeams: [])
        XCTAssertThrowsError(try loader.load(bundleAt: directory.appendingPathComponent("nope.bundle"))) {
            XCTAssertEqual(($0 as? PluginLoadFailure)?.code, "unreadable_bundle")
        }
    }

    func testABundleWithNoPrincipalClassIsRefused() throws {
        let bundle = try makeBundle(principalClass: nil)
        let loader = PluginLoader.acceptingAnyTeam()
        XCTAssertThrowsError(try loader.load(bundleAt: bundle)) {
            XCTAssertEqual(($0 as? PluginLoadFailure)?.code, "no_principal_class")
        }
    }

    /// An unsigned bundle must be refused *before* its principal class is read, since reading it
    /// is what maps and runs the code. Asserting the failure code proves the order: a loader that
    /// checked the signature afterwards would report `no_principal_class` for this fixture.
    func testAnUnsignedBundleIsRefusedForItsSignatureNotItsContents() throws {
        let bundle = try makeBundle(principalClass: nil)
        let loader = PluginLoader(allowedTeams: ["SOMETEAM"])
        XCTAssertThrowsError(try loader.load(bundleAt: bundle)) {
            let code = ($0 as? PluginLoadFailure)?.code
            XCTAssertTrue(
                code == "signature_invalid" || code == "untrusted_team",
                "expected a signature refusal before the principal class was read, got \(code ?? "nil")"
            )
        }
    }

    /// An empty allowlist loads **nothing**.
    ///
    /// It used to skip the signature check, and that read as a convenience for probes while being
    /// the shipping default: `NativePluginCatalog.allowedTeams` is empty until a first-party team
    /// is added, and its own documentation said empty meant *load nothing*. The host and the loader
    /// stated opposite policies and the loader won, so any bundle dropped into the plugins folder
    /// would have been mapped into the process unsandboxed.
    func testAnEmptyAllowlistLoadsNothingRatherThanEverything() throws {
        let bundle = try makeBundle(principalClass: nil)
        let loader = PluginLoader(allowedTeams: [])
        XCTAssertThrowsError(try loader.load(bundleAt: bundle)) {
            let code = ($0 as? PluginLoadFailure)?.code
            XCTAssertTrue(
                code == "signature_invalid" || code == "untrusted_team",
                "an empty allowlist must refuse before the principal class is read, got \(code ?? "nil")"
            )
        }
    }

    /// The unsafe mode still exists, because a probe needs it — but it has to be asked for by name
    /// rather than reached by leaving an argument empty.
    func testRunningAnythingHasToBeAskedForByName() throws {
        let bundle = try makeBundle(principalClass: nil)
        XCTAssertThrowsError(try PluginLoader.acceptingAnyTeam().load(bundleAt: bundle)) {
            XCTAssertEqual(($0 as? PluginLoadFailure)?.code, "no_principal_class",
                           "the signature check is skipped, so the bundle's contents decide")
        }
    }

    func testRefusalCodesCarryNoPathOrIdentity() {
        let failures: [PluginLoadFailure] = [
            .unreadableBundle(path: "/Users/someone/secret/Plugin.bundle"),
            .signatureInvalid(status: -67062),
            .untrustedTeam("ABCDE12345"),
            .noPrincipalClass,
            .wrongProtocol,
            .apiVersionMismatch(found: 9, expected: 1),
        ]
        for failure in failures {
            XCTAssertFalse(failure.code.contains("/"), "\(failure.code) leaks a path")
            XCTAssertFalse(failure.code.contains("ABCDE12345"), "\(failure.code) leaks a team")
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

    /// The version is what the loader compares against. If it changes, every installed plugin
    /// stops loading until it is rebuilt, so it should never move by accident.
    func testTheAPIVersionIsTheOneTheLoaderEnforces() {
        XCTAssertEqual(ThreadingPluginAPI.version, 3)
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
