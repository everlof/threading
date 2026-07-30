import AppKit
import XCTest
@testable import Threading

/// The sidebar block of a theme document: its wire forms, the gates that refuse a sidebar the
/// user could not read their way out of, and the resolution that turns a stated style into
/// drawable values.
final class SidebarStyleTests: XCTestCase {

    private var previousTheme: AppTheme!

    @MainActor
    override func setUp() {
        super.setUp()
        previousTheme = AppThemeLibrary.current
    }

    @MainActor
    override func tearDown() {
        AppThemeLibrary.apply(previousTheme)
        ThemeAssetStore.removeAll(for: Self.scratchThemeID)
        super.tearDown()
    }

    private static let scratchThemeID = AppThemeID("custom-sidebar-style-tests")

    // MARK: - Wire forms

    func testAFullSidebarStyleRoundTripsThroughItsDocumentForm() throws {
        let style = SidebarStyle(
            background: SidebarStyle.Background(
                gradient: SidebarStyle.Gradient(
                    stops: [
                        .init(color: NSColor(hex: "#101020")!, position: 0),
                        .init(color: NSColor(hex: "#202040")!, position: 1)
                    ],
                    angleDegrees: 135
                ),
                image: SidebarStyle.ImageLayer(asset: "dark-background.png", mode: .tile, opacity: 0.4)
            ),
            brand: SidebarStyle.Brand(
                logo: .asset("dark-logo.png"),
                title: SidebarStyle.Brand.Title(
                    text: "Sonda",
                    fontFamily: "Baskerville",
                    fontSize: 15,
                    weight: .bold,
                    hidden: false
                )
            )
        )

        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(SidebarStyle.self, from: data)
        XCTAssertEqual(decoded, style)
    }

    /// `"mark"` and `"hidden"` are bare words; an asset is an object — so a theme cannot ship
    /// a file named "hidden" and lose its logo to the collision.
    func testTheLogoWireFormKeepsWordsAndAssetsApart() throws {
        let decoder = JSONDecoder()

        func logo(_ json: String) throws -> SidebarStyle.Brand.Logo {
            try decoder.decode(SidebarStyle.Brand.Logo.self, from: Data(json.utf8))
        }

        XCTAssertEqual(try logo("\"mark\""), .mark)
        XCTAssertEqual(try logo("\"hidden\""), .hidden)
        XCTAssertEqual(try logo("{\"asset\": \"hidden\"}"), .asset("hidden"))
        XCTAssertThrowsError(try logo("\"sparkles\""))
    }

    /// A document written before the block existed decodes to a variant without one — the
    /// same absent-means-default rule every other theme field follows.
    func testAVariantDocumentWithoutASidebarBlockDecodesToNone() throws {
        let json = """
        {
            "roles": {},
            "terminalPalette": \(String(
                data: try JSONEncoder().encode(TerminalTheme.basic), encoding: .utf8
            )!)
        }
        """
        let variant = try JSONDecoder().decode(AppTheme.Variant.self, from: Data(json.utf8))
        XCTAssertNil(variant.sidebar)
    }

    // MARK: - Editing

    /// `assemble` rebuilds every variant for its rename pass; a sidebar dropped there would
    /// vanish on every create and update while looking untouched in the patch.
    @MainActor
    func testAssembleCarriesTheSidebarThroughItsRenamePass() throws {
        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        let style = SidebarStyle(brand: SidebarStyle.Brand(logo: .hidden, title: nil))
        let variant = AppThemeEditing.makeVariant(
            named: "Carried",
            from: base,
            kind: kind,
            sidebar: .set(style)
        )
        let theme = try AppThemeEditing.assemble(
            id: Self.scratchThemeID,
            name: "Carried",
            mode: kind == .dark ? .dark : .light,
            summary: nil,
            variants: [kind: variant]
        )
        XCTAssertEqual(theme.variant(kind)?.sidebar, style)
    }

    /// An update that says nothing about the sidebar must not strip it; one that says
    /// `remove` must. A plain optional cannot carry that difference, which is the reason
    /// `SidebarChange` exists.
    @MainActor
    func testMakeVariantInheritsRemovesAndReplacesTheSidebarDistinctly() throws {
        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        let stated = SidebarStyle(brand: SidebarStyle.Brand(logo: .hidden))
        let carrier = try AppThemeEditing.assemble(
            id: Self.scratchThemeID,
            name: "Carrier",
            mode: kind == .dark ? .dark : .light,
            summary: nil,
            variants: [kind: AppThemeEditing.makeVariant(
                named: "Carrier", from: base, kind: kind, sidebar: .set(stated)
            )]
        )

        let inherited = AppThemeEditing.makeVariant(named: "A", from: carrier, kind: kind)
        XCTAssertEqual(inherited.sidebar, stated, "an untouched patch dropped the sidebar")

        let removed = AppThemeEditing.makeVariant(
            named: "B", from: carrier, kind: kind, sidebar: .remove
        )
        XCTAssertNil(removed.sidebar)

        let empty = AppThemeEditing.makeVariant(
            named: "C", from: carrier, kind: kind, sidebar: .set(SidebarStyle())
        )
        XCTAssertNil(empty.sidebar, "an empty block should normalise to absence, not linger")
    }

    // MARK: - Validation

