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

    // MARK: - Repainting What Is Already On Screen

    /// The half that dynamic colours cannot fix. A `CALayer` resolves `backgroundColor` to a
    /// `CGColor` once and keeps it, so a view filled before the theme changed would hold its old
    /// colour forever — the same freeze that left the terminal's pane stale. `applySurface`
    /// records what it was given so the sweep can resolve it again.
    func testARecordedSurfaceIsResolvedAgainWhenTheThemeChanges() {
        AppThemePalette.set(.system)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.applySurface(fill: Design.Surface.panel, radius: 4, border: Design.Surface.border)

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
            XCTAssertEqual(derived.resolvedHex, label.resolvedHex, "\(role.rawValue) changed hue")
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
    }

    func testThemesRoundTripThroughTheirDocument() throws {
        for theme in AppThemeStyles.all {
            let data = try JSONEncoder().encode(theme)
            let decoded = try JSONDecoder().decode(AppTheme.self, from: data)

            XCTAssertEqual(decoded.id, theme.id)
            XCTAssertEqual(decoded.mode, theme.mode)
            for (role, color) in theme.roles {
                XCTAssertEqual(decoded.roles[role]?.hexString, color.hexString, role.rawValue)
            }
        }
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
