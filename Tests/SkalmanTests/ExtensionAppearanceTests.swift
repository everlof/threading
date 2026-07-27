import AppKit
import XCTest
@testable import Skalman
import SkalmanExtensionKit

/// Extension-contributed appearance: themes and fonts as package data.
///
/// The contract under test is data-plane end to end — a theme document is read, namespaced and
/// validated at inspection, held in a registry derived from enablement, and merged into
/// `AppThemeLibrary.all` as a third tier; a font file is parsed at inspection and registered
/// process-scoped on enable. No extension code runs anywhere in these paths, which is what the
/// inspector-only fixtures here demonstrate.
@MainActor
final class ExtensionAppearanceTests: XCTestCase {

    private var preservedThemeID: String?
    private var preservedActivate: ((URL) -> Bool)?
    private var preservedDeactivate: ((URL) -> Void)?

    override func setUp() {
        super.setUp()
        // The suite runs hosted in the app: `appThemeID` is the developer's real choice and the
        // registry is the app's real registry. Both are set aside and put back.
        preservedThemeID = UserDefaults.standard.string(forKey: "appThemeID")
        preservedActivate = ExtensionAppearanceRegistry.shared.activateFont
        preservedDeactivate = ExtensionAppearanceRegistry.shared.deactivateFont
        ExtensionAppearanceRegistry.shared.activateFont = { _ in true }
        ExtensionAppearanceRegistry.shared.deactivateFont = { _ in }
    }

