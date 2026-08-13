import AppKit
import ThreadingExtensionKit
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

    private func optionalView(named identifier: String, in root: NSView) -> NSView? {
        func walk(_ node: NSView) -> NSView? {
            if node.accessibilityIdentifier() == identifier { return node }
            for child in node.subviews {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(root)
    }

    private func optionalView<View: NSView>(ofType type: View.Type, in root: NSView) -> View? {
        if let match = root as? View { return match }
        for child in root.subviews {
            if let match = optionalView(ofType: type, in: child) { return match }
        }
        return nil
    }

    private func view(named identifier: String, in root: NSView) throws -> NSView {
        try XCTUnwrap(
            optionalView(named: identifier, in: root),
            "no view identified as \(identifier)"
        )
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

    /// A row's hover card may read account directories and git context. Mounting the visible
    /// rows at launch must not perform that work for cards the pointer never asks to see.
    func testHoverInfoDiscoveryIsDeferredUntilTheCardIsRequested() {
        var infoBuildCount = 0
        let row = SessionRowView(
            customizationLookup: { _ in .empty },
            sessionHoverContentProvider: { _ in NSViewController() },
            sessionHoverInfoProvider: { session, activity in
                infoBuildCount += 1
                return SessionInfoPopoverViewController.Info(
                    session: session,
                    activity: activity
                )
            }
        )
        let session = session("Deferred hover details")

        row.configure(with: session, activity: .idle)

        XCTAssertEqual(infoBuildCount, 0)
        XCTAssertNotNil(row.makeSessionHoverCard(session: session, activity: .idle))
        XCTAssertEqual(infoBuildCount, 1)
    }

    /// The app starts before extension processes publish their component patches. Empty
    /// lookups must not create two rendering hosts and two notification observers per visible
    /// row; the sidebar's collection observer wakes the row when a real patch arrives.
    func testCustomizationHostsAreDeferredUntilPublishedContentExists() throws {
        var resolutions: [ExtensionComponentTarget: ComponentCustomizationResolution] = [:]
        let row = SessionRowView(
            customizationLookup: { resolutions[$0] ?? .empty },
            defersCustomizationUntilNeeded: true
        )
        let session = session("Deferred customization")

        row.configure(with: session, activity: .idle)
        XCTAssertFalse(row.customizationHostsAreMaterialized)
        XCTAssertFalse(row.customizationScaffoldingIsMaterialized)
        XCTAssertNil(optionalView(named: "sidebar.session.identity.content", in: row))
        XCTAssertNil(optionalView(named: "sidebar.session.content", in: row))
        XCTAssertNil(optionalView(named: "sidebar.session.slot.after-title", in: row))
        XCTAssertNil(optionalView(named: "sidebar.session.attention-overlay", in: row))

        let target = ExtensionComponentTarget(
            component: HostComponentContracts.sidebarSessionRow.id,
            contractVersion: HostComponentContracts.sidebarSessionRow.version,
            entityID: session.id.uuidString.lowercased()
        )
        resolutions[target] = ComponentCustomizationResolution(
            properties: [.title: .text("Published title")],
            slots: [:],
            replacement: nil,
            replacementExtensionIdentifier: nil,
            replacementCandidates: [],
            hooks: []
        )

        row.refreshCustomizations(changedTargets: [target])

        XCTAssertTrue(row.customizationHostsAreMaterialized)
        XCTAssertTrue(row.customizationScaffoldingIsMaterialized)
        XCTAssertNotNil(optionalView(named: "sidebar.session.content", in: row))
        XCTAssertNotNil(optionalView(named: "sidebar.session.slot.after-title", in: row))
        let title = try XCTUnwrap(
            optionalView(named: "sidebar.session.title", in: row) as? MorphingTitleLabel
        )
        XCTAssertEqual(title.stringValue, "Published title")
    }

    /// Deferring the hosts must not defer the row's *native* content: the title lands only
    /// through the customization pipeline, so a row with nothing published applies it with
    /// no overrides. Shipped as every sidebar session losing its name on the next launch.
    func testDeferredRowStillShowsItsNativeTitle() throws {
        let row = SessionRowView(
            customizationLookup: { _ in .empty },
            defersCustomizationUntilNeeded: true
        )
        let session = session("Native title")

        row.configure(with: session, activity: .idle)

        XCTAssertFalse(row.customizationHostsAreMaterialized)
        let title = try XCTUnwrap(
            optionalView(named: "sidebar.session.title", in: row) as? MorphingTitleLabel
        )
        XCTAssertEqual(title.stringValue, session.displayTitle)
    }

    /// A standard login has no account chip. Resolving it during first paint used to scan the
    /// account directories and parse shell aliases even though the result could not be shown.
    func testStandardAccountSkipsDiscoveryButAnAlternateAccountStillResolvesItsChip() {
        var resolvedHandles: [AccountHandle] = []
        let row = SessionRowView(
            customizationLookup: { _ in .empty },
            sessionAccountProvider: { provider, handle in
                resolvedHandles.append(handle)
                return AgentAccount(
                    provider: provider,
                    handle: handle,
                    configPath: "/tmp/\(handle.name)"
                )
            }
        )

        row.configure(with: session("Standard"), activity: .idle)
        XCTAssertEqual(resolvedHandles, [])
        XCTAssertNil(
            optionalView(named: "sidebar.session.account", in: row),
            "a standard row built an account-badge subtree it can never show"
        )

        row.configure(
            with: AgentSession(
                kind: .claude,
                title: "Alternate",
                accountHandle: .named("work")
            ),
            activity: .idle
        )
        XCTAssertEqual(resolvedHandles, [.named("work")])
        XCTAssertNotNil(
            optionalView(named: "sidebar.session.account", in: row),
            "the alternate account did not cross the badge boundary"
        )
    }

    /// The controls remain in the hierarchy for pointerless access, while their hidden glyphs
    /// stay out of first sidebar paint and materialize together on the first real hover.
    func testHoverControlGlyphsAreDeferredUntilTheRowRevealsThem() throws {
        let (_, row) = hostedRow()
        row.configure(with: session(), activity: .idle)

        let actions = try XCTUnwrap(
            try view(named: "sidebar.session.actions", in: row) as? ThemedIconButton
        )
        let archive = try XCTUnwrap(
            try view(named: "sidebar.session.archive", in: row) as? ThemedIconButton
        )
        XCTAssertFalse(actions.hasMaterializedGlyph)
        XCTAssertFalse(archive.hasMaterializedGlyph)
        XCTAssertEqual(actions.accessibilityRole(), .button)
        XCTAssertEqual(archive.accessibilityRole(), .button)

        enter(row)
        defer { leave(row) }

        XCTAssertTrue(actions.hasMaterializedGlyph)
        XCTAssertTrue(archive.hasMaterializedGlyph)
    }

    /// Pinning already changes where the row sorts, but position alone is not a visible state:
    /// under Name or Recent Activity the same session may have led the list anyway. The row
    /// therefore carries an explicit mark, and reuse must remove it when the cell is handed to
    /// an ordinary session.
    func testPinnedSessionsCarryAnAccessibleMarkThatClearsOnReuse() throws {
        let (_, row) = hostedRow()
        row.configure(with: session("Ordinary session"), activity: .idle)
        XCTAssertNil(
            optionalView(named: "sidebar.session.pinned", in: row),
            "an unpinned row resolved and installed an absent pin mark"
        )

        var pinned = session("Pinned session")
        pinned.isPinned = true
        row.configure(with: pinned, activity: .idle)

        let indicator = try view(named: "sidebar.session.pinned", in: row)
        XCTAssertFalse(indicator.isHidden)
        XCTAssertTrue(indicator.isAccessibilityElement())
        XCTAssertEqual(indicator.accessibilityRole(), .image)
        XCTAssertEqual(
            indicator.accessibilityLabel(),
            SidebarRowDefaults.pinnedAccessibilityLabel
        )

        row.configure(with: session("Ordinary session"), activity: .idle)
        XCTAssertTrue(indicator.isHidden, "a recycled row kept the previous session's pin")
    }

    /// Idle is the overwhelmingly common stored-session state at launch. Its trailing geometry
    /// remains stable for hover actions, but the attention dot, limit mark and their constraints
    /// have no pixels to contribute until a real status arrives.
    func testIdleRowsMaterializeStatusContentOnlyAfterAVisibleState() {
        let (_, row) = hostedRow()
        let session = session("Deferred status")

        row.configure(with: session, activity: .idle)
        XCTAssertNotNil(optionalView(named: "sidebar.session.status", in: row))
        XCTAssertNil(
            optionalView(ofType: SessionStatusIndicator.self, in: row),
            "an idle row built the invisible status subtree"
        )

        row.configure(with: session, activity: .working)
        let materialized = optionalView(ofType: SessionStatusIndicator.self, in: row)
        XCTAssertNotNil(materialized, "a working row did not cross the status boundary")

        row.configure(with: session, activity: .idle)
        XCTAssertTrue(
            optionalView(ofType: SessionStatusIndicator.self, in: row) === materialized,
            "reuse discarded status content instead of keeping its now-warm subtree"
        )
    }

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
        let entries = sidebar.sessionActionEntries(
            for: AgentSession(kind: .claude, title: "Terminal", usesNativeUI: false)
        )
        let options = try sessionOptions(in: entries)

        XCTAssertNotNil(
            options.first { $0.item?.title == SessionActionMenuDefaults.attachmentsTitle }
        )

        // Nothing has muted this session or its project, so the item offers the change rather
        // than describing the state — an Unmute on something already audible would read as
        // the opposite of what is true.
        XCTAssertNotNil(
            options.first { $0.item?.title == L10n.string("Mute Notifications") },
            "the session menu lost its mute item"
        )

        let interface = try XCTUnwrap(
            options.compactMap(\.item).first { $0.title == "Interface" }?.submenu
        )
        XCTAssertEqual(
            interface.compactMap { $0.item?.title },
            [SessionSurfaceTogglePresentation.nativeTitle, AgentKind.claude.originalUITitle]
        )
        XCTAssertEqual(interface.compactMap { $0.item?.isSelected }, [false, true])

        let nativeEntries = sidebar.sessionActionEntries(
            for: AgentSession(kind: .claude, title: "Native", usesNativeUI: true)
        )
        let nativeInterface = try XCTUnwrap(
            try sessionOptions(in: nativeEntries)
                .compactMap(\.item).first { $0.title == "Interface" }?.submenu
        )
        XCTAssertEqual(nativeInterface.compactMap { $0.item?.isSelected }, [true, false])
    }

    /// The menu reads in groups — it had grown to seventeen top-level items with a twelve-item
    /// unbroken middle — and the fold takes what is set once and left alone. Theme and
    /// Permission Mode stay top-level because they are reached for repeatedly; the fold's own
    /// order is stated because it is a decision, not an accident of call order.
    func testTheSessionMenuFoldsTheSetOnceItemsAndKeepsItsGroupsApart() throws {
        let sidebar = ProjectSidebarViewController()
        let entries = sidebar.sessionActionEntries(
            for: AgentSession(kind: .claude, title: "Terminal", usesNativeUI: false)
        )

        let options = try sessionOptions(in: entries)
        XCTAssertEqual(
            options.compactMap { $0.item?.title },
            [
                "Interface",
                "Claude Remote Control",
                L10n.string("Mute Notifications"),
                // Beside Mute rather than beside Theme: both are conduct — what this chat does
                // when nobody is watching — while Theme and Sound are presentation.
                SessionActionMenuDefaults.limitRecoveryTitle,
                SessionActionMenuDefaults.attachmentsTitle
            ]
        )

        // Every row in the fold must be able to answer a choice: an action of its own, or a
        // submenu to open — a row with neither draws, highlights and silently does nothing.
        for item in options.compactMap(\.item) {
            XCTAssertTrue(
                item.onChoose != nil || item.submenu != nil,
                "\(item.title) answers nothing inside the fold"
            )
        }

        let titles = entries.compactMap { $0.item?.title }
        XCTAssertTrue(titles.contains(L10n.string("Theme")))
        XCTAssertTrue(titles.contains(L10n.string("Permission Mode")))

        // Most of the middle groups are conditional, so an absent group must fold its
        // separator away rather than leaving two in a row.
        for (index, entry) in entries.enumerated() where !entry.isItem {
            XCTAssertTrue(
                index > 0 && entries[index - 1].isItem,
                "an empty group left its separator behind at index \(index)"
            )
        }
    }

    /// The Copy fold carries two identifiers under two names, never one under a fallback. The
    /// agent's id names the conversation to the CLI, Threading's names it to the app, and the
    /// retired single item copied whichever existed — so the string on the pasteboard meant
    /// different things on different rows, invisibly. The agent's item is absent rather than
    /// disabled until the agent has named the conversation: there is nothing true to copy
    /// under that title yet.
    func testTheCopyFoldOffersBothIdentifiersOnceTheAgentHasNamedTheConversation() throws {
        let sidebar = ProjectSidebarViewController()

        var named = AgentSession(kind: .codex, title: "Named")
        named.resumeState = .resumable(TranscriptID("019852cf-codex-rollout"))
        let fold = try copySubmenu(in: sidebar.sessionActionEntries(for: named))
        XCTAssertEqual(
            Array(fold.compactMap { $0.item?.title }.prefix(2)),
            [L10n.string("Agent Session ID"), L10n.string("Threading ID")],
            "the identifier pair separated or lost its order"
        )

        let fresh = AgentSession(kind: .codex, title: "Fresh")
        XCTAssertEqual(fresh.resumeState, .awaitingIdentifier)
        let freshFold = try copySubmenu(in: sidebar.sessionActionEntries(for: fresh))
        XCTAssertFalse(
            freshFold.compactMap { $0.item?.title }
                .contains(L10n.string("Agent Session ID")),
            "an id the agent has not issued was offered for copying"
        )
        XCTAssertEqual(
            freshFold.first?.item?.title,
            L10n.string("Threading ID"),
            "Threading's own id exists from birth and its row must too"
        )
    }

    /// The fold's full complement, stated as a decision: ids first (the agent's, then
    /// Threading's), then the checkout, then the transcript — and every row answers a choice,
    /// because a fold member with nothing to do draws, highlights and silently does nothing.
    func testTheCopyFoldCarriesThePathsWhenTheyResolve() throws {
        var session = AgentSession(kind: .codex, title: "Named")
        session.resumeState = .resumable(TranscriptID("019852cf-codex-rollout"))

        let entry = ProjectSidebarViewController().sessionCopyEntry(
            for: session,
            project: Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p")),
            transcriptURL: URL(fileURLWithPath: "/tmp/rollout.jsonl")
        )
        let fold = try XCTUnwrap(entry.item?.submenu)
        XCTAssertEqual(
            fold.compactMap { $0.item?.title },
            [
                L10n.string("Agent Session ID"),
                L10n.string("Threading ID"),
                L10n.string("Worktree Path"),
                L10n.string("Transcript Path")
            ]
        )
        for item in fold.compactMap(\.item) {
            XCTAssertNotNil(item.onChoose, "\(item.title) answers nothing inside the fold")
        }
    }

    /// A terminal carries the same Copy fold as the chat rows — the id that names it to
    /// Threading and the checkout it stands in — under the same titles. One concept, one
    /// name, whichever row it is asked of.
    func testTheTerminalMenuOffersTheCopyFold() throws {
        let entries = ProjectSidebarViewController()
            .terminalMenuEntries(for: TerminalID(), row: 0)
        let fold = try XCTUnwrap(
            entries.compactMap(\.item).first { $0.title == L10n.string("Copy") }?.submenu,
            "the terminal menu lost its Copy fold"
        )
        XCTAssertEqual(
            fold.compactMap { $0.item?.title },
            [L10n.string("Threading ID"), L10n.string("Worktree Path")]
        )
    }

    private func copySubmenu(in entries: [ThemedMenuEntry]) throws -> [ThemedMenuEntry] {
        try XCTUnwrap(
            entries.compactMap(\.item).first { $0.title == L10n.string("Copy") }?.submenu,
            "the session menu has no Copy fold"
        )
    }

    private func sessionOptions(in entries: [ThemedMenuEntry]) throws -> [ThemedMenuEntry] {
        try XCTUnwrap(
            entries.compactMap(\.item)
                .first { $0.title == SessionActionMenuDefaults.sessionOptionsTitle }?
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

    /// Invisible hover actions do not earn permanent title width. The status keeps one inline
    /// target at rest; entering the row makes room for both controls before they can take clicks.
    // MARK: - The Settings Mark

    /// The mark is asserted on a row inside its host rather than on a bare view, the rule this
    /// file already follows: a row's content is laid out by the row, and a mark that measures
    /// correctly detached can still be one an outline view never gives room to.
    ///
    /// Absence first, because that is the case that has to stay free — nearly every row carries
    /// no override, and the indicator must not become part of mounting every one of them.
    func testAnOrdinaryRowCarriesNoSettingsMark() throws {
        try withAppLimitRecovery(.flagOnly) {
            let (host, row) = hostedRow()
            let plain = session()
            row.configure(
                with: plain,
                activity: .idle,
                conduct: RowConductSummary.forSession(plain)
            )
            host.layoutSubtreeIfNeeded()

            XCTAssertNil(optionalView(named: RowConductDefaults.sessionIdentifier, in: row))
        }
    }

    func testAnArmedChatWearsTheSettingsMarkAndNamesIt() throws {
        try withAppLimitRecovery(.flagOnly) {
            let (host, row) = hostedRow()
            var armed = session()
            armed.limitRecoveryPolicy = .waitForReset
            row.configure(
                with: armed,
                activity: .idle,
                conduct: RowConductSummary.forSession(armed)
            )
            host.layoutSubtreeIfNeeded()

            let mark = try view(named: RowConductDefaults.sessionIdentifier, in: row)
            XCTAssertFalse(mark.isHidden)
            XCTAssertGreaterThan(mark.frame.width, 0, "the mark was given no room in the row")
            XCTAssertEqual(mark.accessibilityLabel(), RowConductStrings.markLabel)
            XCTAssertEqual(mark.toolTip, RowConductStrings.limitRecovery(.waitForReset))
        }
    }

    /// A chat that armed nothing while the app default is already armed is doing what every
    /// other chat does, and says nothing. The mark is for rows that *differ*.
    func testAChatFollowingAnArmedSettingCarriesNoMark() throws {
        try withAppLimitRecovery(.waitForReset) {
            let (host, row) = hostedRow()
            let plain = session()
            row.configure(
                with: plain,
                activity: .idle,
                conduct: RowConductSummary.forSession(plain)
            )
            host.layoutSubtreeIfNeeded()

            XCTAssertNil(optionalView(named: RowConductDefaults.sessionIdentifier, in: row))
        }
    }

    /// Cells are recycled, so a mark left standing would be one chat claiming another's setting.
    func testTheSettingsMarkLeavesWhenTheRowIsReusedForAnOrdinaryChat() throws {
        try withAppLimitRecovery(.flagOnly) {
            let (host, row) = hostedRow()
            var armed = session()
            armed.limitRecoveryPolicy = .waitForReset
            row.configure(
                with: armed,
                activity: .idle,
                conduct: RowConductSummary.forSession(armed)
            )
            host.layoutSubtreeIfNeeded()
            XCTAssertFalse(try view(named: RowConductDefaults.sessionIdentifier, in: row).isHidden)

            let other = session("Somebody else")
            row.configure(
                with: other,
                activity: .idle,
                conduct: RowConductSummary.forSession(other)
            )
            host.layoutSubtreeIfNeeded()

            XCTAssertTrue(try view(named: RowConductDefaults.sessionIdentifier, in: row).isHidden)
        }
    }

    func testTheTrailingSlotOnlyPaysForVisibleContent() throws {
        let (host, row) = hostedRow()
        row.configure(
            with: session("A session title long enough to absorb the available width"),
            activity: .working
        )
        host.layoutSubtreeIfNeeded()

        let slot = try view(named: "sidebar.session.trailing", in: row)
        let title = try view(named: "sidebar.session.title", in: row)
        let restingTitleWidth = title.frame.width

        XCTAssertEqual(
            slot.frame.width,
            SidebarRowDefaults.trailingSlotSize,
            accuracy: 0.5,
            "an unhovered row reserved room for actions it was not showing"
        )

        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            slot.frame.width,
            SidebarRowDefaults.sessionTrailingSlotWidth,
            accuracy: 0.5,
            "the hovered working row did not contain both actions and its status target"
        )
        XCTAssertGreaterThan(
            restingTitleWidth,
            title.frame.width,
            "the resting title did not reclaim the invisible action's width"
        )
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

    /// A click target does not move because a session started spinning.
    ///
    /// The slot used to size itself to the row's actual state: the pair took the row's edge when
    /// there was no status to draw and stepped one column inboard when there was, so the archive
    /// button stood 22pt apart on two rows of the same list. Reserving the status column
    /// unconditionally costs an idle row a column of title while it is hovered, and buys a
    /// trailing geometry that is a fact about the list rather than about each session.
    func testTheActionPairSitsInOnePlaceWhateverTheRowIsDoing() throws {
        func archiveCentre(activity: SessionActivity, isLoading: Bool) throws -> CGFloat {
            let (host, row) = hostedRow()
            row.configure(with: session(), activity: activity, isLoading: isLoading)
            enter(row)
            defer { leave(row) }
            host.layoutSubtreeIfNeeded()

            let archive = try view(named: "sidebar.session.archive", in: row)
            return row.convert(
                NSPoint(x: archive.bounds.midX, y: archive.bounds.midY),
                from: archive
            ).x
        }

        let idle = try archiveCentre(activity: .idle, isLoading: false)
        for state in [
            (activity: SessionActivity.working, isLoading: false, name: "a working row"),
            (activity: .awaitingUser, isLoading: false, name: "a blocked row"),
            (activity: .needsAttention, isLoading: false, name: "an unread row"),
            (activity: .idle, isLoading: true, name: "a loading row")
        ] {
            XCTAssertEqual(
                try archiveCentre(activity: state.activity, isLoading: state.isLoading),
                idle,
                accuracy: 0.5,
                "\(state.name) put its archive button somewhere an idle row does not"
            )
        }
    }

    /// And it does not move *while it is being reached for*.
    ///
    /// This is the way the drift was actually met. `SessionLoadingState.presentation` is raised
    /// because the sidebar is putting the session you just clicked on screen, so the row under the
    /// pointer gained a spinner a moment after the click and the archive button stepped aside —
    /// then stepped back when the load finished.
    func testTheActionPairDoesNotMoveWhenAStatusArrivesUnderThePointer() throws {
        let (host, row) = hostedRow()
        let session = session()
        row.configure(with: session, activity: .idle)
        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        let archive = try view(named: "sidebar.session.archive", in: row)
        func centre() -> CGFloat {
            row.convert(NSPoint(x: archive.bounds.midX, y: archive.bounds.midY), from: archive).x
        }
        let reached = centre()

        row.configure(with: session, activity: .idle, isLoading: true)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            centre(),
            reached,
            accuracy: 0.5,
            "the archive button moved out from under the pointer when the row began loading"
        )

        row.configure(with: session, activity: .idle, isLoading: false)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            centre(),
            reached,
            accuracy: 0.5,
            "the archive button moved back when the row finished loading"
        )
    }

    /// The dot must not move or disappear when actions arrive. Activity is durable state, so the
    /// pair occupies the two columns inboard of the one status keeps at the list's trailing edge.
    func testTheStatusDotKeepsTheRowsTrailingEdge() throws {
        let (host, row) = hostedRow()
        row.configure(with: session(), activity: .working)
        host.layoutSubtreeIfNeeded()

        let status = try view(named: "sidebar.session.status", in: row)
        let restingStatusCentre = row.convert(
            NSPoint(x: status.bounds.midX, y: status.bounds.midY),
            from: status
        )

        enter(row)
        defer { leave(row) }
        host.layoutSubtreeIfNeeded()

        let archive = try view(named: "sidebar.session.archive", in: row)
        let statusCentre = row.convert(NSPoint(x: status.bounds.midX, y: status.bounds.midY), from: status)
        let archiveCentre = row.convert(NSPoint(x: archive.bounds.midX, y: archive.bounds.midY), from: archive)

        XCTAssertEqual(
            statusCentre.x,
            restingStatusCentre.x,
            accuracy: 0.5,
            "the status dot left the row's trailing edge when the slot widened"
        )
        XCTAssertGreaterThan(statusCentre.x, archiveCentre.x)
        XCTAssertEqual(status.alphaValue, 1, accuracy: 0.01)
        XCTAssertFalse(
            row.convert(status.bounds, from: status)
                .intersects(row.convert(archive.bounds, from: archive)),
            "the persistent status overlapped the action moved inboard beside it"
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

    // MARK: - Hover Card Sound Line

    /// The session row keeps no tooltip of its own, so the hover card is where an overridden
    /// chat has to say so. A chat that inherits adds no line: configuration is not status.
    @MainActor
    func testTheHoverCardNamesASoundTheChatDoesNotInherit() {
        var overridden = AgentSession(kind: .claude, title: "Ping")
        overridden.soundOverrides = [
            SoundOverrideKeys.all: SoundChoice.named("Submarine").storedValue
        ]

        let info = SessionInfoPopoverViewController.Info(session: overridden, activity: .idle)
        XCTAssertNotNil(
            info.soundLine,
            "an overridden chat said nothing on its one hover surface"
        )
        XCTAssertEqual(
            info.soundLine?.contains("Submarine"), true,
            "the line does not name the sound it exists to name"
        )

        let inheriting = SessionInfoPopoverViewController.Info(
            session: AgentSession(kind: .claude, title: "Quiet"),
            activity: .idle
        )
        XCTAssertNil(inheriting.soundLine, "a chat that inherits grew a line for it")
    }

    /// Seeds the app-scope limit-recovery answer without announcing a settings change.
    ///
    /// Written straight to the preference rather than through `LimitRecoverySettings.policy`,
    /// whose setter posts `AppSettingsDidChange` into whatever observers the test host has live.
    /// `SidebarTreeBuilderTests` writes `UserDefaults` directly for exactly this reason, and a
    /// sidebar controller an earlier case left alive will act on the broadcast.
    private func withAppLimitRecovery(
        _ policy: LimitRecoveryPolicy,
        run: () throws -> Void
    ) rethrows {
        PreferenceStore.shared.set(policy.rawValue, forKey: LimitRecoverySettings.storageKey)
        defer { PreferenceStore.shared.removeObject(forKey: LimitRecoverySettings.storageKey) }
        try run()
    }
}
