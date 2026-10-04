import AppKit
@testable import SwiftTerm
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// The terminal palette's optional phosphor glow, from the stored document to the view that
/// draws it.
///
/// The renderer half — that a halo appears in each run's own colour, that decorations do not
/// glow, and that a partial repaint is pixel-identical to a full one — is SwiftTerm's own
/// `TextGlowTests`. This half is what the app owns: the palette carries it without disturbing a
/// single stored byte of a palette that has none, the tools write and read it, and every
/// terminal a profile reaches is handed it.
final class TerminalGlowTests: XCTestCase {

    // MARK: - Fixtures

    private let glow = TerminalGlow(radius: 3, opacity: 0.4)

    private func json(of theme: TerminalTheme) throws -> [String: Any] {
        let data = try JSONEncoder().encode(theme)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decoded(_ document: [String: Any]) throws -> TerminalTheme {
        let data = try JSONSerialization.data(withJSONObject: document)
        return try JSONDecoder().decode(TerminalTheme.self, from: data)
    }

    private func sortedBytes(of theme: TerminalTheme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(theme)
    }

    // MARK: - Storage

    /// The migration rule, stated as bytes: a palette with no glow encodes to exactly the
    /// document it did before the field existed, because an absent glow is never written.
    func testAPaletteWithoutAGlowWritesNoGlowKeyAndRoundTripsByteForByte() throws {
        for theme in TerminalTheme.builtInThemes + [.systemLight, .systemDark] {
            XCTAssertNil(try json(of: theme)["glow"], "\(theme.name) wrote a glow key")

            let bytes = try sortedBytes(of: theme)
            let restored = try JSONDecoder().decode(TerminalTheme.self, from: bytes)
            XCTAssertNil(restored.glow)
            XCTAssertEqual(try sortedBytes(of: restored), bytes, "\(theme.name) did not round-trip")
        }
    }

    func testAnAbsentKeyMeansNoGlow() throws {
        var document = try json(of: TerminalTheme.pro)
        document.removeValue(forKey: "glow")

        XCTAssertNil(try decoded(document).glow)
    }

    func testAStoredGlowRoundTrips() throws {
        var theme = TerminalTheme.homebrew
        theme.glow = glow

        let document = try json(of: theme)
        let stored = try XCTUnwrap(document["glow"] as? [String: Any])
        XCTAssertEqual(stored["radius"] as? Double, 3)
        XCTAssertEqual(stored["opacity"] as? Double, 0.4)

        let restored = try decoded(document)
        XCTAssertEqual(restored.glow, glow)
        XCTAssertEqual(restored.foreground.hexString, theme.foreground.hexString)
    }

    /// A glow that cannot be read costs the halo, never the palette: the terminal still has to
    /// be readable.
    func testAnUnreadableGlowIsDroppedAndThePaletteStillLoads() throws {
        var document = try json(of: TerminalTheme.pro)
        document["glow"] = "bright"

        let theme = try decoded(document)

        XCTAssertNil(theme.glow)
        XCTAssertEqual(theme.foreground.hexString, TerminalTheme.pro.foreground.hexString)
        XCTAssertEqual(theme.background.hexString, TerminalTheme.pro.background.hexString)
    }

    /// Opt-in means no shipped palette states one, so nothing anyone already uses starts to glow.
    @MainActor
    func testNoStockPaletteGlows() {
        for theme in TerminalTheme.builtInThemes + [.systemLight, .systemDark] {
            XCTAssertNil(theme.glow, theme.name)
        }
        for theme in AppThemeStyles.all {
            for kind in theme.availableVariants {
                XCTAssertNil(theme.variant(kind)?.terminalPalette.glow, "\(theme.name) \(kind)")
            }
        }
    }

    /// A variant is rebuilt by copying, so the glow rides through every edit that replaces some
    /// other part of it, and through the document an app theme is stored as.
    @MainActor
    func testAnAppThemeVariantCarriesItsPalettesGlow() throws {
        let base = AppThemeStyles.cyberpunk
        let kind = try XCTUnwrap(base.availableVariants.first)
        let variant = try XCTUnwrap(base.variant(kind))
        var palette = variant.terminalPalette
        palette.glow = glow

        let glowing = variant.replacing(terminalPalette: palette)
        XCTAssertEqual(glowing.replacing(roles: [:]).terminalPalette.glow, glow)

        let data = try JSONEncoder().encode(glowing)
        let restored = try JSONDecoder().decode(AppTheme.Variant.self, from: data)
        XCTAssertEqual(restored.terminalPalette.glow, glow)
    }

    // MARK: - Bounds

    func testTheBoundsAreStatedAndNamedInTheError() {
        XCTAssertNil(glow.validationError(field: "terminal_colors.glow"))
        XCTAssertNil(TerminalGlow(radius: 0.5, opacity: 0.05).validationError(field: "g"))
        XCTAssertNil(TerminalGlow(radius: 6, opacity: 0.8).validationError(field: "g"))

        let wide = TerminalGlow(radius: 9, opacity: 0.4).validationError(field: "colors.glow")
        XCTAssertEqual(wide, "colors.glow.radius must be between 0.5 and 6 points.")

        let strong = TerminalGlow(radius: 3, opacity: 0.95).validationError(field: "colors.glow")
        XCTAssertEqual(strong, "colors.glow.opacity must be between 0.05 and 0.8.")

        XCTAssertNotNil(TerminalGlow(radius: 0.2, opacity: 0.4).validationError(field: "g"))
        XCTAssertNotNil(TerminalGlow(radius: .nan, opacity: 0.4).validationError(field: "g"))
        XCTAssertNotNil(TerminalGlow(radius: 3, opacity: 0.01).validationError(field: "g"))
    }

    /// A hand-edited document is not validated on the way in, so the renderer is only ever
    /// handed a glow inside the bounds.
    func testTheRendererIsHandedAClampedGlow() {
        let wild = TerminalGlow(radius: 40, opacity: 3).textGlow
        XCTAssertEqual(wild.radius, TerminalGlow.radiusRange.upperBound)
        XCTAssertEqual(Double(wild.opacity), TerminalGlow.opacityRange.upperBound)

        let faint = TerminalGlow(radius: 0, opacity: 0).textGlow
        XCTAssertEqual(faint.radius, TerminalGlow.radiusRange.lowerBound)
        XCTAssertEqual(Double(faint.opacity), TerminalGlow.opacityRange.lowerBound)

        XCTAssertEqual(glow.textGlow, TerminalTextGlow(radius: 3, opacity: 0.4))
    }

    // MARK: - The Wire to the Phone

    /// The iPhone's renderer has no glow, so the palette it is sent is exactly what it was:
    /// no new key, and nothing a phone built before the glow could fail to decode.
    @MainActor
    func testTheRemotePaletteIsUnchangedByAGlow() throws {
        var glowing = TerminalTheme.homebrew
        glowing.glow = glow

        let plain = RemoteThemeBridge.terminalTheme(TerminalTheme.homebrew)
        let sent = RemoteThemeBridge.terminalTheme(glowing)
        XCTAssertEqual(sent, plain)

        let data = try JSONEncoder().encode(sent)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(document["glow"])
        XCTAssertEqual(try JSONDecoder().decode(RemoteTerminalThemeDTO.self, from: data), plain)
    }
}

// MARK: - Applying It to a Terminal

/// Every terminal reaches its palette through `TerminalSession.applyProfile`, so that is where
/// the glow has to land — and leave again.
@MainActor
final class TerminalGlowSessionTests: XCTestCase {

