import AppKit
import LabelMorph
@testable import Threading
import XCTest

/// A theme's name morph (`ThemeTitleMorph`): what it says on the wire, what validation holds it
/// to, how the label resolves it against the person's Motion setting, and the tool loop.
@MainActor
final class ThemeTitleMorphTests: XCTestCase {

    private let katakana = "ｱｲｳｴｵ"
    private var previousTheme: AppTheme?
    private var previousSettings: DesignSettingsReading?

    override func setUp() async throws {
        try await super.setUp()
        previousTheme = AppThemePalette.current
        previousSettings = DesignSettings.current
        DesignSettings.current = StubDesignSettings()
    }

    override func tearDown() async throws {
        if let previousTheme { AppThemePalette.set(previousTheme) }
        if let previousSettings { DesignSettings.current = previousSettings }
        try await super.tearDown()
    }

    // MARK: - Wire form

    func testTheMorphRoundTripsAndAnUnknownStyleDropsOnlyTheBlock() throws {
        let morph = ThemeTitleMorph(style: .scramble, characters: katakana)
        let variant = try XCTUnwrap(AppThemeStyles.threading.variant(.dark)).replacingTitleMorph(morph)
        let data = try JSONEncoder().encode(variant)
        XCTAssertEqual(try JSONDecoder().decode(AppTheme.Variant.self, from: data).titleMorph, morph)

        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        document["titleMorph"] = ["style": "warpDrive"]
        let future = try JSONSerialization.data(withJSONObject: document)
        let decoded = try JSONDecoder().decode(AppTheme.Variant.self, from: future)
        XCTAssertNil(decoded.titleMorph, "a style this build cannot draw is dropped")
        XCTAssertEqual(decoded.material, variant.material, "the theme around it is kept")
        XCTAssertEqual(Set(decoded.roles.keys), Set(variant.roles.keys))

        XCTAssertNil(try XCTUnwrap(AppThemeStyles.threading.variant(.dark)).titleMorph)
    }

    func testTheMorphIsGated() throws {
        let base = try XCTUnwrap(AppThemeStyles.threading.variant(.dark))
        func assertRefused(_ morph: ThemeTitleMorph, mentioning fragment: String) {
            let theme = AppTheme(
                id: AppThemeID("custom-morph-\(UUID().uuidString)"),
                name: "Morph",
                mode: .dark,
                summary: nil,
                variants: [.dark: base.replacingTitleMorph(morph)]
            )
            XCTAssertThrowsError(try AppThemeEditing.validate(theme)) { error in
                XCTAssertTrue("\(error)".contains(fragment), "\(error)")
            }
        }
        assertRefused(ThemeTitleMorph(style: .automatic), mentioning: "automatic")
        assertRefused(ThemeTitleMorph(style: .flip, characters: "AB"), mentioning: "scramble")
        assertRefused(ThemeTitleMorph(style: .scramble, characters: "   "), mentioning: "characters")
        assertRefused(
            ThemeTitleMorph(style: .scramble, characters: String(repeating: "ｱ", count: 97)),
            mentioning: "characters"
        )
        XCTAssertEqual(ThemeTitleMorph(style: .scramble, characters: "ｱ ｲ\n").scrambleCharacters, ["ｱ", "ｲ"])
        XCTAssertNil(ThemeTitleMorph(style: .flip).scrambleCharacters)
    }

    // MARK: - Resolution

    func testThemesChoicePlaysTheThemesScrambleFromItsAlphabet() throws {
        AppThemePalette.set(try theme(ThemeTitleMorph(style: .scramble, characters: katakana)))
        XCTAssertEqual(DesignSettings.current.chatNameMorphStyle, .automatic, "the default")
        let label = MorphingTitleLabel()
        label.morphStyleOverride = .automatic
        let scramble = try XCTUnwrap(label.activeEffect as? ScrambleEffect)
        XCTAssertEqual(scramble.characters, Array(katakana))
    }

    func testAnExplicitStyleWinsButAScrambleStillUsesTheThemesAlphabet() throws {
        AppThemePalette.set(try theme(ThemeTitleMorph(style: .scramble, characters: katakana)))
        let label = MorphingTitleLabel()
        label.morphStyleOverride = .crossfade
        XCTAssertFalse(label.activeEffect is ScrambleEffect, "the person's own style wins")

        label.morphStyleOverride = .scramble
        XCTAssertEqual((label.activeEffect as? ScrambleEffect)?.characters, Array(katakana))

        AppThemePalette.set(AppTheme.system)
        label.morphStyleOverride = .scramble
        XCTAssertNotEqual(
            (label.activeEffect as? ScrambleEffect)?.characters, Array(katakana),
            "without the theme a scramble decodes from its own alphabet"
        )
    }