    override func tearDown() {
        ExtensionAppearanceRegistry.shared.replace(contributions: [])
        if let preservedActivate { ExtensionAppearanceRegistry.shared.activateFont = preservedActivate }
        if let preservedDeactivate { ExtensionAppearanceRegistry.shared.deactivateFont = preservedDeactivate }
        if let preservedThemeID {
            UserDefaults.standard.set(preservedThemeID, forKey: "appThemeID")
        } else {
            UserDefaults.standard.removeObject(forKey: "appThemeID")
        }
        AppThemeLibrary.restore()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A contributed theme as the registry would hold it: a stock theme's variants under a
    /// namespaced id, exactly what the inspector produces.
    private func contributedTheme(id: String = "ext.com.example.pack.storm") -> AppTheme {
        let base = AppThemeStyles.newsprint
        return AppTheme(
            id: AppThemeID(id),
            name: "Storm",
            mode: base.mode,
            summary: "Contributed for tests",
            variants: base.variants
        )
    }

    private func contribution(
        themes: [AppTheme],
        fontURLs: [URL] = [],
        extensionName: String = "Test Extension"
    ) -> ExtensionAppearanceRegistry.Contribution {
        .init(
            extensionIdentifier: "com.example.pack",
            extensionName: extensionName,
            themes: themes,
            fontURLs: fontURLs
        )
    }

    /// Writes an inspectable package: manifest, executable, and any theme/font resources.
    private func makeAppearancePackage(
        capabilities: Set<ExtensionCapability>,
        themes: [ExtensionThemeContribution] = [],
        fonts: [ExtensionFontContribution] = [],
        resources: [String: Data] = [:]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkalmanAppearanceTests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let manifest = ExtensionManifest(
            identifier: "com.example.pack",
            name: "Test Extension",
            version: "0.1.0",
            executable: "bin/extension",
            capabilities: capabilities,
            themes: themes,
            fonts: fonts
        )
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )
        let executable = bin.appendingPathComponent("extension")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        for (path, data) in resources {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        return root
    }

    /// A real font file that ships with macOS, for parse-positive fixtures. Inspection only
    /// parses — registration semantics were probed separately and are stubbed here.
    private func systemFontData() throws -> Data {
        let candidates = [
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/System/Library/Fonts/Supplemental/Verdana.ttf",
            "/System/Library/Fonts/Supplemental/Courier New.ttf"
        ]
        for candidate in candidates {
            if let data = FileManager.default.contents(atPath: candidate) { return data }
        }
        throw XCTSkip("no known system font file present on this machine")
    }

    // MARK: - Inspection

    func testInspectorReadsNamespacesAndValidatesAContributedTheme() throws {
        let document = try JSONEncoder().encode(AppThemeStyles.newsprint)
        let root = try makeAppearancePackage(
            capabilities: [.themeProvider],
            themes: [.init(id: "storm", resource: "Resources/storm.json")],
            resources: ["Resources/storm.json": document]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = try ExtensionBundleInspector.inspect(at: root)
        XCTAssertEqual(bundle.themes.count, 1)
        let theme = try XCTUnwrap(bundle.themes.first?.theme)
        XCTAssertEqual(
            theme.id.rawValue, "ext.com.example.pack.storm",
            "the id is the host's namespace, not the document's own"
        )
        XCTAssertEqual(theme.name, AppThemeStyles.newsprint.name)
        XCTAssertEqual(theme.variants, AppThemeStyles.newsprint.variants)
    }

    func testAManifestDeclaringThemesWithoutTheCapabilityIsRefused() throws {
        let document = try JSONEncoder().encode(AppThemeStyles.newsprint)
        let root = try makeAppearancePackage(
            capabilities: [],
            themes: [.init(id: "storm", resource: "Resources/storm.json")],
            resources: ["Resources/storm.json": document]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: root)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(
                message.contains("appearance.themes"),
                "the refusal must teach the capability name — got: \(message)"
            )
        }
    }

    func testAThemeDocumentFailingTheEditingGatesIsRefusedAtInspection() throws {
        // Structurally decodable, semantically hollow: no variants survives decoding and must
        // be stopped by the same `AppThemeEditing.validate` a custom theme faces.
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AppThemeStyles.newsprint)
        ) as? [String: Any])
        object["variants"] = [String: Any]()
        let hollow = try JSONSerialization.data(withJSONObject: object)

        let root = try makeAppearancePackage(
            capabilities: [.themeProvider],
            themes: [.init(id: "storm", resource: "Resources/storm.json")],
            resources: ["Resources/storm.json": hollow]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: root)) { error in
            guard case .themeResourceInvalid(let path, _) = error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, "Resources/storm.json")
        }
    }

    func testAThemeResourceSymlinkEscapingThePackageIsRefused() throws {
        let root = try makeAppearancePackage(
            capabilities: [.themeProvider],
            themes: [.init(id: "storm", resource: "Resources/storm.json")]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: resources.appendingPathComponent("storm.json"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )

        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: root)) { error in
            guard case .themeResourceInvalid = error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testAFontFileMustParseAndAParseableOneReportsItsFamilies() throws {
        let garbage = Data("not a font at all".utf8)
        let bad = try makeAppearancePackage(
            capabilities: [.fontProvider],
            fonts: [.init(resource: "Resources/fake.ttf")],
            resources: ["Resources/fake.ttf": garbage]
        )
        defer { try? FileManager.default.removeItem(at: bad) }
        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: bad)) { error in
            guard case .fontResourceInvalid(let path, _) = error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, "Resources/fake.ttf")
        }

        let good = try makeAppearancePackage(
            capabilities: [.fontProvider],
            fonts: [.init(resource: "Resources/real.ttf")],
            resources: ["Resources/real.ttf": try systemFontData()]
        )
        defer { try? FileManager.default.removeItem(at: good) }
        let bundle = try ExtensionBundleInspector.inspect(at: good)
        XCTAssertEqual(bundle.fonts.count, 1)
        XCTAssertFalse(
            try XCTUnwrap(bundle.fonts.first).familyNames.isEmpty,
            "the family names come from the file, and the disclosure depends on them"
        )
    }

    // MARK: - The Library's Third Tier

    func testAContributedThemeJoinsTheLibraryAndLeavesWithItsExtension() {
        let theme = contributedTheme()
        ExtensionAppearanceRegistry.shared.replace(
            contributions: [contribution(themes: [theme])]
        )
        XCTAssertTrue(AppThemeLibrary.all.contains { $0.id == theme.id })
        XCTAssertTrue(AppThemeLibrary.isContributed(theme))
        XCTAssertFalse(AppThemeLibrary.isCustom(theme))
        XCTAssertFalse(AppThemeLibrary.isStock(theme))
        XCTAssertEqual(AppThemeLibrary.contributorName(of: theme), "Test Extension")

        ExtensionAppearanceRegistry.shared.replace(contributions: [])
        XCTAssertFalse(AppThemeLibrary.all.contains { $0.id == theme.id })
    }

    func testAContributedThemeCannotBeEditedButNamesItsRemedy() {
        let theme = contributedTheme()
        ExtensionAppearanceRegistry.shared.replace(
            contributions: [contribution(themes: [theme])]
        )
        XCTAssertThrowsError(try AppThemeLibrary.update(theme)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("extension"), "got: \(message)")
        }
    }

    /// The whole selection lifecycle in one arc: the stored choice cannot resolve at launch and
    /// falls back without being forgotten; the extension enabling makes it resolvable and it is
    /// taken again; the extension disabling falls back to System *as the recorded choice*, so a
    /// later re-enable does not snap the theme back over whatever was chosen since.
    func testTheStoredChoiceHealsOnEnableAndFallsBackHonestlyOnDisable() {
        let theme = contributedTheme()
        UserDefaults.standard.set(theme.id.rawValue, forKey: "appThemeID")
        AppThemeLibrary.restore()
        XCTAssertEqual(
            AppThemeLibrary.current.id, AppThemeID("system"),
            "an unresolvable stored choice falls back to System at launch"
        )

        ExtensionAppearanceRegistry.shared.replace(
            contributions: [contribution(themes: [theme])]
        )
        XCTAssertEqual(
            AppThemeLibrary.current.id, theme.id,
            "the standing choice is taken again the moment it resolves"
        )

        ExtensionAppearanceRegistry.shared.replace(contributions: [])
        XCTAssertEqual(AppThemeLibrary.current.id, AppThemeID("system"))
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "appThemeID"), "system",
            "the fallback is recorded, so re-enabling does not snap the theme back"
        )

        ExtensionAppearanceRegistry.shared.replace(
            contributions: [contribution(themes: [theme])]
        )
        XCTAssertEqual(
            AppThemeLibrary.current.id, AppThemeID("system"),
            "System stays: it is the recorded choice now, not a fallback"
        )
    }

    // MARK: - Fonts Bookkeeping

    func testFontRegistrationFollowsEnablementAndSkipsFailures() {
        var activated: [URL] = []
        var deactivated: [URL] = []
        let good = URL(fileURLWithPath: "/tmp/good.ttf")
        let broken = URL(fileURLWithPath: "/tmp/broken.ttf")
        ExtensionAppearanceRegistry.shared.activateFont = { url in
            activated.append(url)
            return url != broken
        }
        ExtensionAppearanceRegistry.shared.deactivateFont = { deactivated.append($0) }

        ExtensionAppearanceRegistry.shared.replace(
            contributions: [contribution(themes: [], fontURLs: [good, broken])]
        )
        XCTAssertEqual(Set(activated), [good, broken])
        XCTAssertEqual(
            ExtensionAppearanceRegistry.shared.activeFontURLs, [good],
            "a failed registration must not be bookkept as active"
        )

        ExtensionAppearanceRegistry.shared.replace(contributions: [])
        XCTAssertEqual(deactivated, [good], "only what was activated is unregistered")
        XCTAssertTrue(ExtensionAppearanceRegistry.shared.activeFontURLs.isEmpty)
    }

    // MARK: - Surfaces That Report Origin

    func testMCPOriginDistinguishesTheThreeTiers() {
        let theme = contributedTheme()
        ExtensionAppearanceRegistry.shared.replace(
            contributions: [contribution(themes: [theme])]
        )
        XCTAssertEqual(AgentToolCoordinator.origin(of: .system), "built-in")
        XCTAssertEqual(AgentToolCoordinator.origin(of: theme), "extension “Test Extension”")
    }

    func testTheInstallProposalDisclosesThemesAndFontFamilies() throws {
        let root = FileManager.default.temporaryDirectory
        let bundle = SkalmanExtensionBundle(
            rootURL: root,
            executableURL: root.appendingPathComponent("bin/extension"),
            sourceURL: nil,
            manifest: ExtensionManifest(
                identifier: "com.example.pack",
                name: "Test Extension",
                version: "0.1.0",
                executable: "bin/extension",
                capabilities: [.themeProvider, .fontProvider],
                themes: [.init(id: "storm", resource: "Resources/storm.json")],
                fonts: [.init(resource: "Resources/rain.ttf")]
            ),
            themes: [.init(contributionID: "storm", theme: contributedTheme())],
            fonts: [.init(
                url: root.appendingPathComponent("Resources/rain.ttf"),
                familyNames: ["Rain Mono"]
            )]
        )
        let message = ExtensionInstallProposal(bundle: bundle).message
        XCTAssertTrue(message.contains("Storm"), "the theme is named before installation")
        XCTAssertTrue(message.contains("Rain Mono"), "the font family is named before installation")
        XCTAssertTrue(
            message.contains("nothing applies one automatically"),
            "the disclosure states that installation changes no appearance by itself"
        )
    }
}
