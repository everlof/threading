import AppKit
import CoreGraphics
import XCTest
@testable import Threading

/// The themed controls that replace stock AppKit, so a styled app is themed all the way down
/// rather than themed cards around system-blue switches.
@MainActor
final class ThemedControlTests: XCTestCase {

    override func tearDown() {
        Design.Accessibility.increaseContrastOverrideForTesting = nil
        Design.Accessibility.differentiateWithoutColorOverrideForTesting = nil
        Design.Motion.reduceMotionOverrideForTesting = nil
        AppThemeLibrary.apply(.system)
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Drop-in Behaviour

    /// `ThemedToggle` replaces `NSSwitch` at call sites that read `.state == .on` and fire an
    /// action, so it has to behave like one: a click flips the state and sends the action.
    func testAToggleFlipsAndFiresLikeASwitch() {
        let toggle = ThemedToggle()
        toggle.state = .off

        let target = ActionSpy()
        toggle.target = target
        toggle.action = #selector(ActionSpy.fire)

        toggle.mouseDown(with: .init())

        XCTAssertEqual(toggle.state, .on, "a click did not flip the state")
        XCTAssertEqual(target.count, 1, "the action did not fire")

        toggle.mouseDown(with: .init())
        XCTAssertEqual(toggle.state, .off)
        XCTAssertEqual(target.count, 2)
    }

    func testADisabledToggleIgnoresClicks() {
        let toggle = ThemedToggle()
        toggle.isEnabled = false
        toggle.state = .off

        toggle.mouseDown(with: .init())

        XCTAssertEqual(toggle.state, .off, "a disabled toggle changed state")
    }

    func testToggleCanBeReachedAndActivatedWithoutAPointer() throws {
        let toggle = ThemedToggle()
        let target = ActionSpy()
        toggle.target = target
        toggle.action = #selector(ActionSpy.fire)

        XCTAssertTrue(toggle.acceptsFirstResponder)
        XCTAssertTrue(toggle.isAccessibilityEnabled())

        toggle.keyDown(with: try keyEvent(" ", keyCode: 49))

        XCTAssertEqual(toggle.state, .on)
        XCTAssertEqual(target.count, 1)

        toggle.isEnabled = false
        XCTAssertFalse(toggle.acceptsFirstResponder)
        XCTAssertFalse(toggle.isAccessibilityEnabled())
    }

    func testDifferentiateWithoutColorAddsAVisibleOnStateMark() throws {
        let toggle = ThemedToggle(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
        toggle.state = .on

        Design.Accessibility.differentiateWithoutColorOverrideForTesting = false
        let colorOnly = try renderedPNG(of: toggle)

        Design.Accessibility.differentiateWithoutColorOverrideForTesting = true
        let differentiated = try renderedPNG(of: toggle)

        XCTAssertNotEqual(colorOnly, differentiated, "the on state remained colour-only")
    }

    func testTheHelperBuildsAThemedToggleNotAnNSSwitch() {
        let spy = ActionSpy()
        let control: ThemedControl = SettingsUI.toggle(
            isOn: true,
            target: spy,
            action: #selector(ActionSpy.fire)
        )
        XCTAssertTrue(control is ThemedToggle, "SettingsUI.toggle still hands back a raw switch")
        XCTAssertEqual((control as? ThemedToggle)?.state, .on)
    }

    // MARK: - Toggle Motion

    /// The flip animates behind an interaction while the *state* still lands synchronously —
    /// the drop-in contract above — and a programmatic assignment does not animate at all, so
    /// a settings page configuring itself never sweeps the switches it builds.
    func testAClickAnimatesTheKnobWhereAConfiguredStateLandsAtOnce() {
        Design.Motion.reduceMotionOverrideForTesting = false
        let toggle = ThemedToggle(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
        let window = NSWindow(
            contentRect: toggle.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = toggle
        defer { window.orderOut(nil) }

        toggle.mouseDown(with: .init())
        XCTAssertEqual(toggle.state, .on, "the state waited for the animation")
        XCTAssertLessThan(toggle.knobProgress, 1, "the knob teleported to its end")

        toggle.advanceAnimation(now: CACurrentMediaTime() + 1)
        XCTAssertEqual(toggle.knobProgress, 1, "the animation never landed")

        toggle.state = .off
        XCTAssertEqual(toggle.knobProgress, 0, "a programmatic state change animated")
    }

    /// Reduce Motion zeroes the travel through `Design.Motion`: one path, one final state, no
    /// separate accessibility branch for callers to remember.
    func testReduceMotionLandsTheKnobInOneFrame() {
        Design.Motion.reduceMotionOverrideForTesting = true
        let toggle = ThemedToggle(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
        let window = NSWindow(
            contentRect: toggle.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = toggle
        defer { window.orderOut(nil) }

        toggle.mouseDown(with: .init())
        XCTAssertEqual(toggle.knobProgress, 1, "Reduce Motion still animated the knob")
    }

    /// The curves' endpoints are exact — the knob leaves from and lands at its resting
    /// geometry — and the settle-plus-swell worst case stays inside the track. Overshoot and
    /// swell both spend the knob inset and peak near each other, so the compound bound is the
    /// one a retuned constant would silently break.
    func testTheKnobCurveLandsExactlyAndNeverLeavesTheTrack() {
        XCTAssertEqual(ThemedToggle.Motion.position(at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(ThemedToggle.Motion.position(at: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(ThemedToggle.Motion.knobScale(at: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(ThemedToggle.Motion.knobScale(at: 1), 1, accuracy: 0.0001)

        let knobDiameter = ThemedToggle.Layout.height - ThemedToggle.Layout.knobInset * 2
        let travel = ThemedToggle.Layout.width - knobDiameter - ThemedToggle.Layout.knobInset * 2
        for step in 0...100 {
            let phase = CGFloat(step) / 100
            let grow = knobDiameter * (ThemedToggle.Motion.knobScale(at: phase) - 1) / 2
            let pastEnd = travel * (ThemedToggle.Motion.position(at: phase) - 1) + grow
            XCTAssertLessThanOrEqual(
                pastEnd, ThemedToggle.Layout.knobInset,
                "the knob leaves the track at phase \(phase)"
            )
            XCTAssertLessThanOrEqual(
                grow, ThemedToggle.Layout.knobInset,
                "the swell leaves the track at phase \(phase)"
            )
        }
    }

    // MARK: - Toggle Geometry

    /// The knob's corner is derived from the track's rather than stated, so the accent gutter
    /// between them is the same width on the flats as across the diagonals.
    ///
    /// Holding a radius of its own left `knobInset √2` at the corners against `knobInset` on the
    /// flats — a wedge of track surviving at each knob corner. Invisible inside a full-width
    /// gutter, and the whole of what was left of it once a focus ring was drawn *in* that gutter:
    /// four accent specks around a knob that otherwise looked flush.
    func testTheKnobsCornerIsConcentricWithTheTracks() {
        let inset = ThemedToggle.Layout.knobInset
        let knobDiameter = ThemedToggle.Layout.height - inset * 2

        // A hard-cornered theme's 2pt track over a 2pt inset leaves a knob with no corner at all,
        // which is what a uniform gutter costs — and what Bauhaus, Newsprint and Neo Brutalism
        // want anyway.
        XCTAssertEqual(
            ThemedToggle.Layout.knobRadius(trackRadius: ThemedToggle.Layout.squareKnobRadius),
            0, accuracy: 0.0001
        )

        // The rounded themes are unchanged: a stadium track still holds a disc, and still holds
        // one all the way through the swell.
        let stadium = ThemedToggle.Layout.height / 2
        for step in 0...100 {
            let phase = CGFloat(step) / 100
            let grow = knobDiameter * (ThemedToggle.Motion.knobScale(at: phase) - 1) / 2
            XCTAssertEqual(
                ThemedToggle.Layout.knobRadius(trackRadius: stadium, grownBy: grow),
                (knobDiameter + grow * 2) / 2,
                accuracy: 0.0001,
                "the knob stopped being a disc at phase \(phase)"
            )
        }
    }

    /// The switch reserves its own focus-ring margin, because drawing is clipped to `bounds` and
    /// this is the one control with no slack inside its silhouette to lend a ring: the knob is
    /// inset by exactly the ring's width.
    func testTheSwitchReservesRoomOutsideTheTrackForItsFocusRing() {
        let size = ThemedToggle().intrinsicContentSize
        let horizontal = (size.width - ThemedToggle.Layout.width) / 2
        let vertical = (size.height - ThemedToggle.Layout.height) / 2

        XCTAssertEqual(horizontal, vertical, accuracy: 0.0001, "the margin is not square")
        XCTAssertEqual(
            vertical,
            ThemedToggle.Layout.focusGap + Design.Accessibility.focusRingWidth,
            accuracy: 0.0001,
            "the ring is drawn into room the switch never asked for, so the clip takes it"
        )
    }

    // MARK: - Theming

    /// The whole point: the on-track is the theme's accent, not the system's. Sampled from the
    /// drawn control rather than asserted by hex — exact bytes drift with anti-aliasing, but the
    /// *hue* is unmistakable: Cyberpunk's green-dominant accent draws a green track, Swiss's
    /// red-dominant one draws a red track, and a stock `NSSwitch` would draw the same system
    /// blue under both.
    func testTheOnTrackTakesTheThemeAccent() {
        func trackColour(under theme: AppTheme) -> NSColor {
            AppThemePalette.set(theme)
            let toggle = ThemedToggle(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
            toggle.state = .on

            let rep = toggle.bitmapImageRepForCachingDisplay(in: toggle.bounds)!
            toggle.cacheDisplay(in: toggle.bounds, to: rep)
            // Well inside the track on the left, clear of the knob and the rounded edges.
            return rep.colorAt(x: 8, y: 11)!.usingColorSpace(.sRGB)!
        }

        let cyber = trackColour(under: AppThemeStyles.cyberpunk)
        let swiss = trackColour(under: AppThemeStyles.swissMinimalist)

        XCTAssertGreaterThan(cyber.greenComponent, cyber.redComponent,
                             "Cyberpunk's track is not green")
        XCTAssertGreaterThan(swiss.redComponent, swiss.greenComponent,
                             "Swiss's track is not red")
    }

    // MARK: - Segmented Control

    private func makeSegmentedControl(
        selectedIndex: Int = 0
    ) -> (ThemedSegmentedControl, [Int]) {
        let control = ThemedSegmentedControl(frame: NSRect(x: 0, y: 0, width: 180, height: 26))
        control.configure(
            titles: ["All", "Agent", "You"],
            selectedIndex: selectedIndex
        )
        control.layoutSubtreeIfNeeded()
        return (control, [])
    }

    func testASegmentSelectsOnClickAndReportsItOnce() throws {
        let (control, _) = makeSegmentedControl()
        var reported: [Int] = []
        control.onSelect = { reported.append($0) }

        try XCTUnwrap(control.segment(at: 2)).mouseDown(with: .init())

        XCTAssertEqual(control.selectedIndex, 2)
        XCTAssertEqual(reported, [2])

        // Re-picking the segment already on is not a choice, and reporting it would make every
        // host re-run whatever the selection drives.
        try XCTUnwrap(control.segment(at: 2)).mouseDown(with: .init())
        XCTAssertEqual(reported, [2], "re-selecting the current segment reported a change")
    }

    /// Setting the property is a host restoring state, not the user picking — so it moves the
    /// selection and stays silent.
    func testAProgrammaticSelectionDoesNotReportAChange() {
        let (control, _) = makeSegmentedControl()
        var reported: [Int] = []
        control.onSelect = { reported.append($0) }

        control.selectedIndex = 1

        XCTAssertEqual(control.selectedIndex, 1)
        XCTAssertTrue(reported.isEmpty, "restoring a selection reported it as a choice")
    }

    func testTheRunIsWalkedWithTheArrowKeysAndDoesNotWrap() throws {
        let (control, _) = makeSegmentedControl()
        let right = try keyEvent(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124)
        let left = try keyEvent(String(UnicodeScalar(NSLeftArrowFunctionKey)!), keyCode: 123)

        try XCTUnwrap(control.segment(at: 0)).keyDown(with: right)
        XCTAssertEqual(control.selectedIndex, 1)

        try XCTUnwrap(control.segment(at: 1)).keyDown(with: right)
        XCTAssertEqual(control.selectedIndex, 2)

        // The end holds rather than wrapping: with three segments a wrap reads as the selection
        // jumping the length of the control instead of moving one step.
        try XCTUnwrap(control.segment(at: 2)).keyDown(with: right)
        XCTAssertEqual(control.selectedIndex, 2, "the run wrapped at its end")

        try XCTUnwrap(control.segment(at: 2)).keyDown(with: left)
        XCTAssertEqual(control.selectedIndex, 1)
    }

    func testASegmentIsActivatedFromTheKeyboardAndByAccessibility() throws {
        let (control, _) = makeSegmentedControl()
        let space = try keyEvent(" ", keyCode: 49)

        try XCTUnwrap(control.segment(at: 1)).keyDown(with: space)
        XCTAssertEqual(control.selectedIndex, 1)

        XCTAssertTrue(try XCTUnwrap(control.segment(at: 2)).accessibilityPerformPress())
        XCTAssertEqual(control.selectedIndex, 2)
    }

    /// A run of mutually exclusive choices is a radio group whose segments are its buttons —
    /// the same shape `ThemedTabItemView` already reports, so VoiceOver and UI scripting can
    /// name and pick one segment rather than meeting a single opaque control.
    func testTheRunReportsItselfAsARadioGroupOfNamedButtons() throws {
        let (control, _) = makeSegmentedControl(selectedIndex: 1)

        XCTAssertEqual(control.accessibilityRole(), .radioGroup)

        let agent = try XCTUnwrap(control.segment(at: 1))
        let you = try XCTUnwrap(control.segment(at: 2))

        XCTAssertTrue(agent.isAccessibilityElement())
        XCTAssertEqual(agent.accessibilityRole(), .radioButton)
        XCTAssertEqual(agent.accessibilityTitle(), "Agent")
        XCTAssertEqual(agent.accessibilityValue() as? Bool, true)
        XCTAssertEqual(you.accessibilityValue() as? Bool, false)
    }

    func testTheSelectedSegmentIsDrawnDifferentlyFromItsNeighbours() throws {
        let (control, _) = makeSegmentedControl(selectedIndex: 0)
        let first = try XCTUnwrap(control.segment(at: 0))
        let second = try XCTUnwrap(control.segment(at: 1))

        XCTAssertNotEqual(
            try renderedPNG(of: first),
            try renderedPNG(of: second),
            "the selection is not visible on the control"
        )
    }

    /// The track goes through `applySurface` and the segments draw from roles, so both follow a
    /// live switch. A run drawn once and left alone is how a themed control keeps the palette it
    /// was born under — the bug `ThemedControl` exists to prevent.
    func testTheRunFollowsALiveThemeSwitch() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let (control, _) = makeSegmentedControl(selectedIndex: 1)
        let cyber = try renderedPNG(of: control)

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        AppThemeRefresh.repaint(control)
        let swiss = try renderedPNG(of: control)

        XCTAssertNotEqual(cyber, swiss, "the run kept the palette it was built under")
    }

    // MARK: - Pop-Up Drop-in Behaviour

    /// `ThemedPopUp` replaces `NSPopUpButton` at call sites that add titled items and read the
    /// selection back, so the whole of that small surface has to behave the same — including
    /// AppKit's habit of selecting the first item a pop-up is given.
    func testAPopUpSelectsItsFirstItemAndReadsItBack() {
        let popUp = ThemedPopUp()
        XCTAssertEqual(popUp.indexOfSelectedItem, -1, "an empty pop-up claimed a selection")
        XCTAssertNil(popUp.selectedItem)

        popUp.addItem(withTitle: "Claude Code")
        popUp.addItem(withTitle: "Codex")

        XCTAssertEqual(popUp.numberOfItems, 2)
        XCTAssertEqual(popUp.indexOfSelectedItem, 0, "the first item was not selected")
        XCTAssertEqual(popUp.selectedItem?.title, "Claude Code")
        XCTAssertEqual(popUp.item(at: 1)?.title, "Codex")

        popUp.selectItem(at: 1)
        XCTAssertEqual(popUp.selectedItem?.title, "Codex")
    }

    /// The index usually comes from looking a stored value up in a list, so one the list no
    /// longer holds must leave the control unselected rather than trap — the settings window is
    /// not a place to crash over a stale preference.
    func testAnOutOfRangeSelectionIsToleratedRatherThanTrapped() {
        let popUp = ThemedPopUp()
        popUp.addItem(withTitle: "Block")

        popUp.selectItem(at: 7)

        XCTAssertEqual(popUp.indexOfSelectedItem, -1)
        XCTAssertNil(popUp.selectedItem)
    }

    func testChoosingAnItemRecordsTheSelectionThenFiresTheAction() {
        let popUp = ThemedPopUp()
        popUp.addItem(withTitle: "System")
        popUp.addItem(withTitle: "Cyberpunk")

        let target = ActionSpy()
        popUp.target = target
        popUp.action = #selector(ActionSpy.fire)

        popUp.chooseItem(at: 1)

        XCTAssertEqual(popUp.indexOfSelectedItem, 1, "the choice was not recorded")
        XCTAssertEqual(target.count, 1, "the action did not fire")
    }

    /// A pull-down is an actions button: its entries do things rather than becoming the title,
    /// which is what the themes list's gear depends on.
    func testAPullDownKeepsItsLabelAndRecordsNoSelection() {
        let popUp = ThemedPopUp()
        popUp.pullsDown = true
        popUp.addItem(withTitle: "")
        popUp.addItem(withTitle: "Duplicate")

        popUp.chooseItem(at: 1)

        XCTAssertNil(popUp.selectedItem, "a pull-down recorded a selection")
        XCTAssertEqual(popUp.accessibilityValue() as? String, "",
                       "a pull-down stopped showing its own first item")
    }

    /// Tinting a template directly against a view's backing context sees the surface already
    /// drawn beneath the glyph and floods the whole image slot. The Themes-page gear exposed
    /// this as a black square in light appearance and a white one in dark appearance.
    func testABorderlessPullDownDrawsItsTemplateGlyphWithoutABox() throws {
        let popUp = ThemedPopUp(frame: NSRect(x: 0, y: 0, width: 38, height: 26))
        popUp.pullsDown = true
        popUp.isBordered = false
        popUp.addItem(ThemedMenuItem(
            title: "",
            image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Actions")
        ))
        popUp.addItem(withTitle: "Duplicate")

        let rep = try XCTUnwrap(popUp.bitmapImageRepForCachingDisplay(in: popUp.bounds))
        popUp.cacheDisplay(in: popUp.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / popUp.bounds.width

        // The image slot begins at the standard medium inset. A gear has no ink in its upper
        // leading corner; a flooded slot does.
        let corner = try XCTUnwrap(rep.colorAt(
            x: Int((Design.Spacing.medium + 1) * scale),
            y: Int((popUp.bounds.midY + 6) * scale)
        ))
        XCTAssertLessThan(
            corner.alphaComponent,
            0.2,
            "the template tint flooded the pop-up's image slot"
        )
    }

    /// A pull-down action is app-owned behavior on the semantic item. It runs without also
    /// firing the pop-up's selection target/action, which belongs to ordinary choices.
    func testAPerItemActionRunsWithoutFiringTheSelectionAction() {
        let popUp = ThemedPopUp()
        let selectionTarget = ActionSpy()
        var itemActions = 0
        popUp.target = selectionTarget
        popUp.action = #selector(ActionSpy.fire)
        popUp.addItem(ThemedMenuItem(title: "Rename…", onChoose: { itemActions += 1 }))

        popUp.chooseItem(at: 0)

        XCTAssertEqual(itemActions, 1)
        XCTAssertEqual(selectionTarget.count, 0)
    }

    func testTheHelperBuildsAThemedPopUpNotAnNSPopUpButton() {
        let spy = ActionSpy()
        let control: ThemedControl = SettingsUI.popUp(
            target: spy,
            action: #selector(ActionSpy.fire)
        )
        XCTAssertTrue(control is ThemedPopUp, "SettingsUI.popUp still hands back a raw pop-up")
    }

    func testThemedMenuChoosesWithArrowKeysAndReturn() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        let popUp = ThemedPopUp(frame: NSRect(x: 24, y: 180, width: 140, height: 26))
        popUp.addItem(withTitle: "System")
        popUp.addItem(ThemedMenuItem(
            title: "Cyberpunk",
            subtitle: "Neon and deep black"
        ))
        popUp.addSeparator()
        popUp.addItem(ThemedMenuItem(title: "Unavailable", isEnabled: false))
        let target = ActionSpy()
        popUp.target = target
        popUp.action = #selector(ActionSpy.fire)
        root.addSubview(popUp)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }

        XCTAssertTrue(popUp.accessibilityPerformShowMenu())

        let responder = try XCTUnwrap(window.firstResponder)
        responder.keyDown(with: try keyEvent("", keyCode: 125))
        responder.keyDown(with: try keyEvent("\r", keyCode: 36))

        XCTAssertEqual(popUp.selectedItem?.title, "Cyberpunk")
        XCTAssertEqual(target.count, 1)
        XCTAssertFalse(
            descendants(in: root).contains { $0.accessibilityRole() == .menu },
            "choosing left the dropdown attached to the window"
        )
    }

    func testThemedMenuExposesMenuRowsToAccessibility() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        let source = NSView(frame: NSRect(x: 24, y: 180, width: 140, height: 26))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }

        let token = try XCTUnwrap(ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [
                    .item(ThemedMenuItem(title: "Enabled")),
                    .item(ThemedMenuItem(title: "Disabled", isEnabled: false))
                ],
                minimumWidth: source.bounds.width
            ),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, _ in },
            onDismiss: {}
        ))
        defer { ThemedMenuPresenter.dismiss(token) }

        let menu = try XCTUnwrap(
            descendants(in: root).first { $0.accessibilityRole() == .menu }
        )
        let rows = descendants(in: menu).filter { $0.accessibilityRole() == .menuItem }

        XCTAssertEqual(rows.compactMap { $0.accessibilityTitle() }, ["Enabled", "Disabled"])
        XCTAssertEqual(rows.map { $0.isAccessibilityEnabled() }, [true, false])
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: window), [])
    }

    /// Two *adjacent* filled rows keep a hairline of panel between them.
    ///
    /// A menu reaches that pair whenever the highlight and a press part company — the keyboard
    /// moved the highlight off the row the pointer is resting on, and that row is then pressed —
    /// or while a parent row holds the menu path through the grace its submenu is given to
    /// close. Drawn at the row's full height those capsules share an edge and fuse into one
    /// pinched blob, with the corner radii reading as a dent rather than as the gap between two
    /// shapes. Asserted off the pixels, because the claim is about what the two rows look like
    /// together and each row on its own was always right.
    func testThemedMenuPartsTwoFilledRowsWithAHairline() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        root.appearance = appearance
        let source = NSView(frame: NSRect(x: 24, y: 250, width: 240, height: 26))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = root
        defer { window.close() }

        let token = try XCTUnwrap(ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [
                    .item(ThemedMenuItem(title: "One")),
                    .item(ThemedMenuItem(title: "Two")),
                    .item(ThemedMenuItem(title: "Three"))
                ],
                minimumWidth: source.bounds.width
            ),
            from: source,
            selectedEntryIndex: 0,
            onChoose: { _, _ in },
            onDismiss: {}
        ))
        defer { ThemedMenuPresenter.dismiss(token) }

        // The overlay is laid out by frames during the window's display cycle, which an
        // offscreen render never enters — so the pass is forced.
        markNeedingLayout(root)
        root.layoutSubtreeIfNeeded()

        let rows = descendants(in: root).filter { $0.accessibilityRole() == .menuItem }
        XCTAssertEqual(rows.count, 3)
        let frames = rows.map { root.convert($0.bounds, from: $0) }

        // The first row opens highlighted; the pointer, already resting on the row beneath it
        // when the keyboard moved the highlight away, presses it. Nothing new is hovered, so
        // both rows are filled at once — which is the state the inset exists for.
        rows[1].mouseDown(with: try mouseEvent(
            .leftMouseDown,
            at: NSPoint(x: frames[1].midX, y: frames[1].midY),
            in: window
        ))

        markNeedingLayout(root)
        root.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)

        // Well inside the fill's right end: past every title, and clear of the corner arc that
        // rounds the capsule's own edge.
        let probeX = frames[0].maxX - Design.Spacing.pane
        let highlighted = try colour(of: rep, at: NSPoint(x: probeX, y: frames[0].midY), in: root)
        let pressed = try colour(of: rep, at: NSPoint(x: probeX, y: frames[1].midY), in: root)
        // The third row is filled by nothing, so it is what bare panel looks like here.
        let bare = try colour(of: rep, at: NSPoint(x: probeX, y: frames[2].midY), in: root)
        let between = try colour(of: rep, at: NSPoint(x: probeX, y: frames[0].minY), in: root)

        XCTAssertNotEqual(highlighted.hexString, bare.hexString, "the highlighted row drew no fill")
        XCTAssertNotEqual(pressed.hexString, bare.hexString, "the pressed row drew no fill")
        XCTAssertEqual(
            between.hexString,
            bare.hexString,
            "the two fills met — a filled row has to stop short of the row stacked against it"
        )
    }

