import AppKit
import XCTest
@testable import Threading

/// Draws the generated Dock icon under every stock theme and writes the contact sheet out.
///
/// The same reason the other render tests exist: whether the Threading mark still reads at 16pt on
/// Newsprint's beige, or whether Bauhaus's hard printed shadow lands on the plate or hangs off
/// its corner, is a question about a picture. The assertions here cover what a picture cannot —
/// that the ink is legible on its own ground, that the System theme leaves the bundle icon
/// alone, and that a custom theme edited to new colours is not served its old cache entry.
@MainActor
final class AppIconRenderTests: XCTestCase {

    private enum Render {
        /// The canvas, and the sizes the Dock and the switcher actually draw at.
        static let sheetSide = 256
        static let smallestDockSide = 16

        /// A point on the plate's left edge at half height — inside the straight section rather
        /// than the corner arc, and 227pt from the nearest ink on a 1024 canvas, which clears the
        /// widest glow any theme states (86pt) with room to spare. The obvious corner sample sits
        /// *outside* the rounded plate and reads its drop shadow.
        static let groundSample = CGPoint(x: 0.13, y: 0.5)

        /// The phone's copy is written at the size iOS compiles, not at contact-sheet size: the
        /// packager used to upscale a 256px Dock render four times, and the softness showed.
        static let phoneSide = 1024

        /// The outer band of a phone icon, per edge, that has to be the ground and nothing else.
        /// Six percent is well outside the safe zone's margin the widest themed glow can reach
        /// into, and well inside the ring the Dock's plate shadow used to leave.
        static let phoneEdgeBandRatio: CGFloat = 0.06
        /// How far a band pixel may drift from the ground, in summed sRGB channel difference: a
        /// rounding trip through the raster's colour space, never a shadow.
        static let flatGroundTolerance: CGFloat = 0.02

        /// How far a theme icon's ink may stray, per edge, from where the primary icon's ink
        /// lands — as a fraction of the tile. A printed lift or a halo moves an edge a few
        /// pixels; the quarter-size mark the phone used to get moved it a hundred.
        static let phoneMarkExtentTolerance: CGFloat = 0.03

        /// Seven percent in from an edge, at half width: outside the plate, which ends ten
        /// percent in, and inside the reach of its shadow's blur — so the margin below the plate
        /// reads the shadow and the margin above it reads nothing.
        static let plateShadowSample: CGFloat = 0.07

        static var phoneDirectory: URL {
            directory.appendingPathComponent("phone", isDirectory: true)
        }

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    // MARK: - Behaviour

