import AppKit
import XCTest
@testable import Threading

/// The chrome block of a theme document: its wire forms, the editing seams that must not drop
/// it, and the gates that refuse a band the window's own buttons could not be read on.
final class WindowChromeStyleTests: XCTestCase {

    private var previousTheme: AppTheme!

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            previousTheme = AppThemeLibrary.current
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            AppThemeLibrary.apply(previousTheme)
            // `apply` early-returns when the library already held this theme, so a palette a
            // test set directly would survive it. Resync explicitly.
            AppThemePalette.set(previousTheme)
        }
        super.tearDown()
    }

    private static let scratchThemeID = AppThemeID("custom-window-chrome-style-tests")

    // MARK: - Fixtures

    /// A band any gate should accept: white ink on the navy every titlebar of 1998 wore.
    private func navyTitleBar() -> WindowChromeStyle.TitleBar {
        WindowChromeStyle.TitleBar(
            activeGradient: .init(stops: [
                .init(color: NSColor(hex: "#000080")!, position: 0),
                .init(color: NSColor(hex: "#1084D0")!, position: 1)
            ], angleDegrees: 90),
            ink: .white
        )
    }

    @MainActor
    private func themed(_ chrome: WindowChromeStyle) throws -> AppTheme {
        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        return try AppThemeEditing.assemble(
            id: Self.scratchThemeID,
            name: "Gated",
            mode: kind == .dark ? .dark : .light,
            summary: nil,
            variants: [kind: AppThemeEditing.makeVariant(
                named: "Gated", from: base, kind: kind, chrome: .set(chrome)
            )]
        )
    }

    // MARK: - Wire forms

    func testAFullChromeStyleRoundTripsThroughItsDocumentForm() throws {
        let style = WindowChromeStyle(
            titleBar: WindowChromeStyle.TitleBar(
                activeGradient: .init(stops: [
                    .init(color: NSColor(hex: "#000080")!, position: 0),
                    .init(color: NSColor(hex: "#1084D0")!, position: 1)
                ], angleDegrees: 90),
                inactiveGradient: .init(stops: [
                    .init(color: NSColor(hex: "#808080")!, position: 0),
                    .init(color: NSColor(hex: "#B5B5B5")!, position: 1)
                ], angleDegrees: 90),
                ink: NSColor(hex: "#FFFFFF")!,
                inactiveInk: NSColor(hex: "#F0F0F0")!,
                titleAlignment: .center,
                titleFontStyle: .italic,
                height: 30,
                buttonGlyphStyle: .platinum,
                buttonPlacement: .split,
                showsAppIcon: false,
                activeTexture: .init(
                    kind: .pinstripes,
                    color: NSColor(hex: "#777777")!,
                    spacing: 3
                ),
                inactiveTexture: .init(kind: .pinstripes),
                shape: .leadingTab,
                tabWidth: 210,
                visibleButtons: [.close, .zoom, .depth]
            ),
            frame: .init(width: 4)
        )

        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(WindowChromeStyle.self, from: data)
        XCTAssertEqual(decoded, style)
    }

    /// A document written before the block existed decodes to a variant without one — the
    /// absent-means-default rule every other theme field follows.
    func testAVariantDocumentWithoutAChromeBlockDecodesToNone() throws {
        let json = """
        {
            "roles": {},
            "terminalPalette": \(String(
                data: try JSONEncoder().encode(TerminalTheme.basic), encoding: .utf8
            )!)
        }
        """
        let variant = try JSONDecoder().decode(AppTheme.Variant.self, from: Data(json.utf8))
        XCTAssertNil(variant.chrome)
    }

    /// Every field but the active gradient is optional on the wire; a minimal document decodes
    /// to the defaults the app used before the field existed.
    func testOptionalFieldsAbsentOnTheWireDecodeToDefaults() throws {
        let json = """
        {
            "titleBar": {
                "activeGradient": {
                    "stops": [
                        {"color": "#000080", "position": 0},
                        {"color": "#1084D0", "position": 1}
                    ]
                }
            }
        }
        """
        let style = try JSONDecoder().decode(WindowChromeStyle.self, from: Data(json.utf8))
        XCTAssertNil(style.titleBar.ink)
        XCTAssertNil(style.titleBar.inactiveGradient)
        XCTAssertNil(style.titleBar.height)
        XCTAssertEqual(style.titleBar.titleAlignment, .leading)
        XCTAssertEqual(style.titleBar.titleFontStyle, .upright)
        XCTAssertEqual(style.titleBar.buttonGlyphStyle, .plain)
        XCTAssertEqual(style.titleBar.buttonPlacement, .trailing)
        XCTAssertTrue(style.titleBar.showsAppIcon)
        XCTAssertNil(style.titleBar.activeTexture)
        XCTAssertNil(style.titleBar.inactiveTexture)
        XCTAssertEqual(style.titleBar.shape, .fullWidth)
        XCTAssertNil(style.titleBar.tabWidth)
        XCTAssertEqual(style.titleBar.visibleButtons, [.minimize, .zoom, .close])
        XCTAssertNil(style.frame)
    }

    // MARK: - Editing

    /// `assemble` rebuilds every variant for its rename pass; a chrome block dropped there
    /// would vanish on every create and update while looking untouched in the patch — the
    /// exact trap `SidebarStyleTests` pins for the sidebar.
    @MainActor
    func testAssembleCarriesTheChromeThroughItsRenamePass() throws {
        let style = WindowChromeStyle(titleBar: navyTitleBar(), frame: .init(width: 2))
        let theme = try themed(style)
        let kind = theme.availableVariants[0]
        XCTAssertEqual(theme.variant(kind)?.chrome, style)
        XCTAssertTrue(theme.takesOverWindowChrome)
        XCTAssertEqual(
            theme.windowChrome(for: kind.appearance ?? NSAppearance.currentDrawing()),
            style
        )
    }

    /// An update that says nothing about the chrome must not hand the window frame back to
    /// AppKit; one that says `remove` must. The reason `ChromeChange` exists.
    @MainActor
    func testMakeVariantInheritsRemovesAndReplacesTheChromeDistinctly() throws {
        let stated = WindowChromeStyle(titleBar: navyTitleBar())
        let carrier = try themed(stated)
        let kind = carrier.availableVariants[0]

        let inherited = AppThemeEditing.makeVariant(named: "A", from: carrier, kind: kind)
        XCTAssertEqual(inherited.chrome, stated, "an untouched patch dropped the chrome")

        let removed = AppThemeEditing.makeVariant(
            named: "B", from: carrier, kind: kind, chrome: .remove
        )
        XCTAssertNil(removed.chrome)

        let replacement = WindowChromeStyle(titleBar: navyTitleBar(), frame: .init(width: 3))
        let replaced = AppThemeEditing.makeVariant(
            named: "C", from: carrier, kind: kind, chrome: .set(replacement)
        )
        XCTAssertEqual(replaced.chrome, replacement)
    }

    // MARK: - Validation

    /// The band's ink is the window's title and buttons; a band it cannot be read on loses
    /// the window its close button. Same gate as sidebar text, same floor — but only while
    /// the window is key: the inactive band deliberately gets the softer "tellable" floor,
    /// because inactive title text signals inactivity by carrying less ink.
    @MainActor
    func testTheActiveBandGetsTheLabelFloorAndTheInactiveBandTheSofterOne() throws {
        // White ink on a mid-gray reads at about 2.7:1 — above the tellable floor, below the
        // label's. As an active band it must be refused; as an inactive one, accepted.
        let midGray = SidebarStyle.Gradient(stops: [
            .init(color: NSColor(hex: "#9E9E9E")!, position: 0),
            .init(color: NSColor(hex: "#9E9E9E")!, position: 1)
        ])

        XCTAssertThrowsError(try themed(WindowChromeStyle(
            titleBar: .init(activeGradient: midGray, ink: .white)
        )), "an active band the ink cannot be read on should be refused")

        var titleBar = navyTitleBar()
        titleBar.inactiveGradient = midGray
        titleBar.inactiveInk = .white
        XCTAssertNoThrow(try themed(WindowChromeStyle(titleBar: titleBar)))

        // Below even the tellable floor the inactive band is refused too.
        var invisible = navyTitleBar()
        invisible.inactiveGradient = SidebarStyle.Gradient(stops: [
            .init(color: NSColor(hex: "#B5B5B5")!, position: 0),
            .init(color: NSColor(hex: "#B5B5B5")!, position: 1)
        ])
        invisible.inactiveInk = NSColor(hex: "#D4D0C8")!
        XCTAssertThrowsError(try themed(WindowChromeStyle(titleBar: invisible)))
    }

    @MainActor
    func testChromeBoundsAreEnforced() throws {
        var oneStop = navyTitleBar()
        oneStop.activeGradient = .init(stops: [.init(color: .black, position: 0)])
        XCTAssertThrowsError(try themed(WindowChromeStyle(titleBar: oneStop)),
                             "one stop is a fill pretending to be a gradient")

        var wayward = navyTitleBar()
        wayward.activeGradient = .init(stops: [
            .init(color: .black, position: -0.5),
            .init(color: .black, position: 1)
        ])
        XCTAssertThrowsError(try themed(WindowChromeStyle(titleBar: wayward)),
                             "a stop outside 0...1 should be refused")

        var tooTall = navyTitleBar()
        tooTall.height = 60
        XCTAssertThrowsError(try themed(WindowChromeStyle(titleBar: tooTall)),
                             "a band taller than a title bar should be refused")

        var tooShort = navyTitleBar()
        tooShort.height = 12
        XCTAssertThrowsError(try themed(WindowChromeStyle(titleBar: tooShort)),
                             "a band its own buttons cannot fit in should be refused")

        XCTAssertThrowsError(try themed(WindowChromeStyle(
            titleBar: navyTitleBar(), frame: .init(width: 12)
        )), "a frame past the resize edges should be refused")

        var packedTexture = navyTitleBar()
        packedTexture.activeTexture = .init(kind: .pinstripes, spacing: 1)
        XCTAssertThrowsError(try themed(WindowChromeStyle(titleBar: packedTexture)),
                             "texture strokes packed into a solid fill should be refused")

        var sparseTexture = navyTitleBar()
        sparseTexture.inactiveTexture = .init(kind: .pinstripes, spacing: 9)
        XCTAssertThrowsError(try themed(WindowChromeStyle(titleBar: sparseTexture)),
                             "a texture too sparse to read as title chrome should be refused")

        var narrowTab = navyTitleBar()
        narrowTab.shape = .leadingTab
        narrowTab.tabWidth = 119
        XCTAssertThrowsError(try themed(WindowChromeStyle(titleBar: narrowTab)),
                             "a tab too narrow for its furniture should be refused")

        var wideTab = navyTitleBar()
        wideTab.shape = .leadingTab
        wideTab.tabWidth = 361
        XCTAssertThrowsError(try themed(WindowChromeStyle(titleBar: wideTab)),
                             "a title tab that stops reading as a tab should be refused")

        var noButtons = navyTitleBar()
        noButtons.visibleButtons = []
        XCTAssertThrowsError(try themed(WindowChromeStyle(titleBar: noButtons)),
                             "custom chrome must leave a visible way to operate the window")

        var duplicateButton = navyTitleBar()
        duplicateButton.visibleButtons = [.close, .close]
        XCTAssertThrowsError(try themed(WindowChromeStyle(titleBar: duplicateButton)),
                             "one semantic window operation may not be drawn twice")

        XCTAssertNoThrow(try themed(WindowChromeStyle(
            titleBar: navyTitleBar(), frame: .init(width: 4)
        )))
    }

    /// Band colours may differ between appearances; whether the window wears its own frame
    /// may not — an adaptive theme flipping frames with the weather would rebuild the window
    /// chrome every sunset.
    @MainActor
    func testAnAdaptiveThemeStatesChromeInBothVariantsOrNeither() throws {
        let base = AppThemeStyles.christmas
        XCTAssertEqual(Set(base.availableVariants), Set(AppTheme.VariantKind.allCases),
                       "the fixture needs the one stock adaptive theme")

        let chrome = WindowChromeStyle(titleBar: navyTitleBar())

        XCTAssertThrowsError(try AppThemeEditing.assemble(
            id: Self.scratchThemeID,
            name: "Lopsided",
            mode: .system,
            summary: nil,
            variants: [
                .light: AppThemeEditing.makeVariant(
                    named: "Lopsided", from: base, kind: .light, chrome: .set(chrome)
                ),
                .dark: AppThemeEditing.makeVariant(named: "Lopsided", from: base, kind: .dark)
            ]
        ), "chrome in one variant of an adaptive theme should be refused")

        XCTAssertNoThrow(try AppThemeEditing.assemble(
            id: Self.scratchThemeID,
            name: "Even",
            mode: .system,
            summary: nil,
            variants: [
                .light: AppThemeEditing.makeVariant(
                    named: "Even", from: base, kind: .light, chrome: .set(chrome)
                ),
                .dark: AppThemeEditing.makeVariant(
                    named: "Even", from: base, kind: .dark, chrome: .set(chrome)
                )
            ]
        ))
    }
}
