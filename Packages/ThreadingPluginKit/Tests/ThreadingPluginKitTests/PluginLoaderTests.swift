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

    func testSignedVerificationCanFinishOffMainBeforeDecisionAndMapping() async throws {
        let bundle = try makeBundle(principalClass: nil)
        try sign(bundle)
        let loader = PluginLoader.signatureAndDecision()

        let verified = try await Task.detached {
            try loader.verify(bundleAt: bundle)
        }.value

        XCTAssertNotNil(verified.identity)
        XCTAssertThrowsError(try verified.load { _ in false }) {
            XCTAssertEqual(($0 as? PluginLoadFailure)?.code, "not_approved")
        }
    }

    func testVerifiedInstalledBundleMapsTheStagedBuildAfterSourceReplacement() async throws {
        let bundle = try makeBundle(
            principalClass: "LoaderFixturePrincipal",
            executable: true,
            displayName: "Verified fixture"
        )
        try sign(bundle)
        let loader = PluginLoader.signatureAndDecision()
        let verified = try await Task.detached {
            try loader.verify(bundleAt: bundle)
        }.value

        try FileManager.default.removeItem(at: bundle)
        _ = try makeBundle(principalClass: nil, displayName: "Replacement fixture")
        try sign(bundle)

        XCTAssertEqual(
            verified.displayName,
            "Verified fixture",
            "approval presentation must come from the same staged build that will be mapped"
        )
        XCTAssertThrowsError(try verified.load { _ in true }) {
            XCTAssertEqual(
                ($0 as? PluginLoadFailure)?.code,
                "wrong_protocol",
                "mapping must use the verified staged copy, not the replaced install path"
            )
        }
    }

    func testVerifiedPresentationNameUniformlyBoundsHostileMetadataAndFallbacks() throws {
        let hostile = "Bad\u{200D}format\u{2028}line\u{2029}paragraph\u{0007}control"
        let hostileBundle = try makeBundle(
            principalClass: nil,
            displayName: hostile,
            bundleIdentifier: hostile
        )
        let hostileVerified = try PluginLoader.uncheckedForProbesAndTests()
            .verify(bundleAt: hostileBundle)
        XCTAssertEqual(hostileVerified.displayName, "Plugin")

        let longName = String(repeating: "A", count: 320)
        let longBundle = try makeBundle(
            principalClass: nil,
            displayName: longName,
            bundleFileName: "LongFixture"
        )
        let longVerified = try PluginLoader.uncheckedForProbesAndTests()
            .verify(bundleAt: longBundle)
        XCTAssertEqual(longVerified.displayName.unicodeScalars.count, 256)
        XCTAssertTrue(longVerified.displayName.allSatisfy { $0 == "A" })
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
            .buildChanged(identifier: "codes.threading.plugin.example"),
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

    private func makeBundle(
        principalClass: String?,
        executable: Bool = false,
        displayName: String = "Fixture",
        bundleIdentifier: String = "codes.threading.test.fixture",
        bundleFileName: String = "Fixture"
    ) throws -> URL {
        let bundle = directory.appendingPathComponent("\(bundleFileName).bundle")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundlePackageType": "BNDL",
        ]
        if let principalClass { plist["NSPrincipalClass"] = principalClass }
        if executable { plist["CFBundleExecutable"] = "Fixture" }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if executable { try compileFixtureExecutable(in: contents) }
        return bundle
    }

    private func compileFixtureExecutable(in contents: URL) throws {
        let source = directory.appendingPathComponent("Fixture.m")
        try Data("""
            #import <Foundation/Foundation.h>
            @interface LoaderFixturePrincipal : NSObject
            @end
            @implementation LoaderFixturePrincipal
            @end
            """.utf8).write(to: source)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = [
            "-fobjc-arc",
            "-framework", "Foundation",
            "-bundle",
            source.path,
            "-o", macOS.appendingPathComponent("Fixture").path,
        ]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "clang failed"
            throw NSError(
                domain: "PluginLoaderTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func sign(_ bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--timestamp=none", bundle.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "codesign failed"
            throw NSError(
                domain: "PluginLoaderTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
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
        XCTAssertEqual(theme.color(.label), theme.text)
        XCTAssertEqual(theme.color(.panel), theme.surface)
    }

    func testTheThemeVendsExactSemanticColorsToCustomComponents() {
        let exact = NSColor(calibratedRed: 0.17, green: 0.29, blue: 0.83, alpha: 1)
        let theme = PluginTheme(
            background: .black,
            surface: .darkGray,
            text: .white,
            secondaryText: .gray,
            accent: .orange,
            monospacedFont: .monospacedSystemFont(ofSize: 11, weight: .regular),
            rowHeight: 16,
            isDark: true,
            semanticColors: [.fieldSurface: exact]
        )

        XCTAssertEqual(theme.color(.fieldSurface), exact)
        XCTAssertEqual(
            PluginThemeColorRole.allCases.count,
            30,
            "Adding a host palette role is an SDK decision, not a silent omission."
        )
    }

    /// V5 adds the bounded change-request summary and visibility-interest callback. A new host can
    /// still run a v3 pane plugin, while an older host's exact generation check refuses newer code
    /// before selector dispatch.
    func testTheAPIVersionCompatibilityWindowPreservesV3PanePlugins() {
        XCTAssertEqual(ThreadingPluginAPI.version, 5)
        XCTAssertEqual(ThreadingPluginAPI.minimumSupportedVersion, 3)
        XCTAssertFalse(ThreadingPluginAPI.supports(2))
        XCTAssertTrue(ThreadingPluginAPI.supports(3))
        XCTAssertTrue(ThreadingPluginAPI.supports(4))
        XCTAssertTrue(ThreadingPluginAPI.supports(5))
        XCTAssertFalse(ThreadingPluginAPI.supports(6))
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