    private func profile(glow: TerminalGlow?) -> TerminalProfile {
        var profile = TerminalProfile.default
        var theme = TerminalTheme.homebrew
        theme.glow = glow
        profile.theme = theme
        return profile
    }

    func testASessionDrawsItsPalettesGlow() {
        let session = TerminalSession(
            profile: profile(glow: TerminalGlow(radius: 3, opacity: 0.4)),
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )

        XCTAssertEqual(session.terminalView.textGlow, TerminalTextGlow(radius: 3, opacity: 0.4))
    }

    /// A live palette change moves the glow on the view that is already drawing, and a palette
    /// without one takes it away rather than leaving the last one on.
    func testAProfileChangeMovesAndClearsTheGlow() {
        let session = TerminalSession(
            profile: profile(glow: nil),
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        XCTAssertNil(session.terminalView.textGlow)

        session.updateProfile(profile(glow: TerminalGlow(radius: 5, opacity: 0.6)))
        XCTAssertEqual(session.terminalView.textGlow, TerminalTextGlow(radius: 5, opacity: 0.6))

        session.updateProfile(profile(glow: nil))
        XCTAssertNil(session.terminalView.textGlow)
    }

    func testAnOutOfBoundsStoredGlowReachesTheViewClamped() {
        let session = TerminalSession(
            profile: profile(glow: TerminalGlow(radius: 30, opacity: 0.4)),
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )

        XCTAssertEqual(session.terminalView.textGlow?.radius, TerminalGlow.radiusRange.upperBound)
    }
}

// MARK: - Follow App Theme

/// "Follow App Theme" resolves to the active app theme's paired palette, so a variant's glow
/// reaches every terminal that follows the chrome with no wiring of its own.
@MainActor
final class TerminalGlowFollowsAppThemeTests: XCTestCase {

