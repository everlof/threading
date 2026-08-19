import AppKit
import XCTest
@testable import Threading

/// The interaction contract shared by app-owned alerts and popovers.
///
/// These are presentation components, not just painted cards: edge placement, Escape, focus
/// return, accessibility, theme refresh, and the absence of stock chrome are the behavior.
@MainActor
final class ThemedPresentationTests: XCTestCase {

    // MARK: - Popover geometry

    func testPopoverFlipsAwayFromTheScreenEdge() {
        let placement = ThemedPopoverLayout.place(
            anchor: NSRect(x: 970, y: 280, width: 20, height: 30),
            contentSize: NSSize(width: 220, height: 120),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            preferredEdge: .maxX
        )

        XCTAssertEqual(placement.edge, .minX)
        XCTAssertLessThan(placement.panelFrame.maxX, 970)
    }

    func testPopoverClampsToTheVisibleScreenAndKeepsItsArrowOnTheAnchor() {
        let anchor = NSRect(x: 2, y: 2, width: 18, height: 18)
        let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
        let placement = ThemedPopoverLayout.place(
            anchor: anchor,
            contentSize: NSSize(width: 280, height: 180),
            visibleFrame: screen,
            preferredEdge: .minY
        )

        XCTAssertGreaterThanOrEqual(placement.panelFrame.minX, screen.minX + 8)
        XCTAssertGreaterThanOrEqual(placement.panelFrame.minY, screen.minY + 8)
        XCTAssertLessThanOrEqual(placement.panelFrame.maxX, screen.maxX - 8)
        XCTAssertLessThanOrEqual(placement.panelFrame.maxY, screen.maxY - 8)

        let globalTip = NSPoint(
            x: placement.panelFrame.minX + placement.arrowTip.x,
            y: placement.panelFrame.minY + placement.arrowTip.y
        )
        XCTAssertGreaterThanOrEqual(globalTip.x, anchor.minX)
        XCTAssertLessThanOrEqual(globalTip.x, anchor.maxX)
        XCTAssertEqual(globalTip.y, anchor.maxY + ThemedPopoverLayout.anchorGap, accuracy: 0.5)
    }

    // MARK: - Popover chrome drawing

    /// The border must run unbroken through the two junctions where the arrow leaves the body.
    ///
    /// The chrome used to fill and stroke the body and the arrow as two paths and repaint
    /// their seam in surface colour — which also erased the tails of the arrow's own stroked
    /// sides, leaving gaps at exactly those junctions. The gap was visible in a picture and in
    /// no assertion, so this samples the drawn pixels along the outline itself.
    func testPopoverBorderRunsUnbrokenThroughTheArrowJunctions() throws {
        let placement = ThemedPopoverLayout.place(
            anchor: NSRect(x: 40, y: 300, width: 20, height: 20),
            contentSize: NSSize(width: 220, height: 140),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            preferredEdge: .maxX
        )
        XCTAssertEqual(placement.edge, .maxX, "the fixture wants the arrow on the left edge")

        let chrome = ThemedPopoverChromeView(
            frame: NSRect(origin: .zero, size: placement.panelFrame.size)
        )
        chrome.placement = placement
        let rep = try rendered(chrome, scale: 3)
        try writeRender(of: rep, named: "popover-chrome-left-arrow")

        let body = placement.bodyFrame
        let inset = Design.Radius.border / 2
        let wallX = body.minX + inset
        let tip = NSPoint(x: inset, y: placement.arrowTip.y)
        let half = ThemedPopoverLayout.arrowBreadth / 2
        let baseTop = NSPoint(x: wallX, y: tip.y + half)
        let baseBottom = NSPoint(x: wallX, y: tip.y - half)
        let surface = try pixel(of: rep, at: NSPoint(x: body.midX, y: body.midY), in: chrome)

        let samples: [(NSPoint, String)] = [
            (NSPoint(x: wallX, y: baseTop.y + 8), "the wall above the arrow"),
            (NSPoint(x: wallX, y: baseBottom.y - 8), "the wall below the arrow"),
            (along(baseTop, tip, 0.5), "the arrow's upper side"),
            (along(baseBottom, tip, 0.5), "the arrow's lower side"),
            // The two junctions — the exact pixels the seam repaint used to erase.
            (along(baseTop, tip, 0.05), "the upper junction"),
            (along(baseBottom, tip, 0.05), "the lower junction")
        ]
        for (point, place) in samples {
            let sample = try pixel(of: rep, at: point, in: chrome)
            XCTAssertGreaterThan(
                contrast(sample, surface), 0.03,
                "\(place) shows no border ink at (\(point.x), \(point.y))"
            )
        }
    }

