import AppKit
import XCTest
@testable import Skalman

/// The app-chrome theme: its roles, its derivations, and the promise that matters most —
/// that the **System theme changes nothing**.
///
/// That promise is the whole reason this refactor is safe to land before any style exists. The
/// design system's "system colours only" rule is not abolished by theming; it becomes the
/// default, and a user who never picks a style keeps light, dark and their own accent working
/// exactly as they did.
@MainActor
final class AppThemeTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - The System Theme Changes Nothing

    func testSystemThemeResolvesEveryRoleToItsSystemColour() {
        AppThemePalette.set(.system)

        for role in AppThemeRole.allCases {
            XCTAssertEqual(
                AppTheme.system.resolved(role),
                role.systemColor,
                "\(role.rawValue) drifted from the colour the app used before theming"
            )
        }
    }

    func testSystemThemeIsExplicitlyAdaptiveAcrossLightAndDarkAppearances() throws {
        XCTAssertEqual(AppTheme.system.mode, .system)
        XCTAssertNil(AppTheme.Mode.system.appearance)
        XCTAssertTrue(AppTheme.system.variants.isEmpty)

        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var lightGround = ""
        var darkGround = ""
        var lightLabel = ""
        var darkLabel = ""

        light.performAsCurrentDrawingAppearance {
            lightGround = (AppTheme.system.resolved(.ground).usingColorSpace(.sRGB) ?? .black).hexString
            lightLabel = (AppTheme.system.resolved(.label).usingColorSpace(.sRGB) ?? .black).hexString
        }
        dark.performAsCurrentDrawingAppearance {
            darkGround = (AppTheme.system.resolved(.ground).usingColorSpace(.sRGB) ?? .black).hexString
            darkLabel = (AppTheme.system.resolved(.label).usingColorSpace(.sRGB) ?? .black).hexString
        }

        XCTAssertNotEqual(lightGround, darkGround)
        XCTAssertNotEqual(lightLabel, darkLabel)
        XCTAssertNotNil(AppTheme.Mode.light.appearance)
        XCTAssertNotNil(AppTheme.Mode.dark.appearance)
    }

    func testAuthoredAdaptiveThemeResolvesItsCompleteMatchingVariant() throws {
        let theme = try adaptiveFixture()
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertEqual(
            theme.resolved(.ground, appearance: lightAppearance).hexString,
            AppThemeStyles.swissMinimalist.resolved(.ground).hexString
        )
        XCTAssertEqual(
            theme.resolved(.ground, appearance: darkAppearance).hexString,
            AppThemeStyles.cyberpunk.resolved(.ground).hexString
        )
        XCTAssertEqual(
            theme.variant(for: lightAppearance)?.material,
            AppThemeStyles.swissMinimalist.material
        )
        XCTAssertEqual(
            theme.variant(for: darkAppearance)?.material,
            AppThemeStyles.cyberpunk.material
        )
        XCTAssertEqual(
            theme.variant(for: lightAppearance)?.terminalPalette.id,
            AppThemeStyles.swissMinimalist.terminalPalette.id
        )
        XCTAssertEqual(
            theme.variant(for: darkAppearance)?.terminalPalette.id,
            AppThemeStyles.cyberpunk.terminalPalette.id
        )
    }

    func testCompatibilityProjectionsFollowTheCurrentDrawingAppearance() throws {
        let theme = try adaptiveFixture()
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var lightRadius: CGFloat = -1
        var darkRadius: CGFloat = -1
        var lightTerminal = ""
        var darkTerminal = ""

        lightAppearance.performAsCurrentDrawingAppearance {
            lightRadius = theme.material.panelRadius
            lightTerminal = theme.terminalPalette.background.hexString
        }
        darkAppearance.performAsCurrentDrawingAppearance {
            darkRadius = theme.material.panelRadius
            darkTerminal = theme.terminalPalette.background.hexString
        }

        XCTAssertEqual(lightRadius, AppThemeStyles.swissMinimalist.material.panelRadius)
        XCTAssertEqual(darkRadius, AppThemeStyles.cyberpunk.material.panelRadius)
        XCTAssertEqual(
            lightTerminal,
            AppThemeStyles.swissMinimalist.terminalPalette.background.hexString
        )
        XCTAssertEqual(
            darkTerminal,
            AppThemeStyles.cyberpunk.terminalPalette.background.hexString
        )
    }

    func testSecondVariantIsOptionalUntilThemeBecomesAdaptive() throws {
        XCTAssertNoThrow(try AppThemeEditing.validate(AppThemeStyles.cyberpunk))

        let dark = try XCTUnwrap(AppThemeStyles.cyberpunk.variant(.dark))
        let invalid = AppTheme(
            id: AppThemeID("missing-light"),
            name: "Missing Light",
            mode: .system,
            summary: nil,
            variants: [.dark: dark]
        )
        XCTAssertThrowsError(try AppThemeEditing.validate(invalid)) { error in
            XCTAssertTrue(error.localizedDescription.contains("both light and dark"))
        }
    }

    func testDuplicatingAnAdaptiveThemePreservesBothVariants() throws {
        let source = try adaptiveFixture()
        let copy = try AppThemeEditing.duplicate(
            source,
            id: AppThemeID("adaptive-copy"),
            name: "Adaptive Copy"
        )

        XCTAssertEqual(copy.mode, .system)
        XCTAssertEqual(Set(copy.availableVariants), [.light, .dark])
        XCTAssertEqual(copy.variant(.light)?.roles, source.variant(.light)?.roles)
        XCTAssertEqual(copy.variant(.dark)?.roles, source.variant(.dark)?.roles)
        XCTAssertEqual(copy.variant(.light)?.terminalPalette.name, "Adaptive Copy")
        XCTAssertEqual(copy.variant(.dark)?.terminalPalette.name, "Adaptive Copy")
    }

    func testDuplicatingSystemMaterialisesEditableLightAndDarkVariants() throws {
        let copy = try AppThemeEditing.duplicate(
            .system,
            id: AppThemeID("system-copy"),
            name: "System Copy"
        )

        XCTAssertEqual(copy.mode, .system)
        XCTAssertEqual(Set(copy.availableVariants), [.light, .dark])
        for kind in AppTheme.VariantKind.allCases {
            let variant = try XCTUnwrap(copy.variant(kind))
            for role in AppThemeRole.authored {
                XCTAssertNotNil(variant.roles[role], "\(kind.rawValue).\(role.wireName)")
            }
        }
    }

    /// The tokens as their call sites see them, pinned against the literal expressions they
    /// replaced. If one of these changes, the app's default appearance changed.
    func testDesignTokensAreUnchangedUnderTheSystemTheme() {
        AppThemePalette.set(.system)

        let expected: [(String, NSColor, NSColor)] = [
            ("panel", Design.Surface.panel, .textBackgroundColor.withAlphaComponent(0.4)),
            ("border", Design.Surface.border, .separatorColor),
            ("accent", Design.Surface.accent, .controlAccentColor),
            ("controlResting", Design.Surface.controlResting,
             .unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5)),
            ("controlHover", Design.Surface.controlHover,
             .unemphasizedSelectedContentBackgroundColor),
            ("bubbleFill", Design.Chat.bubbleFill, .controlAccentColor.withAlphaComponent(0.22)),
            ("turnDivider", Design.Chat.turnDivider, .separatorColor.withAlphaComponent(0.5)),
            ("syntaxKeyword", Design.Syntax.keyword, .systemPurple),
            ("syntaxComment", Design.Syntax.comment, .tertiaryLabelColor),
            ("label", Design.Text.label, .labelColor),
            ("secondary", Design.Text.secondary, .secondaryLabelColor),
            ("tertiary", Design.Text.tertiary, .tertiaryLabelColor)
        ]

        for (name, token, original) in expected {
            XCTAssertEqual(
                token.resolvedHex, original.resolvedHex,
                "\(name) no longer matches the system colour it replaced"
            )
        }
    }

    // MARK: - Material

    /// The System theme's geometry is the geometry the app always had. These are the literals
    /// `Design.Radius` held before it read a theme.
    func testSystemGeometryIsUnchanged() {
        AppThemePalette.set(.system)

        XCTAssertEqual(Design.Radius.panel, 12)
        XCTAssertEqual(Design.Radius.control, 8)
        XCTAssertEqual(Design.Radius.border, 1)
        XCTAssertEqual(Design.Radius.pill(height: 26), 13, "a System pill is still fully rounded")
    }

    /// The point of the material layer: two themes that differ only in hue read as one app in
    /// two tints. A style has to change the *silhouette* as well.
    func testEveryStyleHasItsOwnSilhouette() {
        for theme in AppThemeStyles.all {
            XCTAssertNotEqual(
                theme.material, AppTheme.Material.system,
                "\(theme.name) has the same geometry as System, so it is only a tint"
            )
        }
    }

    func testAStyleSquaresItsPillsWhenItSquaresEverythingElse() {
        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        XCTAssertEqual(Design.Radius.pill(height: 26), 0, "Swiss left its chips rounded")

        AppThemePalette.set(.system)
        XCTAssertEqual(Design.Radius.pill(height: 26), 13)
    }

    /// A glow is opt-in per theme; a style without one must not inherit a halo from the last.
    func testOnlyThemesThatAskForAGlowHaveOne() {
        XCTAssertNotNil(AppThemeStyles.cyberpunk.material.glow)
        XCTAssertNil(AppThemeStyles.swissMinimalist.material.glow)
        XCTAssertNil(AppTheme.system.material.glow)
    }

    /// A glow is a layer shadow, and a shadow spills past the panel that casts it — so any
    /// clipping host budgets `Design.Size.glowGutter` around glowing panels. The gutter is a
    /// stated constant rather than a derivation, because layout must not move when a theme
    /// does; this is what makes shipping a wider glow a loud decision instead of a silent
    /// clip. The blur's visible extent is about twice its radius, after travelling its offset.
    func testGlowGutterCoversEveryStockGlow() {
        for theme in AppThemeLibrary.stock {
            guard let glow = theme.material.glow else { continue }
            XCTAssertGreaterThanOrEqual(
                Design.Size.glowGutter,
                abs(glow.offsetX) + glow.radius * 2,
                "\(theme.name)'s horizontal shadow spills past its gutter"
            )
            XCTAssertGreaterThanOrEqual(
                Design.Size.glowGutter,
                abs(glow.offsetY) + glow.radius * 2,
                "\(theme.name)'s vertical shadow spills past its gutter"
            )
        }

        // The settings column's top and bottom padding double as the first and last card's
        // gutter (`SettingsUI.page`), so the page padding must cover the spill too.
        XCTAssertGreaterThanOrEqual(Design.Spacing.large, Design.Size.glowGutter)
    }

    func testDirectedPanelShadowsFitTheMaterialContract() {
        let hard = AppThemeStyles.neoBrutalism.material.glow
        XCTAssertEqual(hard?.radius, 0)
        XCTAssertNotEqual(hard?.offsetX ?? 0, 0)
        XCTAssertNotEqual(hard?.offsetY ?? 0, 0)

        let halo = AppThemeStyles.vaporwave.material.glow
        XCTAssertGreaterThan(halo?.radius ?? 0, 0)
        XCTAssertEqual(halo?.offsetX, 0)
        XCTAssertEqual(halo?.offsetY, 0)
    }

    /// The accent has to be *stated* for the surfaces that carry a style's identity — the
    /// selected row, the chips, the focus. Derived-from-label greys are what made the first
    /// pass read as the same app in a different tint.
    func testStylesStateTheirOwnControlFills() {
        for theme in AppThemeStyles.all {
            XCTAssertNotNil(
                theme.roles[.controlResting],
                "\(theme.name) leaves its controls to the grey derivation"
            )
            XCTAssertNotNil(theme.roles[.accent], "\(theme.name) states no accent")
        }
    }

    // MARK: - Dynamic Resolution

    /// The measured fact the whole refactor rests on: a themed colour re-resolves when the
    /// *theme* changes, not only when the system appearance does. Without this, every one of
    /// the app's ~220 colour call sites would need a re-assignment path of its own.
    func testAThemedColourFollowsTheCurrentTheme() {
        let color = AppThemePalette.color(.accent)

        AppThemePalette.set(.system)
        let underSystem = color.resolvedHex

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let underCyberpunk = color.resolvedHex

        XCTAssertEqual(underCyberpunk, AppThemeStyles.cyberpunk.resolved(.accent).resolvedHex)
        XCTAssertNotEqual(underSystem, underCyberpunk, "the same colour object did not re-resolve")
    }

    // MARK: - Surfaces That Follow the Appearance

    /// The other half of the frozen-`CGColor` problem, and the one nothing swept: a **system
    /// light/dark switch**. A theme change runs `AppThemeRefresh`; an appearance change ran
    /// nothing, so dynamic text turned dark while the surface under it stayed dark too.
    ///
    /// It stayed invisible while the largest surface in the window was a system material AppKit
    /// repainted itself. The sidebar paints its own ground now, so the gap is real, and
    /// `ThemedSurfaceView` is the view that closes it.
    @MainActor
    func testAThemedSurfaceViewReResolvesWhenTheAppearanceChanges() throws {
        AppThemePalette.set(.system)

        let surface = ThemedSurfaceView()
        surface.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        surface.appearance = NSAppearance(named: .darkAqua)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            surface.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        }

        let dark = try XCTUnwrap(surface.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })

        // The switch AppKit reports through `viewDidChangeEffectiveAppearance`.
        surface.appearance = NSAppearance(named: .aqua)

        let light = try XCTUnwrap(surface.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
        XCTAssertGreaterThan(
            (light.usingColorSpace(.sRGB)?.brightnessComponent ?? 0),
            (dark.usingColorSpace(.sRGB)?.brightnessComponent ?? 1),
            "the ground kept its dark fill after the appearance turned light"
        )
    }

    /// A plain view is what the sidebar used before, and it is the failure this exists to
    /// prevent: the layer keeps whatever it was handed.
    @MainActor
    func testAPlainViewKeepsItsFillAcrossAnAppearanceChange() throws {
        AppThemePalette.set(.system)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.appearance = NSAppearance(named: .darkAqua)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            view.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        }
        let before = try XCTUnwrap(view.layer?.backgroundColor)

        view.appearance = NSAppearance(named: .aqua)

        XCTAssertEqual(view.layer?.backgroundColor, before)
    }

    // MARK: - Repainting What Is Already On Screen

    /// The half that dynamic colours cannot fix. A `CALayer` resolves `backgroundColor` to a
    /// `CGColor` once and keeps it, so a view filled before the theme changed would hold its old
    /// colour forever — the same freeze that left the terminal's pane stale. `applySurface`
    /// records what it was given so the sweep can resolve it again.
    func testARecordedSurfaceIsResolvedAgainWhenTheThemeChanges() {
        AppThemePalette.set(.system)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.applySurface(fill: Design.Surface.panel, radius: .fixed(4), border: Design.Surface.border)

        let before = view.layer?.backgroundColor
        XCTAssertNotNil(before)

        AppThemePalette.set(AppThemeStyles.cyberpunk)

        // Nothing has repainted yet: this is the stale state the sweep exists to fix.
        XCTAssertEqual(view.layer?.backgroundColor, before, "the layer resolved itself, unexpectedly")

        view.reapplyRecordedSurfaceForTesting()

        let after = try? XCTUnwrap(view.layer?.backgroundColor)
        XCTAssertNotEqual(after, before, "the recorded surface was not resolved again")
        XCTAssertEqual(
            after.flatMap { NSColor(cgColor: $0)?.hexString },
            AppThemeStyles.cyberpunk.resolved(.panel).hexString
        )
    }

    /// Semantic radius identity cannot be recovered from its current number. Swiss deliberately
    /// gives panels, controls, and pills the same zero radius; a numeric recorder therefore
    /// classified every one as the first matching role and replayed the wrong shape when the
    /// next theme separated them again.
    func testRecordedSurfaceRadiusKeepsItsRoleAcrossEqualRadiusThemes() {
        AppThemePalette.set(AppThemeStyles.swissMinimalist)

        let panel = NSView()
        panel.applySurface(fill: Design.Surface.panel, radius: .panel)

        let control = NSView()
        control.applySurface(fill: Design.Surface.panel, radius: .control)

        let pill = NSView()
        pill.applySurface(fill: Design.Surface.panel, radius: .pill(height: 26))

        let fixed = NSView()
        fixed.applySurface(fill: Design.Surface.panel, radius: .fixed(5))

        XCTAssertEqual(panel.layer?.cornerRadius, 0)
        XCTAssertEqual(control.layer?.cornerRadius, 0)
        XCTAssertEqual(pill.layer?.cornerRadius, 0)
        XCTAssertEqual(fixed.layer?.cornerRadius, 5)

        AppThemePalette.set(.system)
        for view in [panel, control, pill, fixed] {
            view.reapplyRecordedSurfaceForTesting()
        }

        XCTAssertEqual(panel.layer?.cornerRadius, 12)
        XCTAssertEqual(control.layer?.cornerRadius, 8)
        XCTAssertEqual(pill.layer?.cornerRadius, 13)
        XCTAssertEqual(fixed.layer?.cornerRadius, 5)
    }

    /// State-specific fills use the lighter layer helper rather than replacing the surface
    /// record. It must retain the dynamic NSColor for the same reason `applySurface` does.
    func testARecordedLayerColourIsResolvedAgainWhenTheThemeChanges() {
        AppThemePalette.set(.system)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.applyLayerBackground(Design.Surface.controlResting)
        let before = view.layer?.backgroundColor

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        XCTAssertEqual(view.layer?.backgroundColor, before)

        view.reapplyRecordedLayerColorsForTesting()

        let after = view.layer?.backgroundColor
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(
            after.flatMap { NSColor(cgColor: $0)?.hexString },
            AppThemeStyles.swissMinimalist.resolved(.controlResting).hexString
        )
    }

    /// A view with no recorded surface must survive the sweep untouched — most views have none.
    func testTheSweepLeavesUnrecordedViewsAlone() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.magenta.cgColor

        view.reapplyRecordedSurfaceForTesting()

        XCTAssertEqual(
            NSColor(cgColor: view.layer!.backgroundColor!)?.hexString,
            NSColor.magenta.hexString
        )
    }

    // MARK: - Derivation

    /// A style states a dozen roles; the rest are derived. What must never happen is a themed
    /// role falling back to a *system* colour — a fixed dark ground with system labels over it
    /// would flip half the window when macOS switched appearance.
    func testEveryRoleIsThemedOnceAStyleIsApplied() {
        for theme in AppThemeStyles.all {
            for role in AppThemeRole.allCases {
                let resolved = theme.resolved(role)
                XCTAssertNotEqual(
                    resolved.resolvedHex, role.systemColor.resolvedHex,
                    "\(theme.name) leaves \(role.rawValue) on the system colour"
                )
            }
        }
    }

    func testDerivedLabelTiersDescendFromTheStatedLabel() {
        let theme = AppThemeStyles.cyberpunk
        let label = theme.resolved(.label)

        for role in [AppThemeRole.secondaryLabel, .tertiaryLabel, .quaternaryLabel] {
            let derived = theme.resolved(role)
            XCTAssertEqual(
                derived.withAlphaComponent(1).resolvedHex,
                label.withAlphaComponent(1).resolvedHex,
                "\(role.rawValue) changed hue"
            )
            XCTAssertLessThan(derived.alphaComponent, label.alphaComponent)
        }
    }

    // MARK: - Legibility

    /// A style that cannot be read is not a style. Every stock theme's text must clear the same
    /// contrast floor the terminal themes are held to, on each of its own surfaces.
    func testEveryStockStyleIsLegibleOnItsOwnSurfaces() {
        for theme in AppThemeStyles.all {
            for surface in [AppThemeRole.ground, .surface, .panel] {
                let ratio = ThemeContrast.ratio(theme.resolved(.label), theme.resolved(surface))
                XCTAssertGreaterThanOrEqual(
                    ratio, ThemeContrast.minimumRatio,
                    "\(theme.name): label on \(surface.rawValue) is \(String(format: "%.1f", ratio)):1"
                )
            }
        }
    }

    func testStockStyleAccentsStandOutFromTheirGround() {
        for theme in AppThemeStyles.all {
            let ratio = ThemeContrast.ratio(theme.resolved(.accent), theme.resolved(.ground))
            XCTAssertGreaterThanOrEqual(ratio, 2.0, "\(theme.name)'s accent vanishes into its ground")
        }
    }

    // MARK: - Identity

    /// Stock themes are addressed by slug, never by display name — the mistake the terminal
    /// themes made, where renaming one in a release would silently reset every assignment.
    func testStockThemesHaveUniqueStableIdentifiers() {
        let ids = AppThemeLibrary.stock.map(\.id.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count, "two stock themes share an id")
        XCTAssertTrue(ids.contains(AppThemeID.system.rawValue))
        XCTAssertEqual(ids.count, 11, "the curated stock catalogue unexpectedly changed size")
    }

    func testEveryStockStylePassesTheSameValidationAsAgentCreatedThemes() throws {
        for theme in AppThemeStyles.all {
            XCTAssertNoThrow(
                try AppThemeEditing.validate(theme),
                "\(theme.name) fails the public theme contract"
            )
        }
    }

    func testEveryStockStyleHasAUniquePairedTerminalPalette() {
        let ids = AppThemeStyles.all.map(\.terminalPalette.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testThemesRoundTripThroughTheirDocument() throws {
        for theme in AppThemeStyles.all {
            let data = try JSONEncoder().encode(theme)
            let decoded = try JSONDecoder().decode(AppTheme.self, from: data)

            XCTAssertEqual(decoded.id, theme.id)
            XCTAssertEqual(decoded.mode, theme.mode)
            XCTAssertEqual(Set(decoded.variants.keys), Set(theme.variants.keys))
            for kind in theme.availableVariants {
                XCTAssertEqual(decoded.variant(kind)?.material, theme.variant(kind)?.material)
                for (role, color) in theme.variant(kind)?.roles ?? [:] {
                    XCTAssertEqual(
                        decoded.variant(kind)?.roles[role]?.hexString,
                        color.hexString,
                        "\(kind.rawValue).\(role.rawValue)"
                    )
                }
            }
        }
    }

    func testAdaptiveThemeRoundTripsBothVariants() throws {
        let theme = try adaptiveFixture()
        let encoded = try JSONEncoder().encode(theme)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNotNil(object["variants"])
        XCTAssertNil(object["roles"], "new documents must not write the legacy single-variant shape")

        let decoded = try JSONDecoder().decode(AppTheme.self, from: encoded)
        XCTAssertEqual(decoded.mode, .system)
        XCTAssertEqual(Set(decoded.variants.keys), Set(theme.variants.keys))
        for kind in theme.availableVariants {
            let original = try XCTUnwrap(theme.variant(kind))
            let restored = try XCTUnwrap(decoded.variant(kind))
            XCTAssertEqual(restored.material, original.material)
            for role in AppThemeRole.allCases {
                XCTAssertEqual(
                    restored.roles[role]?.hexString,
                    original.roles[role]?.hexString,
                    "\(kind.rawValue).\(role.wireName)"
                )
            }
            for color in ThemeColorKey.allCases {
                XCTAssertEqual(
                    restored.terminalPalette[color].hexString,
                    original.terminalPalette[color].hexString,
                    "\(kind.rawValue).terminal.\(color.wireName)"
                )
            }
        }
    }

    func testThemeDocumentsPreserveTranslucentRoles() throws {
        let color = try XCTUnwrap(NSColor(hex: "#12345680"))
        let theme = AppTheme(
            id: AppThemeID("alpha"),
            name: "Alpha",
            mode: .dark,
            summary: nil,
            roles: [.accentMuted: color],
            terminalPalette: .basic,
            material: .system
        )

        let decoded = try JSONDecoder().decode(
            AppTheme.self,
            from: JSONEncoder().encode(theme)
        )
        let restored = try XCTUnwrap(decoded.roles[.accentMuted])
        XCTAssertEqual(restored.hexString, "#12345680")
        XCTAssertEqual(restored.alphaComponent, color.alphaComponent, accuracy: 1 / 255)
    }

    func testCustomThemeStorePersistsCompleteDocuments() throws {
        let suite = "AppThemeStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppThemeStore(defaults: defaults, key: "themes")

        store.insert(AppThemeStyles.cyberpunk)

        let restored = try XCTUnwrap(store.themes.first)
        XCTAssertEqual(restored.id, AppThemeStyles.cyberpunk.id)
        XCTAssertEqual(
            restored.roles[.accentMuted]?.hexString,
            AppThemeStyles.cyberpunk.roles[.accentMuted]?.hexString
        )
        XCTAssertEqual(restored.material, AppThemeStyles.cyberpunk.material)
        XCTAssertEqual(restored.terminalPalette, AppThemeStyles.cyberpunk.terminalPalette)
    }

    func testCustomThemeMaterialisesSystemRolesBeforeItIsStored() throws {
        let theme = try AppThemeEditing.make(
            id: AppThemeID("fixed-system-copy"),
            name: "Fixed System Copy",
            base: .system,
            mode: .dark,
            roles: [
                .ground: NSColor(hex: "#080808")!,
                .surface: NSColor(hex: "#101010")!,
                .panel: NSColor(hex: "#181818")!,
                .label: NSColor(hex: "#F4F4F4")!,
                .accent: NSColor(hex: "#66CCFF")!
            ]
        )

        for role in AppThemeRole.authored {
            XCTAssertNotNil(theme.roles[role], "\(role.wireName) stayed dynamic")
        }
    }

    func testCustomThemeValidationRejectsUnreadableChrome() {
        XCTAssertThrowsError(
            try AppThemeEditing.make(
                id: AppThemeID("unreadable"),
                name: "Unreadable",
                base: AppThemeStyles.cyberpunk,
                roles: [
                    .ground: NSColor(hex: "#111111")!,
                    .surface: NSColor(hex: "#111111")!,
                    .panel: NSColor(hex: "#111111")!,
                    .label: NSColor(hex: "#111111")!
                ]
            )
        )
    }

    func testCustomThemeValidationMeasuresTranslucentTextAsDrawn() {
        XCTAssertThrowsError(
            try AppThemeEditing.make(
                id: AppThemeID("faint"),
                name: "Faint",
                base: AppThemeStyles.cyberpunk,
                roles: [
                    .label: NSColor(hex: "#FFFFFF20")!
                ]
            )
        )
    }

    /// A role added in a later release must not stop an older document loading.
    func testAnUnknownRoleInADocumentIsSkippedRatherThanFatal() throws {
        let json = """
        {"id":"future","name":"Future","mode":"dark",
         "roles":{"ground":"#101010","label":"#EEEEEE","hologram":"#FF00FF"}}
        """
        let decoded = try JSONDecoder().decode(AppTheme.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.roles[.ground]?.hexString, "#101010")
        XCTAssertEqual(decoded.roles.count, 2)
    }

    func testLegacySingleVariantDocumentMigratesDuringDecode() throws {
        let json = """
        {
          "id":"legacy-dark",
          "name":"Legacy Dark",
          "mode":"dark",
          "roles":{"ground":"#101010","label":"#EEEEEE"},
          "material":{"panelRadius":4,"controlRadius":3,"borderWidth":1}
        }
        """
        let decoded = try JSONDecoder().decode(AppTheme.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.availableVariants, [.dark])
        XCTAssertNil(decoded.variant(.light))
        XCTAssertEqual(decoded.variant(.dark)?.roles[.ground]?.hexString, "#101010")
        XCTAssertEqual(decoded.variant(.dark)?.material.panelRadius, 4)
    }

    func testAppThemeRolesAcceptAgentFacingSnakeCase() {
        XCTAssertEqual(AppThemeRole.named("status_positive"), .statusPositive)
        XCTAssertEqual(AppThemeRole.named("controlResting"), .controlResting)
        XCTAssertNil(AppThemeRole.named("wallpaper"))
    }

    // MARK: - Typography

    func testSemanticTypographyRolesKeepAConsistentHierarchy() {
        XCTAssertGreaterThan(
            Design.Typography.heading().pointSize,
            Design.Typography.placeholderTitle().pointSize
        )
        XCTAssertGreaterThan(
            Design.Typography.placeholderTitle().pointSize,
            Design.Typography.body().pointSize
        )
        XCTAssertGreaterThan(
            Design.Typography.body().pointSize,
            Design.Typography.detail().pointSize
        )
        XCTAssertEqual(
            Design.Typography.body().pointSize,
            Design.Typography.emphasizedBody().pointSize,
            "emphasis changed size instead of weight"
        )
    }

    func testCodeAndNumericRolesUseTheExpectedFixedWidthFamilies() {
        XCTAssertTrue(Design.Typography.code().fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertTrue(Design.Typography.inlineCode().fontDescriptor.symbolicTraits.contains(.monoSpace))

        let numeric = Design.Typography.numericBody()
        let one = ("1" as NSString).size(withAttributes: [.font: numeric]).width
        let eight = ("8" as NSString).size(withAttributes: [.font: numeric]).width
        XCTAssertEqual(one, eight, accuracy: 0.001)
    }

    private func adaptiveFixture() throws -> AppTheme {
        let light = try XCTUnwrap(AppThemeStyles.swissMinimalist.variant(.light))
        let dark = try XCTUnwrap(AppThemeStyles.cyberpunk.variant(.dark))
        return try AppThemeEditing.assemble(
            id: AppThemeID("adaptive-fixture"),
            name: "Adaptive Fixture",
            mode: .system,
            summary: nil,
            variants: [.light: light, .dark: dark]
        )
    }
}

// MARK: - Helpers

private extension NSColor {
    /// Compares colours by what they actually draw as, since a dynamic colour and a literal are
    /// never `==` even when they render identically.
    var resolvedHex: String {
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        var hex = ""
        appearance.performAsCurrentDrawingAppearance {
            hex = (usingColorSpace(.sRGB) ?? .black).hexString
        }
        return hex
    }
}
