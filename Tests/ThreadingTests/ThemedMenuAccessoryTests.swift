import AppKit
import XCTest
@testable import Threading

/// The hover-revealed action a menu row can carry at its trailing edge — the play button on a
/// sound.
///
/// Everything here turns on one sentence: **pressing it must not choose the row.** That is the
/// whole reason the affordance exists, and it is also the part a refactor breaks silently, since
/// a press that both auditioned and chose would look completely correct to anyone clicking it
/// once. The rest pins what a hover-revealed control is entitled to be asked: that it is invisible
/// until the row is current, that it answers its own hover, that its column is paid for on every
/// row so nothing reflows under the pointer, and that a pointer-only control was not shipped —
/// the right arrow and VoiceOver reach the same code.
@MainActor
final class ThemedMenuAccessoryTests: XCTestCase {

    // MARK: - Fixtures

    private enum Fixture {
        static let size = NSSize(width: 260, height: 200)
        /// The entry the accessory hangs on. Index 1 rather than 0, so a bug that reaches the
        /// first row by accident does not read as a pass.
        static let auditioned = 1
        static let plain = 0
    }

    private var previousTheme: AppTheme?

    override func setUp() {
        super.setUp()
        previousTheme = AppThemePalette.current
        addTeardownBlock {
            MainActor.assumeIsolated {
                if let previous = self.previousTheme { AppThemePalette.set(previous) }
            }
        }
    }

    /// Three ordinary rows, the middle one auditionable. `played` counts what the accessory did.
    private func entries(played: @escaping () -> Void) -> [ThemedMenuEntry] {
        var withAccessory = ThemedMenuItem(title: "Funk", onChoose: {})
        withAccessory.accessory = ThemedMenuAccessory(
            symbolName: "play.fill",
            title: "Play",
            action: played
        )
        return [
            .item(ThemedMenuItem(title: "Basso", onChoose: {})),
            .item(withAccessory),
            .item(ThemedMenuItem(title: "Glass", onChoose: {}))
        ]
    }

    /// The surface in an unshown window, which is what the events need: a real window number, and
    /// a coordinate space for `locationInWindow` to mean something.
    private func present(
        _ entries: [ThemedMenuEntry],
        highlighted: Int? = nil,
        chose: @escaping (Int) -> Void = { _ in }
    ) -> (window: NSWindow, surface: NSView) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = ThemedSurfaceView()
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = NSRect(origin: .zero, size: Fixture.size)
        host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        window.contentView = host