    /// **A checked row is not a highlighted row.** The check says what is on; the fill says
    /// where the pointer or the keyboard is, and only one row can be that at a time.
    ///
    /// The sidebar's arrangement menu is three toggles and a chosen order, so it came up with
    /// three of its five rows filled in the theme's `selection` — the ground behind selected
    /// *text*, which Win98 holds at a near-opaque navy — before it had been touched. Whichever
    /// row the pointer was actually on then had nothing left to say.
    func testAThemedMenuChecksARowRatherThanFillingIt() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        root.appearance = appearance
        let source = NSView(frame: NSRect(x: 24, y: 250, width: 240, height: 26))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = root
        defer { window.close() }

        // The highlight opens on the first row, so the checked one is left saying only what a
        // checked row says on its own.
        let token = try XCTUnwrap(ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [
                    .item(ThemedMenuItem(title: "Sort by Recent Activity")),
                    .item(ThemedMenuItem(title: "Sort by Order Added", isSelected: true)),
                    .item(ThemedMenuItem(title: "Sort by Name"))
                ],
                minimumWidth: source.bounds.width
            ),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, _ in },
            onDismiss: {}
        ))
        defer { ThemedMenuPresenter.dismiss(token) }

        markNeedingLayout(root)
        root.layoutSubtreeIfNeeded()

        let rows = descendants(in: root).filter { $0.accessibilityRole() == .menuItem }
        XCTAssertEqual(rows.count, 3)
        let frames = rows.map { root.convert($0.bounds, from: $0) }

        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)

        let probeX = frames[0].maxX - Design.Spacing.pane
        let highlighted = try colour(of: rep, at: NSPoint(x: probeX, y: frames[0].midY), in: root)
        let checked = try colour(of: rep, at: NSPoint(x: probeX, y: frames[1].midY), in: root)
        let bare = try colour(of: rep, at: NSPoint(x: probeX, y: frames[2].midY), in: root)

        XCTAssertNotEqual(highlighted.hexString, bare.hexString, "the highlighted row drew no fill")
        XCTAssertEqual(
            checked.hexString,
            bare.hexString,
            "a checked row painted itself as though the pointer were on it"
        )

        // And the check is genuinely there — "no fill" must not be reached by marking nothing.
        // The glyph is a thin diagonal, so its column is scanned rather than sampled at a point.
        var inked = 0
        let box = NSRect(
            x: frames[1].minX + ThemedMenuMetrics.contentInset,
            y: frames[1].midY - ThemedMenuMetrics.checkSize / 2,
            width: ThemedMenuMetrics.checkSize,
            height: ThemedMenuMetrics.checkSize
        )
        for x in stride(from: box.minX, through: box.maxX, by: 0.5) {
            for y in stride(from: box.minY, through: box.maxY, by: 0.5) {
                let pixel = try colour(of: rep, at: NSPoint(x: x, y: y), in: root)
                if pixel.hexString != bare.hexString { inked += 1 }
            }
        }
        XCTAssertGreaterThan(inked, 0, "the checked row drew neither a fill nor a check")
    }

    func testThemedMenuSurfaceUsesTheSourceViewsLocalAppearance() throws {
        let originalAppAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = originalAppAppearance }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        root.appearance = NSAppearance(named: .aqua)
        let source = NSView(frame: NSRect(x: 24, y: 180, width: 140, height: 26))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }

        let token = try XCTUnwrap(ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [.item(ThemedMenuItem(title: "Light item"))],
                minimumWidth: source.bounds.width
            ),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, _ in },
            onDismiss: {}
        ))
        defer { ThemedMenuPresenter.dismiss(token) }

        let menu = try XCTUnwrap(
            descendants(in: root).first { $0.accessibilityRole() == .menu }
        )
        let actual = try XCTUnwrap(
            menu.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        )
        var expected: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            expected = NSColor(cgColor: Design.Surface.elevated.cgColor)
        }
        let resolvedExpected = try XCTUnwrap(expected)
        XCTAssertEqual(actual.hexString, resolvedExpected.hexString)
    }

    func testPullDownOmitsItsDisplayOnlyLabelFromTheCustomMenu() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        let popUp = ThemedPopUp(frame: NSRect(x: 20, y: 160, width: 90, height: 26))
        popUp.pullsDown = true
        popUp.addItem(withTitle: "Actions")
        var actionCount = 0
        popUp.addItem(ThemedMenuItem(title: "Duplicate", onChoose: { actionCount += 1 }))
        root.addSubview(popUp)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }

        XCTAssertTrue(popUp.accessibilityPerformShowMenu())
        let rows = descendants(in: root).filter { $0.accessibilityRole() == .menuItem }
        XCTAssertEqual(rows.compactMap { $0.accessibilityTitle() }, ["Duplicate"])

        try XCTUnwrap(window.firstResponder).keyDown(
            with: try keyEvent("\r", keyCode: 36)
        )
        XCTAssertEqual(actionCount, 1)
        XCTAssertEqual(popUp.accessibilityValue() as? String, "Actions")
    }

    func testThemedMenuLayoutOpensWhereThereIsRoomAndClampsToThePane() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        let size = NSSize(width: 180, height: 120)

        let highAnchor = NSRect(x: 350, y: 230, width: 40, height: 26)
        let below = ThemedMenuLayout.frame(
            anchor: highAnchor,
            desiredSize: size,
            in: bounds,
            flipped: false
        )
        XCTAssertLessThan(below.maxY, highAnchor.minY)
        XCTAssertLessThanOrEqual(below.maxX, bounds.maxX - ThemedMenuLayout.screenInset)

        let lowAnchor = NSRect(x: 20, y: 12, width: 100, height: 26)
        let above = ThemedMenuLayout.frame(
            anchor: lowAnchor,
            desiredSize: size,
            in: bounds,
            flipped: false
        )
        XCTAssertGreaterThan(above.minY, lowAnchor.maxY)
        XCTAssertGreaterThanOrEqual(above.minX, bounds.minX + ThemedMenuLayout.screenInset)
    }

    /// A clamped panel that happens to end on a row boundary looks like the whole menu. The
    /// session row's menu grew past the maximum and did exactly that, so Copy Session ID and
    /// Delete Session were invisible until something scrolled — which nothing invited.
    func testAMenuTooTallToShowEveryRowCutsTheLastOneInHalf() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 900)
        let cap = ThemedMenuLayout.maximumHeight(in: bounds)
        let entries = (0..<32).map { ThemedMenuEntry.item(ThemedMenuItem(title: "Row \($0)")) }
        let natural = ThemedMenuMetrics.height(for: entries)
        XCTAssertGreaterThan(natural, cap)

        let panel = ThemedMenuLayout.frame(
            anchor: NSRect(x: 40, y: 820, width: 40, height: 26),
            desiredSize: NSSize(width: 200, height: natural),
            in: bounds,
            flipped: false,
            whenClipped: { ThemedMenuMetrics.clippedHeight(for: entries, atMost: $0) }
        )

        XCTAssertLessThanOrEqual(panel.height, cap)
        // The peek is paid for out of one row, never out of two.
        XCTAssertGreaterThan(panel.height, cap - ThemedMenuMetrics.rowHeight)
        XCTAssertEqual(
            (panel.height - ThemedMenuMetrics.outerInset * 2)
                .truncatingRemainder(dividingBy: ThemedMenuMetrics.rowHeight),
            ThemedMenuMetrics.rowHeight / 2,
            accuracy: 0.5,
            "the clipped panel ends on a whole row, so nothing on screen says the list continues"
        )
    }

    /// The peek is for menus that are actually cut. A menu with room for every row is left
    /// alone — half a row hanging off a complete list would promise something that is not there.
    func testAMenuWithRoomForEveryRowIsNotCut() {
        let entries = (0..<4).map { ThemedMenuEntry.item(ThemedMenuItem(title: "Row \($0)")) }
        let natural = ThemedMenuMetrics.height(for: entries)

        let panel = ThemedMenuLayout.frame(
            anchor: NSRect(x: 40, y: 700, width: 40, height: 26),
            desiredSize: NSSize(width: 200, height: natural),
            in: NSRect(x: 0, y: 0, width: 400, height: 900),
            flipped: false,
            whenClipped: { height in
                XCTFail("a menu that fits was treated as clipped")
                return height
            }
        )

        XCTAssertEqual(panel.height, natural, accuracy: 0.5)
    }

    /// A separator is carried whole into the hidden part: sliced down its middle it reads as a
    /// stray rule along the panel's edge, which says nothing about there being more below.
    func testTheCutFallsOnARowRatherThanOnASeparator() {
        var entries: [ThemedMenuEntry] = []
        for index in 0..<24 {
            entries.append(.item(ThemedMenuItem(title: "Row \(index)")))
            entries.append(.separator)
        }
        let clipped = ThemedMenuMetrics.clippedHeight(
            for: entries,
            atMost: ThemedMenuLayout.maximumHeightFloor
        )

        // Where the rows stop being visible: the panel's own padding sits at both ends, so the
        // content the scroller shows ends one inset above the panel's lower edge.
        let cut = clipped - ThemedMenuMetrics.outerInset * 2
        var consumed: CGFloat = 0
        for entry in entries {
            let height = ThemedMenuMetrics.height(of: entry)
            if consumed + height > cut {
                XCTAssertTrue(entry.isItem, "the cut fell on a separator")
                XCTAssertEqual(cut - consumed, height / 2, accuracy: 0.5)
                return
            }
            consumed += height
        }
        XCTFail("the panel was not clipped at all")
    }

    /// The wiring, not the arithmetic: a presented panel takes the peek rather than the bare
    /// clamp, which is the part a refactor of the presenter could drop without any geometry
    /// test noticing.
    func testAPresentedPanelTakesThePeekRatherThanTheBareClamp() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 900))
        let source = NSView(frame: NSRect(x: 24, y: 820, width: 160, height: 26))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }

        let entries = (0..<24).map { ThemedMenuEntry.item(ThemedMenuItem(title: "Row \($0)")) }
        let token = try XCTUnwrap(ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 190),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, _ in },
            onDismiss: {}
        ))
        let panel = try menuFrame(in: root)
        ThemedMenuPresenter.dismiss(token)

        XCTAssertEqual(
            panel.height,
            ThemedMenuMetrics.clippedHeight(
                for: entries,
                atMost: ThemedMenuLayout.maximumHeight(in: root.bounds)
            ),
            accuracy: 0.5
        )
    }

    /// The cap follows the window. It was a flat 360, set when the longest menu was half its
    /// eventual size; once the session menu outgrew it, scrolling became the normal state and
    /// Delete Session sat below the fold on every right-click. A tall window now shows the
    /// whole list, and a cramped one keeps the old floor.
    func testTheMenuHeightCapFollowsTheWindow() {
        let tall = NSRect(x: 0, y: 0, width: 600, height: 1200)
        XCTAssertEqual(
            ThemedMenuLayout.maximumHeight(in: tall),
            tall.height * ThemedMenuLayout.maximumHeightRatio
        )

        let cramped = NSRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertEqual(
            ThemedMenuLayout.maximumHeight(in: cramped),
            ThemedMenuLayout.maximumHeightFloor
        )

        // A session-menu-sized list fits whole where the flat cap would have cut it.
        let entries = (0..<18).map { ThemedMenuEntry.item(ThemedMenuItem(title: "Row \($0)")) }
        let natural = ThemedMenuMetrics.height(for: entries)
        XCTAssertGreaterThan(natural, ThemedMenuLayout.maximumHeightFloor)
        let panel = ThemedMenuLayout.frame(
            anchor: NSRect(x: 40, y: 1100, width: 40, height: 26),
            desiredSize: NSSize(width: 200, height: natural),
            in: tall,
            flipped: false,
            whenClipped: { ThemedMenuMetrics.clippedHeight(for: entries, atMost: $0) }
        )
        XCTAssertEqual(
            panel.height,
            natural,
            accuracy: 0.5,
            "a window with room still clipped the menu"
        )
    }

    /// A submenu is clamped by the same two limits and hides its tail the same way — the Theme
    /// list is long enough to reach both.
    func testASubmenuTooTallToShowEveryRowCutsTheLastOneInHalf() {
        let entries = (0..<24).map { ThemedMenuEntry.item(ThemedMenuItem(title: "Row \($0)")) }
        let natural = ThemedMenuMetrics.height(for: entries)

        let panel = ThemedMenuLayout.submenuFrame(
            parentPanel: NSRect(x: 40, y: 400, width: 200, height: 300),
            rowFrame: NSRect(x: 40, y: 600, width: 200, height: ThemedMenuMetrics.rowHeight),
            desiredSize: NSSize(width: 200, height: natural),
            in: NSRect(x: 0, y: 0, width: 600, height: 900),
            flipped: false,
            firstRowInset: ThemedMenuMetrics.outerInset,
            whenClipped: { ThemedMenuMetrics.clippedHeight(for: entries, atMost: $0) }
        )

        XCTAssertEqual(
            (panel.height - ThemedMenuMetrics.outerInset * 2)
                .truncatingRemainder(dividingBy: ThemedMenuMetrics.rowHeight),
            ThemedMenuMetrics.rowHeight / 2,
            accuracy: 0.5
        )
    }

    /// A menu opened by a secondary click lands on the pointer, not on its view.
    ///
    /// The presenter was written for dropdowns, where the anchor is the button and the panel
    /// lines up under its edge. A context menu presented the same way opens in one fixed place
    /// however large the thing clicked is — the composer's attachment thumbnail showed it — and
    /// a menu that ignores where the click landed does not read as answering the click.
    func testThemedMenuOpensOnThePointerForASecondaryClick() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        // High enough that both menus have room to open downward, so the two anchors are
        // compared on the same side of their anchor rather than on opposite ones.
        let source = NSView(frame: NSRect(x: 20, y: 150, width: 240, height: 100))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }

        let presentation = ThemedMenuPresentation(
            entries: [
                .item(ThemedMenuItem(title: "Inspect")),
                .item(ThemedMenuItem(title: "Reveal in Finder")),
                .item(ThemedMenuItem(title: "Remove Attachment"))
            ],
            minimumWidth: 190
        )

        // Deliberately away from every edge of the source, so anchoring to the view and
        // anchoring to the click cannot agree by accident.
        let click = NSPoint(x: 180, y: 200)
        let pointerToken = try XCTUnwrap(ThemedMenuPresenter.present(
            presentation,
            from: source,
            anchor: .pointer(click),
            selectedEntryIndex: nil,
            onChoose: { _, _ in },
            onDismiss: {}
        ))
        let atPointer = try menuFrame(in: root)
        ThemedMenuPresenter.dismiss(pointerToken)

        // The panel's corner *is* the click: it hangs below the point, with no dropdown standoff.
        XCTAssertEqual(atPointer.minX, click.x, accuracy: 0.5)
        XCTAssertEqual(atPointer.maxY, click.y, accuracy: 0.5)

        let controlToken = try XCTUnwrap(ThemedMenuPresenter.present(
            presentation,
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, _ in },
            onDismiss: {}
        ))
        let atControl = try menuFrame(in: root)
        ThemedMenuPresenter.dismiss(controlToken)

        // A dropdown is unchanged: still the source's leading edge, still standing off it.
        XCTAssertEqual(atControl.minX, source.frame.minX, accuracy: 0.5)
        XCTAssertEqual(atControl.maxY, source.frame.minY - ThemedMenuLayout.gap, accuracy: 0.5)
    }

    /// The open dropdown's panel, in `root`'s coordinates.
    private func menuFrame(in root: NSView) throws -> NSRect {
        let menu = try XCTUnwrap(
            descendants(in: root).first { $0.accessibilityRole() == .menu },
            "no dropdown was presented"
        )
        return root.convert(menu.bounds, from: menu)
    }

    // MARK: - Submenus

    /// A parent row opens beside its panel; the keyboard walks in and out of it the way the
    /// platform's menus do — right arrow in with the first row lit, left arrow back out with
    /// the parent keeping the highlight — and a choice anywhere in the chain answers the
    /// whole menu.
    func testThemedMenuSubmenuOpensChoosesAndClosesFromTheKeyboard() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        let source = NSView(frame: NSRect(x: 24, y: 240, width: 160, height: 26))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }

        var chosen: String?
        var dismissed = false
        let token = try XCTUnwrap(ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [
                    .item(ThemedMenuItem(title: "Plain", onChoose: { chosen = "Plain" })),
                    .item(ThemedMenuItem(title: "Options", submenu: [
                        .item(ThemedMenuItem(title: "First", onChoose: { chosen = "First" })),
                        .item(ThemedMenuItem(title: "Second", onChoose: { chosen = "Second" }))
                    ]))
                ],
                minimumWidth: 160
            ),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { dismissed = true }
        ))
        defer { ThemedMenuPresenter.dismiss(token) }
        let overlay = try XCTUnwrap(window.firstResponder as? NSView)

        func menus() -> [NSView] {
            descendants(in: root).filter { $0.accessibilityRole() == .menu }
        }
        XCTAssertEqual(menus().count, 1)

        // Down to "Options", right to open. The submenu joins the tree, its panel sits to
        // the right of the root's, and its first row takes the highlight.
        overlay.keyDown(with: try keyEvent("", keyCode: 125))
        overlay.keyDown(with: try keyEvent("", keyCode: 124))
        XCTAssertEqual(menus().count, 2, "right arrow should have opened the submenu")

        let panels = menus().map { root.convert($0.bounds, from: $0) }
        XCTAssertGreaterThan(
            panels[1].minX,
            panels[0].minX,
            "the submenu should open beside its parent, not over it"
        )

        let rows = descendants(in: menus()[1])
            .filter { $0.accessibilityRole() == .menuItem }
        XCTAssertEqual(rows.compactMap { $0.accessibilityTitle() }, ["First", "Second"])

        // Left closes just the submenu; the root panel stays.
        overlay.keyDown(with: try keyEvent("", keyCode: 123))
        XCTAssertEqual(menus().count, 1, "left arrow should have closed only the submenu")
        XCTAssertFalse(dismissed, "closing a submenu must not answer the menu")

        // Back in, and Return on "Second" answers the whole menu.
        overlay.keyDown(with: try keyEvent("", keyCode: 124))
        overlay.keyDown(with: try keyEvent("", keyCode: 125))
        overlay.keyDown(with: try keyEvent("", keyCode: 36))
        XCTAssertEqual(chosen, "Second")
        XCTAssertTrue(dismissed, "a submenu choice should close the whole menu")

        XCTAssertEqual(ThemeBoundaryAudit.violations(in: window), [])
    }

    /// Wheeling a clamped menu slides rows under a stationary pointer, and AppKit hands each
    /// arrival a `mouseEntered`. That is the list's motion, not the hand's: the highlight must
    /// stay where the pointer last put it, and Return must answer with the row the user chose,
    /// not whichever one the scroll parked under the cursor.
    func testScrollingAMenuDoesNotHandTheHighlightToTheRowThatSlidUnderThePointer() throws {
        let fixture = try clampedMenuFixture()
        defer {
            ThemedMenuPresenter.dismiss(fixture.token)
            fixture.window.close()
        }

        // The menu opens with its first row highlighted. Scroll the panel, then deliver the
        // enter the scroll hands to the row now under the pointer.
        scroll(fixture.scrollView, by: ThemedMenuMetrics.rowHeight * 2)
        fixture.rows[5].mouseEntered(with: try enterEvent(
            at: windowCentre(of: fixture.rows[5]),
            in: fixture.window
        ))

        fixture.overlay.keyDown(with: try keyEvent("\r", keyCode: 36))
        XCTAssertEqual(
            fixture.chosen(),
            "Row 0",
            "the scroll handed the highlight to the row that slid under the pointer"
        )
    }

    /// The freeze ends the moment the pointer actually moves — and the landing is re-answered
    /// from position, because the row under the pointer got no fresh enter: it has believed
    /// itself hovered since the scroll delivered its `mouseEntered`.
    func testPointerMovementAfterAScrollLandsTheHighlightOnTheRowUnderIt() throws {
        let fixture = try clampedMenuFixture()
        defer {
            ThemedMenuPresenter.dismiss(fixture.token)
            fixture.window.close()
        }

        scroll(fixture.scrollView, by: ThemedMenuMetrics.rowHeight * 2)
        fixture.rows[5].mouseEntered(with: try enterEvent(
            at: windowCentre(of: fixture.rows[5]),
            in: fixture.window
        ))

        // Any visible row whose centre is clear of the freeze tolerance around wherever the
        // machine's real pointer happens to be — rows sit a full row apart, so at most one
        // candidate can be too close.
        let freeze = fixture.window.mouseLocationOutsideOfEventStream
        let target = try XCTUnwrap(
            [fixture.rows[4], fixture.rows[6]].first { row in
                let centre = windowCentre(of: row)
                return hypot(centre.x - freeze.x, centre.y - freeze.y)
                    > ThemedMenuMotion.scrollHoverTolerance * 2
            }
        )
        fixture.overlay.mouseMoved(with: try mouseEvent(
            .mouseMoved,
            at: windowCentre(of: target),
            in: fixture.window
        ))

        fixture.overlay.keyDown(with: try keyEvent("\r", keyCode: 36))
        XCTAssertEqual(
            fixture.chosen(),
            target.accessibilityTitle(),
            "moving after a scroll should land the highlight on the row under the pointer"
        )
    }

    /// A pointer highlight names a row that is already under the pointer, so it must not
    /// scroll — nudging the half-peeked row fully in moves the list under a hand that did not
    /// ask, and during a wheel gesture it visibly fights the wheel. Keyboard travel keeps the
    /// scroll-into-view: a row arrowed to below the fold has to come on screen.
    func testAPointerHighlightLeavesTheScrollAloneWhereKeyboardTravelWouldNot() throws {
        let fixture = try clampedMenuFixture()
        defer {
            ThemedMenuPresenter.dismiss(fixture.token)
            fixture.window.close()
        }
        let clip = fixture.scrollView.contentView
        XCTAssertEqual(clip.bounds.origin.y, 0)

        // The clamped panel ends on the half-peeked row: visible, but not wholly.
        let visible = clip.documentVisibleRect
        let peeked = try XCTUnwrap(
            fixture.rows.first { row in
                row.frame.intersects(visible) && !visible.contains(row.frame)
            },
            "a clamped menu should have a half-peeked row"
        )
        peeked.mouseEntered(with: try enterEvent(
            at: windowCentre(of: peeked),
            in: fixture.window
        ))
        XCTAssertEqual(
            clip.bounds.origin.y,
            0,
            "hovering the half-peeked row scrolled the menu under the pointer"
        )

        for _ in fixture.rows { fixture.overlay.keyDown(with: try keyEvent("", keyCode: 125)) }
        XCTAssertGreaterThan(
            clip.bounds.origin.y,
            0,
            "keyboard travel below the fold no longer scrolls its row into view"
        )
    }

    /// A menu tall enough to clamp against its root and scroll, presented and laid out, with
    /// its rows in entry order and the choice recorded by title.
    private func clampedMenuFixture() throws -> (
        window: NSWindow,
        overlay: NSView,
        rows: [NSView],
        scrollView: NSScrollView,
        token: AnyObject,
        chosen: () -> String?
    ) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 500))
        let source = NSView(frame: NSRect(x: 24, y: 460, width: 160, height: 26))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root

        var chosen: String?
        let token = try XCTUnwrap(ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: (0..<24).map {
                    .item(ThemedMenuItem(title: "Row \($0)"))
                },
                minimumWidth: 160
            ),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, item in chosen = item.title },
            onDismiss: {}
        ))
        markNeedingLayout(root)
        root.layoutSubtreeIfNeeded()

        let overlay = try XCTUnwrap(window.firstResponder as? NSView)
        let rows = descendants(in: root).filter { $0.accessibilityRole() == .menuItem }
        XCTAssertEqual(rows.count, 24)
        let scrollView = try XCTUnwrap(rows[0].enclosingScrollView)
        XCTAssertTrue(
            scrollView.contentView.documentVisibleRect.height
                < ThemedMenuMetrics.height(for: (0..<24).map {
                    .item(ThemedMenuItem(title: "Row \($0)"))
                }),
            "the fixture's menu fits — nothing here scrolls"
        )
        return (window, overlay, rows, scrollView, token, { chosen })
    }

    private func scroll(_ scrollView: NSScrollView, by delta: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + delta))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Pressing a parent row (a click, or an accessibility press) opens its submenu rather
    /// than answering the menu — a parent has nothing to answer with.
    func testPressingAParentRowOpensItsSubmenuInsteadOfChoosing() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        let source = NSView(frame: NSRect(x: 24, y: 240, width: 160, height: 26))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }

        var dismissed = false
        let token = try XCTUnwrap(ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [
                    .item(ThemedMenuItem(title: "Options", submenu: [
                        .item(ThemedMenuItem(title: "Inner"))
                    ]))
                ],
                minimumWidth: 160
            ),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, _ in },
            onDismiss: { dismissed = true }
        ))
        defer { ThemedMenuPresenter.dismiss(token) }

        let parent = try XCTUnwrap(
            descendants(in: root).first {
                $0.accessibilityRole() == .menuItem && $0.accessibilityTitle() == "Options"
            }
        )
        XCTAssertTrue(parent.accessibilityPerformPress())

        let menus = descendants(in: root).filter { $0.accessibilityRole() == .menu }
        XCTAssertEqual(menus.count, 2, "the press should have opened the submenu")
        XCTAssertFalse(dismissed, "opening a submenu is not an answer")

        // The open chain hangs off the parent item for accessibility, the way the platform
        // models an item's menu.
        XCTAssertEqual(parent.accessibilityChildren()?.count, 1)
    }

    /// The submenu panel's geometry: beside the parent panel with its first row level with
    /// the parent row, and mirrored to the left when the right edge has no room.
    func testThemedMenuSubmenuFrameOpensBesideAndFlipsWhenCramped() {
        let bounds = NSRect(x: 0, y: 0, width: 600, height: 400)
        let parentPanel = NSRect(x: 40, y: 100, width: 200, height: 200)
        let rowFrame = NSRect(x: 48, y: 240, width: 184, height: 28)
        let size = NSSize(width: 180, height: 120)
        let inset: CGFloat = 6

        let beside = ThemedMenuLayout.submenuFrame(
            parentPanel: parentPanel,
            rowFrame: rowFrame,
            desiredSize: size,
            in: bounds,
            flipped: false,
            firstRowInset: inset
        )
        XCTAssertEqual(
            beside.minX,
            parentPanel.maxX - ThemedMenuLayout.submenuOverlap,
            accuracy: 0.5
        )
        XCTAssertEqual(
            beside.maxY,
            rowFrame.maxY + inset,
            accuracy: 0.5,
            "the submenu's first row should sit level with the row that opened it"
        )

        let crampedPanel = NSRect(x: 380, y: 100, width: 200, height: 200)
        let crampedRow = NSRect(x: 388, y: 240, width: 184, height: 28)
        let mirrored = ThemedMenuLayout.submenuFrame(
            parentPanel: crampedPanel,
            rowFrame: crampedRow,
            desiredSize: size,
            in: bounds,
            flipped: false,
            firstRowInset: inset
        )
        XCTAssertEqual(
            mirrored.maxX,
            crampedPanel.minX + ThemedMenuLayout.submenuOverlap,
            accuracy: 0.5,
            "with no room on the right the panel should mirror to the left"
        )
    }

    // MARK: - Menu Motion

    /// The dropdown arrives with a fade-and-grow rather than snapping in. The animation rides
    /// on the surface's shadow chassis, so panel and shadow arrive as one.
    func testTheMenuAnimatesInWhenMotionIsAllowed() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let (window, root, source) = try menuHarness()
        defer { window.close() }

        let token = try XCTUnwrap(present(from: source))
        defer { ThemedMenuPresenter.dismiss(token) }

        let menu = try XCTUnwrap(
            descendants(in: root).first { $0.accessibilityRole() == .menu }
        )
        XCTAssertNotNil(
            menu.superview?.layer?.animation(forKey: ThemedMenuMotion.appearAnimationKey),
            "the menu appeared with no entrance animation"
        )
    }

    /// An animated dismissal defers only pixels. The session's observable end — the menu role
    /// leaving the accessibility tree, events no longer landing — is synchronous, and the
    /// faded overlay leaves the view tree shortly after.
    func testAnAnimatedDismissalEndsTheSessionSynchronously() throws {
        Design.Motion.reduceMotionOverrideForTesting = false
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let (window, root, source) = try menuHarness()
        defer { window.close() }

        var dismissed = false
        // The token is the session — held for the test the way `ChipView` holds it, since the
        // overlay only references it weakly.
        let token = try XCTUnwrap(present(from: source, onDismiss: { dismissed = true }))
        defer { ThemedMenuPresenter.dismiss(token) }
        let overlay = try XCTUnwrap(
            descendants(in: root)
                .first { $0.accessibilityRole() == .menu }?.superview?.superview
        )

        try XCTUnwrap(window.firstResponder).keyDown(
            with: try keyEvent("\u{1b}", keyCode: 53)
        )

        XCTAssertTrue(dismissed, "onDismiss waited for the fade")
        XCTAssertFalse(
            descendants(in: root).contains { $0.accessibilityRole() == .menu },
            "a closing menu is still a menu to the accessibility tree"
        )
        XCTAssertNil(
            overlay.hitTest(NSPoint(x: 10, y: 10)),
            "a closing menu still takes events"
        )

        let deadline = Date().addingTimeInterval(2)
        while overlay.superview != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(overlay.superview, "the faded overlay never left the view tree")
    }

    /// Under Reduce Motion every dismissal is immediate — no fade to wait out.
    func testReduceMotionDismissesTheMenuImmediately() throws {
        Design.Motion.reduceMotionOverrideForTesting = true
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let (window, root, source) = try menuHarness()
        defer { window.close() }

        let token = try XCTUnwrap(present(from: source))
        defer { ThemedMenuPresenter.dismiss(token) }
        let overlay = try XCTUnwrap(
            descendants(in: root)
                .first { $0.accessibilityRole() == .menu }?.superview?.superview
        )

        try XCTUnwrap(window.firstResponder).keyDown(
            with: try keyEvent("\u{1b}", keyCode: 53)
        )

        XCTAssertNil(overlay.superview, "an instant dismissal left the overlay attached")
    }

    // MARK: - Press-Drag-Release

    /// The other half of how a platform menu tracks a press: button down on the control, held
    /// through the open, released over a row. The control keeps receiving the held press's
    /// events and forwards them, so the release chooses the row it lands on.
    func testAHeldPressDraggedOntoARowChoosesItOnRelease() throws {
        let (window, root, popUp) = try openedPopUp(titles: ["System", "Cyberpunk"])
        defer { window.close() }

        let row = try XCTUnwrap(
            descendants(in: root).first {
                $0.accessibilityRole() == .menuItem && $0.accessibilityTitle() == "Cyberpunk"
            }
        )
        let target = windowCentre(of: row)
        popUp.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: target, in: window))
        popUp.mouseUp(with: try mouseEvent(.leftMouseUp, at: target, in: window))

        XCTAssertEqual(popUp.selectedItem?.title, "Cyberpunk")
        XCTAssertFalse(
            descendants(in: root).contains { $0.accessibilityRole() == .menu },
            "the release chose a row, so the menu should have closed"
        )
    }

    /// Releasing the held press back on the control is the ordinary click-to-open: the menu
    /// stays for browsing rather than reading the release as a choice or a dismissal.
    func testAHeldPressReleasedOnTheSourceLeavesTheMenuOpen() throws {
        let (window, root, popUp) = try openedPopUp(titles: ["System", "Cyberpunk"])
        defer { window.close() }

        let onControl = windowCentre(of: popUp)
        popUp.mouseUp(with: try mouseEvent(.leftMouseUp, at: onControl, in: window))

        XCTAssertTrue(
            descendants(in: root).contains { $0.accessibilityRole() == .menu },
            "releasing on the control dismissed the menu it had just opened"
        )
        XCTAssertEqual(popUp.selectedItem?.title, "System", "a release on the control chose")
    }

    /// A press dragged off the menu and released over nothing lets the menu go, the way a
    /// held `NSMenu` closes when the press ends outside it.
    func testAHeldPressReleasedOutsideLetsTheMenuGo() throws {
        let (window, root, source) = try menuHarness()
        defer { window.close() }

        var dismissed = false
        let token = try XCTUnwrap(present(from: source, onDismiss: { dismissed = true }))
        defer { ThemedMenuPresenter.dismiss(token) }
        layOutMenu(in: root)

        ThemedMenuPresenter.dragEnded(
            token,
            event: try mouseEvent(.leftMouseUp, at: NSPoint(x: 2, y: 2), in: window)
        )

        XCTAssertTrue(dismissed, "an outside release did not let the menu go")
        XCTAssertFalse(descendants(in: root).contains { $0.accessibilityRole() == .menu })
    }

    // MARK: - Type-To-Filter

    /// Typing narrows the menu: the highlight lands on the first match and Return chooses it.
    /// The rows keep their places — a filter dims non-matches rather than reflowing the panel.
    func testTypingFiltersAndReturnChoosesTheFirstMatch() throws {
        let (window, root, source) = try menuHarness()
        defer { window.close() }

        var chosen: String?
        let token = try XCTUnwrap(ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [
                    .item(ThemedMenuItem(title: "System")),
                    .item(ThemedMenuItem(title: "Cyberpunk")),
                    .item(ThemedMenuItem(title: "Swiss"))
                ],
                minimumWidth: source.bounds.width
            ),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, item in chosen = item.title },
            onDismiss: {}
        ))
        defer { ThemedMenuPresenter.dismiss(token) }

        let responder = try XCTUnwrap(window.firstResponder)
        responder.keyDown(with: try keyEvent("s", keyCode: 1))
        responder.keyDown(with: try keyEvent("w", keyCode: 13))
        responder.keyDown(with: try keyEvent("\r", keyCode: 36))

        XCTAssertEqual(chosen, "Swiss")
        XCTAssertFalse(
            descendants(in: root).contains { $0.accessibilityRole() == .menu },
            "Return on the filtered highlight left the menu open"
        )
    }

    /// Escape backs out one layer at a time: the first press clears a live filter, and only
    /// the second lets the menu go — a half-typed query should not cost the menu too.
    func testEscapeClearsTheFilterBeforeClosingTheMenu() throws {
        let (window, root, source) = try menuHarness()
        defer { window.close() }

        var dismissed = false
        let token = try XCTUnwrap(present(from: source, onDismiss: { dismissed = true }))
        defer { ThemedMenuPresenter.dismiss(token) }

        let responder = try XCTUnwrap(window.firstResponder)
        responder.keyDown(with: try keyEvent("f", keyCode: 3))

        let echo = try XCTUnwrap(
            descendants(in: root).compactMap { $0 as? NSTextField }
                .first { $0.stringValue.hasPrefix("Filter:") },
            "typing showed no filter echo"
        )
        XCTAssertFalse(echo.isHidden)

        responder.keyDown(with: try keyEvent("\u{1b}", keyCode: 53))
        XCTAssertFalse(dismissed, "escape closed the menu instead of clearing the filter")
        XCTAssertTrue(echo.isHidden, "clearing the filter left its echo up")

        responder.keyDown(with: try keyEvent("\u{1b}", keyCode: 53))
        XCTAssertTrue(dismissed, "escape with no filter should let the menu go")
    }

    /// A pop-up whose menu is already open, laid out, and ready for the drag lookups.
    private func openedPopUp(titles: [String]) throws -> (NSWindow, NSView, ThemedPopUp) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        let popUp = ThemedPopUp(frame: NSRect(x: 24, y: 180, width: 140, height: 26))
        for title in titles { popUp.addItem(withTitle: title) }
        root.addSubview(popUp)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root

        XCTAssertTrue(popUp.accessibilityPerformShowMenu())
        layOutMenu(in: root)
        return (window, root, popUp)
    }

    /// The drag lookup reads row frames, which only a layout pass assigns; a test window never
    /// displays, so the pass is run by hand.
    private func layOutMenu(in root: NSView) {
        for view in [root] + descendants(in: root) { view.needsLayout = true }
        root.layoutSubtreeIfNeeded()
    }

    private func windowCentre(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }

    private func auxiliaryMouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        buttonNumber: UInt32 = 2
    ) throws -> NSEvent {
        let cgType: CGEventType
        switch type {
        case .otherMouseDown:
            cgType = .otherMouseDown
        case .otherMouseDragged:
            cgType = .otherMouseDragged
        case .otherMouseUp:
            cgType = .otherMouseUp
        default:
            XCTFail("Not an auxiliary mouse event: \(type)")
            cgType = .otherMouseDown
        }

        // Quartz uses a top-left display origin while AppKit reports window points bottom-up.
        // The test event has no real window, so mirror the point here to make
        // `event.locationInWindow` equal the point the fixture asked for.
        let displayHeight = CGDisplayBounds(CGMainDisplayID()).height
        let quartzPoint = CGPoint(x: point.x, y: displayHeight - point.y)
        let button = try XCTUnwrap(CGMouseButton(rawValue: buttonNumber))
        let cgEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: cgType,
            mouseCursorPosition: quartzPoint,
            mouseButton: button
        ))
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }

    private func menuHarness() throws -> (NSWindow, NSView, NSView) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        let source = NSView(frame: NSRect(x: 24, y: 180, width: 140, height: 26))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        return (window, root, source)
    }

    private func present(
        from source: NSView,
        onDismiss: @escaping () -> Void = {}
    ) -> AnyObject? {
        ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [
                    .item(ThemedMenuItem(title: "First", isSelected: true)),
                    .item(ThemedMenuItem(title: "Second"))
                ],
                minimumWidth: source.bounds.width
            ),
            from: source,
            selectedEntryIndex: 0,
            onChoose: { _, _ in },
            onDismiss: onDismiss
        )
    }

    // MARK: - Pop-Up Theming

    /// A stock `NSPopUpButton` draws the system bezel whatever the theme is. This one lays down
    /// the theme's own `controlResting`, which is what makes a control read as part of a style
    /// rather than as an AppKit control sitting inside one.
    ///
    /// Compared against the role itself rather than against a hue: the fill used to be asserted
    /// *green*, because Cyberpunk happened to hold its neon accent down there, and rebuilding
    /// that theme against its reference then broke a test about pop-ups. What the pop-up owes the
    /// theme is the colour the theme states, whatever colour that is.
    ///
    /// Sampled from the control's own drawing rather than from a composited page, and the
    /// channels are compared *over white*: a 5%-alpha fill is worth a step or two of an 8-bit
    /// channel, so its raw components quantise far too coarsely to compare directly, while the
    /// composite they actually produce does not.
    func testThePopUpFillTakesTheThemeSurface() throws {
        func drawnFill(under theme: AppTheme) throws -> (drawn: NSColor, role: NSColor) {
            AppThemePalette.set(theme)
            let popUp = ThemedPopUp(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
            let rep = try XCTUnwrap(popUp.bitmapImageRepForCachingDisplay(in: popUp.bounds))
            popUp.cacheDisplay(in: popUp.bounds, to: rep)
            // Inside the fill, clear of the border, the chevron and any title.
            return (
                try XCTUnwrap(rep.colorAt(x: 60, y: 13)?.usingColorSpace(.sRGB)),
                try XCTUnwrap(Design.Surface.controlResting.usingColorSpace(.sRGB))
            )
        }

        func overWhite(_ color: NSColor) -> [CGFloat] {
            let alpha = color.alphaComponent
            return [color.redComponent, color.greenComponent, color.blueComponent]
                .map { $0 * alpha + (1 - alpha) }
        }

        for theme in [AppThemeStyles.cyberpunk, AppThemeStyles.swissMinimalist] {
            let (drawn, role) = try drawnFill(under: theme)

            XCTAssertEqual(
                drawn.alphaComponent,
                role.alphaComponent,
                accuracy: 0.01,
                "\(theme.name)'s pop-up did not lay its control fill down at the theme's weight"
            )
            for (drawnChannel, roleChannel) in zip(overWhite(drawn), overWhite(role)) {
                XCTAssertEqual(
                    drawnChannel,
                    roleChannel,
                    accuracy: 0.01,
                    "\(theme.name)'s pop-up is not drawn in its own control colour"
                )
            }
        }
    }

    /// The other half of a style's identity is its silhouette. Swiss squares every corner, so the
    /// pop-up's corner is filled; a rounded theme leaves it empty. A stock control would round
    /// both.
    func testThePopUpCornerFollowsTheThemeSilhouette() {
        func cornerAlpha(under theme: AppTheme) -> CGFloat {
            AppThemePalette.set(theme)
            let popUp = ThemedPopUp(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
            let rep = popUp.bitmapImageRepForCachingDisplay(in: popUp.bounds)!
            popUp.cacheDisplay(in: popUp.bounds, to: rep)
            return rep.colorAt(x: 0, y: 0)!.alphaComponent
        }

        XCTAssertEqual(cornerAlpha(under: AppThemeStyles.swissMinimalist), 1, accuracy: 0.05,
                       "a square theme did not fill the pop-up's corner")
        XCTAssertLessThan(cornerAlpha(under: .system), 0.5,
                          "a rounded theme filled the pop-up's corner")
    }
    // MARK: - Button

    func testAButtonPaintsTheThemesActionCaseTrackingAndWeightWithoutRenamingIt() {
        AppThemePalette.set(AppThemeStyles.bauhaus)
        let button = ThemedButton(title: "Start", target: nil, action: nil)
        let empty = ThemedButton(title: "", target: nil, action: nil)
        let style = AppThemeStyles.bauhaus.material.buttonStyle
        let expectedTitleWidth = ceil(
            ("START" as NSString).size(withAttributes: [
                .font: Design.Typography.control(weight: style.fontWeight.appKitWeight),
                .kern: style.tracking
            ]).width
        )

        XCTAssertEqual(
            button.intrinsicContentSize.width - empty.intrinsicContentSize.width,
            expectedTitleWidth,
            accuracy: 0.5,
            "the button did not measure the same transformed title it paints"
        )
        XCTAssertEqual(
            button.accessibilityTitle(),
            "Start",
            "a display convention leaked into the button's accessible name"
        )
    }

    func testOutlinedAndFilledPrimaryTreatmentsProduceDifferentSurfaces() throws {
        func interiorAlpha(under theme: AppTheme) throws -> CGFloat {
            AppThemePalette.set(theme)
            let button = ThemedButton(title: "Go", target: nil, action: nil)
            button.isProminent = true
            button.frame = NSRect(x: 0, y: 0, width: 120, height: 26)
            let rep = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / button.bounds.width
            return try XCTUnwrap(
                rep.colorAt(x: Int(12 * scale), y: Int(button.bounds.midY * scale))
            ).alphaComponent
        }

        XCTAssertLessThan(
            try interiorAlpha(under: AppThemeStyles.artDeco),
            0.1,
            "Art Deco's reference-outline action was filled"
        )
        XCTAssertGreaterThan(
            try interiorAlpha(under: AppThemeStyles.neoBrutalism),
            0.9,
            "Neo Brutalism's reference-filled action became transparent"
        )
    }

    func testWindows98ControlsPaintNativeFieldsDropdownsAndDefaultButtons() throws {
        AppThemePalette.set(AppThemeStyles.win98)

        let prompt = PromptView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        let promptCG = try XCTUnwrap(prompt.layer?.backgroundColor)
        let promptFill = try XCTUnwrap(NSColor(cgColor: promptCG))
        XCTAssertEqual(promptFill.usingColorSpace(.sRGB)?.hexString, "#FFFFFF")

        let chip = ChipView(frame: NSRect(x: 0, y: 0, width: 160, height: 26))
        chip.configure(symbolName: "folder", title: "")
        chip.layoutSubtreeIfNeeded()
        let chipRep = try XCTUnwrap(chip.bitmapImageRepForCachingDisplay(in: chip.bounds))
        chip.cacheDisplay(in: chip.bounds, to: chipRep)
        assertRGB(
            try colour(of: chipRep, at: NSPoint(x: 30, y: 13), in: chip),
            equals: NSColor(hex: "#FFFFFF")!,
            message: "the combo value well did not stay white"
        )
        assertRGB(
            try colour(of: chipRep, at: NSPoint(x: 145, y: 6), in: chip),
            equals: NSColor(hex: "#C0C0C0")!,
            message: "the combo arrow was not its own button-face control"
        )

        let button = ThemedButton(title: "", target: nil, action: nil)
        button.isProminent = true
        button.frame = NSRect(x: 0, y: 0, width: 100, height: 26)
        let buttonRep = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: buttonRep)
        assertRGB(
            try colour(of: buttonRep, at: NSPoint(x: 50, y: 13), in: button),
            equals: NSColor(hex: "#C0C0C0")!,
            message: "the default action remained a modern accent-filled button"
        )
        assertRGB(
            try colour(of: buttonRep, at: NSPoint(x: 0, y: 13), in: button),
            equals: NSColor(hex: "#000000")!,
            message: "the default action lost its classic outer frame"
        )
    }

    /// A pressable control has to behave like `NSButton` at the call sites it replaces: a click
    /// inside fires once, and a click that wanders off before releasing fires not at all.
    func testAButtonFiresOnAClickAndNotOnAClickDraggedAway() {
        let button = ThemedButton(frame: NSRect(x: 0, y: 0, width: 80, height: 26))
        let target = ActionSpy()
        button.target = target
        button.action = #selector(ActionSpy.fire)

        button.mouseDown(with: .init())
        button.mouseUp(with: .init())
        XCTAssertEqual(target.count, 1, "a click did not fire the action")

        button.mouseDown(with: .init())
        button.mouseDragged(with: .init())   // a synthesised event reports (0, 0) in window space
        button.mouseUp(with: .init())
        XCTAssertEqual(target.count, 2, "the second click inside the bounds did not fire")
    }

    /// And it keeps firing when the view it lives in is torn down mid-click.
    ///
    /// `ThemedButton` is what an *extension* contributes into a sidebar row — see
    /// `ExtensionNodeRenderer` — and a sidebar row is handed back to the reuse pool whenever the
    /// tree's shape changes. So it needs the same guarantee `ThemedIconButton` gives the row's own
    /// archive button, for the same reason: AppKit routes a mouse-up to the view that took the
    /// mouse-down and to no other, and delivers nothing at all once that view is detached.
    func testAButtonCompletesItsClickEvenWhenItsViewIsTornDownFirst() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = try XCTUnwrap(window.contentView)

        let target = ActionSpy()
        let button = ThemedButton(title: "Run", target: target, action: #selector(ActionSpy.fire))
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 40, y: 20, width: 80, height: 26)
        root.addSubview(button)

        let inside = NSPoint(x: button.frame.midX, y: button.frame.midY)
        let outside = NSPoint(x: button.frame.maxX + 40, y: button.frame.midY)

        button.mouseDown(with: try mouseEvent(.leftMouseDown, at: inside, in: window))
        button.removeFromSuperview()
        NSApp.sendEvent(try mouseEvent(.leftMouseUp, at: inside, in: window))
        XCTAssertEqual(target.count, 1, "an extension's button died with the row that held it")

        // And the same teardown released away from it still cancels.
        root.addSubview(button)
        button.mouseDown(with: try mouseEvent(.leftMouseDown, at: inside, in: window))
        button.removeFromSuperview()
        NSApp.sendEvent(try mouseEvent(.leftMouseUp, at: outside, in: window))
        XCTAssertEqual(target.count, 1, "a click released away from the button fired anyway")
    }

    func testButtonCanBeReachedAndActivatedWithoutAPointer() throws {
        let target = ActionSpy()
        let button = ThemedButton(title: "Continue", target: target, action: #selector(ActionSpy.fire))

        XCTAssertTrue(button.acceptsFirstResponder)
        XCTAssertTrue(button.isAccessibilityEnabled())

        button.keyDown(with: try keyEvent("\r", keyCode: 36))
        XCTAssertEqual(target.count, 1)

        button.isEnabled = false
        XCTAssertFalse(button.acceptsFirstResponder)
        XCTAssertFalse(button.isAccessibilityEnabled())
        XCTAssertFalse(button.accessibilityPerformPress())
    }

    func testTabItemSharesSelectionSemanticsAcrossKeyboardAndAccessibility() throws {
        let tab = ThemedTabItemView(
            title: "Browser",
            symbolName: "globe",
            placement: .horizontal,
            inkSource: .chrome
        )
        var selections = 0
        tab.onSelect = { selections += 1 }

        XCTAssertEqual(tab.accessibilityRole(), .radioButton)
        XCTAssertEqual(tab.accessibilityTitle(), "Browser")
        XCTAssertEqual(tab.accessibilityValue() as? Bool, false)

        tab.keyDown(with: try keyEvent("\r", keyCode: 36))
        XCTAssertEqual(selections, 1)

        tab.isSelected = true
        XCTAssertEqual(tab.accessibilityValue() as? Bool, true)
    }

    func testMiddleClickClosesATabOnReleaseWithoutSelectingIt() throws {
        let tab = ThemedTabItemView(
            title: "Browser",
            symbolName: "globe",
            placement: .horizontal,
            showsClose: true,
            inkSource: .chrome
        )
        tab.translatesAutoresizingMaskIntoConstraints = true
        tab.frame = NSRect(x: 30, y: 20, width: 180, height: Design.Size.tabHeight)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(tab)

        var selections = 0
        var closes = 0
        tab.onSelect = { selections += 1 }
        tab.onClose = { closes += 1 }

        let inside = NSPoint(x: tab.frame.midX, y: tab.frame.midY)
        let down = try auxiliaryMouseEvent(.otherMouseDown, at: inside)
        let up = try auxiliaryMouseEvent(.otherMouseUp, at: inside)
        XCTAssertEqual(down.buttonNumber, 2, "the fixture did not create a middle-button event")

        tab.otherMouseDown(with: down)
        XCTAssertEqual(closes, 0, "middle click closed before the release")
        tab.otherMouseUp(with: up)

        XCTAssertEqual(closes, 1)
        XCTAssertEqual(selections, 0, "closing an inactive tab selected it first")
    }

    func testDraggingAMiddleClickOffTheTabCancelsTheClose() throws {
        let tab = ThemedTabItemView(
            title: "Browser",
            symbolName: "globe",
            placement: .horizontal,
            showsClose: true,
            inkSource: .chrome
        )
        tab.translatesAutoresizingMaskIntoConstraints = true
        tab.frame = NSRect(x: 30, y: 20, width: 180, height: Design.Size.tabHeight)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(tab)

        var closes = 0
        tab.onClose = { closes += 1 }

        let inside = NSPoint(x: tab.frame.midX, y: tab.frame.midY)
        let outside = NSPoint(x: tab.frame.midX, y: tab.frame.maxY + Design.Spacing.large)
        tab.otherMouseDown(
            with: try auxiliaryMouseEvent(.otherMouseDown, at: inside)
        )
        tab.otherMouseDragged(
            with: try auxiliaryMouseEvent(.otherMouseDragged, at: outside)
        )
        tab.otherMouseUp(
            with: try auxiliaryMouseEvent(.otherMouseUp, at: outside)
        )

        XCTAssertEqual(closes, 0)
    }

    func testAuxiliaryButtonsBeyondMiddleDoNotCloseATab() throws {
        let tab = ThemedTabItemView(
            title: "Browser",
            symbolName: "globe",
            placement: .horizontal,
            showsClose: true,
            inkSource: .chrome
        )
        tab.frame = NSRect(x: 0, y: 0, width: 180, height: Design.Size.tabHeight)

        var closes = 0
        tab.onClose = { closes += 1 }
        let inside = NSPoint(x: tab.bounds.midX, y: tab.bounds.midY)

        tab.otherMouseDown(
            with: try auxiliaryMouseEvent(.otherMouseDown, at: inside, buttonNumber: 3)
        )
        tab.otherMouseUp(
            with: try auxiliaryMouseEvent(.otherMouseUp, at: inside, buttonNumber: 3)
        )

        XCTAssertEqual(closes, 0, "a navigation mouse button was mistaken for the middle button")
    }

    func testAnOffsetTabItemReceivesPointerHitTesting() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let tab = ThemedTabItemView(
            title: "Accounts",
            symbolName: "person.2",
            placement: .sidebar,
            inkSource: .chrome
        )
        tab.frame = NSRect(x: 28, y: 92, width: 240, height: Design.Size.sidebarTabHeight)
        root.addSubview(tab)

        let hit = root.hitTest(NSPoint(x: tab.frame.midX, y: tab.frame.midY))

        XCTAssertTrue(hit === tab, "an offset sidebar tab dropped a click inside its bounds")
    }

    func testToolbarButtonIsKeyboardReachableAndReportsSelectedState() throws {
        let button = ThemedIconButton(
            symbolName: "sidebar.trailing",
            accessibility: "Display panel"
        )
        var presses = 0
        button.onPress = { presses += 1 }

        XCTAssertTrue(button.acceptsFirstResponder)
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityTitle(), "Display panel")

        button.keyDown(with: try keyEvent(" ", keyCode: 49))
        XCTAssertEqual(presses, 1)

        button.isSelected = true
        XCTAssertEqual(button.accessibilityValue() as? Bool, true)
    }

    /// An icon button that performs an action still acts on the release, and lets go of the press
    /// when the pointer leaves it — the change-your-mind affordance `ThemedButton` has always had
    /// and this one did not. Without it the press was decided at the release and shown nowhere: a
    /// slip off a 20-point target cancelled silently, leaving the button drawn as though held.
    ///
    /// Only a button that opens a *menu* acts on the press; see `presentsMenu`.
    func testAnActionIconButtonActsOnTheReleaseAndLetsGoWhenTheDragLeavesIt() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = try XCTUnwrap(window.contentView)

        let button = ThemedIconButton(symbolName: "archivebox", accessibility: "Archive")
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 40, y: 20, width: Design.Size.inlineButtonTarget, height: Design.Size.inlineButtonTarget)
        root.addSubview(button)

        var presses = 0
        button.onPress = { presses += 1 }

        let inside = NSPoint(x: button.frame.midX, y: button.frame.midY)
        let outside = NSPoint(x: button.frame.maxX + 30, y: button.frame.midY)

        button.mouseDown(with: try mouseEvent(.leftMouseDown, at: inside, in: window))
        XCTAssertEqual(presses, 0, "an action button fired before it was released")

        button.mouseUp(with: try mouseEvent(.leftMouseUp, at: inside, in: window))
        XCTAssertEqual(presses, 1)

        button.mouseDown(with: try mouseEvent(.leftMouseDown, at: inside, in: window))
        button.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: outside, in: window))
        button.mouseUp(with: try mouseEvent(.leftMouseUp, at: outside, in: window))
        XCTAssertEqual(presses, 1, "a press released off the button still fired")
    }

    /// A press outlives the view that took it.
    ///
    /// The third report about this family of buttons, after the `⋯`'s hit testing and its lost
    /// release. AppKit routes a mouse-up to the view that took the mouse-down and to no other, and
    /// delivers nothing at all when that view has been detached in between — which is exactly what
    /// the sidebar does to every row it hands back to the reuse pool. The `⋯` escaped it by opening
    /// its menu on the press; an action button cannot, because acting on the press is the wrong
    /// gesture for an action and gives up the drag-out-to-cancel affordance above. So the release
    /// is read from the event stream instead of waited for at this view.
    ///
    /// Asserted at the component rather than at the archive button, because that is what makes it
    /// true of a button a row grows later — an extension's, or ours — without that button's author
    /// having to know any of this.
    func testAnActionIconButtonCompletesItsPressEvenWhenItsViewIsTornDownFirst() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = try XCTUnwrap(window.contentView)

        let button = ThemedIconButton(symbolName: "archivebox", accessibility: "Archive")
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(
            x: 40,
            y: 20,
            width: Design.Size.inlineButtonTarget,
            height: Design.Size.inlineButtonTarget
        )
        root.addSubview(button)

        var presses = 0
        button.onPress = { presses += 1 }

        let inside = NSPoint(x: button.frame.midX, y: button.frame.midY)
        button.mouseDown(with: try mouseEvent(.leftMouseDown, at: inside, in: window))

        // What `reloadData()` does to a row under the pointer: the view that took the press is no
        // longer in the hierarchy, so AppKit has nowhere to route the release.
        button.removeFromSuperview()

        NSApp.sendEvent(try mouseEvent(.leftMouseUp, at: inside, in: window))
        XCTAssertEqual(presses, 1, "the press died with the view that took it")
    }

    /// The same teardown, released *off* the button: the change-your-mind affordance survives too,
    /// so the fix above cannot become "a detached button fires on any release anywhere".
    func testAPressAbandonedOffTheButtonStillDoesNotFireAfterATeardown() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = try XCTUnwrap(window.contentView)

        let button = ThemedIconButton(symbolName: "archivebox", accessibility: "Archive")
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(
            x: 40,
            y: 20,
            width: Design.Size.inlineButtonTarget,
            height: Design.Size.inlineButtonTarget
        )
        root.addSubview(button)

        var presses = 0
        button.onPress = { presses += 1 }

        let inside = NSPoint(x: button.frame.midX, y: button.frame.midY)
        let outside = NSPoint(x: button.frame.maxX + 30, y: button.frame.midY)

        button.mouseDown(with: try mouseEvent(.leftMouseDown, at: inside, in: window))
        button.removeFromSuperview()

        NSApp.sendEvent(try mouseEvent(.leftMouseUp, at: outside, in: window))
        XCTAssertEqual(presses, 0, "a press released away from the button fired anyway")
    }

    // MARK: - Hover

    /// The pane toggle sat filled with the panel closed, and the fill was a hover nobody had
    /// left: closing the panel widens the content pane, which slides its header — and this button
    /// with it — a few hundred points sideways, out from under a pointer that never moved. A
    /// tracking area reports pointer crossings only, so no `mouseExited` was ever delivered, and
    /// on a toolbar button a resting hover wears the same `surface` fill as *selected*. The button
    /// was claiming the panel was open.
    ///
    /// Both directions matter. Clearing on every relayout would be just as wrong the other way —
    /// the pointer resting on a button while a theme change or a morphing title re-lays the header
    /// out would drop the hover under the pointer — so the correction is asked of the pointer's
    /// actual position rather than applied blindly.
    func testHoverEndsWhenTheControlLeavesTheStillPointerRatherThanTheOtherWayAround() throws {
        let window = PointerFixtureWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let root = try XCTUnwrap(window.contentView)
        let button = ThemedIconButton(symbolName: "sidebar.trailing", accessibility: "Display panel")
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(
            x: 400,
            y: 40,
            width: Design.Size.toolbarButtonWidth,
            height: Design.Size.toolbarButtonHeight
        )
        root.addSubview(button)

        window.pointerLocation = NSPoint(x: button.frame.midX, y: button.frame.midY)
        button.mouseEntered(with: try enterEvent(at: window.pointerLocation, in: window))
        XCTAssertTrue(button.isHovered, "the button did not take the pointer")

        // The header re-lays out with the pointer still on the button: a redraw, not a departure.
        button.updateTrackingAreas()
        XCTAssertTrue(
            button.isHovered,
            "a relayout under a stationary pointer dropped a hover the pointer had not left"
        )

        // The panel closes: the pane grows, the header slides, the pointer stays where it was.
        button.frame = button.frame.offsetBy(dx: -260, dy: 0)
        button.updateTrackingAreas()
        XCTAssertFalse(
            button.isHovered,
            "the button kept its hover fill after moving out from under the pointer"
        )
    }

    /// The same correction, on a control whose hover is a layer fill and a width rather than a
    /// drawn state — `hoverDidChange` is the seam, so the chip must narrow again too.
    func testAChipThatSlidesOutFromUnderThePointerGivesBackItsHoverWidth() throws {
        let window = PointerFixtureWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let root = try XCTUnwrap(window.contentView)
        let chip = ChipView(frame: NSRect(x: 300, y: 40, width: 120, height: Design.Size.chipHeight))
        chip.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(chip)

        window.pointerLocation = NSPoint(x: chip.frame.midX, y: chip.frame.midY)
        chip.mouseEntered(with: try enterEvent(at: window.pointerLocation, in: window))
        XCTAssertTrue(chip.isHovered)

        // Sideways, and still well inside the window: a control that left the window entirely
        // would clear for a second reason and prove nothing about this one.
        chip.frame = chip.frame.offsetBy(dx: -220, dy: 0)
        chip.updateTrackingAreas()
        XCTAssertFalse(chip.isHovered, "the chip stayed hovered after sliding out from under the pointer")
    }

    /// The window is a row of panes, and nothing else here would have noticed if it stopped
    /// being one.
    ///
    /// `NSSplitViewController` configures the split view it builds for itself; handing it one of
    /// ours inherits `NSSplitView`'s defaults instead, and `isVertical` defaults to *false* —
    /// which laid the sidebar out as a band across the top of the window with the terminal under
    /// it. Every other test passed, because a stacked layout is a perfectly valid layout.
    func testTheWindowLaysItsPanesOutSideBySide() throws {
        let controller = MainWindowController()
        let splitView = controller.splitViewController.splitView

        XCTAssertTrue(
            splitView.isVertical,
            "the window's panes stacked instead of sitting side by side"
        )
        XCTAssertEqual(
            splitView.dividerStyle,
            .thin,
            "the divider between panes went back to the thick style"
        )

        // Side by side means the split view puts its second pane to the *right* of its first,
        // not under it. Asked of the arranged subviews, which are what the split view actually
        // positions, and after a layout — an unlaid window leaves every pane at the origin,
        // where the check would pass or fail on nothing.
        controller.window?.setContentSize(NSSize(width: 1200, height: 700))
        splitView.layoutSubtreeIfNeeded()

        let panes = splitView.arrangedSubviews
        XCTAssertGreaterThanOrEqual(panes.count, 2, "the window lost a pane")
        XCTAssertLessThanOrEqual(
            panes[0].frame.maxX,
            panes[1].frame.minX + splitView.dividerThickness,
            "the sidebar is no longer beside the session pane"
        )
        XCTAssertEqual(
            panes[0].frame.minY,
            panes[1].frame.minY,
            "the panes are at different heights, so they are stacked rather than side by side"
        )
    }

    /// The toolbar holds only the controls that are the *window's*.
    ///
    /// A toolbar lays its items out against the window, so anything in it describing a pane
    /// drifts away from that pane the moment a divider moves — which is exactly what happened
    /// when `NSTrackingSeparatorToolbarItem` stopped tracking a non-sidebar split item. The
    /// sidebar toggle stays because it acts on the split rather than on either side of it; the
    /// selection-history pair stays because it retraces the window's page selection.
    func testWindowToolbarHoldsOnlyTheWindowsOwnControls() throws {
        let controller = MainWindowController()
        let items = try XCTUnwrap(controller.window?.toolbar?.items)

        XCTAssertEqual(
            items.map(\.itemIdentifier),
            [.threadingToggleSidebar, .threadingNavigation],
            "a toolbar item describing a pane cannot stay aligned with it — move it to the header"
        )
        XCTAssertTrue(
            items[0].view is ThemedIconButton,
            "the sidebar toggle still uses system toolbar chrome"
        )
        XCTAssertTrue(
            items[1].view is ToolbarButtonGroupView,
            "the history pair travels as one grouped item, spaced by our rules not NSToolbar's"
        )
    }

    func testPaneHeaderCarriesThePageItsActionsAndTracksPaneState() throws {
        let controller = MainWindowController()
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.window?.setContentSize(NSSize(width: 1200, height: 700))
        root.layoutSubtreeIfNeeded()

        let all = descendants(in: root)
        let tab = controller.pageTabView
        XCTAssertTrue(
            tab.isDescendant(of: root),
            "the page tab is not in the window's content — it is still a toolbar item"
        )
        let header = try XCTUnwrap(tab.superview as? NSStackView)

        // Reading across: which page, then a way to open another. Adjacency is the claim; the
        // gap between them is the stack's.
        let arranged = header.arrangedSubviews
        let tabIndex = try XCTUnwrap(arranged.firstIndex(of: tab))
        XCTAssertTrue(
            arranged[tabIndex + 1] is ThemedIconButton,
            "New Session must remain directly after the active page tab"
        )

        // The session's five actions travel as one group, so the row cannot space them as
        // unrelated controls. Found through the Context button rather than by taking the first
        // group in the row: the header carries a second one — the "Open in" pair — and "the
        // first group" silently became that the day it was added.
        let context = try XCTUnwrap(controller.sessionContextToolbarButton)
        let group = try XCTUnwrap(
            all.compactMap { $0 as? ToolbarButtonGroupView }
                .first { context.isDescendant(of: $0) }
        )
        XCTAssertEqual(
            descendants(in: group).compactMap { $0 as? ThemedIconButton }.count,
            5,
            "the session actions group lost one of its buttons"
        )

        XCTAssertEqual(controller.displayPaneToolbarButton?.isSelected, false)
        controller.toggleDisplayPane()
        XCTAssertEqual(controller.displayPaneToolbarButton?.isSelected, true)
        controller.toggleDisplayPane()
        XCTAssertEqual(controller.displayPaneToolbarButton?.isSelected, false)
    }

    /// A full-size-content window reports a zero-height safe area for one layout pass while its
    /// toolbar is attaching. If both this equality and the header's 40pt floor are required,
    /// AppKit logs an unsatisfiable-constraints failure on every launch before settling on the
    /// exact same geometry. The equality must yield only during that transient pass.
    func testPaneHeaderSafeAreaConstraintYieldsDuringWindowAttachment() throws {
        let controller = MainWindowController()
        let root = try XCTUnwrap(controller.window?.contentView)
        let tab = controller.pageTabView
        XCTAssertTrue(tab.isDescendant(of: root))
        let headerHost = try XCTUnwrap(tab.superview?.superview)
        let pane = try XCTUnwrap(headerHost.superview)

        let safeAreaConstraint = try XCTUnwrap(
            pane.constraints.first { constraint in
                constraint.firstItem as AnyObject === headerHost
                    && constraint.firstAttribute == .bottom
                    && constraint.secondItem as AnyObject === pane.safeAreaLayoutGuide
                    && constraint.secondAttribute == .top
            },
            "the pane header is no longer tied to the toolbar safe area"
        )

        XCTAssertEqual(safeAreaConstraint.priority.rawValue, 999)
    }

    /// The header is the pane's, which is the whole reason it moved out of the toolbar: it is
    /// laid out against the pane's leading edge, so a divider drag carries it along instead of
    /// sliding the sidebar out from under it.
    func testPaneHeaderStaysInsideTheContentPaneWhenTheSidebarWidens() throws {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1200, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()

        let split = controller.splitView
        let tab = try XCTUnwrap(
            descendants(in: try XCTUnwrap(window.contentView))
                .compactMap { $0 as? ThemedIconButton }
                .first { $0 === controller.newSessionButton }
        )

        func tabLeadsThePane() -> Bool {
            let panes = split.arrangedSubviews
            guard panes.count >= 2 else { return false }
            let contentPane = panes[1]
            let tabInWindow = tab.convert(tab.bounds, to: nil)
            let paneInWindow = contentPane.convert(contentPane.bounds, to: nil)
            return tabInWindow.minX >= paneInWindow.minX
                && tabInWindow.maxX <= paneInWindow.maxX
        }

        XCTAssertTrue(tabLeadsThePane(), "the header starts outside its own pane")

        split.setPosition(360, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            tabLeadsThePane(),
            "the header did not follow the divider — this is the bug the move exists to remove"
        )
    }

    /// Pairing is a journey with live state and security context, not an obscure General toggle.
    /// Its own catalogue entry is the discoverability contract; the identifiers keep the setup
    /// accessible to both UI tests and assistive tooling.
    func testRemoteAccessHasADiscoverableSetupPage() throws {
        let definition = try XCTUnwrap(SettingsPages.page(id: SettingsPages.remoteAccessID))
        XCTAssertEqual(definition.title, "Remote Access")
        XCTAssertTrue(
            SettingsPages.sidebarItems.contains { $0.id == SettingsPages.remoteAccessID },
            "Remote Access is still hidden inside another settings page"
        )

        let controller = definition.make()
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: SettingsUIDefaults.pageWidth,
            height: 760
        )
        controller.view.layoutSubtreeIfNeeded()

        let ids = Set(
            ([controller.view] + descendants(in: controller.view))
                .compactMap { $0.accessibilityIdentifier() }
        )
        XCTAssertTrue(ids.contains("settings.remote-access.page"))
        XCTAssertTrue(ids.contains("settings.remote-access.enabled"))
        XCTAssertTrue(ids.contains("settings.remote-access.connection-mode"))
        XCTAssertTrue(ids.contains("settings.remote-access.owner-relay-fallback"))
        XCTAssertTrue(ids.contains("settings.remote-access.keep-relay-ready"))
        XCTAssertTrue(ids.contains("settings.remote-access.input-control-default"))
        XCTAssertTrue(ids.contains("settings.remote-access.status"))
        XCTAssertTrue(ids.contains("settings.remote-access.pair"))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }

    func testRemoteAccessSetupPageRendersInBothAppearances() throws {
        let previousMode = AppSettings.shared.remoteAccessConnectionMode
        let previousEnabled = AppSettings.shared.remoteAccessEnabled
        let previousFallback = AppSettings.shared.remoteAccessAllowsOwnerRelayFallback
        let previousKeepReady = AppSettings.shared.remoteAccessKeepsRelayReady
        AppSettings.shared.remoteAccessConnectionMode = .tailscaleAndRelay
        AppSettings.shared.remoteAccessEnabled = false
        AppSettings.shared.remoteAccessAllowsOwnerRelayFallback = false
        AppSettings.shared.remoteAccessKeepsRelayReady = false
        defer {
            AppSettings.shared.remoteAccessConnectionMode = previousMode
            AppSettings.shared.remoteAccessEnabled = previousEnabled
            AppSettings.shared.remoteAccessAllowsOwnerRelayFallback = previousFallback
            AppSettings.shared.remoteAccessKeepsRelayReady = previousKeepReady
        }
        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let output {
            try FileManager.default.createDirectory(
                at: output,
                withIntermediateDirectories: true
            )
        }

        for (name, appearanceName) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", .darkAqua)
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var png: Data?
            appearance.performAsCurrentDrawingAppearance {
                let controller = RemoteAccessPreferencesViewController()
                let host = NSView(frame: NSRect(
                    x: 0,
                    y: 0,
                    width: SettingsUIDefaults.pageWidth,
                    height: 920
                ))
                controller.view.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(controller.view)
                NSLayoutConstraint.activate([
                    controller.view.topAnchor.constraint(equalTo: host.topAnchor),
                    controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
                ])
                host.appearance = appearance
                controller.view.appearance = appearance
                host.wantsLayer = true
                host.layer?.backgroundColor = Design.Surface.ground.cgColor
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()
                if let scrollView = controller.view as? NSScrollView {
                    scrollView.contentView.scroll(to: .zero)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    host.layoutSubtreeIfNeeded()
                }
                png = try? renderedPNG(of: host)
            }

            let rendered = try XCTUnwrap(png)
            XCTAssertGreaterThan(rendered.count, 20_000, "\(name) setup page rendered empty")
            attach(rendered, named: "remote-access-settings-\(name)")
            if let output {
                try rendered.write(
                    to: output.appendingPathComponent("remote-access-settings-\(name).png")
                )
            }
        }
    }

    /// A `+` beside a closable "General ✕" reads as "add another one of these", which is the one
    /// thing it does not do — it creates a *session*, and a preferences page is no context for
    /// one. The design system's own rule: a control offering nothing here hides.
    @MainActor
    func testNewSessionHidesWhileSettingsIsThePage() throws {
        let controller = MainWindowController()
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.newSessionButton?.isHidden, false)

        controller.toggleSettings()
        XCTAssertEqual(
            controller.newSessionButton?.isHidden,
            true,
            "New Session is still offered on a settings page"
        )

        controller.toggleSettings()
        XCTAssertEqual(controller.newSessionButton?.isHidden, false)
    }

    /// ⌘, is the platform's *open* chord because preferences are normally their own window, with
    /// ⌘W to close. Here Settings is a page in this window, so the chord that put it there is
    /// what takes it away again — there is no second window for ⌘W to mean.
    @MainActor
    func testTheSettingsCommandClosesWhatItOpened() throws {
        let controller = MainWindowController()
        let container = try XCTUnwrap(
            controller.splitViewController.splitViewItems[1].viewController
                as? TerminalContainerViewController
        )

        XCTAssertFalse(container.isShowingSettings)

        controller.toggleSettingsFromCommand()
        XCTAssertTrue(container.isShowingSettings, "⌘, did not open Settings")

        controller.toggleSettingsFromCommand()
        XCTAssertFalse(container.isShowingSettings, "⌘, opened Settings but would not close it")
    }

    /// The accent means "this wants you" — it is the sidebar's attention dot. Spending it on the
    /// fact that a page happens to be open says that about nothing, which is the rule the design
    /// system already states for a tab's icon. The cog raises its ink instead.
    @MainActor
    func testSettingsCogMarksItselfWithoutSpendingTheAccent() throws {
        let sidebar = ProjectSidebarViewController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.view.layoutSubtreeIfNeeded()

        let cog = try XCTUnwrap(
            descendants(in: sidebar.view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.title == L10n.string("Settings") && $0.image != nil },
            "the sidebar footer has no Settings button to be the cogwheel"
        )

        sidebar.setSettingsMode(true)
        XCTAssertNotEqual(
            cog.contentTintColor,
            Design.Surface.accent,
            "the cogwheel is spending the accent to say a page is open"
        )
        XCTAssertEqual(cog.contentTintColor, Design.Text.label)

        sidebar.setSettingsMode(false)
        XCTAssertEqual(cog.contentTintColor, Design.Text.secondary)
    }

    /// The one thing a pane-owned header has to know about the window.
    ///
    /// The header shares its strip with the traffic lights and the sidebar toggle, which is fine
    /// while the sidebar is there — the pane begins past them. Collapsed, the pane begins at the
    /// window's leading edge and the tab lands on top of the lights, which is precisely why this
    /// project abandoned its first hand-rolled header.
    @MainActor
    func testHeaderStepsAsideForTheWindowControlsWhenTheSidebarCollapses() throws {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1200, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()

        let container = try XCTUnwrap(
            controller.splitViewController.splitViewItems[1].viewController
                as? TerminalContainerViewController
        )

        XCTAssertEqual(
            container.headerLeadingInset,
            PaneHeaderDefaults.inset,
            "with the sidebar out, the pane already starts past the window's controls"
        )

        controller.toggleSidebar()
        // The collapse is animated, and the inset is settled against the state it lands in.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: Design.Motion.standard * 2))
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            container.headerLeadingInset,
            PaneHeaderDefaults.assumedWindowControlsWidth / 2,
            "the header stayed under the traffic lights with the sidebar collapsed"
        )
    }

    private enum DividerDragFixture {
        static let windowSize = NSSize(width: 1200, height: 700)
        /// One mouse-move's worth of travel. Small enough that the pointer passes through every
        /// width the floor and the shut threshold live at rather than jumping over them.
        static let step: CGFloat = 8
        /// One mouse-up ends the drag; the rest are slack. `mouseDown(with:)` does not return
        /// until the tracking loop has pulled an up of its own, so a loop that wants one more
        /// event than it was queued would hang the whole suite rather than fail a test.
        static let mouseUps = 8
        /// Comfortably inside a band, so neither case is decided by a rounding error: a push
        /// this far past the threshold shuts the column, and a stop this far short of it
        /// does not.
        static let margin: CGFloat = 20
        /// A width that is plainly nobody's default and comfortably inside what the window can
        /// give, so restoring it proves the store rather than the layout.
        static let chosenWidthOffset: CGFloat = 97
    }

    /// Drags a split divider to `pointerX` through the loop AppKit actually runs for one.
    ///
    /// `setPosition` — what the other collapse tests here use — takes the item's Auto Layout
    /// path and cannot see any of this: past the floor the divider stops dead and the pointer
    /// travels on alone, and it is that overshoot, invisible in every frame, that decides
    /// whether the pane shuts. The events are queued on the window *before* the loop is
    /// entered, because `mouseDown(with:)` does not return until it has pulled its own mouse-up.
    @MainActor
    private func dragDivider(
        at index: Int,
        to pointerX: CGFloat,
        in controller: MainWindowController
    ) throws {
        let window = try XCTUnwrap(controller.window)
        let splitView = controller.splitViewController.splitView
        let leadingPane = try XCTUnwrap(splitView.arrangedSubviews[index])
        func inWindow(_ x: CGFloat) -> NSPoint {
            splitView.convert(NSPoint(x: x, y: splitView.frame.midY), to: nil)
        }

        var queued: [NSEvent] = []
        var x = leadingPane.frame.maxX
        // Toward the target in either direction — the sidebar's divider shuts it leftward,
        // the panel's shuts it rightward — through every width on the way.
        while abs(x - pointerX) > DividerDragFixture.step {
            x += DividerDragFixture.step * (pointerX > x ? 1 : -1)
            queued.append(try mouseEvent(.leftMouseDragged, at: inWindow(x), in: window))
        }
        queued.append(try mouseEvent(.leftMouseDragged, at: inWindow(pointerX), in: window))
        queued.append(
            contentsOf: try (0..<DividerDragFixture.mouseUps).map { _ in
                try mouseEvent(.leftMouseUp, at: inWindow(pointerX), in: window)
            }
        )
        for event in queued { window.postEvent(event, atStart: false) }

        let grab = leadingPane.frame.maxX + splitView.dividerThickness / 2
        splitView.mouseDown(with: try mouseEvent(.leftMouseDown, at: inWindow(grab), in: window))
        window.contentView?.layoutSubtreeIfNeeded()
        // The shut runs a turn after the release, through the shared transition route.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: Design.Motion.standard))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The sidebar's copy of the drag, answering whether the column ended up shut.
    @MainActor
    private func dragSidebarDivider(
        to pointerX: CGFloat,
        in controller: MainWindowController
    ) throws -> Bool {
        try dragDivider(at: 0, to: pointerX, in: controller)
        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        return sidebarItem.isCollapsed
    }

    /// A fresh window whose sidebar sits at the floor the running app gives it.
    @MainActor
    private func windowAtSidebarFloor() throws -> (MainWindowController, CGFloat) {
        // Spare mouse-ups from an earlier drag are still in the app's queue, and
        // `nextEvent(matching:)` does not care which window they were made for.
        while NSApp.nextEvent(
            matching: .any,
            until: Date(timeIntervalSinceNow: 0),
            inMode: .default,
            dequeue: true
        ) != nil {}

        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(DividerDragFixture.windowSize)
        window.contentView?.layoutSubtreeIfNeeded()
        // The floor is claimed a turn of the run loop after setup, once the toolbar's own
        // controls can be measured — drag against the one the app really has.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: Design.Motion.standard))
        window.contentView?.layoutSubtreeIfNeeded()

        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        return (controller, sidebarItem.minimumThickness)
    }

    /// Carrying the divider on past the column shuts it.
    ///
    /// AppKit's own rule wants *half the floor* — around a hundred points past a column that
    /// has already stopped moving, every one of them without feedback, which is how "it does not
    /// collapse any more" gets reported about a gesture that technically still works.
    /// `PaneTransition.shutOvershoot` is where the push becomes an answer instead.
    @MainActor
    func testPushingTheDividerPastTheSidebarShutsIt() throws {
        let (controller, floor) = try windowAtSidebarFloor()
        let toggle = try XCTUnwrap(controller.sidebarToolbarButton)
        XCTAssertTrue(toggle.isSelected, "the toggle did not start out lit for a visible sidebar")

        let shut = try dragSidebarDivider(
            to: floor - PaneTransition.shutOvershoot - DividerDragFixture.margin,
            in: controller
        )

        XCTAssertTrue(shut, "the divider pushed past the sidebar's floor stopped dead")
        // A pane shut this way never reaches `toggleSidebar`, which used to be the only place
        // the toolbar's toggle was told.
        XCTAssertFalse(
            toggle.isSelected,
            "the toolbar's sidebar toggle stayed lit for a column that had been shut"
        )
    }

    /// And stopping at the column does not.
    ///
    /// The floor is a size the user asks for deliberately — as narrow as the sidebar goes — so
    /// arriving there, or drifting a little past it, has to leave the column standing.
    @MainActor
    func testStoppingAtTheSidebarsFloorLeavesItOpen() throws {
        let (controller, floor) = try windowAtSidebarFloor()
        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)

        let shut = try dragSidebarDivider(
            to: floor - PaneTransition.shutOvershoot + DividerDragFixture.margin,
            in: controller
        )

        XCTAssertFalse(shut, "the sidebar shut on a drag that only reached its floor")
        XCTAssertEqual(
            sidebarItem.viewController.view.frame.width,
            floor,
            accuracy: 1,
            "the sidebar did not come to rest at the floor the drag pushed it to"
        )
    }

    /// The same gesture at the window's other edge shuts the display panel.
    ///
    /// The panel's floor is its 48pt chrome, so its shut threshold is half the floor rather
    /// than the full overshoot — the full one lies 12pt *outside the window*, a release the
    /// pointer cannot reach when the window's edge meets the screen's
    /// (`PaneTransition.dragShutsPane`).
    @MainActor
    func testPushingTheDividerPastTheDisplayPanelShutsIt() throws {
        let (controller, pane, displayItem) = try windowWithDisplayPanelOpen()
        let toggle = try XCTUnwrap(controller.displayPaneToolbarButton)
        XCTAssertTrue(toggle.isSelected, "the toggle did not start out lit for a visible panel")

        try dragDivider(
            at: controller.splitViewController.splitViewItems.count - 2,
            to: pane.frame.maxX - panelShutThreshold(displayItem) + DividerDragFixture.margin,
            in: controller
        )

        XCTAssertTrue(
            displayItem.isCollapsed,
            "the divider pushed past the panel's floor stopped dead"
        )
        XCTAssertFalse(
            toggle.isSelected,
            "the toolbar's panel toggle stayed lit for a panel that had been shut"
        )
    }

    /// And stopping at the panel's floor leaves it standing, exactly as the sidebar's does.
    @MainActor
    func testStoppingAtTheDisplayPanelsFloorLeavesItOpen() throws {
        let (controller, pane, displayItem) = try windowWithDisplayPanelOpen()

        try dragDivider(
            at: controller.splitViewController.splitViewItems.count - 2,
            to: pane.frame.maxX - panelShutThreshold(displayItem) - DividerDragFixture.margin,
            in: controller
        )

        XCTAssertFalse(displayItem.isCollapsed, "the panel shut on a drag inside its threshold")
        XCTAssertEqual(
            pane.frame.width,
            displayItem.minimumThickness,
            accuracy: 1,
            "the panel did not come to rest at the floor the drag pushed it to"
        )
    }

    /// A fresh window with the panel revealed, its width already the divider's own answer.
    @MainActor
    private func windowWithDisplayPanelOpen() throws -> (
        MainWindowController, NSView, NSSplitViewItem
    ) {
        let (controller, _) = try windowAtSidebarFloor()
        let window = try XCTUnwrap(controller.window)
        let displayItem = try XCTUnwrap(controller.splitViewController.splitViewItems.last)

        controller.setDisplayPaneVisible(true)
        // The reveal restores the stored width through the transition route's deferred turns.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: Design.Motion.standard))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(displayItem.isCollapsed, "the panel never opened, so nothing can shut it")

        let pane = try XCTUnwrap(
            controller.splitViewController.splitView.arrangedSubviews.last
        )
        return (controller, pane, displayItem)
    }

    /// Where a release means "shut" for the panel: the floor less the capped overshoot.
    private func panelShutThreshold(_ item: NSSplitViewItem) -> CGFloat {
        item.minimumThickness - min(PaneTransition.shutOvershoot, item.minimumThickness / 2)
    }

    /// The gesture's arithmetic, stated once: the overshoot, capped at half the floor so a
    /// shallow pane's shut point stays inside the window.
    @MainActor
    func testTheShutThresholdNeverLiesOutsideTheWindow() {
        // A deep floor affords the full overshoot...
        XCTAssertFalse(PaneTransition.dragShutsPane(thickness: 148, floor: 207))
        XCTAssertTrue(PaneTransition.dragShutsPane(thickness: 146, floor: 207))
        // ...and a shallow one halves itself rather than asking for a release past the edge.
        XCTAssertFalse(PaneTransition.dragShutsPane(thickness: 25, floor: 48))
        XCTAssertTrue(PaneTransition.dragShutsPane(thickness: 23, floor: 48))
    }

    /// The drawer's divider takes the same push. Its height constraint clamps at the floor
    /// while the hand keeps going, so the overshoot lives only in the container's running
    /// total — driven through the divider callbacks' seams, because a synthesized `NSEvent`
    /// cannot carry the `deltaY` the real strip reports.
    @MainActor
    func testPushingTheDrawersDividerPastItsFloorShutsIt() throws {
        let fixture = try drawerSession()
        defer { fixture.tearDown() }
        let container = fixture.container
        XCTAssertTrue(container.isShellDrawerOpen, "the fixture's drawer never opened")

        // One pull down to the floor, then the overshoot past it.
        container.drawerDividerDragged(by: ShellDrawerHeight.stored - drawerFloor)
        container.drawerDividerDragged(
            by: PaneTransition.shutOvershoot + DividerDragFixture.margin
        )
        container.drawerDividerDragEnded()

        XCTAssertFalse(container.isShellDrawerOpen, "the drawer stopped dead at its floor")
        XCTAssertEqual(
            ShellDrawerHeight.stored,
            drawerFloor,
            accuracy: 1,
            "the drawer recorded the overshoot as a height, so it would reopen shorter"
        )
    }

    /// And a pull that stops at the floor — or drifts a little past it — leaves it open,
    /// exactly as the window's other panes do.
    @MainActor
    func testStoppingAtTheDrawersFloorLeavesItOpen() throws {
        let fixture = try drawerSession()
        defer { fixture.tearDown() }
        let container = fixture.container

        container.drawerDividerDragged(
            by: ShellDrawerHeight.stored - drawerFloor
                + PaneTransition.shutOvershoot - DividerDragFixture.margin
        )
        container.drawerDividerDragEnded()

        XCTAssertTrue(
            container.isShellDrawerOpen,
            "the drawer shut on a drag that only reached its floor"
        )
    }

    /// The least the drawer can be — `TerminalContainerViewController.drawerFloor`, restated
    /// because the container keeps its own private.
    private var drawerFloor: CGFloat {
        ShellDrawerDefaults.minimumHeight + ThemedTabStripView.bandHeight
    }

    private struct DrawerFixture {
        let container: TerminalContainerViewController
        let tearDown: () -> Void
    }

    /// A real project and session with the drawer open on its shell tab — unwindowed, so the
    /// shell never spawns — and the developer's own drawer height put back on teardown, since
    /// `ShellDrawerHeight` lives in the real defaults.
    @MainActor
    private func drawerSession() throws -> DrawerFixture {
        let previousHeight = ShellDrawerHeight.stored
        // Pinned before the container reads it, so the drag arithmetic below is the test's
        // rather than whatever height this machine's drawer was last left at.
        ShellDrawerHeight.stored = ShellDrawerDefaults.defaultHeight
            + ThemedTabStripView.bandHeight

        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "threading-drawer-drag-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ProjectStore.shared
        let project = store.addProject(folderURL: folder)
        let session = try XCTUnwrap(
            store.addSession(to: project.id, kind: .claude, usesNativeUI: false, title: "Drawer")
        )

        let container = TerminalContainerViewController()
        container.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        container.view.layoutSubtreeIfNeeded()
        // The pane's subject, stated without launching its agent: the drawer is per-session.
        container.setCurrentSessionForTesting(session.id)
        container.openShellDrawer()
        container.view.layoutSubtreeIfNeeded()

        return DrawerFixture(container: container) {
            container.closeShellDrawer(for: session.id)
            container.setCurrentSessionForTesting(nil)
            store.removeProject(id: project.id)
            try? FileManager.default.removeItem(at: folder)
            ShellDrawerHeight.stored = previousHeight
        }
    }

    /// The column has no ceiling of its own — only the one the terminal implies.
    ///
    /// A fixed 400pt maximum stopped the divider in open space with the window nowhere near
    /// full, which reads as a broken drag. What is left is the terminal's own floor, which the
    /// split view enforces without being asked twice.
    @MainActor
    func testTheSidebarMayBeDraggedPastItsOldCeiling() throws {
        let (controller, _) = try windowAtSidebarFloor()
        let window = try XCTUnwrap(controller.window)
        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        let splitView = controller.splitViewController.splitView

        let beyond = SidebarDefaults.maxWidth + DividerDragFixture.margin
        splitView.setPosition(beyond, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            sidebarItem.viewController.view.frame.width,
            beyond,
            accuracy: 1,
            "the sidebar was held at a ceiling of its own with the window nowhere near full"
        )

        // And the terminal's floor is the limit that is left, not a number in the sidebar's.
        splitView.setPosition(
            DividerDragFixture.windowSize.width,
            ofDividerAt: 0
        )
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(
            controller.splitViewController.splitViewItems[1].viewController.view.frame.width,
            MainWindowDefaults.minContentWidth,
            "the sidebar took width the terminal had said it needed"
        )
    }

    /// A pane's contents may say how wide they would like to be. They may not say how wide the
    /// *pane* is.
    ///
    /// The composer's column fills its pane up to `ComposerDefaults.contentWidth`, and stated as
    /// an equality at `.defaultHigh` beside a required cap that reads, to Auto Layout, as "this
    /// pane is at most 784 wide" — a claim that outranks the priority a split view holds its
    /// panes at. In a 1200pt window the terminal was pinned at 784 and the sidebar could not be
    /// dragged below 415: the divider stopped dead 200pt above its floor, and pushing on shut the
    /// column instead. The host here claims its width the way a split item does, at 250, so a
    /// column that outranks it fails this.
    @MainActor
    func testTheComposerColumnDoesNotCapThePaneItFills() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 600))
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pane)

        let composer = SessionComposerViewController()
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(composer.view)

        let paneWidth = pane.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        paneWidth.priority = NSLayoutConstraint.Priority(250)

        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pane.topAnchor.constraint(equalTo: root.topAnchor),
            pane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            paneWidth,
            composer.view.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            composer.view.topAnchor.constraint(equalTo: pane.topAnchor),
            composer.view.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        ])
        root.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            pane.frame.width,
            root.frame.width,
            accuracy: 1,
            "the composer's column held its pane below the width the pane asked for"
        )

        // And the cap itself still holds, which is the other half: the column stops at its
        // measure rather than running the full width of a wide pane.
        let column = try XCTUnwrap(
            descendant(withIdentifier: "composer.session-start.content", in: composer.view),
            "the composer's prompt column was not found"
        )
        XCTAssertEqual(
            column.frame.width,
            ComposerDefaults.contentWidth,
            accuracy: 1,
            "the column did not stop at the width it is capped to"
        )
    }

    /// The width the user left the divider at is the width the app opens at next time.
    ///
    /// The window's own frame is autosaved, so a restart brought back the arranged window with
    /// the column inside it reset to its default.
    @MainActor
    func testTheSidebarOpensAtTheWidthItWasLeftAt() throws {
        let stored = PreferenceStore.shared.double(forKey: SidebarWidthTestKey.key)
        defer {
            PreferenceStore.shared.set(stored, forKey: SidebarWidthTestKey.key)
        }

        let (controller, floor) = try windowAtSidebarFloor()
        let window = try XCTUnwrap(controller.window)
        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        let chosen = floor + DividerDragFixture.chosenWidthOffset

        controller.splitViewController.splitView.setPosition(chosen, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(SidebarWidth.stored ?? 0, chosen, accuracy: 1, "the divider recorded nothing")

        // A second launch, reading what the first one left.
        let (relaunched, _) = try windowAtSidebarFloor()
        let restored = try XCTUnwrap(relaunched.splitViewController.splitViewItems.first)
        XCTAssertEqual(
            restored.viewController.view.frame.width,
            chosen,
            accuracy: 1,
            "the sidebar came back at its default rather than the width it was left at"
        )
        XCTAssertFalse(sidebarItem.isCollapsed)
    }

    private enum SidebarWidthTestKey {
        /// The store's own key, restated so the test can put the developer's value back — a
        /// hosted test writes to a scratch suite, but it is still shared across the suite.
        static let key = "ThreadingSidebarWidth"
    }

    /// The other half of the same fact: those controls sit at a fixed window x, so the sidebar
    /// cannot be narrower than they are.
    ///
    /// Dragged to `SidebarDefaults.minWidth` the divider ran through the forward chevron, leaving
    /// half a button hanging over the terminal. Below the controls there is no useful width left,
    /// so the floor is where they end and the next size down is collapsed.
    @MainActor
    func testSidebarStopsWhereTheWindowControlsEnd() throws {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1200, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        // The floor is claimed one turn of the run loop after setup, once the toolbar's own
        // items have been laid out and can be measured.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: Design.Motion.standard))
        window.contentView?.layoutSubtreeIfNeeded()

        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)

        XCTAssertGreaterThan(
            sidebarItem.minimumThickness,
            SidebarDefaults.minWidth,
            "the sidebar kept the list's own floor, which is narrower than the window's controls"
        )
        // Pre-layout the toolbar's buttons have no frame to measure, and the fallback stands in.
        // Where there is a real frame, it is what the floor has to clear.
        let controlsMaxX = [
            controller.sidebarToolbarButton,
            controller.navBackToolbarButton,
            controller.navForwardToolbarButton
        ]
            .compactMap { $0.map { button in button.convert(button.bounds, to: nil).maxX } }
            .max() ?? 0
        if controlsMaxX > PaneHeaderDefaults.inset {
            XCTAssertGreaterThanOrEqual(
                sidebarItem.minimumThickness,
                controlsMaxX,
                "at its minimum the sidebar's divider crossed the trailing-most toolbar control"
            )
        }

        // With no useful width left below the minimum, the next size down is shut: pushed past
        // it the column collapses rather than sticking at a width it cannot fill.
        controller.splitViewController.splitView.setPosition(
            SidebarDefaults.minWidth / 2,
            ofDividerAt: 0
        )
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            sidebarItem.isCollapsed,
            "driven below its minimum the sidebar stopped dead instead of collapsing"
        )
    }

    func testActivePageTabOwnsItsCloseAffordance() throws {
        let tab = ThemedTabItemView(
            title: "Themes",
            symbolName: "paintpalette",
            placement: .horizontal,
            showsClose: true,
            inkSource: .backdrop
        )
        var closes = 0
        tab.onClose = { closes += 1 }

        let close = try XCTUnwrap(
            descendants(in: tab).compactMap { $0 as? ThemedIconButton }.first
        )
        XCTAssertFalse(tab.isHidden)
        XCTAssertFalse(close.isHidden)
        XCTAssertEqual(close.accessibilityTitle(), "Close Themes")
        XCTAssertTrue(close.accessibilityPerformPress())
        XCTAssertEqual(closes, 1)

        // The × inks from the tab it sits in, so a page tab over the terminal backdrop cannot
        // end up with a close button coloured for the chrome.
        XCTAssertEqual(close.inkSource, .backdrop)

        tab.update(title: "Project", symbolName: "folder", showsClose: false)
        XCTAssertTrue(close.isHidden, "a non-closable destination kept the × visible")
    }

    /// The toolbar holds the page tab to a minimum width, so the window's chrome does not resize
    /// itself around every session name — which means a short name leaves the tab with room to
    /// spare. That room belongs to the title. Under the stack's default gravity it landed *after*
    /// the last view instead, leaving the × 43pt inboard of a tab whose fill ran to the edge.
    ///
    /// The title's line still starts where it did, because it is drawn from the label's leading
    /// edge rather than centred in it. Asserted as the same start at both widths: a glyph's layer
    /// frame is padded for ink that overhangs its box and snapped to device pixels, and that
    /// constant cancels between two measurements rather than being restated here.
    func testAPageTabSpendsSpareWidthOnItsTitleRatherThanAfterItsClose() throws {
        let tab = ThemedTabItemView(
            title: "Fix",
            symbolName: "folder",
            placement: .horizontal,
            showsClose: true,
            inkSource: .backdrop
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        tab.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(tab)
        let width = tab.widthAnchor.constraint(
            equalToConstant: tab.intrinsicContentSize.width
        )
        NSLayoutConstraint.activate([
            tab.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            tab.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            width
        ])
        host.layoutSubtreeIfNeeded()

        let title = try XCTUnwrap(
            descendants(in: tab).compactMap { $0 as? MorphingTitleLabel }.first
        )
        let close = try XCTUnwrap(
            descendants(in: tab).compactMap { $0 as? ThemedIconButton }.first
        )
        func lineStart() throws -> CGFloat {
            let glyphs = title.subviews.flatMap { $0.layer?.sublayers ?? [] }
            XCTAssertFalse(glyphs.isEmpty, "the title drew nothing")
            return try XCTUnwrap(glyphs.map { title.convert($0.frame, to: tab).minX }.min())
        }
        let snug = try lineStart()

        width.constant = SessionTitleDefaults.minWidth
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(
            tab.bounds.width,
            tab.intrinsicContentSize.width + Design.Spacing.large,
            "the fixture is not holding the tab wider than it wants to be"
        )

        let glyph = close.convert(
            close.bounds.insetBy(dx: close.opticalHorizontalInset, dy: 0),
            to: tab
        )
        XCTAssertEqual(
            tab.bounds.maxX - glyph.maxX,
            Design.Spacing.inset,
            accuracy: 0.5,
            "the spare width landed after the × instead of in the title"
        )
        XCTAssertEqual(
            try lineStart(),
            snug,
            accuracy: 1,
            "the title's first glyph moved with the room around it instead of staying put"
        )
    }

    func testDisplayPaneHasNoDetachedHeaderCloseButton() {
        let controller = DisplayPaneController()
        controller.loadView()
        controller.viewDidLoad()

        let closeButtons = descendants(in: controller.view).filter {
            $0.accessibilityTitle() == "Close" || $0.accessibilityLabel() == "Close"
        }
        XCTAssertEqual(
            closeButtons,
            [],
            "the display pane kept a detached × instead of using the toolbar panel toggle"
        )
    }

    func testKeyboardFocusChangesAButtonsVisibleDrawing() throws {
        let button = ThemedButton(title: "Continue", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 20, width: 100, height: 26)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 66),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(button)

        let unfocused = try renderedPNG(of: button)
        XCTAssertTrue(window.makeFirstResponder(button))
        let focused = try renderedPNG(of: button)

        XCTAssertNotEqual(unfocused, focused, "keyboard focus drew no visible treatment")
    }

    /// The accounts pane's icon well is a 30pt disc — a surface *applied* to the layer rather
    /// than drawn — and a layer corner clips what `draw(_:)` lays down. A ring built from the
    /// rounded-rect token instead survived only where the two shapes met: four 1pt dashes at the
    /// edge midpoints, with the corners of the ring cut away entirely, which is what "the
    /// selection circle is broken" looked like on screen. So the ring is sampled all the way
    /// round, diagonals included — the places the mismatch erased.
    func testTheFocusRingClosesAllTheWayRoundAnAppliedDisc() throws {
        AppThemePalette.set(.system)

        let size = AccountsPreferencesLayout.iconWellSize
        let well = ThemedButton(title: "✳️", target: nil, action: nil)
        well.isBordered = false
        well.frame = NSRect(x: 0, y: 0, width: size, height: size)
        well.applySurface(fill: Design.Surface.controlResting, radius: .pill(height: size))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(well)

        let resting = try ringSamples(of: well)
        XCTAssertTrue(window.makeFirstResponder(well))
        let focused = try ringSamples(of: well)

        for (angle, restingColor) in resting {
            let focusedColor = try XCTUnwrap(focused[angle])
            XCTAssertNotEqual(
                focusedColor, restingColor,
                "the focus ring is missing at \(angle)° — it is not following the well's disc"
            )
        }
    }

    /// Samples the drawn control on the circle the focus ring occupies: the applied radius,
    /// pulled in by half the ring's width. Keyed by angle so a failure names where the ring
    /// broke rather than which array index did.
    private func ringSamples(of view: NSView) throws -> [Int: NSColor] {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        // The rep is sized in *pixels*: on a Retina backing store that is twice the points the
        // geometry is stated in, and sampling in points would read the wrong circle.
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let radius = try XCTUnwrap(view.appliedSurfaceRadius) - Design.Accessibility.focusRingWidth / 2

        var samples: [Int: NSColor] = [:]
        for angle in stride(from: 0, to: 360, by: 45) {
            let radians = CGFloat(angle) * .pi / 180
            let point = CGPoint(
                x: (center.x + cos(radians) * radius) * scale,
                y: (center.y + sin(radians) * radius) * scale
            )
            samples[angle] = try XCTUnwrap(
                rep.colorAt(x: Int(point.x.rounded()), y: Int(point.y.rounded()))
            ).usingColorSpace(.sRGB)
        }
        return samples
    }

    // MARK: - Accessibility Display Options

    func testIncreaseContrastStrengthensFaintRolesAndFocusGeometry() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        Design.Accessibility.increaseContrastOverrideForTesting = false

        let regularInk = Design.Text.on(Design.Surface.ground)
        let regularInkBorderAlpha = regularInk.border.alphaComponent
        let regularWidth = Design.Radius.border

        Design.Accessibility.increaseContrastOverrideForTesting = true

        let strongInk = Design.Text.on(Design.Surface.ground)

        XCTAssertGreaterThan(strongInk.secondary.alphaComponent, regularInk.secondary.alphaComponent)
        XCTAssertGreaterThan(strongInk.border.alphaComponent, regularInkBorderAlpha)
        XCTAssertGreaterThan(Design.Radius.border, regularWidth)
        XCTAssertEqual(Design.Accessibility.focusRingWidth, 3)

        // The faint *fills* are read under a theme that authors faint ones. Only a translucent
        // role has anything to strengthen: `Design.Accessibility.color` leaves an opaque authored
        // colour exactly as the theme wrote it, since nothing is won by making a solid surface
        // more solid — and Cyberpunk's control fill became one of those when that theme was
        // rebuilt against its reference.
        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        Design.Accessibility.increaseContrastOverrideForTesting = false
        let regularControl = try resolvedLayerColor(Design.Surface.controlResting)
        let regularDivider = try resolvedLayerColor(Design.Surface.divider)
        Design.Accessibility.increaseContrastOverrideForTesting = true
        let strongControl = try resolvedLayerColor(Design.Surface.controlResting)
        let strongDivider = try resolvedLayerColor(Design.Surface.divider)
        XCTAssertGreaterThan(strongControl.alphaComponent, regularControl.alphaComponent)
        XCTAssertGreaterThan(strongDivider.alphaComponent, regularDivider.alphaComponent)
    }

    func testAccessibilityRefreshReappliesRecordedLayerSurfaces() throws {
        // A theme whose control fill is authored translucent: the claim is that a *recorded*
        // surface is re-resolved, and only a faint role visibly moves when it is.
        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        Design.Accessibility.increaseContrastOverrideForTesting = false

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        view.applySurface(
            fill: Design.Surface.controlResting,
            radius: .control,
            border: Design.Surface.border
        )
        let regular = try XCTUnwrap(
            view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB)
        )

        Design.Accessibility.increaseContrastOverrideForTesting = true
        view.reapplyRecordedSurfaceForTesting()
        let increased = try XCTUnwrap(
            view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB)
        )

        XCTAssertGreaterThan(increased.alphaComponent, regular.alphaComponent)
        XCTAssertEqual(view.layer?.borderWidth, Design.Radius.controlBorder)
    }

    /// Structural cards and compact controls may be constructed at different scales. Bauhaus's
    /// reference uses four-point card ink and two-point button ink, while old themes inherit one
    /// weight for both; `applySurface` must preserve that semantic split even when both are square.
    func testAppliedSurfacesRouteStructuralAndControlBorderWeightsSeparately() {
        AppThemePalette.set(AppThemeStyles.bauhaus)

        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        panel.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )
        let control = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        control.applySurface(
            fill: Design.Surface.controlResting,
            radius: .control,
            border: Design.Surface.border
        )

        XCTAssertEqual(Design.Radius.border, 4)
        XCTAssertEqual(Design.Radius.controlBorder, 2)
        XCTAssertEqual(panel.layer?.borderWidth, 4)
        XCTAssertEqual(control.layer?.borderWidth, 2)

        AppThemePalette.set(AppThemeStyles.neoBrutalism)
        control.reapplyRecordedSurfaceForTesting()
        XCTAssertEqual(Design.Radius.border, 4)
        XCTAssertEqual(Design.Radius.controlBorder, 4)
        XCTAssertEqual(control.layer?.borderWidth, 4, "nil did not inherit structural weight")
    }

    /// Pattern is a backdrop role, not an automatic side effect of a colour or square corner.
    /// The same Bauhaus ground can fill a broad pane and a compact surface; only the former may
    /// wear the reference's dot field, and switching to a flat theme must remove the live layer.
    func testAppliedBackdropPatternIsExplicitAndThemeRefreshable() throws {
        AppThemePalette.set(AppThemeStyles.bauhaus)

        let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        backdrop.applySurface(
            fill: Design.Surface.ground,
            radius: .fixed(0),
            pattern: .backdrop
        )
        let compact = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        compact.applySurface(fill: Design.Surface.ground, radius: .fixed(0))

        let pattern = try XCTUnwrap(
            backdrop.layer?.sublayers?.first { $0.name == "threading.backdropPattern" }
        )
        XCTAssertEqual(pattern.opacity, 0.20, accuracy: 0.001)
        XCTAssertNil(
            compact.layer?.sublayers?.first { $0.name == "threading.backdropPattern" }
        )

        AppThemePalette.set(AppThemeStyles.newsprint)
        backdrop.reapplyRecordedSurfaceForTesting()
        XCTAssertNil(
            backdrop.layer?.sublayers?.first { $0.name == "threading.backdropPattern" },
            "a flat theme inherited the previous theme's pattern layer"
        )
    }

    /// The sheet buttons depend on this: Return confirms, Escape cancels, and nothing else in the
    /// window has to route it.
    func testAKeyEquivalentFiresTheAction() throws {
        let button = ThemedButton(title: "Import", target: nil, action: nil)
        let target = ActionSpy()
        button.target = target
        button.action = #selector(ActionSpy.fire)
        button.keyEquivalent = "\r"

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))

        XCTAssertTrue(button.performKeyEquivalent(with: event))
        XCTAssertEqual(target.count, 1)

        button.isEnabled = false
        XCTAssertFalse(button.performKeyEquivalent(with: event), "a disabled button answered Return")
        XCTAssertEqual(target.count, 1)
    }

    /// The three tiers are the two flags, named — and reading the name back has to survive
    /// either one being set directly, since most call sites still say the flags.
    func testEmphasisNamesTheThreeShapesTheButtonAlreadyHad() {
        let button = ThemedButton()
        XCTAssertEqual(button.emphasis, .secondary, "a plain bordered button is the ordinary tier")

        button.emphasis = .primary
        XCTAssertTrue(button.isProminent)
        XCTAssertTrue(button.isBordered, "the accent fill is a *bordered* shape")

        button.emphasis = .tertiary
        XCTAssertFalse(button.isProminent)
        XCTAssertFalse(button.isBordered)

        button.isBordered = true
        XCTAssertEqual(button.emphasis, .secondary)
        button.isProminent = true
        XCTAssertEqual(button.emphasis, .primary)
    }

    /// A chord on a button beside a text view has to be exact.
    ///
    /// `keyEquivalent` matches the character whatever is held with it, which is right for a
    /// sheet and wrong here: AppKit offers every key-down to the view tree's key equivalents
    /// *before* the first responder sees it, so a start button answering "\r" would eat the
    /// Return meant for the prompt beside it — the whole reason the composer's send moved to
    /// ⌘Return in the first place.
    func testAShortcutAnswersItsOwnChordAndNothingElse() throws {
        let target = ActionSpy()
        let button = ThemedButton(
            title: "Start session",
            target: target,
            action: #selector(ActionSpy.fire)
        )
        button.emphasis = .primary
        button.shortcut = KeyboardShortcut(key: "\r", modifiers: .command)

        func returnKey(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ))
        }

        XCTAssertFalse(
            button.performKeyEquivalent(with: try returnKey([])),
            "a bare Return belongs to whatever is being typed into"
        )
        XCTAssertFalse(
            button.performKeyEquivalent(with: try returnKey([.command, .shift])),
            "⇧⌘↩ is a different chord"
        )
        XCTAssertEqual(target.count, 0)

        XCTAssertTrue(button.performKeyEquivalent(with: try returnKey(.command)))
        XCTAssertEqual(target.count, 1)

        // Caps Lock rides along on ordinary events and is nobody's key equivalent.
        XCTAssertTrue(button.performKeyEquivalent(with: try returnKey([.command, .capsLock])))
        XCTAssertEqual(target.count, 2)

        button.isEnabled = false
        XCTAssertFalse(button.performKeyEquivalent(with: try returnKey(.command)))
        XCTAssertEqual(target.count, 2)

        // Hidden is the one that bites: panes here are hidden rather than torn down, so the
        // session composer's ⌘Return sits in the window all the while a conversation is being
        // replied to.
        button.isEnabled = true
        button.isHidden = true
        XCTAssertFalse(button.performKeyEquivalent(with: try returnKey(.command)))
        XCTAssertEqual(target.count, 2)
    }

    /// The chord is drawn *after* the title and measured into the button's own width, so it
    /// neither crowds the words nor truncates them.
    func testAShortcutIsNamedBesideTheTitleRatherThanOverIt() throws {
        func button(withShortcut shortcut: KeyboardShortcut?) -> ThemedButton {
            let button = ThemedButton(title: "Start session", target: nil, action: nil)
            button.isBordered = false
            button.shortcut = shortcut
            return button
        }

        let plain = button(withShortcut: nil)
        let hinted = button(withShortcut: KeyboardShortcut(key: "\r", modifiers: .command))

        let glyphs = ("⌘↩" as NSString)
            .size(withAttributes: [.font: Design.Typography.controlRegular()])
        XCTAssertGreaterThanOrEqual(
            hinted.intrinsicContentSize.width - plain.intrinsicContentSize.width,
            ceil(glyphs.width),
            "the chord has to be measured into the button, or the title truncates around it"
        )

        // Both drawn at the same size: the hinted one puts ink where the plain one has none.
        let frame = NSRect(origin: .zero, size: hinted.intrinsicContentSize)
        func rightmostInk(_ button: ThemedButton) throws -> Int {
            button.frame = frame
            let rep = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: rep)
            for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
                for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                    return x
                }
            }
            return 0
        }

        XCTAssertGreaterThan(
            try rightmostInk(hinted),
            try rightmostInk(plain),
            "the chord did not draw"
        )
    }

    /// A chord and the title it names ink the **same band**, so the two read as a single line
    /// rather than as a hint floating above some words.
    ///
    /// This is asserted against a *serif* theme because that is the only place it can go wrong:
    /// `⌘` and `↩` are absent from New York, so they arrive from a fallback face whose metrics
    /// are not the theme's. The drawing used to answer that by centring the chord's inked path
    /// on its own line box and adding the correction to `y` — in a view that is not flipped, so
    /// the hint rose by the fraction of a point it should have dropped, and its taller fallback
    /// ascent lifted it further. Under SF the title and the chord resolve to one face and the
    /// two errors cancelled to nothing, which is why it shipped: `⌘↩` sat a point and a quarter
    /// above "Start session" under every serif theme and was square under the default one.
    ///
    /// Measured from the ink rather than from the code's own arithmetic: each line's baseline is
    /// recovered by taking where its lowest ink actually landed and subtracting how far below the
    /// baseline that font puts it.
    func testAShortcutInksTheSameBandAsItsTitle() throws {
        let previous = AppThemeLibrary.current
        addTeardownBlock { AppThemeLibrary.apply(previous) }

        // Six device pixels per point: the offset being guarded against is a fraction of one.
        let scale: CGFloat = 6
        let title = "Start session"
        let chord = KeyboardShortcut(key: "\r", modifiers: .command)

        for (name, theme) in [("system", AppTheme.system), ("serif", AppThemeStyles.newsprint)] {
            AppThemeLibrary.apply(theme)
            let button = ThemedButton(title: title, target: nil, action: nil)
            // Unbordered, so the alpha channel holds the ink and nothing else.
            button.isBordered = false
            button.shortcut = chord
            let size = button.intrinsicContentSize
            button.frame = NSRect(origin: .zero, size: size)

            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            rep.size = size
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            button.draw(button.bounds)
            NSGraphicsContext.restoreGraphicsState()

            // Every inked column, and the lowest row each one reaches.
            var inkRows: [Int: (Int, Int)] = [:]
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh
                where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                    let seen = inkRows[x] ?? (y, y)
                    inkRows[x] = (min(seen.0, y), max(seen.1, y))
                }
            }
            let inked = inkRows.keys.sorted()
            XCTAssertFalse(inked.isEmpty, "\(name): the button drew nothing")

            // The chord is the ink beyond the widest gap — `Layout.shortcutGap` is wider than
            // any space inside the words.
            let split = zip(inked, inked.dropFirst()).max { $0.1 - $0.0 < $1.1 - $1.0 }?.1 ?? 0
            func bandCentre(_ columns: [Int]) -> CGFloat {
                let rows = columns.compactMap { inkRows[$0] }
                let top = CGFloat(rows.map(\.0).min() ?? 0) / scale
                let bottom = CGFloat((rows.map(\.1).max() ?? 0) + 1) / scale
                return (top + bottom) / 2
            }

            let titleCentre = bandCentre(inked.filter { $0 < split })
            let chordCentre = bandCentre(inked.filter { $0 >= split })

            // A quarter point: comfortably above what the ink threshold can invent, and well
            // under the point the hint was floating by when this was written.
            XCTAssertEqual(
                chordCentre, titleCentre, accuracy: 0.25,
                "\(name): the chord's ink is centred \(titleCentre - chordCentre)pt above the title's"
            )
        }
    }


    /// A title is measured to size the button and drawn inside that size, so the two must use the
    /// *same* attributes. They did not: measured in the regular weight, drawn in the medium one,
    /// which left "Add Project" a hair too wide for its own rect — `NSString.draw(in:)` wraps, so
    /// it broke at the space and drew "Project" on a second line below the button. The sidebar
    /// footer read "Add".
    func testAButtonIsWideEnoughForItsOwnTitle() {
        let button = ThemedButton(title: "Add Project", target: nil, action: nil)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)

        let drawn = ("Add Project" as NSString).size(withAttributes: [.font: Design.Typography.control()])

        XCTAssertGreaterThanOrEqual(
            button.intrinsicContentSize.width, ceil(drawn.width),
            "the button measured itself too narrow to draw its own title on one line"
        )
    }

    func testAPlainTemplateIconDoesNotTintItsBoundingBox() throws {
        let button = ThemedButton(
            symbol: "xmark",
            accessibility: "Close",
            target: nil,
            action: nil
        )
        button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)

        let rep = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / button.bounds.width
        let quietPixel = try XCTUnwrap(
            rep.colorAt(x: Int(5 * scale), y: Int(12 * scale))
        )
        var strongestAlpha: CGFloat = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                strongestAlpha = max(strongestAlpha, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        XCTAssertLessThan(
            quietPixel.alphaComponent,
            0.1,
            "tinting the template image painted its transparent bounding box"
        )
        XCTAssertGreaterThan(strongestAlpha, 0.2, "the icon itself did not draw")
    }

    /// Disabling dims. It stopped doing that once, in the one place it is most visible: a theme
    /// whose resting surface is *already* translucent — Cyberpunk holds its neon at 10% — where
    /// `withAlphaComponent` replaced the alpha rather than scaling it and made the disabled
    /// buttons the loudest things on the page.
    func testADisabledButtonIsQuieterThanAnEnabledOne() {
        AppThemePalette.set(AppThemeStyles.cyberpunk)

        func fillAlpha(enabled: Bool) -> CGFloat {
            let button = ThemedButton(frame: NSRect(x: 0, y: 0, width: 80, height: 26))
            button.isEnabled = enabled
            let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds)!
            button.cacheDisplay(in: button.bounds, to: rep)
            return rep.colorAt(x: 40, y: 13)!.alphaComponent
        }

        XCTAssertLessThan(fillAlpha(enabled: false), fillAlpha(enabled: true),
                          "a disabled button drew a louder surface than an enabled one")
    }

    /// A translucent Bauhaus secondary showed its title twice: once on the face and once in the
    /// hard shadow behind it. The primary hid the same mistake only because its red fill is
    /// opaque. A drawn control therefore casts depth from a transparent path-only companion,
    /// never from the layer containing its text and glyph.
    func testAButtonShadowComesFromAShapeOnlyCompanionLayer() throws {
        AppThemePalette.set(AppThemeStyles.bauhaus)
        let button = ThemedButton(
            frame: NSRect(x: 0, y: 0, width: 110, height: Design.Size.chipHeight)
        )
        button.title = "Ordinary"

        let rep = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: rep)

        XCTAssertEqual(button.layer?.shadowOpacity, 0, "the text-bearing layer still casts depth")
        let shadow = try XCTUnwrap(
            button.layer?.sublayers?.first { $0.name == "threading.controlGlow.primary" }
        )
        XCTAssertNotNil(shadow.shadowPath, "the companion has no face silhouette")
        XCTAssertNil(shadow.contents, "the shadow companion copied the button artwork")
        XCTAssertNil(shadow.backgroundColor, "the shadow companion covers translucent faces")

        AppThemePalette.set(.system)
        button.needsDisplay = true
        button.cacheDisplay(in: button.bounds, to: rep)
        XCTAssertFalse(
            button.layer?.sublayers?.contains {
                $0.name == "threading.controlGlow.primary"
            } ?? false,
            "switching away from a lifted theme kept the companion shadow"
        )
    }

    // MARK: - Search Match

    /// Every token is found everywhere it occurs, so a phrase lights up both of its words rather
    /// than neither. Matching is case- and diacritic-insensitive, which is the one spelling of
    /// "contains" the filters use too.
    func testEveryTokenOfAQueryIsFoundWhereverItOccurs() {
        func marked(_ text: String, _ query: String) -> [String] {
            SearchTextMatch.ranges(in: text, matching: query).map { String(text[$0]) }
        }

        XCTAssertEqual(marked("Mute the sound, mute the orb", "mute"), ["Mute", "mute"])
        XCTAssertEqual(marked("Notifications · Mute · Sound", "mute sound"), ["Mute", "Sound"])
        XCTAssertEqual(marked("Motión", "motion"), ["Motión"])
        XCTAssertEqual(marked("Nothing here", ""), [])
        XCTAssertEqual(marked("Nothing here", "   "), [])
        XCTAssertEqual(marked("", "mute"), [])
    }

    /// Two tokens landing on neighbouring characters are one found word, not two grounds with a
    /// seam down the middle — and an overlap must not produce two runs over the same characters,
    /// which would paint the tint on itself and read darker than every other match on screen.
    func testTouchingAndOverlappingMatchesBecomeOneRun() {
        let text = "Startup shell"
        XCTAssertEqual(
            SearchTextMatch.ranges(in: text, matching: "start artup").map { String(text[$0]) },
            ["Startup"]
        )
        XCTAssertEqual(
            SearchTextMatch.ranges(in: text, matching: "start up").map { String(text[$0]) },
            ["Startup"]
        )
    }

    /// The case a fixed "find the query inside the text" gets backwards. A row showing the first
    /// characters of a session id, found because the reader pasted the *whole* id, has to say so:
    /// every character it is showing is one they typed.
    func testAQueryThatContainsTheWholeLineMarksAllOfIt() {
        let shown = "9f3c1a20"
        let ranges = SearchTextMatch.ranges(
            in: shown,
            matching: "9f3c1a20-77b4-4e6d-9c02-5a1e8b3d40ff"
        )
        XCTAssertEqual(ranges.map { String(shown[$0]) }, [shown])

        XCTAssertEqual(
            SearchTextMatch.ranges(in: shown, matching: "0000-77b4-4e6d").count, 0,
            "a longer query that does not contain the line marked it anyway"
        )
    }

    /// A match carries weight *and* a ground. Colour alone fails Differentiate Without Colour;
    /// weight alone disappears in a list of matches. The label states both or it states neither.
    func testAMatchIsMarkedByWeightAsWellAsByColour() throws {
        let label = SearchMatchLabel(role: .body)
        label.show("Mute a session", matching: "mute")

        let field = try XCTUnwrap(descendants(in: label).compactMap { $0 as? NSTextField }.first)
        let content = field.attributedStringValue

        let matched = content.attributes(at: 0, effectiveRange: nil)
        let rest = content.attributes(at: content.length - 1, effectiveRange: nil)

        let matchedFont = try XCTUnwrap(matched[.font] as? NSFont)
        let restFont = try XCTUnwrap(rest[.font] as? NSFont)
        XCTAssertNotEqual(matchedFont, restFont, "the matched run was set in the resting weight")
        XCTAssertNotNil(matched[.backgroundColor], "the matched run was given no ground")
        XCTAssertNil(rest[.backgroundColor], "the ground ran past the match")
        XCTAssertEqual(
            matchedFont.pointSize, restFont.pointSize,
            "emphasis changed the point size, which moves the line the two runs share"
        )
    }

    /// An empty query is not a search. A settings page that is merely *open* must look exactly as
    /// it did before this component existed.
    func testAnUnsearchedLineIsAPlainLine() throws {
        let label = SearchMatchLabel(role: .body)
        label.show("Mute a session", matching: "")

        let field = try XCTUnwrap(descendants(in: label).compactMap { $0 as? NSTextField }.first)
        let content = field.attributedStringValue
        content.enumerateAttribute(
            .backgroundColor,
            in: NSRange(location: 0, length: content.length)
        ) { value, _, _ in
            XCTAssertNil(value, "an empty query marked something")
        }
        XCTAssertEqual(field.stringValue, "Mute a session")
    }

    /// The ground has to *draw*, not merely be an attribute nobody applied. Asserted in pixels,
    /// under a theme whose accent is nothing like the panel it sits on, because the bug this
    /// catches — a background attribute on a label AppKit draws through its cell — is invisible
    /// to every assertion about the attributed string.
    func testTheMatchedRunPaintsAGroundBehindItself() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)

        /// Covered pixels rather than the strongest one: the *text* is opaque either way, so
        /// peak alpha cannot tell a ground from the glyphs standing on it. A ground is area.
        func coveredPixels(matching query: String) throws -> Int {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
            host.appearance = NSAppearance(named: .darkAqua)

            let label = SearchMatchLabel(role: .body)
            label.show("Mute", matching: query)
            host.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                label.centerYAnchor.constraint(equalTo: host.centerYAnchor)
            ])
            host.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)

            var covered = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    covered += 1
                }
            }
            return covered
        }

        let unmatched = try coveredPixels(matching: "zzz")
        let matched = try coveredPixels(matching: "mute")
        XCTAssertGreaterThan(unmatched, 0, "the line itself never drew")
        XCTAssertGreaterThan(
            matched, unmatched,
            "the highlight covered no more of the line than the glyphs did — the ground never drew"
        )
    }

    /// The freeze this component exists to answer. An attributed string keeps the fonts and inks
    /// it was built with; `AppThemeRefresh`'s sweep re-resolves a *recorded role* on a label and
    /// cannot reach inside one, so a highlighted row would keep the previous theme's typeface.
    func testAHighlightedLineFollowsALiveThemeChange() throws {
        AppThemePalette.set(.system)
        let label = SearchMatchLabel(role: .body)
        label.show("Mute a session", matching: "mute")

        let field = try XCTUnwrap(descendants(in: label).compactMap { $0 as? NSTextField }.first)
        let before = try XCTUnwrap(
            field.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )

        // Cyberpunk states a monospaced typeface, so the switch has to move the *font*, not only
        // the palette — which is the half a colour sweep would have got right on its own.
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeLibrary.current.id))

        let after = try XCTUnwrap(
            field.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertNotEqual(
            before.fontName, after.fontName,
            "the matched run stayed in the previous theme's typeface"
        )
    }

    // MARK: - Text Field

    /// The bezel is the whole point: a stock field draws a system-shaped, system-coloured well,
    /// and the themed one draws its own. Leaving AppKit's background on would paint a rectangle
    /// under it.
    func testAThemedFieldDrawsNoStockChrome() {
        let field = ThemedTextField()
        XCTAssertFalse(field.isBezeled)
        XCTAssertFalse(field.drawsBackground)
        XCTAssertEqual(field.focusRingType, .none)
    }

    /// AppKit draws a placeholder in a *system* grey, which is one of the colours a styled page
    /// has already moved away from.
    func testAPlaceholderIsRestatedInTheThemeColour() {
        let field = ThemedTextField()
        field.placeholderString = "/bin/bash"

        let attributed = field.placeholderAttributedString
        XCTAssertEqual(attributed?.string, "/bin/bash")
        XCTAssertNotNil(
            attributed?.attribute(.foregroundColor, at: 0, effectiveRange: nil),
            "the placeholder kept AppKit's own grey"
        )
    }

    /// `NSTextField(string:)` imports a class factory method, which is free to hand back a plain
    /// `NSTextField` — the subclass would then be one only by the annotation at the call site.
    func testTheStringInitializerReallyBuildsAThemedField() {
        let field = ThemedTextField(string: "claudedb")
        XCTAssertEqual(field.stringValue, "claudedb")
        XCTAssertFalse(field.isBezeled, "init(string:) bypassed the themed setup")
    }

    /// A field is not a chip you can type in.
    ///
    /// It borrowed `chipHeight` for as long as it was treated as one, and the theme's rule is
    /// two points thick on each side: at 26 the twenty points left inside carried a 13pt face
    /// with about three points of air, and the text read as wedged against the border. Pinned
    /// with the air stated, so the next change to the scale has to mean it.
    func testAFieldLeavesRealAirAroundItsText() {
        let field = ThemedTextField(string: "claudedb")
        let line = ceil((field.font ?? Design.Typography.body()).boundingRectForFont.height)

        XCTAssertEqual(field.intrinsicContentSize.height, Design.Size.fieldHeight)
        XCTAssertGreaterThanOrEqual(
            (Design.Size.fieldHeight - line) / 2,
            Design.Spacing.small,
            "the field is back to holding its text against the border"
        )
    }

    /// The two fields given a frame rather than asked for their size — an alert's accessory and
    /// the rename prompt — restate the same height, or the one field the app puts in front of a
    /// decision is the tightest one it draws.
    func testFieldsPlacedByFrameUseTheSameHeight() {
        XCTAssertEqual(TextPromptDefaults.fieldHeight, Design.Size.fieldHeight)
        XCTAssertEqual(SidebarDefaults.renameFieldHeight, Design.Size.fieldHeight)
    }

    // MARK: - Backdrop Overlays

    /// The second ground, and the rule that keeps it straight: **a `BackdropOverlay` may not read
    /// `Design.Text` or `Design.Surface`.**
    ///
    /// The window has two grounds. The chrome's is `Design.Surface.ground`, which the app theme
    /// owns and which `Design.Text` is calibrated against — but a terminal pane paints the
    /// *window* with the terminal palette's background, so the toolbar and the pane's floating
    /// cards sit on a colour the app theme knows nothing about. A light app theme over a dark
    /// terminal wrote a near-black session title and an invisible usage pill straight across it.
    ///
    /// The type is what fixes it: `BackdropOverlay` hands its subclass an `Ink` derived from the
    /// backdrop, and the toolbar's item factory and the pane's `addOverlay` both take that type,
    /// so a new button cannot be added without one. This is the part the compiler cannot check —
    /// that having been handed the right ink, the view actually uses it.
    ///
    /// `Design.Radius`, `Design.Typography`, `Design.Spacing`, `Design.Diff` and `Design.Status`
    /// stay allowed: geometry is ground-independent, and a semantic colour that stopped meaning
    /// "added" would cost more than the contrast it bought.
    func testBackdropOverlaysDoNotReadChromeRoles() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "the source tree was not found from #filePath")

        var overlayFiles: [String] = []
        var offences: [String] = []

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // The base class itself explains the rule and names the roles it forbids.
            // Matches `: BackdropOverlay {` and `: BackdropOverlay, Protocol {` alike — the
            // first version of this rule saw only the former, which is a rule that stops
            // working the first time someone adds a conformance.
            let declaresOverlay = text.range(of: #": BackdropOverlay\s*[{,]"#, options: .regularExpression) != nil
            guard declaresOverlay, !file.lastPathComponent.hasPrefix("BackdropOverlay")
            else { continue }
            overlayFiles.append(file.lastPathComponent)

            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("*") else { continue }
                guard code.contains("Design.Text.") || code.contains("Design.Surface.") else { continue }
                offences.append("\(file.lastPathComponent):\(index + 1) — \(code)")
            }
        }

        XCTAssertFalse(overlayFiles.isEmpty, "no BackdropOverlay subclasses were found to check")
        XCTAssertEqual(
            offences, [],
            "a BackdropOverlay read the chrome's roles. It is drawn on the window's backdrop, "
                + "not on Design.Surface.ground — colour it from the Ink handed to applyInk(_:)."
        )
    }

    /// Which tone the ink is cut from is *measured* against the ground rather than guessed from a
    /// luminance threshold, so a mid-tone terminal — and there are plenty — gets the one that
    /// actually reads rather than the one a constant happened to pick.
    func testInkTakesWhicheverToneReadsOnTheGround() {
        for ground in [NSColor.black, NSColor(hex: "#07070B")!, NSColor(hex: "#1C0F1E")!] {
            let ink = Design.Text.on(ground)
            XCTAssertGreaterThan(
                ThemeContrast.ratio(ink.label, ground), ThemeContrast.minimumRatio,
                "ink on \(ground) is not legible"
            )
        }

        // Paper takes black, night takes white — and the two must not agree.
        let onPaper = Design.Text.on(.white)
        let onInk = Design.Text.on(.black)
        XCTAssertNotEqual(onPaper.base, onInk.base, "the ink did not flip between grounds")
    }

    /// Every tier and surface is the *base* at an opacity, never a dimming of the tier above it:
    /// `withAlphaComponent` replaces alpha rather than scaling it, so chaining reads as a scale
    /// it is not — the same trap that once made disabled buttons the loudest thing on the page.
    func testEveryInkValueIsCutFromTheOneBaseTone() {
        let ink = Design.Text.on(NSColor(hex: "#101014")!)
        let expected = ink.base.usingColorSpace(.sRGB)!

        for value in [ink.label, ink.secondary, ink.tertiary, ink.quaternary,
                      ink.surface, ink.surfaceHover, ink.border] {
            let resolved = value.usingColorSpace(.sRGB)!
            XCTAssertEqual(resolved.redComponent, expected.redComponent, accuracy: 0.001)
            XCTAssertEqual(resolved.greenComponent, expected.greenComponent, accuracy: 0.001)
            XCTAssertEqual(resolved.blueComponent, expected.blueComponent, accuracy: 0.001)
        }

        XCTAssertGreaterThan(ink.label.alphaComponent, ink.secondary.alphaComponent)
        XCTAssertGreaterThan(ink.secondary.alphaComponent, ink.tertiary.alphaComponent)
        XCTAssertGreaterThan(ink.tertiary.alphaComponent, ink.quaternary.alphaComponent)
    }

    /// The third thing that moves the ink, and the one that announces itself through no event:
    /// under the System theme the backdrop is a *dynamic* colour, so macOS switching to dark at
    /// sunset changes what it resolves to while the theme and the backdrop object both stay
    /// exactly as they were. Found by review rather than by a screenshot, because it only shows
    /// up at dusk.
    func testTheInkFollowsAChangeOfSystemAppearance() {
        AppThemePalette.set(.system)
        WindowBackdrop.set(.chrome)

        let spy = InkSpy(frame: NSRect(x: 0, y: 0, width: 100, height: 22))

        spy.appearance = NSAppearance(named: .darkAqua)
        let onDark = spy.applied.last
        spy.appearance = NSAppearance(named: .aqua)
        let onLight = spy.applied.last

        XCTAssertNotNil(onDark, "no ink was applied when the appearance changed")
        XCTAssertNotEqual(
            onDark?.base, onLight?.base,
            "the ink did not follow the system appearance — a dynamic backdrop changed meaning "
                + "under it and nothing asked again"
        )
    }

    // MARK: - Split Control

    /// Two halves of one thing draw **one** silhouette.
    ///
    /// The Open In control was two `ThemedIconButton`s in a group, and the group is right for
    /// four buttons that act on four different things. These two act on one, so spaced apart they
    /// read as an app's icon with an unrelated chevron beside it — and the hover said so out
    /// loud, each half raising a rounded rect of its own with a seam down the middle of a control
    /// the pointer had just claimed was single.
    func testTheSplitControlDrawsOneSurfaceAcrossBothHalves() throws {
        AppThemePalette.set(.system)
        let control = splitControl()
        let samples = try surfaceSamples(across: control)

        XCTAssertGreaterThan(
            samples.first?.alphaComponent ?? 0, 0.05,
            "the plate is not drawn at all — the rest of this test would pass on empty air"
        )
        for sample in samples {
            XCTAssertEqual(
                sample, samples[0],
                "the plate changes colour across its own width — the halves are drawing "
                    + "surfaces of their own again"
            )
        }
    }

    /// Hovering raises the half under the pointer and nothing else, **inside** the plate.
    ///
    /// Both halves of the claim matter. The raise has to be visible — a split control whose two
    /// targets look identical is a control that will be pressed wrong — and it has to stop at the
    /// plate's own outline, which is what the corner sample is for: a half filling its own square
    /// rect squares off the plate's rounded end, which is the seam again at the other edge.
    func testHoveringRaisesOnlyTheHalfUnderThePointerAndStaysInsideThePlate() throws {
        AppThemePalette.set(.system)

        for (name, hovered) in [("press", \SplitIconButtonView.action),
                                ("chevron", \SplitIconButtonView.chevron)] {
            let control = splitControl()
            let resting = try surfaceSamples(across: control)

            control[keyPath: hovered].mouseEntered(with: hoverEvent())
            let raised = try surfaceSamples(across: control)

            let lit = zip(resting, raised).filter { $0.0 != $0.1 }.count
            XCTAssertGreaterThan(lit, 0, "hovering the \(name) half raised nothing")
            XCTAssertLessThan(
                lit, resting.count,
                "hovering the \(name) half raised the whole plate — the other half is a "
                    + "separate target and has to keep saying so"
            )

            for corner in try cornerSamples(of: control) {
                XCTAssertLessThan(
                    corner.alphaComponent, 0.5,
                    "the \(name) half's raise squared off the plate's corner — it is drawing "
                        + "its own rect rather than filling inside the shared silhouette"
                )
            }
        }
    }

    /// The plate is furniture; the halves are the buttons. Announcing all three would report one
    /// control as three objects, and announcing only the plate would lose the two names that say
    /// what each press does.
    func testTheSplitControlAnnouncesItsHalvesAndNotItself() {
        let control = splitControl()

        XCTAssertFalse(control.isAccessibilityElement())
        XCTAssertEqual(control.accessibilityRole(), .group)
        XCTAssertTrue(control.action.isAccessibilityElement())
        XCTAssertEqual(control.action.accessibilityTitle(), "Open in Finder")
        XCTAssertEqual(control.chevron.accessibilityTitle(), "Choose an app")

        var opened = 0
        control.action.onPress = { opened += 1 }
        XCTAssertTrue(control.action.accessibilityPerformPress())
        XCTAssertEqual(opened, 1, "the press half does nothing when VoiceOver presses it")
    }

    /// The plate is read from the ink at draw time, so a session on another palette — or a live
    /// theme switch — recolours it with nothing recorded to go stale.
    func testTheSplitControlFollowsTheBackdropItIsDrawnOn() throws {
        let original = WindowBackdrop.ground
        defer { WindowBackdrop.set(original) }

        WindowBackdrop.set(.terminal(NSColor(hex: "#0B0B0F")!))
        let control = splitControl()
        let onNight = try surfaceSamples(across: control)

        WindowBackdrop.set(.terminal(NSColor(hex: "#FAFAF7")!))
        let onPaper = try surfaceSamples(across: control)

        XCTAssertNotEqual(
            onNight.first, onPaper.first,
            "the plate kept the colour it was first drawn in — it is not reading its ink"
        )
    }

    /// One plate, welded: the halves share an edge and the plate is exactly as wide as they are.
    /// A gap here is the group this control replaced.
    func testTheSplitControlIsExactlyItsTwoHalvesWide() {
        let control = splitControl()

        XCTAssertEqual(control.action.frame.maxX, control.chevron.frame.minX, accuracy: 0.5)
        XCTAssertEqual(
            control.frame.width,
            Design.Size.toolbarButtonWidth + Design.Size.splitMenuWidth,
            accuracy: 0.5
        )
        XCTAssertEqual(control.frame.height, Design.Size.toolbarButtonHeight, accuracy: 0.5)
    }

    /// A control laid out and drawn the way the header draws it, in a window that is never shown.
    private func splitControl() -> SplitIconButtonView {
        let control = SplitIconButtonView(
            action: ThemedIconButton(
                symbolName: "arrow.up.forward.app",
                accessibility: "Open in Finder"
            ),
            chevron: ThemedIconButton(
                symbolName: DesignSymbols.chevron,
                accessibility: "Choose an app",
                target: .splitMenu
            )
        )

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
        host.addSubview(control)
        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return control
    }

    /// The plate's fill along its middle row, sampled inside its own border and past the corners
    /// so the curve is never what a comparison is reading.
    private func surfaceSamples(across control: SplitIconButtonView) throws -> [NSColor] {
        let rep = try XCTUnwrap(control.bitmapImageRepForCachingDisplay(in: control.bounds))
        control.cacheDisplay(in: control.bounds, to: rep)

        // The rep is sized in pixels; on a Retina backing that is twice the points the geometry
        // is stated in, and sampling in points would read the wrong column.
        let scale = CGFloat(rep.pixelsWide) / control.bounds.width
        // Above the glyphs rather than through them: the icon and the chevron are centred in a
        // 16pt slot in a 28pt plate, so a row taken across the middle reads *artwork* and would
        // report a seam in every state including the ones that have none. Below the plate's own
        // border, and inset past its corners, so the curve is never what is being compared.
        let row = Int((Design.Spacing.tight * scale).rounded())
        let inset = Design.Radius.control(fitting: control.bounds.size) + 1

        return try stride(from: inset, to: control.bounds.width - inset, by: 2).map { x in
            try XCTUnwrap(
                rep.colorAt(x: Int((x * scale).rounded()), y: row),
                "the plate could not be sampled at \(x)"
            ).usingColorSpace(.sRGB)!
        }
    }

    /// The four outermost pixels, which a rounded plate leaves clear and a square fill does not.
    private func cornerSamples(of control: SplitIconButtonView) throws -> [NSColor] {
        let rep = try XCTUnwrap(control.bitmapImageRepForCachingDisplay(in: control.bounds))
        control.cacheDisplay(in: control.bounds, to: rep)

        return try [(0, 0), (rep.pixelsWide - 1, 0),
                    (0, rep.pixelsHigh - 1), (rep.pixelsWide - 1, rep.pixelsHigh - 1)]
            .map { try XCTUnwrap(rep.colorAt(x: $0.0, y: $0.1)) }
    }

    private func hoverEvent() -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
    }

    // MARK: - Content Surfaces

    func testThemedContentContainersStartTransparent() {
        XCTAssertFalse(ThemedScrollView().drawsBackground)
        XCTAssertFalse(ThemedClipView().drawsBackground)
        XCTAssertEqual(ThemedTableView().backgroundColor, .clear)
        XCTAssertEqual(ThemedOutlineView().backgroundColor, .clear)
        XCTAssertFalse(ThemedTextView(frame: .zero, textContainer: nil).drawsBackground)
    }

    func testThemedScrollViewInstallsScrollerBoundariesWithoutChangingPolicy() throws {
        let scroll = ThemedScrollView()
        let vertical = try XCTUnwrap(scroll.verticalScroller as? ThemedScroller)
        let horizontal = try XCTUnwrap(scroll.horizontalScroller as? ThemedScroller)

        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertEqual(scroll.scrollerStyle, NSScroller.preferredScrollerStyle)
        XCTAssertTrue(ThemedScroller.isCompatibleWithOverlayScrollers)
        if case .chrome = vertical.inkSource {
            // Expected: ordinary scroll views sit on the app theme's chrome.
        } else {
            XCTFail("vertical scrollbar did not use chrome ink")
        }
        if case .chrome = horizontal.inkSource {
            // Expected.
        } else {
            XCTFail("horizontal scrollbar did not use chrome ink")
        }

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        XCTAssertTrue(scroll.verticalScroller === vertical)
        XCTAssertTrue(scroll.horizontalScroller === horizontal)

        scroll.scrollerStyle = scroll.scrollerStyle == .overlay ? .legacy : .overlay
        XCTAssertTrue(scroll.verticalScroller === vertical)
        XCTAssertTrue(scroll.horizontalScroller === horizontal)
    }

    func testScrollerKeepsSystemRenderingAndDistinguishesAuthoredThemes() throws {
        func configured(_ scroll: NSScrollView) throws -> NSScroller {
            scroll.frame = NSRect(x: 0, y: 0, width: 120, height: 180)
            scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 720))
            scroll.scrollerStyle = .legacy
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = false
            scroll.layoutSubtreeIfNeeded()

            let scroller = try XCTUnwrap(scroll.verticalScroller)
            scroller.controlSize = .regular
            scroller.isEnabled = true
            scroller.doubleValue = 0.35
            scroller.knobProportion = 0.25
            scroller.appearance = NSAppearance(named: .darkAqua)
            return scroller
        }

        AppThemePalette.set(.system)
        let systemScroller = try XCTUnwrap(configured(ThemedScrollView()) as? ThemedScroller)
        XCTAssertTrue(
            systemScroller.delegatesDrawingToAppKit,
            "System must hand scrollbar drawing back to AppKit"
        )
        let system = try renderedPNG(of: systemScroller)
        attach(system, named: "scroller-system")

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let cyberScroller = try XCTUnwrap(configured(ThemedScrollView()) as? ThemedScroller)
        XCTAssertFalse(cyberScroller.delegatesDrawingToAppKit)
        let cyber = try renderedPNG(of: cyberScroller)
        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        let swissScroller = try XCTUnwrap(configured(ThemedScrollView()) as? ThemedScroller)
        XCTAssertFalse(swissScroller.delegatesDrawingToAppKit)
        let swiss = try renderedPNG(of: swissScroller)
        attach(cyber, named: "scroller-cyberpunk")
        attach(swiss, named: "scroller-swiss-minimalist")

        XCTAssertNotEqual(cyber, system)
        XCTAssertNotEqual(swiss, system)
        XCTAssertNotEqual(cyber, swiss)
    }

    func testOpenStepMovesALegacyScrollerAndItsReservationToTheLeadingEdge() throws {
        let scroll = ThemedScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 720))
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false

        AppThemeLibrary.apply(.system)
        scroll.layoutSubtreeIfNeeded()
        let trailingScroller = try XCTUnwrap(scroll.verticalScroller).frame
        let trailingContent = scroll.contentView.frame
        XCTAssertGreaterThanOrEqual(trailingScroller.minX, trailingContent.maxX)

        AppThemeLibrary.apply(AppThemeStyles.openStep)
        scroll.layoutSubtreeIfNeeded()
        let leadingScroller = try XCTUnwrap(scroll.verticalScroller).frame
        let leadingContent = scroll.contentView.frame
        XCTAssertLessThanOrEqual(leadingScroller.maxX, leadingContent.minX)
        XCTAssertEqual(leadingContent.width, trailingContent.width, accuracy: 0.5)
        XCTAssertEqual(leadingScroller.width, trailingScroller.width, accuracy: 0.5)

        scroll.tile()
        XCTAssertEqual(scroll.contentView.frame, leadingContent,
                       "repeated layout must not walk the document across the window")

        AppThemeLibrary.apply(.system)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(scroll.verticalScroller).frame.minX,
            scroll.contentView.frame.maxX,
            "leaving OPENSTEP must restore AppKit's native trailing geometry"
        )
    }

    func testOpenStepOverlayScrollerFloatsOnTheLeftWithoutMovingContent() throws {
        let scroll = ThemedScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 720))
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false

        AppThemeLibrary.apply(.system)
        scroll.layoutSubtreeIfNeeded()
        let nativeContent = scroll.contentView.frame

        AppThemeLibrary.apply(AppThemeStyles.openStep)
        scroll.layoutSubtreeIfNeeded()
        let scroller = try XCTUnwrap(scroll.verticalScroller)
        XCTAssertLessThan(scroller.frame.midX, scroll.bounds.midX)
        XCTAssertEqual(scroll.contentView.frame, nativeContent)
    }

    func testScrollerRedrawsWhenItsInkSourceChanges() {
        let chrome = ThemedScroller(frame: NSRect(x: 0, y: 0, width: 17, height: 180))
        let backdrop = ThemedScroller(
            frame: NSRect(x: 20, y: 0, width: 17, height: 180),
            inkSource: .backdrop
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 180))
        root.addSubview(chrome)
        root.addSubview(backdrop)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        defer { window.orderOut(nil) }

        chrome.needsDisplay = false
        NotificationCenter.default.post(
            AppThemeDidChange(themeID: AppThemeStyles.cyberpunk.id)
        )
        XCTAssertTrue(chrome.needsDisplay)

        backdrop.needsDisplay = false
        NotificationCenter.default.post(WindowBackdropDidChange(color: .black))
        XCTAssertTrue(backdrop.needsDisplay)
    }

    /// A scroller inside a scroll view is AppKit's to fade — it must not also be ours, or two
    /// owners would fight over one alpha.
    func testAScrollbarInsideAScrollViewIsLeftEntirelyToAppKit() throws {
        let scroll = ThemedScrollView(frame: NSRect(x: 0, y: 0, width: 120, height: 180))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 720))
        scroll.hasVerticalScroller = true
        scroll.layoutSubtreeIfNeeded()

        let scroller = try XCTUnwrap(scroll.verticalScroller as? ThemedScroller)
        XCTAssertEqual(scroller.alphaValue, 1)

        scroller.doubleValue = 0.4
        XCTAssertEqual(scroller.alphaValue, 1, "a managed scroller must not take its own fade")
    }

    /// The terminal's scrollbar: a bare `NSScroller` in an ordinary view, which AppKit neither
    /// fades nor draws. Standing alone means owning both, and the resting state is down.
    func testAStandaloneScrollbarRestsDownAndComesUpOnlyForMovement() throws {
        Design.Motion.reduceMotionOverrideForTesting = true
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let scroller = standaloneScroller()
        XCTAssertEqual(scroller.alphaValue, 0, "a standalone scrollbar starts out of the way")

        // What a streaming agent produces: the buffer grows under a viewport pinned to the
        // bottom, so the thumb shrinks while the position stays exactly where it was.
        scroller.knobProportion = 0.05
        scroller.knobProportion = 0.02
        XCTAssertEqual(
            scroller.alphaValue,
            0,
            "output arriving under a pinned viewport is not scrolling and must not raise the bar"
        )

        scroller.doubleValue = 0.6
        XCTAssertEqual(scroller.alphaValue, 1, "scrolling raises it")
    }

    /// The bar goes away on its own, and waits while the pointer is on it — otherwise the thumb
    /// that just appeared could not be grabbed.
    func testAStandaloneScrollbarLeavesAfterItsHoldUnlessTheHandIsOnIt() throws {
        Design.Motion.reduceMotionOverrideForTesting = true
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let scroller = standaloneScroller()
        scroller.doubleValue = 0.6
        XCTAssertEqual(scroller.alphaValue, 1)

        waitForRunLoop(Design.Motion.scrollerHold + 0.2)
        XCTAssertEqual(scroller.alphaValue, 0, "the bar leaves on its own after the hold")

        scroller.mouseEntered(with: crossingEvent())
        XCTAssertEqual(scroller.alphaValue, 1, "reaching for it brings it back")
        waitForRunLoop(Design.Motion.scrollerHold + 0.2)
        XCTAssertEqual(scroller.alphaValue, 1, "and it waits there while the pointer is on it")

        scroller.mouseExited(with: crossingEvent())
        waitForRunLoop(Design.Motion.scrollerHold + 0.2)
        XCTAssertEqual(scroller.alphaValue, 0)
    }

    /// Nothing to scroll, nothing to show: a program that takes the alternate screen buffer
    /// disables the scroller, and it must not leave a bar behind while its hold runs out.
    func testAStandaloneScrollbarGoesWithTheScrollbackItReported() throws {
        Design.Motion.reduceMotionOverrideForTesting = true
        defer { Design.Motion.reduceMotionOverrideForTesting = nil }

        let scroller = standaloneScroller()
        scroller.doubleValue = 0.6
        XCTAssertEqual(scroller.alphaValue, 1)

        scroller.isEnabled = false
        XCTAssertEqual(scroller.alphaValue, 0)

        scroller.doubleValue = 0.2
        XCTAssertEqual(scroller.alphaValue, 0, "a disabled scrollbar has nothing to report")
    }

    /// A scroller SwiftTerm's way: added to a plain view, enabled, with a position of its own.
    private func standaloneScroller() -> ThemedScroller {
        let scroller = ThemedScroller(
            frame: NSRect(x: 0, y: 0, width: 17, height: 180),
            inkSource: .backdrop
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 180))
        host.addSubview(scroller)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        scroller.isEnabled = true
        return scroller
    }

    private func waitForRunLoop(_ interval: TimeInterval) {
        let settled = expectation(description: "the run loop advanced")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { settled.fulfill() }
        wait(for: [settled], timeout: interval + 5)
    }

    private func crossingEvent() -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
    }

    func testHorizontalOnlyScrollSurfaceHandsVerticalGestureToConversation() throws {
        let outer = ScrollWheelSpy(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 640))
        outer.documentView = document

        let codeScroll = ThemedScrollView(frame: NSRect(x: 20, y: 20, width: 240, height: 80))
        codeScroll.hasHorizontalScroller = true
        codeScroll.hasVerticalScroller = false
        codeScroll.forwardsVerticalScrollToAncestor = true
        document.addSubview(codeScroll)

        codeScroll.scrollWheel(with: try wheelEvent(horizontal: 0, vertical: 12))
        XCTAssertEqual(outer.receivedWheelEvents, 1)

        var localEvents = 0
        codeScroll.onUserScroll = { localEvents += 1 }
        codeScroll.scrollWheel(with: try wheelEvent(horizontal: 12, vertical: 1))
        XCTAssertEqual(outer.receivedWheelEvents, 1)
        XCTAssertEqual(localEvents, 1, "A horizontal gesture escaped the code block")
    }

    func testNestedScrollKeepsVerticalMomentumLockedWhenTailTurnsDiagonal() {
        var router = NestedScrollGestureRouter()

        XCTAssertTrue(router.forwardsToAncestor(
            deltaX: 1,
            deltaY: 18,
            phase: .began,
            momentumPhase: []
        ))
        XCTAssertTrue(router.forwardsToAncestor(
            deltaX: 5,
            deltaY: 2,
            phase: .changed,
            momentumPhase: []
        ), "diagonal noise stole an in-flight vertical gesture")
        XCTAssertTrue(router.forwardsToAncestor(
            deltaX: 0,
            deltaY: 0,
            phase: .ended,
            momentumPhase: []
        ), "the direct-gesture end discarded the axis before momentum began")
        XCTAssertTrue(router.forwardsToAncestor(
            deltaX: 4,
            deltaY: 1,
            phase: [],
            momentumPhase: .began
        ), "momentum did not inherit the gesture's vertical axis")
        XCTAssertTrue(router.forwardsToAncestor(
            deltaX: 3,
            deltaY: 1,
            phase: [],
            momentumPhase: .changed
        ), "the momentum tail changed destination under a stationary pointer")
        XCTAssertTrue(router.forwardsToAncestor(
            deltaX: 0,
            deltaY: 0,
            phase: [],
            momentumPhase: .ended
        ))

        XCTAssertFalse(router.forwardsToAncestor(
            deltaX: 12,
            deltaY: 1,
            phase: .began,
            momentumPhase: []
        ), "a new horizontal gesture inherited the previous vertical lock")
    }

    /// A wrapper that only changes its type name is not a themed component. The process-tree
    /// header used to be such a seam; pin that it now paints a role from the active theme.
    func testThemedTableHeaderPaintsTheActiveTheme() {
        func sampled(under theme: AppTheme) -> NSColor {
            AppThemePalette.set(theme)

            let table = ThemedTableView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
            table.addTableColumn(NSTableColumn(identifier: .init("Name")))

            let header = ThemedTableHeaderView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
            table.headerView = header

            let rep = header.bitmapImageRepForCachingDisplay(in: header.bounds)!
            header.cacheDisplay(in: header.bounds, to: rep)
            return rep.colorAt(x: 8, y: 12)!.usingColorSpace(.sRGB)!
        }

        let cyber = sampled(under: AppThemeStyles.cyberpunk)
        let swiss = sampled(under: AppThemeStyles.swissMinimalist)
        XCTAssertNotEqual(cyber.hexString, swiss.hexString)
    }

    // MARK: - The Rule Itself

    /// Runs the same SwiftSyntax checker as the application build. The policy and exception list
    /// therefore have one owner; the test cannot quietly drift to a second regex vocabulary.
    func testNoStockControlsOutsideTheDesignSystem() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ThreadingTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["scripts/check_theme_boundaries.sh"]
        task.currentDirectoryURL = root

        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        task.waitUntilExit()

        let report = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(task.terminationStatus, 0, report)
    }

    func testRuntimeAuditRejectsRawControlsButAllowsThemedComponentsAndLabels() {
        let root = NSView()
        root.addSubview(ThemedButton())
        root.addSubview(NSTextField(labelWithString: "Safe label"))

        XCTAssertEqual(ThemeBoundaryAudit.violations(in: root), [])

        let raw = NSButton()
        root.addSubview(raw)
        let violations = ThemeBoundaryAudit.violations(in: root)

        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.className, "NSButton")
    }

    func testRuntimeAuditAcceptsNamedSystemChromeBoundaries() {
        let root = NSView()
        root.addSubview(ThemeSwatchView())

        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        let scrollEdgeEffect = NSVisualEffectView()
        scroll.addSubview(scrollEdgeEffect)
        let privateChromeWrapper = NSView()
        let nestedScrollEdgeEffect = NSVisualEffectView()
        privateChromeWrapper.addSubview(nestedScrollEdgeEffect)
        scroll.addSubview(privateChromeWrapper)
        root.addSubview(scroll)

        XCTAssertEqual(ThemeBoundaryAudit.violations(in: root), [])

        let documentEffect = NSVisualEffectView()
        scroll.documentView = NSView()
        scroll.documentView?.addSubview(documentEffect)
        XCTAssertEqual(
            ThemeBoundaryAudit.violations(in: root).map(\.className),
            ["NSVisualEffectView"]
        )
    }

    func testThemedScrollViewDoesNotExemptARawReplacementScroller() {
        let scroll = ThemedScrollView()
        scroll.verticalScroller = NSScroller(frame: .zero)
        scroll.hasVerticalScroller = true

        XCTAssertTrue(
            ThemeBoundaryAudit.violations(in: scroll).contains { $0.className == "NSScroller" }
        )
    }

    func testPromptUsesOnlyThemedRuntimeBoundaries() {
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: PromptView()), [])
    }

    func testPromptCanTakeFocusAndShowsItOnTheWholeSurface() {
        let prompt = PromptView(frame: NSRect(x: 20, y: 20, width: 720, height: 116))
        prompt.placeholder = "Describe a task or ask a question"

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 156))
        root.addSubview(prompt)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        root.layoutSubtreeIfNeeded()
        guard let editor = descendants(in: prompt).first(where: { $0 is NSTextView }) as? NSTextView else {
            return XCTFail("PromptView did not contain its text editor")
        }

        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.isSelectable)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(prompt.layer?.borderWidth, Design.Accessibility.focusRingWidth)
        XCTAssertEqual(prompt.layer?.borderColor, Design.Surface.accent.cgColor)

        prompt.reapplyRecordedSurfaceForTesting()
        XCTAssertEqual(
            prompt.layer?.borderWidth,
            Design.Accessibility.focusRingWidth,
            "a theme refresh discarded the focused border geometry"
        )

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(prompt.layer?.borderWidth, Design.Radius.border)
        XCTAssertEqual(prompt.layer?.borderColor, Design.Surface.border.cgColor)
    }

    func testOnScreenTextFieldContainsOnlyItsNamedPrivateEditorBoundary() {
        let field = ThemedTextField(string: "Editable")
        field.frame = NSRect(x: 20, y: 20, width: 240, height: 28)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 68))
        root.addSubview(field)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        defer { window.orderOut(nil) }

        XCTAssertEqual(ThemeBoundaryAudit.violations(in: window), [])
    }

    // MARK: - Component Gallery

    func testComponentGalleryCataloguesEveryConcreteDesignComponent() throws {
        XCTAssertEqual(
            ComponentGalleryViewController.componentNames,
            [
                "BackdropOverlay",
                "BackdropThemedControl",
                "BrowserAnnotationOverlay",
                "BrowserDeviceToolbar",
                "BrowserFindBar",
                "ChipView",
                "ConversationContextRailView",
                "ConversationHandoffView",
                "CompareInspectorView",
                "ExecutionAuditEventView",
                "FileActivityMapView",
                "GlyphView",
                "HoverPopoverScheduler",
                "ImageCompareCanvas",
                "ImageCompareView",
                "MediaInspectorCanvas",
                "MediaInspectorDocumentView",
                "MediaInspectorView",
                "MorphingTitleLabel",
                "NavigatorGridItemView",
                "PaneFooterView",
                "PaneHeaderView",
                "PromptCompletionPresenter",
                "PromptView",
                "SearchMatchLabel",
                "SemanticSceneView",
                "SeparatorView",
                "ShortcutRecorderView",
                "SidebarBackdropView",
                "SidebarBrandView",
                "SplitIconButtonView",
                "SubagentSummaryView",
                "SubmissionStatusView",
                "ThreadingMarkView",
                "ThemeSwatchImage",
                "ThemeSwatchView",
                "ThemedAlert",
                "ThemedButton",
                "ThemedCheckbox",
                "ThemedClipView",
                "ThemedControl",
                "ThemedDisclosureRow",
                "ThemedFileIconView",
                "ThemedFloatingGlyphView",
                "ThemedOutlineView",
                "ThemedPopUp",
                "ThemedPopover",
                "ThemedPopoverChromeView",
                "ThemedProgressBar",
                "ThemedScroller",
                "ThemedScrollView",
                "ThemedSegmentedControl",
                "ThemedSpinner",
                "ThemedSplitView",
                "ListSelectionStrength",
                "ThemedTableHeaderView",
                "ThemedTableRowView",
                "ThemedTableView",
                "ThemedTabItemView",
                "ThemedTabStripView",
                "ThemedTextField",
                "ThemedSearchField",
                "ThemedTextView",
                "ThemedToggle",
                "ThemedSurface",
                "ThemedSurfaceView",
                "ThemeRedraw",
                "ThemedIconButton",
                "ThemedImagePreview",
                "ToastPresenter",
                "ToastView",
                "ToolbarButtonGroupView",
                "WorkingOrbView",
                "WindowBackdrop",
                "WindowChromeButton",
                "WindowChromeFrameView",
                "WindowCommandBandView",
                "WindowTitleBandView"
            ]
        )

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let designDirectory = root.appendingPathComponent("Sources/Threading/UI/Design")
        let declarations = try FileManager.default.contentsOfDirectory(
            at: designDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")

        let pattern = try NSRegularExpression(
            pattern: #"(?m)^(?:final )?class\s+([A-Za-z_][A-Za-z0-9_]*)"#
        )
        let range = NSRange(declarations.startIndex..., in: declarations)
        let declaredComponents: Set<String> = Set(
            pattern.matches(in: declarations, range: range).compactMap { match -> String? in
                guard let nameRange = Range(match.range(at: 1), in: declarations) else { return nil }
                return String(declarations[nameRange])
            }
        )
        let missing = declaredComponents.subtracting(ComponentGalleryViewController.componentNames)

        XCTAssertEqual(
            missing,
            Set<String>(),
            "new public design components need an interactive Component Gallery story"
        )
    }

    func testComponentGalleryTreeContainsNoRawAppKitChrome() {
        let controller = ComponentGalleryWindowController()
        let window = controller.window!
        window.setContentSize(NSSize(width: 1_020, height: 780))

        XCTAssertEqual(ThemeBoundaryAudit.violations(in: window), [])
    }

    func testMainWindowTreeContainsNoRawAppKitChrome() {
        let controller = MainWindowController()
        let window = controller.window!
        window.setContentSize(NSSize(width: 1_200, height: 760))

        let violations = ThemeBoundaryAudit.violations(in: window)
        XCTAssertEqual(
            violations,
            [],
            ThemeBoundaryAudit.failureDescription(
                for: violations,
                windowTitle: "MainWindowController"
            )
        )
    }

    func testComponentGalleryOpensAtTheFirstStory() throws {
        let controller = ComponentGalleryViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_020, height: 780)
        controller.view.layoutSubtreeIfNeeded()

        let scroll = try XCTUnwrap(
            descendant(withIdentifier: "gallery.catalogue", in: controller.view) as? NSScrollView
        )
        let document = try XCTUnwrap(scroll.documentView)
        let firstStory = try XCTUnwrap(
            descendant(withIdentifier: "gallery.story.ThemedButton", in: document)
        )
        let firstStoryFrame = document.convert(firstStory.bounds, from: firstStory)

        XCTAssertTrue(
            document.visibleRect.intersects(firstStoryFrame),
            "the gallery opened away from its first component"
        )
    }

    func testComponentGalleryAppearanceSwitchIsWindowLocal() {
        let originalAppAppearance = NSApp.appearance
        let controller = ComponentGalleryViewController()
        controller.loadView()

        controller.setAppearance(.dark)
        XCTAssertEqual(controller.appearanceMode, .dark)
        XCTAssertEqual(controller.view.appearance?.name, .darkAqua)
        XCTAssertTrue(NSApp.appearance === originalAppAppearance)

        controller.setAppearance(.light)
        XCTAssertEqual(controller.appearanceMode, .light)
        XCTAssertEqual(controller.view.appearance?.name, .aqua)
        XCTAssertTrue(NSApp.appearance === originalAppAppearance)
    }

    func testComponentGalleryAppearanceSwitchReResolvesLayerBackedSurfaces() throws {
        let originalAppAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = originalAppAppearance }

        let controller = ComponentGalleryViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_020, height: 780)
        controller.setAppearance(.light)

        let card = try XCTUnwrap(
            descendant(withIdentifier: "gallery.story.ThemedButton", in: controller.view)
        )
        let actual = try XCTUnwrap(
            card.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        )
        var expected: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            expected = NSColor(cgColor: Design.Surface.panel.cgColor)
        }
        let resolvedExpected = try XCTUnwrap(expected)
        XCTAssertEqual(actual.hexString, resolvedExpected.hexString)
    }

    func testComponentGalleryRendersEveryStockThemeInBothAppearances() throws {
        // The gallery's theme control is the *app's*: `setTheme` calls `AppThemeLibrary.apply`,
        // which sets the palette and pins `NSApp.appearance` for the whole process. Walking the
        // stock list and stopping left the last one — Christmas — applied for every test that ran
        // after this one, and for the app the developer had running, since `NSApp.appearance` is
        // not something a scratch defaults suite can redirect. The same rule CLAUDE.md states for
        // a user's stored choice, in the piece of global state that is not stored at all.
        let restoreTheme = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(restoreTheme) }

        let owner = ComponentGalleryWindowController()
        let window = try XCTUnwrap(owner.window)
        let controller = try XCTUnwrap(
            window.contentViewController as? ComponentGalleryViewController
        )
        window.setContentSize(NSSize(width: 1_020, height: 780))
        let chip = try XCTUnwrap(
            descendant(withIdentifier: "gallery.menu.chip", in: controller.view) as? ChipView
        )
        let gallery = try XCTUnwrap(
            descendant(withIdentifier: "gallery.catalogue", in: controller.view) as? NSScrollView
        )
        let document = try XCTUnwrap(gallery.documentView)
        let promptStory = try XCTUnwrap(
            descendant(withIdentifier: "gallery.story.PromptView", in: document)
        )

        for theme in AppThemeLibrary.stock {
            controller.setTheme(theme)
            for appearance in ComponentGalleryViewController.AppearanceMode.allCases {
                controller.setAppearance(appearance)

                let fixtureStem = [
                    "component-gallery",
                    theme.id.rawValue,
                    appearance.rawValue.lowercased()
                ].joined(separator: "-")

                try captureGalleryFixture(window, named: fixtureStem)

                let promptRect = promptStory.convert(promptStory.bounds, to: document)
                document.scrollToVisible(promptRect)
                gallery.reflectScrolledClipView(gallery.contentView)
                try captureGalleryFixture(window, named: "\(fixtureStem)-prompt")

                gallery.contentView.scroll(to: .zero)
                gallery.reflectScrolledClipView(gallery.contentView)
                XCTAssertTrue(chip.accessibilityPerformShowMenu())
                try captureGalleryFixture(window, named: "\(fixtureStem)-menu")
                let responder = try XCTUnwrap(window.firstResponder)
                responder.keyDown(with: try keyEvent("\u{1b}", keyCode: 53))
                XCTAssertFalse(
                    descendants(in: controller.view).contains {
                        $0.accessibilityRole() == .menu
                    },
                    "\(fixtureStem) left its dropdown open after Escape"
                )
            }
        }
    }

    private func captureGalleryFixture(_ window: NSWindow, named name: String) throws {
        let rep = try captureAppOwnedWindowContent(window)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(
            png.count,
            20_000,
            "\(name) rendered as an unexpectedly empty image"
        )
        attach(png, named: name)

        if let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: output,
                withIntermediateDirectories: true
            )
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    /// Captures the complete app-owned root used by `ThemeBoundaryAudit`. AppKit's frame view is
    /// intentionally excluded: cacheDisplay cannot synchronously recover layer-backed window
    /// compositor pixels, and the title bar/toolbar are system chrome outside our theme contract.
    private func captureAppOwnedWindowContent(_ window: NSWindow) throws -> NSBitmapImageRep {
        let root = try XCTUnwrap(window.contentViewController?.view ?? window.contentView)

        // MainWindowController installs its split-view material containment on the next turn.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        root.layoutSubtreeIfNeeded()

        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            root.wantsLayer = true
            root.layer?.backgroundColor = Design.Surface.ground.cgColor
        }

        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return rep
    }

    private func attach(_ png: Data, named name: String) {
        // Data, not NSImage: XCTest may encode an image attachment after the fixture has moved
        // to its next appearance, which makes a dynamic-colour AppKit hierarchy serialize black.
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func descendant(withIdentifier identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let match = descendant(withIdentifier: identifier, in: child) {
                return match
            }
        }
        return nil
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func markNeedingLayout(_ view: NSView) {
        view.needsLayout = true
        for subview in view.subviews { markNeedingLayout(subview) }
    }

    /// What was actually painted at `point`, stated in `view`'s own coordinates.
    ///
    /// The bitmap is addressed in pixels from its top-left corner and `view` is not flipped, so
    /// both the flip and the backing scale are applied here rather than at each probe.
    private func colour(
        of rep: NSBitmapImageRep,
        at point: NSPoint,
        in view: NSView
    ) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let x = Int((point.x * scale).rounded(.down))
        let y = Int(((view.bounds.maxY - point.y) * scale).rounded(.down))
        return try XCTUnwrap(
            rep.colorAt(
                x: min(max(0, x), rep.pixelsWide - 1),
                y: min(max(0, y), rep.pixelsHigh - 1)
            ),
            "no pixel at \(point)"
        )
    }

    private func assertRGB(
        _ actual: NSColor,
        equals expected: NSColor,
        accuracy: CGFloat = 2.0 / 255.0,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual = actual.usingColorSpace(.sRGB),
              let expected = expected.usingColorSpace(.sRGB) else {
            XCTFail("could not resolve sampled colours", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.redComponent, expected.redComponent,
                       accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent,
                       accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent,
                       accuracy: accuracy, message, file: file, line: line)
    }

    private func keyEvent(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    private func enterEvent(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseEntered,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        )
    }

    private func wheelEvent(horizontal: Int32, vertical: Int32) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ))
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func renderedPNG(of view: NSView) throws -> Data {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func resolvedLayerColor(_ color: NSColor) throws -> NSColor {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        return try XCTUnwrap(
            view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.sRGB)
        )
    }
}

// MARK: - Helpers

private final class ActionSpy: NSObject {
    private(set) var count = 0
    @objc func fire() { count += 1 }
}

private final class ScrollWheelSpy: ThemedScrollView {
    private(set) var receivedWheelEvents = 0

    override func scrollWheel(with event: NSEvent) {
        receivedWheelEvents += 1
    }
}

/// A window that stands in for the key one, with the pointer wherever the test puts it.
///
/// Hover is read from the *window* rather than from an event, because the moment being tested is
/// one where no event is being delivered — the view moved, not the pointer. There is no way to put
/// the real pointer somewhere from a test, and a fixture window here is never ordered on screen
/// (see the note in CLAUDE.md about what showing one does to the test host), so both answers are
/// overridden rather than arranged.
private final class PointerFixtureWindow: NSWindow {
    var pointerLocation: NSPoint = .zero

    override var isKeyWindow: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointerLocation }
}

/// A `BackdropOverlay` that only records what it was handed. It also stands as the smallest
/// statement of the contract: a subclass overrides `applyInk` and colours from the argument.
private final class InkSpy: BackdropOverlay {
    private(set) var applied: [Design.Ink] = []

    override func applyInk(_ ink: Design.Ink) {
        applied.append(ink)
    }
}