    override func tearDown() {
        AppThemeLibrary.apply(.system)
        super.tearDown()
    }

    func testFollowingTheAppThemeDrawsItsVariantsGlow() async throws {
        let glow = TerminalGlow(radius: 2, opacity: 0.3)
        let base = AppThemeStyles.cyberpunk
        let kind = try XCTUnwrap(base.availableVariants.first)
        let variant = try XCTUnwrap(base.variant(kind))
        var palette = variant.terminalPalette
        palette.glow = glow
        let theme = AppTheme(
            id: AppThemeID("glow-probe-\(UUID().uuidString)"),
            name: "Glow Probe",
            mode: kind == .dark ? .dark : .light,
            summary: nil,
            variants: [kind: variant.replacing(terminalPalette: palette)]
        )

        AppThemeLibrary.apply(theme)

        XCTAssertEqual(ThemeAssignments.palette(withID: .followsAppTheme).glow, glow)
        XCTAssertEqual(ThemeAssignments.followsAppTheme.glow, glow)

        AppThemeLibrary.apply(AppThemeStyles.newsprint)
        XCTAssertNil(ThemeAssignments.palette(withID: .followsAppTheme).glow)
    }
}

// MARK: - The Tools

/// The glow as an agent writes it — `terminal_colors.glow` on an app theme variant and
/// `colors.glow` on `create_theme` — and reads it back.
@MainActor
final class TerminalGlowToolTests: XCTestCase {

    private func coordinator() -> AgentToolCoordinator {
        AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
    }

    private func call(_ json: String) throws -> MCPToolCall {
        try JSONDecoder()
            .decode(MCPToolCallParameters.self, from: Data(json.utf8))
            .call
    }

    private func createDarkTheme(
        named name: String,
        terminalColors: TerminalColorsArguments?
    ) async -> MCPToolResult {
        await coordinator().createAppTheme(
            CreateAppThemeArguments(
                name: name,
                baseID: AppThemeStyles.cyberpunk.id.rawValue,
                appearance: "dark",
                mode: nil,
                summary: nil,
                variants: [
                    "dark": AppThemeVariantArguments(terminalColors: terminalColors)
                ],
                roles: nil,
                material: nil,
                terminalColors: nil,
                apply: false
            )
        )
    }

    private func update(
        _ theme: AppTheme,
        terminalColors: TerminalColorsArguments
    ) async -> MCPToolResult {
        await coordinator().updateAppTheme(
            UpdateAppThemeArguments(
                themeID: theme.id.rawValue,
                name: nil,
                appearance: nil,
                mode: nil,
                summary: nil,
                variants: ["dark": AppThemeVariantArguments(terminalColors: terminalColors)],
                roles: nil,
                material: nil,
                terminalColors: nil,
                apply: false
            )
        )
    }

