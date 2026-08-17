import AppKit
import XCTest
@testable import Threading
import ThreadingExtensionKit

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
        // The registry is the app's real registry, so it is set aside and put back. The stored
        // choice is read through `PreferenceStore` rather than `UserDefaults.standard`: hosted
        // tests are redirected there precisely so this suite cannot rewrite the developer's own
        // theme, and reaching past the seam would assert against a key the app no longer reads.
        preservedThemeID = PreferenceStore.shared.string(forKey: "appThemeID")
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
            PreferenceStore.shared.set(preservedThemeID, forKey: "appThemeID")
        } else {
            PreferenceStore.shared.removeObject(forKey: "appThemeID")
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
            .appendingPathComponent("ThreadingAppearanceTests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let manifest = ExtensionManifest(
            identifier: "com.example.pack",
            name: "Test Extension",
            version: "0.1.0",
            runtime: .native,
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

    // MARK: - The App-Icon Mark

    func testAThemeCarriesADeclaredMarkThroughInspection() throws {
        let root = try makeAppearancePackage(
            capabilities: [.themeProvider],
            themes: [.init(
                id: "storm", resource: "Resources/storm.json", iconMark: "Resources/storm.png"
            )],
            resources: [
                "Resources/storm.json": try JSONEncoder().encode(AppThemeStyles.newsprint),
                "Resources/storm.png": try markPNG(fillsBounds: false)
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = try ExtensionBundleInspector.inspect(at: root)
        let mark = try XCTUnwrap(bundle.themes.first?.iconMark, "the mark was dropped")
        XCTAssertNotNil(NSImage(data: mark), "the stored mark is not a decodable image")
    }

    /// The anti-impersonation gate. A package that ships the whole tile is refused outright
    /// rather than having its artwork quietly ignored, because a theme whose icon the host will
    /// not draw is a disagreement its author has to be told about.
    func testAMarkThatFillsItsBoundsIsRefused() throws {
        let root = try makeAppearancePackage(
            capabilities: [.themeProvider],
            themes: [.init(
                id: "storm", resource: "Resources/storm.json", iconMark: "Resources/storm.png"
            )],
            resources: [
                "Resources/storm.json": try JSONEncoder().encode(AppThemeStyles.newsprint),
                "Resources/storm.png": try markPNG(fillsBounds: true)
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: root)) { error in
            guard case ExtensionBundleError.themeResourceInvalid(_, let message) = error else {
                return XCTFail("expected a theme resource error, got \(error)")
            }
            XCTAssertTrue(
                message.contains("transparent"),
                "the refusal should say what shape is wanted, got: \(message)"
            )
        }
    }

    func testAMarkThatIsNotAnImageIsRefused() throws {
        let root = try makeAppearancePackage(
            capabilities: [.themeProvider],
            themes: [.init(
                id: "storm", resource: "Resources/storm.json", iconMark: "Resources/storm.png"
            )],
            resources: [
                "Resources/storm.json": try JSONEncoder().encode(AppThemeStyles.newsprint),
                // What a captive portal or an error page serves with a 200 and a .png suffix.
                "Resources/storm.png": Data("<html><body>Not found</body></html>".utf8)
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: root))
    }

    // MARK: - The Shipped Example

    /// `Examples/StormThemeExtension` is what an author copies to ship a theme with an icon, and
    /// it is the only example exercising `appearance.themes` at all.
    ///
    /// It cannot be inspected as a package — like every example here it ships source and no built
    /// `bin/`, so `ExtensionBundleInspector` would refuse it for a missing executable. What can be
    /// checked is everything that would actually be wrong: that the manifest points at files that
    /// exist, that the theme document decodes and passes the same validation a real contribution
    /// gets, and that the mark clears the same two gates `inspectThemeIconMark` applies. A broken
    /// example is worse than no example, because it is copied before it is read.
    func testTheShippedStormExampleIsValid() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Packages/ThreadingExtensionKit/Examples/StormThemeExtension"
            )

        let manifestData = try Data(
            contentsOf: root.appendingPathComponent("threading-extension.json")
        )
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: manifestData)
        XCTAssertNoThrow(try manifest.validate(), "the example manifest does not validate")

        let declaration = try XCTUnwrap(manifest.themes.first, "the example declares no theme")
        let markPath = try XCTUnwrap(
            declaration.iconMark, "the example is the icon-mark example and declares none"
        )

        let theme = try JSONDecoder().decode(
            AppTheme.self,
            from: Data(contentsOf: root.appendingPathComponent(declaration.resource))
        )
        XCTAssertNoThrow(
            try AppThemeEditing.validate(theme),
            "the example theme document would be refused"
        )

        let markData = try Data(contentsOf: root.appendingPathComponent(markPath))
        let normalized = try XCTUnwrap(
            ProjectIconStore.normalizedPNGData(from: markData, maxPixelSize: 1024),
            "the example mark does not survive the host's image gate"
        )
        let mark = try XCTUnwrap(NSImage(data: normalized))
        XCTAssertFalse(
            ProjectIconStore.fillsItsBounds(mark),
            "the example mark is a filled tile, which the host refuses"
        )
    }

    /// The seam between the loader and the icon: a registered contribution's mark comes back
    /// as an image, and an update that keeps the theme's identity is not served the old one.
    ///
    /// The cache is the whole risk here. A package updating its artwork without renaming its
    /// theme is the ordinary way new artwork arrives, and it is invisible to the theme-id
    /// comparison the registry already makes.
    func testTheRegistryServesAMarkAndDropsItWhenThePackageUpdates() throws {
        let theme = contributedTheme()
        let registry = ExtensionAppearanceRegistry.shared
        defer { registry.replace(contributions: []) }

        let first = try markPNG(fillsBounds: false)
        registry.replace(contributions: [
            .init(
                extensionIdentifier: "com.example.pack",
                extensionName: "Test Extension",
                themes: [theme],
                fontURLs: [],
                iconMarks: [theme.id: first]
            )
        ])
        let served = try XCTUnwrap(
            registry.iconMark(forThemeID: theme.id), "the registered mark was not served"
        )
        XCTAssertGreaterThan(served.size.width, 0)

        // Same theme id, different bytes — an update, not a new theme.
        let second = try markPNG(fillsBounds: false, inset: 8)
        registry.replace(contributions: [
            .init(
                extensionIdentifier: "com.example.pack",
                extensionName: "Test Extension",
                themes: [theme],
                fontURLs: [],
                iconMarks: [theme.id: second]
            )
        ])
        let updated = try XCTUnwrap(registry.iconMark(forThemeID: theme.id))
        XCTAssertFalse(
            updated === served, "the updated package was served its previous mark"
        )

        registry.replace(contributions: [])
        XCTAssertNil(
            registry.iconMark(forThemeID: theme.id),
            "the mark outlived the contribution that carried it"
        )
    }

    /// A 64² PNG: either fully opaque, or a small opaque square centred on transparency.
    private func markPNG(fillsBounds: Bool, inset: CGFloat = 20) throws -> Data {
        let side = 64
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill(using: .copy)
        NSColor.systemBlue.setFill()
        let ink = fillsBounds
            ? NSRect(x: 0, y: 0, width: side, height: side)
            : NSRect(
                x: inset, y: inset,
                width: CGFloat(side) - inset * 2, height: CGFloat(side) - inset * 2
            )
        ink.fill(using: .sourceOver)
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let raster = NSBitmapImageRep(data: tiff),
              let png = raster.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
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

    // MARK: - Live reload

    /// The half of live reload nothing else exercises: a contributed theme keeps its identity
    /// and changes its answers, and the active chrome follows. `current` is a value copy, so
    /// before the registry diffed *values* this repainted nothing until the next manual
    /// switch — the bug an extension chrome that follows the weather would sit on all day.
    func testAValueChangeInTheActiveContributedThemeReappliesItLive() throws {
        let registry = ExtensionAppearanceRegistry.shared
        defer {
            registry.replace(contributions: [])
            AppThemeLibrary.apply(.system)
        }

        let original = contributedTheme()
        registry.replace(contributions: [contribution(themes: [original])])
        AppThemeLibrary.apply(original)
        XCTAssertEqual(AppThemeLibrary.current, original)

        let kind = try XCTUnwrap(original.availableVariants.first)
        let variant = try XCTUnwrap(original.variant(kind))
        var roles = variant.roles
        roles[.accent] = NSColor(hex: "#AA77FF")
        var variants = original.variants
        variants[kind] = AppTheme.Variant(
            roles: roles,
            terminalPalette: variant.terminalPalette,
            material: variant.material,
            sidebar: variant.sidebar
        )
        let edited = AppTheme(
            id: original.id,
            name: original.name,
            mode: original.mode,
            summary: original.summary,
            variants: variants
        )

        registry.replace(contributions: [contribution(themes: [edited])])

        XCTAssertEqual(
            AppThemeLibrary.current.variant(kind)?.roles[.accent]?.hexString,
            "#AA77FF",
            "the active theme kept the old value after its contribution changed"
        )
    }

    /// The watcher is deliberately dumb — any write under the package, one coalesced report
    /// after the quiet — so this asserts exactly that: a burst of writes lands as one change.
    func testTheThemeWatcherCoalescesABurstOfWritesIntoOneReport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingThemeWatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reported = expectation(description: "one coalesced change")
        var reports = 0
        let watcher = ExtensionThemeWatcher(root: root) {
            reports += 1
            if reports == 1 { reported.fulfill() }
        }
        watcher.start()
        defer { watcher.stop() }

        for index in 0..<3 {
            try Data("{\"edit\": \(index)}".utf8).write(
                to: root.appendingPathComponent("storm.json")
            )
        }

        wait(for: [reported], timeout: 5)
        // The trailing edge already fired; a second report would have to arrive inside the
        // same coalesce window it just closed.
        RunLoop.main.run(until: Date().addingTimeInterval(ExtensionThemeWatchDefaults.coalesce))
        XCTAssertEqual(reports, 1, "three writes in one burst reported more than once")
    }

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
    /// taken again; the extension disabling falls back to Threading *as the recorded choice*, so a
    /// later re-enable does not snap the theme back over whatever was chosen since.
    func testTheStoredChoiceHealsOnEnableAndFallsBackHonestlyOnDisable() {
        let theme = contributedTheme()
        PreferenceStore.shared.set(theme.id.rawValue, forKey: "appThemeID")
        AppThemeLibrary.restore()
        XCTAssertEqual(
            AppThemeLibrary.current.id, AppThemeStyles.threading.id,
            "an unresolvable stored choice falls back to the product default at launch"
        )

        ExtensionAppearanceRegistry.shared.replace(
            contributions: [contribution(themes: [theme])]
        )
        XCTAssertEqual(
            AppThemeLibrary.current.id, theme.id,
            "the standing choice is taken again the moment it resolves"
        )

        ExtensionAppearanceRegistry.shared.replace(contributions: [])
        XCTAssertEqual(AppThemeLibrary.current.id, AppThemeStyles.threading.id)
        XCTAssertEqual(
            PreferenceStore.shared.string(forKey: "appThemeID"), AppThemeStyles.threading.id.rawValue,
            "the fallback is recorded, so re-enabling does not snap the theme back"
        )

        ExtensionAppearanceRegistry.shared.replace(
            contributions: [contribution(themes: [theme])]
        )
        XCTAssertEqual(
            AppThemeLibrary.current.id, AppThemeStyles.threading.id,
            "Threading stays: it is the recorded choice now, not a fallback"
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
        let bundle = ThreadingExtensionBundle(
            rootURL: root,
            executableURL: root.appendingPathComponent("bin/extension"),
            sourceURL: nil,
            manifest: ExtensionManifest(
                identifier: "com.example.pack",
                name: "Test Extension",
                version: "0.1.0",
                runtime: .native,
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
