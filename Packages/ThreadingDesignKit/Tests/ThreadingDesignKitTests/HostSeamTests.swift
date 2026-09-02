import AppKit
import XCTest
@testable import ThreadingDesignKit

/// The seam is the whole reason this package can exist, so it is what gets tested.
///
/// These files are the application's own, compiled a second time. What has to be proven is not
/// that a button draws — the application's own tests do that against the same source — but that a
/// plugin's copy answers to the *host's* theme and preferences rather than to a default of its
/// own. A plugin whose components silently kept the stock palette would look almost right, which
/// is the failure worth a test.
final class HostSeamTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.install(AppThemeStyles.threading)
        AppSettings.appTextSize = .standard
        super.tearDown()
    }

    @MainActor
    func testAColourTokenFollowsTheThemeTheHostInstalls() throws {
        let candidates = AppThemeStyles.all
        let ground = { (theme: AppTheme) -> NSColor in
            AppThemePalette.install(theme)
            return Design.Surface.ground.usingColorSpace(.sRGB)!
        }
        let first = try XCTUnwrap(candidates.first)
        let contrasting = try XCTUnwrap(
            candidates.first { ground($0).brightnessComponent != ground(first).brightnessComponent },
            "the stock themes should not all paint the same ground"
        )
        XCTAssertNotEqual(
            ground(first).brightnessComponent,
            ground(contrasting).brightnessComponent,
            "a token resolves through whatever the host installed, not a baked-in palette"
        )
    }

    /// The dynamic colour re-resolves when it is *drawn*, which is what lets a live theme change
    /// reach a plugin's views without rebuilding them.
    @MainActor
    func testATokenReresolvesRatherThanCapturingItsColour() throws {
        func ground(_ theme: AppTheme) -> CGFloat {
            AppThemePalette.install(theme)
            return Design.Surface.ground.usingColorSpace(.sRGB)!.brightnessComponent
        }
        let stock = AppThemeStyles.threading
        let other = try XCTUnwrap(
            AppThemeStyles.all.first(where: { ground($0) != ground(stock) }),
            "the stock themes should not all paint the same ground"
        )
        AppThemePalette.install(stock)
        let token = Design.Surface.ground
        let before = token.usingColorSpace(.sRGB)!.brightnessComponent
        AppThemePalette.install(other)
        let after = token.usingColorSpace(.sRGB)!.brightnessComponent
        XCTAssertNotEqual(before, after, "the same NSColor answers the theme installed later")
    }

    /// `DesignSettings` names five values and the host supplies them. Text size is the one with
    /// visible consequences everywhere, so it stands in for the rest.
    @MainActor
    func testTextSizeComesFromTheHostRatherThanTheDeveloperSDefaults() {
        AppSettings.appTextSize = .standard
        let standard = Design.Typography.scale
        AppSettings.appTextSize = .extraLarge
        let large = Design.Typography.scale
        XCTAssertGreaterThan(large, standard, "a plugin lays out at the size the user chose")
    }

    /// Without a host resolver there is no asset store to read, and the styles already draw a
    /// fallback. The contract is that this is silent rather than a crash.
    func testSkinArtworkIsAbsentUntilTheHostSuppliesIt() {
        ThemeAssetStore.resolve = nil
        XCTAssertNil(ThemeAssetStore.image(named: "titlebar", for: .system))
    }
}

/// The handoff is the claim that a plugin gets the host's theme *exactly*, rather than a handful
/// of sampled tokens. That is worth proving rather than asserting, because the two sides compile
/// their own `AppTheme` and only the encoding is shared.
final class HostThemeHandoffTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.install(AppThemeStyles.threading)
        super.tearDown()
    }

    /// A theme crosses as a colour hex per role, so it arrives quantised to 8 bits and without
    /// the wide-gamut marker the catalogue colour carried — measured at 0.878433 → 0.878431, which
    /// is a difference no display resolves. Identity and material cross exactly; colour crosses to
    /// the precision a hex can carry, and this says so rather than asserting a struct equality that
    /// would fail on the seventh decimal.
    @MainActor
    func testEveryStockThemeCrossesWithItsIdentityMaterialAndColoursIntact() throws {
        let hexStep = 1.0 / 255.0
        for theme in AppThemeStyles.all {
            AppThemePalette.install(theme)
            let encoded = try HostThemeHandoff.encodeCurrent()
            AppThemePalette.install(AppThemeStyles.threading)   // a plugin starts on the stock one
            let arrived = try HostThemeHandoff.install(encoded: encoded)

            XCTAssertEqual(arrived.id, theme.id)
            XCTAssertEqual(arrived.name, theme.name)
            XCTAssertEqual(arrived.mode, theme.mode)
            XCTAssertEqual(Set(arrived.variants.keys), Set(theme.variants.keys), "\(theme.id)")
            for (kind, variant) in theme.variants {
                let crossed = try XCTUnwrap(arrived.variants[kind], "\(theme.id) lost its \(kind)")
                XCTAssertEqual(crossed.material, variant.material, "\(theme.id) \(kind) material")
                XCTAssertEqual(Set(crossed.roles.keys), Set(variant.roles.keys), "\(theme.id) \(kind)")
                for (role, colour) in variant.roles {
                    let a = try XCTUnwrap(crossed.roles[role]?.usingColorSpace(.sRGB))
                    let b = try XCTUnwrap(colour.usingColorSpace(.sRGB))
                    XCTAssertEqual(a.redComponent, b.redComponent, accuracy: hexStep, "\(theme.id) \(role)")
                    XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: hexStep, "\(theme.id) \(role)")
                    XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: hexStep, "\(theme.id) \(role)")
                    XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: hexStep, "\(theme.id) \(role)")
                }
            }
            XCTAssertEqual(AppThemePalette.current.id, theme.id, "the arrived theme is the one in force")
        }
    }

    /// Every role, not just the ones a token payload happens to name — that difference is the
    /// whole reason the handoff carries an encoded theme.
    @MainActor
    func testEveryRoleResolvesTheSameOnBothSides() throws {
        let source = try XCTUnwrap(AppThemeStyles.all.first { $0.id != AppThemeStyles.threading.id })
        AppThemePalette.install(source)
        let expected = AppThemeRole.allCases.map { role in
            AppThemePalette.color(role).usingColorSpace(.sRGB)!.brightnessComponent
        }
        let encoded = try HostThemeHandoff.encodeCurrent()
        AppThemePalette.install(AppThemeStyles.threading)
        try HostThemeHandoff.install(encoded: encoded)
        let actual = AppThemeRole.allCases.map { role in
            AppThemePalette.color(role).usingColorSpace(.sRGB)!.brightnessComponent
        }
        for (index, role) in AppThemeRole.allCases.enumerated() {
            XCTAssertEqual(actual[index], expected[index], accuracy: 1.0 / 255.0,
                           "\(role) resolved differently after the handoff")
        }
    }

    /// A host that could not encode its theme is not a reason to stop drawing.
    func testAnAbsentThemeIsRefusedWithoutDisturbingTheOneInForce() {
        AppThemePalette.install(AppThemeStyles.threading)
        XCTAssertThrowsError(try HostThemeHandoff.install(encoded: nil))
        XCTAssertThrowsError(try HostThemeHandoff.install(encoded: Data("not a theme".utf8)))
        XCTAssertEqual(AppThemePalette.current, AppThemeStyles.threading)
    }
}
