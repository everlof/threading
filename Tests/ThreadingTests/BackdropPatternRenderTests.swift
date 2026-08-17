import AppKit
import XCTest
@testable import Threading

/// The theme's backdrop pattern, and the text drawn on top of it.
///
/// This case exists because that pair had never been looked at. `backdropPattern` promises "a
/// restrained repeating treatment", and every assertion about it checked ranges — opacity in 0...1,
/// spacing in 8...64 — while Neo Brutalism quietly stated `role: .label, opacity: 1` and drew 3pt
/// dots in the body text's own ink on the ground that body text sits on. It was reported from use,
/// on the About window's version pair, and the picture is the only place it was ever visible.
///
/// So there are two halves here: the catalogue sweep that no theme can state its way past, and the
/// renders that are how the next one gets noticed.
@MainActor
final class BackdropPatternRenderTests: XCTestCase {

    private enum Render {

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let width: CGFloat = 420
        static let bandHeight: CGFloat = 76
    }

    // MARK: - The Budget

    /// A mark's weight is its size times its ink, so the invariant is the product — the rule-ink
    /// budget's shape exactly. Swept over the stock catalogue in both appearances.
    func testEveryStockThemeKeepsItsBackdropInkWithinTheBudget() throws {
        var patterned: [String] = []

        for theme in [AppTheme.system] + AppThemeStyles.all {
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                let material = theme.material(for: appearance)
                guard let spec = material.backdropPattern else { continue }
                patterned.append(theme.name)

                let ink = theme.resolved(spec.role, appearance: appearance)
                let authored = (ink.usingColorSpace(.sRGB)?.alphaComponent ?? 1) * spec.opacity
                let drawn = min(authored, material.backdropInkCeiling)

                XCTAssertLessThanOrEqual(
                    drawn * max(1, spec.lineWidth),
                    AppTheme.Material.backdropInkBudget + 0.01,
                    "\(theme.name) (\(appearanceName.rawValue)) marks its backdrop heavier "
                        + "than the budget"
                )
                // Never *raised*: a theme quieter than its ceiling keeps exactly what it states.
                if authored <= material.backdropInkCeiling {
                    XCTAssertEqual(
                        drawn, authored, accuracy: 0.0001,
                        "\(theme.name) (\(appearanceName.rawValue)) had its quiet pattern re-inked"
                    )
                }
            }
        }

