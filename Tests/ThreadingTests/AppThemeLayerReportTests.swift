import AppKit
import XCTest
@testable import Threading

/// The layer report an agent reads after every create and update.
///
/// The report is the agent path's answer to "it only changed the colours": no gate refuses a
/// recolour, so the result has to say plainly when that is all a theme is, and whose shape and
/// frame a recoloured period theme is really wearing.
@MainActor
final class AppThemeLayerReportTests: XCTestCase {

    // MARK: - States

    func testAColoursOnlyThemeOverSystemSaysItIsARecolour() {
        let theme = custom(variant: AppTheme.Variant(
            roles: [.accent: .systemRed],
            terminalPalette: .basic,
            material: .system
        ))
        let report = AppThemeLayerReport(
            theme: theme,
            startingFrom: .system,
            origin: .base(name: AppTheme.system.name)
        )

        XCTAssertEqual(report.states, [
            .palette: .changed, .material: .absent, .chrome: .absent, .character: .absent
        ])
        XCTAssertTrue(report.text.contains("Colours only"), report.text)
        XCTAssertTrue(report.text.contains("chrome (the theme's own window frame)"), report.text)
        XCTAssertTrue(report.text.contains("update_app_theme"), report.text)
    }

    func testRecolouringAPeriodStyleNamesWhoseFrameItWears() throws {
        let base = AppThemeStyles.win98
        let original = try XCTUnwrap(base.variant(.light))
        let theme = custom(variant: original.replacing(roles: [.accent: .systemGreen]))
        let report = AppThemeLayerReport(
            theme: theme,
            startingFrom: base,
            origin: .base(name: base.name)
        )

        XCTAssertEqual(report.states[.palette], .changed)
        XCTAssertEqual(report.states[.material], .kept)
        XCTAssertEqual(report.states[.chrome], .kept)
        XCTAssertTrue(report.text.contains("chrome: from \(base.name)"), report.text)
        XCTAssertTrue(report.text.contains("Only the colours are new"), report.text)
        XCTAssertTrue(report.text.contains("\(base.name)'s"), report.text)
        XCTAssertFalse(report.text.contains("Colours only"), "the frame is stated, just inherited")
    }

    func testAWholeWorldReportsAllFourLayers() throws {
        let base = AppThemeStyles.win98
        let original = try XCTUnwrap(base.variant(.light))
        let dressed = original
            .replacing(roles: [.accent: .systemBlue])
            .replacingCharacter(
                sprites: original.sprites,
                moments: original.moments,
                words: ThemeWords(working: ["Defragmenting…"])
            )
        let report = AppThemeLayerReport(
            theme: custom(variant: dressed),
            startingFrom: base,
            origin: .base(name: base.name)
        )

        XCTAssertEqual(report.states[.character], .changed)
        XCTAssertTrue(report.text.contains("All four layers are stated."), report.text)
        XCTAssertFalse(report.text.contains("Not stated"), report.text)
        XCTAssertFalse(report.text.contains("Only the colours are new"), report.text)
    }

    func testAPartialThemeNamesOnlyTheMissingLayers() throws {
        let base = AppThemeStyles.swissMinimalist
        let original = try XCTUnwrap(base.availableVariants.first.flatMap { base.variant($0) })
        let report = AppThemeLayerReport(
            theme: custom(variant: original.replacingChrome(nil)),
            startingFrom: base,
            origin: .previous
        )

        XCTAssertEqual(report.states[.material], .kept)
        XCTAssertEqual(report.states[.chrome], .absent)
        XCTAssertTrue(report.text.contains("Not stated: chrome"), report.text)
        XCTAssertFalse(report.text.contains("material (shape"), "material is stated")
    }

    func testAnUpdateSaysKeptRatherThanNamingABase() throws {
        let base = AppThemeStyles.win98
        let original = try XCTUnwrap(base.variant(.light))
        let report = AppThemeLayerReport(
            theme: custom(variant: original.replacing(roles: [.accent: .systemPink])),
            startingFrom: custom(variant: original),
            origin: .previous
        )

        XCTAssertTrue(report.text.contains("chrome: kept"), report.text)
        XCTAssertFalse(
            report.text.contains("Only the colours are new"),
            "an update that adjusts a colour is ordinary, not a recolour passing as a theme"
        )
    }

