import AppKit
import XCTest
@testable import Threading

/// The shop-app vocabulary: coupon pop-ups, round checks, striped meters, pill scrollers,
/// outlined fields, sticker badges, a glossy title band and pill caption buttons.
///
/// Each value is generic — any theme may state it — so each is tested on a fixture material
/// rather than on the custom theme that first wore it. Pixel assertions read the bitmap by its
/// own rows (top first), which keeps them independent of whether a view draws flipped.
@MainActor
final class ShopVocabularyTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Coupon Outline

    func testCouponBitesAreEvenlySpacedAndClearOfTheCorners() throws {
        let centres = CouponOutline.biteCentres(along: 12...112)
        XCTAssertEqual(centres.count, 10)
        let first = try XCTUnwrap(centres.first)
        let last = try XCTUnwrap(centres.last)
        XCTAssertEqual(first, 17, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(first - CouponOutline.biteRadius, 12)
        XCTAssertLessThanOrEqual(last + CouponOutline.biteRadius, 112)
        XCTAssertTrue(
            CouponOutline.biteCentres(along: 0...9).isEmpty,
            "a side too short for one pitch keeps a straight edge rather than a crowded bite"
        )
    }

    func testTheCouponIsBittenOnItsSidesAndStraightAcrossItsTopAndBottom() throws {
        let rect = NSRect(x: 0, y: 0, width: 200, height: 100)
        let radius: CGFloat = 12
        let path = CouponOutline.path(in: rect, cornerRadius: radius)
        let centres = CouponOutline.biteCentres(along: (rect.minY + radius)...(rect.maxY - radius))
        XCTAssertGreaterThan(centres.count, 1)
        let bite = centres[centres.count / 2]

        XCTAssertFalse(path.contains(NSPoint(x: 1, y: bite)), "the leading side is bitten")
        XCTAssertFalse(path.contains(NSPoint(x: rect.maxX - 1, y: bite)), "so is the trailing")
        XCTAssertTrue(
            path.contains(NSPoint(x: 1, y: (centres[0] + centres[1]) / 2)),
            "between two bites the side is solid"
        )
        XCTAssertTrue(path.contains(NSPoint(x: rect.midX, y: 1)), "the bottom is straight")
        XCTAssertTrue(path.contains(NSPoint(x: rect.midX, y: rect.maxY - 1)), "so is the top")
    }

    func testAStemlessCouponPopoverWearsTheOutlineAndKeepsItsContentClear() throws {
        let style = AppTheme.Material.PopoverStyle(arrow: .none, edge: .coupon)
        let placement = ThemedPopoverLayout.place(
            anchor: NSRect(x: 400, y: 400, width: 20, height: 20),
            contentSize: NSSize(width: 220, height: 140),
            visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 1000),
            preferredEdge: .minY,
            style: style,
            hasMaterialShadow: false
        )
        let stroke = Design.Radius.border
        let outline = ThemedPopoverLayout.outline(
            for: placement,
            cornerRadius: Design.Radius.panel,
            strokeWidth: stroke
        )
        let body = placement.bodyFrame.insetBy(dx: stroke / 2, dy: stroke / 2)
        let radius = min(Design.Radius.panel, min(body.width, body.height) / 2)
        let centres = CouponOutline.biteCentres(along: (body.minY + radius)...(body.maxY - radius))
        let bite = try XCTUnwrap(centres.dropFirst(centres.count / 2).first)

        XCTAssertFalse(outline.contains(NSPoint(x: body.minX + 1, y: bite)))
        XCTAssertTrue(outline.contains(NSPoint(x: body.midX, y: body.midY)))
        XCTAssertGreaterThanOrEqual(
            placement.contentFrame.minX - placement.bodyFrame.minX,
            CouponOutline.depth,
            "content keeps clear of the bites"
        )
    }

    func testACouponEdgeRequiresAStemlessPopover() throws {
        var material = try lightVariant().material
        material.popoverStyle = .init(arrow: .triangle, edge: .coupon)
        XCTAssertThrowsError(try AppThemeEditing.validate(fixture(material: material)))

        material.popoverStyle = .init(arrow: .none, edge: .coupon)
        XCTAssertNoThrow(try AppThemeEditing.validate(fixture(material: material)))
    }

    // MARK: - Window

    func testGlossDefaultsToWhiteWhateverTheInk() throws {
        let resolved = WindowChromeAppearance.resolved(from: chrome(
            ink: .black,
            texture: .init(kind: .gloss)
        ))
        let colour = try XCTUnwrap(resolved.activeTexture?.color.usingColorSpace(.sRGB))
        XCTAssertEqual(colour.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(colour.greenComponent, 1, accuracy: 0.01)
        XCTAssertEqual(
            colour.alphaComponent,
            WindowChromeStyleLimits.defaultGlossAlpha,
            accuracy: 0.01
        )
    }

    func testGlossLightensTheTopOfTheBandAndLeavesItsFootAlone() throws {
        let glossy = try bandRender(texture: .init(kind: .gloss))
        let plain = try bandRender(texture: nil)
        let x = glossy.pixelsWide / 2
        let top = 2
        let foot = glossy.pixelsHigh - 3

        XCTAssertGreaterThan(
            try brightness(glossy, x: x, y: top),
            try brightness(plain, x: x, y: top) + 0.08,
            "the sheen lifts the band's upper edge"
        )
        XCTAssertEqual(
            try brightness(glossy, x: x, y: foot),
            try brightness(plain, x: x, y: foot),
            accuracy: 0.02,
            "and is gone by its foot"
        )
    }

    func testPillsAreRoundPlatesInTheBandsInkWithTheFigureCutOut() throws {
        let anatomy = WindowChromeCaptionAnatomy.of(.pills)
        XCTAssertEqual(anatomy.slotSize, NSSize(width: 16, height: 16))
        XCTAssertTrue(anatomy.plateFollowsKeyState, "the plate is the ink, so it dims with it")

        let button = WindowChromeButton(role: .close)
        button.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        button.fixtureIsKey = true
        button.fixtureStyle = WindowChromeAppearance.resolved(from: chrome(
            ink: .white,
            glyphs: .pills
        ))
        let rep = try render(button)
        let scale = CGFloat(rep.pixelsWide) / button.bounds.width

        let rim = try colour(rep, x: Int(8 * scale), y: Int(2.5 * scale))
        XCTAssertGreaterThan(rim.redComponent, 0.85, "the plate is the band's white ink")
        let corner = try colour(rep, x: 0, y: 0)
        XCTAssertLessThan(corner.alphaComponent, 0.1, "and round, so its corners stay clear")
        let centre = try colour(rep, x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
        XCTAssertLessThan(centre.redComponent, 0.5, "the close cross is cut out to the band")
    }

    // MARK: - Shop Controls

    func testARoundCheckIsACircleFilledWithTheAccent() throws {
        let round = try checkboxAccentGeometry(style: .round)
        XCTAssertFalse(round.cornerIsAccent, "a circle leaves its bounding corner clear")
        XCTAssertTrue(round.edgeMidpointIsAccent)

        let modern = try checkboxAccentGeometry(style: .automatic)
        XCTAssertTrue(modern.cornerIsAccent, "the modern box reaches further into its corner")
        XCTAssertFalse(
            AppTheme.Material.CheckboxStyle.round.isHistorical,
            "round keeps the modern size, hover plate and disabled dimming"
        )
    }

    func testStripedProgressIsATallerCapsuleCrossedByStripes() throws {
        try wear { $0.progressStyle = .striped }
        let bar = ThemedProgressBar(frame: NSRect(
            x: 0, y: 0, width: 200, height: ThemedProgressDrawing.stripedHeight
        ))
        XCTAssertEqual(bar.intrinsicContentSize.height, ThemedProgressDrawing.stripedHeight)
        bar.progress = 1

        let rep = try render(bar)
        let row = rep.pixelsHigh / 2
        let samples = try stride(from: rep.pixelsWide / 8, to: rep.pixelsWide * 7 / 8, by: 1)
            .map { try brightness(rep, x: $0, y: row) }
        XCTAssertGreaterThan(
            (samples.max() ?? 0) - (samples.min() ?? 0),
            0.08,
            "the fill is crossed by light stripes"
        )
        XCTAssertLessThan(
            try colour(rep, x: 0, y: 0).alphaComponent,
            0.5,
            "and its ends are round"
        )
    }

    func testAPillScrollerKeepsTheModernGeometry() {
        XCTAssertFalse(AppTheme.Material.ScrollerAppearance.pill.usesLegacyPresentation)
        XCTAssertTrue(AppTheme.Material.ScrollerAppearance.amiga.usesLegacyPresentation)
    }

    func testAnOutlinedFieldWearsTheAccentAtRest() throws {
        let outlinedEdge = try fieldEdgeColour(style: .outlined)
        let wellEdge = try fieldEdgeColour(style: .well)
        let accent = try XCTUnwrap(Self.accent.usingColorSpace(.sRGB))

        XCTAssertEqual(outlinedEdge.redComponent, accent.redComponent, accuracy: 0.12)
        XCTAssertEqual(outlinedEdge.greenComponent, accent.greenComponent, accuracy: 0.12)
        let distance = abs(wellEdge.redComponent - accent.redComponent)
            + abs(wellEdge.greenComponent - accent.greenComponent)
            + abs(wellEdge.blueComponent - accent.blueComponent)
        XCTAssertGreaterThan(distance, 0.3, "an ordinary well rests on its structural border")
    }

    // MARK: - Sticker Badge

    func testAStickerReservesItsTiltedPlateAndSpeaksItsText() {
        let sticker = ThemedStickerBadge(text: "12")
        let ink = ("12" as NSString).size(withAttributes: [
            .font: Design.Typography.numericDetail(weight: .bold)
        ])
        XCTAssertGreaterThan(sticker.intrinsicContentSize.width, ink.width)
        XCTAssertGreaterThan(sticker.intrinsicContentSize.height, ink.height)
        XCTAssertEqual(sticker.accessibilityValue() as? String, "12")
        XCTAssertEqual(sticker.accessibilityRole(), .staticText)
    }

    func testAStickerThemeSetsTheProjectCountAsAStickerAndBack() throws {
        let project = Project(name: "Threading", folderURL: URL(fileURLWithPath: "/tmp/Threading"))
        let row = ProjectRowView(customizationLookup: { _ in .empty })

        try wear { $0.badgeStyle = .sticker }
        row.configure(with: project, collapsedSessionCount: 3)
        let sticker = try XCTUnwrap(stickers(in: row).first { !$0.isHidden })
        XCTAssertEqual(sticker.text, "3")
        XCTAssertFalse(row.countLabelIsMaterialized, "the quiet label is never made")

        AppThemePalette.set(.system)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppTheme.system.id))
        XCTAssertTrue(sticker.isHidden, "a switch away restates the count as a number")
        XCTAssertTrue(row.countLabelIsMaterialized)
    }

    // MARK: - Wire

    func testOldMaterialDocumentsDecodeToTheQuietDefaults() throws {
        let data = Data(#"{"panelRadius": 8, "controlRadius": 4}"#.utf8)
        let material = try JSONDecoder().decode(AppTheme.Material.self, from: data)
        XCTAssertEqual(material.fieldStyle, .well)
        XCTAssertEqual(material.badgeStyle, .plain)
    }

    func testTheToolAuthorsAndReportsEveryShopValue() async throws {
        let name = "Shop Vocabulary Theme \(UUID().uuidString)"
        let created = try call("""
            {
              "name": "create_app_theme",
              "arguments": {
                "name": "\(name)",
                "base_id": "swiss-minimalist",
                "appearance": "light",
                "variants": {
                  "light": {
                    "material": {
                      "popover_style": {"arrow": "none", "edge": "coupon"},
                      "checkbox_style": "round",
                      "progress_style": "striped",
                      "scroller_appearance": "pill",
                      "field_style": "outlined",
                      "badge_style": "sticker"
                    },
                    "chrome": {
                      "title_bar": {
                        "active_gradient": {"stops": [
                          {"color": "#C04A00", "position": 0},
                          {"color": "#A03C00", "position": 1}
                        ]},
                        "ink": "#FFFFFF",
                        "button_glyph_style": "pills",
                        "active_texture": {"kind": "gloss"}
                      }
                    }
                  }
                },
                "apply": false
              }
            }
            """)
        let arguments: CreateAppThemeArguments = try requireToolArguments(
            created,
            tool: .createAppTheme
        )
        let result = await coordinator().createAppTheme(arguments)
        XCTAssertFalse(result.isError, result.text)
        let theme = try XCTUnwrap(AppThemeLibrary.all.first { $0.name == name })
        defer { _ = AppThemeLibrary.delete(theme) }

        let variant = try XCTUnwrap(theme.variant(.light))
        XCTAssertEqual(variant.material.popoverStyle.edge, .coupon)
        XCTAssertEqual(variant.material.checkboxStyle, .round)
        XCTAssertEqual(variant.material.progressStyle, .striped)
        XCTAssertEqual(variant.material.scrollerAppearance, .pill)
        XCTAssertEqual(variant.material.fieldStyle, .outlined)
        XCTAssertEqual(variant.material.badgeStyle, .sticker)
        XCTAssertEqual(variant.chrome?.titleBar.buttonGlyphStyle, .pills)
        XCTAssertEqual(variant.chrome?.titleBar.activeTexture?.kind, .gloss)

        let document = coordinator().getAppTheme(
            AppThemeReferenceArguments(themeID: theme.id.rawValue)
        ).text
        for value in ["\"coupon\"", "\"round\"", "\"striped\"", "\"pill\"", "\"outlined\"",
                      "\"sticker\"", "\"pills\"", "\"gloss\""] {
            XCTAssertTrue(document.contains(value), "get_app_theme reports \(value)")
        }
    }

    func testRefusalsNameTheNewValues() async throws {
        let refused = try call("""
            {
              "name": "create_app_theme",
              "arguments": {
                "name": "Refused \(UUID().uuidString)",
                "base_id": "swiss-minimalist",
                "appearance": "light",
                "variants": {"light": {"material": {"field_style": "sunken"}}},
                "apply": false
              }
            }
            """)
        let arguments: CreateAppThemeArguments = try requireToolArguments(
            refused,
            tool: .createAppTheme
        )
        let result = await coordinator().createAppTheme(arguments)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("\"outlined\""), result.text)
    }

    // MARK: - Render

    /// Draws every part of the vocabulary under one shop-like fixture, light, to
    /// `$THREADING_RENDER_OUT/shop-vocabulary.png` — the picture a reviewer reads, since a
    /// scallop or a sticker's lean is noticed in a render rather than in any assertion.
    func testRendersTheShopVocabulary() throws {
        try wear { material in
            material.popoverStyle = .init(arrow: .none, edge: .coupon)
            material.checkboxStyle = .round
            material.progressStyle = .striped
            material.scrollerAppearance = .pill
            material.fieldStyle = .outlined
            material.badgeStyle = .sticker
        }
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))

        let band = WindowTitleBandView(appIconProvider: { nil })
        band.translatesAutoresizingMaskIntoConstraints = true
        band.frame = NSRect(x: 20, y: 500, width: 380, height: 38)
        band.fixtureIsKey = true
        band.fixtureStyle = WindowChromeAppearance.resolved(from: WindowChromeStyle(
            titleBar: .init(
                activeGradient: .init(stops: [
                    .init(color: NSColor(srgbRed: 0.94, green: 0.42, blue: 0, alpha: 1), position: 0),
                    .init(color: NSColor(srgbRed: 0.87, green: 0.35, blue: 0, alpha: 1), position: 1)
                ], angleDegrees: 180),
                ink: .white,
                height: 38,
                buttonGlyphStyle: .pills,
                buttonPlacement: .leading,
                activeTexture: .init(kind: .gloss)
            )
        ))
        canvas.addSubview(band)

        let style = AppTheme.Material.PopoverStyle(arrow: .none, edge: .coupon)
        let placement = ThemedPopoverLayout.place(
            anchor: NSRect(x: 100, y: 400, width: 20, height: 20),
            contentSize: NSSize(width: 170, height: 110),
            visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 1000),
            preferredEdge: .minY,
            style: style,
            hasMaterialShadow: false
        )
        let popover = ThemedPopoverChromeView(frame: NSRect(
            origin: NSPoint(x: 20, y: 340),
            size: placement.panelFrame.size
        ))
        popover.placement = placement
        canvas.addSubview(popover)

        let menu = ThemedMenuReferenceFixture.make(
            entries: ["Add to cart", "Apply coupon", "Spin the wheel"].map {
                .item(ThemedMenuItem(title: $0))
            },
            size: NSSize(width: 170, height: 110),
            highlightedEntryIndex: 1
        )
        menu.frame.origin = NSPoint(x: 230, y: 340)
        canvas.addSubview(menu)

        let checked = ThemedCheckbox(title: "Free shipping", state: .on) { _ in }
        checked.frame = NSRect(origin: NSPoint(x: 20, y: 290), size: checked.intrinsicContentSize)
        let unchecked = ThemedCheckbox(title: "Gift wrap", state: .off) { _ in }
        unchecked.frame = NSRect(origin: NSPoint(x: 220, y: 290), size: unchecked.intrinsicContentSize)
        canvas.addSubview(checked)
        canvas.addSubview(unchecked)

        let bar = ThemedProgressBar(frame: NSRect(
            x: 20, y: 260, width: 380, height: ThemedProgressDrawing.stripedHeight
        ))
        bar.progress = 0.72
        canvas.addSubview(bar)

        let field = ThemedTextField(frame: NSRect(x: 20, y: 200, width: 380, height: 32))
        field.placeholderString = "Search deals"
        canvas.addSubview(field)

        let toast = ToastView(request: ToastRequest(message: "Coupon applied: 90% off"))
        toast.translatesAutoresizingMaskIntoConstraints = true
        toast.frame = NSRect(x: 20, y: 60, width: 380, height: 52)
        canvas.addSubview(toast)

        var x: CGFloat = 20
        for text in ["3", "12", "main", "v2.0"] {
            let sticker = ThemedStickerBadge(text: text)
            sticker.frame = NSRect(origin: NSPoint(x: x, y: 150), size: sticker.intrinsicContentSize)
            canvas.addSubview(sticker)
            x += sticker.intrinsicContentSize.width + Design.Spacing.large
        }

        canvas.layoutSubtreeIfNeeded()
        let rep = try render(canvas)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let directory = Self.renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("shop-vocabulary.png"))
    }

    private static var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    // MARK: - Fixtures

    private static let accent = NSColor(srgbRed: 0.85, green: 0.15, blue: 0.55, alpha: 1)

    private func lightVariant() throws -> AppTheme.Variant {
        try XCTUnwrap(AppThemeStyles.swissMinimalist.variant(.light))
    }

    private func fixture(material: AppTheme.Material) throws -> AppTheme {
        var roles = try lightVariant().roles
        roles[.accent] = Self.accent
        return AppTheme(
            id: AppThemeID("shop-vocabulary-fixture"),
            name: "Shop Vocabulary Fixture",
            mode: .light,
            summary: nil,
            variants: [.light: try lightVariant().replacing(roles: roles, material: material)]
        )
    }

    /// Applies the fixture theme with one material change.
    private func wear(_ change: (inout AppTheme.Material) -> Void) throws {
        var material = try lightVariant().material
        change(&material)
        AppThemePalette.set(try fixture(material: material))
    }

    private func chrome(
        ink: NSColor,
        glyphs: WindowChromeStyle.TitleBar.ButtonGlyphStyle = .plain,
        texture: WindowChromeStyle.TitleBar.Texture? = nil
    ) -> WindowChromeStyle {
        let navy = NSColor(srgbRed: 0, green: 0, blue: 0.5, alpha: 1)
        return WindowChromeStyle(titleBar: .init(
            activeGradient: .init(stops: [
                .init(color: navy, position: 0),
                .init(color: navy, position: 1)
            ], angleDegrees: 180),
            ink: ink,
            buttonGlyphStyle: glyphs,
            activeTexture: texture
        ))
    }

    private func bandRender(
        texture: WindowChromeStyle.TitleBar.Texture?
    ) throws -> NSBitmapImageRep {
        let band = WindowTitleBandView(appIconProvider: { nil })
        band.translatesAutoresizingMaskIntoConstraints = true
        band.frame = NSRect(x: 0, y: 0, width: 320, height: 32)
        band.fixtureIsKey = true
        band.fixtureStyle = WindowChromeAppearance.resolved(from: chrome(
            ink: .white,
            texture: texture
        ))
        band.layoutSubtreeIfNeeded()
        return try render(band)
    }

    private func checkboxAccentGeometry(
        style: AppTheme.Material.CheckboxStyle
    ) throws -> (cornerIsAccent: Bool, edgeMidpointIsAccent: Bool) {
        try wear { $0.checkboxStyle = style }
        let checkbox = ThemedCheckbox(title: "", state: .on) { _ in }
        checkbox.frame = NSRect(origin: .zero, size: checkbox.intrinsicContentSize)
        let rep = try render(checkbox)

        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where try isAccent(colour(rep, x: x, y: y)) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertLessThan(minX, maxX, "the checked box draws accent ink")
        let inset = max(1, (maxX - minX) / 10)
        return (
            try isAccent(colour(rep, x: minX + inset, y: minY + inset)),
            try isAccent(colour(rep, x: minX + 1, y: (minY + maxY) / 2))
        )
    }

    private func fieldEdgeColour(style: AppTheme.Material.FieldStyle) throws -> NSColor {
        try wear { $0.fieldStyle = style }
        let field = ThemedTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        let rep = try render(field)
        let scale = CGFloat(rep.pixelsWide) / field.bounds.width
        return try colour(rep, x: Int(scale), y: rep.pixelsHigh / 2)
    }

    private func isAccent(_ colour: NSColor) -> Bool {
        guard let accent = Self.accent.usingColorSpace(.sRGB) else { return false }
        return colour.alphaComponent > 0.8
            && abs(colour.redComponent - accent.redComponent) < 0.1
            && abs(colour.greenComponent - accent.greenComponent) < 0.1
            && abs(colour.blueComponent - accent.blueComponent) < 0.1
    }

    private func stickers(in view: NSView) -> [ThemedStickerBadge] {
        view.subviews.flatMap { subview -> [ThemedStickerBadge] in
            (subview as? ThemedStickerBadge).map { [$0] } ?? stickers(in: subview)
        }
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func colour(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        let raw = try XCTUnwrap(rep.colorAt(x: x, y: y), "no pixel at \(x), \(y)")
        return try XCTUnwrap(raw.usingColorSpace(.sRGB))
    }

    private func brightness(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> CGFloat {
        let pixel = try colour(rep, x: x, y: y)
        return (pixel.redComponent + pixel.greenComponent + pixel.blueComponent) / 3
    }

    private func call(_ json: String) throws -> MCPToolCall {
        try JSONDecoder()
            .decode(MCPToolCallParameters.self, from: Data(json.utf8))
            .call
    }

    private func coordinator() -> AgentToolCoordinator {
        AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
    }
}
