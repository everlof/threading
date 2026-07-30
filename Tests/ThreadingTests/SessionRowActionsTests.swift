import AppKit
import XCTest
@testable import Threading

/// The row's trailing slot holds the status indicator and the `⋯` actions button *overlaid*,
/// crossfaded on hover. Two views in one 16pt square means the question "which one takes the
/// click" has an answer nothing on screen shows — and a spinner is exactly when a user reaches
/// for the menu, because a working session is the one they want to act on.
@MainActor
final class SessionRowActionsTests: XCTestCase {

    // MARK: - Helpers

    /// A row in a window, since hit testing needs a view tree with real frames.
    ///
    /// The window is built and never ordered on screen: `applicationShouldTerminateAfterLastWindowClosed`
    /// is true, so a shown-then-released window queues a termination AppKit acts on the next
    /// time anything spins the run loop — inside some later, unrelated test.
    private func hostedRow() -> (host: NSView, row: SessionRowView) {
        let row = SessionRowView(customizationLookup: { _ in .empty })
        row.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        return (host, row)
    }

    private func enter(_ row: SessionRowView) {
        let event = NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: row.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )
        row.mouseEntered(with: XCTUnwrap2(event))
    }

    private func leave(_ row: SessionRowView) {
        let event = NSEvent.enterExitEvent(
            with: .mouseExited,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: row.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )
        row.mouseExited(with: XCTUnwrap2(event))
    }

    private func XCTUnwrap2(_ event: NSEvent?) -> NSEvent {
        // A synthesized enter/exit event cannot fail to build here; force it rather than make
        // every caller throwing for a value AppKit always returns.
        guard let event else { preconditionFailure("could not synthesize an enter/exit event") }
        return event
    }

    private func view(named identifier: String, in root: NSView) throws -> NSView {
        func walk(_ node: NSView) -> NSView? {
            if node.accessibilityIdentifier() == identifier { return node }
            for child in node.subviews {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return try XCTUnwrap(walk(root), "no view identified as \(identifier)")
    }

    private func session(_ title: String = "Working session") -> AgentSession {
        AgentSession(kind: .claude, title: title)
    }

    /// A click on `view`, as the two halves AppKit delivers them.
    private func clickEvents(on view: NSView) throws -> (down: NSEvent, up: NSEvent) {
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type,
                    location: centre,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: view.window?.windowNumber ?? 0,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
        }
        return (try event(.leftMouseDown), try event(.leftMouseUp))
    }

    // MARK: - Tests

    /// The report that produced this test: the `⋯` could not be clicked on the selected chat,
    /// which was also the one showing a spinner.
    func testTheActionsButtonTakesTheClickWhileTheRowIsWorking() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .working)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        let button = try view(named: "sidebar.session.actions", in: row)
        let centre = host.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)

        let hit = try XCTUnwrap(host.hitTest(centre), "nothing at all answered in the trailing slot")
        XCTAssertTrue(
            hit === button || hit.isDescendant(of: button),
            "the trailing slot's click went to \(type(of: hit)) rather than the actions button"
        )
    }

    /// The same square while the row is *loading*, which is the state the stuck spinner left
    /// every selected row in: the status indicator is opaque and animating underneath.
    func testTheActionsButtonTakesTheClickWhileTheRowIsLoading() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .idle, isLoading: true)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        let button = try view(named: "sidebar.session.actions", in: row)
        let centre = host.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)

        let hit = try XCTUnwrap(host.hitTest(centre))
        XCTAssertTrue(
            hit === button || hit.isDescendant(of: button),
            "a loading row's spinner takes the click meant for its menu (\(type(of: hit)))"
        )
    }

    /// Reconfiguring must not drop the hover: rows are reconfigured continuously while an agent
    /// works, and a `⋯` that vanished under a resting pointer is indistinguishable from one
    /// that cannot be clicked.
    func testReconfiguringUnderThePointerKeepsTheActionsButtonVisible() throws {
        let (host, row) = hostedRow()
        let session = session()
        row.configure(with: session, activity: .idle)
        enter(row)
        defer { leave(row) }

        row.configure(with: session, activity: .working)
        row.configure(with: session, activity: .working, isLoading: true)
        host.layoutSubtreeIfNeeded()

        // The fade lives on the container holding both buttons, so that is what carries the
        // answer — asserting on the `⋯` alone would pass whatever the row did.
        let controls = try view(named: "sidebar.session.hover-controls", in: row)
        XCTAssertEqual(controls.alphaValue, 1, "the hover controls faded out under a resting pointer")
    }

    /// The second report about this button: it opened "one press in three or four".
    ///
    /// Hit testing was not the fault this time — the press lands, and it is the *release* that
    /// goes missing. AppKit routes a mouse-up to the view that took the mouse-down, and to no
    /// other: a row rebuilt in between (`reloadData` hands every cell back to the reuse pool,
    /// which the sidebar does whenever the tree's shape changes) leaves that view detached, and
    /// the detached view is sent nothing while the view that replaced it is sent nothing either.
    /// Measured against AppKit directly: down, remove the view, up — one `mouseDown`, no
    /// `mouseUp`, anywhere.
    ///
    /// So the menu opens on the press, like every other menu on the platform and like
    /// `ChipView` and `ThemedPopUp` here. There is then no release to lose.
    func testTheActionsButtonOpensItsMenuOnThePressRatherThanTheRelease() throws {
        let (host, row) = hostedRow()
        let session = session()
        row.configure(with: session, activity: .working)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        var opened: [SessionID] = []
        row.onAction = { sessionID, _ in opened.append(sessionID) }

        let button = try view(named: "sidebar.session.actions", in: row)
        let click = try clickEvents(on: button)

        button.mouseDown(with: click.down)
        XCTAssertEqual(
            opened,
            [session.id],
            "the ⋯ waited for a release AppKit does not promise to deliver here"
        )

        // The release is the menu's, not the button's: acting on it too would open a second menu
        // behind the first.
        button.mouseUp(with: click.up)
        XCTAssertEqual(opened, [session.id], "the release opened the menu a second time")
    }

    /// The button has to answer to the accessibility press as well as to the pointer — it is
    /// how the row is reached without a mouse, and how a UI test drives it.
    func testTheActionsButtonReportsItselfAsAPressableButton() throws {
        let (_, row) = hostedRow()
        row.configure(with: session(), activity: .idle)

        let button = try view(named: "sidebar.session.actions", in: row)
        XCTAssertTrue(button.isAccessibilityElement())
        XCTAssertEqual(button.accessibilityRole(), .button)
    }

    // MARK: - Shared Session Menu

    /// The pane-header menu calls this exact builder too, so this is the contract both
    /// entrances expose rather than a row-only inventory. The occasional items live in the
    /// Session Options fold now, so that is where they are held to being.
    func testSharedSessionMenuIncludesAttachmentsAndBothInterfaces() throws {
        let sidebar = ProjectSidebarViewController()
        let menu = NSMenu()
        sidebar.populateSessionActions(
            menu,
            for: AgentSession(kind: .claude, title: "Terminal", usesNativeUI: false)
        )
        let options = try sessionOptions(in: menu)

        XCTAssertNotNil(
            options.items.first { $0.title == SessionActionMenuDefaults.attachmentsTitle }
        )

        // Nothing has muted this session or its project, so the item offers the change rather
        // than describing the state — an Unmute on something already audible would read as
        // the opposite of what is true.
        XCTAssertNotNil(
            options.items.first { $0.title == L10n.string("Mute Notifications") },
            "the session menu lost its mute item"
        )

        let interface = try XCTUnwrap(options.items.first { $0.title == "Interface" }?.submenu)
        XCTAssertEqual(
            interface.items.map(\.title),
            [SessionSurfaceTogglePresentation.nativeTitle, AgentKind.claude.originalUITitle]
        )
        XCTAssertEqual(interface.items.map(\.state), [.off, .on])

        let nativeMenu = NSMenu()
        sidebar.populateSessionActions(
            nativeMenu,
            for: AgentSession(kind: .claude, title: "Native", usesNativeUI: true)
        )
        let nativeInterface = try XCTUnwrap(
            try sessionOptions(in: nativeMenu).items.first { $0.title == "Interface" }?.submenu
        )
        XCTAssertEqual(nativeInterface.items.map(\.state), [.on, .off])
    }

    /// The menu reads in groups — it had grown to seventeen top-level items with a twelve-item
    /// unbroken middle — and the fold takes what is set once and left alone. Theme and
    /// Permission Mode stay top-level because they are reached for repeatedly; the fold's own
    /// order is stated because it is a decision, not an accident of call order.
    func testTheSessionMenuFoldsTheSetOnceItemsAndKeepsItsGroupsApart() throws {
        let sidebar = ProjectSidebarViewController()
        let menu = NSMenu()
        sidebar.populateSessionActions(
            menu,
            for: AgentSession(kind: .claude, title: "Terminal", usesNativeUI: false)
        )

        let options = try sessionOptions(in: menu)
        XCTAssertEqual(
            options.items.map(\.title),
            [
                "Interface",
                "Claude Remote Control",
                L10n.string("Mute Notifications"),
                SessionActionMenuDefaults.attachmentsTitle
            ]
        )

        // Every actionable item in the fold carries its own target: the builder's retarget
        // loop walks only the top level, and an untargeted submenu item draws, disables or —
        // worse — silently does nothing.
        for item in options.items where item.action != nil {
            XCTAssertNotNil(item.target, "\(item.title) has no target inside the fold")
        }

        XCTAssertNotNil(menu.items.first { $0.title == L10n.string("Theme") })
        XCTAssertNotNil(menu.items.first { $0.title == L10n.string("Permission Mode") })

        // Most of the middle groups are conditional, so an absent group must fold its
        // separator away rather than leaving two in a row.
        for (index, item) in menu.items.enumerated() where item.isSeparatorItem {
            XCTAssertTrue(
                index > 0 && !menu.items[index - 1].isSeparatorItem,
                "an empty group left its separator behind at index \(index)"
            )
        }
    }

    private func sessionOptions(in menu: NSMenu) throws -> NSMenu {
        try XCTUnwrap(
            menu.items.first { $0.title == SessionActionMenuDefaults.sessionOptionsTitle }?
                .submenu,
            "the session menu has no Session Options fold"
        )
    }

    /// The dedicated header button is a transition, not a mode badge: it always names and
    /// depicts the other surface, including the provider-specific terminal title.
    func testSurfaceTogglePresentationPointsAtTheOtherSurface() {
        let terminal = SessionSurfaceTogglePresentation(
            session: AgentSession(kind: .claude, title: "Terminal")
        )
        XCTAssertTrue(terminal.targetUsesNativeUI)
        XCTAssertEqual(terminal.title, SessionSurfaceTogglePresentation.nativeTitle)
        XCTAssertEqual(terminal.symbolName, SessionSurfaceTogglePresentation.nativeSymbol)

        let nativeClaude = SessionSurfaceTogglePresentation(
            session: AgentSession(
                kind: .claude,
                title: "Native Claude",
                usesNativeUI: true
            )
        )
        XCTAssertFalse(nativeClaude.targetUsesNativeUI)
        XCTAssertEqual(nativeClaude.title, AgentKind.claude.originalUITitle)
        XCTAssertEqual(nativeClaude.symbolName, SessionSurfaceTogglePresentation.originalSymbol)

        let nativeCodex = SessionSurfaceTogglePresentation(
            session: AgentSession(kind: .codex, title: "Native Codex", usesNativeUI: true)
        )
        XCTAssertEqual(nativeCodex.title, AgentKind.codex.originalUITitle)
    }

    // MARK: - Archive

    /// The archive button holds the row's trailing edge, so it — not the `⋯` — is what a click
    /// at the outer edge of the slot reaches.
    func testTheArchiveButtonTakesTheClickAtTheRowsTrailingEdge() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .working)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        let archive = try view(named: "sidebar.session.archive", in: row)
        let centre = host.convert(NSPoint(x: archive.bounds.midX, y: archive.bounds.midY), from: archive)

        let hit = try XCTUnwrap(host.hitTest(centre), "nothing answered at the archive button")
        XCTAssertTrue(
            hit === archive || hit.isDescendant(of: archive),
            "the archive button's click went to \(type(of: hit)) instead"
        )
    }

    /// Both buttons must lie *inside* the trailing slot. One pinned to the slot's edge and left
    /// to overhang draws perfectly and cannot be clicked, because `NSView.hitTest` stops at the
    /// container's bounds — the failure this layout exists to avoid.
    func testBothHoverButtonsLieInsideTheTrailingSlot() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .idle)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        let slot = try view(named: "sidebar.session.trailing", in: row)
        for identifier in ["sidebar.session.actions", "sidebar.session.archive"] {
            let button = try view(named: identifier, in: row)
            let frame = slot.convert(button.bounds, from: button)
            XCTAssertTrue(
                slot.bounds.contains(frame),
                "\(identifier) at \(frame) escapes the slot's \(slot.bounds) and cannot be clicked"
            )
        }
    }

    /// The archive button is the *outer* of the pair. Stated as an assertion because the order
    /// is the request, not an accident of how the stack was built.
    func testTheArchiveButtonSitsOutboardOfTheActionsButton() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .idle)
        host.layoutSubtreeIfNeeded()

        let actions = try view(named: "sidebar.session.actions", in: row)
        let archive = try view(named: "sidebar.session.archive", in: row)
        let actionsFrame = row.convert(actions.bounds, from: actions)
        let archiveFrame = row.convert(archive.bounds, from: archive)

        XCTAssertGreaterThan(
            archiveFrame.minX,
            actionsFrame.minX,
            "the archive button should sit outboard of the ⋯, at the row's trailing edge"
        )
    }

    /// The dot must not move when the slot widens to carry a second button: it is shown on every
    /// row at rest, and the pair is shown on one row under the pointer.
    func testTheStatusDotKeepsTheRowsTrailingEdge() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .working)
        host.layoutSubtreeIfNeeded()

        let status = try view(named: "sidebar.session.status", in: row)
        let archive = try view(named: "sidebar.session.archive", in: row)
        let statusCentre = row.convert(NSPoint(x: status.bounds.midX, y: status.bounds.midY), from: status)
        let archiveCentre = row.convert(NSPoint(x: archive.bounds.midX, y: archive.bounds.midY), from: archive)

        XCTAssertEqual(
            statusCentre.x,
            archiveCentre.x,
            accuracy: 0.5,
            "the status dot left the row's trailing edge when the slot widened"
        )
    }

    /// Pressing it reports the row's session, which is what the sidebar archives.
    func testPressingArchiveReportsTheRowsSession() throws {
        let (host, row) = hostedRow()
        let session = session()
        row.configure(with: session, activity: .idle)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        var archived: [SessionID] = []
        row.onArchive = { archived.append($0) }

        let archive = try view(named: "sidebar.session.archive", in: row)
        XCTAssertTrue(archive.accessibilityPerformPress())

        XCTAssertEqual(archived, [session.id])
    }

    /// The `⋯`'s bug, one button over.
    ///
    /// Archive cannot answer it the way the `⋯` did — a menu belongs on the press, an action
    /// belongs on the release — so `ThemedIconButton` reads the release from the event stream
    /// rather than waiting for AppKit to route it back to a view the reuse pool has already
    /// taken. The row asserts it here because this is the button the report was about.
    func testArchiveSurvivesTheRowBeingRebuiltBetweenThePressAndTheRelease() throws {
        let (host, row) = hostedRow()
        let session = session()
        row.configure(with: session, activity: .idle)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        var archived: [SessionID] = []
        row.onArchive = { archived.append($0) }

        let archive = try view(named: "sidebar.session.archive", in: row)
        let click = try clickEvents(on: archive)

        archive.mouseDown(with: click.down)
        // `reloadData()` hands the row back to the pool, detaching the button mid-gesture.
        row.removeFromSuperview()
        NSApp.sendEvent(click.up)

        XCTAssertEqual(
            archived,
            [session.id],
            "archive waited for a release AppKit does not promise to deliver here"
        )
    }

    /// And it archives the session it was *aimed* at, not whichever one the row became.
    ///
    /// The other half of completing a press that outlives its row: the recycled view is re-pointed
    /// at a different session, so an action that reads the row's current id when it finally fires
    /// would archive one the user never pointed at. That would turn a lost click into a destructive
    /// one — strictly worse than the bug being fixed — so the press carries the session it named.
    func testAPressStartedOnOneSessionNeverArchivesTheRowsNextOne() throws {
        let (host, row) = hostedRow()
        let first = session("First")
        let second = session("Second")
        row.configure(with: first, activity: .idle)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        var archived: [SessionID] = []
        row.onArchive = { archived.append($0) }

        let archive = try view(named: "sidebar.session.archive", in: row)
        let click = try clickEvents(on: archive)

        archive.mouseDown(with: click.down)
        // The sidebar rebuilds and this very view comes back serving another session.
        row.configure(with: second, activity: .idle)
        archive.mouseUp(with: click.up)

        XCTAssertEqual(
            archived,
            [first.id],
            "the press archived the session the row was recycled into"
        )
    }

    /// It is revealed by the pointer and hidden at rest, exactly as the `⋯` is: a list of rows
    /// each showing an archive button is a list inviting an accident.
    func testTheArchiveButtonIsHiddenUntilTheRowIsHovered() throws {
        let (host, row) = hostedRow()
        let session = session()
        row.configure(with: session, activity: .idle)
        host.layoutSubtreeIfNeeded()

        let controls = try view(named: "sidebar.session.hover-controls", in: row)
        XCTAssertEqual(controls.alphaValue, 0, "the archive button was showing on a row at rest")

        // Read through `configure`, which reasserts the hover state without animating. Reading
        // straight after enter/exit would race the crossfade rather than test it.
        enter(row)
        row.configure(with: session, activity: .idle)
        XCTAssertEqual(controls.alphaValue, 1, "the archive button stayed hidden under the pointer")

        leave(row)
        row.configure(with: session, activity: .idle)
        XCTAssertEqual(controls.alphaValue, 0, "the archive button outstayed the pointer")
    }

    /// Reachable and labelled without a mouse.
    func testTheArchiveButtonReportsItselfAsAPressableButton() throws {
        let (_, row) = hostedRow()
        row.configure(with: session(), activity: .idle)

        let archive = try view(named: "sidebar.session.archive", in: row)
        XCTAssertTrue(archive.isAccessibilityElement())
        XCTAssertEqual(archive.accessibilityRole(), .button)
        XCTAssertEqual(
            archive.accessibilityTitle(),
            SidebarRowDefaults.archiveAccessibilityLabel
        )
    }
}