    func testPopoverChromeRendersEveryArrowEdge() throws {
        let screen = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let anchors: [(NSRectEdge, NSRect)] = [
            (.maxX, NSRect(x: 300, y: 390, width: 20, height: 20)),
            (.minX, NSRect(x: 880, y: 390, width: 20, height: 20)),
            (.maxY, NSRect(x: 590, y: 240, width: 20, height: 20)),
            (.minY, NSRect(x: 590, y: 560, width: 20, height: 20)),
        ]
        var renders = Set<Data>()

        for (edge, anchor) in anchors {
            let placement = ThemedPopoverLayout.place(
                anchor: anchor,
                contentSize: NSSize(width: 220, height: 140),
                visibleFrame: screen,
                preferredEdge: edge
            )
            XCTAssertEqual(placement.edge, edge)
            let chrome = ThemedPopoverChromeView(
                frame: NSRect(origin: .zero, size: placement.panelFrame.size)
            )
            chrome.placement = placement
            let rep = try rendered(chrome, scale: 2)
            try writeRender(of: rep, named: "popover-chrome-\(edge.rawValue)-arrow")
            renders.insert(try XCTUnwrap(rep.representation(using: .png, properties: [:])))
        }

        XCTAssertEqual(renders.count, anchors.count, "an arrow edge rendered as another edge")
    }

    /// Aqua Help Tags are compact pale-yellow plates, not the modern rounded speech bubble. The
    /// Tiger HIG measures that grammar directly; Cheetah's surviving plate is the nearest later
    /// figure and remains source-shaped in its manifest rather than promoted to native 10.0
    /// pixels.
    func testAquaHelpTagPopoverUsesThePeriodPlateGrammar() throws {
        let previous = AppThemePalette.current
        defer { AppThemePalette.set(previous) }

        for (theme, fixture) in [
            (AppThemeStyles.aqua, "popover-chrome-aqua-cheetah-help-tag"),
            (AppThemeStyles.aquaTiger, "popover-chrome-aqua-tiger-help-tag")
        ] {
            AppThemePalette.set(theme)
            let material = theme.material
            let contentSize = NSSize(width: 125, height: 18)
            let placement = ThemedPopoverLayout.place(
                anchor: NSRect(x: 300, y: 390, width: 20, height: 20),
                contentSize: contentSize,
                visibleFrame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
                preferredEdge: .maxY,
                style: material.popoverStyle,
                hasMaterialShadow: false,
                bevelWidth: material.bevel?.width
            )

            XCTAssertFalse(placement.hasArrow, "Help Tags are stemless plates")
            XCTAssertFalse(placement.classic, "Aqua Help Tag copy keeps Lucida-style text")
            XCTAssertEqual(material.popoverStyle.cornerRadius, 1)

            let chrome = ThemedPopoverChromeView(
                frame: NSRect(origin: .zero, size: placement.panelFrame.size)
            )
            chrome.placement = placement
            let rep = try rendered(chrome, scale: 2)
            try writeRender(of: rep, named: fixture)

            let centre = try pixel(
                of: rep,
                at: NSPoint(x: placement.bodyFrame.midX, y: placement.bodyFrame.midY),
                in: chrome
            )
            let expected = AppThemePalette.current.resolved(.tooltipSurface)
            XCTAssertEqual(centre.hexString, expected.hexString)

            let edge = try pixel(
                of: rep,
                at: NSPoint(x: placement.bodyFrame.minX + 0.5, y: placement.bodyFrame.midY),
                in: chrome
            )
            XCTAssertGreaterThan(contrast(edge, centre), 0.05,
                                 "the Help Tag lost its one-pixel warm edge")
        }
    }

    func testWindows98PopoverUsesAPaleSquareStemlessInfotip() throws {
        AppThemePalette.set(AppThemeStyles.win98)
        defer { AppThemePalette.set(.system) }

        let contentSize = NSSize(width: 220, height: 140)
        let material = AppThemeStyles.win98.material
        let placement = ThemedPopoverLayout.place(
            anchor: NSRect(x: 300, y: 390, width: 20, height: 20),
            contentSize: contentSize,
            visibleFrame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            preferredEdge: .maxX,
            style: material.popoverStyle,
            hasMaterialShadow: material.glow != nil,
            bevelWidth: material.bevel?.width
        )

        XCTAssertTrue(placement.classic)
        XCTAssertFalse(placement.hasArrow)
        XCTAssertEqual(placement.bodyFrame.origin, .zero)
        XCTAssertEqual(placement.bodyFrame.size, placement.panelFrame.size)
        XCTAssertEqual(placement.contentFrame.width, contentSize.width)
        XCTAssertEqual(placement.contentFrame.height, contentSize.height)
        XCTAssertEqual(placement.contentFrame.minX, ThemedPopoverLayout.compactBorderInset)

        let chrome = ThemedPopoverChromeView(
            frame: NSRect(origin: .zero, size: placement.panelFrame.size)
        )
        chrome.placement = placement
        let rep = try rendered(chrome, scale: 2)
        try writeRender(of: rep, named: "popover-chrome-win98-infotip")
        let centre = try pixel(
            of: rep,
            at: NSPoint(x: placement.bodyFrame.midX, y: placement.bodyFrame.midY),
            in: chrome
        )
        XCTAssertEqual(centre.hexString, "#FFFFE1")
        let edge = try pixel(
            of: rep,
            at: NSPoint(x: 0.5, y: placement.bodyFrame.midY),
            in: chrome
        )
        XCTAssertGreaterThan(contrast(edge, centre), 0.1, "the infotip lost its thin dark rule")
    }