    func testThemesChoiceWithoutAThemedMorphIsTheAppsOwn() throws {
        AppThemePalette.set(AppTheme.system)
        let label = MorphingTitleLabel()
        label.morphStyleOverride = .automatic
        XCTAssertNotNil(label.activeEffect)
        XCTAssertFalse(label.activeEffect is ScrambleEffect)
        XCTAssertEqual(MotionPreferencesDefaults.chatNameMorphStyle, .automatic)
        XCTAssertEqual(ChatNameMorphStyle.allCases.first, .automatic, "listed first in Motion")
    }

    func testTheMorphCountsAsCharacter() throws {
        let base = try XCTUnwrap(AppThemeStyles.threading.variant(.dark))
        let morphed = base.replacingTitleMorph(ThemeTitleMorph(style: .flip))
        XCTAssertFalse(AppThemeLayer.character.isUnchanged(from: base, to: morphed))
    }

    // MARK: - Tools

    func testAnAgentCanGiveNamesAMorphAndTakeItBack() async throws {
        let name = "Morph \(UUID().uuidString)"
        let created = await coordinator().createAppTheme(CreateAppThemeArguments(
            name: name,
            baseID: AppThemeStyles.threading.id.rawValue,
            appearance: "dark",
            mode: nil,
            summary: nil,
            variants: ["dark": AppThemeVariantArguments(
                titleMorph: AppThemeTitleMorphArguments(style: "scramble", characters: katakana)
            )],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        ))
        XCTAssertFalse(created.isError, created.text)
        let stored = try XCTUnwrap(AppThemeLibrary.all.first { $0.name == name })
        defer {
            if let latest = AppThemeLibrary.theme(withID: stored.id) {
                _ = AppThemeLibrary.delete(latest)
            }
        }
        XCTAssertEqual(stored.variant(.dark)?.titleMorph, ThemeTitleMorph(style: .scramble, characters: katakana))

        let get = coordinator().getAppTheme(AppThemeReferenceArguments(themeID: stored.id.rawValue))
        XCTAssertTrue(get.text.contains("\"title_morph\""), get.text)

        let switched = await coordinator().updateAppTheme(update(stored, AppThemeVariantArguments(
            titleMorph: AppThemeTitleMorphArguments(style: "flip")
        )))
        XCTAssertFalse(switched.isError, switched.text)
        XCTAssertEqual(
            AppThemeLibrary.theme(withID: stored.id)?.variant(.dark)?.titleMorph,
            ThemeTitleMorph(style: .flip),
            "a style away from scramble drops the alphabet it no longer uses"
        )

        let refused = await coordinator().updateAppTheme(update(stored, AppThemeVariantArguments(
            titleMorph: AppThemeTitleMorphArguments(style: "automatic")
        )))
        XCTAssertTrue(refused.isError)

        let removed = await coordinator().updateAppTheme(update(stored, AppThemeVariantArguments(
            removeTitleMorph: true
        )))
        XCTAssertFalse(removed.isError, removed.text)
        XCTAssertNil(AppThemeLibrary.theme(withID: stored.id)?.variant(.dark)?.titleMorph)
    }

    func testTheVariantSchemaDescribesTheMorph() throws {
        let tool = try XCTUnwrap(MCPTools.definitions.first { $0.name == MCPTools.createAppTheme })
        let schema = String(describing: tool.inputSchema)
        XCTAssertTrue(schema.contains("title_morph"))
        XCTAssertTrue(schema.contains("remove_title_morph"))
    }

    // MARK: - Helpers

    private func theme(_ morph: ThemeTitleMorph) throws -> AppTheme {
        AppTheme(
            id: AppThemeID("custom-morph-\(UUID().uuidString)"),
            name: "Morph",
            mode: .dark,
            summary: nil,
            variants: [.dark: try XCTUnwrap(AppThemeStyles.threading.variant(.dark)).replacingTitleMorph(morph)]
        )
    }

    private func update(_ theme: AppTheme, _ variant: AppThemeVariantArguments) -> UpdateAppThemeArguments {
        UpdateAppThemeArguments(
            themeID: theme.id.rawValue,
            name: nil,
            appearance: nil,
            mode: nil,
            summary: nil,
            variants: ["dark": variant],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        )
    }

    private func coordinator() -> AgentToolCoordinator {
        AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
    }
}
