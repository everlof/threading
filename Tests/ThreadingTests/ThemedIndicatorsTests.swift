import AppKit
import XCTest
@testable import Threading

/// The three views in `ThemedIndicators` replace stock AppKit parts that could not be told to
/// use the theme's colours: `NSBox`'s system-grey hairline, `NSProgressIndicator`'s system-grey
/// spinner, and its system-blue bar. Each is drawn, so each is checked by sampling what it
/// actually put on screen rather than by reading the token back.
@MainActor
final class ThemedIndicatorsTests: XCTestCase {

    override func tearDown() {
        Design.Motion.reduceMotionOverrideForTesting = nil
        Design.Accessibility.increaseContrastOverrideForTesting = nil
        Design.Accessibility.differentiateWithoutColorOverrideForTesting = nil
        AppThemePalette.set(.system)
        WindowBackdrop.set(.chrome)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Draws a view and samples one pixel, which is the only way to check a colour that is
    /// chosen inside `draw(_:)` rather than stored anywhere.
    ///
    /// Sampled values are *composited*: the design system's surfaces rest below full opacity, so
    /// a pixel never matches the token's own hex. Comparisons here are therefore always between
    /// two sampled pixels, never between a pixel and a token.
    private func colour(of view: NSView, atX x: Int, y: Int) throws -> NSColor {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds),
                                "the view has no drawable bounds")
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    /// Samples in view points rather than backing pixels. The cache representation is Retina on
    /// the test host, so a literal pixel coordinate can accidentally inspect a neighbouring
    /// segment even when the requested point lies in the classic bar's gap.
    private func colour(of view: NSView, atPointX x: CGFloat, y: CGFloat) throws -> NSColor {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds),
                                "the view has no drawable bounds")
        view.cacheDisplay(in: view.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / max(1, view.bounds.width)
        let scaleY = CGFloat(rep.pixelsHigh) / max(1, view.bounds.height)
        return try XCTUnwrap(
            rep.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?.usingColorSpace(.sRGB)
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// A bar drawn at a known fraction, to sample reference colours from.
    private func bar(at fraction: Double) -> ThemedProgressBar {
        let bar = ThemedProgressBar(frame: NSRect(x: 0, y: 0, width: 100, height: 4))
        bar.progress = fraction
        return bar
    }

    /// A view inside a window, which is what `needsDisplay` needs before AppKit will record it —
    /// a windowless view drops the request. The window is kept for the test's lifetime and never
    /// closed, since `isReleasedWhenClosed` defaults on and closing over-releases it.
    private func hosted(_ view: NSView) -> NSView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        windows.append(window)
        return view
    }

    private var windows: [NSWindow] = []

    // MARK: - Separator

    /// The rule's thickness is the theme's border width rather than a literal 1, so a style that
    /// draws heavy rules draws them between rows too and not only around cards — Bauhaus rules at
    /// 2 and Neo Brutalism at 3. The same token is what the window's split seam takes its weight
    /// from, so the two agree by construction rather than by coincidence.
    func testTheSeparatorTakesItsThicknessFromTheThemeNotALiteral() {
        let horizontal = SeparatorView(.horizontal)
        XCTAssertEqual(horizontal.intrinsicContentSize.height, Design.Radius.border)
        XCTAssertEqual(horizontal.intrinsicContentSize.width, NSView.noIntrinsicMetric,
                       "a horizontal rule fixed its own width")

        let vertical = SeparatorView(.vertical)
        XCTAssertEqual(vertical.intrinsicContentSize.width, Design.Radius.border)
        XCTAssertEqual(vertical.intrinsicContentSize.height, NSView.noIntrinsicMetric,
                       "a vertical rule fixed its own height")
    }

    /// The whole reason `NSBox` was replaced: the rule is the theme's divider, not a system
    /// grey. Swiss Minimalist is the case that makes it obvious — black rules on white — so the
    /// two styles have to draw visibly different lines.
    func testTheSeparatorDrawsTheThemesDividerRatherThanASystemGrey() throws {
        func rule(under theme: AppTheme) throws -> NSColor {
            AppThemePalette.set(theme)
            let view = SeparatorView(.horizontal)
            view.frame = NSRect(x: 0, y: 0, width: 20, height: 2)
            return try colour(of: view, atX: 10, y: 1)
        }

        let cyberpunk = try rule(under: AppThemeStyles.cyberpunk)
        let swiss = try rule(under: AppThemeStyles.swissMinimalist)

        XCTAssertNotEqual(cyberpunk.hexString, swiss.hexString,
                          "both themes drew the same rule, so it is not theme-derived")
    }

    /// A rule already on screen has to follow a live theme switch, which for a view that draws
    /// in `draw(_:)` means being asked to redraw — `ThemeRedraw`'s whole job.
    func testTheSeparatorRedrawsOnAThemeChange() {
        AppThemePalette.set(.system)
        let view = SeparatorView(.horizontal)
        view.frame = NSRect(x: 0, y: 0, width: 20, height: 2)
        _ = hosted(view)
        view.needsDisplay = false

        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.cyberpunk.id))

        XCTAssertTrue(view.needsDisplay, "a theme change left the rule undrawn")
    }

    // MARK: - A Rule's Weight, Theme By Theme

    /// A pane header pinned in a window, which is where a rule's thickness is actually decided:
    /// the header pins its `SeparatorView` on three edges and leaves the fourth to
    /// `intrinsicContentSize`. Asserted through the header rather than on a bare rule because a
    /// component measured outside the container it ships in can agree with the token and still be
    /// drawn at another weight.
    private func hostedPaneHeader() throws -> PaneHeaderView {
        let header = PaneHeaderView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        windows.append(window)
        return header
    }

    /// The thickness the header's rule was *placed* at, which is what the eye reads.
    /// `intrinsicContentSize` is only the claim.
    private func ruleThickness(in header: PaneHeaderView) throws -> CGFloat {
        header.layoutSubtreeIfNeeded()
        let rules = descendants(of: header).compactMap { $0 as? SeparatorView }
        XCTAssertEqual(rules.count, 1, "the header no longer holds exactly one rule")
        return try XCTUnwrap(rules.first).frame.height
    }

    /// A weight as the device can actually place it. Auto Layout backing-aligns every frame, so a
    /// 1.5-point rule is 1.5 points on a Retina backing store and 2 on a 1× one; comparing two
    /// weights means comparing them on the same grid.
    private func onePixelGrid(_ view: NSView, of weight: CGFloat) -> CGFloat {
        view.backingAlignedRect(
            NSRect(x: 0, y: 0, width: weight, height: weight),
            options: .alignAllEdgesNearest
        ).height
    }

    /// A theme switch as the app performs it: the palette moves, then everything on screen is told.
    private func switchTheme(to theme: AppTheme) {
        AppThemePalette.set(theme)
        NotificationCenter.default.post(AppThemeDidChange(themeID: theme.id))
    }

    /// A theme change moves a rule's *weight* as well as its ink, and a rule already on screen was
    /// placed against the weight the constraint system last asked for. `intrinsicContentSize` reads
    /// the token live, but AppKit caches the answer until it is told the answer moved — so
    /// repainting alone left every rule in the window ruling for the theme that had just left,
    /// while anything built after the switch took the new weight. Arriving at Editorial (1) from
    /// Neo Brutalism (4), one window drew both.
    ///
    /// The same staleness as the split seam's, one view along: see
    /// `AppThemeTests.testTheSeamIsRelaidOutWhenTheThemeChangesUnderIt`.
    func testARuleAlreadyLaidOutTakesTheWeightOfTheThemeThatArrives() throws {
        switchTheme(to: AppThemeStyles.neoBrutalism)
        let header = try hostedPaneHeader()
        XCTAssertEqual(
            try ruleThickness(in: header),
            AppThemeStyles.neoBrutalism.material.borderWidth,
            "the header did not start at Neo Brutalism's weight"
        )

        switchTheme(to: AppThemeStyles.editorial)

        XCTAssertEqual(
            try ruleThickness(in: header),
            AppThemeStyles.editorial.material.borderWidth,
            "the rule kept the weight of the theme that just left"
        )
    }

    /// Every rule in the window is one decision — `Design.Radius.border` — so a pane header's rule
    /// and the split seam between the very same panes have to agree under **every** style, however
    /// the window arrived there.
    ///
    /// Swept across the whole catalogue rather than the three styles that happened to be on screen
    /// when the seam's own weight was fixed: the seam reads the token live and was therefore right
    /// all along, while the header's rule kept whatever it was last measured at. Each theme is
    /// entered from Neo Brutalism because the heaviest style leaves the widest stale rule behind,
    /// so a theme is never entered from itself — which is why entering Neo Brutalism *from* Neo
    /// Brutalism was the case that passed while the rest of the catalogue did not.
    ///
    /// Compared against the token **as the backing store can place it**: Auto Layout rounds a
    /// frame to whole device pixels, so the four styles that rule at 1.5 land on a half point on
    /// Retina and on a whole one at 1×, and a raw comparison would assert the screen away.
    func testEveryStockThemeRulesAtOneWeightThroughoutTheWindow() throws {
        let split = ThemedSplitView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let header = try hostedPaneHeader()

        for theme in [AppTheme.system] + AppThemeStyles.all {
            switchTheme(to: AppThemeStyles.neoBrutalism)
            _ = try ruleThickness(in: header)
            switchTheme(to: theme)

            let placed = try ruleThickness(in: header)
            XCTAssertEqual(
                placed,
                onePixelGrid(header, of: Design.Radius.border),
                accuracy: 0.01,
                "\(theme.name)'s rules did not weigh what the theme itself states"
            )
            XCTAssertEqual(
                placed,
                onePixelGrid(header, of: split.dividerThickness),
                accuracy: 0.01,
                "\(theme.name) ruled inside its panes and between them at two different weights"
            )
        }
    }

    /// A rule's *perceived* weight is thickness × ink, and the anchor is the text stem: a rule
    /// carrying more ink than the body face's stem (`Material.ruleInkBudget`) reads as a bar
    /// across the content rather than a rule between rows. Neo Brutalism stated full label ink
    /// under a 3pt weight and every rule in the window drew 2.5× the stem of the text beside it.
    ///
    /// Swept across the whole catalogue and both appearances because the cap is enforced at the
    /// one interpreter (`Design.Surface.divider`) precisely so a theme — the next stock style, a
    /// user's own, an extension's — cannot state its way past it. The second assertion is the
    /// other half of the contract: a theme already quieter than its ceiling keeps its authored
    /// ink, so the cap only ever pulls *down*.
    func testEveryStockThemeKeepsItsRuleInkWithinTheBudget() throws {
        Design.Accessibility.increaseContrastOverrideForTesting = false
        defer { Design.Accessibility.increaseContrastOverrideForTesting = nil }

        for theme in [AppTheme.system] + AppThemeStyles.all {
            switchTheme(to: theme)
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var drawn: NSColor?
                var authored: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    drawn = Design.Surface.divider.usingColorSpace(.sRGB)
                    authored = theme.resolved(.divider, appearance: appearance)
                        .usingColorSpace(.sRGB)
                }
                let material = theme.material(for: appearance)
                let rule = try XCTUnwrap(drawn, "\(theme.name)'s rule ink did not resolve")
                XCTAssertLessThanOrEqual(
                    rule.alphaComponent * max(1, material.borderWidth),
                    AppTheme.Material.ruleInkBudget + 0.01,
                    "\(theme.name) (\(appearanceName.rawValue)) rules heavier than the text stem"
                )

                let stated = try XCTUnwrap(authored)
                if stated.alphaComponent <= material.ruleInkCeiling {
                    XCTAssertEqual(
                        rule.hexString,
                        stated.hexString,
                        "\(theme.name) (\(appearanceName.rawValue)) had its quiet rule re-inked"
                    )
                }
            }
        }
    }

    // MARK: - Spinner

    func testMotionDurationsBecomeImmediateWhenReduceMotionIsEnabled() {
        Design.Motion.reduceMotionOverrideForTesting = false
        XCTAssertGreaterThan(Design.Motion.quick, 0)
        XCTAssertGreaterThan(Design.Motion.standard, 0)

        Design.Motion.reduceMotionOverrideForTesting = true
        XCTAssertEqual(Design.Motion.quick, 0)
        XCTAssertEqual(Design.Motion.standard, 0)
    }

    /// `isDisplayedWhenStopped`, kept the way this app used it: a stopped spinner is not a small
    /// grey ring, it is nothing at all.
    func testAStoppedSpinnerIsNothingRatherThanAStillRing() {
        let spinner = ThemedSpinner(frame: NSRect(x: 0, y: 0, width: 14, height: 14))

        XCTAssertTrue(spinner.isHidden, "a spinner that never started was visible")

        spinner.isAnimating = true
        XCTAssertFalse(spinner.isHidden)

        spinner.isAnimating = false
        XCTAssertTrue(spinner.isHidden, "a stopped spinner stayed on screen")
    }

    /// The animation is added when it starts and taken away when it stops — a spinner runs for
    /// as long as an agent is working, and one left rotating behind `isHidden` is main-thread
    /// work with nothing to show for it.
    func testTheAnimationIsAddedOnStartAndRemovedOnStop() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        let spinner = ThemedSpinner(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        let arc = try XCTUnwrap(spinner.layer?.sublayers?.compactMap({ $0 as? CAShapeLayer }).first,
                                "the spinner has no arc layer")

        XCTAssertNil(arc.animation(forKey: "spin"))

        spinner.isAnimating = true
        let running = try XCTUnwrap(arc.animation(forKey: "spin"), "starting added no animation")

        // Re-asserting the same state must not restart it, or a spinner told it is working twice
        // visibly jumps back to the top of its rotation.
        spinner.isAnimating = true
        XCTAssertTrue(arc.animation(forKey: "spin") === running,
                      "the spinner restarted an animation that was already running")

        spinner.isAnimating = false
        XCTAssertNil(arc.animation(forKey: "spin"), "stopping left the animation attached")
    }

    /// A shape layer added by hand is not given the view's `contentsScale` — only the backing
    /// layer AppKit makes is — so it rasterises its path at 1× and the compositor scales it up.
    /// `ThreadingMarkView` documents the trap and fixed itself; the spinner had the identical
    /// construction and spun blurry on every Retina display for as long as an agent worked.
    /// Swept over every hand-layered indicator so the next one cannot reintroduce it.
    func testHandAddedShapeLayersCarryTheWindowsBackingScale() throws {
        let spinner = ThemedSpinner(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        spinner.isAnimating = true
        let mark = ThreadingMarkView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))

        for view in [spinner, mark] {
            let host = hosted(view)
            host.layoutSubtreeIfNeeded()
            let window = try XCTUnwrap(host.window)
            let shapes = sublayers(of: try XCTUnwrap(view.layer))
                .compactMap { $0 as? CAShapeLayer }
            XCTAssertFalse(shapes.isEmpty, "\(type(of: view)) lost its shape layers")
            for shape in shapes {
                XCTAssertEqual(
                    shape.contentsScale,
                    window.backingScaleFactor,
                    "\(type(of: view)) rasterises a path at a scale its window does not have"
                )
            }
        }
    }

    private func sublayers(of layer: CALayer) -> [CALayer] {
        (layer.sublayers ?? []).flatMap { [$0] + sublayers(of: $0) }
    }

    /// Reduce Motion removes perpetual rotation but not the status itself: the themed arc stays
    /// visible as a static working indicator.
    func testReduceMotionKeepsTheWorkingIndicatorButRemovesItsRotation() throws {
        Design.Motion.reduceMotionOverrideForTesting = true
        let spinner = ThemedSpinner(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        let arc = try XCTUnwrap(spinner.layer?.sublayers?.compactMap({ $0 as? CAShapeLayer }).first)

        spinner.isAnimating = true

        XCTAssertFalse(spinner.isHidden)
        XCTAssertNil(arc.animation(forKey: "spin"))
    }

    /// A `CAShapeLayer`'s `strokeColor` is a `CGColor`, which resolves once and freezes — the
    /// exact trap the themed controls draw to avoid. A spinner has to keep its layer to animate
    /// off the main thread, so it re-applies the colour on every redraw instead. This is that
    /// re-application: drawing under one theme and then another must repaint the arc.
    func testTheArcColourIsReappliedOnEveryRedrawRatherThanFrozen() throws {
        let spinner = ThemedSpinner(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        let arc = try XCTUnwrap(spinner.layer?.sublayers?.compactMap({ $0 as? CAShapeLayer }).first)

        // Started first: a stopped spinner hides itself and a hidden view is never drawn, so the
        // arc would carry no colour at all — which is right, and is not what this is about.
        spinner.isAnimating = true

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        _ = try? colour(of: spinner, atX: 7, y: 7)
        let underCyberpunk = try XCTUnwrap(arc.strokeColor.flatMap { NSColor(cgColor: $0) })

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        _ = try? colour(of: spinner, atX: 7, y: 7)
        let underSwiss = try XCTUnwrap(arc.strokeColor.flatMap { NSColor(cgColor: $0) })

        XCTAssertNotEqual(underCyberpunk.hexString, underSwiss.hexString,
                          "the arc kept the first theme's accent through a redraw")
        XCTAssertEqual(underSwiss.hexString,
                       AppThemeStyles.swissMinimalist.resolved(.accent).hexString,
                       "the arc is not drawn in the theme's accent")
    }

    /// The accent is the spinner's ordinary status ink and the emphasized sidebar selection's
    /// fill. When the host lays that fill underneath it, the spinner must take the ink measured
    /// against the selection rather than drawing the fill on itself and disappearing.
    func testASpinnerOnASelectionUsesTheSelectionsInk() throws {
        let spinner = ThemedSpinner(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        let arc = try XCTUnwrap(spinner.layer?.sublayers?.compactMap({ $0 as? CAShapeLayer }).first)
        spinner.isAnimating = true

        for theme in [AppTheme.system, AppThemeStyles.botanical, AppThemeStyles.swissMinimalist] {
            AppThemePalette.set(theme)
            spinner.hostGround = .selection
            spinner.display()

            let selected = try XCTUnwrap(arc.strokeColor.flatMap { NSColor(cgColor: $0) })
            XCTAssertEqual(
                selected.hexString,
                Design.Ink.selection.label.hexString,
                "\(theme.name): the spinner did not take the selection's ink"
            )

            spinner.hostGround = nil
            spinner.display()
            let ordinary = try XCTUnwrap(arc.strokeColor.flatMap { NSColor(cgColor: $0) })
            XCTAssertEqual(
                ordinary.hexString,
                Design.Surface.accent.hexString,
                "\(theme.name): leaving the selection did not restore the accent"
            )
        }
    }

    /// Selection is one ground change for the whole status slot. Its layered indicators retain
    /// that semantic ground rather than a resolved colour, so a live theme change can re-resolve it.
    func testASelectedStatusGroundReachesTheLayeredStatusMarks() throws {
        AppThemePalette.set(AppThemeStyles.industrial)
        let indicator = SessionStatusIndicator()
        indicator.hostGround = .selection

        let spinner = try XCTUnwrap(
            descendants(of: indicator).compactMap { $0 as? ThemedSpinner }.first
        )
        let warning = try XCTUnwrap(
            descendants(of: indicator).compactMap { $0 as? ThemedWarningMark }.first
        )

        XCTAssertEqual(indicator.hostGround, .selection)
        XCTAssertEqual(spinner.hostGround, .selection)
        XCTAssertEqual(warning.hostGround, .selection)

        indicator.hostGround = nil
        XCTAssertNil(spinner.hostGround)
        XCTAssertNil(warning.hostGround)
    }

    // MARK: - Progress Bar

    /// The bar fills from the leading edge in proportion to its fraction: at a quarter, a point
    /// near the left is accent and one near the right is still track.
    func testTheBarFillsInProportionToItsFraction() throws {
        AppThemePalette.set(.system)

        // References drawn by the bar itself, so the comparison survives the alpha compositing
        // that stops a sampled pixel ever equalling its token.
        let track = try colour(of: bar(at: 0), atX: 50, y: 2)
        let accent = try colour(of: bar(at: 1), atX: 50, y: 2)
        XCTAssertNotEqual(track.hexString, accent.hexString,
                          "the fill and the track are indistinguishable")

        let quarter = bar(at: 0.25)
        XCTAssertEqual(try colour(of: quarter, atX: 5, y: 2).hexString, accent.hexString,
                       "the leading quarter is not filled")
        XCTAssertEqual(try colour(of: quarter, atX: 95, y: 2).hexString, track.hexString,
                       "the trailing three quarters are not still track")
    }

    /// "A caller reading a fraction off a web view is reading someone else's number." A fraction
    /// past 1 fills the bar and no more — it must not draw past its own bounds or wrap.
    func testAFractionPastOneFillsTheBarAndNoMore() throws {
        AppThemePalette.set(.system)
        let accent = try colour(of: bar(at: 1), atX: 50, y: 2)

        XCTAssertEqual(try colour(of: bar(at: 5), atX: 99, y: 2).hexString, accent.hexString,
                       "an over-full bar did not fill to its end")
    }

    /// A negative fraction draws no fill at all rather than a rect of negative width, which is
    /// the same guard from the other side.
    func testANegativeFractionDrawsNoFill() throws {
        AppThemePalette.set(.system)
        let track = try colour(of: bar(at: 0), atX: 50, y: 2)

        XCTAssertEqual(try colour(of: bar(at: -1), atX: 1, y: 2).hexString, track.hexString,
                       "a negative fraction still drew a fill")
    }

    func testSegmentedProgressUsesAClassicSunkenControl() throws {
        AppThemePalette.set(AppThemeStyles.win98)
        let bar = ThemedProgressBar(frame: NSRect(x: 0, y: 0, width: 100, height: 14))
        bar.progress = 0.5

        XCTAssertEqual(bar.intrinsicContentSize.height, 14)
        let segment = try colour(of: bar, atPointX: 5, y: 7)
        let gap = try colour(of: bar, atPointX: 10, y: 7)
        let unfilled = try colour(of: bar, atPointX: 70, y: 7)
        XCTAssertNotEqual(segment.hexString, gap.hexString, "the classic bar became one smooth slab")
        XCTAssertEqual(gap.hexString, unfilled.hexString, "the gap did not reveal the sunken track")

        AppThemePalette.set(.system)
        XCTAssertEqual(ThemedProgressBar().intrinsicContentSize.height, 3)
    }

    /// Workbench's manual names a horizontal percentage gauge, not Win32's separated blocks.
    /// Its native pixels are unavailable, but the authored recipe still has to keep the source's
    /// hard trough and active title blue distinct from the modern action accent.
    func testWorkbenchProgressUsesAContinuousSunkenGaugeInTitleBlue() throws {
        AppThemePalette.set(AppThemeStyles.amiga)
        let bar = ThemedProgressBar(frame: NSRect(x: 0, y: 0, width: 100, height: 12))
        bar.progress = 0.5

        XCTAssertEqual(bar.intrinsicContentSize.height, ThemedProgressDrawing.workbenchHeight)
        let fill = try colour(of: bar, atPointX: 20, y: 6)
        let track = try colour(of: bar, atPointX: 80, y: 6)
        XCTAssertNotEqual(fill.hexString, track.hexString,
                          "the Workbench gauge lost its percentage fill")

        let titleBlue = try XCTUnwrap(
            WindowChromeAppearance.resolve()?.activeGradient.colors.first?.usingColorSpace(.sRGB)
        )
        XCTAssertEqual(fill.redComponent, titleBlue.redComponent, accuracy: 0.01,
                       "the Workbench gauge changed title blue's red channel")
        XCTAssertEqual(fill.greenComponent, titleBlue.greenComponent, accuracy: 0.01,
                       "the Workbench gauge changed title blue's green channel")
        XCTAssertEqual(fill.blueComponent, titleBlue.blueComponent, accuracy: 0.01,
                       "the Workbench gauge used the general action accent instead of title blue")
    }

    /// Indigo Magic's scale is not a modern hairline or a Win32 row of blocks: its measured
    /// recessed track begins on an eight-pixel diagonal. A full bar therefore fills the upper
    /// part of the leading edge while the lower corner remains the field, which pins the source
    /// geometry without depending on one guessed native colour.
    func testIRIXProgressUsesTheMeasuredSlantedLeadingEdge() throws {
        AppThemePalette.set(AppThemeStyles.irix)
        let bar = ThemedProgressBar(frame: NSRect(x: 0, y: 0, width: 100, height: 14))
        bar.progress = 1

        XCTAssertEqual(bar.intrinsicContentSize.height, ThemedProgressDrawing.irixHeight)
        let filled = try colour(of: bar, atPointX: 50, y: 7)
        let leadingOutside = try colour(of: bar, atPointX: 3, y: 11)
        let leadingInside = try colour(of: bar, atPointX: 15, y: 11)
        XCTAssertEqual(leadingInside.hexString, filled.hexString,
                       "the measured diagonal did not admit the filled side of the track")
        XCTAssertNotEqual(leadingOutside.hexString, filled.hexString,
                          "the measured diagonal was flattened into a rectangular fill")
    }

    /// Setting the fraction is what asks for the redraw; without it the bar would only move when
    /// something else happened to dirty it.
    func testSettingTheFractionAsksForARedraw() {
        let bar = ThemedProgressBar(frame: NSRect(x: 0, y: 0, width: 100, height: 4))
        _ = hosted(bar)
        bar.needsDisplay = false

        bar.progress = 0.5

        XCTAssertTrue(bar.needsDisplay, "the bar did not repaint when its fraction moved")
    }

    func testIndicatorsExposeProgressSemantics() {
        let spinner = ThemedSpinner()
        XCTAssertTrue(spinner.isAccessibilityElement())
        XCTAssertEqual(spinner.accessibilityRole(), .progressIndicator)
        XCTAssertEqual(spinner.accessibilityLabel(), "Working")

        let bar = ThemedProgressBar()
        bar.progress = 1.4
        XCTAssertTrue(bar.isAccessibilityElement())
        XCTAssertEqual(bar.accessibilityRole(), .progressIndicator)
        XCTAssertEqual(bar.accessibilityLabel(), "Progress")
        XCTAssertEqual(bar.accessibilityValue() as? Double, 1)
    }

    func testSessionLoadingUsesTheSpinnerEvenWhenTheAgentIsDormant() throws {
        let indicator = SessionStatusIndicator()
        let spinner = try XCTUnwrap(
            indicator.subviews.compactMap { $0 as? ThemedSpinner }.first
        )

        indicator.update(for: .dormant, isLoading: true)
        XCTAssertTrue(spinner.isAnimating)
        XCTAssertEqual(spinner.accessibilityLabel(), "Loading session")

        // The activity did not change; only the asynchronous activation state did. That still
        // has to stop the spinner, which is why the indicator caches both values.
        indicator.update(for: .dormant, isLoading: false)
        XCTAssertFalse(spinner.isAnimating)
        XCTAssertTrue(spinner.isHidden)
    }

    // MARK: - The Two Attention Marks

    /// The mark, whichever it is. It is the one subview that is not the spinner.
    private func mark(of indicator: SessionStatusIndicator) throws -> NSView {
        try XCTUnwrap(indicator.subviews.first { !($0 is ThemedSpinner) })
    }

    /// Resolves a token the way `applySurface` does, so a comparison is between two colours
    /// settled in the same appearance rather than across two.
    private func resolved(_ colour: NSColor, in view: NSView) -> CGColor {
        var result: CGColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            result = colour.cgColor
        }
        return result ?? colour.cgColor
    }

    /// A session blocked on a question has stopped until it is answered, so it takes the loud
    /// mark: filled, in the warning role.
    func testABlockedSessionTakesTheFilledWarningDot() throws {
        let indicator = SessionStatusIndicator()
        let dot = try mark(of: indicator)

        indicator.update(for: .awaitingUser)

        XCTAssertFalse(dot.isHidden)
        XCTAssertEqual(dot.layer?.backgroundColor, resolved(Design.Status.warning, in: dot))
        XCTAssertEqual(dot.layer?.borderWidth, 0, "a filled mark carries no ring")
        XCTAssertEqual(dot.accessibilityLabel(), "Session waiting for an answer")
    }

    /// A turn that ended unseen is unread, not stuck, so it takes the quiet one: a hollow ring
    /// in the accent.
    func testAFinishedSessionTakesTheHollowAccentRing() throws {
        let indicator = SessionStatusIndicator()
        let dot = try mark(of: indicator)

        indicator.update(for: .needsAttention)

        XCTAssertFalse(dot.isHidden)
        XCTAssertEqual(
            dot.layer?.backgroundColor?.alpha,
            0,
            "a hollow mark is a ring around nothing"
        )
        XCTAssertGreaterThan(try XCTUnwrap(dot.layer?.borderWidth), 0)
        XCTAssertEqual(dot.layer?.borderColor, resolved(Design.Surface.accent, in: dot))
        XCTAssertEqual(dot.accessibilityLabel(), "Session needs attention")
    }

    /// Filled versus hollow is what carries the distinction where colour cannot — the two must
    /// differ in ink at the centre, not only in hue.
    func testTheTwoMarksDifferInShapeRatherThanOnlyInColour() throws {
        func centreAlpha(for activity: SessionActivity) throws -> CGFloat {
            let indicator = SessionStatusIndicator()
            indicator.frame = NSRect(x: 0, y: 0, width: 12, height: 12)
            indicator.update(for: activity)
            indicator.layoutSubtreeIfNeeded()

            let dot = try mark(of: indicator)
            let layer = try XCTUnwrap(dot.layer)
            let size = 8
            let context = try XCTUnwrap(CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.scaleBy(
                x: CGFloat(size) / max(layer.bounds.width, 1),
                y: CGFloat(size) / max(layer.bounds.height, 1)
            )
            layer.render(in: context)

            let pixels = try XCTUnwrap(context.data)
            let centre = (size / 2) * size * 4 + (size / 2) * 4
            return CGFloat(pixels.load(fromByteOffset: centre + 3, as: UInt8.self)) / 255
        }

        XCTAssertGreaterThan(try centreAlpha(for: .awaitingUser), 0.5, "filled: ink at the centre")
        XCTAssertLessThan(try centreAlpha(for: .needsAttention), 0.5, "hollow: a hole at the centre")
    }

    /// The mark changes style under a row that is already showing one — the session was blocked,
    /// was answered, worked on and then finished — so the surface has to be laid down again.
    func testTheMarkRestylesWithoutBeingRebuilt() throws {
        let indicator = SessionStatusIndicator()
        let dot = try mark(of: indicator)

        indicator.update(for: .awaitingUser)
        indicator.update(for: .working)
        indicator.update(for: .needsAttention)

        XCTAssertEqual(dot.layer?.backgroundColor?.alpha, 0, "the filled fill must not survive")
        XCTAssertGreaterThan(try XCTUnwrap(dot.layer?.borderWidth), 0)
    }

    /// Draws the four states as the sidebar actually stacks them, light and dark.
    ///
    /// The assertions above pin the two marks apart; this is what says whether they read apart —
    /// a 6pt ring and a 6pt dot at the end of a row is exactly the size where a distinction can
    /// be true and invisible.
    func testRendersTheStatusMarkStorybook() throws {
        let directory: URL = {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let states: [(String, SessionActivity)] = [
            ("Working on the thing", .working),
            ("Asked you a question", .awaitingUser),
            ("Finished while you were away", .needsAttention),
            ("Waiting at its prompt", .idle)
        ]

        var written = 0
        for (appearanceName, appearanceID) in [("light", NSAppearance.Name.aqua),
                                               ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceID))
            var data: Data?

            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated {
                    let host = NSView(frame: NSRect(
                        x: 0,
                        y: 0,
                        width: SidebarDefaults.defaultWidth,
                        height: CGFloat(states.count) * SidebarDefaults.rowHeight
                    ))
                    host.appearance = appearance
                    host.applySurface(fill: Design.Surface.background, radius: .fixed(0))

                    for (index, state) in states.enumerated() {
                        let row = SessionRowView()
                        row.frame = NSRect(
                            x: 0,
                            y: CGFloat(states.count - 1 - index) * SidebarDefaults.rowHeight,
                            width: host.bounds.width,
                            height: SidebarDefaults.rowHeight
                        )
                        row.configure(
                            with: AgentSession(kind: .claude, title: state.0),
                            activity: state.1
                        )
                        host.addSubview(row)
                    }

                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        return
                    }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }
            }

            try XCTUnwrap(data).write(
                to: directory.appendingPathComponent("session-status-\(appearanceName).png")
            )
            written += 1
        }

        XCTAssertEqual(written, 2)
        print("Rendered session status marks to \(directory.path)")
    }

    func testGitStatusCardBecomesALiveRunReceipt() {
        let card = GitStatusOverlayView()
        card.update(with: GitChangeMonitor.Reading(
            branch: "feature/progress",
            summary: GitChangeSummary(files: 2, added: 35, removed: 1)
        ))

        // Spoken as the rows are stacked, with the exact counts the drawn card abbreviates.
        XCTAssertEqual(card.accessibilityLabel(), "feature/progress  ·  2 files +35 −1")

        card.updateRunState(
            isActive: true,
            progress: RunProgress(step: 2, total: 4)
        )
        XCTAssertFalse(card.isHidden)
        XCTAssertEqual(
            card.accessibilityLabel(),
            "Step 2 / 4  ·  2 files +35 −1"
        )

        card.updateRunState(
            isActive: true,
            progress: RunProgress(completed: 1, active: 2, total: 4)
        )
        XCTAssertEqual(
            card.accessibilityLabel(),
            "1 / 4 done · 2 active  ·  2 files +35 −1"
        )

        card.updateRunState(
            isActive: true,
            progress: RunProgress(step: 2, total: 4)
        )

        // A checkout reading and a plan update are independent streams. Either one must rebuild
        // the receipt immediately without restarting or replacing the other.
        card.update(with: GitChangeMonitor.Reading(
            branch: "feature/progress",
            summary: GitChangeSummary(files: 1_234, added: 8_349, removed: 4_742)
        ))
        XCTAssertEqual(
            card.accessibilityLabel(),
            "Step 2 / 4  ·  \(1_234.formatted()) files "
                + "+\(8_349.formatted()) −\(4_742.formatted())"
        )

        card.updateRunState(isActive: false, progress: nil)
        XCTAssertEqual(
            card.accessibilityLabel(),
            "feature/progress  ·  \(1_234.formatted()) files "
                + "+\(8_349.formatted()) −\(4_742.formatted())"
        )
    }

    /// Who can see this chat from outside the Mac is a fact the card had no room for and the app
    /// had nowhere else for: two clients quietly holding one terminal is what made the shared PTY
    /// flip between grid sizes, and nothing on screen said a second one was there.
    ///
    /// The row therefore appears for either half — somebody watching, or a link nobody has used
    /// yet — because a shared, unwatched chat that looks exactly like a private one is the case
    /// worth showing.
    func testTheCardSaysWhoCanSeeThisChatFromOutsideTheMac() {
        let card = GitStatusOverlayView()
        card.update(with: GitChangeMonitor.Reading(
            branch: "master",
            summary: GitChangeSummary(files: 0, added: 0, removed: 0)
        ))
        XCTAssertEqual(card.accessibilityLabel(), "master")

        card.updateAudience(GitStatusOverlayView.AudienceReading(following: 2, isShared: true))
        XCTAssertFalse(card.isHidden)
        XCTAssertTrue(
            descendants(of: card).contains { ($0 as? ThemedButton)?.title == "2 following" },
            "a live audience is a count, because the number is the fact"
        )

        card.updateAudience(GitStatusOverlayView.AudienceReading(following: 0, isShared: true))
        XCTAssertTrue(
            descendants(of: card).contains { ($0 as? ThemedButton)?.title == "Shared" },
            "a shared chat nobody is on still says so — \"0 following\" would be a row "
                + "spent saying nothing, and hiding it makes a reachable chat look private"
        )

        card.updateAudience(GitStatusOverlayView.AudienceReading())
        XCTAssertFalse(
            descendants(of: card).contains {
                ($0 as? ThemedButton).map { !$0.isHidden && $0.title == "Shared" } ?? false
            },
            "a chat nobody can reach spends no row on the fact"
        )
    }

    /// The card's own geometry is load-bearing — one row of text inset top and bottom *is* the
    /// pill height — and a button row gives its own padding back out of whatever it touches.
    /// A second button row is the case that arithmetic had never seen.
    func testTwoButtonRowsKeepTheCardOnItsOwnRhythm() {
        let card = GitStatusOverlayView()
        card.applyInk(WindowBackdrop.ink)
        card.update(with: GitChangeMonitor.Reading(
            branch: "master",
            summary: GitChangeSummary(files: 0, added: 0, removed: 0)
        ))
        card.layoutSubtreeIfNeeded()
        let oneRow = card.fittingSize.height

        card.updateSubagents(workingCount: 1, doneCount: 2)
        card.updateAudience(GitStatusOverlayView.AudienceReading(following: 1, isShared: true))
        card.layoutSubtreeIfNeeded()
        let threeRows = card.fittingSize.height

        XCTAssertGreaterThan(threeRows, oneRow)
        // Both button rows are present rather than one having been laid on top of the other.
        let visibleButtons = descendants(of: card).compactMap { $0 as? ThemedButton }
            .filter { !$0.isHidden && !($0.title).isEmpty }
        XCTAssertEqual(visibleButtons.count, 2)
        XCTAssertEqual(
            Set(visibleButtons.map(\.title)),
            ["1 working · 2 done", "1 following"]
        )
    }

    /// A run promotes the card's first line; it does not put a *third* spinner on screen.
    ///
    /// A terminal session's CLI draws its own a few lines below the card, and a native
    /// conversation animates one beside its status. The card's copy repeated either one without
    /// adding another state.
    func testTheRunReceiptCarriesNoSpinnerOfItsOwn() {
        let card = GitStatusOverlayView()
        card.update(with: GitChangeMonitor.Reading(
            branch: "feature/progress",
            summary: GitChangeSummary(files: 2, added: 35, removed: 1)
        ))
        card.updateRunState(isActive: true, progress: RunProgress(step: 2, total: 4))
        card.applyInk(WindowBackdrop.ink)

        let everything = descendants(of: card)
        XCTAssertTrue(
            everything.compactMap { $0 as? WorkingOrbView }.isEmpty,
            "the corner card animated a spinner two other surfaces already draw"
        )
        // The mark is still there — it says which kind of line this is, which is the job the
        // spinner was doing badly.
        let marks = everything.compactMap {
            ($0 as? ThemedFloatingGlyphView)?.semanticDescription
        }
        XCTAssertTrue(marks.contains("Plan"), "the promoted line lost its mark with the spinner")
    }

    /// Marks share one column, so the rows read as a list. The children row is a titled button
    /// with padding of its own, so the text rows are inset by exactly that much — asserted on
    /// the drawn frames, since this is the alignment a constraint cannot state directly.
    func testEveryRowsMarkSitsInOneColumn() throws {
        let card = GitStatusOverlayView()
        card.update(with: GitChangeMonitor.Reading(
            branch: "feature/progress",
            summary: GitChangeSummary(files: 12, added: 4_203, removed: 250)
        ))
        card.updateSubagents(workingCount: 0, doneCount: 9)
        card.applyInk(WindowBackdrop.ink)
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        card.layoutSubtreeIfNeeded()

        // Only the marks actually drawn: the card keeps a row per fact in its hierarchy and hides
        // the ones it has nothing to say for, so an undrawn mark has no column to be in.
        let marks = descendants(of: card)
            .compactMap { $0 as? ThemedFloatingGlyphView }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .map { card.convert($0.bounds, from: $0).minX }
        XCTAssertEqual(marks.count, 2, "the branch and counters marks should both be drawn")

        let button = try XCTUnwrap(
            descendants(of: card).compactMap { $0 as? ThemedButton }.first
        )
        let buttonMark = card.convert(button.bounds, from: button).minX
            + button.opticalHorizontalInset

        for mark in marks {
            XCTAssertEqual(mark, buttonMark, accuracy: 0.5,
                           "a row's mark sits outside the column the others share")
        }
    }

    /// Every gap in the card is the same gap, and the card's own inset is the same at both ends.
    ///
    /// It was not: the leading row was centred in a 26-point band and every row below it was a
    /// bare label in a stack spaced at zero, so a three-fact card came out 6 / 0 / 0 — the branch
    /// alone at the top with the counters and the agent line stuck together under it. Asserted on
    /// the laid-out frames rather than on the ink, because the rows share one font and therefore
    /// one line box: equal frame gaps are equal gaps between the words.
    func testEveryRowSitsOnTheSameRhythm() throws {
        for children in [0, 9] {
            let card = GitStatusOverlayView()
            card.update(with: GitChangeMonitor.Reading(
                branch: "test-levels-and-sidebar-archive",
                summary: GitChangeSummary(files: 76, added: 22_431, removed: 14_004)
            ))
            card.updateModel(GitStatusOverlayView.ModelReading(
                name: "Opus",
                effort: "Extra High"
            ))
            card.updateSubagents(workingCount: 0, doneCount: children)
            card.applyInk(WindowBackdrop.ink)
            card.frame = NSRect(origin: .zero, size: card.fittingSize)
            card.layoutSubtreeIfNeeded()

            // The words, not the rows: the children row is a button and pads its title out to a
            // hit target, so its *frame* is deliberately taller than a line of text. What has to
            // land on the rhythm is what the reader sees, so the button is measured back down to
            // the line box its title is drawn in — the same one every other row's label is.
            let lineBox = GitStatusOverlayDefaults.textRowHeight
            let words = descendants(of: card)
                .filter { $0 is NSTextField || $0 is ThemedButton }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
                .map { view -> CGRect in
                    let frame = card.convert(view.bounds, from: view)
                    guard view is ThemedButton else { return frame }
                    return frame.insetBy(dx: 0, dy: (frame.height - lineBox) / 2)
                }
                // One row per line: the counters row has two labels side by side on the same one.
                .reduce(into: [CGRect]()) { rows, frame in
                    if let index = rows.firstIndex(where: { abs($0.midY - frame.midY) < 1 }) {
                        rows[index] = rows[index].union(frame)
                    } else {
                        rows.append(frame)
                    }
                }
                .sorted { $0.maxY > $1.maxY }

            let expected = children > 0 ? 4 : 3
            XCTAssertEqual(words.count, expected, "the card drew \(words.count) rows, not \(expected)")

            let gaps = zip(words, words.dropFirst()).map { $0.minY - $1.maxY }
            for gap in gaps {
                XCTAssertEqual(gap, GitStatusOverlayDefaults.rowGap, accuracy: 0.5,
                               "the rows are spaced \(gaps) — a card of unequal gaps")
            }

            let top = card.bounds.maxY - (words.first?.maxY ?? 0)
            let bottom = words.last?.minY ?? 0
            XCTAssertEqual(top, GitStatusOverlayDefaults.verticalInset, accuracy: 0.5,
                           "the first row does not sit on the card's inset")
            XCTAssertEqual(bottom, top, accuracy: 0.5,
                           "the card is padded \(top) at the top and \(bottom) at the bottom")
        }
    }

    /// One row of any kind, inset above and below, is the pill the card started as — which is
    /// what lets the corner hold a one-line reading without looking like a panel.
    func testAnySingleRowMakesTheSameOneLineCard() {
        let cards: [(String, @MainActor (GitStatusOverlayView) -> Void)] = [
            ("branch", { $0.update(with: .init(branch: "master", summary: .clean)) }),
            ("agent", { $0.updateModel(.init(name: "Opus 5")) }),
            ("children", { $0.updateSubagents(workingCount: 0, doneCount: 9) })
        ]
        for (name, state) in cards {
            let card = GitStatusOverlayView()
            state(card)
            card.applyInk(WindowBackdrop.ink)
            XCTAssertEqual(
                card.fittingSize.height,
                GitStatusOverlayDefaults.height,
                accuracy: 0.5,
                "a card holding only the \(name) row is not the one-line card"
            )
        }
    }

    /// The totals follow the file count on the same line rather than being pushed to the card's
    /// trailing edge by a spacer — which on a long branch name opened a hole halfway across the
    /// counters row and nowhere else.
    func testTheCountersFollowTheFileCountRatherThanTheCardsEdge() throws {
        let card = GitStatusOverlayView()
        card.update(with: GitChangeMonitor.Reading(
            branch: "test-levels-and-sidebar-archive",
            summary: GitChangeSummary(files: 12, added: 4_203, removed: 250)
        ))
        card.applyInk(WindowBackdrop.ink)
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        card.layoutSubtreeIfNeeded()

        let counters = descendants(of: card)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .filter { $0.stringValue.contains("4.2") || $0.stringValue.contains("12 ") }
        let frames = counters
            .map { card.convert($0.bounds, from: $0) }
            .sorted { $0.minX < $1.minX }
        guard frames.count == 2 else {
            return XCTFail("the counters row drew \(frames.count) readings, not two")
        }
        // A stack spaces views by their *alignment* rects, and a label's frame stands off its
        // ink on both sides, so the token is the drawn gap plus those two.
        let padding = counters[0].alignmentRectInsets.right + counters[1].alignmentRectInsets.left
        XCTAssertEqual(frames[1].minX - frames[0].maxX + padding,
                       Design.Spacing.medium, accuracy: 0.5,
                       "the totals are held apart from the file count by a stretched gap")
    }

    func testGitStatusCardCarriesASeparateSubagentDestination() throws {
        let card = GitStatusOverlayView()
        var openedSubagents = 0
        card.onOpenSubagents = { openedSubagents += 1 }

        card.updateSubagents(workingCount: 2, doneCount: 3)
        XCTAssertFalse(card.isHidden, "Subagents should retain the corner card without Git data")

        let button = try XCTUnwrap(
            card.subviews
                .compactMap { $0 as? NSStackView }
                .flatMap(\.arrangedSubviews)
                .compactMap { $0 as? ThemedButton }
                .first { $0.title == "2 working · 3 done" }
        )
        XCTAssertEqual(button.accessibilityTitle(), "2 working · 3 done")
        XCTAssertEqual(button.accessibilityHelp(), "Open Subagents")
        _ = button.sendAction(button.action, to: button.target)
        XCTAssertEqual(openedSubagents, 1)

        card.updateSubagents(workingCount: 0, doneCount: 3)
        XCTAssertEqual(button.title, "3 done")

        card.updateSubagents(workingCount: 0, doneCount: 0)
        XCTAssertTrue(card.isHidden)
    }

    // MARK: - The Card's Agent Line

    /// The row the terminal pane owes the user: for three of four logins on the machine this was
    /// written against, Claude's own status line is usage and nothing else, so the card is the only
    /// place the model appears.
    func testTheAgentLineNamesTheModelAndHowItRuns() throws {
        let card = GitStatusOverlayView()
        card.update(with: GitChangeMonitor.Reading(
            branch: "test-levels-and-sidebar-archive",
            summary: GitChangeSummary(files: 2, added: 35, removed: 1)
        ))
        card.updateModel(GitStatusOverlayView.ModelReading(
            name: "Opus 5",
            effort: "Extra High",
            isFast: true
        ))
        card.applyInk(WindowBackdrop.ink)

        XCTAssertFalse(card.isHidden)
        // Spoken as the rows are stacked, the agent line last — and within it as the row is drawn,
        // the speed last of all, because on screen it is the bolt after the words.
        XCTAssertEqual(
            card.accessibilityLabel(),
            "test-levels-and-sidebar-archive  ·  2 files +35 −1  ·  Opus 5 · Extra High · Fast"
        )

        let marks = descendants(of: card)
            .compactMap { $0 as? ThemedFloatingGlyphView }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .compactMap(\.semanticDescription)
        XCTAssertTrue(marks.contains("Model"), "the agent line lost its mark")
    }

    /// Fast mode is a bolt, and only when it is on. The word is gone from the row: it cost a
    /// sixth of a capped card to say what the mark says at a glance, and every other surface in
    /// the app already draws this state as `bolt.fill`.
    func testFastModeIsABoltThatOnlyAppearsWhenItIsOn() {
        let card = GitStatusOverlayView()

        func drawnMarks() -> [String] {
            descendants(of: card)
                .compactMap { $0 as? ThemedFloatingGlyphView }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
                .compactMap(\.semanticDescription)
        }

        func drawnWords() -> String {
            descendants(of: card)
                .compactMap { $0 as? NSTextField }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
                .map(\.stringValue)
                .joined(separator: " ")
        }

        card.updateModel(GitStatusOverlayView.ModelReading(name: "GPT-5", effort: "High"))
        card.applyInk(WindowBackdrop.ink)
        XCTAssertFalse(drawnMarks().contains("Fast"), "standard speed drew a bolt")

        card.updateModel(GitStatusOverlayView.ModelReading(
            name: "GPT-5",
            effort: "High",
            isFast: true
        ))
        XCTAssertTrue(drawnMarks().contains("Fast"), "fast mode drew no bolt")
        XCTAssertFalse(
            drawnWords().contains("Fast"),
            "the bolt replaced the word; both together say it twice"
        )
        // The reader who hears the card gets the word, in the bolt's place.
        XCTAssertEqual(card.accessibilityLabel(), "GPT-5 · High · Fast")
    }

    /// Speed alone still opens the row, and the row is then the mark and the bolt with no words
    /// between them — a card is entitled to say one true thing.
    func testABoltAloneKeepsTheAgentLine() {
        let card = GitStatusOverlayView()
        card.updateModel(GitStatusOverlayView.ModelReading(isFast: true))
        card.applyInk(WindowBackdrop.ink)

        XCTAssertFalse(card.isHidden, "speed on its own did not hold the card open")
        let marks = descendants(of: card)
            .compactMap { $0 as? ThemedFloatingGlyphView }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .compactMap(\.semanticDescription)
        XCTAssertEqual(Set(marks), ["Model", "Fast"])
        XCTAssertEqual(card.accessibilityLabel(), "Fast")
    }

    /// Each part is independently droppable: a session may know its model and not its posture, or
    /// the reverse, and the row says whichever it has rather than waiting for a full set.
    func testTheAgentLineShowsOnlyTheFactsItWasGiven() {
        let card = GitStatusOverlayView()
        card.updateModel(GitStatusOverlayView.ModelReading(name: "Opus 5"))
        card.applyInk(WindowBackdrop.ink)

        XCTAssertFalse(card.isHidden, "a fact with no Git reading still deserves the card")
        XCTAssertEqual(card.accessibilityLabel(), "Opus 5")

        card.updateModel(GitStatusOverlayView.ModelReading(effort: "Extra High"))
        XCTAssertEqual(card.accessibilityLabel(), "Extra High")
    }

    /// The posture reads between the model and how it thinks, which is the order the composer's
    /// own chips are in — one fact keeps one place wherever it is shown.
    ///
    /// It is on the card at all because nothing else showed it: a terminal's mode lives in the
    /// CLI's own footer, the session's `⋯` menu states only what the *next* launch will ask for,
    /// and Claude's status-line payload carries no posture for a status line to print.
    func testTheAgentLineShowsThePostureBetweenTheModelAndItsEffort() {
        let card = GitStatusOverlayView()
        card.updateModel(GitStatusOverlayView.ModelReading(
            name: "Opus 5",
            mode: AgentPermissionMode.auto.displayName,
            effort: "Extra High"
        ))
        card.applyInk(WindowBackdrop.ink)

        XCTAssertFalse(card.isHidden)
        XCTAssertEqual(card.accessibilityLabel(), "Opus 5 · Auto · Extra High")
    }

    /// A posture on its own is a row, for the same reason speed on its own is: the caller has
    /// already dropped whatever the session's own surfaces say, and what is left is what the card
    /// owes. This is the live case for a login that pins no model — the observed posture is then
    /// the only agent fact the pane has.
    func testAPostureAloneKeepsTheAgentLine() {
        let card = GitStatusOverlayView()
        card.updateModel(GitStatusOverlayView.ModelReading(
            mode: AgentPermissionMode.bypassPermissions.displayName
        ))
        card.applyInk(WindowBackdrop.ink)

        XCTAssertFalse(card.isHidden, "the posture did not hold the card open on its own")
        XCTAssertEqual(card.accessibilityLabel(), "Bypass Permissions")
    }

    /// An empty reading and no reading mean the same thing: the caller whose status line already
    /// says everything and the caller with nothing to add both want the row gone.
    func testAnEmptyAgentReadingHidesTheRowEntirely() throws {
        let card = GitStatusOverlayView()
        card.updateModel(GitStatusOverlayView.ModelReading(name: "Opus 5"))
        card.applyInk(WindowBackdrop.ink)
        XCTAssertFalse(card.isHidden)

        card.updateModel(GitStatusOverlayView.ModelReading())
        XCTAssertTrue(card.isHidden, "an all-nil reading left an empty row holding the card open")

        card.updateModel(nil)
        XCTAssertTrue(card.isHidden)
    }

    /// A model-only card is not a Git receipt, so it must not claim to be a button that opens Git
    /// Review — and clicking it must do nothing.
    func testAModelOnlyCardIsNotAGitReceipt() {
        let card = GitStatusOverlayView()
        var opened = 0
        card.onOpen = { opened += 1 }
        card.updateModel(GitStatusOverlayView.ModelReading(name: "Opus 5"))
        card.applyInk(WindowBackdrop.ink)

        XCTAssertEqual(card.accessibilityRole(), .group)
        XCTAssertNil(card.toolTip)
        card.mouseDown(with: NSEvent())
        XCTAssertEqual(opened, 0, "a card with no Git sentence opened Git Review")
    }

    /// Whichever row leads carries the card's top padding, and only a band does. The agent line
    /// leads a card with no checkout sentence, which is where the band has to move to it.
    func testTheAgentLineTakesTheBandWhenItLeads() throws {
        let card = GitStatusOverlayView()
        card.updateModel(GitStatusOverlayView.ModelReading(name: "Opus 5"))
        card.applyInk(WindowBackdrop.ink)
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        card.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            card.fittingSize.height,
            GitStatusOverlayDefaults.height,
            accuracy: 0.5,
            "a leading agent line should reproduce the card's single-band height"
        )
    }

    /// The row grows the card downward rather than taking width from the branch name — the whole
    /// reason the card stacks instead of running facts along one line.
    func testTheAgentLineGrowsTheCardDownward() {
        let card = GitStatusOverlayView()
        card.update(with: GitChangeMonitor.Reading(
            branch: "test-levels-and-sidebar-archive",
            summary: GitChangeSummary(files: 2, added: 35, removed: 1)
        ))
        card.applyInk(WindowBackdrop.ink)
        let without = card.fittingSize

        card.updateModel(GitStatusOverlayView.ModelReading(name: "Opus 5", effort: "Extra High"))
        let with = card.fittingSize

        XCTAssertGreaterThan(with.height, without.height, "the agent line did not add a row")
        XCTAssertLessThanOrEqual(
            with.width,
            GitStatusOverlayDefaults.maxWidth,
            "the card broke its own ceiling"
        )
    }

    /// The card carries its colours inside attributed strings, which cannot be re-inked in place;
    /// a theme change therefore has to rebuild the model row as well as repaint the surface.
    func testTheAgentLineRestylesWhenTheFloatingChromeChanges() throws {
        WindowBackdrop.set(.terminal(NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)))
        defer { WindowBackdrop.set(.chrome) }
        AppThemePalette.set(AppThemeStyles.win98)
        let card = GitStatusOverlayView()
        card.updateModel(GitStatusOverlayView.ModelReading(name: "Opus 5", effort: "Extra High"))
        card.applyInk(WindowBackdrop.ink)

        func modelRowColours() -> [String] {
            descendants(of: card)
                .compactMap { $0 as? NSTextField }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
                .compactMap { $0.attributedStringValue }
                .flatMap { string -> [String] in
                    var found: [String] = []
                    string.enumerateAttribute(
                        .foregroundColor,
                        in: NSRange(location: 0, length: string.length)
                    ) { value, _, _ in
                        guard let colour = value as? NSColor,
                              let frozen = colour.usingColorSpace(.sRGB) else { return }
                        found.append(frozen.hexString)
                    }
                    return found
                }
        }

        let before = modelRowColours()
        XCTAssertFalse(before.isEmpty, "the agent line drew no coloured run")

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        card.applyInk(WindowBackdrop.ink)

        XCTAssertNotEqual(
            before,
            modelRowColours(),
            "the agent line kept the previous theme's floating-surface ink"
        )
    }

    func testRunReceiptRendersUnderSystemAndContrastingThemes() throws {
        Design.Motion.reduceMotionOverrideForTesting = true

        for theme in [
            AppTheme.system,
            AppThemeStyles.win98,
            AppThemeStyles.cyberpunk,
            AppThemeStyles.swissMinimalist,
            AppThemeStyles.neoBrutalism,
            AppThemeStyles.claymorphism
        ] {
            AppThemePalette.set(theme)
            WindowBackdrop.set(.chrome)

            let card = GitStatusOverlayView()
            card.update(with: GitChangeMonitor.Reading(
                branch: "feature/progress",
                summary: GitChangeSummary(files: 2, added: 35, removed: 1)
            ))
            card.updateRunState(
                isActive: true,
                progress: RunProgress(step: 2, total: 4)
            )
            card.applyInk(WindowBackdrop.ink)
            // Sized by what it holds: the card is as tall as the rows it stacked.
            card.frame = NSRect(origin: .zero, size: card.fittingSize)
            card.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
            card.cacheDisplay(in: card.bounds, to: rep)
            XCTAssertNotNil(
                rep.representation(using: .png, properties: [:]),
                "\(theme.name) did not draw the run receipt"
            )
        }
    }

    /// The card floats over pane content but belongs to the active chrome. Windows 98 therefore
    /// keeps its information-yellow surface even over an unrelated green terminal palette.
    func testTheGitCardUsesOpaqueThemeChromeAboveThePane() throws {
        let ground = NSColor(srgbRed: 0.05, green: 0.12, blue: 0.09, alpha: 1)
        AppThemePalette.set(AppThemeStyles.win98)
        WindowBackdrop.set(.terminal(ground))
        defer { WindowBackdrop.set(.chrome) }

        let card = GitStatusOverlayView()
        card.update(with: GitChangeMonitor.Reading(
            branch: "sidebar-hover-refresh-test",
            summary: GitChangeSummary(files: 12, added: 8_511, removed: 4_746)
        ))
        card.applyInk(WindowBackdrop.ink)

        let fill = try XCTUnwrap(card.layer?.backgroundColor)
        XCTAssertEqual(fill.alpha, 1, accuracy: 0.001,
                       "the card's fill let the text behind it through")
        let border = try XCTUnwrap(card.layer?.borderColor)
        XCTAssertEqual(border.alpha, 1, accuracy: 0.001,
                       "the card's border let the text behind it through")
        XCTAssertEqual(card.alphaValue, 1,
                       "a view-level alpha thins the fill along with what it is quieting")
        XCTAssertEqual(card.layer?.cornerRadius, 0, "Windows 98 grew modern rounded corners")
        XCTAssertEqual(card.layer?.shadowOpacity, 0, "Windows 98 gained an ambient shadow")

        let painted = try XCTUnwrap(NSColor(cgColor: fill)?.usingColorSpace(.sRGB))
        XCTAssertEqual(painted.hexString, "#FFFFE1")
        // Branch, changes, model, speed — the card's whole semantic set, held whether or not the
        // reading it was given draws each one.
        XCTAssertEqual(
            descendants(of: card).compactMap { $0 as? ThemedFloatingGlyphView }.count,
            4,
            "the themed card lost one of its semantic marks"
        )
    }

    /// The floating-surface grammar carries more than colour. Period chrome uses its hard bevel
    /// instead of a flat rule, while authored modern materials keep the depth construction they
    /// use on every other panel.
    func testTheGitCardConsumesTheThemesAuthoredEdgeAndDepth() throws {
        let card = GitStatusOverlayView()
        card.update(with: GitChangeMonitor.Reading(
            branch: "surface-grammar",
            summary: GitChangeSummary(files: 3, added: 21, removed: 8)
        ))

        AppThemePalette.set(AppThemeStyles.platinum)
        card.applyInk(WindowBackdrop.ink)
        XCTAssertNotNil(
            card.layer?.sublayers?.first { $0.name == "threading.bevel" },
            "a period card did not consume its material bevel"
        )
        XCTAssertEqual(card.layer?.borderWidth, 0,
                       "the flat border was left on underneath the period bevel")
        XCTAssertEqual(card.layer?.shadowOpacity, 0,
                       "the period card gained a modern ambient shadow")

        AppThemePalette.set(AppThemeStyles.neoBrutalism)
        card.applyInk(WindowBackdrop.ink)
        XCTAssertNil(card.layer?.sublayers?.first { $0.name == "threading.bevel" })
        XCTAssertGreaterThan(card.layer?.shadowOpacity ?? 0, 0,
                             "Neo Brutalism lost its hard offset depth")

        AppThemePalette.set(AppThemeStyles.claymorphism)
        card.applyInk(WindowBackdrop.ink)
        XCTAssertNotNil(
            card.layer?.sublayers?.first { $0.name == "threading.bevel" },
            "Claymorphism lost its soft inner relief"
        )
        XCTAssertGreaterThan(card.layer?.shadowOpacity ?? 0, 0,
                             "Claymorphism lost its soft outer depth")
        XCTAssertNotNil(
            card.layer?.sublayers?.first { $0.name == "threading.glow.highlight" },
            "Claymorphism lost the authored light half of its paired shadow"
        )
    }

    /// The branch mark and the branch name have to sit on one line, and the pair has to sit in
    /// the middle of the pill. Neither held: `NSTextField.label(attributed:)` left the field on
    /// AppKit's 13pt default, and a single-line field draws on the *field's* baseline, so 11pt
    /// runs landed a little over two points below the baseline the field itself reported. The
    /// words sat low in the card and the mark, centred on the same box, read high beside them.
    ///
    /// Measured on the drawing, because the constraints were right the whole time.
    func testTheGitCardsMarkAndItsWordsShareOneOpticalLine() throws {
        let card = GitStatusOverlayView()
        // Capitals only: the ink box of `MASTER` is exactly the cap band, so its centre can be
        // compared with the mark's without a descender dragging the measurement down.
        card.update(with: GitChangeMonitor.Reading(
            branch: "MASTER",
            summary: GitChangeSummary(files: 2, added: 35, removed: 1)
        ))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        card.applyInk(WindowBackdrop.ink)
        host.layoutSubtreeIfNeeded()

        // The card stacks one fact per row, so the pair being measured is the top row's — the
        // counters are a line of their own below it.
        let content = try XCTUnwrap(card.subviews.compactMap { $0 as? NSStackView }.first)
        let summary = try XCTUnwrap(content.arrangedSubviews.compactMap { $0 as? NSStackView }.first)
        let mark = try XCTUnwrap(
            summary.arrangedSubviews.compactMap { $0 as? ThemedFloatingGlyphView }.first
        )
        let words = try XCTUnwrap(summary.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
        let markFrame = card.convert(mark.bounds, from: mark)
        let wordsFrame = card.convert(words.bounds, from: words)

        let ink = try RenderedInk(of: card, scale: 8)
        let fill = try XCTUnwrap(card.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        // The summary band, measured from the top of the card, so neither the counters line
        // below nor the card's own edge counts as ink. It clears the border by more than the
        // border's width: at eight samples per point its antialiased skirt is ink too, and a
        // band that starts at the card's edge measures the edge instead of the words — which
        // is exactly what this test used to do, both ranges pinned to the band's own ends.
        let band = Design.Spacing.tight
            ... GitStatusOverlayDefaults.height - Design.Spacing.tight

        let markInk = try XCTUnwrap(
            ink.rows(from: markFrame.minX, to: markFrame.maxX, within: band, unlike: fill),
            "the branch mark drew nothing"
        )
        let wordsInk = try XCTUnwrap(
            ink.rows(from: wordsFrame.minX, to: wordsFrame.maxX, within: band, unlike: fill),
            "the branch name drew nothing"
        )

        XCTAssertEqual(markInk.middle, wordsInk.middle, accuracy: 0.75,
                       "the mark and the name are drawn on different lines")
        for (name, drawn) in [("mark", markInk), ("name", wordsInk)] {
            XCTAssertEqual(drawn.middle, GitStatusOverlayDefaults.height / 2, accuracy: 0.75,
                           "the \(name) sits off the centre of the band it is in")
        }
    }

    /// Draws the card in the states that add and remove a row across each floating-surface
    /// construction: native light/dark, a Windows infotip, a period bevel, hard depth, soft depth.
    ///
    /// One row per fact is a decision a picture settles and an assertion cannot: whether four
    /// facts at the corner of a pane still read as a card rather than as a panel, and whether
    /// the two marks and the counters line hold a column at the leading edge.
    func testRendersTheGitCardStorybook() throws {
        let directory: URL = {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let dirty = GitChangeSummary(files: 12, added: 4_203, removed: 250)
        // The last card is drawn with the pointer on its Git rows, because "the part that acts
        // lights up and the part that does not stays quiet" is a claim about a picture: what a
        // wash does to a 26-point card floating over a terminal is not readable from a colour.
        let states: [(hovered: Bool, apply: @MainActor (GitStatusOverlayView) -> Void)] = [
            (false, { $0.update(with: .init(branch: "master", summary: .clean)) }),
            (false, {
                $0.update(with: .init(branch: "test-levels-and-sidebar-archive", summary: dirty))
            }),
            (false, {
                $0.update(with: .init(branch: "master", summary: GitChangeSummary(
                    files: 76, added: 22_431, removed: 14_004
                )))
                // Fast, so the bolt the row ends on is in the picture — including under the two
                // period themes, where it is drawn by hand rather than by SF Symbols.
                $0.updateModel(.init(name: "Opus · 1M", effort: "Extra High", isFast: true))
            }),
            (false, {
                $0.update(with: .init(branch: "test-levels-and-sidebar-archive", summary: dirty))
                $0.updateSubagents(workingCount: 2, doneCount: 9)
            }),
            (false, {
                $0.update(with: .init(
                    branch: "test-levels-and-sidebar-archive",
                    summary: GitChangeSummary(files: 1_234, added: 8_349, removed: 4_742)
                ))
                $0.updateRunState(isActive: true, progress: RunProgress(step: 2, total: 4))
                $0.updateSubagents(workingCount: 0, doneCount: 9)
            }),
            (true, {
                $0.update(with: .init(branch: "test-levels-and-sidebar-archive", summary: dirty))
                $0.updateModel(.init(name: "Opus · 1M", effort: "Extra High"))
                $0.updateSubagents(workingCount: 2, doneCount: 9)
            })
        ]

        Design.Motion.reduceMotionOverrideForTesting = true
        let variants: [(
            name: String,
            theme: AppTheme,
            appearance: NSAppearance.Name,
            background: NSColor?
        )] = [
            ("system-light", .system, .aqua, nil),
            ("system-dark", .system, .darkAqua, nil),
            ("win98-on-terminal", AppThemeStyles.win98, .aqua,
             NSColor(srgbRed: 0, green: 0.33, blue: 0, alpha: 1)),
            // Platinum's terminal is white. Rendering its floating card over the gray window
            // ground hid the exact failure this fixture is meant to catch: a white card over
            // the real white terminal, visible only as its trailing bevel.
            ("platinum-on-terminal", AppThemeStyles.platinum, .aqua, .white),
            ("neo-brutalism", AppThemeStyles.neoBrutalism, .aqua, nil),
            ("claymorphism", AppThemeStyles.claymorphism, .aqua, nil)
        ]
        var written = 0
        for variant in variants {
            AppThemePalette.set(variant.theme)
            let appearance = try XCTUnwrap(NSAppearance(named: variant.appearance))
            var data: Data?

            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated {
                    // Built before the host, because the host's height *is* the cards': a fixed
                    // canvas clipped the last card off the sheet, and the last card is the
                    // hovered one — the single state this storybook exists to show.
                    let cards: [(card: GitStatusOverlayView, hovered: Bool, size: NSSize)] =
                        states.map { state in
                            let card = GitStatusOverlayView()
                            state.apply(card)
                            card.applyInk(WindowBackdrop.ink)
                            return (card, state.hovered, card.fittingSize)
                        }
                    let height = cards.reduce(Design.Spacing.inset) {
                        $0 + $1.size.height + Design.Spacing.large
                    }

                    let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: height))
                    host.appearance = appearance
                    host.applySurface(
                        fill: variant.background ?? Design.Surface.background,
                        radius: .fixed(0)
                    )

                    // Laid out from the top down, the way the pane's corner stacks them.
                    var top = Design.Spacing.inset
                    var lit: [GitStatusOverlayView] = []
                    for entry in cards {
                        entry.card.frame = NSRect(
                            x: host.bounds.width - entry.size.width - Design.Spacing.inset,
                            y: host.bounds.height - top - entry.size.height,
                            width: entry.size.width,
                            height: entry.size.height
                        )
                        host.addSubview(entry.card)
                        if entry.hovered { lit.append(entry.card) }
                        top += entry.size.height + Design.Spacing.large
                    }

                    host.layoutSubtreeIfNeeded()

                    // The pointer arrives after layout, since where the Git rows are is the
                    // question the card only answers once it has laid them out.
                    for card in lit {
                        card.mouseEntered(with: NSEvent())
                        let branch = card.subviews
                            .compactMap { $0 as? NSStackView }
                            .flatMap { self.descendants(of: $0) }
                            .compactMap { $0 as? NSTextField }
                            .first { $0.stringValue.contains("test-levels") }
                        guard let branch else { continue }
                        let words = branch.convert(branch.bounds, to: nil)
                        card.mouseMoved(with: self.pointer(
                            at: NSPoint(x: words.midX, y: words.midY)
                        ))
                    }
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        return
                    }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }
            }

            try XCTUnwrap(data).write(
                to: directory.appendingPathComponent("git-card-\(variant.name).png")
            )
            written += 1
        }

        XCTAssertEqual(written, variants.count)
        print("Rendered the git card storybook to \(directory.path)")
    }

    /// Hover lifts what the card *says*, not the card. The distinction is the whole fix: an
    /// alpha on the view is a hole in it.
    func testGitCardHoverLiftsItsContentsAndLeavesTheSurfaceOpaque() throws {
        let card = GitStatusOverlayView()
        card.update(with: GitChangeMonitor.Reading(
            branch: "main",
            summary: GitChangeSummary(files: 1, added: 2, removed: 3)
        ))
        card.applyInk(WindowBackdrop.ink)
        let contents = try XCTUnwrap(card.subviews.compactMap { $0 as? NSStackView }.first)

        XCTAssertEqual(contents.alphaValue,
                       GitStatusOverlayDefaults.restingContentAlpha,
                       accuracy: 0.001)

        card.mouseEntered(with: NSEvent())
        XCTAssertEqual(contents.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(card.layer?.backgroundColor).alpha, 1, accuracy: 0.001)

        card.mouseExited(with: NSEvent())
        XCTAssertEqual(contents.alphaValue,
                       GitStatusOverlayDefaults.restingContentAlpha,
                       accuracy: 0.001)
    }

    // MARK: - What the Card Says Can Be Clicked

    /// The pointer lights the rows that open Git Review and nothing else on the card.
    ///
    /// It used to light all of it, by a hair: the whole view lifted from 85% to full, which is
    /// the same answer for the branch that opens a pane, the agent line that does nothing, and an
    /// extension row that cannot. The lift stays — it is the card waking up — and the wash under
    /// the words is what says *this part acts*.
    ///
    /// Measured after the pointer has already entered, so the alpha lift is in both renders and
    /// the only thing left to differ is the wash.
    func testOnlyTheRowsThatActLightUnderThePointer() throws {
        let card = try laidOutCard()
        let quiet = try drawing(of: card)

        card.mouseEntered(with: NSEvent())
        let awake = try drawing(of: card)
        XCTAssertNotEqual(awake, quiet, "the card did not wake up under the pointer at all")

        card.mouseMoved(with: pointer(at: try centre(of: "Opus 5", in: card)))
        XCTAssertEqual(try drawing(of: card), awake,
                       "the agent line lit under the pointer, and it opens nothing")

        card.mouseMoved(with: pointer(at: try centre(of: "main", in: card)))
        XCTAssertNotEqual(try drawing(of: card), awake,
                          "the branch row is the card's Git receipt and drew no hover at all")

        card.mouseExited(with: NSEvent())
        XCTAssertEqual(try drawing(of: card), quiet,
                       "the wash outlived the pointer that raised it")
    }

    /// One row lights at a time, even though both open Git Review.
    ///
    /// They used to lift together, on the reasoning that they are one destination. But a hover
    /// answers *where the pointer is*; the destination is what the click is for. Lighting the
    /// counters because the pointer is on the branch reports a pointer that is not there.
    func testOnlyTheGitRowUnderThePointerLights() throws {
        let card = try laidOutCard()
        card.mouseEntered(with: NSEvent())
        let awake = try drawing(of: card)

        card.mouseMoved(with: pointer(at: try centre(of: "main", in: card)))
        let onBranch = try drawing(of: card)

        card.mouseMoved(with: pointer(at: try centre(of: "12", in: card)))
        let onCounters = try drawing(of: card)

        XCTAssertNotEqual(onBranch, awake, "the branch row drew no wash under the pointer")
        XCTAssertNotEqual(onCounters, awake, "the counters row drew no wash under the pointer")
        XCTAssertNotEqual(onBranch, onCounters,
                          "both Git rows lit for a pointer that was only ever on one of them")
    }

    /// Splitting the wash in two opens a gap the union does not have: the ground between the
    /// rows, and the padding grown past it, are inside the hit target but inside neither row. A
    /// pointer that opens Git Review while the card shows nothing lit is the same broken promise
    /// as a wash over a row that does not act, told backwards — so every point that clicks
    /// through lights the row it is nearest. Swept rather than sampled at one guessed offset,
    /// because where the rows end and the gap starts is exactly what this must not assume.
    func testNoPointThatOpensGitReviewLeavesTheCardUnlit() throws {
        let card = try laidOutCard()
        card.mouseEntered(with: NSEvent())
        let awake = try drawing(of: card)

        let branch = try centre(of: "main", in: card)
        let counters = try centre(of: "12", in: card)
        var opened = 0
        card.onOpen = { opened += 1 }

        for step in 0...10 {
            let point = NSPoint(x: branch.x,
                                y: branch.y + (counters.y - branch.y) * CGFloat(step) / 10)
            card.mouseMoved(with: pointer(at: point))
            XCTAssertNotEqual(try drawing(of: card), awake,
                              "nothing lit at \(point), between the two rows that act")
            card.mouseDown(with: pointer(at: point))
        }

        XCTAssertEqual(opened, 11, "a lit point did not open Git Review")
    }

    /// The lit rows and the clickable rows are the same rows. A hover that promises a
    /// destination the click does not deliver — or the reverse — is worse than no hover.
    func testTheGitRowsAreTheCardsHitTargetRatherThanTheWholeCard() throws {
        let card = try laidOutCard()
        var opened = 0
        card.onOpen = { opened += 1 }

        card.mouseDown(with: pointer(at: try centre(of: "Opus 5", in: card)))
        XCTAssertEqual(opened, 0, "the agent line opened Git Review")

        card.mouseDown(with: pointer(at: try centre(of: "main", in: card)))
        XCTAssertEqual(opened, 1, "the branch row did not open Git Review")
    }

    /// A card that calls itself a button has to be pressable by something other than a pointer.
    /// It carried the role and no action, so VoiceOver announced a button that did nothing.
    func testTheCardOpensGitReviewForAScreenReaderToo() throws {
        let card = try laidOutCard()
        var opened = 0
        card.onOpen = { opened += 1 }

        XCTAssertEqual(card.accessibilityRole(), .button)
        XCTAssertTrue(card.accessibilityPerformPress())
        XCTAssertEqual(opened, 1)

        card.clear()
        card.updateModel(GitStatusOverlayView.ModelReading(name: "Opus 5"))
        card.applyInk(WindowBackdrop.ink)
        XCTAssertFalse(card.accessibilityPerformPress(),
                       "a card with no Git sentence answered a press")
        XCTAssertEqual(opened, 1)
    }

    /// Both button rows are inked for the floating surface they sit on, which is what gives them a
    /// hover at all. The audience row was given neither colour, so it drew in AppKit's own label
    /// tier and lifted to nothing — inert by omission rather than by design.
    func testBothButtonRowsAreInkedForTheFloatingSurfaceTheySitOn() throws {
        let card = GitStatusOverlayView()
        card.updateSubagents(workingCount: 1, doneCount: 0)
        card.updateAudience(GitStatusOverlayView.AudienceReading(following: 0, isShared: true))
        card.applyInk(WindowBackdrop.ink)

        let buttons = card.subviews
            .compactMap { $0 as? NSStackView }
            .flatMap(\.arrangedSubviews)
            .compactMap { $0 as? ThemedButton }
            .filter { !$0.isHidden }
        XCTAssertEqual(buttons.count, 2, "the card drew \(buttons.count) button rows, not two")

        for button in buttons {
            XCTAssertEqual(button.hoverFill, Design.Ink.chrome.surfaceHover,
                           "\(button.title) raises nothing under the pointer")
            XCTAssertEqual(button.contentTintColor, Design.Ink.chrome.secondary,
                           "\(button.title) is not inked for the floating chrome it sits on")
        }
    }

    // MARK: - Switching the Card Off

    /// The switch and "has anything to say" are two answers, and the card needs both.
    func testTheCardCanBeSwitchedOffAndBackOnWithoutLosingWhatItSays() throws {
        Design.Motion.reduceMotionOverrideForTesting = true
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let card = try laidOutCard()
        XCTAssertFalse(card.isHidden, "a card with a branch and a switch left on is not on screen")

        card.setAllowedOnScreen(false, animated: true)
        XCTAssertTrue(card.isHidden, "the card stayed after being switched off")

        card.setAllowedOnScreen(true, animated: true)
        XCTAssertFalse(card.isHidden, "the card did not come back")
        XCTAssertEqual(card.alphaValue, 1, accuracy: 0.001,
                       "the card came back still faded out")
    }

    /// Switching it on is permission, not content. A pane with no checkout has nothing to show,
    /// and a switch cannot conjure a branch.
    func testSwitchingTheCardOnShowsNothingWhenItHasNothingToSay() throws {
        Design.Motion.reduceMotionOverrideForTesting = true
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let card = try laidOutCard()
        card.clear()
        XCTAssertTrue(card.isHidden)

        card.setAllowedOnScreen(false, animated: false)
        card.setAllowedOnScreen(true, animated: false)
        XCTAssertTrue(card.isHidden, "an empty card was shown because the switch was on")
    }

    /// A card switched off while the pointer was on it must not return already lit: no exit is
    /// delivered to a view hidden out from under the pointer.
    func testACardHiddenUnderThePointerDoesNotComeBackLit() throws {
        Design.Motion.reduceMotionOverrideForTesting = true
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let card = try laidOutCard()
        let quiet = try drawing(of: card)

        card.mouseEntered(with: NSEvent())
        card.mouseMoved(with: pointer(at: try centre(of: "main", in: card)))
        XCTAssertNotEqual(try drawing(of: card), quiet, "the pointer lit nothing to begin with")

        card.setAllowedOnScreen(false, animated: false)
        card.setAllowedOnScreen(true, animated: false)

        XCTAssertEqual(try drawing(of: card), quiet,
                       "the card came back wearing the hover it left with")
    }

    /// The leaving is animated rather than instant — which is exactly why `isHidden` cannot be
    /// the state the next toggle reads.
    func testTheCardAnimatesAwayRatherThanBlinkingOut() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let card = try laidOutCard()
        card.setAllowedOnScreen(false, animated: true)
        XCTAssertFalse(card.isHidden, "the card was hidden before its fade had a chance to run")

        // Back before the vanish could finish. The card is wanted on screen, and the stale
        // completion still in flight must not take it away a beat later.
        card.setAllowedOnScreen(true, animated: true)
        XCTAssertFalse(card.isHidden)

        let settled = expectation(description: "both transitions finished")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertFalse(card.isHidden, "a stale vanish hid a card that had been asked back")
        XCTAssertEqual(card.alphaValue, 1, accuracy: 0.001)
    }

    /// Under Reduce Motion the end state is owed *now*, not a run-loop turn later: a zero-length
    /// animation still defers its completion, and a caller that read `isHidden` straight after
    /// would get the state the card was leaving.
    func testReduceMotionPutsTheCardWhereItIsGoingImmediately() throws {
        Design.Motion.reduceMotionOverrideForTesting = true
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let card = try laidOutCard()
        card.setAllowedOnScreen(false, animated: true)
        XCTAssertTrue(card.isHidden)
        XCTAssertEqual(card.alphaValue, 0, accuracy: 0.001)
    }

    // MARK: - Room for the Card

    /// The card floats *over* the terminal, so what it costs is the text underneath. Half the
    /// pane is where it stops being an annotation and starts being a second column.
    func testTheCardKeepsToHalfThePaneOrWithdraws() {
        XCTAssertTrue(GitStatusOverlayDefaults.hasRoom(forCardWidth: 200, inPaneWidth: 800))
        XCTAssertTrue(GitStatusOverlayDefaults.hasRoom(forCardWidth: 200, inPaneWidth: 400),
                      "exactly half is still room")
        XCTAssertFalse(GitStatusOverlayDefaults.hasRoom(forCardWidth: 200, inPaneWidth: 320),
                       "the card covered most of a narrow pane and stayed")

        // The rule is a share because the card's width is the branch name's: the same pane is
        // roomy for one checkout and tight for another.
        XCTAssertTrue(GitStatusOverlayDefaults.hasRoom(forCardWidth: 140, inPaneWidth: 320))
    }

    /// A pane with no width has not been laid out yet rather than being narrow. Answering "no
    /// room" there hides the card for the whole of the first layout pass.
    func testAPaneThatHasNotBeenLaidOutYetIsNotCalledTooNarrow() {
        XCTAssertTrue(GitStatusOverlayDefaults.hasRoom(forCardWidth: 200, inPaneWidth: 0))
    }

    /// Every row of the card is one height, and the hover wash is that height.
    ///
    /// It was two heights and neither was stated: a text row's line box is 15pt, a plain
    /// `ThemedButton` pads itself to 22, and the wash grew by whatever `rowGap` had left over —
    /// which was 2, so the lit row came out *shorter* than the control sitting under it. The
    /// numbers now come from `rowPadding`, and this is what says so.
    func testEveryRowOfTheCardIsOneHeightAndTheWashIsThatHeight() throws {
        let card = try laidOutCard()
        card.updateSubagents(workingCount: 2, doneCount: 9)
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        card.layoutSubtreeIfNeeded()

        let button = try XCTUnwrap(descendants(of: card).compactMap { $0 as? ThemedButton }.first)
        XCTAssertEqual(button.frame.height, GitStatusOverlayDefaults.rowHeight, accuracy: 0.5,
                       "the children row kept the height ThemedButton picked for itself")

        // The wash is not reachable directly, so it is measured the way it is drawn: a text row's
        // line box grown by the padding either side.
        let words = try XCTUnwrap(descendants(of: card).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.contains("main") })
        let lit = words.frame.height + GitStatusOverlayDefaults.rowPadding * 2
        XCTAssertEqual(lit, GitStatusOverlayDefaults.rowHeight, accuracy: 0.5,
                       "a lit text row and the control row below it are different shapes")
    }

    /// The gap has to carry both neighbouring washes *and* a hairline of ground between them.
    /// It did not, so the wash was clamped to fit the gap — the gap was setting the padding.
    func testTheRowGapLeavesRoomForTwoWashesAndAHairline() {
        XCTAssertGreaterThanOrEqual(
            GitStatusOverlayDefaults.rowGap,
            GitStatusOverlayDefaults.rowPadding * 2 + Design.Spacing.hairline,
            "two lit rows would fuse into the single block the per-row wash exists to avoid"
        )
    }

    // MARK: - Card Fixtures

    /// A card carrying all three kinds of row — a Git receipt that acts, and an agent line that
    /// does not — laid out at its own size so a point can be taken in either.
    private func laidOutCard() throws -> GitStatusOverlayView {
        let card = GitStatusOverlayView()
        card.update(with: GitChangeMonitor.Reading(
            branch: "main",
            summary: GitChangeSummary(files: 12, added: 4_203, removed: 250)
        ))
        card.updateModel(GitStatusOverlayView.ModelReading(name: "Opus 5"))
        card.applyInk(WindowBackdrop.ink)
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        card.layoutSubtreeIfNeeded()
        return card
    }

    /// The centre of the row holding a given reading, in the card's own coordinates — which are
    /// also the window's here, since the fixture card is the root of its own tree at the origin.
    private func centre(of text: String, in card: GitStatusOverlayView) throws -> NSPoint {
        let label = try XCTUnwrap(
            descendants(of: card)
                .compactMap { $0 as? NSTextField }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
                .first { $0.stringValue.contains(text) },
            "the card is not showing \(text)"
        )
        let frame = card.convert(label.bounds, from: label)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    private func pointer(at location: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) ?? NSEvent()
    }

    /// What the view actually drew, as bytes — the comparison a hover wash needs, since the
    /// thing that changed is a fill behind text rather than a property anyone can read back.
    private func drawing(of view: NSView) throws -> Data {
        // A layer-backed view hands `cacheDisplay` whatever its layer already holds, and a state
        // change only marks that layer dirty — so without this the second capture is a picture of
        // the first, and every assertion about a redraw passes by never taking one.
        view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

// MARK: - Rendered Ink

/// One view drawn at a magnification, so a measurement can be taken of what it *drew* rather
/// than of the frames it was given. The distinction is the point: the git card's mark and its
/// words were laid out on one centre line and drawn on two.
private struct RenderedInk {

    private let rep: NSBitmapImageRep
    private let scale: CGFloat

    @MainActor
    init(of view: NSView, scale: Int) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * scale,
            pixelsHigh: Int(view.bounds.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the view has no drawable bounds")
        // Point size on a pixel grid that is `scale` times denser, which is what makes a
        // fraction-of-a-point misalignment measurable at all.
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        self.rep = rep
        self.scale = CGFloat(scale)
    }

    /// The rows carrying ink in a column band, in points **from the top** — the direction a
    /// reader compares two things in, and the opposite of the view's own coordinates.
    func rows(
        from minX: CGFloat,
        to maxX: CGFloat,
        within band: ClosedRange<CGFloat>,
        unlike fill: NSColor
    ) -> ClosedRange<CGFloat>? {
        var first: Int?
        var last = 0
        for y in Int(band.lowerBound * scale)..<Int(band.upperBound * scale) {
            for x in Int(minX * scale)..<Int(maxX * scale)
            where rep.colorAt(x: x, y: y)?.isInk(over: fill) == true {
                if first == nil { first = y }
                last = y
                break
            }
        }
        guard let first else { return nil }
        return CGFloat(first) / scale ... CGFloat(last + 1) / scale
    }
}

private extension NSColor {

    /// Far enough from the surface behind it to be something drawn on it. The threshold clears
    /// the antialiased skirt of a glyph without needing the ink's own colour, which here is
    /// three different roles — a grey name, a green count, a red one.
    func isInk(over fill: NSColor) -> Bool {
        guard let ink = usingColorSpace(.sRGB), let ground = fill.usingColorSpace(.sRGB) else {
            return false
        }
        return max(
            abs(ink.redComponent - ground.redComponent),
            abs(ink.greenComponent - ground.greenComponent),
            abs(ink.blueComponent - ground.blueComponent)
        ) > 0.08
    }
}

private extension ClosedRange where Bound == CGFloat {
    var middle: CGFloat { (lowerBound + upperBound) / 2 }
}