    func testPeriodPopoverCanConsumeTheMaterialsHardBevel() throws {
        AppThemePalette.set(AppThemeStyles.platinum)
        defer { AppThemePalette.set(.system) }

        let material = AppThemeStyles.platinum.material
        let placement = ThemedPopoverLayout.place(
            anchor: NSRect(x: 300, y: 390, width: 20, height: 20),
            contentSize: NSSize(width: 220, height: 140),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            preferredEdge: .maxX,
            style: material.popoverStyle,
            hasMaterialShadow: false,
            bevelWidth: material.bevel?.width
        )
        let chrome = ThemedPopoverChromeView(
            frame: NSRect(origin: .zero, size: placement.panelFrame.size)
        )
        chrome.placement = placement
        let rep = try rendered(chrome, scale: 2)
        try writeRender(of: rep, named: "popover-chrome-platinum-bevel")
        let topLeft = try pixel(
            of: rep,
            at: NSPoint(x: 0.5, y: placement.bodyFrame.maxY - 0.5),
            in: chrome
        )
        let bottomRight = try pixel(
            of: rep,
            at: NSPoint(x: placement.bodyFrame.maxX - 0.5, y: 0.5),
            in: chrome
        )
        XCTAssertNotEqual(topLeft.hexString, bottomRight.hexString)
    }

