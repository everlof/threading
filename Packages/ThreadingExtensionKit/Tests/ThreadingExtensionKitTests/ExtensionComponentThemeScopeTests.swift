import Foundation
import XCTest
@testable import ThreadingExtensionKit

/// A theme-shipping extension may scope its decorations to its own themes. The field is
/// additive: an unscoped patch or manifest must keep its previous wire fields, an older decoder must
/// read a scoped one, and a scope that could never be satisfied is refused before it reaches
/// a host.
final class ExtensionComponentThemeScopeTests: XCTestCase {
    /// The patch's wire shape before `themeScope` existed, synthesized exactly as it was.
    private struct LegacyPatch: Codable, Equatable {
        let id: String
        let target: ExtensionComponentTarget
        let properties: [ExtensionComponentPropertyPatch]
        let slots: [ExtensionComponentSlotPatch]
        let replacement: ExtensionNode?
        let hook: ExtensionNode?
    }

    private let backdrop = ExtensionNode.overlay(
        base: .image(
            .extensionResource("Resources/dunes.png"),
            role: .backdrop,
            accessibilityLabel: nil
        ),
        overlay: .proceed
    )

    func testAnUnscopedPatchKeepsTheLegacyWireShape() throws {
        let patch = ExtensionComponentPatch(
            id: "sidebar-dunes",
            target: .sidebarBackdrop(),
            hook: backdrop
        )
        let legacy = LegacyPatch(
            id: patch.id,
            target: patch.target,
            properties: [],
            slots: [],
            replacement: nil,
            hook: backdrop
        )

        // JSON key order is not part of the wire contract; compare canonical encodings.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encodedPatch = try encoder.encode(patch)
        let encodedLegacy = try encoder.encode(legacy)

        XCTAssertEqual(patch.themeScope, .always)
        XCTAssertEqual(encodedPatch, encodedLegacy)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedPatch) as? [String: Any]
        )
        XCTAssertNil(object["themeScope"], "`always` is written by omission")
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionComponentPatch.self,
                from: encodedLegacy
            ),
            patch,
            "a publication from an older SDK decodes as `always`"
        )
    }

    func testAScopedPatchRoundTripsAndAnOlderDecoderStillReadsIt() throws {
        let patch = ExtensionComponentPatch(
            id: "sidebar-dunes",
            target: .sidebarBackdrop(),
            hook: backdrop,
            themeScope: .ownThemes
        )
        let data = try JSONEncoder().encode(patch)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["themeScope"] as? String, "ownThemes")
        XCTAssertEqual(try JSONDecoder().decode(ExtensionComponentPatch.self, from: data), patch)
        // A host that predates the field ignores the key rather than refusing the publication;
        // it draws the decoration under every theme, which is what it always did.
        let older = try JSONDecoder().decode(LegacyPatch.self, from: data)
        XCTAssertEqual(older.hook, backdrop)

        let explicitAlways = Data(
            #"{"id":"a","target":{"component":"sidebar.backdrop","contractVersion":1},"properties":[],"slots":[],"themeScope":"always"}"#
                .utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ExtensionComponentPatch.self, from: explicitAlways),
            ExtensionComponentPatch(id: "a", target: .sidebarBackdrop())
        )
    }

    func testAnUnknownScopeIsRefusedRatherThanWidened() {
        let unknown = Data(
            #"{"id":"a","target":{"component":"sidebar.backdrop","contractVersion":1},"properties":[],"slots":[],"themeScope":"sometimes"}"#
                .utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(ExtensionComponentPatch.self, from: unknown))
    }

    func testWithThemeScopeChangesOnlyTheScope() {
        let patch = ExtensionComponentPatch(
            id: "row",
            target: .init(component: "sidebar.session-row", contractVersion: 1, entityID: "s"),
            slots: [.init(slot: "after-title", children: [.status("Passed", role: .positive)])],
            hook: backdrop
        )
        let scoped = patch.withThemeScope(.ownThemes)

        XCTAssertEqual(scoped.themeScope, .ownThemes)
        XCTAssertEqual(scoped.withThemeScope(.always), patch)
    }

    func testPublicationRefusesOwnThemesFromAnExtensionWithoutATheme() throws {
        let scoped = ExtensionComponentPatch(
            id: "sidebar-dunes",
            target: .sidebarBackdrop(),
            hook: backdrop,
            themeScope: .ownThemes
        )
        let unscoped = ExtensionComponentPatch(
            id: "display-dunes",
            target: .displayBackdrop(),
            hook: backdrop
        )
        let publication = ExtensionComponentPatchPublication(patches: [unscoped, scoped])

        XCTAssertThrowsError(try publication.validate(for: manifest(themes: false))) { error in
            let issues = (error as? ExtensionValidationError)?.issues ?? []
            XCTAssertEqual(issues.map(\.path), ["patches[1].themeScope"])
            XCTAssertTrue(issues.first?.message.contains("contributes none") == true)
        }
        XCTAssertNoThrow(try publication.validate(for: manifest(themes: true)))
        XCTAssertNoThrow(
            try ExtensionComponentPatchPublication(patches: [unscoped])
                .validate(for: manifest(themes: false)),
            "`always` needs no theme"
        )
    }

    func testAManifestScopeIsOmittedByDefaultAndRefusedWhenItCouldNeverApply() throws {
        let plain = manifest(themes: true)
        let plainObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
        )
        XCTAssertNil(plainObject["componentThemeScope"])
        XCTAssertEqual(plain.componentThemeScope, .always)

        let bound = manifest(themes: true, scope: .ownThemes)
        XCTAssertNoThrow(try bound.validate())
        let data = try JSONEncoder().encode(bound)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["componentThemeScope"] as? String, "ownThemes")
        XCTAssertEqual(try JSONDecoder().decode(ExtensionManifest.self, from: data), bound)

        XCTAssertThrowsError(try manifest(themes: false, scope: .ownThemes).validate()) { error in
            let issues = (error as? ExtensionValidationError)?.issues ?? []
            XCTAssertEqual(issues.map(\.path), ["componentThemeScope"])
        }
        XCTAssertThrowsError(
            try manifest(themes: true, scope: .ownThemes, components: false).validate()
        ) { error in
            let issues = (error as? ExtensionValidationError)?.issues ?? []
            XCTAssertEqual(issues.map(\.path), ["componentThemeScope"])
            XCTAssertTrue(issues.first?.message.contains("ui.components") == true)
        }

        var explicit = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(plain)
        ) as? [String: Any])
        explicit["componentThemeScope"] = "always"
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionManifest.self,
                from: JSONSerialization.data(withJSONObject: explicit)
            ),
            plain,
            "an explicit `always` is the default, not a different manifest"
        )
    }

    func testEveryPatchSchemaAdmitsTheScope() throws {
        let schema = ThreadingComponentCatalog.patchSchema(for: ThreadingComponentCatalog.sidebarBackdrop)
        guard case .object(let root) = schema,
              case .object(let properties)? = root["properties"],
              case .object(let scope)? = properties["themeScope"] else {
            return XCTFail("themeScope is missing from the generated patch schema")
        }
        XCTAssertEqual(scope["enum"], .array([.string("always"), .string("ownThemes")]))
        XCTAssertEqual(scope["default"], .string("always"))
    }

    private func manifest(
        themes: Bool,
        scope: ExtensionComponentThemeScope = .always,
        components: Bool = true
    ) -> ExtensionManifest {
        var capabilities: Set<ExtensionCapability> = []
        if components { capabilities.insert(.componentCustomization) }
        if themes { capabilities.insert(.themeProvider) }
        return ExtensionManifest(
            identifier: "com.example.storm",
            name: "Storm",
            version: "1.0.0",
            runtime: .webAssembly,
            executable: "bin/storm.wasm",
            capabilities: capabilities,
            themes: themes ? [.init(id: "storm", resource: "themes/storm.json")] : [],
            componentThemeScope: scope
        )
    }
}
