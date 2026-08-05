import AppKit
import XCTest
@testable import Threading

/// The rule that decides whether a mark disappears into what it is drawn on.
///
/// It exists because a brand mark cannot be told to change colour: Claude's starburst is coral
/// wherever it is drawn, and a holly-red selected row is coral-coloured too. The project icons
/// have answered this since the sidebar started drawing favicons, but they answered it against
/// the *appearance*, which is only the right question while the ground never moves.
///
/// `ProjectIconStore.needsBackplate` — the appearance-based rule this generalises — is pinned by
/// `ProjectIconTests.testBackplateDecisionFollowsToneAndAppearance`, and only there. A copy of
/// those seven assertions stood here to show the generalisation had not changed the old answer,
/// but being character-for-character the same call it could only ever fail alongside the
/// original, so it reported nothing the original did not.
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

    /// A ground of a stated tone. Written as an sRGB grey rather than `NSColor(white:)` so the
    /// number in the test is the number the rule measures: a calibrated grey is converted before
    /// it is read, and the conversion is not the identity.
    private func ground(_ tone: CGFloat) -> IconBackplate.Ground {
        IconBackplate.Ground(NSColor(srgbRed: tone, green: tone, blue: tone, alpha: 1))
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
        XCTAssertTrue(IconBackplate.isNeeded(markTone: 0.5, ground: ground(0.5)))
        XCTAssertTrue(IconBackplate.isNeeded(markTone: 0.1, ground: ground(0.13)))
        XCTAssertFalse(IconBackplate.isNeeded(markTone: 0.1, ground: ground(0.9)))
        XCTAssertFalse(IconBackplate.isNeeded(markTone: 0.95, ground: ground(0.13)))
    }

    /// A rescue for something whose shape cannot be measured would put a plate behind every
    /// icon in the list.
    func testAnUnmeasurableMarkNeverPlates() {
        XCTAssertFalse(IconBackplate.isNeeded(markTone: nil, ground: ground(0.5)))
        XCTAssertFalse(IconBackplate.isNeeded(markTone: nil, ground: ground(0)))
    }

    func testThePlateOpposesItsGround() {
        let onDark = IconBackplate.plateColor(against: ground(0.1))
        let onLight = IconBackplate.plateColor(against: ground(0.9))

        XCTAssertGreaterThan(IconBackplate.tone(of: onDark), 0.8, "a dark ground got a dark plate")
        XCTAssertLessThan(IconBackplate.tone(of: onLight), 0.3, "a light ground got a light plate")
    }

    /// Two grounds a thousandth apart are the same ground, and a rendition composed against one
    /// serves the other: the cache is keyed on this, and a key that followed the raw measurement
    /// would mint an entry per read.
    func testGroundsThatCannotDisagreeShareACacheKey() {
        XCTAssertEqual(ground(0.750).cacheKey, ground(0.7503).cacheKey)
        XCTAssertNotEqual(ground(0.75).cacheKey, ground(0.97).cacheKey)
    }

    // MARK: - Composing

    /// A template takes its context's tint, so it is already drawn in a colour chosen to be
    /// seen. Plating one puts a light square behind a glyph that was never in trouble.
    func testATemplateMarkIsNeverPlated() {
        let template = swatch(.black)
        template.isTemplate = true

        let result = IconBackplate.plated(template, against: ground(0.02))
        XCTAssertTrue(result === template)
    }

    func testAMarkThatReadsAgainstItsGroundIsReturnedUnchanged() {
        let mark = swatch(.white)
        let result = IconBackplate.plated(mark, against: ground(0.05))
        XCTAssertTrue(result === mark)
    }

    /// The plate appears *around* the mark: the ink keeps exactly the size it draws at with
    /// no plate, and only the plate spans the slot. The first version inset the ink by a
    /// ratio of the plate instead, so a mark visibly shrank the moment its row was selected.
    func testGainingAPlateLeavesTheInkAtItsOwnSize() throws {
        let inkSide = SidebarRowDefaults.iconSize
        let plateSide = SidebarRowDefaults.iconSlotWidth
        let mark = swatch(.black, size: inkSide)

        // Black ink on a near-black ground vanishes, so this composes a light plate.
        let plated = IconBackplate.plated(mark, against: ground(0.1), size: plateSide)
        XCTAssertFalse(plated === mark, "black on a black ground was left to disappear")
        XCTAssertEqual(plated.size.width, plateSide)

        let pixelsPerPoint = 4
        let canvas = Int(plateSide) * pixelsPerPoint
        let ink = try XCTUnwrap(
            darkInkBounds(of: plated, canvasPixels: canvas),
            "the composite rendered no ink at all"
        )

        let expected = Int(inkSide) * pixelsPerPoint
        XCTAssertEqual(
            ink.maxX - ink.minX + 1, expected, accuracy: 2,
            "the plate resized the ink instead of appearing behind it"
        )
        XCTAssertEqual(ink.maxY - ink.minY + 1, expected, accuracy: 2)

        let margin = (Int(plateSide) - Int(inkSide)) * pixelsPerPoint / 2 - 2
        XCTAssertGreaterThanOrEqual(ink.minX, margin, "no plate showing before the ink")
        XCTAssertLessThanOrEqual(ink.maxX, canvas - 1 - margin, "no plate showing after the ink")
    }

    func testAVanishingMarkComesBackOnAPlate() throws {
        let mark = swatch(NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1))
        let hollyRed = IconBackplate.Ground(NSColor(srgbRed: 1, green: 0.3, blue: 0.35, alpha: 1))

        let result = IconBackplate.plated(mark, against: hollyRed)
        XCTAssertFalse(result === mark, "coral on holly red was left to disappear")

        // The plate is what the ground now sees, and it opposes it.
        let composedTone = try XCTUnwrap(IconBackplate.tone(of: result))
        XCTAssertGreaterThan(
            abs(composedTone - hollyRed.tone),
            abs(try XCTUnwrap(IconBackplate.tone(of: mark)) - hollyRed.tone),
            "the plated mark is no easier to find than the bare one"
        )
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
                ground: IconBackplate.Ground(selectedGround)
            ),
            "the coral mark on the accent-filled selected row was judged legible"
        )
        XCTAssertFalse(
            IconBackplate.isNeeded(
                markTone: IconBackplate.tone(of: mark),
                ground: IconBackplate.Ground(restingGround)
            ),
            "an unselected fir-green row plates a mark that reads perfectly well on it"
        )

        try write(mark: mark, on: selectedGround, named: "backplate-selected")
        try write(mark: mark, on: restingGround, named: "backplate-resting")
    }

    /// The rendered ink's bounding box, in pixels, when the image is drawn over white — the
    /// plate is light and so is the ground, so only the ink reads dark.
    private func darkInkBounds(
        of image: NSImage,
        canvasPixels: Int
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        guard let context = CGContext(
            data: nil,
            width: canvasPixels,
            height: canvasPixels,
            bitsPerComponent: 8,
            bytesPerRow: canvasPixels * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: canvasPixels, height: canvasPixels)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: canvasPixels * canvasPixels * 4)

        var ink: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<canvasPixels {
            for x in 0..<canvasPixels {
                let offset = (y * canvasPixels + x) * 4
                let luminance = 0.2126 * Double(pixels[offset])
                    + 0.7152 * Double(pixels[offset + 1])
                    + 0.0722 * Double(pixels[offset + 2])
                guard luminance < 128 else { continue }
                ink = ink.map {
                    (min($0.minX, x), min($0.minY, y), max($0.maxX, x), max($0.maxY, y))
                } ?? (x, y, x, y)
            }
        }
        return ink
    }

    /// The claim is that you can see it, so the two grounds are also written out — the same
    /// fixture-to-PNG idea the conversation and git-review renders use, for the same reason.
    ///
    /// Rendered at the row's real geometry — the mark slot-sized to `iconSize`, the plate
    /// spanning the wider `iconSlotWidth` — so the picture also shows the ink *not moving*
    /// between the two states.
    private func write(mark: NSImage, on ground: NSColor, named name: String) throws {
        let scale: CGFloat = 8
        let inkSide = SidebarRowDefaults.iconSize
        let plateSide = SidebarRowDefaults.iconSlotWidth

        let sized = try XCTUnwrap(mark.copy() as? NSImage)
        sized.size = NSSize(width: inkSide, height: inkSide)
        let plated = IconBackplate.plated(
            sized,
            against: IconBackplate.Ground(ground),
            size: plateSide
        )

        let canvas = NSImage(
            size: NSSize(width: plateSide * scale * 2.5, height: plateSide * scale * 1.5),
            flipped: false
        ) { bounds in
            ground.setFill()
            bounds.fill()
            let bareBox = NSSize(width: inkSide * scale, height: inkSide * scale)
            let platedBox = NSSize(
                width: plated.size.width * scale,
                height: plated.size.height * scale
            )
            sized.draw(in: NSRect(
                origin: NSPoint(
                    x: plateSide * scale * 0.2,
                    y: (bounds.height - bareBox.height) / 2
                ),
                size: bareBox
            ))
            plated.draw(in: NSRect(
                origin: NSPoint(
                    x: plateSide * scale * 1.3,
                    y: (bounds.height - platedBox.height) / 2
                ),
                size: platedBox
            ))
            return true
        }

        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
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
