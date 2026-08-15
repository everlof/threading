import AppKit
import XCTest
@testable import Threading

/// The Motion page's dropdowns, which show each choice rather than naming it.
///
/// Both settings choose between *animations*, and the previous list named them: deciding meant
/// selecting one, watching it, selecting the next, and comparing against a memory of the first.
/// None of what replaced that is visible to an assertion about a control — a row hosts a live
/// view now, one row at a time demonstrates a text transition, and the second name it morphs to
/// comes out of the bundle — so this is where those claims are pinned, and `testRenders…` is
/// where they are looked at.
@MainActor
final class MotionPreviewTests: XCTestCase {

    private enum Render {
        static let width: CGFloat = SettingsUIDefaults.pageWidth
        static let height: CGFloat = 620

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    private var window: NSWindow?
    private var hostedController: MotionPreferencesViewController?
    private static let hostedWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Render.width, height: Render.height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        return window
    }()

    override func tearDown() {
        Design.Motion.reduceMotionOverrideForTesting = nil
        AppThemePalette.set(.system)
        retireFixtureWindow()
        super.tearDown()
    }

    // MARK: - The Working Indicator

    /// Every row carries the orb it stands for, and its own instance of it: ten rows sharing
    /// one view would show the animation in whichever row happened to be laid out last.
    func testEveryWorkingIndicatorRowCarriesItsOwnLiveOrb() throws {
        let popUp = try orbPopUp()
        var seen: [ObjectIdentifier] = []

        for (index, style) in WorkingOrbStyle.allCases.enumerated() {
            let item = try XCTUnwrap(popUp.item(at: index))
            XCTAssertEqual(item.title, style.displayName)

            let preview = try XCTUnwrap(item.preview, "\(style.displayName) has no preview")
            XCTAssertEqual(preview.placement, .leading)

            let orb = try XCTUnwrap(
                preview.view as? WorkingOrbView,
                "\(style.displayName) previews something other than the orb itself"
            )
            seen.append(ObjectIdentifier(orb))
        }

        XCTAssertEqual(Set(seen).count, WorkingOrbStyle.allCases.count)
    }

    /// A named style shows its own animation; Random has none to show, so what its row
    /// demonstrates is the choosing.
    func testNamedOrbsHoldTheirStateAndRandomRerollsOnHighlight() throws {
        let popUp = try orbPopUp()

        for (index, style) in WorkingOrbStyle.allCases.enumerated() {
            let preview = try XCTUnwrap(popUp.item(at: index)?.preview)
            let orb = try XCTUnwrap(preview.view as? WorkingOrbView)

            guard style != .random else {
                XCTAssertNotNil(
                    preview.highlightChanged,
                    "Random has no fixed orb, so its row has to answer the highlight"
                )
                continue
            }

            XCTAssertEqual(
                orb.state.rawValue, style.rawValue,
                "\(style.displayName) previews the wrong animation"
            )
            let before = orb.state
            preview.highlightChanged?(true)
            XCTAssertEqual(orb.state, before, "a named orb changed under the pointer")
        }
    }

    // MARK: - Chat Name Transitions

    func testEveryTransitionRowIsItsOwnMorphingName() throws {
        let popUp = try namePopUp()

        for (index, style) in ChatNameMorphStyle.allCases.enumerated() {
            let item = try XCTUnwrap(popUp.item(at: index))
            let preview = try XCTUnwrap(item.preview, "\(style.displayName) has no preview")

            // The name *is* the preview, so the row draws no title of its own — and the item
            // keeps the title anyway, which is what filtering and VoiceOver read.
            XCTAssertEqual(preview.placement, .title)
            XCTAssertEqual(item.title, style.displayName)

            let label = try XCTUnwrap(preview.view as? MorphingTitleLabel)
            XCTAssertEqual(label.stringValue, style.displayName)
        }
    }

    /// A demonstration holds the row's own name first. The highlight is also where it lands when
    /// the menu opens, so a list that started morphing immediately would show the app's name in
    /// the one row whose own name the user came to read.
    func testAnOpenedMenuShowsEveryNameBeforeAnythingMoves() throws {
        let popUp = try namePopUp(inWindow: true)

        XCTAssertTrue(popUp.accessibilityPerformShowMenu())

        for (index, style) in ChatNameMorphStyle.allCases.enumerated() {
            let label = try XCTUnwrap(
                popUp.item(at: index)?.preview?.view as? MorphingTitleLabel
            )
            XCTAssertEqual(
                label.stringValue, style.displayName,
                "\(style.displayName) started demonstrating before its name could be read"
            )
        }
    }