    func testRemovingALayerReportsItAbsent() throws {
        let base = AppThemeStyles.win98
        let original = try XCTUnwrap(base.variant(.light))
        let report = AppThemeLayerReport(
            theme: custom(variant: original.replacingChrome(nil)),
            startingFrom: custom(variant: original),
            origin: .previous
        )

        XCTAssertEqual(report.states[.chrome], .absent)
    }

    // MARK: - Through the Tool

    func testTheCreateToolAppendsTheReport() async throws {
        let name = "Layer Report Theme \(UUID().uuidString)"
        let result = await coordinator().createAppTheme(CreateAppThemeArguments(
            name: name,
            baseID: AppTheme.system.id.rawValue,
            appearance: "dark",
            mode: nil,
            summary: nil,
            variants: [
                "dark": AppThemeVariantArguments(
                    roles: ["accent": "#3A6EA5"],
                    material: nil,
                    terminalColors: nil
                )
            ],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        ))
        XCTAssertFalse(result.isError, result.text)
        if let created = AppThemeLibrary.all.first(where: { $0.name == name }) {
            _ = AppThemeLibrary.delete(created)
        }

        XCTAssertTrue(result.text.contains("Layers — palette: changed"), result.text)
        XCTAssertTrue(result.text.contains("Colours only"), result.text)
    }

    func testNewChromeColoursAroundTheBasesTerminalAreNamed() throws {
        let base = AppThemeStyles.win98
        let original = try XCTUnwrap(base.variant(.light))
        let recoloured = original.replacing(roles: [.accent: .systemGreen])
        let report = AppThemeLayerReport(
            theme: custom(variant: recoloured),
            startingFrom: base,
            origin: .base(name: base.name)
        )
        XCTAssertEqual(report.states[.palette], .changed, "one half moving counts as the layer")
        XCTAssertEqual(report.terminalLeftBehind, [.light])
        XCTAssertTrue(report.text.contains("terminal palette is still \(base.name)'s"), report.text)
        XCTAssertTrue(report.text.contains("terminal_colors"), report.text)

        // A renamed copy of the same colours is still the base's terminal.
        let renamed = original.terminalPalette.identified(
            TerminalThemeID("layer-report-renamed"),
            named: "Renamed"
        )
        XCTAssertEqual(
            AppThemeLayerReport(
                theme: custom(variant: recoloured.replacing(terminalPalette: renamed)),
                startingFrom: base,
                origin: .base(name: base.name)
            ).terminalLeftBehind,
            [.light]
        )

        var paired = original.terminalPalette
        paired[.background] = .systemGreen
        let both = AppThemeLayerReport(
            theme: custom(variant: recoloured.replacing(terminalPalette: paired)),
            startingFrom: base,
            origin: .base(name: base.name)
        )
        XCTAssertTrue(both.terminalLeftBehind.isEmpty)
        XCTAssertFalse(both.text.contains("terminal palette"), both.text)

        let terminalOnly = AppThemeLayerReport(
            theme: custom(variant: original.replacing(terminalPalette: paired)),
            startingFrom: base,
            origin: .base(name: base.name)
        )
        XCTAssertTrue(terminalOnly.terminalLeftBehind.isEmpty, "only new chrome colours ask")
    }

    func testTheSchemaAsksForTheTerminalInEveryVariant() throws {
        let create = try XCTUnwrap(MCPTools.definitions.first { $0.name == MCPTools.createAppTheme })
        XCTAssertTrue(create.description.contains("State both halves in every variant"))
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(MCPTools.appVariantSchema), encoding: .utf8))
        XCTAssertTrue(json.contains("agents' TUIs"), "terminal_colors says who draws in it")
        XCTAssertTrue(json.contains("errors and removed diff lines"), "slots say what they carry")
    }

    func testTheToolDescriptionsAskForADecisionAboutDepth() {
        let create = MCPTools.definitions.first { $0.name == MCPTools.createAppTheme }
        let update = MCPTools.definitions.first { $0.name == MCPTools.updateAppTheme }

        let createDescription = create?.description ?? ""
        XCTAssertTrue(
            createDescription.hasPrefix("Decide how far the theme goes"),
            "the decision leads, so an agent meets it before the vocabulary"
        )
        XCTAssertTrue(createDescription.contains("ask the person how far to go"))
        XCTAssertTrue(update?.description.contains("four layers") == true)
    }

    // MARK: - Private Methods

    private func custom(variant: AppTheme.Variant) -> AppTheme {
        AppTheme(
            id: AppThemeID("layer-report-fixture"),
            name: "Layer Report Fixture",
            mode: .light,
            summary: nil,
            variants: [.light: variant]
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
