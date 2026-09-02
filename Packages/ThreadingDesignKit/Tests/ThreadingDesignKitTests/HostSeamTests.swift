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
