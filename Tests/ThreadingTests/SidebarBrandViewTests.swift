import AppKit
import XCTest
@testable import Threading

/// The brand row and the mark that anchors it: what the sidebar's top-left shows by default,
/// how a chrome restates it, and how the launch flourish behaves when motion is reduced.
final class SidebarBrandViewTests: XCTestCase {

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
            Design.Motion.reduceMotionOverrideForTesting = nil
        }
        super.tearDown()
    }

    // MARK: - The mark

    func testTheMarkStatesItsGeometryAtAnySize() {
        let box = CGRect(x: 0, y: 0, width: 64, height: 64)
        XCTAssertFalse(ThreadingMarkGeometry.outlinePath(in: box).isEmpty)
        XCTAssertFalse(ThreadingMarkGeometry.corePath(in: box).isEmpty)

        let strands = ThreadingMarkGeometry.strandPaths(in: box)
        XCTAssertEqual(strands.count, ThreadingMarkGeometry.strandCount)
        for strand in strands {
            XCTAssertFalse(strand.isEmpty)
            XCTAssertTrue(
                box.insetBy(dx: -1, dy: -1).contains(strand.boundingBoxOfPath),
                "a strand escaped the box it was asked to draw in"
            )
        }
    }

    /// Under Reduce Motion the launch is the finished mark simply being there — no animation
    /// is even constructed, which is what the theme-boundary exception for this view promises.
    @MainActor
    func testTheDrawInConstructsNoAnimationUnderReduceMotion() throws {
        let mark = ThreadingMarkView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))

        Design.Motion.reduceMotionOverrideForTesting = true
        mark.playDrawIn()
        XCTAssertTrue(animatedLayers(of: mark).isEmpty)

        Design.Motion.reduceMotionOverrideForTesting = false
        mark.playDrawIn()
        XCTAssertEqual(
            animatedLayers(of: mark).count,
            ThreadingMarkGeometry.strandCount + 2,
            "the outline, each strand, and the core should each carry the draw-in"
        )
    }

    private func animatedLayers(of view: NSView, key: String = "drawIn") -> [CALayer] {
        (view.layer?.sublayers ?? []).filter { $0.animation(forKey: key) != nil }
    }

    /// The blur. A shape layer added by hand keeps `contentsScale` 1 — only the backing layer
    /// AppKit makes for the view is given the display's — so every path was rasterised at 1x
    /// and enlarged by the compositor.
    @MainActor
    func testEveryShapeLayerRasterisesAtTheDisplaysScale() throws {
        let mark = ThreadingMarkView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let expected = NSScreen.main?.backingScaleFactor ?? 2

        let shapes = try XCTUnwrap(mark.layer?.sublayers)
        XCTAssertEqual(shapes.count, ThreadingMarkGeometry.strandCount + 2)
        for shape in shapes {
            XCTAssertEqual(
                shape.contentsScale,
                expected,
                "a shape layer left at 1x draws the mark soft on a Retina display"
            )
        }
    }

    /// Hover holds a lift on the model — it has to survive the animation, since the pointer can
    /// rest there — and lands the core's one beat on top of it.
    @MainActor
    func testHoverLiftsTheMarkAndSettlesBack() throws {
        let mark = ThreadingMarkView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        Design.Motion.reduceMotionOverrideForTesting = false

        mark.setHovered(true)
        let lifted = try XCTUnwrap(mark.layer?.sublayers?.first)
        XCTAssertGreaterThan(lifted.transform.m11, 1, "the mark did not lift under the pointer")
        XCTAssertEqual(animatedLayers(of: mark, key: "hover").count, 1, "the core is the one beat")

        mark.setHovered(false)
        XCTAssertEqual(lifted.transform.m11, 1, accuracy: 0.001, "the lift never settled back")
    }

    /// The press turns the whole mark by one strand-step. Six-fold symmetry is what makes that
    /// legal: the model value stays put, so the mark is where it started when the turn is over.
    @MainActor
    func testThePressTurnsEveryLayerAndLeavesNoneRotated() throws {
        let mark = ThreadingMarkView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))

        Design.Motion.reduceMotionOverrideForTesting = true
        mark.playPress()
        XCTAssertTrue(animatedLayers(of: mark, key: "press").isEmpty)

        Design.Motion.reduceMotionOverrideForTesting = false
        mark.playPress()
        XCTAssertEqual(
            animatedLayers(of: mark, key: "press").count,
            ThreadingMarkGeometry.strandCount + 2,
            "the shield, every strand and the core turn together or the mark comes apart"
        )
        for layer in try XCTUnwrap(mark.layer?.sublayers) {
            XCTAssertEqual(layer.transform.m12, 0, accuracy: 0.001, "a layer was left rotated")
        }
    }

    /// Under Reduce Motion the pointer changes nothing at all — no lift to settle back from.
    @MainActor
    func testHoverConstructsNothingUnderReduceMotion() throws {
        let mark = ThreadingMarkView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        Design.Motion.reduceMotionOverrideForTesting = true

        mark.setHovered(true)
        XCTAssertTrue(animatedLayers(of: mark, key: "hover").isEmpty)
        for layer in try XCTUnwrap(mark.layer?.sublayers) {
            XCTAssertEqual(layer.transform.m11, 1, accuracy: 0.001)
        }
    }

    /// The whole row is the pointer target, not the 24pt logo alone.
    @MainActor
    func testTheRowTracksThePointerForTheMark() {
        let brand = SidebarBrandView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
        brand.layoutSubtreeIfNeeded()
        brand.updateTrackingAreas()

        XCTAssertFalse(brand.trackingAreas.isEmpty, "nothing would ever tell the mark to lift")
    }

    // MARK: - The brand row

    @MainActor
    func testTheDefaultRowShowsTheMarkBesideTheAppsName() {
        AppThemeLibrary.apply(.system)
        let brand = SidebarBrandView(frame: .zero)
        brand.layoutSubtreeIfNeeded()

        let mark = try? XCTUnwrap(descendant(of: brand, as: ThreadingMarkView.self))
        XCTAssertEqual(mark?.isHidden, false)
        XCTAssertEqual(brand.accessibilityLabel(), AppInfo.name)
    }

    /// A chrome that renames the row renames it live — the same theme switch that repaints
    /// the window reconfigures the brand, with no host wiring.
    @MainActor
    func testAChromeStatingABrandReconfiguresTheRowOnApply() throws {
        AppThemeLibrary.apply(.system)
        let brand = SidebarBrandView(frame: .zero)

        let base = AppThemeStyles.cyberpunk
        let kind = base.availableVariants[0]
        let themed = try AppThemeEditing.assemble(
            id: AppThemeID("custom-sidebar-brand-view-tests"),
            name: "Signed",
            mode: kind == .dark ? .dark : .light,
            summary: nil,
            variants: [kind: AppThemeEditing.makeVariant(
                named: "Signed",
                from: base,
                kind: kind,
                sidebar: .set(SidebarStyle(
                    brand: .init(logo: .hidden, title: .init(text: "Atelier"))
                ))
            )]
        )
        AppThemeLibrary.apply(themed)

        let mark = try XCTUnwrap(descendant(of: brand, as: ThreadingMarkView.self))
        XCTAssertTrue(mark.isHidden, "the chrome hid the logo and the row kept drawing it")
        XCTAssertEqual(brand.accessibilityLabel(), "Atelier")
    }

    // MARK: - The sidebar's shape

    /// The header carries the brand at its leading edge and the list's two controls at its
    /// trailing one; the footer carries Settings alone, icon and word, at the leading margin.
    @MainActor
    func testTheSidebarPlacesBrandAddAndSettingsWhereTheDesignSays() throws {
        AppThemeLibrary.apply(.system)
        let sidebar = ProjectSidebarViewController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.view.layoutSubtreeIfNeeded()

        let brand = try XCTUnwrap(descendant(of: sidebar.view, as: SidebarBrandView.self))
        let header = try XCTUnwrap(ancestor(of: brand, as: PaneHeaderView.self))

        let add = try XCTUnwrap(
            descendants(of: sidebar.view)
                .compactMap { $0 as? ThemedIconButton }
                .first { $0.accessibilityTitle() == L10n.string("Add Project") },
            "the header has no + to add a project"
        )
        XCTAssertNotNil(
            ancestor(of: add, as: PaneHeaderView.self),
            "the + belongs in the header band beside the list it adds to"
        )
        XCTAssertEqual(header, ancestor(of: add, as: PaneHeaderView.self))

        let settings = try XCTUnwrap(
            descendants(of: sidebar.view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.title == L10n.string("Settings") },
            "the footer has no titled Settings button"
        )
        let footer = try XCTUnwrap(ancestor(of: settings, as: PaneFooterView.self))
        let inFooter = footer.convert(settings.frame, from: settings.superview)
        XCTAssertLessThan(
            inFooter.midX,
            footer.bounds.midX,
            "Settings moved to the leading edge and should sit in the left half of the band"
        )
    }

    /// The brand and Settings sit on the **list's** margin, not on the platform's.
    ///
    /// Both bands run the sidebar's full width, so the corner-adapted region they used to
    /// measure from held the window controls clear for their whole height — see
    /// `PaneHeaderTests`. Neither band's ink goes anywhere near the traffic lights, and taking
    /// the allowance anyway indented the brand and the gear some eighty points past every row
    /// between them: one column read as three.
    @MainActor
    func testTheBrandAndSettingsSitOnTheSameMarginAsTheList() throws {
        AppThemeLibrary.apply(.system)
        let sidebar = ProjectSidebarViewController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.view.layoutSubtreeIfNeeded()

        let brand = try XCTUnwrap(descendant(of: sidebar.view, as: SidebarBrandView.self))
        let settings = try XCTUnwrap(
            descendants(of: sidebar.view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.title == L10n.string("Settings") }
        )

        let brandInk = sidebar.view.convert(brand.bounds, from: brand).minX
        let settingsInk = sidebar.view.convert(settings.bounds, from: settings).minX
            + settings.opticalHorizontalInset

        XCTAssertEqual(brandInk, Design.Spacing.inset, accuracy: 0.5)
        XCTAssertEqual(
            settingsInk,
            brandInk,
            accuracy: 1,
            "the top of the column and the bottom of it should start on one line"
        )
    }

    /// Settings mode hides the list's controls — they act on a list that is not on screen —
    /// but the band and the brand stay: the brand is the window's signature, not a list tool.
    @MainActor
    func testSettingsModeKeepsTheBrandAndHidesTheListControls() throws {
        AppThemeLibrary.apply(.system)
        let sidebar = ProjectSidebarViewController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.view.layoutSubtreeIfNeeded()

        let brand = try XCTUnwrap(descendant(of: sidebar.view, as: SidebarBrandView.self))
        let header = try XCTUnwrap(ancestor(of: brand, as: PaneHeaderView.self))
        let add = try XCTUnwrap(
            descendants(of: sidebar.view)
                .compactMap { $0 as? ThemedIconButton }
                .first { $0.accessibilityTitle() == L10n.string("Add Project") }
        )
        let arrange = try XCTUnwrap(
            descendants(of: sidebar.view)
                .compactMap { $0 as? ThemedIconButton }
                .first { $0.accessibilityTitle() == SidebarStrings.arrangementOptions }
        )

        sidebar.setSettingsMode(true)
        XCTAssertFalse(header.isHidden, "settings mode took the whole band and the logo with it")
        XCTAssertFalse(brand.isHidden)
        XCTAssertTrue(add.isHidden)
        XCTAssertTrue(arrange.isHidden)

        sidebar.setSettingsMode(false)
        XCTAssertFalse(add.isHidden)
        XCTAssertFalse(arrange.isHidden)
    }

    // MARK: - Helpers

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func descendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        descendants(of: view).compactMap { $0 as? T }.first
    }

    private func ancestor<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        var current = view.superview
        while let candidate = current {
            if let match = candidate as? T { return match }
            current = candidate.superview
        }
        return nil
    }
}