    /// Once the dwell passes, the highlighted row demonstrates — and that row alone: eleven
    /// names morphing at once is the thing this replaced.
    func testTheHighlightedRowDemonstratesAndTheOthersHoldStill() throws {
        let popUp = try namePopUp(inWindow: true)
        let selected = AppSettings.shared.chatNameMorphStyle

        XCTAssertTrue(popUp.accessibilityPerformShowMenu())
        waitOutTheDwell()

        for (index, style) in ChatNameMorphStyle.allCases.enumerated() {
            let label = try XCTUnwrap(
                popUp.item(at: index)?.preview?.view as? MorphingTitleLabel
            )
            if style == selected {
                XCTAssertEqual(
                    label.stringValue, AppInfo.name,
                    "the highlighted row is not demonstrating"
                )
            } else {
                XCTAssertEqual(
                    label.stringValue, style.displayName,
                    "\(style.displayName) is animating without the highlight"
                )
            }
        }
    }

    /// Moving the highlight on hands the demonstration over. The row that gives it up goes back
    /// to its own name rather than being left showing the app's.
    func testMovingTheHighlightHandsTheDemonstrationOver() throws {
        let popUp = try namePopUp(inWindow: true)
        let selected = AppSettings.shared.chatNameMorphStyle
        let selectedIndex = try XCTUnwrap(ChatNameMorphStyle.allCases.firstIndex(of: selected))
        let next = try XCTUnwrap(
            ChatNameMorphStyle.allCases.first { $0 != selected }
        )
        let nextIndex = try XCTUnwrap(ChatNameMorphStyle.allCases.firstIndex(of: next))

        XCTAssertTrue(popUp.accessibilityPerformShowMenu())

        let leaving = try XCTUnwrap(
            popUp.item(at: selectedIndex)?.preview?.view as? MorphingTitleLabel
        )
        let arriving = try XCTUnwrap(popUp.item(at: nextIndex)?.preview)

        // The reports arrive in no defined order — the menu holds its rows in a dictionary — so
        // the row that is starting is told first, which is the order that used to cancel it.
        arriving.highlightChanged?(true)
        popUp.item(at: selectedIndex)?.preview?.highlightChanged?(false)
        waitOutTheDwell()

        XCTAssertEqual(
            (arriving.view as? MorphingTitleLabel)?.stringValue, AppInfo.name,
            "the row the highlight arrived on was stopped by the row it left"
        )
        XCTAssertEqual(
            leaving.stringValue, selected.displayName,
            "the row left behind kept the app's name"
        )
    }

