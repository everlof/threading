import AppKit
import XCTest
@testable import Skalman

/// The themed controls that replace stock AppKit, so a styled app is themed all the way down
/// rather than themed cards around system-blue switches.
@MainActor
final class ThemedControlTests: XCTestCase {

    override func tearDown() {
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

    func testTheHelperBuildsAThemedToggleNotAnNSSwitch() {
        let spy = ActionSpy()
        let control = SettingsUI.toggle(isOn: true, target: spy, action: #selector(ActionSpy.fire))
        XCTAssertTrue(control is ThemedToggle, "SettingsUI.toggle still hands back a raw switch")
        XCTAssertEqual(control.state, .on)
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
        XCTAssertEqual(popUp.lastItem?.title, "Codex")

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

        popUp.itemChosen(popUp.item(at: 1)!)

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

        popUp.itemChosen(popUp.item(at: 1)!)

        XCTAssertNil(popUp.selectedItem, "a pull-down recorded a selection")
        XCTAssertEqual(popUp.accessibilityValue() as? String, "",
                       "a pull-down stopped showing its own first item")
    }

    /// The retargeting rule, which is why a pull-down works at all: an item that already knows
    /// what to do keeps its action, and only an unclaimed one is routed through the control.
    func testOnlyUnclaimedItemsAreRoutedThroughTheControl() {
        let popUp = ThemedPopUp()
        let owner = ActionSpy()
        let claimed = NSMenuItem(title: "Rename…", action: #selector(ActionSpy.fire), keyEquivalent: "")
        claimed.target = owner
        popUp.menu?.addItem(claimed)
        popUp.addItem(withTitle: "Unclaimed")

        popUp.adoptUnclaimedItems()

        XCTAssertTrue(claimed.target === owner, "an item's own target was taken over")
        XCTAssertEqual(claimed.action, #selector(ActionSpy.fire))
        XCTAssertTrue(popUp.item(at: 1)?.target === popUp, "an unclaimed item was left unrouted")
    }

    func testTheHelperBuildsAThemedPopUpNotAnNSPopUpButton() {
        let spy = ActionSpy()
        let control = SettingsUI.popUp(target: spy, action: #selector(ActionSpy.fire))
        XCTAssertTrue(control is ThemedPopUp, "SettingsUI.popUp still hands back a raw pop-up")
    }

    // MARK: - Pop-Up Theming

    /// A stock `NSPopUpButton` draws the system bezel whatever the theme is. This one draws its
    /// fill from the theme's own `controlResting`, which is not a shade of grey but part of the
    /// style: Cyberpunk holds its neon accent far down so every control glows faintly green,
    /// where Swiss is a neutral wash on paper.
    ///
    /// Sampled from the control's own drawing rather than from a composited page — the fill is
    /// translucent by design, and what is being claimed here is which colour it lays down.
    func testThePopUpFillTakesTheThemeSurface() {
        func fill(under theme: AppTheme) -> NSColor {
            AppThemePalette.set(theme)
            let popUp = ThemedPopUp(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
            let rep = popUp.bitmapImageRepForCachingDisplay(in: popUp.bounds)!
            popUp.cacheDisplay(in: popUp.bounds, to: rep)
            // Inside the fill, clear of the border, the chevron and any title.
            return rep.colorAt(x: 60, y: 13)!.usingColorSpace(.sRGB)!
        }

        let cyber = fill(under: AppThemeStyles.cyberpunk)
        XCTAssertGreaterThan(cyber.greenComponent, cyber.redComponent + 0.5,
                             "Cyberpunk's pop-up is not drawn in its neon")

        let swiss = fill(under: AppThemeStyles.swissMinimalist)
        XCTAssertEqual(swiss.redComponent, swiss.greenComponent, accuracy: 0.02)
        XCTAssertEqual(swiss.greenComponent, swiss.blueComponent, accuracy: 0.02,
                       "Swiss's pop-up is not the neutral wash the style calls for")
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
        WindowBackdrop.set(Design.Surface.ground)

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

    // MARK: - The Rule Itself

    /// The design system's rule, enforced rather than written down: **no stock AppKit control
    /// outside `UI/Design/`.**
    ///
    /// It was written down for a long time and eroded anyway — by the time app themes arrived, a
    /// styled page was themed cards around system-blue switches, softly-bezelled pop-ups and a
    /// system-grey spinner. The themed controls fixed the symptom; this is what stops it coming
    /// back, and it is a test rather than only a lint config because this is what runs on every
    /// build.
    ///
    /// Labels are deliberately allowed: `NSTextField(labelWithString:)` draws no bezel and no
    /// background, so it is already nothing but text in a themed colour. The bezel is the
    /// erosion, not the type.
    func testNoStockControlsOutsideTheDesignSystem() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SkalmanTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")

        let banned = try NSRegularExpression(
            pattern: #"\b(NSButton|NSSwitch|NSPopUpButton|NSSearchField|NSProgressIndicator|NSColorWell|NSBox)\s*\("#
        )
        let bannedField = try NSRegularExpression(
            pattern: #"NSTextField\(\s*(?!labelWithString|wrappingLabelWithString|labelWithAttributedString)"#
        )
        // The same erosion one level down: a system colour follows light and dark but not the
        // theme, so it stays system-blue on a page that has gone neon. Read through a Design role
        // instead. `(?!\s*=)` keeps the property being *assigned* out of it — setting a web
        // view's `underPageBackgroundColor` to a role is the correct thing to do.
        let bannedColour = try NSRegularExpression(
            pattern: #"\.(labelColor|secondaryLabelColor|tertiaryLabelColor|quaternaryLabelColor|controlAccentColor|windowBackgroundColor|controlBackgroundColor|underPageBackgroundColor|separatorColor|gridColor|headerTextColor|selectedContentBackgroundColor|unemphasizedSelectedContentBackgroundColor|systemRed|systemGreen|systemBlue|systemOrange|systemYellow|systemPurple|systemTeal|systemPink|systemIndigo|systemGray)\b(?!\s*=)"#
        )

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter {
                $0.pathExtension == "swift"
                    && !$0.path.contains("/UI/Design/")
                    && !$0.path.contains("/Core/Theme/")
            } ?? []
        XCTAssertFalse(files.isEmpty, "the source tree was not found from #filePath")

        var offences: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for pattern in [banned, bannedField, bannedColour] {
                for match in pattern.matches(in: text, range: range) {
                    guard let found = Range(match.range, in: text) else { continue }
                    let line = text[text.startIndex..<found.lowerBound].filter(\.isNewline).count + 1
                    offences.append("\(file.lastPathComponent):\(line) — \(text[found])")
                }
            }
        }

        XCTAssertEqual(
            offences, [],
            "stock AppKit outside the design system. Controls: ThemedButton, ThemedToggle, "
                + "ThemedPopUp, ThemedTextField, ThemedSearchField, ThemedSpinner, "
                + "ThemedProgressBar, SeparatorView, ThemeSwatchView. Colours: Design.Text.*, "
                + "Design.Surface.*, Design.Status.*, Design.Categorical.ramp."
        )
    }
}

// MARK: - Helpers

private final class ActionSpy: NSObject {
    private(set) var count = 0
    @objc func fire() { count += 1 }
}

/// A `BackdropOverlay` that only records what it was handed. It also stands as the smallest
/// statement of the contract: a subclass overrides `applyInk` and colours from the argument.
private final class InkSpy: BackdropOverlay {
    private(set) var applied: [Design.Ink] = []

    override func applyInk(_ ink: Design.Ink) {
        applied.append(ink)
    }
}