    private func terminalDocument(of theme: AppTheme) throws -> [String: Any] {
        let result = coordinator().getAppTheme(
            AppThemeReferenceArguments(themeID: theme.id.rawValue)
        )
        XCTAssertFalse(result.isError, result.text)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]
        )
        let variants = try XCTUnwrap(document["variants"] as? [String: Any])
        let dark = try XCTUnwrap(variants["dark"] as? [String: Any])
        return try XCTUnwrap(dark["terminal_colors"] as? [String: Any])
    }

    // MARK: Decoding

    func testTerminalColorsDecodeAGlowBesideTheColours() throws {
        let call = try call("""
            {
              "name": "update_app_theme",
              "arguments": {
                "theme_id": "custom-glow",
                "variants": {
                  "dark": {
                    "terminal_colors": {
                      "bright_green": "#33FF66",
                      "glow": {"radius": 3, "opacity": 0.4}
                    }
                  }
                }
              }
            }
            """)

        let arguments: UpdateAppThemeArguments = try requireToolArguments(
            call,
            tool: .updateAppTheme
        )
        let colors = try XCTUnwrap(arguments.variants?["dark"]?.terminalColors)
        XCTAssertEqual(colors["bright_green"], "#33FF66")
        XCTAssertEqual(colors.colors.count, 1, "the glow was read as a colour")
        XCTAssertEqual(colors.glow, TerminalGlowArguments(radius: 3, opacity: 0.4))
        XCTAssertNil(colors.removeGlow)
    }

    func testCreateThemeColorsDecodeAGlowAndARemoval() throws {
        let glowing = try call("""
            {"name": "create_theme", "arguments": {"name": "Bloom",
              "colors": {"glow": {"radius": 2}}, "apply": "none"}}
            """)
        let arguments: CreateThemeArguments = try requireToolArguments(
            glowing,
            tool: .createTheme
        )
        XCTAssertEqual(arguments.colors?.glow?.radius, 2)
        XCTAssertNil(arguments.colors?.glow?.opacity)
        XCTAssertEqual(arguments.colors?.colors, [:])

        let removing = try call("""
            {"name": "create_theme", "arguments": {"name": "Unbloom",
              "colors": {"remove_glow": true}}}
            """)
        let removal: CreateThemeArguments = try requireToolArguments(removing, tool: .createTheme)
        XCTAssertEqual(removal.colors?.removeGlow, true)
    }