        let surface = ThemedMenuReferenceFixture.make(
            entries: entries,
            size: Fixture.size,
            highlightedEntryIndex: highlighted,
            onChoose: chose
        )
        host.addSubview(surface)
        host.layoutSubtreeIfNeeded()
        return (window, surface)
    }

    private func accessoryCentre(in surface: NSView) throws -> NSPoint {
        let rect = try XCTUnwrap(
            ThemedMenuReferenceFixture.accessoryHitRect(
                in: surface,
                entryIndex: Fixture.auditioned
            ),
            "the auditioned row reports no accessory"
        )
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    /// The row view under a point, reached the way a click is: nothing here may name the row's
    /// type, which is private, so the tests speak to it as the responder AppKit would.
    private func rowView(in surface: NSView, at point: NSPoint) throws -> NSView {
        try XCTUnwrap(surface.hitTest(point), "nothing answers a press at \(point)")
    }

    private func mouse(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    // MARK: - The Press

    /// The load-bearing one. A press on the glyph runs the action and the menu's choice never
    /// fires, so the setting behind the list is exactly what it was.
    func testPressingTheAccessoryRunsItAndDoesNotChooseTheRow() throws {
        var played = 0
        var chosen: [Int] = []
        let (window, surface) = present(
            entries { played += 1 },
            chose: { chosen.append($0) }
        )
        let point = try accessoryCentre(in: surface)
        let row = try rowView(in: surface, at: point)

        row.mouseDown(with: try mouse(.leftMouseDown, at: point, in: window))
        row.mouseUp(with: try mouse(.leftMouseUp, at: point, in: window))

        XCTAssertEqual(played, 1, "the accessory did not run")
        XCTAssertEqual(chosen, [], "auditioning a sound also chose it")
    }

    /// And the row is still a row: a press anywhere else on it chooses, and auditions nothing.
    func testPressingTheRowBesideTheAccessoryStillChoosesIt() throws {
        var played = 0
        var chosen: [Int] = []
        let (window, surface) = present(
            entries { played += 1 },
            chose: { chosen.append($0) }
        )
        let accessory = try accessoryCentre(in: surface)
        let row = try rowView(in: surface, at: accessory)
        // The same row, at its leading edge — the name rather than the control.
        let onTheName = NSPoint(
            x: row.convert(row.bounds, to: surface).minX + Design.Spacing.large,
            y: accessory.y
        )

        row.mouseDown(with: try mouse(.leftMouseDown, at: onTheName, in: window))
        row.mouseUp(with: try mouse(.leftMouseUp, at: onTheName, in: window))

        XCTAssertEqual(chosen, [Fixture.auditioned])
        XCTAssertEqual(played, 0, "choosing a row played its accessory as well")
    }

    /// A press that leaves the glyph does nothing at all — neither the audition it began nor the
    /// choice it is now over. That is what every button on the platform does, and it is the only
    /// way out of a mispress on a control this small.
    func testDraggingOffTheAccessoryDisarmsItWithoutChoosing() throws {
        var played = 0
        var chosen: [Int] = []
        let (window, surface) = present(
            entries { played += 1 },
            chose: { chosen.append($0) }
        )
        let accessory = try accessoryCentre(in: surface)
        let row = try rowView(in: surface, at: accessory)
        let away = NSPoint(
            x: row.convert(row.bounds, to: surface).minX + Design.Spacing.large,
            y: accessory.y
        )

        row.mouseDown(with: try mouse(.leftMouseDown, at: accessory, in: window))
        row.mouseDragged(with: try mouse(.leftMouseDragged, at: away, in: window))
        row.mouseUp(with: try mouse(.leftMouseUp, at: away, in: window))

        XCTAssertEqual(played, 0, "the audition ran after the press left the control")
        XCTAssertEqual(chosen, [], "a press that began on the accessory chose the row")
    }

    /// A row nobody can choose offers nothing to press either.
    func testADisabledRowOffersNoAudition() throws {
        var played = 0
        var item = ThemedMenuItem(title: "Funk", isEnabled: false, onChoose: {})
        item.accessory = ThemedMenuAccessory(symbolName: "play.fill", title: "Play") {
            played += 1
        }
        let (window, surface) = present([
            .item(ThemedMenuItem(title: "Basso", onChoose: {})),
            .item(item)
        ])
        let point = try accessoryCentre(in: surface)
        let row = try rowView(in: surface, at: point)

        row.mouseDown(with: try mouse(.leftMouseDown, at: point, in: window))
        row.mouseUp(with: try mouse(.leftMouseUp, at: point, in: window))

        XCTAssertEqual(played, 0)
    }

    // MARK: - The Column

    /// The slot is paid for by the menu, not by the row under the pointer. A control that only
    /// costs width once it is visible would shorten the title as you arrive at it.
    func testTheColumnIsReservedByTheWholeMenu() {
        let plain: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: "Basso")),
            .item(ThemedMenuItem(title: "Funk"))
        ]
        var auditioned = ThemedMenuItem(title: "Funk")
        auditioned.accessory = ThemedMenuAccessory(
            symbolName: "play.fill",
            title: "Play",
            action: {}
        )
        let withOne: [ThemedMenuEntry] = [.item(ThemedMenuItem(title: "Basso")), .item(auditioned)]

        XCTAssertEqual(
            ThemedMenuMetrics.width(for: withOne, minimum: 0)
                - ThemedMenuMetrics.width(for: plain, minimum: 0),
            ThemedMenuMetrics.accessorySlot,
            accuracy: 0.5,
            "one auditionable row did not buy the whole menu its column"
        )
    }

    /// The target is bigger than the glyph and still entirely inside its own row: padding a small
    /// control must not quietly claim presses aimed at the row above or below.
    func testTheTargetIsLargerThanTheGlyphAndStaysInsideItsRow() throws {
        let (_, surface) = present(entries {})
        let hit = try XCTUnwrap(
            ThemedMenuReferenceFixture.accessoryHitRect(in: surface, entryIndex: Fixture.auditioned)
        )
        let row = try rowView(in: surface, at: NSPoint(x: hit.midX, y: hit.midY))
        let rowFrame = row.convert(row.bounds, to: surface)

        XCTAssertGreaterThan(hit.width, ThemedMenuMetrics.accessorySize)
        XCTAssertTrue(rowFrame.contains(hit), "the accessory's target reaches outside its row")
        XCTAssertEqual(
            rowFrame.maxX - hit.maxX,
            ThemedMenuMetrics.contentInset - ThemedMenuMetrics.accessoryHitPadding,
            accuracy: 0.5,
            "the accessory is not at the trailing edge"
        )
    }

    /// A row with no accessory reports none, so nothing is drawn or pressed on it.
    func testARowWithoutAnAccessoryHasNoTarget() {
        let (_, surface) = present(entries {})
        XCTAssertNil(
            ThemedMenuReferenceFixture.accessoryHitRect(in: surface, entryIndex: Fixture.plain)
        )
    }

    // MARK: - Keyboard

    /// Not a pointer-only feature. The right arrow reaches into the highlighted row, which on a
    /// row that opens nothing is the accessory — Space and Return are unavailable by definition,
    /// since both choose, which is the commitment being avoided.
    func testTheRightArrowAuditionsTheHighlightedRow() throws {
        var played = 0
        // Opened on the auditionable row rather than walked to it: a menu opens highlighting the
        // selected entry, so this states which row the key is aimed at instead of counting arrow
        // presses against wherever the highlight happened to start.
        let overlay = try presentedOverlay(entries { played += 1 }, selected: Fixture.auditioned)

        overlay.keyDown(with: try key(keyCode: MenuKey.rightArrow))

        XCTAssertEqual(played, 1, "the right arrow did not audition the highlighted row")
    }

    /// And it has not been taken away from the rows it always belonged to: a row that opens a
    /// submenu still opens it, accessory or no accessory.
    func testTheRightArrowStillOpensASubmenu() throws {
        var played = 0
        var parent = ThemedMenuItem(title: "Sounds", submenu: [
            .item(ThemedMenuItem(title: "Basso", onChoose: {}))
        ])
        parent.accessory = ThemedMenuAccessory(symbolName: "play.fill", title: "Play") {
            played += 1
        }
        let overlay = try presentedOverlay([.item(parent)], selected: 0)
        let panelsBefore = overlay.subviews.count

        overlay.keyDown(with: try key(keyCode: MenuKey.rightArrow))

        XCTAssertEqual(played, 0, "the right arrow auditioned a row that had a submenu to open")
        XCTAssertGreaterThan(
            overlay.subviews.count,
            panelsBefore,
            "the right arrow opened no submenu"
        )
    }

    /// The one gesture that ignores the accessory, on purpose. A press held on the control that
    /// opened the menu and released over a row chooses that row wherever on it the release
    /// landed: a sweep is a choosing gesture from the moment it leaves the button, and the
    /// platform's own menus track a held press the same way. Pinned so that changing it is a
    /// decision rather than a side effect.
    func testAHeldSweepReleasedOverTheAccessoryStillChoosesTheRow() throws {
        var played = 0
        var chosen: [Int] = []
        let size = Fixture.size
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = ThemedSurfaceView()
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        let source = NSView(frame: NSRect(x: 8, y: size.height - 8, width: 1, height: 1))
        host.addSubview(source)

        let token = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries { played += 1 }, minimumWidth: 200),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { index, _ in chosen.append(index) },
            onDismiss: {}
        )
        addTeardownBlock { MainActor.assumeIsolated { ThemedMenuPresenter.dismiss(token) } }
        host.layoutSubtreeIfNeeded()

        let overlay = try XCTUnwrap(host.subviews.last { $0 !== source })
        let hit = try XCTUnwrap(
            ThemedMenuReferenceFixture.accessoryHitRect(in: overlay, entryIndex: Fixture.auditioned),
            "the presented menu reports no accessory"
        )
        let inWindow = overlay.convert(NSPoint(x: hit.midX, y: hit.midY), to: nil)

        ThemedMenuPresenter.dragEnded(token, event: try mouse(.leftMouseUp, at: inWindow, in: window))

        XCTAssertEqual(chosen, [Fixture.auditioned], "the sweep did not choose the row it ended on")
        XCTAssertEqual(played, 0, "a sweep auditioned instead of choosing")
    }

    // MARK: - Accessibility

    /// The accessory is an *action on the row*, never a second element inside it. A menu item is
    /// a leaf here — putting a button inside one would hand every consumer that walks a menu a
    /// row wearing a control.
    func testVoiceOverGetsTheAuditionAsAnActionAndTheRowStaysALeaf() throws {
        var played = 0
        let (_, surface) = present(entries { played += 1 })
        let row = try rowView(in: surface, at: try accessoryCentre(in: surface))

        let actions = try XCTUnwrap(row.accessibilityCustomActions(), "no accessibility action")
        XCTAssertEqual(actions.map(\.name), ["Play"])
        XCTAssertEqual(row.accessibilityChildren()?.count ?? 0, 0, "the row grew a child")

        XCTAssertEqual(try XCTUnwrap(actions.first?.handler)(), true)
        XCTAssertEqual(played, 1, "the accessibility action did not reach the same code")
    }

    func testARowWithoutAnAccessoryOffersNoAction() throws {
        let (_, surface) = present(entries {})
        let row = try rowView(
            in: surface,
            at: NSPoint(x: 20, y: Fixture.size.height - ThemedMenuMetrics.rowHeight / 2)
        )
        XCTAssertNil(row.accessibilityCustomActions()?.first)
    }

    // MARK: - Pixels

    /// Quiet until the row is current, and visibly answering the pointer once it is. Asserted in
    /// pixels because every one of these states is a claim about what is on the screen: an
    /// assertion that the flag was set says nothing about whether anything was drawn.
    func testTheAccessoryIsInvisibleUntilTheRowIsCurrentAndLitUnderThePointer() throws {
        let atRest = try inkInAccessory(highlighted: nil, hovering: false)
        let current = try inkInAccessory(highlighted: Fixture.auditioned, hovering: false)
        let lit = try inkInAccessory(highlighted: Fixture.auditioned, hovering: true)

        XCTAssertEqual(atRest, 0, accuracy: 0.01, "the accessory drew on a row nobody is on")
        XCTAssertGreaterThan(current, 0.02, "the current row drew no accessory")
        XCTAssertNotEqual(
            lit,
            current,
            accuracy: 0.01,
            "the accessory looks the same whether or not the pointer is on it"
        )
    }

    /// A press has to be visible, and the first version of it was not: a plate drawn behind the
    /// glyph in the hover fill, over a row already filled with the hover fill. Every assertion
    /// passed and the two renders were the same picture, so the picture became this assertion.
    func testAPressLooksDifferentFromTheHoverUnderIt() throws {
        let lit = try inkInAccessory(highlighted: Fixture.auditioned, hovering: true)
        let held = try inkInAccessory(
            highlighted: Fixture.auditioned,
            hovering: true,
            pressed: true
        )

        XCTAssertNotEqual(held, lit, accuracy: 0.01, "a held accessory draws exactly like a hovered one")
    }

    /// Its ink is read from `Design` at draw time rather than frozen when the row was built, so a
    /// theme switched under an **already open** menu re-inks the next frame. The same surface is
    /// measured twice; a fixture rebuilt between the two would prove only that the constructor
    /// reads the current theme.
    func testTheAccessoryFollowsALiveThemeSwitch() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let (_, surface) = present(entries {}, highlighted: Fixture.auditioned)
        ThemedMenuReferenceFixture.setAccessoryPointerState(
            in: surface,
            entryIndex: Fixture.auditioned,
            hovering: true,
            pressed: false
        )
        let underCyberpunk = try inkInAccessory(of: surface)

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        AppThemeRefresh.repaint(try XCTUnwrap(surface.superview))
        let underSwiss = try inkInAccessory(of: surface)

        XCTAssertNotEqual(
            underCyberpunk,
            underSwiss,
            accuracy: 0.01,
            "the accessory kept the theme it was built under"
        )
    }

    // MARK: - Private Methods

    private enum MenuKey {
        static let downArrow: UInt16 = 125
        static let rightArrow: UInt16 = 124
    }

    /// The presenter's own overlay, which is where the menu's keys are handled — the production
    /// path installs a monitor that forwards `keyDown` to exactly this view.
    private func presentedOverlay(
        _ entries: [ThemedMenuEntry],
        selected: Int? = nil
    ) throws -> NSView {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = ThemedSurfaceView()
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = NSRect(origin: .zero, size: Fixture.size)
        host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        window.contentView = host
        let source = NSView(frame: NSRect(x: 8, y: Fixture.size.height - 8, width: 1, height: 1))
        host.addSubview(source)

        let token = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 200),
            from: source,
            selectedEntryIndex: selected,
            onChoose: { _, _ in },
            onDismiss: {}
        )
        addTeardownBlock { MainActor.assumeIsolated { ThemedMenuPresenter.dismiss(token) } }
        host.layoutSubtreeIfNeeded()

        return try XCTUnwrap(
            host.subviews.last { $0 !== source },
            "the presenter added no overlay"
        )
    }

    private func key(keyCode: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    /// How much ink stands in the accessory's rectangle, as a fraction of how far its pixels sit
    /// from the panel behind them. Zero means nothing was drawn there.
    ///
    /// A fraction rather than a colour: the two grammars ink this glyph from different roles and
    /// a classic band flattens it to the band's own label, so a test that named a colour would be
    /// testing today's theme rather than the rule.
    private func inkInAccessory(
        highlighted: Int?,
        hovering: Bool,
        pressed: Bool = false
    ) throws -> CGFloat {
        let (_, surface) = present(entries {}, highlighted: highlighted)
        if hovering || pressed {
            ThemedMenuReferenceFixture.setAccessoryPointerState(
                in: surface,
                entryIndex: Fixture.auditioned,
                hovering: hovering,
                pressed: pressed
            )
        }
        return try inkInAccessory(of: surface)
    }

    private func inkInAccessory(of surface: NSView) throws -> CGFloat {
        let host = try XCTUnwrap(surface.superview)
        host.layoutSubtreeIfNeeded()

        let rect = try XCTUnwrap(
            ThemedMenuReferenceFixture.accessoryHitRect(in: surface, entryIndex: Fixture.auditioned)
        )
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        // The rep is backing-scaled: a point-coordinate scan of a 2x bitmap samples a quarter of
        // the rectangle it was aiming at, and on a row that is mostly panel it samples nothing.
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let inSurface = surface.convert(rect, to: host)
        var strongest: CGFloat = 0
        var background: NSColor?
        for x in stride(from: inSurface.minX, to: inSurface.maxX, by: 0.5) {
            for y in stride(from: inSurface.minY, to: inSurface.maxY, by: 0.5) {
                let pixel = NSPoint(
                    x: (x * scale).rounded(.down),
                    // `colorAt` counts rows from the top; the view counts them from the bottom.
                    y: ((host.bounds.height - y) * scale).rounded(.down)
                )
                guard let colour = rep.colorAt(x: Int(pixel.x), y: Int(pixel.y))?
                    .usingColorSpace(.sRGB) else { continue }
                guard let reference = background else {
                    background = colour
                    continue
                }
                strongest = max(strongest, distance(colour, reference))
            }
        }
        return strongest
    }

    private func distance(_ one: NSColor, _ other: NSColor) -> CGFloat {
        abs(one.redComponent - other.redComponent)
            + abs(one.greenComponent - other.greenComponent)
            + abs(one.blueComponent - other.blueComponent)
    }
}