    /// A closed menu takes its demonstration with it. Nothing reports a highlight leaving when
    /// the dropdown is dismissed, so the row's own departure from the window is what ends it.
    func testDismissingTheMenuEndsTheDemonstration() throws {
        let popUp = try namePopUp(inWindow: true)
        let selected = AppSettings.shared.chatNameMorphStyle
        let index = try XCTUnwrap(ChatNameMorphStyle.allCases.firstIndex(of: selected))
        let label = try XCTUnwrap(popUp.item(at: index)?.preview?.view as? MorphingTitleLabel)

        XCTAssertTrue(popUp.accessibilityPerformShowMenu())
        waitOutTheDwell()
        XCTAssertEqual(label.stringValue, AppInfo.name)

        let responder = try XCTUnwrap(window?.firstResponder)
        responder.keyDown(with: try escapeKey())
        // The panel leaves by a fade, so the row departs the window one turn later.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertEqual(
            label.stringValue, selected.displayName,
            "a dismissed menu left a row mid-demonstration"
        )
    }

    /// Reopening the dropdown before the previous panel has faded hands the same preview view to
    /// a new row. The row it was taken from has to stay quiet about losing it, or its teardown
    /// cancels a demonstration that has already started and the feature looks broken.
    func testReopeningBeforeTheOldPanelFadesKeepsTheDemonstration() throws {
        let popUp = try namePopUp(inWindow: true)
        let selected = AppSettings.shared.chatNameMorphStyle
        let index = try XCTUnwrap(ChatNameMorphStyle.allCases.firstIndex(of: selected))
        let label = try XCTUnwrap(popUp.item(at: index)?.preview?.view as? MorphingTitleLabel)

        XCTAssertTrue(popUp.accessibilityPerformShowMenu())
        let responder = try XCTUnwrap(window?.firstResponder)
        responder.keyDown(with: try escapeKey())

        // No run loop in between: the dismissed panel is still on screen, fading.
        XCTAssertTrue(popUp.accessibilityPerformShowMenu())
        waitOutTheDwell()

        XCTAssertEqual(
            label.stringValue, AppInfo.name,
            "the fading panel's row cancelled the demonstration on the new one"
        )
    }

    /// Under Reduce Motion the rows keep their names and stay still. `setStringValue` would not
    /// animate, so demonstrating here would be two names swapping outright — more visual change
    /// than the list it replaced, in the setting that asked for less.
    func testReduceMotionKeepsEveryRowStill() throws {
        Design.Motion.reduceMotionOverrideForTesting = true
        let popUp = try namePopUp(inWindow: true)

        XCTAssertTrue(popUp.accessibilityPerformShowMenu())
        waitOutTheDwell()

        for (index, style) in ChatNameMorphStyle.allCases.enumerated() {
            let label = try XCTUnwrap(
                popUp.item(at: index)?.preview?.view as? MorphingTitleLabel
            )
            XCTAssertEqual(label.stringValue, style.displayName)
        }
    }

    /// The second name is the app's, and it is read rather than written down — the whole reason
    /// `AppInfo` exists.
    func testTheDemonstratedNameComesFromTheBundle() throws {
        let bundled = Bundle.main.infoDictionary?["CFBundleName"] as? String
        if let bundled, !bundled.isEmpty {
            XCTAssertEqual(AppInfo.name, bundled)
        }
        XCTAssertFalse(AppInfo.name.isEmpty)
    }

    /// The morph a demonstration waits for is the preset's, cascaded across the longer name.
    /// One fixed period would cut Bounce off mid-cascade and leave Typewriter looking finished.
    func testTheDemonstrationWaitsForThePresetItIsShowing() {
        let label = MorphingTitleLabel()
        label.setStringValue("Shape Morph", animated: false)

        label.morphStyleOverride = .typewriter
        let typewriter = label.morphSettleDuration(to: AppInfo.name)
        label.morphStyleOverride = .bounce
        let bounce = label.morphSettleDuration(to: AppInfo.name)

        XCTAssertGreaterThan(typewriter, 0)
        XCTAssertGreaterThan(bounce, typewriter)

        Design.Motion.reduceMotionOverrideForTesting = true
        XCTAssertEqual(label.morphSettleDuration(to: AppInfo.name), 0)
    }

    /// A name transition is budgeted whole, not per character.
    ///
    /// The stagger is a cascade's cost and it is multiplied by the name, so a preset's own step
    /// makes the same transition read as slower the more there is to read: at the default
    /// preset's 45ms a session title that is a sentence took two and a half seconds to settle,
    /// nearly all of it cascade. Every preset is pinned, since the budget is the wrapper's and
    /// the step is the package's.
    func testANameTransitionIsBudgetedRatherThanPaidPerCharacter() {
        Design.Motion.reduceMotionOverrideForTesting = false

        let short = "Land it"
        let long = "Land the redirect fix and update the guide"
        let longer = long + ", then land the follow-up behind it as well"

        for style in ChatNameMorphStyle.allCases {
            let label = MorphingTitleLabel()
            label.morphStyleOverride = style
            label.setStringValue("Fix", animated: false)

            let settled = [short, long, longer].map(label.morphSettleDuration(to:))

            XCTAssertGreaterThanOrEqual(settled[1], settled[0], style.displayName)
            // Past the budget, length stops buying time at all.
            XCTAssertEqual(settled[2], settled[1], accuracy: 0.001, style.displayName)
            XCTAssertLessThan(
                settled[2], 0.8,
                "\(style.displayName) settles a long name in \(settled[2])s"
            )
        }
    }

    // MARK: - Geometry

    /// A hosted preview and a drawn title start in the same place. The column of names shifting
    /// four points as one of them animates would read as a bug in the menu rather than as the
    /// transition it is demonstrating.
    func testAPreviewColumnMovesTheTitleAndNothingElse() {
        let plain = ThemedMenuMetrics.titleInset(
            checkColumn: .none,
            hasImageColumn: false,
            hasPreviewColumn: false
        )
        let withPreview = ThemedMenuMetrics.titleInset(
            checkColumn: .none,
            hasImageColumn: false,
            hasPreviewColumn: true
        )

        XCTAssertEqual(withPreview, plain + ThemedMenuMetrics.previewSlot)
        XCTAssertEqual(
            ThemedMenuMetrics.previewInset(checkColumn: .none, hasImageColumn: false),
            ThemedMenuMetrics.markInset(checkColumn: .none)
        )
        XCTAssertEqual(
            ThemedMenuMetrics.titleInset(
                checkColumn: .none,
                hasImageColumn: true,
                hasPreviewColumn: false
            ),
            plain + ThemedMenuMetrics.imageSlot
        )
    }

    /// The column is reserved only when something is in it, on the same terms as the image
    /// column — and a preview placed in the *title's* slot reserves nothing, because that
    /// column already exists.
    func testOnlyALeadingPreviewReservesAColumn() {
        let orb = ThemedMenuPreview(placement: .leading, view: WorkingOrbView())
        let name = ThemedMenuPreview(placement: .title, view: MorphingTitleLabel())

        let plain: [ThemedMenuEntry] = [.item(ThemedMenuItem(title: "Bounce"))]
        let leading: [ThemedMenuEntry] = [.item(ThemedMenuItem(title: "Bounce", preview: orb))]
        let title: [ThemedMenuEntry] = [.item(ThemedMenuItem(title: "Bounce", preview: name))]

        XCTAssertFalse(ThemedMenuMetrics.hasPreviewColumn(plain))
        XCTAssertTrue(ThemedMenuMetrics.hasPreviewColumn(leading))
        XCTAssertFalse(ThemedMenuMetrics.hasPreviewColumn(title))

        let base = ThemedMenuMetrics.width(for: plain, minimum: 0)
        XCTAssertEqual(
            ThemedMenuMetrics.width(for: leading, minimum: 0),
            base + ThemedMenuMetrics.previewSlot
        )
        XCTAssertEqual(ThemedMenuMetrics.width(for: title, minimum: 0), base)
    }

    /// The row places the orb in the column the metrics name, and hands its own name to
    /// VoiceOver as words rather than as a view to navigate into.
    func testTheOpenMenuPlacesItsPreviewsAndStaysOneElementPerRow() throws {
        let popUp = try orbPopUp(inWindow: true)
        XCTAssertTrue(popUp.accessibilityPerformShowMenu())

        let orb = try XCTUnwrap(popUp.item(at: 0)?.preview?.view as? WorkingOrbView)
        let row = try XCTUnwrap(orb.superview)
        window?.contentView?.layoutSubtreeIfNeeded()

        // `.shared`: a pop-up always marks the choice it is currently showing, and no row here
        // carries an icon, so the mark and the previews share one leading column.
        XCTAssertEqual(
            orb.frame.minX,
            ThemedMenuMetrics.previewInset(checkColumn: .shared, hasImageColumn: false),
            accuracy: 0.5
        )
        XCTAssertEqual(orb.frame.midY, row.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(orb.frame.width, ThemedMenuMetrics.previewSize, accuracy: 0.5)
        XCTAssertTrue(
            orb.constraints.filter {
                $0.priority == .required
                    && $0.secondItem == nil
                    && ($0.firstAttribute == .width || $0.firstAttribute == .height)
            }.isEmpty,
            "the row left its theme-specific size constraints on a reusable preview"
        )

        XCTAssertEqual(row.accessibilityRole(), .menuItem)
        XCTAssertEqual(row.accessibilityTitle(), WorkingOrbStyle.allCases[0].displayName)
        XCTAssertEqual(
            row.accessibilityChildren()?.count, 0,
            "the preview is showing up as something to navigate into"
        )
    }

    /// A live view handed into a themed row is still app-owned chrome, and both dropdowns hand
    /// one over.
    func testAnOpenPreviewMenuContainsNoRawAppKitChrome() throws {
        for identifier in [
            MotionPreferencesViewController.Identifier.orbStyle,
            MotionPreferencesViewController.Identifier.nameStyle
        ] {
            let popUp = try popUpInWindow(identifier)
            XCTAssertTrue(popUp.accessibilityPerformShowMenu())

            let window = try XCTUnwrap(self.window)
            XCTAssertEqual(
                ThemeBoundaryAudit.violations(in: window), [],
                "\(identifier) opened a dropdown containing system chrome"
            )
            retireFixtureWindow()
        }
    }

    // MARK: - Renders

    /// Draws the page with each dropdown open, under System and two deliberately different
    /// themes. The claim being checked is not a measurement: it is whether a column of orbs
    /// beside a column of names reads as a list of choices or as a busy smear, which is visible
    /// in a picture and in no assertion anyone would write.
    func testRendersBothDropdownsUnderEveryStockTheme() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for theme in AppThemeLibrary.stock {
            AppThemePalette.set(theme)

            for identifier in [
                MotionPreferencesViewController.Identifier.orbStyle,
                MotionPreferencesViewController.Identifier.nameStyle
            ] {
                let popUp = try popUpInWindow(identifier)
                XCTAssertTrue(popUp.accessibilityPerformShowMenu())
                // Past the dwell, so the highlighted row is caught demonstrating rather than at
                // rest — the state worth looking at is the one the still cannot otherwise show.
                waitOutTheDwell()

                let name = [
                    "motion",
                    identifier.replacingOccurrences(of: "motion.", with: ""),
                    theme.id.rawValue
                ].joined(separator: "-")
                let png = try capture(named: name)
                try png.write(to: directory.appendingPathComponent("\(name).png"))

                retireFixtureWindow()
            }
        }
    }

    // MARK: - Fixtures

    private func orbPopUp(inWindow: Bool = false) throws -> ThemedPopUp {
        inWindow
            ? try popUpInWindow(MotionPreferencesViewController.Identifier.orbStyle)
            : try popUp(MotionPreferencesViewController.Identifier.orbStyle, in: page())
    }

    private func namePopUp(inWindow: Bool = false) throws -> ThemedPopUp {
        inWindow
            ? try popUpInWindow(MotionPreferencesViewController.Identifier.nameStyle)
            : try popUp(MotionPreferencesViewController.Identifier.nameStyle, in: page())
    }

    /// The dropdown presents itself into the source's window, so anything that opens one needs
    /// a real window rather than a detached view.
    ///
    /// Deliberately **not** ordered on screen. The window is shared by every test in this class,
    /// while each test receives a fresh controller and therefore fresh settings-page state.
    /// AppKit's
    /// custom-menu teardown leaves private autoreleased collections referring to its host
    /// window; releasing that window while XCTest drains the same case's pool crashes in
    /// `objc_release`. One stable unshown host avoids both that lifetime race and the live-window
    /// accumulation caused by creating and merely ordering out a new host for every theme.
    private func popUpInWindow(_ identifier: String) throws -> ThemedPopUp {
        retireFixtureWindow()
        let window = Self.hostedWindow
        let controller: MotionPreferencesViewController
        if let hostedController {
            controller = hostedController
        } else {
            controller = MotionPreferencesViewController()
            hostedController = controller
            // Replacing the previous test's controller happens in the next test's autorelease
            // pool, after AppKit has finished draining the menu session that used it.
            window.contentViewController = controller
        }
        // Assigning a content view controller sizes the window to its view's fitting size, and
        // a settings page's height comes from its scroll view — which fits in nothing.
        window.setContentSize(NSSize(width: Render.width, height: Render.height))
        self.window = window
        controller.view.layoutSubtreeIfNeeded()
        return try popUp(identifier, in: controller.view)
    }

    private func page() -> NSView {
        let controller = MotionPreferencesViewController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Render.width, height: Render.height))
        controller.view.frame = host.bounds
        host.addSubview(controller.view)
        host.layoutSubtreeIfNeeded()
        return controller.view
    }

    private func popUp(_ identifier: String, in root: NSView) throws -> ThemedPopUp {
        let match = descendants(of: root).first {
            $0.accessibilityIdentifier() == identifier
        }
        return try XCTUnwrap(match as? ThemedPopUp, "no control identified \(identifier)")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// A custom dropdown is an in-window overlay with responder and event-tracking ownership.
    /// Retire that session synchronously, then keep the class's one unshown host alive for reuse.
    private func retireFixtureWindow() {
        guard let window else { return }
        if let content = window.contentView {
            for popUp in descendants(of: content).compactMap({ $0 as? ThemedPopUp }) {
                popUp.dismissMenu()
            }
        }
        window.orderOut(nil)
        self.window = nil
    }

    /// Runs the main run loop past the dwell a demonstration holds its own name for, plus room
    /// for the morph it then starts. Real time rather than a fake clock, because the thing being
    /// checked is a timer scheduled in `.common` — a seam that skipped the run loop would prove
    /// the arithmetic and not the scheduling.
    private func waitOutTheDwell() {
        let settle = Design.Motion.demonstrationHold + 0.4
        RunLoop.main.run(until: Date(timeIntervalSinceNow: settle))
    }

    private func escapeKey() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window?.windowNumber ?? 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
    }

    private func capture(named name: String) throws -> Data {
        let root = try XCTUnwrap(window?.contentViewController?.view)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        root.layoutSubtreeIfNeeded()

        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            root.wantsLayer = true
            root.layer?.backgroundColor = Design.Surface.ground.cgColor
        }

        XCTAssertFalse(root.bounds.isEmpty, "\(name) root bounds \(root.bounds)")
        let rep = try XCTUnwrap(
            root.bitmapImageRepForCachingDisplay(in: root.bounds),
            "\(name) could not cache \(root.bounds) window=\(String(describing: root.window))"
        )
        root.cacheDisplay(in: root.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000, "\(name) rendered as an empty image")

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
        return png
    }
}