    /// Every other key still has to be a colour string, exactly as before the glow existed.
    func testANonStringColourIsStillRefusedAtDecoding() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            TerminalColorsArguments.self,
            from: Data(#"{"red": 5}"#.utf8)
        ))
    }

    // MARK: App Themes

    /// Create, read back, merge one half, remove — the whole loop through the tools, with the
    /// document `get_app_theme` returns sendable straight back as a patch.
    func testAnAppThemeGlowRoundTripsThroughCreateGetAndUpdate() async throws {
        let name = "Glowing Tool Theme \(UUID().uuidString)"
        let created = await createDarkTheme(
            named: name,
            terminalColors: TerminalColorsArguments(
                ["bright_green": "#33FF66"],
                glow: TerminalGlowArguments(radius: 3, opacity: 0.4)
            )
        )
        XCTAssertFalse(created.isError, created.text)
        let theme = try XCTUnwrap(AppThemeLibrary.all.first { $0.name == name })
        defer {
            if let latest = AppThemeLibrary.theme(withID: theme.id) {
                _ = AppThemeLibrary.delete(latest)
            }
        }
        XCTAssertEqual(
            theme.variant(.dark)?.terminalPalette.glow,
            TerminalGlow(radius: 3, opacity: 0.4)
        )

        let document = try terminalDocument(of: theme)
        let reported = try XCTUnwrap(document["glow"] as? [String: Any])
        XCTAssertEqual(reported["radius"] as? Double, 3)
        XCTAssertEqual(reported["opacity"] as? Double, 0.4)
        let resent = try JSONDecoder().decode(
            TerminalColorsArguments.self,
            from: JSONSerialization.data(withJSONObject: document)
        )
        XCTAssertEqual(resent.glow, TerminalGlowArguments(radius: 3, opacity: 0.4))
        XCTAssertEqual(resent.colors.count, ThemeColorKey.allCases.count)

        // One half stated: the other is the variant's own, not the standard default.
        let merged = await update(
            theme,
            terminalColors: TerminalColorsArguments(
                glow: TerminalGlowArguments(radius: nil, opacity: 0.6)
            )
        )
        XCTAssertFalse(merged.isError, merged.text)
        XCTAssertEqual(
            AppThemeLibrary.theme(withID: theme.id)?.variant(.dark)?.terminalPalette.glow,
            TerminalGlow(radius: 3, opacity: 0.6)
        )

        // A patch that says nothing about the glow leaves it alone.
        let recoloured = await update(theme, terminalColors: ["cursor": "#33FF66"])
        XCTAssertFalse(recoloured.isError, recoloured.text)
        XCTAssertEqual(
            AppThemeLibrary.theme(withID: theme.id)?.variant(.dark)?.terminalPalette.glow,
            TerminalGlow(radius: 3, opacity: 0.6)
        )

        let removed = await update(theme, terminalColors: TerminalColorsArguments(removeGlow: true))
        XCTAssertFalse(removed.isError, removed.text)
        let stored = try XCTUnwrap(AppThemeLibrary.theme(withID: theme.id))
        XCTAssertNil(stored.variant(.dark)?.terminalPalette.glow)
        XCTAssertNil(try terminalDocument(of: stored)["glow"])
    }

    func testAnAppThemeGlowOutOfBoundsIsRefusedByName() async {
        let wide = await createDarkTheme(
            named: "Too Wide \(UUID().uuidString)",
            terminalColors: TerminalColorsArguments(glow: TerminalGlowArguments(radius: 9, opacity: 0.4))
        )
        XCTAssertTrue(wide.isError, wide.text)
        XCTAssertTrue(wide.text.contains("terminal_colors.glow.radius"), wide.text)
        XCTAssertTrue(wide.text.contains("0.5 and 6"), wide.text)

        let both = await createDarkTheme(
            named: "Both \(UUID().uuidString)",
            terminalColors: TerminalColorsArguments(
                glow: TerminalGlowArguments(radius: 2, opacity: 0.3),
                removeGlow: true
            )
        )
        XCTAssertTrue(both.isError, both.text)
        XCTAssertTrue(both.text.contains("remove_glow"), both.text)
    }

    /// The gate is in the variant validator, not only in the tool, so a palette that arrives
    /// any other way is held to the same bounds.
    func testTheVariantValidatorRefusesAnOutOfBoundsGlow() throws {
        let base = AppThemeStyles.cyberpunk
        let kind = try XCTUnwrap(base.availableVariants.first)
        let variant = try XCTUnwrap(base.variant(kind))
        var palette = variant.terminalPalette
        palette.glow = TerminalGlow(radius: 3, opacity: 0.99)

        XCTAssertThrowsError(
            try AppThemeEditing.assemble(
                id: AppThemeID("glow-gate-\(UUID().uuidString)"),
                name: "Glow Gate",
                mode: kind == .dark ? .dark : .light,
                summary: nil,
                variants: [kind: variant.replacing(terminalPalette: palette)]
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("terminal_colors.glow.opacity"),
                error.localizedDescription
            )
        }
    }

    // MARK: Terminal Themes

    func testCreateThemeTakesAGlowAloneAndFillsTheOtherHalf() throws {
        let name = "Bloom \(UUID().uuidString)"
        let result = coordinator().createTheme(
            CreateThemeArguments(
                name: name,
                baseID: TerminalThemeID.homebrew.rawValue,
                base: nil,
                colors: TerminalColorsArguments(glow: TerminalGlowArguments(radius: 2, opacity: nil)),
                apply: "none"
            ),
            for: SessionID()
        )

        XCTAssertFalse(result.isError, result.text)
        let created = try XCTUnwrap(ThemeManager.shared.theme(named: name))
        defer { _ = ThemeManager.shared.deleteTheme(created) }
        XCTAssertEqual(created.glow, TerminalGlow(radius: 2, opacity: TerminalGlow.standard.opacity))
        XCTAssertEqual(created.foreground.hexString, TerminalTheme.homebrew.foreground.hexString)
    }

    func testCreateThemeRefusesAGlowOutOfBounds() {
        let name = "Smudge \(UUID().uuidString)"
        let result = coordinator().createTheme(
            CreateThemeArguments(
                name: name,
                baseID: TerminalThemeID.homebrew.rawValue,
                base: nil,
                colors: TerminalColorsArguments(glow: TerminalGlowArguments(radius: 3, opacity: 0.95)),
                apply: "none"
            ),
            for: SessionID()
        )

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("colors.glow.opacity"), result.text)
        XCTAssertNil(ThemeManager.shared.theme(named: name), "a refused theme was stored")
    }

    func testCreateThemeStillRefusesAnEmptyPalette() {
        let result = coordinator().createTheme(
            CreateThemeArguments(
                name: "Empty \(UUID().uuidString)",
                baseID: TerminalThemeID.homebrew.rawValue,
                base: nil,
                colors: TerminalColorsArguments([:]),
                apply: "none"
            ),
            for: SessionID()
        )

        XCTAssertTrue(result.isError, result.text)
    }

    // MARK: Schema

    func testThePaletteSchemaDescribesTheGlow() throws {
        let definition = try XCTUnwrap(
            MCPTools.definitions.first { $0.name == MCPTools.createTheme }
        )
        let encoded = try JSONEncoder().encode(definition)
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let colors = try XCTUnwrap(properties["colors"] as? [String: Any])
        let palette = try XCTUnwrap(colors["properties"] as? [String: Any])

        let glow = try XCTUnwrap(palette["glow"] as? [String: Any])
        XCTAssertEqual(glow["type"] as? String, "object")
        let halves = try XCTUnwrap(glow["properties"] as? [String: Any])
        XCTAssertEqual((halves["radius"] as? [String: Any])?["type"] as? String, "number")
        XCTAssertEqual((halves["opacity"] as? [String: Any])?["type"] as? String, "number")
        let removal = try XCTUnwrap(palette["remove_glow"] as? [String: Any])
        XCTAssertEqual(removal["type"] as? String, "boolean")

        XCTAssertTrue(definition.description.contains("glow"))
        let createApp = try XCTUnwrap(
            MCPTools.definitions.first { $0.name == MCPTools.createAppTheme }
        )
        XCTAssertTrue(createApp.description.contains("terminal_colors.glow"))
    }
}

