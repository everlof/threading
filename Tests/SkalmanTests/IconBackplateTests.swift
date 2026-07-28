import AppKit
import XCTest
@testable import Skalman

/// The rule that decides whether a mark disappears into what it is drawn on.
///
/// It exists because a brand mark cannot be told to change colour: Claude's starburst is coral
/// wherever it is drawn, and a holly-red selected row is coral-coloured too. The project icons
/// have answered this since the sidebar started drawing favicons, but they answered it against
/// the *appearance*, which is only the right question while the ground never moves.
@MainActor
final class IconBackplateTests: XCTestCase {

    // MARK: - Helpers

    private func swatch(_ color: NSColor, size: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            color.setFill()
            bounds.fill()
            return true
        }
    }

    // MARK: - Measuring

    func testToneReadsBlackAndWhiteAtTheEndsOfItsRange() throws {
        let black = try XCTUnwrap(IconBackplate.tone(of: swatch(.black)))
        let white = try XCTUnwrap(IconBackplate.tone(of: swatch(.white)))

        XCTAssertLessThan(black, 0.05)
        XCTAssertGreaterThan(white, 0.95)
    }

    /// Transparent regions carry no weight, so a small dark glyph on a clear ground reads as
    /// dark rather than as mostly-nothing — the difference between plating a favicon and
    /// plating every icon in the list.
    func testToneIgnoresTransparentAreas() throws {
        let mostlyClear = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: 4, height: 4).fill()
            return true
        }

        let tone = try XCTUnwrap(IconBackplate.tone(of: mostlyClear))
        XCTAssertLessThan(tone, 0.05, "the clear area was averaged in as if it were dark ink")
    }

    func testAnImageWithNoVisiblePixelsHasNoTone() {
        let empty = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true }
        XCTAssertNil(IconBackplate.tone(of: empty))
    }

    // MARK: - Deciding

    func testAMarkIsPlatedOnlyWhenItsGroundIsTooCloseToIt() {
        XCTAssertTrue(IconBackplate.isNeeded(markTone: 0.5, groundTone: 0.5))
        XCTAssertTrue(IconBackplate.isNeeded(markTone: 0.1, groundTone: 0.13))
        XCTAssertFalse(IconBackplate.isNeeded(markTone: 0.1, groundTone: 0.9))
        XCTAssertFalse(IconBackplate.isNeeded(markTone: 0.95, groundTone: 0.13))
    }

    /// A rescue for something whose shape cannot be measured would put a plate behind every
    /// icon in the list.
    func testAnUnmeasurableMarkNeverPlates() {
        XCTAssertFalse(IconBackplate.isNeeded(markTone: nil, groundTone: 0.5))
        XCTAssertFalse(IconBackplate.isNeeded(markTone: nil, groundTone: 0.0))
    }

    func testThePlateOpposesItsGround() {
        let onDark = IconBackplate.plateColor(againstTone: 0.1)
        let onLight = IconBackplate.plateColor(againstTone: 0.9)

        XCTAssertGreaterThan(IconBackplate.tone(of: onDark), 0.8, "a dark ground got a dark plate")
        XCTAssertLessThan(IconBackplate.tone(of: onLight), 0.3, "a light ground got a light plate")
    }

    // MARK: - Composing

    /// A template takes its context's tint, so it is already drawn in a colour chosen to be
    /// seen. Plating one puts a light square behind a glyph that was never in trouble.
    func testATemplateMarkIsNeverPlated() {
        let template = swatch(.black)
        template.isTemplate = true

        let result = IconBackplate.plated(template, againstTone: 0.02)
        XCTAssertTrue(result === template)
    }

    func testAMarkThatReadsAgainstItsGroundIsReturnedUnchanged() {
        let mark = swatch(.white)
        let result = IconBackplate.plated(mark, againstTone: 0.05)
        XCTAssertTrue(result === mark)
    }

    func testAVanishingMarkComesBackOnAPlate() throws {
        let mark = swatch(NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1))
        let groundTone = IconBackplate.tone(of: NSColor(srgbRed: 1, green: 0.3, blue: 0.35, alpha: 1))

        let result = IconBackplate.plated(mark, againstTone: groundTone)
        XCTAssertFalse(result === mark, "coral on holly red was left to disappear")

        // The plate is what the ground now sees, and it opposes it.
        let composedTone = try XCTUnwrap(IconBackplate.tone(of: result))
        XCTAssertGreaterThan(
            abs(composedTone - groundTone),
            abs(try XCTUnwrap(IconBackplate.tone(of: mark)) - groundTone),
            "the plated mark is no easier to find than the bare one"
        )
    }

    // MARK: - The Project Icons' Own Rule

    /// The appearance-based rule the project tiles have always used is now expressed as a
    /// ground, and must still answer exactly as it did.
    func testTheProjectIconRuleIsUnchangedByTheGeneralisation() {
        XCTAssertTrue(ProjectIconStore.needsBackplate(luminance: 0.1, darkAppearance: true))
        XCTAssertFalse(ProjectIconStore.needsBackplate(luminance: 0.1, darkAppearance: false))
        XCTAssertTrue(ProjectIconStore.needsBackplate(luminance: 0.95, darkAppearance: false))
        XCTAssertFalse(ProjectIconStore.needsBackplate(luminance: 0.95, darkAppearance: true))
        XCTAssertFalse(ProjectIconStore.needsBackplate(luminance: 0.5, darkAppearance: true))
        XCTAssertFalse(ProjectIconStore.needsBackplate(luminance: 0.5, darkAppearance: false))
        XCTAssertFalse(ProjectIconStore.needsBackplate(luminance: nil, darkAppearance: true))
    }

    // MARK: - The Reported Case

    /// The report, with the real mark and the real theme: Claude's starburst on a Christmas
    /// selected row. An assertion about tones is not the claim being made — the claim is that
    /// you can see it — so this also writes the row out both ways.
    func testClaudesMarkSurvivesASelectedRowUnderTheChristmasTheme() throws {
        let mark = try XCTUnwrap(AgentKind.claude.icon, "the Claude brand mark is missing")
        try XCTSkipIf(mark.isTemplate, "a template mark tints and never needs a plate")

        AppThemePalette.set(AppThemeStyles.christmas)
        defer { AppThemePalette.set(.system) }

        var selectedGround = NSColor.clear
        var restingGround = NSColor.clear
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        appearance.performAsCurrentDrawingAppearance {
            restingGround = AppThemeStyles.christmas.resolved(.surface, appearance: appearance)
            selectedGround = restingGround.composited(
                under: AppThemeStyles.christmas.resolved(.accent, appearance: appearance)
            )
        }

        XCTAssertTrue(
            IconBackplate.isNeeded(
                markTone: IconBackplate.tone(of: mark),
                groundTone: IconBackplate.tone(of: selectedGround)
            ),
            "the coral mark on the accent-filled selected row was judged legible"
        )
        XCTAssertFalse(
            IconBackplate.isNeeded(
                markTone: IconBackplate.tone(of: mark),
                groundTone: IconBackplate.tone(of: restingGround)
            ),
            "an unselected fir-green row plates a mark that reads perfectly well on it"
        )

        try write(mark: mark, on: selectedGround, named: "backplate-selected")
        try write(mark: mark, on: restingGround, named: "backplate-resting")
    }

    /// The claim is that you can see it, so the two grounds are also written out — the same
    /// fixture-to-PNG idea the conversation and git-review renders use, for the same reason.
    private func write(mark: NSImage, on ground: NSColor, named name: String) throws {
        let scale: CGFloat = 8
        let side = SidebarRowDefaults.iconSize
        let plated = IconBackplate.plated(
            mark,
            againstTone: IconBackplate.tone(of: ground),
            size: side
        )

        let canvas = NSImage(
            size: NSSize(width: side * scale * 2.5, height: side * scale * 1.5),
            flipped: false
        ) { bounds in
            ground.setFill()
            bounds.fill()
            let box = NSSize(width: side * scale, height: side * scale)
            let y = (bounds.height - box.height) / 2
            mark.draw(in: NSRect(origin: NSPoint(x: side * scale * 0.2, y: y), size: box))
            plated.draw(in: NSRect(origin: NSPoint(x: side * scale * 1.3, y: y), size: box))
            return true
        }

        let directory = ProcessInfo.processInfo.environment["SKALMAN_RENDER_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SkalmanRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode \(name)")
            return
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
