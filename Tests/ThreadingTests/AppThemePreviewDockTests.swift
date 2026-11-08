import AppKit
import XCTest
@testable import Threading

/// `preview_app_theme` ends with the theme's Dock tile, because the icon was the one part of a
/// theme its author could not see: a logo standing at a quarter of its plate, and a brown mark on
/// a brown-black plate, were both invisible from the sample window.
@MainActor
final class AppThemePreviewDockTests: XCTestCase {

    private var storedThemeID: AppThemeID?

    override func tearDown() async throws {
        if let storedThemeID { ThemeAssetStore.removeAll(for: storedThemeID) }
        try await super.tearDown()
    }

    func testEachAppearanceGetsItsTileAtTheSampleWindowsWidth() throws {
        let theme = AppThemeStyles.win98
        let kinds = theme.availableVariants
        let strips = AppThemePreviewService.dockStrips(theme, kinds: kinds)
        let window = try XCTUnwrap(AppThemePreviewService.render(theme, kinds: [try XCTUnwrap(kinds.first)]))

        XCTAssertEqual(strips.map(\.kind), kinds)
        XCTAssertEqual(strips.first?.image.width, window.width, "the strip stacks flush under the window")
        XCTAssertEqual(strips.first?.usesThemeMark, false, "a stock style draws the Threading mark")
        XCTAssertEqual(strips.first?.isRimmed, false)
    }

    func testTheSystemThemeHasNoGeneratedTile() {
        XCTAssertTrue(
            AppThemePreviewService.dockStrips(.system, kinds: AppTheme.VariantKind.allCases).isEmpty,
            "System wears the bundle's own icon, which the preview does not invent"
        )
    }

    /// A theme's own logo that disappears into its plate is drawn rimmed and said to be.
    func testAVanishingThemeLogoIsShownRimmed() throws {
        let base = try XCTUnwrap(AppThemeStyles.all.first { $0.availableVariants == [.dark] })
        let appearance = try XCTUnwrap(AppTheme.VariantKind.dark.appearance)
        let id = AppThemeID("custom-preview-dock-\(UUID().uuidString.lowercased())")
        storedThemeID = id
        let ground = base.resolved(.ground, appearance: appearance)
        let png = try XCTUnwrap(Self.diskPNG(side: 512, colour: ground))
        let asset = try XCTUnwrap(ThemeAssetStore.store(imageData: png, for: id, slot: .logo, variant: .dark))

        let variant = try XCTUnwrap(base.variant(.dark)).replacingSidebar(SidebarStyle(
            brand: SidebarStyle.Brand(logo: .asset(asset), dockIcon: true)
        ))
        let theme = AppTheme(id: id, name: "Preview Dock", mode: .dark, summary: "", variants: [.dark: variant])

        let strip = try XCTUnwrap(AppThemePreviewService.dockStrips(theme, kinds: [.dark]).first)
        XCTAssertTrue(strip.usesThemeMark)
        XCTAssertTrue(strip.isRimmed, "a logo in the plate's own colour must be rimmed")
    }

    // MARK: - Private Methods

    private static func diskPNG(side: Int, colour: NSColor) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor((colour.usingColorSpace(.sRGB) ?? colour).cgColor)
        let inset = CGFloat(side) * 0.1
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: inset, dy: inset))
        return context.makeImage().flatMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
        }
    }
}
