import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// The views in `ThemedIndicators` replace stock AppKit parts that could not be told to
/// use the theme's colours: `NSBox`'s system-grey hairline, `NSProgressIndicator`'s system-grey
/// spinner, and its system-blue bar. Each is drawn, so each is checked by sampling what it
/// actually put on screen rather than by reading the token back.
@MainActor
final class ThemedIndicatorsTests: XCTestCase {

    override func tearDown() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
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

    /// A section states the distance between visible content and its rule, while AppKit places
    /// frames. The separator is the shared conversion point: a padded menu row gives back its
    /// invisible top/bottom air, and a bare label keeps the complete gap. The fixed constraint
    /// deliberately disagrees with the stale bounds to cover a density change before layout.
    func testTheSeparatorAppliesOneVisibleInkGapAcrossPaddedAndBareRows() {
        let button = ThemedButton(title: "Attachment", target: nil, action: nil)
        button.emphasis = .tertiary
        button.frame.size.height = 40
        let rowHeight: CGFloat = 27
        button.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

        let separator = SeparatorView()
        let label = NSTextField(labelWithString: "Extension row")
        let stack = NSStackView(views: [button, separator, label])
        stack.orientation = .vertical
        let inkGap: CGFloat = 10

        separator.applyOpticalSpacing(
            in: stack,
            precededBy: button,
            followedBy: label,
            inkGap: inkGap
        )

        let buttonInset = button.opticalVerticalInset(forFrameHeight: rowHeight)
        XCTAssertGreaterThan(buttonInset, 0, "the plain button fixture has no optical padding")
        XCTAssertEqual(stack.customSpacing(after: button) + buttonInset, inkGap, accuracy: 0.001)
        XCTAssertEqual(stack.customSpacing(after: separator), inkGap, accuracy: 0.001)
    }

    /// The same API works sideways: a vertical rule in a horizontal stack subtracts the icon
    /// target's horizontal padding. A second container therefore cannot grow another local
    /// `target minus glyph` calculation when it wants the same visual gap.
    func testTheSeparatorUsesTheRelevantOpticalAxis() {
        let button = ThemedIconButton(
            symbolName: "ellipsis",
            accessibility: "More",
            target: .inline
        )
        let separator = SeparatorView(.vertical)
        let label = NSTextField(labelWithString: "Details")
        let stack = NSStackView(views: [button, separator, label])
        stack.orientation = .horizontal
        let inkGap: CGFloat = 10

        separator.applyOpticalSpacing(
            in: stack,
            precededBy: button,
            followedBy: label,
            inkGap: inkGap
        )

        XCTAssertEqual(
            stack.customSpacing(after: button) + button.opticalHorizontalInset,
            inkGap,
            accuracy: 0.001
        )
        XCTAssertEqual(stack.customSpacing(after: separator), inkGap, accuracy: 0.001)
    }

    // MARK: - Pane Fold

    /// The rule keeps the theme's weight and the band adds the pane's own gap under it. Both
    /// halves of that are the point: a fold drawn as a hairline is a one-point drag target, and a
    /// fold given a strip of its own moves everything below it the day it becomes draggable.
    func testTheFoldIsARuleWithThePanesOwnGapUnderItAsTheGrip() {
        let fold = PaneFoldDivider()

        XCTAssertEqual(
            fold.intrinsicContentSize.height,
            Design.Radius.border + PaneFoldDivider.Layout.grip
        )
        XCTAssertEqual(
            fold.intrinsicContentSize.width,
            NSView.noIntrinsicMetric,
            "a fold fixed the width of the pane it divides"
        )
    }

    /// The seam takes the accent wherever a drag would attach to it, which is what the accent
    /// already means on `ThemedSplitView`'s divider — and the only thing that can say a hairline
    /// is draggable before it has been dragged.
    func testTheFoldLightsItsSeamUnderThePointer() throws {
        let fold = PaneFoldDivider()
        fold.frame = NSRect(x: 0, y: 0, width: 40, height: fold.intrinsicContentSize.height)
        _ = hosted(fold)

        let rest = try colour(of: fold, atPointX: 20, y: 0.5)
        fold.mouseEntered(with: enterEvent(in: fold))
        let lit = try colour(of: fold, atPointX: 20, y: 0.5)

        XCTAssertNotEqual(
            rest.hexString,
            lit.hexString,
            "the seam reads the same under the pointer as at rest"
        )
    }

    /// A press takes the focus so the arrow keys work on the fold the hand just left, and focus
    /// is drawn in the pointer's accent — so a released fold stayed lit after every drag, the one
    /// divider in the window that did (`ThemedSplitView` and `ShellDrawerDivider` never take
    /// focus). The accent stays only for a focus that arrived by keyboard, where there is no
    /// pointer to say where the fold is.
    func testTheFoldPutsItsSeamOutWhenTheHandLetsGoUnlessTheKeyboardPutFocusThere() throws {
        let fold = PaneFoldDivider()
        fold.frame = NSRect(x: 0, y: 0, width: 40, height: fold.intrinsicContentSize.height)
        let window = try XCTUnwrap(hosted(fold).window)
        let rest = try colour(of: fold, atPointX: 20, y: 0.5)

        let press = try clickEvent(in: fold, clicks: 1)
        fold.mouseDown(with: press)
        XCTAssertTrue(window.firstResponder === fold, "a press did not take the focus")
        fold.mouseUp(with: press)

        XCTAssertFalse(fold.showsKeyboardFocus, "a press counted as keyboard traversal")
        XCTAssertEqual(
            try colour(of: fold, atPointX: 20, y: 0.5).hexString,
            rest.hexString,
            "the seam stayed lit after the hand let go of it"
        )

        fold.focusArrived(from: arrowEvent(down: true, fine: false))
        XCTAssertTrue(fold.showsKeyboardFocus)
        XCTAssertNotEqual(
            try colour(of: fold, atPointX: 20, y: 0.5).hexString,
            rest.hexString,
            "keyboard traversal left focus with nothing to see"
        )

        window.makeFirstResponder(nil)
        XCTAssertFalse(fold.showsKeyboardFocus, "resigning kept the keyboard's origin")
    }

