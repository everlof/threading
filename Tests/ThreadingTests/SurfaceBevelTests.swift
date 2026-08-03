import AppKit
import XCTest
@testable import Threading

/// The bevel vocabulary: a material states one, `applySurface` and `ThemedSurface.draw`
/// interpret it, and every theme written before the field existed draws exactly what it
/// always drew.
@MainActor
final class SurfaceBevelTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let themeID = AppThemeID("custom-surface-bevel-tests")

    /// A square-cornered, bevelled variant of Cyberpunk with the two edge roles stated.
    private func makeBevelTheme(width: CGFloat = 2) throws -> AppTheme {
        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        var material = base.variant(kind)?.material ?? .system
        material.panelRadius = 0
        material.controlRadius = 0
        material.glow = nil
        material.bevel = AppTheme.Bevel(width: width)
        return try AppThemeEditing.assemble(
            id: Self.themeID,
            name: "Bevel Fixture",
            mode: kind == .dark ? .dark : .light,
            summary: nil,
            variants: [kind: AppThemeEditing.makeVariant(
                named: "Bevel Fixture",
                from: base,
                kind: kind,
                roles: [
                    .bevelHighlight: NSColor(hex: "#FFFFFF")!,
                    .bevelShadow: NSColor(hex: "#404040")!
                ],
                material: material
            )]
        )
    }

    private func bevelLayer(of view: NSView) -> CALayer? {
        view.layer?.sublayers?.first { $0.name == "threading.bevel" }
    }

    // MARK: - Applied Surfaces

    /// A stock theme without a bevel material draws exactly what it always drew — no edge
    /// layer, its flat border untouched — and the one that states a bevel (Windows 98) is
    /// edged instead of bordered. The sweep asserts the material's own answer, so a future
    /// bevelled style joins the second branch without loosening the first.
    func testEveryStockThemeAppliesSurfacesPerItsOwnMaterial() {
        for theme in AppThemeLibrary.stock {
            AppThemePalette.set(theme)
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
            view.applySurface(
                fill: Design.Surface.panel,
                radius: .panel,
                border: Design.Surface.border
            )
            if theme.material.bevel == nil {
                XCTAssertNil(bevelLayer(of: view), theme.name)
                XCTAssertGreaterThan(view.layer?.borderWidth ?? 0, 0, theme.name)
            } else {
                XCTAssertNotNil(bevelLayer(of: view), theme.name)
                XCTAssertEqual(view.layer?.borderWidth, 0, theme.name)
            }
        }
    }

    func testABevelMaterialRaisesAutomaticSurfacesAndReplacesTheirBorders() throws {
        AppThemePalette.set(try makeBevelTheme())
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        view.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )

        XCTAssertNotNil(bevelLayer(of: view))
        XCTAssertEqual(view.layer?.borderWidth, 0,
                       "the bevel replaces the flat border, it does not join it")
    }

    /// Switching away must strip the edge — the applyThemeGlow "cleared rather than
    /// skipped" rule — and the sweep's re-application is what carries the decision.
    func testSwitchingAwayFromABevelThemeStripsTheEdge() throws {
        AppThemePalette.set(try makeBevelTheme())
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        view.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )
        XCTAssertNotNil(bevelLayer(of: view))

        AppThemePalette.set(.system)
        view.reapplyRecordedSurfaceForTesting()

        XCTAssertNil(bevelLayer(of: view))
        XCTAssertGreaterThan(view.layer?.borderWidth ?? 0, 0, "the flat border returns")
    }

    /// A rounded shape under a bevel material keeps its flat treatment: a rectilinear edge
    /// has no honest answer for a curve.
    func testARoundedSurfaceUnderABevelMaterialKeepsItsFlatBorder() throws {
        AppThemePalette.set(try makeBevelTheme())
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        view.applySurface(
            fill: Design.Surface.panel,
            radius: .fixed(8),
            border: Design.Surface.border
        )

        XCTAssertNil(bevelLayer(of: view))
        XCTAssertGreaterThan(view.layer?.borderWidth ?? 0, 0)
    }

    func testAComponentMayDeclineTheBevelOutright() throws {
        AppThemePalette.set(try makeBevelTheme())
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        view.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border,
            bevel: .none
        )

        XCTAssertNil(bevelLayer(of: view))
        XCTAssertGreaterThan(view.layer?.borderWidth ?? 0, 0)
    }

    // MARK: - The Artwork

    /// The nine-patch is the classic two-ring construction: light from the top-leading
    /// corner, so the top edge samples as the highlight and the bottom as the near-black
    /// frame line derived from the shadow.
    func testTheNinePatchLightsTheTopAndShadesTheBottom() throws {
        let image = try XCTUnwrap(BevelArtwork.ninePatch(
            edgeWidth: 2,
            highlight: .white,
            shadow: .black,
            sunken: false
        ))

        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let bytesPerRow = image.bytesPerRow
        func pixel(x: Int, y: Int) -> (r: UInt8, a: UInt8) {
            let offset = y * bytesPerRow + x * 4
            return (data[offset], data[offset + 3])
        }

        let mid = image.width / 2
        // CGImage rows run top-down; the artwork was drawn in CG's bottom-up space, so the
        // first row is the artwork's top.
        XCTAssertEqual(pixel(x: mid, y: 0).r, 255, "the top edge is lit")
        XCTAssertEqual(pixel(x: mid, y: image.height - 1).r, 0, "the bottom edge is shaded")
        XCTAssertEqual(pixel(x: 0, y: mid).r, 255, "the leading edge is lit")
        XCTAssertEqual(pixel(x: image.width - 1, y: mid).r, 0, "the trailing edge is shaded")
        XCTAssertEqual(pixel(x: mid, y: mid).a, 0, "the middle is clear for the fill beneath")
    }

    // MARK: - Drawn Surfaces

    /// The draw-time half: a `ThemedSurface.draw` under a bevel material comes out edged, and
    /// under System it stays exactly the flat surface it always drew. Drawn over an opaque
    /// blue ground — a translucent border over transparency un-premultiplies to junk — and
    /// judged by the smallest colour component: only the bevel's white highlight lifts all
    /// three, while System's top edge keeps the ground's blue with next to no red.
    func testDrawnSurfacesBevelUnderABevelMaterialOnly() throws {
        func topEdgeSample(_ theme: AppTheme) -> NSColor? {
            AppThemePalette.set(theme)
            let size = NSSize(width: 40, height: 20)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.blue.setFill()
                rect.fill()
                ThemedSurface.draw(rect, fill: .red, border: Design.Surface.border)
                return true
            }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.colorAt(x: 20, y: 1)?.usingColorSpace(.sRGB)
        }

        let bevelled = try XCTUnwrap(topEdgeSample(makeBevelTheme()))
        let litFloor = min(
            bevelled.redComponent, bevelled.greenComponent, bevelled.blueComponent
        )
        XCTAssertGreaterThan(litFloor, 0.9, "the drawn control's top edge takes the highlight")

        let flat = try XCTUnwrap(topEdgeSample(.system))
        let flatFloor = min(flat.redComponent, flat.greenComponent, flat.blueComponent)
        XCTAssertLessThan(flatFloor, 0.9, "under System the same drawing has no lit edge")
    }

    // MARK: - Derivation & Validation

    func testTheEdgeRolesDeriveFromTheSurfaceWhenUnstated() {
        let theme = AppThemeStyles.cyberpunk
        let kind = theme.availableVariants[0]
        let appearance = kind.appearance ?? NSAppearance.currentDrawing()
        let surface = theme.resolved(.surface, appearance: appearance)

        XCTAssertEqual(
            theme.resolved(.bevelHighlight, appearance: appearance),
            surface.lightened(by: 0.45)
        )
        XCTAssertEqual(
            theme.resolved(.bevelShadow, appearance: appearance),
            surface.lightened(by: -0.45)
        )
    }

    func testValidationHoldsABevelMaterialToSquareCornersAndItsWidth() throws {
        XCTAssertThrowsError(try makeBevelTheme(width: 4),
                             "a bevel past three points should be refused")

        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        var rounded = base.variant(kind)?.material ?? .system
        rounded.bevel = AppTheme.Bevel(width: 2)
        XCTAssertGreaterThan(rounded.panelRadius, 0, "the fixture needs a rounded base")
        XCTAssertThrowsError(try AppThemeEditing.assemble(
            id: Self.themeID,
            name: "Rounded Bevel",
            mode: kind == .dark ? .dark : .light,
            summary: nil,
            variants: [kind: AppThemeEditing.makeVariant(
                named: "Rounded Bevel", from: base, kind: kind, material: rounded
            )]
        ), "a bevel on a rounded material authors a treatment that never draws")
    }
}
