import AppKit
import XCTest
@testable import Threading

/// Period chrome sized from a control's box instead of its outline: the Aqua pop-up's gel well,
/// the classic default button's frame, and the thumb every legacy scrollbar kept after its page
/// stopped scrolling.
@MainActor
final class AquaChromeTests: XCTestCase {

    override func tearDown() {
        AppThemeLibrary.apply(.system)
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Scrollers

    /// A page that shrinks below its own viewport leaves AppKit's scroller disabled *and* holding
    /// the knob proportion it last needed. Reading that stale proportion drew a thumb for content
    /// that is no longer there: two-thirds of the trough, parked at one end, unmovable — reported
    /// as a scrollbar that "doesn't move when I scroll" and "shows scroll space that isn't there".
    ///
    /// Every period appearance shares the drawing, so every one is checked: this was found in
    /// Tiger and was never Tiger's.
    func testAScrollerWithNothingLeftToScrollShowsAnEmptyTrough() throws {
        for theme in Self.legacyScrollbarThemes {
            AppThemePalette.set(theme)
            let scroll = ThemedScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
            scroll.hasVerticalScroller = true
            let document = SettingsFlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 1200))
            scroll.documentView = document
            scroll.layoutSubtreeIfNeeded()

            let scroller = try XCTUnwrap(scroll.verticalScroller as? ThemedScroller)
            XCTAssertFalse(
                scroller.rect(for: .knob).isEmpty,
                "\(theme.name): a page taller than its viewport has a thumb"
            )

            document.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
            scroll.layoutSubtreeIfNeeded()
            scroll.reflectScrolledClipView(scroll.contentView)

            XCTAssertFalse(scroller.isEnabled, "\(theme.name): AppKit disables a spent scroller")
            XCTAssertGreaterThan(
                scroller.knobProportion,
                0,
                "\(theme.name): and keeps the proportion it last needed, which is the trap"
            )
            XCTAssertTrue(
                scroller.rect(for: .knob).isEmpty,
                "\(theme.name): drew a thumb for a page with nothing left to scroll"
            )
            XCTAssertFalse(
                scroller.rect(for: .knobSlot).isEmpty,
                "\(theme.name): the trough itself stays — a legacy scrollbar owns its space"
            )
            XCTAssertFalse(
                scroller.rect(for: .incrementLine).isEmpty,
                "\(theme.name): so do the arrows, dimmed rather than removed"
            )
        }
    }

    /// The other half of the same rule: a page that *does* scroll still gets a thumb, sized from
    /// the proportion and placed from the value. Without this the fix above is indistinguishable
    /// from removing the thumb altogether.
    func testAScrollerWithRangeStillSizesAndPlacesItsThumb() throws {
        AppThemePalette.set(AppThemeStyles.aquaTiger)
        let scroll = ThemedScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        scroll.hasVerticalScroller = true
        scroll.documentView = SettingsFlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 1200))
        scroll.layoutSubtreeIfNeeded()

        let scroller = try XCTUnwrap(scroll.verticalScroller as? ThemedScroller)
        let slot = scroller.rect(for: .knobSlot)
        XCTAssertTrue(scroller.isFlipped, "NSScrollView hosts its vertical scrollers flipped")

        scroller.doubleValue = 0
        let atTop = scroller.rect(for: .knob)
        XCTAssertEqual(atTop.minY, slot.minY, accuracy: 0.5, "value 0 is the top of the document")
        XCTAssertEqual(
            atTop.height,
            floor(slot.height * scroller.knobProportion),
            accuracy: 1,
            "the thumb states how much of the document is on screen"
        )

        scroller.doubleValue = 1
        XCTAssertEqual(
            scroller.rect(for: .knob).maxY,
            slot.maxY,
            accuracy: 0.5,
            "value 1 is the bottom"
        )
    }

    /// The picture behind the geometry: a spent Tiger scrollbar draws no blue at all.
    func testASpentTigerScrollbarDrawsNoThumbInk() throws {
        AppThemePalette.set(AppThemeStyles.aquaTiger)
        let scroll = ThemedScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        scroll.hasVerticalScroller = true
        let document = SettingsFlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 1200))
        scroll.documentView = document
        scroll.layoutSubtreeIfNeeded()
        let scroller = try XCTUnwrap(scroll.verticalScroller as? ThemedScroller)

        XCTAssertTrue(
            try drawsAccentInk(scroller),
            "a scrolling page draws its blue gel thumb"
        )

        document.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        scroll.layoutSubtreeIfNeeded()
        scroll.reflectScrolledClipView(scroll.contentView)

        XCTAssertFalse(
            try drawsAccentInk(scroller),
            "the trough of a spent scrollbar still had a blue thumb in it"
        )
    }

    // MARK: - Pop-ups

    /// The well is the pop-up's trailing end, and the curve there belongs to the button. Filled as
    /// a rectangle it painted over both right corners and the border between them, so the control
    /// ended in a hard blue block — the "cut off" edge this was reported as.
    func testTheAquaPopUpWellStaysInsideTheButtonsCorner() throws {
        AppThemePalette.set(AppThemeStyles.aquaTiger)
        let popUp = ThemedPopUp()
        popUp.addItem(withTitle: "Mac OS X 10.4 Tiger")
        popUp.frame = NSRect(x: 20, y: 9, width: 160, height: Design.Size.choiceHeight)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        host.wantsLayer = true
        host.appearance = NSAppearance(named: .aqua)
        host.addSubview(popUp)
        host.layer?.backgroundColor = Design.Surface.ground.cgColor
        host.layoutSubtreeIfNeeded()

        let raster = try render(host)
        let trailing = popUp.frame.maxX
        let well = NSPoint(x: trailing - ClassicChoiceDrawing.arrowWidth / 2, y: popUp.frame.midY)
        XCTAssertTrue(
            isAccentInk(try XCTUnwrap(sample(raster, in: host, at: well))),
            "the well itself is the theme's blue"
        )

        // Two points per corner: the outermost pixel, which is the border's, and the pixel just
        // inside it, which is where the curve is. A well merely inset by the border width clears
        // the first and still squares off the second.
        let corners = [
            NSPoint(x: trailing - 0.5, y: popUp.frame.maxY - 0.5),
            NSPoint(x: trailing - 0.5, y: popUp.frame.minY + 0.5),
            NSPoint(x: trailing - 1.5, y: popUp.frame.maxY - 1.5),
            NSPoint(x: trailing - 1.5, y: popUp.frame.minY + 1.5)
        ]
        for point in corners {
            XCTAssertFalse(
                isAccentInk(try XCTUnwrap(sample(raster, in: host, at: point))),
                "the well squared off the button's corner at \(point)"
            )
        }
    }

    /// A chip and a pop-up are the same control under this material — one serves the composer and
    /// the other serves forms — so their corners have to be the same pixels. The chip's came from
    /// a `CALayer` border, which follows the app's continuous corner: at this radius the stroke
    /// thickens through the arc and leaves a ledge where it meets the straight run, a step the
    /// pop-up a row above it does not have. Compared as drawn, because that difference is a pixel
    /// difference and nothing else states it.
    func testTheTwoAquaChoosersDrawTheSameCorner() throws {
        AppThemePalette.set(AppThemeStyles.aquaTiger)
        let frame = NSRect(x: 10, y: 9, width: 160, height: Design.Size.choiceHeight)

        let popUp = ThemedPopUp()
        popUp.addItem(withTitle: "Agent's Setting")
        popUp.frame = frame
        let chip = ChipView()
        chip.configure(symbolName: nil, title: "Agent's Setting")
        chip.frame = frame

        let corner = NSRect(x: frame.minX, y: frame.maxY - 8, width: 8, height: 8)
        let drawn = try [popUp, chip].map { control -> [NSColor] in
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            host.wantsLayer = true
            host.appearance = NSAppearance(named: .aqua)
            host.addSubview(control)
            host.layer?.backgroundColor = Design.Surface.ground.cgColor
            host.layoutSubtreeIfNeeded()
            let raster = try render(host)
            return try stride(from: corner.minY, to: corner.maxY, by: 1).flatMap { y in
                try stride(from: corner.minX, to: corner.maxX, by: 1).map { x in
                    try XCTUnwrap(sample(raster, in: host, at: NSPoint(x: x + 0.5, y: y + 0.5)))
                }
            }
        }

        print("PROBE frames popUp=\(popUp.frame) chip=\(chip.frame)")
        for (name, block) in zip(["popUp", "chip"], drawn) {
            let rows = stride(from: 0, to: 64, by: 8).map { start in
                block[start..<(start + 8)]
                    .map { String(format: "%.2f", $0.brightnessComponent) }
                    .joined(separator: " ")
            }
            print("PROBE \(name)\n" + rows.reversed().joined(separator: "\n"))
        }
        for (index, pair) in zip(drawn[0], drawn[1]).enumerated() {
            let (fromPopUp, fromChip) = pair
            XCTAssertEqual(
                fromPopUp.brightnessComponent,
                fromChip.brightnessComponent,
                accuracy: 0.02,
                "the two Aqua choosers drew different corners at sample \(index)"
            )
        }
    }

    // MARK: - Default Buttons

    /// Aqua's default button is the blue one. `raised` is the *classic desktop* default — the
    /// ordinary face plus an outer frame — which is Platinum's answer and Win32's, and on a
    /// material with a corner radius it also left a square of frame colour outside every curve.
    func testTheAquaMaterialsFillTheirDefaultButton() throws {
        for theme in [AppThemeStyles.aqua, AppThemeStyles.aquaTiger] {
            let material = try XCTUnwrap(theme.variant(.light)?.material)
            XCTAssertEqual(material.buttonStyle.primaryTreatment, .filled, theme.name)
            XCTAssertEqual(material.buttonStyle.primaryRole, .accent, theme.name)
            XCTAssertGreaterThan(material.controlRadius, 0, theme.name)
        }
    }

    /// And where a material does ask for the classic frame, the frame follows the silhouette it
    /// is framing. A square material is unaffected — its corner is zero — so this is checked on
    /// an authored theme that pairs `raised` with a radius, which is exactly what a custom theme
    /// can do from the theme editor.
    func testAClassicDefaultFrameFollowsTheControlsCorner() throws {
        AppThemePalette.set(try Self.makeRoundedRaisedTheme())
        let button = ThemedButton(title: "Start session", target: nil, action: nil)
        button.isProminent = true
        button.frame = NSRect(x: 20, y: 10, width: 140, height: 28)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 48))
        host.wantsLayer = true
        host.appearance = NSAppearance(named: .aqua)
        host.addSubview(button)
        host.layer?.backgroundColor = Design.Surface.ground.cgColor
        host.layoutSubtreeIfNeeded()

        let raster = try render(host)
        let corners = [
            NSPoint(x: button.frame.minX + 0.5, y: button.frame.minY + 0.5),
            NSPoint(x: button.frame.maxX - 0.5, y: button.frame.minY + 0.5),
            NSPoint(x: button.frame.minX + 0.5, y: button.frame.maxY - 0.5),
            NSPoint(x: button.frame.maxX - 0.5, y: button.frame.maxY - 0.5)
        ]
        for corner in corners {
            XCTAssertFalse(
                isAccentInk(try XCTUnwrap(sample(raster, in: host, at: corner))),
                "the default frame filled the button's box instead of its shape, at \(corner)"
            )
        }
        XCTAssertTrue(
            isAccentInk(try XCTUnwrap(sample(
                raster,
                in: host,
                at: NSPoint(x: button.frame.midX, y: button.frame.maxY - 0.5)
            ))),
            "the frame itself is still drawn along the edge"
        )
    }

    // MARK: - Rendered State

    /// The picture the assertions above stand in for: both Aqua materials' chooser, default
    /// button and scrollbar, the scrollbar in each of its two states. Every one of these bugs was
    /// legible at a glance and invisible to the assertions that existed, which is what a specimen
    /// is for. Written to `THREADING_RENDER_OUT`; both themes are light-only, so there is one
    /// sheet rather than a pair.
    func testRendersTheAquaChromeSpecimen() throws {
        let directory = renderDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for (theme, name) in [(AppThemeStyles.aqua, "cheetah"), (AppThemeStyles.aquaTiger, "tiger")] {
            AppThemePalette.set(theme)
            let sheet = try makeSpecimenSheet()
            let raster = try render(sheet)
            try XCTUnwrap(raster.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("aqua-chrome-\(name).png"))
        }
    }

    private func makeSpecimenSheet() throws -> NSView {
        let sheet = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 160))
        sheet.wantsLayer = true
        sheet.appearance = NSAppearance(named: .aqua)
        sheet.layer?.backgroundColor = Design.Surface.ground.cgColor

        let popUp = ThemedPopUp()
        popUp.addItem(withTitle: "Mac OS X 10.4 Tiger")
        popUp.frame = NSRect(x: 24, y: 116, width: 200, height: Design.Size.choiceHeight)
        sheet.addSubview(popUp)

        let chip = ChipView()
        chip.configure(symbolName: nil, title: "Agent's Setting")
        chip.frame = NSRect(x: 24, y: 78, width: 160, height: Design.Size.choiceHeight)
        sheet.addSubview(chip)

        let primary = ThemedButton(title: "Start session", target: nil, action: nil)
        primary.isProminent = true
        primary.frame = NSRect(x: 24, y: 24, width: 130, height: 28)
        sheet.addSubview(primary)

        let secondary = ThemedButton(title: "Cancel", target: nil, action: nil)
        secondary.frame = NSRect(x: 166, y: 24, width: 90, height: 28)
        sheet.addSubview(secondary)

        for (index, documentHeight) in [CGFloat(600), CGFloat(60)].enumerated() {
            let scroll = ThemedScrollView(frame: NSRect(
                x: 300 + CGFloat(index) * 70,
                y: 20,
                width: 60,
                height: 120
            ))
            scroll.hasVerticalScroller = true
            let document = SettingsFlippedView(frame: NSRect(x: 0, y: 0, width: 40, height: 600))
            scroll.documentView = document
            sheet.addSubview(scroll)
            sheet.layoutSubtreeIfNeeded()
            // Grown then shrunk, so the spent one carries the stale proportion this fixes rather
            // than the zero a scroll view that never scrolled would have.
            document.frame = NSRect(x: 0, y: 0, width: 40, height: documentHeight)
            scroll.layoutSubtreeIfNeeded()
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        sheet.layoutSubtreeIfNeeded()
        return sheet
    }

    private var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    // MARK: - Fixtures

    private static let legacyScrollbarThemes: [AppTheme] = [
        AppThemeStyles.aquaTiger,
        AppThemeStyles.aqua,
        AppThemeStyles.platinum,
        AppThemeStyles.openStep,
        AppThemeStyles.beOS,
        AppThemeStyles.amiga,
        AppThemeStyles.irix,
        AppThemeStyles.win98
    ]

    /// A material that asks for the classic default frame *and* rounds its controls — the pairing
    /// no built-in theme ships and the theme editor allows.
    private static func makeRoundedRaisedTheme() throws -> AppTheme {
        let tiger = AppThemeStyles.aquaTiger
        let base = try XCTUnwrap(tiger.variant(.light))
        var material = base.material
        material.buttonStyle.primaryTreatment = .raised
        return AppTheme(
            id: AppThemeID("test-rounded-raised"),
            name: "Rounded Raised",
            mode: .light,
            summary: nil,
            // Copied, never constructed — see themes.md. A rebuilt variant is how a takeover
            // theme silently loses its window chrome.
            variants: [.light: base.replacing(material: material)]
        )
    }

    // MARK: - Drawing Helpers

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Offscreen reps are backing-scaled, so a point has to be converted before it names a pixel;
    /// read in points, a scan of a 2× raster lands somewhere inside the top-left corner instead.
    private func sample(_ raster: NSBitmapImageRep, in view: NSView, at point: NSPoint) -> NSColor? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let scaleX = CGFloat(raster.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(raster.pixelsHigh) / view.bounds.height
        let x = min(raster.pixelsWide - 1, max(0, Int(point.x * scaleX)))
        // A rep is addressed from its top row; an unflipped view measures from its bottom.
        let y = min(raster.pixelsHigh - 1, max(0, Int((view.bounds.maxY - point.y) * scaleY)))
        return raster.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    /// Compared channel against channel rather than to an exact colour: a cached bitmap comes
    /// back in the window's colour space, so the accent's numbers shift while "much bluer than it
    /// is red" survives the conversion.
    private func isAccentInk(_ color: NSColor) -> Bool {
        guard let drawn = color.usingColorSpace(.sRGB) else { return false }
        return drawn.blueComponent - drawn.redComponent > 0.2
    }

    private func drawsAccentInk(_ scroller: ThemedScroller) throws -> Bool {
        let raster = try XCTUnwrap(
            scroller.bitmapImageRepForCachingDisplay(in: scroller.bounds)
        )
        scroller.cacheDisplay(in: scroller.bounds, to: raster)
        for y in 0..<raster.pixelsHigh {
            for x in 0..<raster.pixelsWide {
                guard let pixel = raster.colorAt(x: x, y: y) else { continue }
                if isAccentInk(pixel) { return true }
            }
        }
        return false
    }
}
