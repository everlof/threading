import AppKit
import XCTest
@testable import Threading

/// Draws the generated Dock icon under every stock theme and writes the contact sheet out.
///
/// The same reason the other render tests exist: whether the chevron still reads at 16pt on
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

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
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
                    "\(theme.name)'s chevron does not read on its own plate"
                )
            }
        }
    }

    /// 16pt is the switcher's smallest rendition and where a mark stops being a mark. Asserted
    /// rather than eyeballed because the contact sheet is drawn large.
    func testTheChevronSurvivesTheSmallestDockSize() throws {
        for theme in AppThemeLibrary.stock where theme.id != .system {
            let appearance = try XCTUnwrap(appearances(for: theme).first)
            let image = try XCTUnwrap(GeneratedAppIcon.image(for: theme, appearance: appearance))
            let raster = try XCTUnwrap(rasterize(image, side: Render.smallestDockSide))
            let ground = try XCTUnwrap(sample(raster, at: Render.groundSample))

            XCTAssertGreaterThan(
                strongestContrast(in: raster, against: ground), 1.5,
                "\(theme.name)'s chevron dissolves into its plate at 16pt"
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

        // Compared across the whole raster rather than at one point: where the chevron's ink
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
    /// Pinned because the two coordinate systems disagree and nothing else would notice.
    /// `Design.applyThemeGlow` hands the theme's `offsetY: -4` to `CALayer.shadowOffset`, whose
    /// y is up, so the lift lands below the panel. `NSShadow` in this drawing context resolves
    /// the same number the other way, and the first render put Bauhaus's black chevron above
    /// its red one — a picture that reads as two marks rather than one lifted off the page.
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

    // MARK: - A Contributed Mark

    /// A contributed theme's mark replaces the chevron — and the plate stays the theme's.
    ///
    /// The second assertion is the one that matters: an extension supplies a glyph, never a
    /// tile, so whatever it ships the icon's ground is still the ground the theme states.
    /// `ExtensionBundleLoader` refuses an opaque mark at inspection; this checks the drawing
    /// half of the same rule.
    func testAContributedMarkReplacesTheChevronButNotThePlate() throws {
        let theme = AppThemeStyles.cyberpunk
        let appearance = try XCTUnwrap(theme.mode.appearance)
        let recipe = try XCTUnwrap(GeneratedAppIcon.Recipe(theme: theme, appearance: appearance))

        let withChevron = try XCTUnwrap(
            GeneratedAppIcon.image(for: theme, appearance: appearance, mark: nil)
        )
        let withMark = try XCTUnwrap(
            GeneratedAppIcon.image(for: theme, appearance: appearance, mark: squareMark())
        )

        let chevronRaster = try XCTUnwrap(rasterize(withChevron, side: Render.sheetSide))
        let markRaster = try XCTUnwrap(rasterize(withMark, side: Render.sheetSide))

        XCTAssertGreaterThan(
            meanDifference(chevronRaster, markRaster), 0.01,
            "the contributed mark did not replace the chevron"
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

    /// The phone's icon is drawn by `scripts/generate_mobile_app_icon.swift`, which restates the
    /// chevron because it is not part of the app target. Restated geometry drifts; this is what
    /// stops it. The script is read as text on purpose — it is the artefact that has to agree,
    /// and compiling it into the test would prove something about a copy of it instead.
    func testThePhoneIconRestatesTheSameChevron() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/generate_mobile_app_icon.swift")
        let source = try String(contentsOf: script, encoding: .utf8)

        let expected: [String: CGFloat] = [
            "strokeRatio": GeneratedAppIcon.Layout.strokeRatio,
            "armX": GeneratedAppIcon.Layout.armX,
            "armTopY": GeneratedAppIcon.Layout.armTopY,
            "armBottomY": GeneratedAppIcon.Layout.armBottomY,
            "apexY": GeneratedAppIcon.Layout.apexY,
            "apexX": GeneratedAppIcon.Layout.apexXRound
        ]

        for (name, value) in expected {
            let pattern = "static let \(name): CGFloat = ([0-9.]+)"
            let match = try XCTUnwrap(
                source.range(of: pattern, options: .regularExpression),
                "\(name) is not stated in the phone's generator"
            )
            let stated = try XCTUnwrap(
                Double(source[match].split(separator: "=")[1].trimmingCharacters(in: .whitespaces))
            )
            XCTAssertEqual(
                CGFloat(stated), value, accuracy: 0.0001,
                "the phone's \(name) has drifted from the Mac's"
            )
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