    /// A drag reports travel, and the release does not: only the pane knows what floor and
    /// ceiling the travel has to be answered against, so the fold hands over points and stops.
    /// The keyboard reports the same points, because a key press moving nothing is a control a
    /// pointer is required for.
    func testTheFoldReportsItsTravelToWhoeverOwnsTheLimits() {
        let fold = PaneFoldDivider()
        var travel: [CGFloat] = []
        fold.onDrag = { travel.append($0) }

        fold.keyDown(with: arrowEvent(down: true, fine: false))
        fold.keyDown(with: arrowEvent(down: false, fine: false))
        fold.keyDown(with: arrowEvent(down: true, fine: true))

        XCTAssertEqual(travel, [
            PaneFoldDivider.Layout.coarseStep,
            -PaneFoldDivider.Layout.coarseStep,
            PaneFoldDivider.Layout.fineStep
        ])
    }

    /// The way out of a fold dragged somewhere unhelpful, and the gesture `NSSplitView` has
    /// answered that way for as long as it has had dividers.
    func testDoubleClickingTheFoldAsksForItToBePlacedAgain() throws {
        let fold = PaneFoldDivider()
        fold.frame = NSRect(x: 0, y: 0, width: 40, height: fold.intrinsicContentSize.height)
        _ = hosted(fold)

        var travel: [CGFloat] = []
        var resets = 0
        fold.onDrag = { travel.append($0) }
        fold.onReset = { resets += 1 }

        fold.mouseDown(with: try clickEvent(in: fold, clicks: 1))
        XCTAssertEqual(resets, 0, "a single press asked for the fold to be placed again")

        fold.mouseDown(with: try clickEvent(in: fold, clicks: 2))
        XCTAssertEqual(resets, 1, "a double-click did not reach the pane")
        XCTAssertEqual(travel, [], "a press moved the fold before the pointer had travelled")
    }

    /// A drawn control has no cell to route VoiceOver through, so a fold that did not say what it
    /// is would be a divider nobody without a pointer could move.
    func testTheFoldIsASplitterAVoiceOverUserCanMove() {
        let fold = PaneFoldDivider()
        var travel: [CGFloat] = []
        fold.onDrag = { travel.append($0) }

        XCTAssertEqual(fold.accessibilityRole(), .splitter)
        XCTAssertEqual(fold.accessibilityOrientation(), .horizontal)
        XCTAssertFalse(
            fold.accessibilityPerformPress(),
            "a fold answered for a press it cannot have"
        )

        XCTAssertTrue(fold.accessibilityPerformIncrement())
        XCTAssertTrue(fold.accessibilityPerformDecrement())
        XCTAssertEqual(travel, [
            PaneFoldDivider.Layout.coarseStep,
            -PaneFoldDivider.Layout.coarseStep
        ])
    }

