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
    /// Neo Brutalism (3), one window drew both.
    ///
    /// The same staleness as the split seam's, one view along: see
    /// `AppThemeTests.testTheSeamIsRelaidOutWhenTheThemeChangesUnderIt`.
    func testARuleAlreadyLaidOutTakesTheWeightOfTheThemeThatArrives() throws {
        switchTheme(to: AppThemeStyles.neoBrutalism)
        let header = try hostedPaneHeader()
        XCTAssertEqual(
            try ruleThickness(in: header),
            3,
            "the header did not start at Neo Brutalism's weight"
        )

        switchTheme(to: AppThemeStyles.editorial)

        XCTAssertEqual(
            try ruleThickness(in: header),
            1,
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

    /// A run promotes the card's first line; it does not put a *third* spinner on screen.
    ///
    /// A terminal session's CLI draws its own a few lines below the card, and a native
    /// conversation animates one beside its status. The card's copy was the only one sitting on
    /// the terminal's palette, where an accent the theme never chose reads as a stray colour
    /// rather than as a state.
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
        let marks = everything.compactMap { ($0 as? NSImageView)?.image?.accessibilityDescription }
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
            .compactMap { $0 as? NSImageView }
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
        // Spoken as the rows are stacked, the agent line last.
        XCTAssertEqual(
            card.accessibilityLabel(),
            "test-levels-and-sidebar-archive  ·  2 files +35 −1  ·  Opus 5 · Fast · Extra High"
        )

        let marks = descendants(of: card)
            .compactMap { $0 as? NSImageView }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .compactMap { $0.image?.accessibilityDescription }
        XCTAssertTrue(marks.contains("Model"), "the agent line lost its mark")
    }

    /// Each part is independently droppable, because the caller has already removed whatever the
    /// session's own status line prints. A card told only about speed says only that.
    func testTheAgentLineShowsOnlyTheFactsItWasGiven() {
        let card = GitStatusOverlayView()
        card.updateModel(GitStatusOverlayView.ModelReading(isFast: true))
        card.applyInk(WindowBackdrop.ink)

        XCTAssertFalse(card.isHidden, "a fact with no Git reading still deserves the card")
        XCTAssertEqual(card.accessibilityLabel(), "Fast")

        card.updateModel(GitStatusOverlayView.ModelReading(name: "Opus 5"))
        XCTAssertEqual(card.accessibilityLabel(), "Opus 5")
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

    /// The card carries its colours inside attributed strings, which cannot be re-inked in place —
    /// so an ink arriving after the row was built has to rebuild it.
    ///
    /// **Switched by backdrop, not by app theme.** This card is a `BackdropOverlay`: it floats on
    /// the *terminal's* ground and takes its ink from there, so an app palette change leaves its
    /// label colours exactly where they were. Written against `AppThemePalette` first, this test
    /// passed nothing and proved nothing — both readings were white at 70% and 50%.
    func testTheAgentLineRestylesWhenTheInkChanges() throws {
        WindowBackdrop.set(.terminal(NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)))
        defer { WindowBackdrop.set(.chrome) }
        let card = GitStatusOverlayView()
        card.updateModel(GitStatusOverlayView.ModelReading(name: "Opus 5", effort: "Extra High"))
        card.applyInk(WindowBackdrop.ink)

        func modelRowColours() -> [NSColor] {
            descendants(of: card)
                .compactMap { $0 as? NSTextField }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
                .compactMap { $0.attributedStringValue }
                .flatMap { string -> [NSColor] in
                    var found: [NSColor] = []
                    string.enumerateAttribute(
                        .foregroundColor,
                        in: NSRange(location: 0, length: string.length)
                    ) { value, _, _ in
                        if let colour = value as? NSColor { found.append(colour) }
                    }
                    return found
                }
        }

        let before = modelRowColours()
        XCTAssertFalse(before.isEmpty, "the agent line drew no coloured run")

        // A near-white ground has to flip the label ink the dark one produced.
        WindowBackdrop.set(.terminal(NSColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1)))
        card.applyInk(WindowBackdrop.ink)

        XCTAssertNotEqual(
            before.map(\.description),
            modelRowColours().map(\.description),
            "the agent line kept the ink measured against the previous ground"
        )
    }

    func testRunReceiptRendersUnderSystemAndContrastingThemes() throws {
        Design.Motion.reduceMotionOverrideForTesting = true

        for theme in [AppTheme.system, AppThemeStyles.cyberpunk, AppThemeStyles.swissMinimalist] {
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

    /// The card floats over the pane's own content, so it has to occlude it. It did not: the
    /// surface role is the base tone at 14% and the whole view sat at 85%, so under a native
    /// conversation the agent's text ran straight through the branch name.
    ///
    /// Opaque, but *the same colour* — flattening keeps what the role asked for over this
    /// ground and drops only the see-through, which is why the second half of this test matters
    /// as much as the first.
    func testTheGitCardOccludesThePaneTextItFloatsOver() throws {
        let ground = NSColor(srgbRed: 0.05, green: 0.12, blue: 0.09, alpha: 1)
        AppThemePalette.set(.system)
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

        // Same colour as the translucent role would have produced over this ground.
        let expected = try XCTUnwrap(
            WindowBackdrop.ink.surface.composited(over: ground).usingColorSpace(.sRGB)
        )
        let painted = try XCTUnwrap(NSColor(cgColor: fill)?.usingColorSpace(.sRGB))
        for channel in [\NSColor.redComponent, \NSColor.greenComponent, \NSColor.blueComponent] {
            XCTAssertEqual(painted[keyPath: channel], expected[keyPath: channel], accuracy: 0.001,
                           "flattening changed the card's colour rather than only its opacity")
        }
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
        let mark = try XCTUnwrap(summary.arrangedSubviews.compactMap { $0 as? NSImageView }.first)
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

    /// Draws the card in the states that add and remove a row, light and dark.
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
        let states: [@MainActor (GitStatusOverlayView) -> Void] = [
            { $0.update(with: .init(branch: "master", summary: .clean)) },
            { $0.update(with: .init(branch: "test-levels-and-sidebar-archive", summary: dirty)) },
            {
                $0.update(with: .init(branch: "test-levels-and-sidebar-archive", summary: dirty))
                $0.updateSubagents(workingCount: 2, doneCount: 9)
            },
            {
                $0.update(with: .init(
                    branch: "test-levels-and-sidebar-archive",
                    summary: GitChangeSummary(files: 1_234, added: 8_349, removed: 4_742)
                ))
                $0.updateRunState(isActive: true, progress: RunProgress(step: 2, total: 4))
                $0.updateSubagents(workingCount: 0, doneCount: 9)
            }
        ]

        Design.Motion.reduceMotionOverrideForTesting = true
        var written = 0
        for (appearanceName, appearanceID) in [("light", NSAppearance.Name.aqua),
                                               ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceID))
            var data: Data?

            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated {
                    let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
                    host.appearance = appearance
                    host.applySurface(fill: Design.Surface.background, radius: .fixed(0))

                    // Laid out from the top down, the way the pane's corner stacks them.
                    var top = Design.Spacing.inset
                    for state in states {
                        let card = GitStatusOverlayView()
                        state(card)
                        card.applyInk(WindowBackdrop.ink)
                        let size = card.fittingSize
                        card.frame = NSRect(
                            x: host.bounds.width - size.width - Design.Spacing.inset,
                            y: host.bounds.height - top - size.height,
                            width: size.width,
                            height: size.height
                        )
                        host.addSubview(card)
                        top += size.height + Design.Spacing.large
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
                to: directory.appendingPathComponent("git-card-\(appearanceName).png")
            )
            written += 1
        }

        XCTAssertEqual(written, 2)
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