// MARK: - Rendered State

/// Draws a few palettes with and without a glow through real `TerminalView`s and writes the sheet
/// out (`THREADING_RENDER_OUT` redirects it), because a halo's job is to be *seen*.
final class TerminalGlowRenderTests: XCTestCase {

    private enum Sheet {
        static let sample = "$ make  \u{1B}[1mBuild succeeded\u{1B}[0m  \u{1B}[32mok\u{1B}[0m  "
            + "\u{1B}[31merror\u{1B}[0m  \u{1B}[4munderlined\u{1B}[0m  ─┼─ █▓"
        static let labelWidth: CGFloat = 170
        static let stripWidth: CGFloat = 520
        static let rowHeight: CGFloat = 44
        static let margin: CGFloat = 16
        static let scale: CGFloat = 2
        static let glow = TerminalGlow(radius: 3, opacity: 0.45)

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    /// One palette's line, drawn by a real terminal into its own bitmap.
    ///
    /// The view sits in an unshown borderless window and its frame is prepared by hand, the way
    /// `TerminalColorQueryTests` renders: the renderer draws only the snapshot a frame tick
    /// prepared, so a view that was fed text and photographed without one comes out blank — the
    /// first draft of this sheet did, at every palette, and its "differs" assertion caught it.
    @MainActor
    private func strip(of palette: TerminalTheme, hosts: inout [NSWindow]) -> NSBitmapImageRep? {
        let frame = NSRect(x: 0, y: 0, width: Sheet.stripWidth, height: Sheet.rowHeight - 4)
        let view = TerminalView(frame: frame)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = view
        hosts.append(window)
        view.suspendsRenderingWhenNotVisible = false
        view.appearance = NSAppearance(named: .darkAqua)
        view.installColors(palette.asSwiftTermColors())
        view.nativeForegroundColor = palette.foreground
        view.nativeBoldForegroundColor = palette.boldForeground
        view.nativeBackgroundColor = palette.background
        view.textGlow = palette.glow?.textGlow
        view.feed(text: "\r\n" + Sheet.sample)
        view.frameTick()
        view.layoutSubtreeIfNeeded()
        view.frameTick()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Pixels that are not the strip's own ground, sampled at the top-left corner.
    private func inkedPixels(_ image: NSBitmapImageRep) -> Int {
        guard let ground = image.colorAt(x: 0, y: 0) else { return 0 }
        var count = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide where image.colorAt(x: x, y: y) != ground {
                count += 1
            }
        }
        return count
    }