    /// A fold already on screen follows a live theme switch, since both its ink and its weight
    /// come from the theme — `ThemeRedraw`'s job, and the reason it invalidates the intrinsic
    /// size as well as the drawing.
    func testTheFoldRedrawsOnAThemeChange() {
        AppThemePalette.set(.system)
        let fold = PaneFoldDivider()
        fold.frame = NSRect(x: 0, y: 0, width: 40, height: fold.intrinsicContentSize.height)
        _ = hosted(fold)
        fold.needsDisplay = false

        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.cyberpunk.id))

        XCTAssertTrue(fold.needsDisplay, "a theme change left the fold undrawn")
    }

    // MARK: - Pane Fold — The Corner

    /// Two panes with a fold running edge to edge inside the trailing one: the attachments pane's
    /// own arrangement, and the reason the fold's leading end lands *on* the window's split seam.
    ///
    /// In a window, because the corner is resolved through the view tree and a press carries
    /// window coordinates. Unshown — nothing here needs to be on screen.
    private func cornerFixture() -> (split: ThemedSplitView, fold: PaneFoldDivider) {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let split = ThemedSplitView(frame: frame)
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        split.adjustSubviews()

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = split
        windows.append(window)

        let fold = PaneFoldDivider()
        return (split, fold)
    }

    /// Hangs the fold inside the split's trailing pane, `inset` points in from both its edges.
    private func install(
        _ fold: PaneFoldDivider,
        in split: ThemedSplitView,
        inset: CGFloat = 0
    ) {
        let pane = split.arrangedSubviews[1]
        pane.addSubview(fold)
        NSLayoutConstraint.activate([
            fold.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: inset),
            fold.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -inset),
            fold.centerYAnchor.constraint(equalTo: pane.centerYAnchor)
        ])
        split.layoutSubtreeIfNeeded()
    }

    /// A fold that runs edge to edge ends on the window's split seam, and holding the point where
    /// they cross while moving only one of them is the gesture arriving at half its meaning: the
    /// hand is on both.
    func testTheFoldsEndOnItsPanesEdgeHoldsTheSeamThere() throws {
        let (split, fold) = cornerFixture()
        install(fold, in: split)
        let seam = try XCTUnwrap(split.arrangedSubviews.first).frame.maxX

        let corner = NSPoint(x: fold.bounds.minX + 2, y: fold.bounds.midY)
        XCTAssertEqual(fold.cornerSide(at: corner), .leading)
        XCTAssertNil(
            fold.cornerSide(at: NSPoint(x: fold.bounds.midX, y: fold.bounds.midY)),
            "the middle of the band claimed a seam it is nowhere near"
        )
        XCTAssertNil(
            fold.cornerSide(at: NSPoint(x: fold.bounds.maxX - 2, y: fold.bounds.midY)),
            "the window's own edge grew a seam to grab"
        )

        fold.mouseDown(with: try clickEvent(in: fold, at: corner, clicks: 1))
        XCTAssertEqual(
            split.activeDividerIndex,
            0,
            "a press in the corner did not take hold of the seam beside it"
        )

        split.moveHeldSeam(by: -40)
        XCTAssertEqual(
            try XCTUnwrap(split.arrangedSubviews.first).frame.maxX,
            seam - 40,
            accuracy: 1,
            "the seam did not travel across with the corner"
        )

        fold.mouseUp(with: try clickEvent(in: fold, at: corner, clicks: 1))
        let released = try XCTUnwrap(split.arrangedSubviews.first).frame.maxX
        split.moveHeldSeam(by: -40)
        XCTAssertEqual(
            try XCTUnwrap(split.arrangedSubviews.first).frame.maxX,
            released,
            accuracy: 0.5,
            "the seam was still being moved after the hand let go of the corner"
        )
    }

    /// The rest of the band is a plain fold, and has to stay one: a press anywhere along it moves
    /// the fold and nothing else, however wide the corner at either end is allowed to be.
    func testAPressAlongTheBandTakesNoSeamWithIt() throws {
        let (split, fold) = cornerFixture()
        install(fold, in: split)
        let seam = try XCTUnwrap(split.arrangedSubviews.first).frame.maxX

        fold.mouseDown(with: try clickEvent(
            in: fold,
            at: NSPoint(x: fold.bounds.midX, y: fold.bounds.midY),
            clicks: 1
        ))

        XCTAssertNil(split.activeDividerIndex, "the band lit a seam no press had attached to")
        split.moveHeldSeam(by: -40)
        XCTAssertEqual(
            try XCTUnwrap(split.arrangedSubviews.first).frame.maxX,
            seam,
            accuracy: 0.5,
            "a press along the band moved the pane beside it"
        )
    }

    /// A corner is where two seams meet, and a fold inset from its pane's edge meets nothing. A
    /// grip there would move a divider the pointer is a dozen points away from.
    func testAFoldInsetFromItsPanesEdgeHasNoCornerToHold() throws {
        let (split, fold) = cornerFixture()
        install(fold, in: split, inset: Design.Spacing.inset)

        XCTAssertNil(fold.cornerRect(on: .leading), "an inset fold offered a corner it has not got")
        XCTAssertNil(fold.cornerRect(on: .trailing))

        fold.mouseDown(with: try clickEvent(
            in: fold,
            at: NSPoint(x: fold.bounds.minX + 2, y: fold.bounds.midY),
            clicks: 1
        ))
        XCTAssertNil(split.activeDividerIndex, "an inset fold took hold of a seam anyway")
    }

    /// A fold in no split view at all — the gallery's own sample, and every fold in a pane that is
    /// not one of a window's — is a fold and nothing more.
    func testAFoldOutsideASplitViewIsJustAFold() throws {
        let fold = PaneFoldDivider()
        fold.frame = NSRect(x: 0, y: 0, width: 120, height: fold.intrinsicContentSize.height)
        _ = hosted(fold)

        XCTAssertNil(fold.cornerSide(at: NSPoint(x: 1, y: fold.bounds.midY)))
        XCTAssertNil(fold.cornerSide(at: NSPoint(x: 119, y: fold.bounds.midY)))
    }

    /// Draws the fold between two halves at rest and under the pointer, light and dark.
    ///
    /// The assertions above pin the seam's ink apart; this is what says whether it reads apart. A
    /// one-point rule with a six-point band under it is exactly the size where "the pointer can
    /// see this is draggable" can be true in an assertion and invisible on screen.
    func testRendersTheFoldAtRestAndUnderThePointer() throws {
        let directory: URL = {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Stated rather than inherited: the palette is global, so a picture of "light and dark"
        // taken after whichever test ran last is a picture of that test's theme.
        AppThemePalette.set(.system)

        let width: CGFloat = 260
        let half: CGFloat = 44

        var written = 0
        for (appearanceName, appearanceID) in [("light", NSAppearance.Name.aqua),
                                               ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceID))
            var data: Data?

            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated {
                    let folds = [PaneFoldDivider(), PaneFoldDivider()]
                    let band = folds[0].intrinsicContentSize.height
                    let host = NSView(frame: NSRect(
                        x: 0,
                        y: 0,
                        width: width,
                        height: (half * 2 + band) * 2 + Design.Spacing.large
                    ))
                    host.appearance = appearance
                    host.applySurface(fill: Design.Surface.background, radius: .fixed(0))

                    for (index, fold) in folds.enumerated() {
                        let block = (half * 2 + band)
                        let bottom = CGFloat(index) * (block + Design.Spacing.large)
                        // One surface on both sides, so the only thing between the halves is the
                        // seam itself — two different fills would read as a boundary whether the
                        // rule drew anything or not.
                        for offset in [bottom, bottom + half + band] {
                            let pane = NSView(frame: NSRect(
                                x: 0, y: offset, width: width, height: half
                            ))
                            pane.applySurface(fill: Design.Surface.panel, radius: .fixed(0))
                            host.addSubview(pane)
                        }
                        fold.frame = NSRect(
                            x: 0, y: bottom + half, width: width, height: band
                        )
                        host.addSubview(fold)
                    }
                    // The upper block is the one under the pointer, so both readings stand in one
                    // picture rather than in two that have to be held side by side.
                    folds[1].mouseEntered(with: NSEvent.enterExitEvent(
                        with: .mouseEntered,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: 0,
                        context: nil,
                        eventNumber: 0,
                        trackingNumber: 0,
                        userData: nil
                    )!)

                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        return
                    }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }
            }

            try XCTUnwrap(data).write(
                to: directory.appendingPathComponent("pane-fold-\(appearanceName).png")
            )
            written += 1
        }

        XCTAssertEqual(written, 2)
        print("Rendered the pane fold to \(directory.path)")
    }

    private func enterEvent(in view: NSView) -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
    }

    /// A press at the fold's own centre. `clickCount` is the one part of a drag a synthesized
    /// event can carry — `deltaY` is not, which is why the travel above is driven through the
    /// keyboard and the pane's own seam.
    private func clickEvent(in view: NSView, clicks: Int) throws -> NSEvent {
        try clickEvent(
            in: view,
            at: NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            clicks: clicks
        )
    }

    /// And a press at a stated point, for the one thing about a fold that depends on *where*
    /// along the band the hand landed: its corners.
    private func clickEvent(in view: NSView, at point: NSPoint, clicks: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1
        ))
    }

    private func arrowEvent(down: Bool, fine: Bool) -> NSEvent {
        let key = String(
            UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!
        )
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: fine ? [.shift] : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: 0
        )!
    }

    // MARK: - Status Progress Ring

    func testStatusProgressRingKeepsEveryCheckSlice() {
        let fractions = ThemedStatusProgressRing.fractions(
            positive: 5,
            pending: 2,
            negative: 1
        )
        XCTAssertEqual(fractions.positive, 5.0 / 8.0, accuracy: 0.001)
        XCTAssertEqual(fractions.pending, 2.0 / 8.0, accuracy: 0.001)
        XCTAssertEqual(fractions.negative, 1.0 / 8.0, accuracy: 0.001)

        let empty = ThemedStatusProgressRing.fractions(positive: 0, pending: 0, negative: 0)
        XCTAssertEqual(empty.positive, 0, accuracy: 0.001)
        XCTAssertEqual(empty.pending, 1, accuracy: 0.001)
        XCTAssertEqual(empty.negative, 0, accuracy: 0.001)
        XCTAssertFalse(
            ThemedStatusProgressRing.image(positive: 5, pending: 2, negative: 1).isTemplate,
            "semantic slices must retain their own colours inside a tinted button"
        )
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
        indicator.update(for: .working)

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
        XCTAssertFalse(
            indicator.subviews.contains { $0 is ThemedSpinner },
            "an idle status eagerly built its invisible working state"
        )

        indicator.update(for: .dormant, isLoading: true)
        let spinner = try XCTUnwrap(
            indicator.subviews.compactMap { $0 as? ThemedSpinner }.first
        )
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
            descendants(of: card)
                .compactMap { $0 as? ThemedButton }
                .first { !$0.isHiddenOrHasHiddenAncestor }
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
            ("children", { $0.updateSubagents(workingCount: 0, doneCount: 9) }),
            ("workspace", { [self] in
                $0.updateWorkspace(.init(workspace: managedWorkspace(state: .active)))
            })
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

    // MARK: - The Card's Isolated Worktree

    /// One managed workspace record, with only the fields this row reads varied.
    private func managedWorkspace(
        state: ManagedWorkspaceState,
        delivery: ManagedWorkspaceDelivery = .mergeAndCleanUp,
        publication: ManagedWorkspacePublication? = nil,
        changeRequest: ManagedWorkspaceChangeRequest? = nil,
        lastError: String? = nil
    ) -> ManagedWorkspace {
        ManagedWorkspace(
            repositoryRoot: "/tmp/source",
            sourceCheckoutPath: "/tmp/source",
            worktreeRoot: "/tmp/managed/session",
            executionPath: "/tmp/managed/session",
            targetBranch: "master",
            baseCommit: "0000000",
            delivery: delivery,
            publication: publication,
            remoteBranch: nil,
            finalCommit: nil,
            changeRequest: changeRequest,
            remoteBranchState: nil,
            state: state,
            lastError: lastError
        )
    }

    /// A managed session works in a directory nobody opened, under a name nobody chose, and this
    /// card said nothing about it: `HEAD` is detached in a managed worktree, so the branch row
    /// cannot appear at all and the card opened on its counters.
    ///
    /// The row states both halves, because the state alone leaves the question it exists to
    /// answer. Where the commits end up was decided once, in a composer closed an hour ago, and
    /// the person now watching an agent commit into a checkout they cannot see is the one who
    /// needs it back.
    func testTheCardSaysWhatTheIsolatedWorktreeIsAndWhereItsWorkLands() {
        let card = GitStatusOverlayView()
        card.applyInk(WindowBackdrop.ink)

        XCTAssertTrue(card.isHidden, "an ordinary session has no workspace row to show")

        let cases: [(ManagedWorkspace, String)] = [
            (
                managedWorkspace(state: .active),
                "Isolated worktree · merges into master"
            ),
            (
                managedWorkspace(state: .active, delivery: .keepForReview),
                "Isolated worktree · stays for review"
            ),
            (
                // Publication outranks delivery while the session is running, because the finish
                // handshake takes them in that order: a published workspace never reaches the
                // local merge path at all.
                managedWorkspace(state: .active, publication: .draft),
                "Isolated worktree · opens a draft change request"
            ),
            (
                managedWorkspace(state: .active, publication: .ready),
                "Isolated worktree · opens a change request"
            ),
            (
                managedWorkspace(state: .integrated),
                "Merged into master · worktree removed"
            ),
            (
                managedWorkspace(state: .kept, delivery: .keepForReview),
                "Worktree kept · not merged into master"
            ),
            (
                managedWorkspace(
                    state: .published,
                    publication: .draft,
                    changeRequest: ManagedWorkspaceChangeRequest(
                        provider: "github",
                        repository: "everlof/threading",
                        remote: "origin",
                        branch: "threading/session",
                        number: 42,
                        url: URL(fileURLWithPath: "/tmp/review"),
                        isDraft: true
                    )
                ),
                "Published as #42 · worktree removed"
            ),
            (
                managedWorkspace(
                    state: .needsAttention,
                    lastError: "The managed checkout has uncommitted changes."
                ),
                // Passed through rather than reworded: the toast carrying this was gone seconds
                // after the finish was refused, and this row is what is left saying what to fix.
                "Needs attention · The managed checkout has uncommitted changes."
            )
        ]

        for (workspace, expected) in cases {
            card.updateWorkspace(.init(workspace: workspace))
            XCTAssertFalse(card.isHidden, "an isolated checkout is worth the card on its own")
            XCTAssertEqual(card.accessibilityLabel(), expected)
            // A card capped at 360 points cannot draw a refusal's reason in full, so the row that
            // truncates carries the whole sentence for the pointer.
            let rows = descendants(of: card).compactMap { $0 as? NSStackView }
            XCTAssertTrue(
                rows.contains { $0.toolTip == expected },
                "the workspace row's hover does not carry \(expected)"
            )
        }

        card.updateWorkspace(nil)
        XCTAssertTrue(card.isHidden, "the row outlived the workspace it was describing")
    }

    /// The row leads the card, and keeps leading it once the other rows arrive.
    ///
    /// Order is the argument: it names the *checkout* every row under it is about. It is also the
    /// row that has to survive a card whose branch line is structurally absent, which is every
    /// managed session — so it is asserted against a reading with no branch, exactly as one
    /// arrives from a detached head.
    func testTheIsolatedWorktreeRowLeadsTheCard() throws {
        let card = GitStatusOverlayView()
        card.updateWorkspace(.init(workspace: managedWorkspace(state: .active)))
        card.update(with: GitChangeMonitor.Reading(
            branch: nil,
            summary: GitChangeSummary(files: 2, added: 35, removed: 1)
        ))
        card.updateModel(GitStatusOverlayView.ModelReading(name: "Opus 5"))
        card.applyInk(WindowBackdrop.ink)
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        card.layoutSubtreeIfNeeded()

        let rows = descendants(of: card)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .sorted { card.convert($0.bounds, from: $0).maxY > card.convert($1.bounds, from: $1).maxY }
            .map(\.stringValue)
        XCTAssertEqual(
            rows.first,
            "Isolated worktree · merges into master",
            "the card led with \(rows.first ?? "nothing") rather than the checkout it runs in"
        )

        // Spoken in the same order the rows are stacked, the workspace first.
        XCTAssertEqual(
            card.accessibilityLabel(),
            "Isolated worktree · merges into master  ·  2 files +35 −1  ·  Opus 5"
        )

        // The mark shares the one column every other row's mark is in.
        let marks = descendants(of: card)
            .compactMap { $0 as? ThemedFloatingGlyphView }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(
            Set(marks.compactMap(\.semanticDescription)),
            ["Isolated worktree", "Changes", "Model"]
        )
        let columns = marks.map { card.convert($0.bounds, from: $0).minX }
        for column in columns {
            XCTAssertEqual(column, columns[0], accuracy: 0.5,
                           "a row's mark sits outside the column the others share: \(columns)")
        }

        // A theme change rebuilds every row from the readings the card is holding. The workspace
        // row is one of those readings and must come back with the rest.
        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        card.applyInk(WindowBackdrop.ink)
        card.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            descendants(of: card).compactMap { ($0 as? NSTextField)?.stringValue }.contains(
                "Isolated worktree · merges into master"
            ),
            "the workspace row did not survive a theme change"
        )
    }

    /// The row's two halves are weighted like the agent line's: what the workspace *is* leads in
    /// the ink the branch row uses, and what happens to it follows one tier quieter. A refused
    /// finish is the exception — it takes the loudest role the card has, because it is the one
    /// state here that is not simply how things are going.
    func testARefusedFinishIsTheLoudestThingOnTheCard() throws {
        let card = GitStatusOverlayView()
        card.applyInk(WindowBackdrop.ink)

        func leadingColour() throws -> NSColor {
            let label = try XCTUnwrap(
                descendants(of: card)
                    .compactMap { $0 as? NSTextField }
                    .first { !$0.isHiddenOrHasHiddenAncestor }
            )
            return try XCTUnwrap(
                label.attributedStringValue
                    .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            )
        }

        card.updateWorkspace(.init(workspace: managedWorkspace(state: .active)))
        let running = try leadingColour()

        card.updateWorkspace(.init(
            workspace: managedWorkspace(state: .needsAttention, lastError: "Refused")
        ))
        let refused = try leadingColour()

        // The card resolves its own floating chrome rather than taking the backdrop's ink: it is
        // an opaque app-owned surface over whatever the terminal is painting.
        XCTAssertNotEqual(running, refused, "a refused finish reads exactly like an ordinary one")
        XCTAssertEqual(refused, Design.Ink.chrome.label)
        XCTAssertEqual(running, Design.Ink.chrome.secondary)
    }

    /// The picture, because this row's whole purpose is to be read at a glance over live terminal
    /// text — and because the states differ by a sentence rather than by a shape, which is
    /// exactly the kind of difference an assertion can pass while the card reads as a wall.
    func testRendersTheIsolatedWorktreeCard() throws {
        let directory: URL = {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let states: [ManagedWorkspace] = [
            managedWorkspace(state: .active),
            managedWorkspace(state: .active, publication: .draft),
            managedWorkspace(state: .integrated),
            managedWorkspace(
                state: .needsAttention,
                lastError: "The managed checkout has uncommitted changes."
            )
        ]

        var written = 0
        // The third pass is a period theme, because the mark this row introduced has to be drawn
        // twice: SF Symbols for modern chrome, and a one-bit box for the themes that select the
        // classic glyph family. Only the second is hand-drawn, so only the second can be wrong in
        // a way no assertion is watching.
        for (appearanceName, appearanceID, theme) in [
            ("light", NSAppearance.Name.aqua, AppTheme.system),
            ("dark", NSAppearance.Name.darkAqua, AppTheme.system),
            ("classic", NSAppearance.Name.aqua, AppThemeStyles.win98)
        ] {
            AppThemePalette.set(theme)
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceID))
            var data: Data?

            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated {
                    let inset = Design.Spacing.medium
                    let host = NSView(frame: .zero)
                    host.appearance = appearance
                    host.applySurface(fill: Design.Surface.background, radius: .fixed(0))

                    var y = inset
                    var width: CGFloat = 0
                    for workspace in states.reversed() {
                        let card = GitStatusOverlayView()
                        card.updateWorkspace(.init(workspace: workspace))
                        // The rows a managed session actually shows beside it: no branch, because
                        // its head is detached, and the agent line its terminal does not carry.
                        card.update(with: GitChangeMonitor.Reading(
                            branch: nil,
                            summary: GitChangeSummary(files: 3, added: 128, removed: 12)
                        ))
                        card.updateModel(.init(name: "Opus 5", effort: "Extra High"))
                        card.applyInk(WindowBackdrop.ink)
                        let size = card.fittingSize
                        card.frame = NSRect(x: inset, y: y, width: size.width, height: size.height)
                        host.addSubview(card)
                        y += size.height + inset
                        width = max(width, size.width)
                    }
                    host.frame = NSRect(x: 0, y: 0, width: width + inset * 2, height: y)

                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        return
                    }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }
            }

            try XCTUnwrap(data).write(
                to: directory.appendingPathComponent("managed-worktree-card-\(appearanceName).png")
            )
            written += 1
        }

        XCTAssertEqual(written, 3)
        print("Rendered the isolated worktree card to \(directory.path)")
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
        // Workspace, branch, changes, model, speed — the card's whole semantic set, held whether
        // or not the reading it was given draws each one.
        XCTAssertEqual(
            descendants(of: card).compactMap { $0 as? ThemedFloatingGlyphView }.count,
            5,
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

        // The card stacks one fact per row, so the pair being measured is the top *drawn* row's —
        // the counters are a line of their own below it, and the rows this reading has nothing to
        // say for (the isolated-worktree line above) are in the stack but hidden.
        let content = try XCTUnwrap(card.subviews.compactMap { $0 as? NSStackView }.first)
        let summary = try XCTUnwrap(
            content.arrangedSubviews.compactMap { $0 as? NSStackView }.first { !$0.isHidden }
        )
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

    /// The review image for the menu-like card itself: remote review, bounded sources, a full
    /// row hover, section rules, and an extension-authored disclosure all share the real host.
    func testRendersStatusCardEnvironmentMenu() throws {
        let directory: URL = {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sessionID = SessionID()
        let publicSessionID = sessionID.uuidString.lowercased()
        let registry = ComponentCustomizationRegistry()
        try registry.register(HostComponentContracts.sessionCornerCard)
        try registry.replacePatches([
            .init(
                id: "issue-reading",
                target: .sessionCornerCard(sessionID: publicSessionID),
                slots: [
                    .init(
                        slot: "top-trailing",
                        children: [
                            .disclosure(
                                id: "issue-details",
                                summary: .stack(
                                    axis: .horizontal,
                                    spacing: .small,
                                    children: [
                                        .image(
                                            .systemSymbol("ticket"),
                                            role: .icon,
                                            accessibilityLabel: "Linear issue"
                                        ),
                                        .text("Linear · FES-12159", role: .compactBody),
                                        .flexibleSpacer,
                                        .status("In progress", role: .warning)
                                    ]
                                ),
                                detail: [
                                    .text("Fix attachment status menu", role: .compactBody),
                                    .divider,
                                    .text("Assigned to David", role: .compactDetail),
                                    .button(
                                        id: "open-issue",
                                        title: "Open in Linear",
                                        role: .standard,
                                        isEnabled: true
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
        ], from: .init(
            extensionIdentifier: "com.example.linear",
            processGeneration: "environment-evidence",
            order: 0
        ))

        let checks = ChangeRequestChecks(state: .pending, passed: 5, pending: 2, failed: 0)
        let repository = ChangeRequestRepository(
            provider: .github,
            host: "github.com",
            namespace: "threading",
            name: "app"
        )
        let request = ChangeRequestSummary(
            number: 482,
            title: "Polish the status card",
            body: "",
            url: URL(string: "https://github.com/threading/app/pull/482")!,
            isDraft: false,
            isMerged: false,
            baseBranch: "main",
            headBranch: "dev/fix/FES-12159",
            headRevision: "abc123",
            checks: checks,
            reviews: .empty
        )
        let review = ChangeRequestRepositoryStatus(
            repository: repository,
            defaultBranch: "main",
            branch: request.headBranch,
            changeRequest: request,
            checks: checks
        )
        let root = URL(fileURLWithPath: "/tmp/environment-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeAttachmentPreviewFixture(
            to: root.appendingPathComponent("hover-reference.png")
        )
        let attachments = [
            ("build-log.txt", SessionAttachment.Kind.document),
            ("design-notes.pdf", .pdf),
            ("checks.png", .image),
            ("hover-reference.png", .image),
            ("environment-card.png", .image)
        ].enumerated().map { index, value in
            SessionAttachment(
                sessionID: sessionID,
                id: "evidence-\(index)",
                root: root,
                url: root.appendingPathComponent(value.0),
                relativePath: value.0,
                sourcePath: value.0,
                kind: value.1,
                origin: .agent,
                referencedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        AppThemePalette.set(.system)
        for (name, appearanceName) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", NSAppearance.Name.darkAqua)
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var data: Data?
            var hoverData: Data?
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated {
                    let host = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 470))
                    host.appearance = appearance
                    host.applySurface(fill: Design.Surface.background, radius: .fixed(0))

                    let terminalLines = [
                        "$ git status --short",
                        " M Sources/Threading/UI/Views/GitStatusOverlayView.swift",
                        "$ swift test --filter StatusCard",
                        "Building for debugging…",
                        "Test Suite 'StatusCard' passed"
                    ]
                    for (index, text) in terminalLines.enumerated() {
                        let label = NSTextField(labelWithString: text)
                        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                        label.textColor = Design.Ink.chrome.tertiary
                        label.frame = NSRect(
                            x: Design.Spacing.pane,
                            y: host.bounds.height - 70 - CGFloat(index) * 25,
                            width: 560,
                            height: 18
                        )
                        host.addSubview(label)
                    }

                    let card = GitStatusOverlayView(
                        customizationLookup: registry.customization(for:)
                    )
                    card.showSession(publicSessionID)
                    card.update(with: .init(
                        branch: request.headBranch,
                        summary: GitChangeSummary(files: 12, added: 247, removed: 39)
                    ))
                    card.updateModel(.init(
                        name: "Opus · 1M",
                        mode: "Auto",
                        effort: "Extra High"
                    ))
                    card.updateChangeRequest(GitStatusOverlayView.ChangeRequestReading(status: review))
                    card.updateSubagents(workingCount: 0, doneCount: 1)
                    card.updateAttachments(.init(attachments: attachments))
                    card.applyInk(WindowBackdrop.ink)

                    let size = card.fittingSize
                    card.frame = NSRect(
                        x: host.bounds.width - size.width - Design.Spacing.pane,
                        y: host.bounds.height - size.height - Design.Spacing.pane,
                        width: size.width,
                        height: size.height
                    )
                    host.addSubview(card)
                    host.layoutSubtreeIfNeeded()

                    // Keep one entire attachment cell lit in the evidence; the title occupies
                    // only part of it, while the hover surface proves the target does not.
                    descendants(of: card)
                        .compactMap { $0 as? ThemedButton }
                        .first { $0.title == "hover-reference.png" }?
                        .mouseEntered(with: NSEvent())
                    host.displayIfNeeded()

                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        return
                    }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])

                    // The interaction evidence uses the same card and row, then mounts the
                    // hover body inside the production popover chrome. This keeps the picture
                    // deterministic without ordering a child window on the test runner's screen.
                    host.setFrameSize(NSSize(width: 980, height: 470))
                    card.frame.origin.x = host.bounds.width - card.bounds.width
                        - Design.Spacing.pane
                    host.layoutSubtreeIfNeeded()

                    guard let previewController = card.makeAttachmentPreviewSurface(
                        forAttachmentAt: 1
                    ) else { return }
                    previewController.loadView()
                    previewController.view.layoutSubtreeIfNeeded()
                    let previewSize = previewController.view.fittingSize
                    guard let button = self.descendants(of: card)
                        .compactMap({ $0 as? ThemedButton })
                        .first(where: { $0.title == "hover-reference.png" })
                    else { return }
                    let anchor = button.convert(button.bounds, to: host)
                    let material = AppThemePalette.current.material(for: appearance)
                    let placement = ThemedPopoverLayout.place(
                        anchor: anchor,
                        contentSize: previewSize,
                        visibleFrame: host.bounds,
                        preferredEdge: .maxX,
                        style: material.popoverStyle,
                        hasMaterialShadow: material.glow != nil,
                        bevelWidth: material.bevel?.width
                    )
                    let chrome = ThemedPopoverChromeView(
                        frame: placement.panelFrame
                    )
                    chrome.appearance = appearance
                    chrome.placement = placement
                    chrome.contentView = previewController.view
                    host.addSubview(chrome)
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()

                    guard let hoverRep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
                    else { return }
                    host.cacheDisplay(in: host.bounds, to: hoverRep)
                    hoverData = hoverRep.representation(using: .png, properties: [:])
                }
            }
            try XCTUnwrap(data).write(
                to: directory.appendingPathComponent("status-card-environment-\(name).png")
            )
            try XCTUnwrap(hoverData).write(
                to: directory.appendingPathComponent(
                    "status-card-attachment-hover-\(name).png"
                )
            )
        }

        print("Rendered the environment status card to \(directory.path)")
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
        XCTAssertTrue(GitStatusOverlayDefaults.hasRoomBesideConversation(
            forCardWidth: 200,
            inPaneWidth: 0
        ))
    }

    /// Conversation content is capped and centred, so the relevant room is its trailing gutter,
    /// not an arbitrary share of the pane. Opening the display panel can leave a card under half
    /// the pane while removing the gutter entirely.
    func testConversationCardWithdrawsBeforeItCanCoverTheReadableColumn() {
        XCTAssertTrue(GitStatusOverlayDefaults.hasRoomBesideConversation(
            forCardWidth: 120,
            inPaneWidth: 1_000
        ))
        XCTAssertFalse(GitStatusOverlayDefaults.hasRoomBesideConversation(
            forCardWidth: 120,
            inPaneWidth: 760
        ), "the card fit the pane but covered the conversation column")
        XCTAssertFalse(GitStatusOverlayDefaults.hasRoomBesideConversation(
            forCardWidth: 40,
            inPaneWidth: 620
        ), "a narrow conversation has no floating-card gutter")
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

    func testStatusCardShowsConnectedReviewAndRoutesBothRowsToGitReview() throws {
        let checks = ChangeRequestChecks(
            state: .pending,
            passed: 4,
            pending: 2,
            failed: 0
        )
        let repository = ChangeRequestRepository(
            provider: .github,
            host: "github.com",
            namespace: "threading",
            name: "app"
        )
        let request = ChangeRequestSummary(
            number: 482,
            title: "Make the environment card useful",
            body: "",
            url: URL(string: "https://github.com/threading/app/pull/482")!,
            isDraft: false,
            isMerged: false,
            baseBranch: "main",
            headBranch: "feature/environment-card",
            headRevision: "abc123",
            checks: checks,
            reviews: .empty
        )
        let status = ChangeRequestRepositoryStatus(
            repository: repository,
            defaultBranch: "main",
            branch: request.headBranch,
            changeRequest: request,
            checks: checks
        )

        let card = GitStatusOverlayView()
        card.update(with: .init(branch: request.headBranch, summary: .clean))
        card.updateChangeRequest(try XCTUnwrap(.init(status: status)))
        card.applyInk(WindowBackdrop.ink)
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        card.layoutSubtreeIfNeeded()

        let buttons = descendants(of: card)
            .compactMap { $0 as? ThemedButton }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(buttons.map(\.title), [
            "#482 · Make the environment card useful",
            "4 passed · 2 pending"
        ])
        XCTAssertTrue(buttons.allSatisfy {
            $0.frame.width >= GitStatusOverlayDefaults.minWidth - 2 * Design.Spacing.medium
        }, "review hover targets should fill the card's menu-like column")

        var opens = 0
        card.onOpen = { opens += 1 }
        buttons.forEach { $0.performClick() }
        XCTAssertEqual(opens, 2)
    }

    func testStatusCardBoundsAttachmentRowsAndOpensTheAttachmentsPane() throws {
        let sessionID = SessionID()
        let root = URL(fileURLWithPath: "/tmp/status-card-attachments", isDirectory: true)
        let names = ["old.txt", "notes.pdf", "trace.zip", "diagram.svg", "latest.png"]
        let attachments = names.enumerated().map { index, name in
            SessionAttachment(
                sessionID: sessionID,
                id: "attachment-\(index)",
                root: root,
                url: root.appendingPathComponent(name),
                relativePath: name,
                sourcePath: name,
                kind: index == names.count - 1 ? .image : .document,
                origin: .agent,
                referencedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let card = GitStatusOverlayView()
        card.update(with: .init(branch: "feature/environment-card", summary: .clean))
        card.updateAttachments(.init(attachments: attachments))
        card.applyInk(WindowBackdrop.ink)
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        card.layoutSubtreeIfNeeded()

        let buttons = descendants(of: card)
            .compactMap { $0 as? ThemedButton }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(buttons.map(\.title), [
            "latest.png",
            "diagram.svg",
            "trace.zip",
            "View all 5 attachments"
        ], "the card mounts three recent rows and one fixed route to the full chronology")
        let expectedCellWidth = card.bounds.width - 2 * Design.Spacing.medium
        XCTAssertTrue(buttons.allSatisfy {
            abs($0.frame.width - expectedCellWidth) < 0.5
        }, "every attachment hover target covers the whole cell")
        XCTAssertTrue(buttons.allSatisfy { !$0.showsSubmenuIndicator },
                      "a hover preview must not masquerade as a click-to-disclose submenu")

        var opened: [String?] = []
        card.onOpenAttachment = { opened.append($0) }
        buttons.first?.performClick()
        buttons.last?.performClick()
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(opened[0], "attachment-4")
        XCTAssertNil(opened[1])
    }

    func testAttachmentHoverPreviewIsLazyBoundedAndCarriesFileActions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preview.png")
        try writeAttachmentPreviewFixture(to: url)

        let card = GitStatusOverlayView()
        card.updateAttachments(.init(attachments: [SessionAttachment(
            sessionID: SessionID(),
            id: "preview",
            root: directory,
            url: url,
            relativePath: url.lastPathComponent,
            sourcePath: url.path,
            kind: .image,
            origin: .agent,
            referencedAt: Date()
        )]))
        XCTAssertEqual(card.attachmentPreviewBuildCountForTesting, 0,
                       "mounting the status card decoded hover-only content")

        let controller = try XCTUnwrap(card.makeAttachmentPreviewSurface(forAttachmentAt: 0))
        controller.loadView()
        controller.view.frame = NSRect(origin: .zero, size: controller.view.fittingSize)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(card.attachmentPreviewBuildCountForTesting, 1)
        let image = try XCTUnwrap(
            descendants(of: controller.view).compactMap { $0 as? ThemedImagePreview }.first
        )
        XCTAssertLessThanOrEqual(
            max(image.image?.size.width ?? .infinity, image.image?.size.height ?? .infinity),
            CGFloat(GitStatusOverlayDefaults.attachmentThumbnailMaximumPixels),
            "the hover surface decoded the full image instead of its thumbnail"
        )
        let actions = descendants(of: controller.view)
            .compactMap { $0 as? ThemedButton }
            .map(\.title)
        XCTAssertEqual(actions, [
            "Copy Image",
            "Copy Path",
            "Open in Attachments",
            "Reveal in Finder"
        ])
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

    /// A deterministic screenshot-like image for the attachment hover evidence. Generated in
    /// the test rather than checked in as opaque binary data, so the fixture's source stays
    /// reviewable beside the UI it exercises.
    private func writeAttachmentPreviewFixture(to url: URL) throws {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(
            calibratedRed: 0.055,
            green: 0.067,
            blue: 0.085,
            alpha: 1
        ).cgColor

        let sidebar = NSView(frame: NSRect(x: 28, y: 28, width: 220, height: 484))
        sidebar.wantsLayer = true
        sidebar.layer?.cornerRadius = 18
        sidebar.layer?.backgroundColor = NSColor(
            calibratedRed: 0.10,
            green: 0.12,
            blue: 0.15,
            alpha: 1
        ).cgColor
        canvas.addSubview(sidebar)

        for (index, width) in [144, 174, 126, 160, 112].enumerated() {
            let line = NSView(frame: NSRect(
                x: 54,
                y: 440 - CGFloat(index) * 58,
                width: CGFloat(width),
                height: 14
            ))
            line.wantsLayer = true
            line.layer?.cornerRadius = 7
            line.layer?.backgroundColor = NSColor(
                calibratedWhite: index == 1 ? 0.78 : 0.34,
                alpha: 1
            ).cgColor
            canvas.addSubview(line)
        }

        let content = NSView(frame: NSRect(x: 278, y: 28, width: 654, height: 484))
        content.wantsLayer = true
        content.layer?.cornerRadius = 18
        content.layer?.backgroundColor = NSColor(
            calibratedRed: 0.075,
            green: 0.09,
            blue: 0.115,
            alpha: 1
        ).cgColor
        canvas.addSubview(content)

        let title = NSTextField(labelWithString: "Attachment status menu")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 322, y: 424, width: 480, height: 42)
        canvas.addSubview(title)

        let card = NSView(frame: NSRect(x: 322, y: 206, width: 530, height: 172))
        card.wantsLayer = true
        card.layer?.cornerRadius = 15
        card.layer?.backgroundColor = NSColor(
            calibratedRed: 0.12,
            green: 0.145,
            blue: 0.18,
            alpha: 1
        ).cgColor
        canvas.addSubview(card)

        for (index, color) in [NSColor.systemGreen, .systemYellow, .systemBlue].enumerated() {
            let pill = NSView(frame: NSRect(
                x: 350 + CGFloat(index) * 154,
                y: 300,
                width: 130,
                height: 28
            ))
            pill.wantsLayer = true
            pill.layer?.cornerRadius = 14
            pill.layer?.backgroundColor = color.withAlphaComponent(0.72).cgColor
            canvas.addSubview(pill)
        }

        for (index, width) in [438, 372, 410].enumerated() {
            let line = NSView(frame: NSRect(
                x: 350,
                y: 258 - CGFloat(index) * 34,
                width: CGFloat(width),
                height: 11
            ))
            line.wantsLayer = true
            line.layer?.cornerRadius = 5.5
            line.layer?.backgroundColor = NSColor(
                calibratedWhite: index == 0 ? 0.78 : 0.45,
                alpha: 1
            ).cgColor
            canvas.addSubview(line)
        }

        canvas.displayIfNeeded()
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
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