        XCTAssertFalse(patterned.isEmpty, "no stock theme authors a backdrop pattern any more")
    }

    /// The cap is the loosest one that fixes the report: it takes Neo Brutalism down and leaves
    /// every other stock pattern at exactly what its author stated. If a future budget change
    /// starts attenuating one of those five, this says so rather than letting it drift.
    func testTheCapTakesNeoBrutalismDownAndLeavesTheOthersAlone() throws {
        var attenuated: [String] = []

        for theme in AppThemeStyles.all {
            let appearance = try XCTUnwrap(NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua))
            let material = theme.material(for: appearance)
            guard let spec = material.backdropPattern else { continue }
            let ink = theme.resolved(spec.role, appearance: appearance)
            let authored = (ink.usingColorSpace(.sRGB)?.alphaComponent ?? 1) * spec.opacity
            if authored > material.backdropInkCeiling + 0.0001 {
                attenuated.append(theme.id.rawValue)
            }
        }

        XCTAssertEqual(attenuated, ["neo-brutalism"])
    }

    /// The measured landing point, kept as a number so the budget and the mark size cannot drift
    /// apart silently: 3pt marks come out at 0.267, which the ladder showed is where the words win
    /// and the dot field is still the theme's own.
    func testNeoBrutalismsDotsLandInTheQuietBand() throws {
        let theme = AppThemeStyles.neoBrutalism
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let material = theme.material(for: appearance)
        let spec = try XCTUnwrap(material.backdropPattern)

        XCTAssertEqual(spec.lineWidth, 3)
        XCTAssertEqual(material.backdropInkCeiling, 0.8 / 3, accuracy: 0.0001)
        XCTAssertLessThan(material.backdropInkCeiling, 0.3)
        XCTAssertGreaterThan(material.backdropInkCeiling, 0.2)
    }

    /// Increase Contrast lifts the rule-ink cap and must not lift this one: a rule is content
    /// beside content, a pattern is behind text, and more ink behind text is strictly worse.
    func testIncreaseContrastDoesNotLiftTheBackdropCap() throws {
        let material = AppThemeStyles.neoBrutalism.material
        let atRest = material.backdropInkCeiling

        Design.Accessibility.increaseContrastOverrideForTesting = true
        defer { Design.Accessibility.increaseContrastOverrideForTesting = nil }

        XCTAssertEqual(material.backdropInkCeiling, atRest)
    }

    // MARK: - Convergence

    /// A converging grid must recede, not fill in.
    ///
    /// Measured on drawn pixels because that is the only place the defect existed: Vaporwave's
    /// marks are inside the ink budget and it still painted a solid accent plate across the bottom
    /// two-thirds of its ground, because the *crowding* fills in rather than the ink. Both halves
    /// are asserted, and the second one is here because the first fix drew the ramp upside down —
    /// which faded the foreground and left the band sitting exactly where it hurt.
    func testTheConvergingGridRecedesInsteadOfFillingIn() throws {
        AppThemePalette.set(AppThemeStyles.vaporwave)
        defer { AppThemePalette.set(.system) }
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        let ground = ThemedSurfaceView()
        ground.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
        ground.frame = NSRect(x: 0, y: 0, width: 420, height: 240)
        ground.appearance = appearance
        AppThemeRefresh.repaint(ground)
        ground.layoutSubtreeIfNeeded()

        var rep: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
            guard let bitmap = ground.bitmapImageRepForCachingDisplay(in: ground.bounds) else {
                return
            }
            ground.cacheDisplay(in: ground.bounds, to: bitmap)
            rep = bitmap
        }
        let bitmap = try XCTUnwrap(rep, "the perspective ground did not draw")

        // The field runs from the bottom up to `height * 0.62`, so in image rows (top-down) the
        // horizon sits at 0.38 of the way down and the foreground is the bottom edge. Above the
        // field is untouched ground, which is the baseline everything else is measured against.
        let baseline = strip(of: bitmap, from: 0.05, to: 0.20)
        let horizon = strip(of: bitmap, from: 0.39, to: 0.45)
        let foreground = strip(of: bitmap, from: 0.92, to: 0.99)
        let clear = baseline.mean + 0.02

        // **Peak ink, deliberately — two more obvious measures were tried and neither separates
        // the plate from the fix.** Mean ink is roughly conserved as the lines converge (many
        // faint lines average to about what a few strong ones do): 0.050 against 0.057. The
        // fraction of the strip still showing ground barely moves either, measured off the two
        // renders: 0.302 against 0.353. What actually changes is how strong the strongest ink at
        // the horizon is, because that is what the ramp takes away — and it is also what made the
        // band unreadable.
        XCTAssertLessThan(
            horizon.peak, foreground.peak * 0.6,
            "the converging grid is not receding: it peaks at \(horizon.peak) on the horizon "
                + "against \(foreground.peak) in the foreground, which is a plate — and a ratio "
                + "above 1 means the ramp is upside down"
        )
        // A pattern that stopped drawing entirely would satisfy the claim above.
        XCTAssertGreaterThan(
            foreground.peak, clear + 0.02,
            "the perspective grid drew nothing at all in the foreground"
        )
    }

    private struct Strip {
        let mean: Double
        let peak: Double
    }

    /// Brightness over a horizontal band, as 0...1. Vaporwave draws a bright accent on a near-black
    /// ground, so brighter means more pattern.
    private func strip(of bitmap: NSBitmapImageRep, from: Double, to: Double) -> Strip {
        let first = Int(Double(bitmap.pixelsHigh) * from)
        let last = min(bitmap.pixelsHigh - 1, Int(Double(bitmap.pixelsHigh) * to))
        guard last >= first else { return Strip(mean: 0, peak: 0) }

        var samples: [Double] = []
        for y in first...last {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                samples.append(
                    Double(colour.redComponent + colour.greenComponent + colour.blueComponent) / 3
                )
            }
        }
        return Strip(
            mean: samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count),
            peak: samples.max() ?? 0
        )
    }

    // MARK: - Images

    /// Text on each patterned theme's ground, at the two sizes that actually sit there — the About
    /// window's version pair and a detail line. This is the picture the bug was reported from.
    func testRendersTextOverEveryPatternedThemesGround() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        var written = 0
        for theme in AppThemeStyles.all where theme.material.backdropPattern != nil {
            AppThemePalette.set(theme)
            let appearance = try XCTUnwrap(
                NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            )
            let band = self.band()
            band.appearance = appearance
            AppThemeRefresh.repaint(band)
            band.layoutSubtreeIfNeeded()

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                guard let rep = band.bitmapImageRepForCachingDisplay(in: band.bounds) else { return }
                band.cacheDisplay(in: band.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
            let url = directory.appendingPathComponent("backdrop-\(theme.id.rawValue).png")
            try XCTUnwrap(data, "no render for \(theme.name)").write(to: url)
            XCTAssertEqual(ThemeBoundaryAudit.violations(in: band), [])
            written += 1
        }

        print("Rendered \(written) backdrop bands to \(directory.path)")
        XCTAssertGreaterThanOrEqual(written, 6)
    }

    // MARK: - Helpers

    private func band() -> NSView {
        let ground = ThemedSurfaceView()
        ground.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)

        let reading = NSTextField(labelWithString: "1.4.0 (212)")
        reading.applyFont(.numericBody)
        reading.textColor = Design.Text.secondary

        let detail = NSTextField(labelWithString: "Architecture    arm64")
        detail.applyFont(.detail())
        detail.textColor = Design.Text.secondary

        let rows = NSStackView(views: [reading, detail])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Design.Spacing.small
        rows.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(rows)

        NSLayoutConstraint.activate([
            ground.widthAnchor.constraint(equalToConstant: Render.width),
            ground.heightAnchor.constraint(equalToConstant: Render.bandHeight),
            rows.leadingAnchor.constraint(
                equalTo: ground.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            rows.centerYAnchor.constraint(equalTo: ground.centerYAnchor)
        ])
        ground.layoutSubtreeIfNeeded()
        return ground
    }
}
