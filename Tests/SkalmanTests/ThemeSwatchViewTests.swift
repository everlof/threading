import AppKit
import XCTest
@testable import Skalman

/// `ThemeSwatchView` is the one place `NSColorWell` still exists — contained rather than
/// replaced, because what it opens is the system colour panel. What is pinned here is the
/// containment (the well is a click target, the swatch is what shows) and the two things about
/// it that have been wrong before: the ring that keeps a dark swatch from reading as a hole, and
/// the recorded surface that keeps the theme sweep from wiping the grid.
@MainActor
final class ThemeSwatchViewTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Helpers

    private func fill(of swatch: ThemeSwatchView) throws -> NSColor {
        let cgColor = try XCTUnwrap(swatch.layer?.backgroundColor, "the swatch drew no fill")
        return try XCTUnwrap(NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB))
    }

    private func well(in swatch: ThemeSwatchView) throws -> NSColorWell {
        try XCTUnwrap(swatch.subviews.compactMap { $0 as? NSColorWell }.first,
                      "the swatch has no colour well")
    }

    // MARK: - Content

    /// The swatch shows the colour it was given, and says which colour it is — the grid has no
    /// column headings on purpose, so the name and hex live in the tooltip.
    func testTheSwatchShowsItsColourAndNamesItInTheTooltip() throws {
        let swatch = ThemeSwatchView()
        swatch.setColor(.systemPurple, name: "bright magenta")

        XCTAssertEqual(swatch.color, .systemPurple)
        XCTAssertEqual(try fill(of: swatch).hexString, NSColor.systemPurple.hexString)

        let tooltip = try XCTUnwrap(swatch.toolTip)
        XCTAssertTrue(tooltip.contains("bright magenta"), "the tooltip does not name the colour")
        XCTAssertTrue(tooltip.contains(NSColor.systemPurple.hexString),
                      "the tooltip does not carry the hex")
    }

    /// The regression this cost once: `applySurface` records what it was given, and init records
    /// `.clear`. A swatch that set its colour any other way kept `.clear` recorded, so the first
    /// app-theme sweep re-applied it and emptied the entire COLORS grid to transparent.
    func testAThemeSweepDoesNotWipeTheSwatchToTransparent() throws {
        let swatch = ThemeSwatchView()
        swatch.setColor(.systemTeal, name: "cyan")

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        swatch.reapplyRecordedSurfaceForTesting()

        XCTAssertEqual(try fill(of: swatch).hexString, NSColor.systemTeal.hexString,
                       "the sweep wiped the swatch back to the `.clear` recorded at init")
    }

    /// Re-assigning the colour the well already holds would fight the shared colour panel while
    /// the user is dragging in it, so the swatch leaves the well alone when nothing changed.
    func testSettingTheSameColourAgainLeavesTheWellUntouched() throws {
        let swatch = ThemeSwatchView()
        let colourWell = try well(in: swatch)

        swatch.setColor(.systemOrange, name: "orange")
        let afterFirst = colourWell.color

        swatch.setColor(.systemOrange, name: "orange")

        XCTAssertEqual(colourWell.color, afterFirst)
    }

    // MARK: - Editability

    /// A built-in theme shows its colours and edits none of them. The well is what makes a
    /// swatch clickable, so hiding it is how read-only is expressed.
    func testTheWellIsPresentOnlyWhileTheSwatchIsEditable() throws {
        let swatch = ThemeSwatchView()
        let colourWell = try well(in: swatch)

        XCTAssertTrue(colourWell.isHidden, "a swatch was editable before being told it was")

        swatch.isEditable = true
        XCTAssertFalse(colourWell.isHidden)

        swatch.isEditable = false
        XCTAssertTrue(colourWell.isHidden)
    }

    /// "A dimmed swatch misreports the palette it is there to display." A read-only swatch shows
    /// its colour at full strength rather than being disabled into a paler version of it.
    func testAReadOnlySwatchStillShowsItsColourAtFullStrength() throws {
        let editable = ThemeSwatchView()
        editable.isEditable = true
        editable.setColor(.systemIndigo, name: "blue")

        let readOnly = ThemeSwatchView()
        readOnly.isEditable = false
        readOnly.setColor(.systemIndigo, name: "blue")

        XCTAssertEqual(try fill(of: readOnly).hexString, try fill(of: editable).hexString,
                       "a read-only swatch drew a different colour from an editable one")
        XCTAssertEqual(readOnly.alphaValue, 1, "a read-only swatch was dimmed")
    }

    // MARK: - Editing

    /// Picking a colour in the panel reports it and becomes the swatch's own colour — the well
    /// is the click target, but the swatch is what the rest of the page reads.
    func testChoosingInTheWellReportsTheColourAndAdoptsIt() throws {
        let swatch = ThemeSwatchView()
        swatch.isEditable = true
        swatch.setColor(.black, name: "black")

        var reported: NSColor?
        swatch.onChange = { reported = $0 }

        let colourWell = try well(in: swatch)
        colourWell.color = .systemGreen
        let action = try XCTUnwrap(colourWell.action)
        _ = (colourWell.target as? NSObject)?.perform(action, with: colourWell)

        XCTAssertEqual(reported?.hexString, NSColor.systemGreen.hexString,
                       "the change was not reported")
        XCTAssertEqual(swatch.color.hexString, NSColor.systemGreen.hexString,
                       "the swatch did not adopt the chosen colour")
        XCTAssertEqual(try fill(of: swatch).hexString, NSColor.systemGreen.hexString,
                       "the swatch did not repaint to the chosen colour")
    }

    // MARK: - The Ring

    /// A theme's `black` on the settings card's own dark ground is very nearly the card, so an
    /// unringed swatch reads as a hole rather than as a value. The ring is the layer's border,
    /// which Core Animation paints above sublayers so the well cannot cover it.
    func testTheSwatchIsRinged() throws {
        let swatch = ThemeSwatchView()
        swatch.setColor(.black, name: "black")

        let layer = try XCTUnwrap(swatch.layer)
        XCTAssertGreaterThan(layer.borderWidth, 0, "the swatch has no ring")
        XCTAssertNotNil(layer.borderColor)
        XCTAssertTrue(layer.masksToBounds, "the well can spill past the swatch's corners")
    }

    /// The ring is a `CGColor` and so resolves once; `updateLayer` is what re-applies it, and
    /// without that a swatch keeps the previous theme's border.
    func testTheRingIsReappliedRatherThanFrozen() throws {
        let swatch = ThemeSwatchView()
        swatch.setColor(.black, name: "black")

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        swatch.updateLayer()
        let underCyberpunk = try XCTUnwrap(swatch.layer?.borderColor.flatMap { NSColor(cgColor: $0) })

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        swatch.updateLayer()
        let underSwiss = try XCTUnwrap(swatch.layer?.borderColor.flatMap { NSColor(cgColor: $0) })

        XCTAssertNotEqual(underCyberpunk.hexString, underSwiss.hexString,
                          "the ring kept the first theme's border colour")
        XCTAssertEqual(underSwiss.hexString,
                       AppThemeStyles.swissMinimalist.resolved(.border).hexString)
    }
}