    func testSystemThemeKeepsTheBundleIcon() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))

        XCTAssertNil(
            GeneratedAppIcon.image(for: .system, appearance: appearance),
            "System asks for the platform's answer, which is the shipped Icon Composer document"
        )
    }

    func testEveryStyleDrawsAnIconOnItsOwnGround() throws {
        for theme in AppThemeLibrary.stock where theme.id != .system {
            for appearance in try appearances(for: theme) {
                let image = try XCTUnwrap(
                    GeneratedAppIcon.image(for: theme, appearance: appearance),
                    "\(theme.name) drew no icon"
                )
                let raster = try XCTUnwrap(rasterize(image, side: Render.sheetSide))
                let drawn = try XCTUnwrap(sample(raster, at: Render.groundSample))

                var expected = NSColor.black
                appearance.performAsCurrentDrawingAppearance {
                    expected = theme.resolved(.ground, appearance: appearance)
                }

                XCTAssertLessThan(
                    difference(drawn, expected), 0.05,
                    "\(theme.name)'s plate is not its own ground"
                )
            }
        }
    }

    /// The floor `GeneratedAppIcon` puts under the accent, checked against the pixels that were
    /// actually drawn rather than against the colour that was asked for.
    func testTheInkReadsAgainstItsGroundInEveryStyle() throws {
        for theme in AppThemeLibrary.stock where theme.id != .system {
            for appearance in try appearances(for: theme) {
                let image = try XCTUnwrap(
                    GeneratedAppIcon.image(for: theme, appearance: appearance)
                )
                let raster = try XCTUnwrap(rasterize(image, side: Render.sheetSide))
                let ground = try XCTUnwrap(sample(raster, at: Render.groundSample))

                XCTAssertGreaterThanOrEqual(
                    strongestContrast(in: raster, against: ground),
                    ThemeContrast.minimumRatio,
                    "\(theme.name)'s mark does not read on its own plate"
                )
            }
        }
    }

    /// 16pt is the switcher's smallest rendition and where a mark stops being a mark. Asserted
    /// rather than eyeballed because the contact sheet is drawn large.
    func testTheMarkSurvivesTheSmallestDockSize() throws {
        for theme in AppThemeLibrary.stock where theme.id != .system {
            let appearance = try XCTUnwrap(appearances(for: theme).first)
            let image = try XCTUnwrap(GeneratedAppIcon.image(for: theme, appearance: appearance))
            let raster = try XCTUnwrap(rasterize(image, side: Render.smallestDockSide))
            let ground = try XCTUnwrap(sample(raster, at: Render.groundSample))

            XCTAssertGreaterThan(
                strongestContrast(in: raster, against: ground), 1.5,
                "\(theme.name)'s mark dissolves into its plate at 16pt"
            )
        }
    }

    /// The cache is keyed by the colours drawn, not by the theme's identity — a custom theme
    /// keeps its id across an edit, and an id-keyed cache would serve the palette the user just
    /// changed away from.
    func testAnEditedCustomThemeIsNotServedItsOldIcon() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let id = AppThemeID("test-edited-custom")

        func theme(accent: NSColor) -> AppTheme {
            AppTheme(
                id: id,
                name: "Edited",
                mode: .dark,
                summary: nil,
                roles: [.ground: NSColor(hex: "#101014") ?? .black, .accent: accent]
            )
        }

        let before = try XCTUnwrap(
            GeneratedAppIcon.image(for: theme(accent: .systemGreen), appearance: appearance)
        )
        let after = try XCTUnwrap(
            GeneratedAppIcon.image(for: theme(accent: .systemOrange), appearance: appearance)
        )

        // Compared across the whole raster rather than at one point: where the mark's ink
        // falls depends on the join, and a probe aimed at the plate's centre lands just inside
        // the vertex's *inner* edge — reading the ground from both, which is a pass by accident.
        let first = try XCTUnwrap(rasterize(before, side: Render.sheetSide))
        let second = try XCTUnwrap(rasterize(after, side: Render.sheetSide))

        XCTAssertGreaterThan(
            meanDifference(first, second), 0.01,
            "the edited theme was served its previous icon"
        )
    }

    /// A printed style's lift falls **down** and to the right, the way the chrome casts it.
    ///
    /// Pinned because the sign has flipped twice and nothing else would notice.
    /// `Design.applyThemeGlow` hands the theme's `offsetY: -4` to `CALayer.shadowOffset`, whose
    /// y is up, so the lift lands below the panel. An `NSImage` drawing handler resolved the
    /// same number the other way — the first render put Bauhaus's black mark above its red one,
    /// a picture that reads as two marks rather than one lifted off the page — so the renderer
    /// negated it; then drawing into a bitmap context (see `GeneratedAppIcon.draw`) agreed with
    /// the layer again and the negation put the lift back on top. This test caught both.
    func testAPrintedStyleCastsItsLiftDownAndRight() throws {
        let bauhaus = try XCTUnwrap(
            AppThemeLibrary.stock.first { $0.id == AppThemeID("bauhaus") }
        )
        let appearance = try XCTUnwrap(bauhaus.mode.appearance)
        let image = try XCTUnwrap(GeneratedAppIcon.image(for: bauhaus, appearance: appearance))
        let raster = try XCTUnwrap(rasterize(image, side: Render.sheetSide))

        // Asked of the recipe rather than re-derived: the ink is the accent *after* the
        // legibility floor, and the lift is the shadow colour composited over the plate at its
        // own opacity — neither is the role colour the theme wrote down.
        let recipe = try XCTUnwrap(GeneratedAppIcon.Recipe(theme: bauhaus, appearance: appearance))
        let shadow = try XCTUnwrap(recipe.shadow, "Bauhaus states a printed lift")
        let lift = try XCTUnwrap(composite(shadow.color, over: recipe.ground))

        let palette = [recipe.ground, recipe.ink, lift]
        let inkCentre = try XCTUnwrap(
            centroid(in: raster, matching: 1, among: palette), "no ink found"
        )
        let liftCentre = try XCTUnwrap(
            centroid(in: raster, matching: 2, among: palette), "no lift found"
        )

        // Raster coordinates: y grows downward, so "below" is a larger y.
        XCTAssertGreaterThan(
            liftCentre.x, inkCentre.x + 2, "the printed lift is not to the right of the mark"
        )
        XCTAssertGreaterThan(
            liftCentre.y, inkCentre.y + 2, "the printed lift is above the mark, not below it"
        )
    }

    /// The plate's own shadow falls **below** the plate, where the Dock puts the one it draws
    /// for a bundle icon.
    ///
    /// Pinned for the reason the printed lift is: the vertical sign of a shadow here depends on
    /// how the icon is drawn, and the plate shadow was stated in the layer's sign while the
    /// icon was an `NSImage` drawing handler, which cast it upward. Nothing noticed on the Mac,
    /// where the margin is transparent; the phone's copy composited it over the ground and
    /// showed a border darker along its top edge than its bottom.
    func testThePlateShadowFallsBelowTheDockIcon() throws {
        let theme = AppThemeStyles.pure
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let image = try XCTUnwrap(GeneratedAppIcon.image(for: theme, appearance: appearance))
        let raster = try XCTUnwrap(rasterize(image, side: Render.sheetSide))

        // In the transparent margin outside the plate, the shadow is the only thing that
        // paints, so its alpha is the measure.
        let below = try XCTUnwrap(
            sample(raster, at: CGPoint(x: 0.5, y: Render.plateShadowSample))
        )
        let above = try XCTUnwrap(
            sample(raster, at: CGPoint(x: 0.5, y: 1 - Render.plateShadowSample))
        )

        XCTAssertGreaterThan(below.alphaComponent, 0.02, "no shadow below the plate")
        XCTAssertGreaterThan(
            below.alphaComponent, above.alphaComponent + 0.02,
            "the plate's shadow is cast upward"
        )
    }

    // MARK: - The Phone Grid

    /// The phone's copy is the ground to every edge — no plate, no rounding, no shadow — with
    /// the mark still on it.
    ///
    /// iOS masks the tile itself and draws nothing under it, so anything the renderer puts in
    /// the margin ends up *inside* the squircle. The Dock form's drop shadow did exactly that:
    /// composited over a white ground it was a grey ring around a smaller plate, which is not
    /// what a theme called Pure looks like.
    func testThePhoneIconIsItsGroundToEveryEdge() throws {
        for theme in AppThemeLibrary.stock where theme.id != .system {
            for appearance in try appearances(for: theme) {
                let image = try XCTUnwrap(
                    GeneratedAppIcon.phoneImage(for: theme, appearance: appearance),
                    "\(theme.name) drew no phone icon"
                )
                let raster = try XCTUnwrap(rasterize(image, side: Render.sheetSide))

                var ground = NSColor.black
                appearance.performAsCurrentDrawingAppearance {
                    ground = theme.resolved(.ground, appearance: appearance)
                }

                assertEdgeBandIsGround(raster, ground: ground, label: theme.name)
                XCTAssertGreaterThanOrEqual(
                    strongestContrast(in: raster, against: ground),
                    ThemeContrast.minimumRatio,
                    "\(theme.name)'s mark does not read on the phone"
                )
            }
        }
    }

    // MARK: - A Contributed Mark

    /// A contributed theme's mark replaces the default mark — and the plate stays the theme's.
    ///
    /// The second assertion is the one that matters: an extension supplies a glyph, never a
    /// tile, so whatever it ships the icon's ground is still the ground the theme states.
    /// `ExtensionBundleLoader` refuses an opaque mark at inspection; this checks the drawing
    /// half of the same rule.
    func testAContributedMarkReplacesTheDefaultMarkButNotThePlate() throws {
        let theme = AppThemeStyles.cyberpunk
        let appearance = try XCTUnwrap(theme.mode.appearance)
        let recipe = try XCTUnwrap(GeneratedAppIcon.Recipe(theme: theme, appearance: appearance))

        let withDefaultMark = try XCTUnwrap(
            GeneratedAppIcon.image(for: theme, appearance: appearance, mark: nil)
        )
        let withMark = try XCTUnwrap(
            GeneratedAppIcon.image(for: theme, appearance: appearance, mark: squareMark())
        )

        let defaultMarkRaster = try XCTUnwrap(
            rasterize(withDefaultMark, side: Render.sheetSide)
        )
        let markRaster = try XCTUnwrap(rasterize(withMark, side: Render.sheetSide))

        XCTAssertGreaterThan(
            meanDifference(defaultMarkRaster, markRaster), 0.01,
            "the contributed mark did not replace the default mark"
        )

        let plate = try XCTUnwrap(sample(markRaster, at: Render.groundSample))
        XCTAssertLessThan(
            difference(plate, recipe.ground), 0.05,
            "the contributed mark took over the plate, which is the theme's to state"
        )
    }

    /// An oversized mark is fitted inside the plate rather than bleeding to its edge — the
    /// margin is what keeps a contributed tile reading as the same kind of icon as a stock one.
    func testAnOversizedMarkIsHeldInsideThePlate() throws {
        let theme = AppThemeStyles.cyberpunk
        let appearance = try XCTUnwrap(theme.mode.appearance)
        let recipe = try XCTUnwrap(GeneratedAppIcon.Recipe(theme: theme, appearance: appearance))

        let huge = squareMark(side: 4096)
        let image = try XCTUnwrap(
            GeneratedAppIcon.image(for: theme, appearance: appearance, mark: huge)
        )
        let raster = try XCTUnwrap(rasterize(image, side: Render.sheetSide))

        // Just inside the plate's straight left edge: still the theme's ground, whatever the
        // mark's own dimensions were.
        let edge = try XCTUnwrap(sample(raster, at: Render.groundSample))
        XCTAssertLessThan(
            difference(edge, recipe.ground), 0.05,
            "an oversized mark reached the plate's edge"
        )
    }

    /// A filled square in a colour no stock theme states, so it cannot be confused with a
    /// plate or an accent when the pixels are classified.
    private func squareMark(side: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.insetBy(dx: side * 0.2, dy: side * 0.2).fill()
            return true
        }
    }

    // MARK: - The Phone's Copy

    /// The primary iOS icon keeps the canonical plate and ink, but holds the mark inside the
    /// platform safe zone. Pin both facts: a stale hand-copied full-bleed raster crowds the icon,
    /// while a transparent or recoloured edge stops behaving like an app-icon plate.
    func testThePhoneIconKeepsCanonicalBrandInkInsideItsSafeZone() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let canonical = repository.appendingPathComponent(
            "Brand/ThreadingMark-Navy-1024.png"
        )
        let mobile = repository.appendingPathComponent(
            "Sources/ThreadingMobile/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
        )

        let canonicalRaster = try XCTUnwrap(
            NSBitmapImageRep(data: Data(contentsOf: canonical))
        )
        let mobileRaster = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: mobile)))
        XCTAssertEqual(mobileRaster.pixelsWide, 1024)
        XCTAssertEqual(mobileRaster.pixelsHigh, 1024)

        let ground = try XCTUnwrap(canonicalRaster.colorAt(x: 0, y: 0))
        for point in [
            CGPoint(x: 0.02, y: 0.5),
            CGPoint(x: 0.5, y: 0.02),
            CGPoint(x: 0.98, y: 0.5),
            CGPoint(x: 0.5, y: 0.98),
        ] {
            let pixel = try XCTUnwrap(sample(mobileRaster, at: point))
            XCTAssertLessThan(
                difference(pixel, ground), 0.02,
                "the canonical navy safe zone was lost at \(point)"
            )
        }

        let centre = try XCTUnwrap(sample(mobileRaster, at: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertGreaterThan(
            difference(centre, ground), 0.25,
            "the canonical Threading ink disappeared from the mobile icon"
        )
    }

    func testEveryStockStyleHasASelectablePhoneIcon() throws {
        let suffixByThemeID: [String: String] = [
            "threading": "Threading",
            "editorial": "Editorial",
            "cyberpunk": "Cyberpunk",
            "swiss-minimalist": "SwissMinimalist",
            "bauhaus": "Bauhaus",
            "art-deco": "ArtDeco",
            "neo-brutalism": "NeoBrutalism",
            "claymorphism": "Claymorphism",
            "vaporwave": "Vaporwave",
            "newsprint": "Newsprint",
            "botanical": "Botanical",
            "industrial": "Industrial",
            "pure": "Pure",
            "cappuccino": "Cappuccino",
            "solarized": "Solarized",
            "nord": "Nord",
            "dracula": "Dracula",
            "platinum-9": "Platinum",
            "aqua-cheetah": "Aqua",
            "aqua-tiger": "Tiger",
            "beos-r5": "BeOS",
            "openstep-42": "OpenStep",
            "irix-indigo-magic": "IRIX",
            "amiga-workbench-31": "Amiga",
            "retro-98": "Windows98",
            "tui": "TUI",
            "classic-player": "ClassicPlayer",
            "christmas": "Christmas",
        ]
        let stockIDs = Set(
            AppThemeLibrary.stock.filter { $0.id != .system }.map(\.id.rawValue)
        )
        XCTAssertEqual(stockIDs, Set(suffixByThemeID.keys))

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assets = repository.appendingPathComponent(
            "Sources/ThreadingMobile/Assets.xcassets",
            isDirectory: true
        )
        let project = try String(contentsOf: repository.appendingPathComponent(
            "Threading.xcodeproj/project.pbxproj"
        ))

        let picker = try String(contentsOf: repository.appendingPathComponent(
            "Sources/ThreadingMobile/MobileSettingsView.swift"
        ))

        // Where the brand mark's ink lands on the primary icon; a theme's mark lands there too.
        let primary = try XCTUnwrap(NSImage(contentsOf: assets
            .appendingPathComponent("AppIcon.appiconset")
            .appendingPathComponent("AppIcon-1024.png")))
        let primaryRaster = try XCTUnwrap(rasterize(primary, side: Render.sheetSide))
        let primaryGround = try XCTUnwrap(primaryRaster.colorAt(x: 0, y: 0))
        let primaryInk = try XCTUnwrap(inkBounds(in: primaryRaster, against: primaryGround))

        for (themeID, suffix) in suffixByThemeID {
            let assetName = "AppIconTheme\(suffix)"
            let iconSet = assets.appendingPathComponent("\(assetName).appiconset")
            let icon = iconSet.appendingPathComponent("AppIcon-1024.png")
            let preview = assets
                .appendingPathComponent("AppIconPreview\(suffix).imageset")
                .appendingPathComponent("AppIconPreview\(suffix)-256.png")
            let iconRaster = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: icon)))
            let previewRaster = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: preview)))

            XCTAssertEqual(iconRaster.pixelsWide, 1024, themeID)
            XCTAssertEqual(iconRaster.pixelsHigh, 1024, themeID)
            XCTAssertEqual(previewRaster.pixelsWide, 256, themeID)
            XCTAssertEqual(previewRaster.pixelsHigh, 256, themeID)
            XCTAssertTrue(project.contains(assetName), "\(assetName) is not registered")
            XCTAssertTrue(
                picker.contains("themed(\"\(themeID)\""),
                "\(themeID) is compiled into the phone but not offered by its icon picker"
            )

            // The shipped bytes, not the renderer: a regeneration from a regressed renderer,
            // or a stale set nobody regenerated, fails here.
            var variants = [icon]
            let dark = iconSet.appendingPathComponent("AppIcon-1024-dark.png")
            if FileManager.default.fileExists(atPath: dark.path) { variants.append(dark) }
            for variant in variants {
                let label = "\(themeID) \(variant.lastPathComponent)"
                let image = try XCTUnwrap(NSImage(contentsOf: variant), label)
                let raster = try XCTUnwrap(rasterize(image, side: Render.sheetSide))
                let ground = try XCTUnwrap(raster.colorAt(x: 0, y: 0))

                assertEdgeBandIsGround(raster, ground: ground, label: label)

                let ink = try XCTUnwrap(inkBounds(in: raster, against: ground), "\(label) has no ink")
                let tolerance = CGFloat(Render.sheetSide) * Render.phoneMarkExtentTolerance
                XCTAssertLessThanOrEqual(
                    abs(ink.minX - primaryInk.minX), tolerance,
                    "\(label)'s mark is not the primary icon's size or place (left edge)"
                )
                XCTAssertLessThanOrEqual(
                    abs(ink.maxX - primaryInk.maxX), tolerance,
                    "\(label)'s mark is not the primary icon's size or place (right edge)"
                )
                XCTAssertLessThanOrEqual(
                    abs(ink.minY - primaryInk.minY), tolerance,
                    "\(label)'s mark is not the primary icon's size or place (top edge)"
                )
                XCTAssertLessThanOrEqual(
                    abs(ink.maxY - primaryInk.maxY), tolerance,
                    "\(label)'s mark is not the primary icon's size or place (bottom edge)"
                )
            }
        }
    }

    // MARK: - Render

    func testRendersTheIconUnderEveryStockStyle() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [String] = []
        for theme in AppThemeLibrary.stock where theme.id != .system {
            for (suffix, appearance) in try namedAppearances(for: theme) {
                let image = try XCTUnwrap(
                    GeneratedAppIcon.image(for: theme, appearance: appearance)
                )
                let raster = try XCTUnwrap(rasterize(image, side: Render.sheetSide))
                let data = try XCTUnwrap(raster.representation(using: .png, properties: [:]))

                let name = suffix.isEmpty
                    ? "appicon-\(theme.id.rawValue).png"
                    : "appicon-\(theme.id.rawValue)-\(suffix).png"
                try data.write(to: directory.appendingPathComponent(name))
                written.append(name)
            }
        }

        print("Rendered \(written.count) app icons to \(directory.path)")
        XCTAssertFalse(written.isEmpty)
    }

    /// The renders `scripts/generate_mobile_theme_icons.sh` packages into the phone's asset
    /// catalogue: every stock style on the phone grid, at the size iOS compiles.
    func testRendersThePhoneIconUnderEveryStockStyle() throws {
        let directory = Render.phoneDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [String] = []
        for theme in AppThemeLibrary.stock where theme.id != .system {
            for (suffix, appearance) in try namedAppearances(for: theme) {
                let image = try XCTUnwrap(
                    GeneratedAppIcon.phoneImage(for: theme, appearance: appearance)
                )
                let raster = try XCTUnwrap(rasterize(image, side: Render.phoneSide))
                let data = try XCTUnwrap(raster.representation(using: .png, properties: [:]))

                let name = suffix.isEmpty
                    ? "appicon-\(theme.id.rawValue).png"
                    : "appicon-\(theme.id.rawValue)-\(suffix).png"
                try data.write(to: directory.appendingPathComponent(name))
                written.append(name)
            }
        }

        print("Rendered \(written.count) phone app icons to \(directory.path)")
        XCTAssertFalse(written.isEmpty)
    }

    // MARK: - Helpers

    private func appearances(for theme: AppTheme) throws -> [NSAppearance] {
        try namedAppearances(for: theme).map(\.appearance)
    }

    /// Adaptive styles are drawn under both appearances; a fixed style only under its own.
    private func namedAppearances(
        for theme: AppTheme
    ) throws -> [(suffix: String, appearance: NSAppearance)] {
        if theme.isAdaptive {
            return [
                ("light", try XCTUnwrap(NSAppearance(named: .aqua))),
                ("dark", try XCTUnwrap(NSAppearance(named: .darkAqua)))
            ]
        }
        return [("", try XCTUnwrap(theme.mode.appearance))]
    }

    private func rasterize(_ image: NSImage, side: Int) -> NSBitmapImageRep? {
        guard let raster = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        raster.size = NSSize(width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: raster)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return raster
    }

    private func sample(_ raster: NSBitmapImageRep, at point: CGPoint) -> NSColor? {
        let x = Int(CGFloat(raster.pixelsWide) * point.x)
        let y = Int(CGFloat(raster.pixelsHigh) * (1 - point.y))
        return raster.colorAt(x: min(x, raster.pixelsWide - 1), y: min(y, raster.pixelsHigh - 1))?
            .usingColorSpace(.sRGB)
    }

    /// Every pixel in the outer `phoneEdgeBandRatio` of the raster is `ground`, within a colour
    /// space round trip.
    private func assertEdgeBandIsGround(
        _ raster: NSBitmapImageRep,
        ground: NSColor,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let band = Int((CGFloat(raster.pixelsWide) * Render.phoneEdgeBandRatio).rounded(.up))
        var worst: (difference: CGFloat, x: Int, y: Int) = (0, 0, 0)
        for y in 0..<raster.pixelsHigh {
            for x in 0..<raster.pixelsWide {
                let inBand = x < band || y < band
                    || x >= raster.pixelsWide - band || y >= raster.pixelsHigh - band
                guard inBand, let pixel = raster.colorAt(x: x, y: y) else { continue }
                let drift = difference(pixel, ground)
                if drift > worst.difference { worst = (drift, x, y) }
            }
        }
        XCTAssertLessThan(
            worst.difference, Render.flatGroundTolerance,
            "\(label) is not its ground at its edge: (\(worst.x), \(worst.y)) drifts by "
                + "\(worst.difference) — a plate shadow or a border inside the phone's mask",
            file: file,
            line: line
        )
    }

    /// The bounding box of every pixel that reads as ink — `ThemeContrast.minimumRatio` or
    /// more against `ground` — in raster coordinates, or nil where nothing does.
    private func inkBounds(in raster: NSBitmapImageRep, against ground: NSColor) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<raster.pixelsHigh {
            for x in 0..<raster.pixelsWide {
                guard let pixel = raster.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      pixel.alphaComponent > 0.9,
                      ThemeContrast.ratio(pixel, ground) >= ThemeContrast.minimumRatio
                else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The highest contrast ratio any pixel in the icon reaches against its own plate — the
    /// measure of "there is ink here", independent of where the mark happens to be drawn.
    private func strongestContrast(in raster: NSBitmapImageRep, against ground: NSColor) -> CGFloat {
        var strongest: CGFloat = 1
        for y in stride(from: 0, to: raster.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: raster.pixelsWide, by: 1) {
                guard let pixel = raster.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      pixel.alphaComponent > 0.9 else { continue }
                strongest = max(strongest, ThemeContrast.ratio(pixel, ground))
            }
        }
        return strongest
    }

    /// `top` drawn over `bottom` at `top`'s own alpha — what a semi-transparent shadow actually
    /// puts on the plate.
    private func composite(_ top: NSColor, over bottom: NSColor) -> NSColor? {
        guard let source = top.usingColorSpace(.sRGB),
              let ground = bottom.usingColorSpace(.sRGB) else { return nil }
        let alpha = source.alphaComponent
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * alpha + b * (1 - alpha) }
        return NSColor(
            srgbRed: mix(source.redComponent, ground.redComponent),
            green: mix(source.greenComponent, ground.greenComponent),
            blue: mix(source.blueComponent, ground.blueComponent),
            alpha: 1
        )
    }

    /// The centre of mass of the pixels whose **nearest** entry in `palette` is `index`, in
    /// raster coordinates — y grows downward.
    ///
    /// Nearest-of-all rather than a tolerance around one colour. A tolerance found nothing: the
    /// raster round-trips through a calibrated colour space, so no pixel is bit-equal to the
    /// colour that was asked for. And a blend of two of the palette's own colours — every
    /// antialiased edge between the mark and the plate — has to be attributed to one of those
    /// two rather than counted as a third shape, which is exactly what nearest-of-all does and
    /// a per-colour tolerance does not.
    private func centroid(
        in raster: NSBitmapImageRep,
        matching index: Int,
        among palette: [NSColor]
    ) -> CGPoint? {
        let references = palette.compactMap { $0.usingColorSpace(.sRGB) }
        guard references.count == palette.count, references.indices.contains(index) else {
            return nil
        }

        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var counted: CGFloat = 0
        for y in 0..<raster.pixelsHigh {
            for x in 0..<raster.pixelsWide {
                guard let pixel = raster.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      pixel.alphaComponent > 0.9 else { continue }
                let distances = references.map { difference(pixel, $0) }
                guard let nearest = distances.enumerated().min(by: { $0.element < $1.element }),
                      nearest.offset == index else { continue }
                sumX += CGFloat(x)
                sumY += CGFloat(y)
                counted += 1
            }
        }
        guard counted > 0 else { return nil }
        return CGPoint(x: sumX / counted, y: sumY / counted)
    }

    /// Mean per-channel difference across two rasters of the same size.
    private func meanDifference(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> CGFloat {
        var total: CGFloat = 0
        var counted = 0
        for y in 0..<min(first.pixelsHigh, second.pixelsHigh) {
            for x in 0..<min(first.pixelsWide, second.pixelsWide) {
                guard let a = first.colorAt(x: x, y: y), let b = second.colorAt(x: x, y: y) else {
                    continue
                }
                total += difference(a, b)
                counted += 1
            }
        }
        return counted == 0 ? 0 : total / CGFloat(counted)
    }

    private func difference(_ first: NSColor, _ second: NSColor) -> CGFloat {
        guard let a = first.usingColorSpace(.sRGB), let b = second.usingColorSpace(.sRGB) else {
            return .greatestFiniteMagnitude
        }
        return abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }
}