    /// Pixels where the two strips differ; the halo is the only thing that can make them.
    private func differingPixels(_ left: NSBitmapImageRep, _ right: NSBitmapImageRep) -> Int {
        guard left.pixelsWide == right.pixelsWide, left.pixelsHigh == right.pixelsHigh else {
            return Int.max
        }
        var count = 0
        for y in 0..<left.pixelsHigh {
            for x in 0..<left.pixelsWide where left.colorAt(x: x, y: y) != right.colorAt(x: x, y: y) {
                count += 1
            }
        }
        return count
    }

    @MainActor
    func testDrawsEachPaletteWithAndWithoutItsGlow() throws {
        let directory = Sheet.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var palettes: [(String, TerminalTheme)] = [
            ("Homebrew", .homebrew), ("Pro", .pro), ("Ocean", .ocean)
        ]
        for theme in [AppThemeStyles.cyberpunk, AppThemeStyles.newsprint] {
            if let kind = theme.availableVariants.first, let variant = theme.variant(kind) {
                palettes.append((theme.name, variant.terminalPalette))
            }
        }

        var hosts: [NSWindow] = []
        // The background is the view's layer colour, which a cache of its drawing does not
        // contain, so each strip is laid on its palette's own ground.
        var rows: [(String, NSColor, NSBitmapImageRep?)] = []
        for (name, palette) in palettes {
            var glowing = palette
            glowing.glow = Sheet.glow
            let plain = strip(of: palette, hosts: &hosts)
            let lit = strip(of: glowing, hosts: &hosts)
            rows.append((name, palette.background, plain))
            rows.append(("\(name) — glow", palette.background, lit))

            let plainImage = try XCTUnwrap(plain, "\(name) drew no strip")
            let litImage = try XCTUnwrap(lit, "\(name) drew no glowing strip")
            XCTAssertGreaterThan(inkedPixels(plainImage), 0, "\(name) drew no text")
            XCTAssertGreaterThan(
                differingPixels(plainImage, litImage), 0,
                "\(name)'s glow drew nothing"
            )
        }

        let height = Sheet.margin * 2 + Sheet.rowHeight * CGFloat(rows.count)
        let width = Sheet.margin * 3 + Sheet.labelWidth + Sheet.stripWidth
        let sheet = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * Sheet.scale),
            pixelsHigh: Int(height * Sheet.scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        sheet.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSColor(hex: "#151515")!.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, row) in rows.enumerated() {
            let top = Sheet.margin + Sheet.rowHeight * CGFloat(rows.count - index - 1)
            (row.0 as NSString).draw(
                at: NSPoint(x: Sheet.margin, y: top + (Sheet.rowHeight - 14) / 2),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor(hex: "#DDDDDD")!
                ]
            )
            let stripRect = NSRect(
                x: Sheet.margin * 2 + Sheet.labelWidth,
                y: top + 2,
                width: Sheet.stripWidth,
                height: Sheet.rowHeight - 4
            )
            row.1.setFill()
            stripRect.fill()
            row.2?.draw(
                in: stripRect, from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: false, hints: nil
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        let url = directory.appendingPathComponent("terminal-glow.png")
        let data = try XCTUnwrap(sheet.representation(using: .png, properties: [:]))
        try data.write(to: url)
        print("Rendered \(rows.count) strips to \(url.path)")
        XCTAssertGreaterThan(data.count, 10_000, "the sheet came out blank")
    }
}