    func testPopoverWindowUsesOnlyTheDepthConstructionChosenByItsTheme() throws {
        let previous = AppThemePalette.current
        defer { AppThemePalette.set(previous) }

        let window = offscreenWindow()
        let anchor = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)
        for (theme, expectsSystemShadow) in [
            (AppTheme.system, true),
            (AppThemeStyles.win98, false),
            (AppThemeStyles.neoBrutalism, false),
            (AppThemeStyles.claymorphism, false)
        ] {
            AppThemePalette.set(theme)
            let popover = ThemedPopover()
            popover.animates = false
            popover.contentViewController = popoverContent()
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

            let panel = try XCTUnwrap(popover.presentedWindow)
            XCTAssertEqual(
                panel.hasShadow,
                expectsSystemShadow,
                "\(theme.name) used the wrong native window shadow"
            )
            popover.close()
        }
    }

    // MARK: - Dismissal and focus

    func testPopoverEscapeClosesOnceAndReturnsFocus() throws {
        let window = testWindow()
        defer { settle(window) }
        let anchor = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)
        XCTAssertTrue(window.makeFirstResponder(anchor))

        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        content.preferredContentSize = content.view.frame.size

        let popover = ThemedPopover()
        popover.contentViewController = content
        var closes = 0
        popover.onClose = { closes += 1 }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        XCTAssertTrue(popover.isShown)
        let panel = try XCTUnwrap(popover.presentedWindow)
        panel.makeKey()
        panel.cancelOperation(nil)

        XCTAssertFalse(popover.isShown)
        XCTAssertNil(popover.presentedWindow)
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(window.firstResponder === anchor)

        popover.close()
        XCTAssertEqual(closes, 1, "closing an already closed surface must be idempotent")
    }

    /// Ordering a panel front is not enough to type into it, and every cheaper assertion says it
    /// is: on a merely-visible panel `makeFirstResponder` returns true and installs the field
    /// editor, so a caret blinks in the popover while the keystrokes reach the window underneath.
    /// ⌘J's file search shipped that way. Only key status is evidence, so that is what is asserted.
    func testPopoverWithAnInitialResponderTakesKeyStatusAndGivesItBack() throws {
        try activateHost()
        let window = testWindow()
        defer { settle(window) }
        let anchor = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)
        XCTAssertTrue(window.makeFirstResponder(anchor))

        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 160, height: 24))
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        content.view.addSubview(field)
        content.preferredContentSize = content.view.frame.size

        let popover = ThemedPopover()
        popover.animates = false
        popover.contentViewController = content
        popover.initialFirstResponder = field
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        let panel = try XCTUnwrap(popover.presentedWindow)
        XCTAssertTrue(panel.isKeyWindow, "a popover asked for the keyboard must hold it")
        XCTAssertTrue(NSApp.keyWindow === panel, "typing must be routed to the popover")
        XCTAssertTrue((panel.firstResponder as? NSTextView)?.delegate === field)
        XCTAssertNotNil(field.currentEditor())

        popover.close()
        XCTAssertFalse(NSApp.keyWindow === panel)
        XCTAssertTrue(
            window.firstResponder === anchor,
            "the keyboard returns to the responder it was taken from"
        )
    }

    /// The other half of the same rule. Most popovers here are pointer-driven, and one that took
    /// key status unasked would pull the caret out of the composer and unemphasize every list
    /// behind it — so the keyboard stays put unless the content named a responder.
    func testPopoverWithoutAnInitialResponderLeavesTheKeyboardWhereItWas() throws {
        let window = offscreenWindow()
        let anchor = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)
        XCTAssertTrue(window.makeFirstResponder(anchor))

        let popover = ThemedPopover()
        popover.animates = false
        popover.contentViewController = popoverContent()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        let panel = try XCTUnwrap(popover.presentedWindow)
        XCTAssertFalse(panel.isKeyWindow, "an unasked popover must not take the keyboard")
        XCTAssertFalse(NSApp.keyWindow === panel)
        XCTAssertTrue(window.firstResponder === anchor)
        popover.close()
    }

    func testPopoverClosesWhenItsAnchorLeavesTheHierarchy() throws {
        let window = offscreenWindow()
        let anchor = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        content.preferredContentSize = content.view.frame.size
        let popover = ThemedPopover()
        popover.animates = false
        popover.contentViewController = content
        var closes = 0
        popover.onClose = { closes += 1 }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        anchor.removeFromSuperview()
        popover.reposition()

        XCTAssertFalse(popover.isShown)
        XCTAssertNil(popover.presentedWindow)
        XCTAssertEqual(closes, 1)
    }

    func testDroppingPopoverOwnerDetachesAndTearsDownItsPanel() throws {
        let window = offscreenWindow()
        let anchor = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        content.preferredContentSize = content.view.frame.size

        var popover: ThemedPopover? = ThemedPopover()
        popover?.animates = false
        popover?.contentViewController = content
        popover?.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        let panel = try XCTUnwrap(popover?.presentedWindow)
        XCTAssertTrue(window.childWindows?.contains(panel) == true)

        popover = nil
        let detached = expectation(description: "panel detached on owner deinit")
        DispatchQueue.main.async {
            XCTAssertNil(panel.parent)
            XCTAssertFalse(panel.isVisible)
            XCTAssertNil(panel.contentViewController)
            detached.fulfill()
        }
        wait(for: [detached], timeout: 1)
    }

    // MARK: - Popovers and dropdowns in one window

    /// The reported bug: the hover card over a sidebar row stayed up when that row's `+` opened
    /// its dropdown, and — being a child window over a menu drawn inside the window — covered
    /// the rows the click was aiming for.
    func testOpeningADropdownClosesThePopoverThatWouldCoverIt() throws {
        let window = offscreenWindow()
        let anchor = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)

        let popover = ThemedPopover()
        popover.animates = false
        popover.contentViewController = popoverContent()
        var closes = 0
        popover.onClose = { closes += 1 }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        XCTAssertTrue(popover.isShown)

        let session = try XCTUnwrap(presentMenu(from: anchor))
        defer { ThemedMenuPresenter.dismiss(session) }

        XCTAssertFalse(popover.isShown, "the dropdown opened underneath an open popover")
        XCTAssertNil(popover.presentedWindow)
        XCTAssertEqual(closes, 1)
    }

    /// The same collision from the other side: hover tracking keeps firing while a dropdown is
    /// open, so a row crossed on the way down the menu must not raise a card over it.
    func testAPopoverDoesNotOpenWhileADropdownIsUpInTheSameWindow() throws {
        let window = offscreenWindow()
        let anchor = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)

        let session = try XCTUnwrap(presentMenu(from: anchor))
        let popover = ThemedPopover()
        popover.animates = false
        popover.contentViewController = popoverContent()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        XCTAssertFalse(popover.isShown, "a popover opened over a dropdown that was already up")
        XCTAssertNil(popover.presentedWindow)

        ThemedMenuPresenter.dismiss(session)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        defer { popover.close() }
        XCTAssertTrue(popover.isShown, "the dropdown's exit left hover popovers shut out")
    }

    /// The exception the rule needs: a dropdown opened from a control *inside* a popover is
    /// presented in that panel's own window, and closing the surface it belongs to would take
    /// the menu down with it.
    func testADropdownOpenedInsideAPopoverLeavesItOpen() throws {
        let window = offscreenWindow()
        let anchor = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)

        let content = popoverContent()
        let inner = ThemedButton(title: "Inside", target: nil, action: nil)
        inner.frame = NSRect(x: 10, y: 10, width: 80, height: Design.Size.chipHeight)
        content.view.addSubview(inner)

        let popover = ThemedPopover()
        popover.animates = false
        popover.contentViewController = content
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        defer { popover.close() }
        XCTAssertNotNil(inner.window)

        let session = try XCTUnwrap(presentMenu(from: inner))
        defer { ThemedMenuPresenter.dismiss(session) }

        XCTAssertTrue(popover.isShown, "a menu closed the very popover it was opened from")
    }

    func testAlertEscapeEndsTheSheetAndReturnsFocus() throws {
        let window = testWindow()
        defer { settle(window) }
        let source = try XCTUnwrap(window.contentView?.subviews.first as? ThemedButton)
        XCTAssertTrue(window.makeFirstResponder(source))

        let alert = ThemedAlert()
        alert.messageText = "Leave this dialog?"
        alert.informativeText = "Escape is always a way out."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let dismissed = expectation(description: "sheet dismissed")
        alert.beginSheetModal(for: window) { response in
            XCTAssertEqual(response, .abort)
            dismissed.fulfill()
        }

        let panel = try XCTUnwrap(alert.presentedWindow)
        panel.cancelOperation(nil)
        wait(for: [dismissed], timeout: 1)

        XCTAssertNil(alert.presentedWindow)
        XCTAssertTrue(window.firstResponder === source)
    }

    /// `dismiss()` exists for a dialog that is *overtaken* — a software-update stage Sparkle
    /// moves past — so it must end the sheet through the ordinary completion path without a
    /// button having answered, and do nothing at all when nothing is presented.
    func testAlertDismissEndsTheSheetWithoutAButtonAnswer() throws {
        let window = testWindow()
        defer { settle(window) }

        let alert = ThemedAlert()
        alert.messageText = "Downloading Update…"
        alert.addButton(withTitle: "Cancel")

        let dismissed = expectation(description: "sheet dismissed")
        alert.beginSheetModal(for: window) { response in
            XCTAssertEqual(response, .abort)
            dismissed.fulfill()
        }
        XCTAssertNotNil(alert.presentedWindow)

        alert.dismiss()
        wait(for: [dismissed], timeout: 1)
        XCTAssertNil(alert.presentedWindow)

        // Nothing presented, nothing to do — not a crash, and not a second completion.
        alert.dismiss()
    }

    // MARK: - Semantics and themes

    func testAlertTreeExposesTheDialogCopyButtonsAndSuppressionChoice() throws {
        let alert = ThemedAlert()
        alert.messageText = "Remove project?"
        alert.informativeText = "The folder stays on disk."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let root = sized(alert.makeContentView())
        let tree = [root] + descendants(in: root)
        let buttons = tree.filter { $0.accessibilityRole() == .button }
        let checkboxes = tree.filter { $0.accessibilityRole() == .checkBox }

        XCTAssertEqual(root.accessibilityLabel(), "Remove project?")
        XCTAssertEqual(Set(buttons.compactMap { $0.accessibilityTitle() }), ["Remove", "Cancel"])
        XCTAssertEqual(checkboxes.first?.accessibilityTitle(), "Don't ask again")
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: root), [])
    }

    func testClassicRequesterMaterialDropsModernStatusIcon() throws {
        let previous = AppThemeLibrary.current
        defer {
            AppThemePalette.set(previous)
            NotificationCenter.default.post(AppThemeDidChange(themeID: previous.id))
        }

        AppThemePalette.set(AppThemeStyles.amiga)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.amiga.id))

        let alert = ThemedAlert()
        alert.messageText = "DiskCopy Request"
        alert.informativeText = "Insert the destination disk and select Continue."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        XCTAssertEqual(ThemedAlert.workbenchShortcutIndex(for: "V"), 0)
        XCTAssertEqual(ThemedAlert.workbenchShortcutIndex(for: "b"), 1)
        XCTAssertNil(ThemedAlert.workbenchShortcutIndex(for: "x"))

        let root = sized(alert.makeContentView())
        let imageViews = ([root] + descendants(in: root)).compactMap { $0 as? NSImageView }
        XCTAssertFalse(imageViews.isEmpty)
        XCTAssertTrue(
            imageViews.allSatisfy(\.isHidden),
            "Workbench requesters are text-led, not modern SF-symbol alerts"
        )
        XCTAssertNotNil(
            ([root] + descendants(in: root)).compactMap { $0 as? WindowChromeButton }
                .first(where: { $0.role == .depth }),
            "Workbench requesters carry the source title strip's depth gadget"
        )
        let buttons = themedButtons(in: root)
        XCTAssertEqual(buttons.map(\.title), ["Continue", "Cancel"])
        let leading = try XCTUnwrap(buttons.first)
        let trailing = try XCTUnwrap(buttons.last)
        let leadingFrame = leading.convert(leading.bounds, to: root)
        let trailingFrame = trailing.convert(trailing.bounds, to: root)
        XCTAssertLessThan(
            leadingFrame.midX,
            trailingFrame.midX,
            "Workbench requesters put Continue at the leading edge and Cancel at the trailing edge"
        )
        XCTAssertGreaterThan(
            trailingFrame.minX - leadingFrame.maxX,
            root.bounds.width * 0.25,
            "Workbench requester gadgets should bookend the bottom rail"
        )
        XCTAssertEqual(
            AppThemePalette.current.resolved(
                AppThemePalette.current.material(for: root.effectiveAppearance)
                    .popoverStyle.surfaceRole,
                appearance: root.effectiveAppearance
            ).hexString,
            "#AAAAAA",
            "Workbench requesters should use the stock application gray"
        )

        root.appearance = NSAppearance(named: .aqua)
        root.layoutSubtreeIfNeeded()
        try writeRender(of: rendered(root, scale: 2), named: "alert-requester-amiga-workbench-31")
    }

    /// IRIX's measured logout requester is the classic exception: its square frame keeps the
    /// period title/message grammar but carries a bright green question field beside the copy.
    func testIRIXRequesterRestoresTheMeasuredQuestionIcon() throws {
        let previous = AppThemeLibrary.current
        defer {
            AppThemePalette.set(previous)
            NotificationCenter.default.post(AppThemeDidChange(themeID: previous.id))
        }

        AppThemePalette.set(AppThemeStyles.irix)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.irix.id))

        let alert = ThemedAlert()
        alert.messageText = "Confirm"
        alert.informativeText = "Do you want to log out now?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")

        let root = sized(alert.makeContentView())
        let image = try XCTUnwrap(
            ([root] + descendants(in: root)).compactMap { $0 as? NSImageView }.first
        )
        XCTAssertFalse(image.isHidden, "IRIX requester lost its measured question field")
        XCTAssertEqual(image.image?.size, NSSize(width: 30, height: 30))

        root.appearance = NSAppearance(named: .aqua)
        root.layoutSubtreeIfNeeded()
        try writeRender(of: rendered(root, scale: 2), named: "alert-requester-irix-indigo-magic")
    }

    /// Prominence follows Return everywhere else, and must not here.
    ///
    /// `ConfirmationAlert.applyDefaultButton` deliberately moves Return to Cancel for an
    /// `.irreversible` prompt, so the accent fill went with it: the loudest thing in a delete
    /// dialog was the button that does not delete, and on a theme whose accent is its negative
    /// colour it was the reddest thing too. Filling the *action* instead was rejected — it makes
    /// the irreversible button the most clickable thing on a sheet meant to slow the user down —
    /// so a destructive confirmation fills neither.
    ///
    /// The frames were always the same size, filled or not — what differed was the *drawing*, and
    /// that is asserted where it happens, in
    /// `testTheFocusedDefaultOfAnAlertKeepsTheEdgeOfItsFill`. Kept here as the cheap guard that
    /// the row still lays out as one.
    func testADestructiveAlertFillsNeitherButtonAndSizesThemAlike() throws {
        let root = sized(destructiveAlert().makeContentView())
        let buttons = themedButtons(in: root)
        let delete = try XCTUnwrap(buttons.first { $0.title == "Delete" })
        let cancel = try XCTUnwrap(buttons.first { $0.title == "Cancel" })

        XCTAssertEqual(delete.emphasis, .secondary)
        XCTAssertEqual(cancel.emphasis, .secondary, "Cancel is wearing the accent fill")
        XCTAssertEqual(
            delete.frame.height,
            cancel.frame.height,
            "a filled button's focus ring is stroked inside its own silhouette, "
                + "so the prominent one read shorter than the bordered one beside it"
        )
        XCTAssertNotNil(delete.contentTintColor, "the destructive action says so in its title")
        XCTAssertNil(cancel.contentTintColor)
    }

    /// The other half of the rule: an ordinary confirmation — a grant, an OK — still fills the
    /// button Return activates, because there the default *is* the action.
    func testAnOrdinaryAlertStillFillsTheButtonReturnActivates() throws {
        let alert = ThemedAlert()
        alert.messageText = "Allow this tool?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")

        let buttons = themedButtons(in: sized(alert.makeContentView()))

        XCTAssertEqual(buttons.first { $0.title == "Allow" }?.emphasis, .primary)
        XCTAssertEqual(buttons.first { $0.title == "Cancel" }?.emphasis, .secondary)
    }

    /// A quit dialog, reported as "Cancel and Quit are different sizes".
    ///
    /// They were, and the focus ring was doing it. A prominent button's ring is stroked inside
    /// its silhouette in `Text.selected` — a near-ground tone, by definition — so on the edge of
    /// an accent *fill* it did not read as a ring around the button: it replaced the outermost
    /// 2pt of the fill on all four sides, and the pill came out 4pt shorter and 4pt narrower than
    /// the bordered Cancel beside it. Nothing in the picture said "focus"; it said "two sizes".
    ///
    /// Not a property of a theme, which is how it was found twice: the destructive-alert fix
    /// settled it for delete dialogs by filling neither button, and every ordinary confirmation
    /// still filled its default. So the rule is stated where the ring is drawn, and asserted here
    /// on the fill's own edge across a light theme, a dark one, and the system default.
    func testTheFocusedDefaultOfAnAlertKeepsTheEdgeOfItsFill() throws {
        let previous = AppThemeLibrary.current
        defer {
            AppThemePalette.set(previous)
            NotificationCenter.default.post(AppThemeDidChange(themeID: previous.id))
        }

        for theme in [AppTheme.system, AppThemeStyles.botanical, AppThemeStyles.cyberpunk] {
            AppThemePalette.set(theme)
            NotificationCenter.default.post(AppThemeDidChange(themeID: theme.id))

            let alert = ThemedAlert()
            alert.messageText = "Quit with one turn in flight?"
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")

            let root = sized(alert.makeContentView())
            root.appearance = NSAppearance(
                named: theme.mode == .dark ? .darkAqua : .aqua
            )
            let window = NSWindow(
                contentRect: root.bounds,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(root)

            let quit = try XCTUnwrap(themedButtons(in: root).first { $0.title == "Quit" })
            XCTAssertEqual(quit.emphasis, .primary, "\(theme.name): the default is not filled")

            // The same button before focus reaches it. Asserted against *itself* rather than
            // against a fill sampled from its middle: a theme whose primary is outlined rather
            // than filled draws a hairline at that edge by design, and comparing the edge to the
            // interior would call that border a defect. What must be true under every treatment
            // is that focus changes nothing at the silhouette's edge.
            root.layoutSubtreeIfNeeded()
            let resting = try rendered(root, scale: 2)

            XCTAssertTrue(window.makeFirstResponder(quit))
            root.layoutSubtreeIfNeeded()

            let rep = try rendered(root, scale: 2)
            try writeRender(of: rep, named: "alert-quit-\(theme.id.rawValue)")

            let frame = quit.convert(quit.bounds, to: root)
            let edges: [(String, NSPoint)] = [
                ("top", NSPoint(x: frame.midX, y: frame.maxY - 1)),
                ("bottom", NSPoint(x: frame.midX, y: frame.minY + 1)),
                ("leading", NSPoint(x: frame.minX + 1, y: frame.midY)),
                ("trailing", NSPoint(x: frame.maxX - 1, y: frame.midY))
            ]
            for (edge, point) in edges {
                XCTAssertLessThan(
                    contrast(
                        try pixel(of: rep, at: point, in: root),
                        try pixel(of: resting, at: point, in: root)
                    ),
                    0.06,
                    "\(theme.name): the focus ring ate the \(edge) edge of the default's fill, "
                        + "so it reads smaller than the Cancel beside it"
                )
            }

            // And the ring is still there to be seen, inside that band.
            let ringPoint = NSPoint(
                x: frame.midX,
                y: frame.maxY - Design.Accessibility.focusRingWidth * 1.5
            )
            XCTAssertGreaterThan(
                contrast(
                    try pixel(of: rep, at: ringPoint, in: root),
                    try pixel(of: resting, at: ringPoint, in: root)
                ),
                0.1,
                "\(theme.name): the focused default draws no ring at all"
            )
        }
    }

    /// The picture, under the theme that showed it. Swiss Minimalist sets `accent` and
    /// `statusNegative` to the same `#D6180B`, which is what collapsed "this is the action" and
    /// "this is destructive" into one signal wearing the wrong label.
    func testSwissMinimalistLeavesTheCancelOfADeleteDialogOnPaper() throws {
        let previous = AppThemeLibrary.current
        defer {
            AppThemePalette.set(previous)
            NotificationCenter.default.post(AppThemeDidChange(themeID: previous.id))
        }
        let swiss = AppThemeStyles.swissMinimalist
        AppThemePalette.set(swiss)
        NotificationCenter.default.post(AppThemeDidChange(themeID: swiss.id))

        let root = sized(destructiveAlert().makeContentView())
        root.appearance = NSAppearance(named: .aqua)
        root.layoutSubtreeIfNeeded()

        let rep = try rendered(root, scale: 2)
        try writeRender(of: rep, named: "alert-destructive-swiss")

        let cancel = try XCTUnwrap(themedButtons(in: root).first { $0.title == "Cancel" })
        let centre = cancel.convert(
            NSPoint(x: cancel.bounds.midX, y: cancel.bounds.midY),
            to: root
        )

        XCTAssertGreaterThan(
            contrast(try pixel(of: rep, at: centre, in: root), Design.Surface.accent),
            0.3,
            "Cancel is filled with the accent in a dialog whose action is Delete"
        )
    }

    func testPresentationChromeChangesLiveAcrossDistinctThemes() throws {
        let previous = AppThemeLibrary.current
        defer {
            AppThemePalette.set(previous)
            NotificationCenter.default.post(AppThemeDidChange(themeID: previous.id))
        }

        let alert = ThemedAlert()
        alert.messageText = "Presentation chrome"
        alert.informativeText = "The surface, type, controls, and status icon follow the app theme."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let root = sized(alert.makeContentView())
        root.appearance = NSAppearance(named: .darkAqua)

        let themes: [AppTheme] = [
            .system,
            AppThemeStyles.swissMinimalist,
            AppThemeStyles.cyberpunk
        ]
        var renders: [Data] = []
        for theme in themes {
            AppThemePalette.set(theme)
            NotificationCenter.default.post(AppThemeDidChange(themeID: theme.id))
            root.layoutSubtreeIfNeeded()
            renders.append(try renderedPNG(of: root))
        }

        XCTAssertEqual(Set(renders).count, themes.count, "presentation chrome ignored a live theme")
    }

    // MARK: - Helpers

    /// Brings the test host to the front, because key status does not exist until it is there.
    ///
    /// `NSApp.keyWindow` is `nil` for the whole of an inactive application, however many windows
    /// it has ordered front: `makeKeyAndOrderFront` records the intent, and the window server
    /// hands the keyboard over at activation. A suite launched from `scripts/test.sh` starts
    /// inactive — the terminal that started it is frontmost — so a key-status assertion there is
    /// reading the environment rather than the code, which is how this test came to fail on a
    /// popover that was working. It is in `all` and not `fast` for exactly this reason: taking
    /// the front is the interruption `fast` exists to avoid.
    ///
    /// Skipped rather than failed when activation does not come, so a session with no window
    /// server reports the truth — the behaviour was not observable — instead of accusing the
    /// popover.
    private func activateHost() throws {
        guard !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(2)
        while !NSApp.isActive, Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
        try XCTSkipUnless(
            NSApp.isActive,
            "the test host could not come to the front, so no window can hold key status"
        )
    }

    /// A **key** window, for the four tests that assert where focus lands — which is the one
    /// thing an unshown window cannot answer, and so the only reason to prefer this over
    /// `offscreenWindow()` below. Everything else in this file uses that one.
    ///
    /// **It has to be on a display, and that is why its tests are skipped from the fast plan.**
    /// A borderless or unconstrained window parked at (-10,000, -10,000) is the usual way to
    /// need a real window without showing one, and it is enough for rendering and for WebKit —
    /// but not for this. The window server does not hand the keyboard to a window that is on no
    /// screen: a titled fixture whose `constrainFrameRect(_:to:)` was overridden to keep it
    /// parked came up with `isKeyWindow` false, and every focus assertion under it failed while
    /// the popover was working correctly. Parking answers "is this drawn"; only a window
    /// somebody could look at answers "where do the keystrokes go".
    private func testWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 420, height: 260),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        let source = ThemedButton(title: "Source", target: nil, action: nil)
        source.frame = NSRect(x: 40, y: 80, width: 100, height: Design.Size.chipHeight)
        root.addSubview(source)
        window.contentView = root
        // Closing a window releases it — and AppKit's sheet machinery keeps its own
        // `_NSWindowTransformAnimation` pointing at that window for as long as the animation is
        // in flight. Released underneath one, the animation's `dealloc` lands on freed memory the
        // next time *anything* flushes a Core Animation transaction, which is whichever later
        // test happens to spin a run loop. It killed the host inside `ToastTests`, two suites
        // along, with a `SIGSEGV` in `-[_NSWindowTransformAnimation dealloc]` and nothing in the
        // log to connect it to the test that armed it. See `settle(_:)`.
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Takes a shown fixture window off screen and lets AppKit finish what it was animating on
    /// it, so nothing is left half-torn-down for the next test's run loop to trip over.
    ///
    /// Ordered out rather than closed: this window has to outlive its own animations, and
    /// `close()` is what hands it to them as freed memory.
    private func settle(_ window: NSWindow) {
        window.orderOut(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.animationSettleInterval))
    }

    /// Long enough for a sheet's transform animation to run out. AppKit's is a quarter second;
    /// this waits it out rather than guessing, because the cost of guessing short is a crash in
    /// another test file.
    private static let animationSettleInterval: TimeInterval = 0.35

    /// A window that is never ordered on screen and never explicitly closed: none of the
    /// popover-versus-dropdown behaviour needs to be visible, and synchronous close can race the
    /// presentation's private autoreleased state (see CLAUDE.md). The window is simply released
    /// with the test.
    private func offscreenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 420, height: 260),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        let source = ThemedButton(title: "Source", target: nil, action: nil)
        source.frame = NSRect(x: 40, y: 80, width: 100, height: Design.Size.chipHeight)
        root.addSubview(source)
        window.contentView = root
        return window
    }

    private func popoverContent() -> NSViewController {
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        content.preferredContentSize = content.view.frame.size
        return content
    }

    private func presentMenu(from source: NSView) -> AnyObject? {
        ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [.item(ThemedMenuItem(title: "New Chat…"))],
                minimumWidth: 0
            ),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, _ in },
            onDismiss: {}
        )
    }

    private func sized(_ view: NSView) -> NSView {
        view.layoutSubtreeIfNeeded()
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func themedButtons(in root: NSView) -> [ThemedButton] {
        ([root] + descendants(in: root)).compactMap { $0 as? ThemedButton }
    }

    /// The alert `ConfirmationAlert` builds for an `.irreversible` prompt: the action first, the
    /// way out second, `hasDestructiveAction` on the action and Return moved off it.
    private func destructiveAlert() -> ThemedAlert {
        let alert = ThemedAlert()
        alert.messageText = "Delete “our custom popover got stuck”?"
        alert.informativeText =
            "The agent will stop and the session is removed from Threading. The saved "
            + "conversation on disk is not deleted, so it could still be imported again later."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        return alert
    }

    private func renderedPNG(of view: NSView) throws -> Data {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// The view drawn at a magnification, so a one-point border is several pixels a sample
    /// can land inside rather than a blend it has to guess at.
    private func rendered(_ view: NSView, scale: Int) throws -> NSBitmapImageRep {
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
        ))
        rep.size = view.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        view.displayIgnoringOpacity(view.bounds, in: context)
        return rep
    }

    /// The rep's colour under a point given in the view's own (unflipped) coordinates.
    private func pixel(
        of rep: NSBitmapImageRep,
        at point: NSPoint,
        in view: NSView
    ) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let x = Int((point.x * scale).rounded(.down))
        let y = Int(((view.bounds.height - point.y) * scale).rounded(.down))
        return try XCTUnwrap(rep.colorAt(
            x: min(max(x, 0), rep.pixelsWide - 1),
            y: min(max(y, 0), rep.pixelsHigh - 1)
        ))
    }

    /// The largest per-channel difference — enough to say "this pixel is not that surface".
    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard let a = a.usingColorSpace(.deviceRGB),
              let b = b.usingColorSpace(.deviceRGB) else { return 0 }
        return max(
            abs(a.redComponent - b.redComponent),
            abs(a.greenComponent - b.greenComponent),
            abs(a.blueComponent - b.blueComponent),
            abs(a.alphaComponent - b.alphaComponent)
        )
    }

    private func along(_ from: NSPoint, _ to: NSPoint, _ t: CGFloat) -> NSPoint {
        NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }

    /// Saves the render where the other render tests put theirs, for appearance review.
    ///
    /// Falls back the way `ThemedCheckboxTests` does rather than returning empty-handed:
    /// `scripts/test.sh` forwards no environment to the test host, so keying this on
    /// `THREADING_RENDER_OUT` alone meant the pictures were written by nothing but an Xcode run
    /// somebody had configured by hand.
    private func writeRender(of rep: NSBitmapImageRep, named name: String) throws {
        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            ?? NSTemporaryDirectory() + "ThreadingRenders"
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url.appendingPathComponent("\(name).png"))
    }
}
