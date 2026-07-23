import AppKit
import XCTest
@testable import Skalman

/// `ChipView` is the app's standard way to offer a choice — the composer alone carries six of
/// them — and had no tests at all. What is pinned here is the behaviour a caller depends on
/// (the menu is rebuilt per click, a choice is recorded and reported, a truncated label is
/// recoverable) and the one thing about it that is invisible in a screenshot: whether its fill
/// survives a live theme switch.
@MainActor
final class ChipViewTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Helpers

    /// A chip inside a container, which is all `updateHoverWidth` needs — it lays out against
    /// its `superview`, not a window. Deliberately no `NSWindow`: one defaults to
    /// `isReleasedWhenClosed`, so closing it in a `defer` over-releases and takes the whole test
    /// process down, which reads as a mass of unrelated failures rather than as one bad helper.
    private func hostedChip(width: CGFloat = 120) -> (chip: ChipView, container: NSView) {
        let chip = ChipView()
        chip.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chip)

        // The squeeze has to come from the *container*, the way a composer row sharing its width
        // out among six chips does. Put on the chip itself it also lands in `fittingSize`, which
        // is what `updateHoverWidth` measures the full label with — so the chip would "widen" to
        // the squeezed width and the hover affordance would silently do nothing.
        // Above the label's own 750 compression resistance, so the title actually truncates,
        // and below the hover constraint's `required - 1`, so hovering can still win it back —
        // which is the same ordering a composer row produces, where the row's width is fixed and
        // the neighbouring chips yield first.
        let squeeze = chip.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        squeeze.priority = NSLayoutConstraint.Priority(800)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            container.heightAnchor.constraint(equalToConstant: 100),
            chip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chip.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            squeeze
        ])
        container.layoutSubtreeIfNeeded()
        return (chip, container)
    }

    private func entries(titles: [String]) -> [ThemedMenuEntry] {
        titles.map { .item(ThemedMenuItem(title: $0, representedValue: $0)) }
    }

    /// The chip's own fill, read back off the layer it sets rather than from the token, so the
    /// test sees what is actually drawn.
    private func fill(of chip: ChipView) throws -> NSColor {
        let cgColor = try XCTUnwrap(chip.layer?.backgroundColor, "the chip drew no fill")
        return try XCTUnwrap(NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB))
    }

    // MARK: - Presentation

    /// The title is also the tooltip, which is not decoration: a chip squeezed into a row
    /// truncates to `Default m…`, and the tooltip is how that is read without hovering long
    /// enough to trigger the width animation.
    func testConfiguringRestatesTheTitleAsTheTooltip() {
        let chip = ChipView()
        chip.configure(symbolName: "gear", title: "Claude Fable 5 · 1M")

        XCTAssertEqual(chip.toolTip, "Claude Fable 5 · 1M")
    }

    /// A chip with no icon hides the image view rather than leaving a gap where one would be,
    /// so an iconless chip's label sits where the eye expects it.
    func testAChipWithNoIconHidesTheIconRatherThanReservingItsSpace() throws {
        let chip = ChipView()

        chip.configure(symbolName: "gear", title: "With")
        let withIcon = chip.fittingSize.width

        chip.configure(icon: nil, title: "With")
        let withoutIcon = chip.fittingSize.width

        XCTAssertLessThan(withoutIcon, withIcon,
                          "a missing icon still reserved its slot")
    }

    /// An unknown SF Symbol name resolves to no image, and must be treated as the iconless
    /// case rather than drawing an empty slot — symbol names are string literals and a
    /// renamed one should degrade quietly.
    func testAnUnknownSymbolIsTreatedAsNoIcon() {
        let chip = ChipView()
        chip.configure(symbolName: "not.a.real.symbol.name", title: "Fallback")

        let iconViews = chip.subviews
            .flatMap(\.subviews)
            .compactMap { $0 as? NSImageView }
        XCTAssertTrue(iconViews.contains { $0.isHidden },
                      "an unresolvable symbol left a visible empty icon slot")
    }

    // MARK: - The Menu

    /// The menu is rebuilt on every click rather than held, which is what lets it reflect state
    /// that moved since the chip was configured — the account list, the checkouts, the models.
    func testTheMenuIsRebuiltOnEveryClick() {
        let (chip, _) = hostedChip()

        var builds = 0
        chip.itemsProvider = { [self] in
            builds += 1
            return entries(titles: ["One"])
        }

        _ = chip.preparedPresentation()
        _ = chip.preparedPresentation()

        XCTAssertEqual(builds, 2, "the chip cached a menu instead of rebuilding it")
    }

    /// A chip with no provider must not pop an empty menu — this is the "hides rather than
    /// showing a dead menu" rule reaching the control itself.
    func testAChipWithNoProviderOpensNothing() {
        let chip = ChipView()

        XCTAssertNil(chip.preparedPresentation(), "a chip with no provider still built a menu")
        XCTAssertNil(chip.selectedItem)
    }

    /// The menu is at least as wide as the chip that opened it, so the popover lines up with
    /// the control rather than shrinking to its longest title.
    func testTheMenuIsNoNarrowerThanTheChip() throws {
        let (chip, _) = hostedChip(width: 140)
        chip.itemsProvider = { [self] in entries(titles: ["Short"]) }

        let presentation = try XCTUnwrap(chip.preparedPresentation())
        XCTAssertEqual(presentation.minimumWidth, chip.bounds.width, accuracy: 0.5)
    }

    /// The semantic model carries every piece feature code may state without exposing system
    /// menu chrome: selection, enabled state, subtitle, image, value, and separators.
    func testThePresentationPreservesSemanticItemState() throws {
        let (chip, _) = hostedChip()
        let image = NSImage(size: NSSize(width: 8, height: 8))
        let choice = ThemedMenuItem(
            title: "Account",
            subtitle: "42% left",
            image: image,
            representedValue: 7,
            isSelected: true,
            isEnabled: false
        )
        chip.itemsProvider = { [.item(choice), .separator] }

        let presentation = try XCTUnwrap(chip.preparedPresentation())
        guard case .item(let preserved) = presentation.entries[0] else {
            return XCTFail("the choice became a separator")
        }
        XCTAssertEqual(preserved.title, "Account")
        XCTAssertEqual(preserved.subtitle, "42% left")
        XCTAssertTrue(preserved.image === image)
        XCTAssertEqual(preserved.representedValue as? Int, 7)
        XCTAssertTrue(preserved.isSelected)
        XCTAssertFalse(preserved.isEnabled)
        guard case .separator = presentation.entries[1] else {
            return XCTFail("the separator became a choice")
        }
    }

    /// Choosing records the selection *and* reports it, in that order — a caller reading
    /// `selectedItem` from inside `onSelect` has to see the new value, not the old one.
    func testChoosingRecordsTheSelectionBeforeReportingIt() throws {
        let (chip, _) = hostedChip()

        let choice = ThemedMenuItem(title: "Chosen", representedValue: "chosen")
        chip.itemsProvider = { [.item(choice)] }

        var seenDuringCallback: ThemedMenuItem?
        chip.onSelect = { _ in seenDuringCallback = chip.selectedItem }
        chip.menuPresentationOverride = { _ in choice }

        XCTAssertTrue(chip.accessibilityPerformPress())
        XCTAssertEqual(chip.selectedItem?.title, "Chosen", "the selection was not recorded")
        XCTAssertEqual(seenDuringCallback?.title, "Chosen",
                       "onSelect ran before the selection was recorded")
    }

    /// `select(_:)` exists so a rebuilt menu keeps its choice; it must not fire `onSelect`,
    /// which would turn restoring a selection into making one.
    func testSelectingProgrammaticallyDoesNotReportAChoice() {
        let chip = ChipView()
        var reported = false
        chip.onSelect = { _ in reported = true }

        chip.select(ThemedMenuItem(title: "Restored", representedValue: "restored"))

        XCTAssertEqual(chip.selectedItem?.title, "Restored")
        XCTAssertFalse(reported, "restoring a selection reported it as a choice")
    }

    // MARK: - Control Contract

    func testTheChipIsOneAccessiblePopUpControl() {
        let chip = ChipView()
        chip.configure(symbolName: "gear", title: "Model")

        XCTAssertTrue(chip.isAccessibilityElement())
        XCTAssertEqual(chip.accessibilityRole(), .popUpButton)
        XCTAssertEqual(chip.accessibilityTitle(), "Model")
        XCTAssertEqual(chip.accessibilityValue() as? String, "Model")
        XCTAssertTrue(chip.isAccessibilityEnabled())

        chip.select(ThemedMenuItem(title: "Selected model"))
        XCTAssertEqual(chip.accessibilityValue() as? String, "Selected model")

        chip.isEnabled = false
        XCTAssertFalse(chip.isAccessibilityEnabled())
        XCTAssertFalse(chip.acceptsFirstResponder)
        XCTAssertEqual(chip.alphaValue, 0.5)
    }

    func testKeyboardAndAccessibilityActionsOpenTheMenu() throws {
        let chip = ChipView()
        chip.itemsProvider = { [self] in entries(titles: ["One"]) }

        var presentations = 0
        chip.menuPresentationOverride = {
            _ in
            presentations += 1
            return nil
        }

        chip.keyDown(with: try keyEvent(" ", keyCode: 49))
        chip.keyDown(with: try keyEvent("\r", keyCode: 36))
        XCTAssertTrue(chip.accessibilityPerformPress())
        XCTAssertTrue(chip.accessibilityPerformShowMenu())

        XCTAssertEqual(presentations, 4)
    }

    /// The press that opened the menu may still be held. AppKit keeps routing its drag and
    /// release to the chip, which forwards both to the open menu — so press-drag-release
    /// chooses a row the way every platform menu does.
    func testAHeldPressReleasedOverARowChoosesThroughTheChip() throws {
        let chip = ChipView(frame: NSRect(x: 24, y: 180, width: 140, height: 26))
        chip.itemsProvider = { [self] in entries(titles: ["One", "Two"]) }
        var chosen: String?
        chip.onSelect = { chosen = $0.representedValue as? String }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        root.addSubview(chip)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }

        XCTAssertTrue(chip.accessibilityPerformShowMenu())
        // Row frames come from a layout pass a never-displayed test window won't run itself.
        for view in [root] + descendants(in: root) { view.needsLayout = true }
        root.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(
            descendants(in: root).first {
                $0.accessibilityRole() == .menuItem && $0.accessibilityTitle() == "Two"
            }
        )
        let target = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        chip.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: target, in: window))
        chip.mouseUp(with: try mouseEvent(.leftMouseUp, at: target, in: window))

        XCTAssertEqual(chosen, "Two")
        XCTAssertEqual(chip.selectedItem?.title, "Two")
        XCTAssertFalse(
            descendants(in: root).contains { $0.accessibilityRole() == .menu },
            "the release chose a row, so the menu should have closed"
        )
    }

    func testFocusDrawsAnAccentRingAndResigningClearsIt() {
        let chip = ChipView(frame: NSRect(x: 10, y: 10, width: 120, height: 26))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(chip)

        XCTAssertTrue(window.makeFirstResponder(chip))
        XCTAssertEqual(chip.layer?.borderWidth, Design.Radius.border)
        XCTAssertNotNil(chip.layer?.borderColor)

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(chip.layer?.borderWidth, 0)
        XCTAssertNil(chip.layer?.borderColor)
    }

    // MARK: - Hover

    /// Hover raises the fill — with a flat chip carrying no bezel, this is most of what says
    /// the thing is clickable at all.
    func testHoverRaisesTheFill() throws {
        let (chip, _) = hostedChip()

        let resting = try fill(of: chip)
        chip.mouseEntered(with: .init())
        let hovered = try fill(of: chip)
        chip.mouseExited(with: .init())
        let restored = try fill(of: chip)

        XCTAssertNotEqual(resting, hovered, "hover did not change the fill")
        XCTAssertEqual(resting, restored, "the fill did not return on exit")
    }

    /// The truncation-recovery rule: a chip squeezed narrower than its label widens to its full
    /// contents while hovered, and gives that width back on exit.
    func testHoverWidensAChipToItsFullLabelAndGivesItBack() {
        let (chip, container) = hostedChip(width: 60)

        chip.configure(symbolName: "gear", title: "A model name far too long for sixty points")
        container.layoutSubtreeIfNeeded()
        let squeezed = chip.frame.width

        chip.mouseEntered(with: .init())
        container.layoutSubtreeIfNeeded()
        let widened = chip.frame.width

        chip.mouseExited(with: .init())
        container.layoutSubtreeIfNeeded()
        let released = chip.frame.width

        XCTAssertGreaterThan(widened, squeezed, "hover did not widen the truncated chip")
        XCTAssertEqual(released, squeezed, accuracy: 0.5,
                       "the chip kept the width it borrowed for hover")
    }

    /// The hover constraint sits just below required so neighbouring chips yield rather than
    /// the layout breaking — a required one would conflict with the row's own width.
    func testTheHoverWidthYieldsRatherThanBreakingTheLayout() throws {
        let (chip, container) = hostedChip(width: 60)

        chip.configure(symbolName: "gear", title: "Another very long label indeed")
        chip.mouseEntered(with: .init())

        let hoverConstraint = try XCTUnwrap(
            chip.constraints.first { $0.firstAttribute == .width && $0.isActive && $0.priority != .required },
            "no yielding hover-width constraint was installed"
        )
        XCTAssertLessThan(hoverConstraint.priority, .required)
    }

    // MARK: - Theming

    /// A chip is not rebuilt on a theme change — the composer holds its six as stored properties
    /// for the life of the controller — so it survives a live switch only by being enrolled in
    /// `AppThemeRefresh`'s sweep, which `applySurface` does by recording what it was given. A
    /// chip that set `layer.backgroundColor` directly instead would look identical here and
    /// keep the old theme's fill forever, so what is pinned is the enrolment.
    func testTheFillIsResolvedAgainWhenTheThemeChanges() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let (chip, _) = hostedChip()
        let underCyberpunk = try fill(of: chip)

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        // The sweep is what repaints; setting the palette alone deliberately does not, which is
        // the stale state `AppThemeRefresh` exists to fix.
        chip.reapplyRecordedSurfaceForTesting()
        let underSwiss = try fill(of: chip)

        XCTAssertNotEqual(underCyberpunk, underSwiss,
                          "the chip is not enrolled in the theme sweep")
        XCTAssertEqual(underSwiss.hexString,
                       AppThemeStyles.swissMinimalist.resolved(.controlResting).hexString,
                       "the chip did not take the new theme's control fill")
    }

    /// The hover fill has to be recorded too, or a chip hovered *while* the theme changes is
    /// swept back to its resting colour under the pointer and stays there until the mouse moves
    /// — the sweep replays what was recorded, not what is on screen.
    func testAHoveredChipKeepsItsHoverFillThroughTheThemeSweep() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let (chip, _) = hostedChip()

        chip.mouseEntered(with: .init())
        let hovered = try fill(of: chip)

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        chip.reapplyRecordedSurfaceForTesting()
        let sweptWhileHovered = try fill(of: chip)

        XCTAssertEqual(sweptWhileHovered.hexString,
                       AppThemeStyles.swissMinimalist.resolved(.controlHover).hexString,
                       "the sweep dropped a hovered chip back to its resting fill")
        XCTAssertNotEqual(sweptWhileHovered, hovered)
    }

    /// The same for the label, which is set once at setup from a theme-dependent token.
    func testTheLabelColourFollowsALiveThemeSwitch() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let chip = ChipView()
        chip.configure(symbolName: nil, title: "Label")

        let label = try XCTUnwrap(
            chip.subviews.flatMap(\.subviews).compactMap({ $0 as? NSTextField }).first,
            "the chip has no label"
        )
        let underCyberpunk = try XCTUnwrap(label.textColor?.usingColorSpace(.sRGB))

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        let underSwiss = try XCTUnwrap(label.textColor?.usingColorSpace(.sRGB))

        XCTAssertNotEqual(underCyberpunk, underSwiss,
                          "the chip's label kept its old theme's colour through a live switch")
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
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
}