    @MainActor
    private func themed(_ sidebar: SidebarStyle) throws -> AppTheme {
        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        return try AppThemeEditing.assemble(
            id: Self.scratchThemeID,
            name: "Gated",
            mode: kind == .dark ? .dark : .light,
            summary: nil,
            variants: [kind: AppThemeEditing.makeVariant(
                named: "Gated", from: base, kind: kind, sidebar: .set(sidebar)
            )]
        )
    }

    /// The sidebar is where every session is found; a wash that swallows its labels locks
    /// the user out of the app as surely as an unreadable terminal. Same gate, same floor.
    @MainActor
    func testAGradientStopTheLabelCannotReadIsRefused() throws {
        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        let appearance = kind.appearance ?? NSAppearance.currentDrawing()
        let label = base.resolved(.label, appearance: appearance)

        XCTAssertThrowsError(try themed(SidebarStyle(
            background: .init(gradient: .init(stops: [
                .init(color: label, position: 0),
                .init(color: label, position: 1)
            ]))
        )), "a gradient painted in the label's own colour should be refused")

        // The surface's own colour is by definition readable under the label the theme passed
        // validation with.
        let surface = base.resolved(.surface, appearance: appearance)
        XCTAssertNoThrow(try themed(SidebarStyle(
            background: .init(gradient: .init(stops: [
                .init(color: surface, position: 0),
                .init(color: surface, position: 1)
            ]))
        )))
    }

    @MainActor
    func testGradientAndTitleBoundsAreEnforced() throws {
        let one = SidebarStyle.Gradient.Stop(color: .black, position: 0)
        XCTAssertThrowsError(try themed(SidebarStyle(
            background: .init(gradient: .init(stops: [one]))
        )), "one stop is a fill pretending to be a gradient")

        XCTAssertThrowsError(try themed(SidebarStyle(
            background: .init(gradient: .init(stops: [
                .init(color: .black, position: -0.5),
                .init(color: .black, position: 1)
            ]))
        )), "a stop outside 0...1 should be refused")

        XCTAssertThrowsError(try themed(SidebarStyle(
            brand: .init(title: .init(fontSize: 60))
        )), "a wordmark the band cannot hold should be refused, not clipped")

        XCTAssertThrowsError(try themed(SidebarStyle(
            brand: .init(logo: .hidden, title: .init(hidden: true))
        )), "a brand with nothing left in it should be removed, not stated")
    }

    // MARK: - Resolution

    /// Absence at every level resolves to the default brand: the mark beside the app's name.
    @MainActor
    func testTheDefaultBrandIsTheMarkBesideTheAppsName() {
        AppThemeLibrary.apply(.system)
        let brand = SidebarAppearance.brand()
        XCTAssertEqual(brand.logo, .mark)
        XCTAssertEqual(brand.title, AppInfo.name)
        XCTAssertNil(SidebarAppearance.background())
    }

    @MainActor
    func testAStatedBrandResolvesItsTitleAndHidesWhatItHides() throws {
        let theme = try themed(SidebarStyle(
            brand: .init(logo: .hidden, title: .init(text: "Atelier", weight: .bold))
        ))
        AppThemeLibrary.apply(theme)

        let kind = theme.availableVariants[0]
        let brand = SidebarAppearance.brand(
            for: kind.appearance ?? NSAppearance.currentDrawing()
        )
        XCTAssertEqual(brand.logo, .hidden)
        XCTAssertEqual(brand.title, "Atelier")
        XCTAssertEqual(
            brand.titleRole,
            .wordmark(family: nil, size: nil, weight: .bold)
        )
    }

    /// A name that resolves to no stored asset degrades to the default treatment — the rule
    /// every dangling theme reference follows.
    @MainActor
    func testADanglingAssetNameDegradesToTheDefault() throws {
        let theme = try themed(SidebarStyle(
            background: .init(image: .init(asset: "never-stored.png")),
            brand: .init(logo: .asset("never-stored.png"))
        ))
        AppThemeLibrary.apply(theme)

        let appearance = theme.availableVariants[0].appearance ?? NSAppearance.currentDrawing()
        XCTAssertNil(SidebarAppearance.background(for: appearance))
        XCTAssertEqual(SidebarAppearance.brand(for: appearance).logo, .mark)
    }

    /// A stored asset resolves, and the gradient arrives sorted whatever order it was authored.
    @MainActor
    func testStoredAssetsAndAuthoredStopsResolveForDrawing() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(
            NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        )
        let kind = AppThemeStyles.cyberpunk.availableVariants[0]
        let stored = try XCTUnwrap(ThemeAssetStore.store(
            imageData: png,
            for: Self.scratchThemeID,
            slot: .background,
            variant: kind
        ))

        let surface = AppThemeStyles.cyberpunk.resolved(
            .surface,
            appearance: kind.appearance ?? NSAppearance.currentDrawing()
        )
        let theme = try themed(SidebarStyle(
            background: .init(
                gradient: .init(stops: [
                    .init(color: surface, position: 1),
                    .init(color: surface, position: 0)
                ]),
                image: .init(asset: stored, mode: .tile, opacity: 0.5)
            )
        ))
        AppThemeLibrary.apply(theme)

        let appearance = kind.appearance ?? NSAppearance.currentDrawing()
        let background = try XCTUnwrap(SidebarAppearance.background(for: appearance))
        XCTAssertEqual(background.gradient?.locations, [0, 1], "stops should arrive sorted")
        XCTAssertEqual(background.image?.opacity, 0.5)
        XCTAssertNotNil(background.image?.image)
    }
}
