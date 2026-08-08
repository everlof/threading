import AppKit
import XCTest
@testable import Threading

/// The bevel vocabulary: a material states a hard period edge or rounded soft relief,
/// `applySurface` and `ThemedSurface.draw` interpret it, and every theme written before the
/// field existed draws exactly what it always drew.
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

    /// The same role vocabulary interpreted as the antialiased inset relief used by clay UI.
    private func makeSoftBevelTheme(width: CGFloat = 3) throws -> AppTheme {
        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        var material = base.variant(kind)?.material ?? .system
        material.glow = nil
        material.bevel = AppTheme.Bevel(width: width, style: .soft)
        return try AppThemeEditing.assemble(
            id: Self.themeID,
            name: "Soft Bevel Fixture",
            mode: kind == .dark ? .dark : .light,
            summary: nil,
            variants: [kind: AppThemeEditing.makeVariant(
                named: "Soft Bevel Fixture",
                from: base,
                kind: kind,
                roles: [
                    .bevelHighlight: NSColor(hex: "#FFFFFFE6")!,
                    .bevelShadow: NSColor(hex: "#7048C84D")!
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

    /// A large field must keep the hard edge at its authored width. The old nine-patch path
    /// stretched a sampled cap into wide gray side bands, which made the Win98 prompt look like
    /// a soft modern inset shadow even though the material requested a two-point hard bevel.
    func testAHardAppliedBevelDoesNotStretchItsEdgeAcrossALargeField() throws {
        AppThemePalette.set(AppThemeStyles.win98)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        view.applySurface(fill: Design.Surface.field, radius: .control, bevel: .sunken)
        view.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        func sample(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try XCTUnwrap(rep.colorAt(
                x: Int((x * scale).rounded(.down)),
                y: Int(((view.bounds.maxY - y) * scale).rounded(.down))
            )?.usingColorSpace(.sRGB))
        }

        let nearLeading = try sample(8, view.bounds.midY)
        let middle = try sample(view.bounds.midX, view.bounds.midY)
        XCTAssertEqual(nearLeading.redComponent, middle.redComponent, accuracy: 2.0 / 255.0)
        XCTAssertEqual(nearLeading.greenComponent, middle.greenComponent, accuracy: 2.0 / 255.0)
        XCTAssertEqual(nearLeading.blueComponent, middle.blueComponent, accuracy: 2.0 / 255.0)
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

    func testASoftBevelFollowsARoundedSurfaceAndReplacesItsBorder() throws {
        AppThemePalette.set(try makeSoftBevelTheme())
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        view.applySurface(
            fill: Design.Surface.panel,
            radius: .fixed(18),
            border: Design.Surface.border
        )

        let edge = try XCTUnwrap(bevelLayer(of: view))
        XCTAssertEqual(view.layer?.borderWidth, 0)
        XCTAssertNotNil(edge.contents, "soft relief must use the resize-safe layer path")
        XCTAssertGreaterThan(edge.contentsCenter.minX, 0)
        XCTAssertLessThan(edge.contentsCenter.maxX, 1)
    }

    /// Soft relief is a fade, not a translucent hard rule. The inverse caster used to share the
    /// visible silhouette exactly, which let its opaque antialiased edge leak through as a dark
    /// one-pixel border before the blur began.
    func testSoftBevelArtworkHasADiffuseEdgeAndAClearMiddle() throws {
        let image = try XCTUnwrap(SoftBevelArtwork.ninePatch(
            radius: 18,
            edgeWidth: 3,
            highlight: NSColor(hex: "#FFFFFFE6")!,
            shadow: NSColor(hex: "#8B5CF64D")!,
            sunken: true,
            broad: true
        ))
        let data = try XCTUnwrap(image.dataProvider?.data) as Data

        func alpha(x: Int, y: Int) -> UInt8 {
            data[y * image.bytesPerRow + x * 4 + 3]
        }

        let middle = image.width / 2
        XCTAssertLessThanOrEqual(alpha(x: middle, y: middle), 2)

        let edgeAlpha = (0..<image.width).flatMap { x in
            [alpha(x: x, y: 1), alpha(x: x, y: image.height - 2)]
        }
        XCTAssertGreaterThan(edgeAlpha.max() ?? 0, 0, "the inset fade disappeared")
        XCTAssertLessThan(edgeAlpha.max() ?? 255, 240, "the caster leaked as an opaque border")
    }

    func testAPairedGlowAddsAndRemovesItsOpposingHighlightShadow() throws {
        AppThemePalette.set(AppThemeStyles.claymorphism)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 60))
        view.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border,
            glow: true
        )

        let highlight = try XCTUnwrap(
            view.layer?.sublayers?.first { $0.name == "threading.glow.highlight" }
        )
        XCTAssertEqual(view.layer?.shadowOffset.width, 16)
        XCTAssertEqual(view.layer?.shadowOffset.height, -16)
        XCTAssertEqual(highlight.shadowOffset.width, -10)
        XCTAssertEqual(highlight.shadowOffset.height, 10)
        XCTAssertNotNil(highlight.shadowPath)

        view.frame.size.width = 240
        view.layoutSubtreeIfNeeded()
        highlight.layoutIfNeeded()
        XCTAssertEqual(highlight.shadowPath?.boundingBox.width, view.bounds.width)

        AppThemePalette.set(.system)
        view.reapplyRecordedSurfaceForTesting()
        XCTAssertNil(
            view.layer?.sublayers?.first { $0.name == "threading.glow.highlight" }
        )
        XCTAssertEqual(view.layer?.shadowOpacity, 0)
    }

    /// A CSS shadow is behind its caster. A path-only Core Animation sublayer is *above* its
    /// parent's background, so the first paired-shadow implementation poured a centred opaque
    /// highlight through the whole surface: Cyberpunk's #1C1C2E settings cards rendered lime
    /// under #E0E0E0 text. Both panel and control companions must leave the face byte-for-byte
    /// the authored role while their halo remains outside it.
    func testCenteredPairedGlowDoesNotPaintInsideItsCaster() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        defer { AppThemePalette.set(.system) }

        let fixtures: [(name: String, fill: NSColor, control: Bool)] = [
            ("panel", Design.Surface.panel, false),
            ("control", Design.Surface.controlResting, true)
        ]

        for fixture in fixtures {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 60))
            view.applySurface(
                fill: fixture.fill,
                radius: .control,
                glow: !fixture.control,
                controlGlow: fixture.control
            )
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)

            let actual = try XCTUnwrap(
                rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
                    .usingColorSpace(.sRGB)
            )
            let expected = try XCTUnwrap(fixture.fill.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.02,
                           "Cyberpunk's \(fixture.name) glow painted inside the face")
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.02,
                           "Cyberpunk's \(fixture.name) glow painted inside the face")
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.02,
                           "Cyberpunk's \(fixture.name) glow painted inside the face")
        }
    }

    func testClayControlsUseTheirOwnTighterPairedShadow() throws {
        AppThemePalette.set(AppThemeStyles.claymorphism)
        let button = ThemedButton(frame: NSRect(x: 0, y: 0, width: 100, height: 26))
        button.title = "Continue"
        let rep = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: rep)

        let primary = try XCTUnwrap(
            button.layer?.sublayers?.first { $0.name == "threading.controlGlow.primary" }
        )
        let highlight = try XCTUnwrap(
            button.layer?.sublayers?.first { $0.name == "threading.controlGlow.highlight" }
        )
        XCTAssertEqual(primary.shadowOffset.width, 6)
        XCTAssertEqual(primary.shadowOffset.height, -6)
        XCTAssertNotNil(primary.shadowPath, "the control face lost its isolated shadow caster")
        XCTAssertEqual(button.layer?.shadowOpacity, 0,
                       "the button title became part of its shadow")
        XCTAssertEqual(highlight.shadowOffset.width, -4)
        XCTAssertEqual(highlight.shadowOffset.height, 4)

        button.isEnabled = false
        button.needsDisplay = true
        button.cacheDisplay(in: button.bounds, to: rep)
        XCTAssertNil(
            button.layer?.sublayers?.first { $0.name == "threading.controlGlow.primary" },
            "a disabled Clay button kept its full-strength violet lift"
        )
        XCTAssertNil(
            button.layer?.sublayers?.first { $0.name == "threading.controlGlow.highlight" },
            "a disabled Clay button kept its full-strength white lift"
        )

        AppThemePalette.set(.system)
        button.needsDisplay = true
        button.cacheDisplay(in: button.bounds, to: rep)
        XCTAssertEqual(button.layer?.shadowOpacity, 0)
        XCTAssertNil(
            button.layer?.sublayers?.first { $0.name == "threading.controlGlow.primary" }
        )
        XCTAssertNil(
            button.layer?.sublayers?.first { $0.name == "threading.controlGlow.highlight" }
        )
    }

    func testIndustrialSeparatesNeutralSecondaryReliefFromCoralCTADepth() throws {
        AppThemePalette.set(AppThemeStyles.industrial)
        defer { AppThemePalette.set(.system) }

        func render(_ button: ThemedButton) throws -> (CALayer, CALayer) {
            let rep = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: rep)
            return (
                try XCTUnwrap(button.layer?.sublayers?.first {
                    $0.name == "threading.controlGlow.primary"
                }),
                try XCTUnwrap(button.layer?.sublayers?.first {
                    $0.name == "threading.controlGlow.highlight"
                })
            )
        }

        let secondary = ThemedButton(frame: NSRect(x: 0, y: 0, width: 100, height: 26))
        secondary.title = "Duplicate"
        let secondaryLayers = try render(secondary)
        XCTAssertEqual(secondaryLayers.0.shadowOffset.width, 8)
        XCTAssertEqual(secondaryLayers.0.shadowOffset.height, -8)
        XCTAssertEqual(secondaryLayers.1.shadowOffset.width, -8)
        XCTAssertEqual(secondaryLayers.1.shadowOffset.height, 8)

        let primary = ThemedButton(frame: NSRect(x: 0, y: 0, width: 100, height: 26))
        primary.title = "Continue"
        primary.isProminent = true
        let primaryLayers = try render(primary)
        XCTAssertEqual(primaryLayers.0.shadowOffset.width, 4)
        XCTAssertEqual(primaryLayers.0.shadowOffset.height, -4)
        XCTAssertEqual(primaryLayers.1.shadowOffset.width, -4)
        XCTAssertEqual(primaryLayers.1.shadowOffset.height, 4)
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
            // The outermost row is the authored highlight. Row one is deliberately the darker
            // derived sheen (#DFDFDF in the Win98 construction), so sampling it makes this test
            // judge the secondary ring against the primary ring's threshold.
            return rep.colorAt(x: 20, y: 0)?.usingColorSpace(.sRGB)
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

    func testValidationAllowsSoftReliefOnRoundedCorners() throws {
        XCTAssertNoThrow(try makeSoftBevelTheme())
        XCTAssertThrowsError(try makeSoftBevelTheme(width: 4),
                             "soft relief keeps the same edge-width budget")
    }

    func testBevelDocumentsDefaultOldPayloadsToTheHardStyle() throws {
        let old = try JSONDecoder().decode(
            AppTheme.Bevel.self,
            from: Data("{\"width\":2}".utf8)
        )
        XCTAssertEqual(old.style, .hard)

        let encoded = try JSONEncoder().encode(AppTheme.Bevel(width: 3, style: .soft))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["style"] as? String, "soft")
    }
}
