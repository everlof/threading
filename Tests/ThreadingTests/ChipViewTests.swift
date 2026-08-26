import AppKit
import XCTest
@testable import Threading

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

    /// Classic chooser grammar includes its native measure and face, rather than drawing a
    /// Windows combo box at the modern chip height under every period theme.
    func testAClassicChooserFollowsEachMaterialsHeightAndFace() throws {
        let chip = ChipView()
        chip.configure(symbolName: "gear", title: "Choice")

        AppThemePalette.set(AppThemeStyles.platinum)
        chip.needsDisplay = true
        chip.layoutSubtreeIfNeeded()
        XCTAssertEqual(chip.intrinsicContentSize.height, 16)
        XCTAssertEqual(
            try fill(of: chip).hexString,
            AppThemeStyles.platinum.resolved(.controlResting).hexString,
            "Platinum inherited the Win32 sunken value well"
        )

        AppThemePalette.set(AppThemeStyles.win98)
        chip.needsDisplay = true
        chip.layoutSubtreeIfNeeded()
        XCTAssertEqual(chip.intrinsicContentSize.height, 21)
        XCTAssertEqual(
            try fill(of: chip).hexString,
            AppThemeStyles.win98.resolved(.fieldSurface).hexString,
            "Win98 lost its white sunken value well"
        )

        AppThemePalette.set(AppThemeStyles.beOS)
        chip.needsDisplay = true
        chip.layoutSubtreeIfNeeded()
        XCTAssertEqual(chip.intrinsicContentSize.height, 18)
        XCTAssertEqual(chip.fittingSize.height, 18, "the fixed chooser constraint kept an old theme's height")
    }

    /// A classic popup draws its arrow independently of the content stack. Its natural width
    /// must therefore include that arrow well before a `ControlRowView` decides how to spend
    /// spare space; otherwise the spring grows while the last title glyph is clipped.
    func testAClassicChooserNaturalWidthReservesItsArrowWell() throws {
        AppThemePalette.set(AppThemeStyles.platinum)
        let chip = ChipView()
        chip.configure(icon: nil, title: "Everlof")
        chip.frame.size = chip.intrinsicContentSize
        chip.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(
            descendants(in: chip).compactMap { $0 as? NSTextField }.first
        )
        let labelFrame = chip.convert(label.bounds, from: label)
        let arrow = ClassicChoiceDrawing.arrowRect(in: chip.bounds, style: .popup)

        XCTAssertGreaterThan(chip.intrinsicContentSize.width, label.intrinsicContentSize.width)
        XCTAssertLessThanOrEqual(
            labelFrame.maxX,
            arrow.minX - ClassicChoiceDrawing.textInset + 0.5,
            "the popup label entered the independently drawn arrow well "
                + "(chip=\(chip.intrinsicContentSize.width), label=\(label.frame), "
                + "intrinsic=\(label.intrinsicContentSize.width), fitting=\(label.fittingSize.width), "
                + "cell=\(label.cell?.cellSize.width ?? -1), insets=\(label.alignmentRectInsets))"
        )
        XCTAssertGreaterThanOrEqual(
            label.frame.width,
            label.intrinsicContentSize.width - 0.5,
            "the popup truncated despite being laid out at its natural width"
        )
    }

    /// The period themes scale Helvetica independently of the system font. Measuring the
    /// label's plain attributed value used AppKit's default font instead of the font on its
    /// cell, leaving a control that claimed to be natural width while visibly drawing `A…` or
    /// `Extra Hi…` in the composer footer.
    func testClassicChooserNaturalWidthUsesTheFontItActuallyDraws() throws {
        for theme in [AppThemeStyles.openStep, AppThemeStyles.irix] {
            AppThemePalette.set(theme)
            for title in ["Auto", "Extra High"] {
                let chip = ChipView()
                chip.configure(icon: nil, title: title)
                chip.frame.size = chip.intrinsicContentSize
                chip.layoutSubtreeIfNeeded()

                let label = try XCTUnwrap(
                    descendants(in: chip).compactMap { $0 as? NSTextField }.first
                )
                let font = try XCTUnwrap(label.font)
                let drawnTitleWidth = title.size(withAttributes: [.font: font]).width
                let cell = try XCTUnwrap(label.cell)
                let titleRect = cell.titleRect(forBounds: label.bounds)
                XCTAssertGreaterThanOrEqual(
                    titleRect.width,
                    drawnTitleWidth - 0.5,
                    "\(theme.name) truncated \(title) at its own natural width "
                        + "(frame=\(label.frame.width), titleRect=\(titleRect.width), "
                        + "glyphs=\(drawnTitleWidth), cell=\(cell.cellSize.width))"
                )
                XCTAssertTrue(
                    cell.expansionFrame(withFrame: label.bounds, in: label).isEmpty,
                    "\(theme.name) still asked AppKit to expand the truncated \(title) cell"
                )
            }
        }
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

    /// A styled subtitle has one entry point, and it keeps both halves in step: the runs the
    /// row draws, and the plain join everything that is not drawing keeps reading — the
    /// tooltip, the filter, the measured width. Two properties drifting apart would be a row
    /// whose tooltip says something its pixels do not.
    func testSettingSubtitleSegmentsKeepsThePlainStringInStep() {
        var item = ThemedMenuItem(title: "Everlof")

        item.setSubtitle([
            ThemedMenuSubtitleSegment("Claude Code"),
            ThemedMenuSubtitleSegment(" · ", .muted),
            ThemedMenuSubtitleSegment("7d ", .muted),
            ThemedMenuSubtitleSegment("93%", .critical)
        ])
        XCTAssertEqual(item.subtitle, "Claude Code · 7d 93%")
        XCTAssertEqual(item.subtitleSegments?.count, 4)

        item.setSubtitle([])
        XCTAssertNil(item.subtitle)
        XCTAssertNil(item.subtitleSegments)
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

    /// A row chosen in the open menu answers back through the chip: its selection, its callback
    /// and the panel closing. How the row was chosen belongs to the menu — a click, the keyboard,
    /// or a press-drag-release the presenter tracks on the chip's behalf — so the gesture itself
    /// is exercised there, against every control that opens one.
    func testARowChosenInTheMenuAnswersThroughTheChip() throws {
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
        XCTAssertTrue(row.accessibilityPerformPress())

        XCTAssertEqual(chosen, "Two")
        XCTAssertEqual(chip.selectedItem?.title, "Two")
        XCTAssertFalse(
            descendants(in: root).contains { $0.accessibilityRole() == .menu },
            "choosing a row left the menu open"
        )
    }

    /// With one chip's menu open, a click on a sibling chip moves the menu there rather than
    /// only closing. The overlay does not silence tracking areas, so the sibling has been
    /// showing its hover invitation the whole time — a click it invited must land.
    func testAClickOnASiblingChipMovesTheMenuThereInsteadOfOnlyClosing() throws {
        let (first, second, root, window) = try twoChipsInAWindow()
        defer { window.close() }

        XCTAssertTrue(first.accessibilityPerformShowMenu())
        let overlay = try XCTUnwrap(
            root.subviews.first { !($0 is ChipView) },
            "opening the menu should have added its overlay"
        )

        let target = second.convert(NSPoint(x: second.bounds.midX, y: second.bounds.midY), to: nil)
        overlay.mouseDown(with: try mouseEvent(.leftMouseDown, at: target, in: window))

        let menus = descendants(in: root).filter { $0.accessibilityRole() == .menu }
        XCTAssertEqual(menus.count, 1, "exactly the sibling's menu should be open")
        XCTAssertTrue(
            descendants(in: root).contains {
                $0.accessibilityRole() == .menuItem && $0.accessibilityTitle() == "Alpha"
            },
            "the open menu should be the sibling's"
        )
    }

    /// The two clicks that must keep only closing: back on the chip whose menu is open — the
    /// toggle — and anywhere that opens nothing, where the dismissing click is swallowed the
    /// way `NSMenu` swallows it rather than passed to whatever content lies underneath.
    func testAClickOnTheOpenChipOrOnEmptySpaceOnlyCloses() throws {
        for pointOfDismissal in [NSPoint(x: 94, y: 193), NSPoint(x: 400, y: 250)] {
            let (first, _, root, window) = try twoChipsInAWindow()
            defer { window.close() }

            XCTAssertTrue(first.accessibilityPerformShowMenu())
            let overlay = try XCTUnwrap(root.subviews.first { !($0 is ChipView) })

            overlay.mouseDown(with: try mouseEvent(.leftMouseDown, at: pointOfDismissal, in: window))

            XCTAssertFalse(
                descendants(in: root).contains { $0.accessibilityRole() == .menu },
                "the click at \(pointOfDismissal) should have closed the menu and opened nothing"
            )
        }
    }

    /// Two chips side by side, the way a composer row carries them, with distinct menus so a
    /// test can tell whose is open.
    private func twoChipsInAWindow() throws -> (
        first: ChipView, second: ChipView, root: NSView, window: NSWindow
    ) {
        let first = ChipView(frame: NSRect(x: 24, y: 180, width: 140, height: 26))
        first.itemsProvider = { [self] in entries(titles: ["One", "Two"]) }
        let second = ChipView(frame: NSRect(x: 220, y: 180, width: 140, height: 26))
        second.itemsProvider = { [self] in entries(titles: ["Alpha", "Beta"]) }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        root.addSubview(first)
        root.addSubview(second)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        return (first, second, root, window)
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

    /// **The pill is the hover.** At rest a chip is its answer set in text: no plate, so a row
    /// of six reads as six phrases rather than six objects. The plate is what says "you are on
    /// this one", and it belongs to the pointer.
    func testAChipDrawsNoPlateUntilThePointerIsOnIt() throws {
        let (chip, _) = hostedChip()

        XCTAssertEqual(
            try fill(of: chip).alphaComponent,
            0,
            accuracy: 0.001,
            "the chip drew a plate with nothing on it"
        )

        chip.mouseEntered(with: .init())
        XCTAssertGreaterThan(
            try fill(of: chip).alphaComponent,
            0,
            "hover did not raise the plate"
        )
    }

    /// The plate appears for the keyboard too. A chip reached by Tab draws the accent ring on a
    /// silhouette, and a ring around ink with no shape behind it is not the same affordance.
    func testKeyboardFocusRaisesThePlateTheHoverWouldHave() throws {
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
        XCTAssertGreaterThan(try fill(of: chip).alphaComponent, 0, "focus left the chip flat")

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(
            try fill(of: chip).alphaComponent,
            0,
            accuracy: 0.001,
            "the plate outlived the focus that raised it"
        )
    }

    /// A chip given exactly the width it asked for draws its whole title.
    ///
    /// A text cell's natural width is fractional and stack layout rounds the arranged frame
    /// down, so a chip measured to the point can be handed a frame a fraction short of drawing
    /// what it measured — and an ellipsis inside a control at its own full intrinsic width is
    /// the one truncation nothing in the row asked for. `Claude Code · Everlof` was the case:
    /// visible only once the title dropped from the control face's medium weight to regular,
    /// which took away the point of slack the heavier measurement happened to carry.
    func testAChipAtItsOwnIntrinsicWidthDrawsTheWholeTitle() throws {
        for title in ["Claude Code · Everlof", "Opus · 1M", "Agent's Setting", "Extra High"] {
            let chip = ChipView()
            chip.configure(symbolName: "cpu", title: title)
            chip.translatesAutoresizingMaskIntoConstraints = true
            chip.frame = NSRect(origin: .zero, size: chip.intrinsicContentSize)
            chip.layoutSubtreeIfNeeded()

            let label = try XCTUnwrap(
                chip.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }.first
            )
            let cell = try XCTUnwrap(label.cell)
            XCTAssertTrue(
                cell.expansionFrame(withFrame: label.bounds, in: label).isEmpty,
                "\"\(title)\" drew truncated at the chip's own intrinsic width "
                    + "(chip=\(chip.frame.width), label=\(label.frame.width), "
                    + "cell=\(cell.cellSize.width))"
            )
        }
    }

    /// The ink moves with the plate, on one ramp: the title a tier below `label` at rest, the
    /// mark and the chevron a tier below that, and each one step brighter under the pointer.
    ///
    /// A row of settings is not the content of the screen it sits under, and at full strength it
    /// read as the brightest thing in the composer — brighter than the brief being typed above
    /// it. Pinned because it is one assignment away from silently reverting to `label`, and a
    /// screenshot is the only other place it shows.
    func testTheInkStepsATierWithThePlate() throws {
        let (chip, _) = hostedChip()
        chip.configure(symbolName: "cpu", title: "Opus · 1M")

        let title = try XCTUnwrap(
            chip.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }.first,
            "the chip has no label"
        )
        let marks = chip.subviews.flatMap(\.subviews).compactMap { $0 as? NSImageView }
        XCTAssertEqual(marks.count, 2, "expected the chip's mark and its chevron")

        XCTAssertEqual(title.textColor?.hexString, Design.Text.secondary.hexString,
                       "a resting chip stated its answer at full strength")
        for mark in marks {
            XCTAssertEqual(mark.contentTintColor?.hexString, Design.Text.tertiary.hexString)
        }

        chip.mouseEntered(with: .init())
        XCTAssertEqual(title.textColor?.hexString, Design.Text.label.hexString,
                       "the pointer did not bring the title up a tier")
        for mark in marks {
            XCTAssertEqual(mark.contentTintColor?.hexString, Design.Text.secondary.hexString)
        }

        chip.mouseExited(with: .init())
        XCTAssertEqual(title.textColor?.hexString, Design.Text.secondary.hexString,
                       "the title kept the tier the pointer lent it")
    }

    /// Nothing moves when the plate appears. The frame carries the padding at rest as well, so
    /// a run of chips does not shuffle sideways as the pointer crosses it — and a row aligning
    /// by ink is told what that padding is rather than measuring the plate that is not drawn.
    func testTheFrameCarriesThePlatesPaddingEvenWithNoPlateDrawn() {
        let chip = ChipView()
        chip.configure(symbolName: nil, title: "Opus · 1M")
        let resting = chip.intrinsicContentSize.width

        chip.mouseEntered(with: .init())
        XCTAssertEqual(
            chip.intrinsicContentSize.width,
            resting,
            accuracy: 0.5,
            "the chip changed size when its plate appeared"
        )
        XCTAssertEqual(chip.opticalHorizontalInset, ChipView.horizontalPadding)
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
        let (chip, _) = hostedChip(width: 60)

        chip.configure(symbolName: "gear", title: "Another very long label indeed")
        chip.mouseEntered(with: .init())

        let hoverConstraint = try XCTUnwrap(
            chip.constraints.first { $0.firstAttribute == .width && $0.isActive && $0.priority != .required },
            "no yielding hover-width constraint was installed"
        )
        XCTAssertLessThan(hoverConstraint.priority, .required)
    }

    // MARK: - Rendered State

    /// The change is a *look*, so it is reviewed as one: a row at rest beside the same row with
    /// the pointer on its third chip, in both appearances.
    func testRendersTheRowAtRestAndUnderThePointer() throws {
        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let titles = [
            ("cpu", "Opus · 1M"),
            ("hand.raised", "Manual"),
            ("brain", "Extra High"),
            ("bolt.fill", "Standard")
        ]

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            var data: Data?

            let render = {
                let column = NSStackView()
                column.orientation = .vertical
                column.alignment = .leading
                column.spacing = Design.Spacing.large
                column.translatesAutoresizingMaskIntoConstraints = false

                var hovered: [ChipView] = []
                for hoveredIndex in [nil, 2] as [Int?] {
                    let row = NSStackView()
                    row.orientation = .horizontal
                    row.alignment = .centerY
                    row.spacing = Design.Spacing.small
                    for (index, entry) in titles.enumerated() {
                        let chip = ChipView()
                        chip.configure(symbolName: entry.0, title: entry.1)
                        row.addArrangedSubview(chip)
                        if index == hoveredIndex { hovered.append(chip) }
                    }
                    column.addArrangedSubview(row)
                }

                let host = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 120))
                host.wantsLayer = true
                host.appearance = appearance
                column.appearance = appearance
                host.addSubview(column)
                NSLayoutConstraint.activate([
                    column.leadingAnchor.constraint(
                        equalTo: host.leadingAnchor,
                        constant: Design.Spacing.inset
                    ),
                    column.centerYAnchor.constraint(equalTo: host.centerYAnchor)
                ])
                host.layer?.backgroundColor = Design.Surface.ground.cgColor
                host.layoutSubtreeIfNeeded()

                // Only now: an applied surface freezes the appearance the view had when it was
                // applied, and a chip hovered before it was in this hierarchy would wear the
                // *other* appearance's plate for the whole picture.
                for chip in hovered { chip.mouseEntered(with: .init()) }

                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    return
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
            appearance?.performAsCurrentDrawingAppearance(render)

            try XCTUnwrap(data, "Failed to render the chip row in \(name)")
                .write(to: directory.appendingPathComponent("chip-row-\(name).png"))
        }
    }

    // MARK: - Theming

    /// The sweep replays what was **recorded**, so a chip resting flat has to be recorded flat.
    ///
    /// This used to pin the opposite — that a resting chip took the new theme's `controlResting`
    /// — which was the enrolment test back when a chip wore a plate at rest. The enrolment is
    /// still what matters and is now pinned by the hovered case below; what this holds is that a
    /// theme change cannot hand a flat row of chips six plates it never drew.
    func testTheThemeSweepDoesNotPutAPlateBackUnderARestingChip() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let (chip, _) = hostedChip()

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        // The sweep is what repaints; setting the palette alone deliberately does not, which is
        // the stale state `AppThemeRefresh` exists to fix.
        chip.reapplyRecordedSurfaceForTesting()

        XCTAssertEqual(
            try fill(of: chip).alphaComponent,
            0,
            accuracy: 0.001,
            "the sweep drew a plate under a chip nobody was pointing at"
        )
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
