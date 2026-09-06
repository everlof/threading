import AppKit
import XCTest
@testable import Threading

/// Renaming a login, and the surfaces that have to follow it.
///
/// A name is printed in more than one place on the Accounts page alone — the row's own field and
/// the header of the limit card scoped to that login — and outside it on the sidebar's account
/// chip and the composer's identity chip. The page used to keep all of them honest by rebuilding
/// itself and posting `ProjectsDidChange`, which is correct and costs 125 ms plus a sidebar
/// rebuild, a search reindex and an extension fact republish. These hold the narrower route to
/// the same answer.
@MainActor
final class AccountPresentationPropagationTests: XCTestCase {

    private enum Fixture {
        static let suite = "codes.threading.tests.account-presentation"
        static let paneWidth = SettingsUIDefaults.pageWidth
        static let paneHeight: CGFloat = 900
    }

    private var defaults: UserDefaults!
    private var accountStore: AccountPreferencesStore!
    private var limitSettings: CustomLimitSettings!

    override func setUp() async throws {
        try await super.setUp()
        // One stable suite per class, erased at both ends: a suite per method accumulates on
        // disk, and the shared store would write the developer's own account names.
        UserDefaults.standard.removePersistentDomain(forName: Fixture.suite)
        defaults = UserDefaults(suiteName: Fixture.suite)
        accountStore = AccountPreferencesStore(defaults: defaults)
        limitSettings = CustomLimitSettings(defaults: defaults)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: Fixture.suite)
        defaults = nil
        accountStore = nil
        limitSettings = nil
        try await super.tearDown()
    }

    // MARK: - The page

    /// The two places the page prints the name both follow the edit.
    func testRenamingALoginRestampsItsRowAndTheLimitCardScopedToIt() throws {
        let page = try mountedPage()
        let field = try XCTUnwrap(nameField(in: page.controller, at: 0))

        field.stringValue = "Renamed Login"
        page.controller.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: field
        ))
        settle(page.host)

        XCTAssertEqual(
            nameField(in: page.controller, at: 0)?.stringValue,
            "Renamed Login",
            "the account row"
        )
        XCTAssertTrue(
            labels(in: page.controller).contains("Renamed Login"),
            "the limit card scoped to this login prints the name on its header: \(labels(in: page.controller))"
        )
        XCTAssertFalse(
            labels(in: page.controller).contains("Fixture 0"),
            "no surface still prints the old name"
        )
    }

    /// The other logins are not collateral: their rows keep their own names.
    func testRenamingOneLoginLeavesTheOthersAlone() throws {
        let page = try mountedPage()
        let field = try XCTUnwrap(nameField(in: page.controller, at: 0))

        field.stringValue = "Renamed Login"
        page.controller.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: field
        ))
        settle(page.host)

        XCTAssertEqual(nameField(in: page.controller, at: 1)?.stringValue, "Fixture 1")
    }

    /// The performance contract, stated as the structural fact behind it rather than a clock:
    /// a presentation edit restamps rows, it does not rebuild the page.
    func testRenamingALoginDoesNotRebuildTheWholePage() throws {
        let page = try mountedPage()
        let field = try XCTUnwrap(nameField(in: page.controller, at: 0))
        let rebuilds = page.controller.presentationRebuildCountForTesting

        field.stringValue = "Renamed Login"
        page.controller.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: field
        ))

        XCTAssertEqual(page.controller.presentationRebuildCountForTesting, rebuilds)
    }

    /// The exception, and the reason the targeted path checks the roster first: a login arriving
    /// or leaving while Settings stands open moves every row index below it.
    func testALoginLeavingWhileSettingsIsOpenStillRebuildsThePage() throws {
        var roster = fixtureAccounts()
        let controller = AccountsPreferencesViewController(
            accountsProvider: provider(for: { roster }),
            limitSettings: limitSettings,
            accountStore: accountStore
        )
        let host = mount(controller)
        let field = try XCTUnwrap(nameField(in: controller, at: 0))
        let rebuilds = controller.presentationRebuildCountForTesting

        roster.removeLast()
        field.stringValue = "Renamed Login"
        controller.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: field
        ))
        settle(host)

        XCTAssertGreaterThan(controller.presentationRebuildCountForTesting, rebuilds)
    }

    /// Switching a login off dims its row. That is presentation too, and takes the same route.
    func testSwitchingALoginOffRestampsItWithoutRebuildingThePage() throws {
        let page = try mountedPage()
        let toggle = try XCTUnwrap(
            descendants(of: page.controller.view)
                .compactMap { $0 as? ThemedToggle }
                .first { $0.tag == 0 }
        )
        let rebuilds = page.controller.presentationRebuildCountForTesting

        XCTAssertEqual(toggle.state, .on, "the fixture starts switched on")
        // The themed switch routes its own press; `NSControl.performClick(_:)` is not that path.
        toggle.mouseDown(with: .init())
        settle(page.host)

        XCTAssertEqual(accountStore.isEnabled(fixtureAccounts()[0].id), false)
        XCTAssertEqual(page.controller.presentationRebuildCountForTesting, rebuilds)
    }

    /// The rule that made the repair a repair rather than a rearrangement.
    ///
    /// Rebuilding the row that owns the live field editor removes the field AppKit is editing in,
    /// and the input session teardown that follows measured 80 ms of the commit's 125 — against
    /// 2.8 ms for the identical commit with nothing focused. So that one row is restamped by
    /// value: the same field object survives the edit it delivered.
    func testTheFieldTheEditCameFromSurvivesTheCommit() throws {
        let accounts = fixtureAccounts()
        let controller = AccountsPreferencesViewController(
            accountsProvider: provider(for: { accounts }),
            limitSettings: limitSettings,
            accountStore: accountStore
        )
        let host = mount(controller)
        // Unshown, and never ordered on screen: installing a field editor needs neither.
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = host
        let field = try XCTUnwrap(nameField(in: controller, at: 0))
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertNotNil(field.currentEditor(), "the fixture must actually be editing")

        field.stringValue = "  Renamed Login  "
        controller.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: field
        ))
        settle(host)

        XCTAssertTrue(
            descendants(of: controller.view).contains { $0 === field },
            "the row was rebuilt, taking the field being edited with it"
        )
        // Restated rather than left as typed, which is what the rebuild used to buy: the store
        // trims, and this is where that reaches the person who typed the spaces.
        XCTAssertEqual(field.stringValue, "Renamed Login")

        window.contentView = nil
    }

    /// The row kept standing for its field editor's sake still has to stop announcing the old
    /// name: its switch says which login it switches.
    func testTheRowsSwitchAnnouncesTheNewNameAfterARename() throws {
        let page = try mountedPage()
        let field = try XCTUnwrap(nameField(in: page.controller, at: 0))

        field.stringValue = "Renamed Login"
        page.controller.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: field
        ))
        settle(page.host)

        let toggle = try XCTUnwrap(
            descendants(of: page.controller.view)
                .compactMap { $0 as? ThemedToggle }
                .first { $0.tag == 0 }
        )
        XCTAssertEqual(
            toggle.accessibilityLabel(),
            AccountsPreferencesStrings.enabledLabel("Renamed Login")
        )
    }

    /// Clearing the field is the other half of restating it: the automatic name comes back.
    func testClearingTheFieldRestoresTheDiscoveredName() throws {
        let page = try mountedPage()
        let field = try XCTUnwrap(nameField(in: page.controller, at: 0))
        field.stringValue = "Renamed Login"
        page.controller.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: field
        ))

        field.stringValue = ""
        page.controller.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: field
        ))
        settle(page.host)

        XCTAssertEqual(nameField(in: page.controller, at: 0)?.stringValue, "Fixture 0")
    }

    // MARK: - The surfaces outside the page

    /// The chip is cached by what it *draws*, and the name is not drawn — the initial comes from
    /// the login address. So the announcement has to be restamped on the cache-hit path, or a
    /// renamed account keeps telling VoiceOver its old name for the life of the process.
    func testTheAccountChipAnnouncesTheNameItWasLastAskedFor() throws {
        let before = AgentAccount(
            provider: .claude,
            handle: .named("claude-chip-fixture"),
            configPath: "/Users/dev/.claude-chip-fixture",
            // The two names share an initial deliberately: the initial is part of the cache key
            // and comes from the login address in the app, so a rename there always lands on the
            // hit path. A fixture with no cached email falls back to the display name, and two
            // names starting differently would quietly build a second chip instead.
            displayName: "Alpha Fixture"
        )
        let after = AgentAccount(
            provider: .claude,
            handle: before.handle,
            configPath: before.configPath,
            displayName: before.displayName,
            displayNameOverride: "Amended Fixture"
        )

        let first = try XCTUnwrap(AccountBadge.chip(for: before))
        XCTAssertEqual(first.accessibilityDescription, "Alpha Fixture")
        let second = try XCTUnwrap(AccountBadge.chip(for: after))

        XCTAssertEqual(second.accessibilityDescription, "Amended Fixture")
    }

    /// Both surfaces that used to depend on the page's `ProjectsDidChange` now listen for the
    /// event the store already posts. Held as source structure because the alternative is a
    /// window on screen; the failure this prevents is the observer being deleted, not miswired.
    func testTheSidebarAndComposerObserveTheAccountEvent() throws {
        for file in [
            "Sources/Threading/UI/Views/ProjectSidebarViewController.swift",
            "Sources/Threading/UI/Views/SessionComposerViewController.swift"
        ] {
            let source = try String(contentsOf: repositoryFile(file), encoding: .utf8)
            XCTAssertTrue(
                source.contains("observe(AccountPreferencesDidChange.self)"),
                "\(file) must follow an account rename"
            )
        }
    }

    /// The page no longer announces a presentation edit as a change to the project graph.
    func testTheAccountsPageNoLongerPostsTheStructuralEvent() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "Sources/Threading/UI/Preferences/AccountsPreferencesViewController.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("post(ProjectsDidChange()"))
    }

    // MARK: - Helpers

    private func fixtureAccounts() -> [AgentAccount] {
        (0..<4).map { index in
            AgentAccount(
                provider: index.isMultiple(of: 2) ? .claude : .codex,
                handle: .named("fixture-account-\(index)"),
                configPath: "/Users/dev/.fixture-account-\(index)",
                displayName: "Fixture \(index)"
            )
        }
    }

    /// Stands in for `AgentAccountDiscovery`, whose contract is that the durable preferences are
    /// layered over the discovered account on every read. A fixture returning a fixed array would
    /// prove the page re-reads nothing, since the store is where an edit lands.
    private func provider(for roster: @escaping () -> [AgentAccount]) -> () -> [AgentAccount] {
        { [accountStore] in
            roster().map { discovered in
                AgentAccount(
                    provider: discovered.provider,
                    handle: discovered.handle,
                    configPath: discovered.configPath,
                    displayName: discovered.displayName,
                    displayNameOverride: accountStore?.displayNameOverride(for: discovered.id),
                    emoji: accountStore?.emoji(for: discovered.id),
                    isEnabled: accountStore?.isEnabled(discovered.id) ?? true
                )
            }
        }
    }

    private func mountedPage() throws -> (controller: AccountsPreferencesViewController, host: NSView) {
        let accounts = fixtureAccounts()
        let controller = AccountsPreferencesViewController(
            accountsProvider: provider(for: { accounts }),
            limitSettings: limitSettings,
            accountStore: accountStore
        )
        // The limit cards are folded on an untouched install, and their headers are where the
        // second copy of the name lives, so the fixture opens them.
        controller.expandLimitsForTesting()
        return (controller, mount(controller))
    }

    private func mount(_ controller: AccountsPreferencesViewController) -> NSView {
        let bounds = NSRect(x: 0, y: 0, width: Fixture.paneWidth, height: Fixture.paneHeight)
        let host = NSView(frame: bounds)
        let page = controller.view
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: host.topAnchor),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        controller.viewWillAppear()
        controller.expandLimitsForTesting()
        settle(host)
        return host
    }

    /// A virtual table materializes a cell when it lays out *and draws*.
    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
    }

    private func nameField(
        in controller: AccountsPreferencesViewController,
        at index: Int
    ) -> ThemedTextField? {
        descendants(of: controller.view)
            .compactMap { $0 as? ThemedTextField }
            .first { $0.tag == index && $0.isEditable }
    }

    private func labels(in controller: AccountsPreferencesViewController) -> Set<String> {
        Set(descendants(of: controller.view).compactMap { ($0 as? NSTextField)?.stringValue })
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func repositoryFile(_ path: String) -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root.appendingPathComponent(path)
    }
}
