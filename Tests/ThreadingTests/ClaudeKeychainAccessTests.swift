import AppKit
import XCTest
import os
@testable import Threading

/// A Claude login added after the Privacy switch went on was never offered the keychain prompt,
/// so its silent reads failed closed and its usage froze on the CLI's days-old `.claude.json`
/// snapshot — labelled as the per-turn status-line feed, with nothing on screen saying why.
/// These pin the four halves of the repair: the refusal is remembered, every surface showing
/// the stale reading offers **Allow…**, a grant re-reads at once, and the stale reading names
/// its real source.
@MainActor
final class ClaudeKeychainAccessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    // MARK: - Remembering the Refusal

    /// The read's status is the only evidence there is, and the fail-closed statuses an ACL
    /// or a locked keychain return must read as "waiting", not as "no login".
    func testReadStatusesClassifyIntoTheThreeAnswers() {
        XCTAssertEqual(ClaudeKeychainCredentials.availability(for: errSecSuccess), .granted)
        XCTAssertEqual(ClaudeKeychainCredentials.availability(for: errSecItemNotFound), .missing)
        XCTAssertEqual(ClaudeKeychainCredentials.availability(for: errSecAuthFailed), .needsGrant)
        XCTAssertEqual(
            ClaudeKeychainCredentials.availability(for: errSecInteractionNotAllowed),
            .needsGrant
        )
    }

    /// A refresh tick that learns nothing new must wake nobody; a changed answer must reach
    /// every surface drawing the login.
    func testObservedAnswerAnnouncesOnlyChanges() {
        let path = "/fixtures/keychain-observed-\(UUID().uuidString)"
        defer { ClaudeKeychainCredentials.forgetAll() }
        var announcements = 0
        let token = NotificationCenter.default.observe(ClaudeKeychainAccessDidChange.self) {
            if $0.configPath == path { announcements += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertNil(ClaudeKeychainCredentials.observedAvailability(forConfigPath: path))
        ClaudeKeychainCredentials.recordForTesting(.needsGrant, forConfigPath: path)
        ClaudeKeychainCredentials.recordForTesting(.needsGrant, forConfigPath: path)
        ClaudeKeychainCredentials.recordForTesting(.granted, forConfigPath: path)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(ClaudeKeychainCredentials.observedAvailability(forConfigPath: path), .granted)
        XCTAssertEqual(announcements, 2, "a repeated answer was announced as a change")
    }

    // MARK: - Offering the Grant

    /// Offered only where it can help: the user asked for live usage, and this login's item
    /// refused the last read. Off, granted, missing and never-read all stay quiet.
    func testOffersGrantOnlyForARefusingLoginWithLiveUsageOn() throws {
        let account = fixture("waiting")
        var answer: ClaudeKeychainCredentials.Availability? = .needsGrant
        let on = try settings(readsKeychain: true)
        let access = ClaudeKeychainAccess(settings: on, observedAvailability: { _ in answer })

        XCTAssertTrue(access.offersGrant(for: account))
        for quiet: ClaudeKeychainCredentials.Availability? in [.granted, .missing, nil] {
            answer = quiet
            XCTAssertFalse(access.offersGrant(for: account), "offered for \(String(describing: quiet))")
        }

        answer = .needsGrant
        let off = ClaudeKeychainAccess(
            settings: try settings(readsKeychain: false),
            observedAvailability: { _ in answer }
        )
        XCTAssertFalse(off.offersGrant(for: account), "offered a grant the user opted out of")
    }

    /// One prompt per waiting login and none for any other; only a login the prompt actually
    /// opened is re-read early, and a declined one is reported as still waiting. While the
    /// prompt is up the button is withdrawn, so a second click cannot stack a second prompt.
    func testRequestPromptsOnlyWaitingLoginsAndRereadsWhatItOpened() throws {
        let granted = fixture("already")
        let accepts = fixture("accepts")
        let declines = fixture("declines")
        let absent = fixture("absent")
        let prompted = OSAllocatedUnfairLock(initialState: [String]())
        var refreshed: [AccountID] = []

        let access = ClaudeKeychainAccess(
            settings: try settings(readsKeychain: true),
            observedAvailability: { _ in .needsGrant },
            probe: { path in
                switch path {
                case granted.configPath: return .granted
                case absent.configPath: return .missing
                default: return .needsGrant
                }
            },
            grant: { path in
                prompted.withLock { $0.append(path) }
                return path == accepts.configPath
            },
            claudeAccounts: { [granted, accepts, declines, absent] },
            refreshUsage: { refreshed.append($0.id) }
        )

        let done = expectation(description: "request finished")
        var outcome: ClaudeKeychainAccess.Outcome?
        access.requestAccessForAllLogins {
            outcome = $0
            done.fulfill()
        }
        XCTAssertFalse(access.offersGrant(for: accepts), "the button stayed up behind its prompt")
        wait(for: [done], timeout: 5)

        XCTAssertEqual(prompted.withLock { $0 }, [accepts.configPath, declines.configPath])
        XCTAssertEqual(outcome?.granted, [accepts])
        XCTAssertEqual(outcome?.stillWaiting, [declines])
        XCTAssertEqual(refreshed, [accepts.id])
        XCTAssertTrue(access.offersGrant(for: declines), "the offer did not come back")
    }

    /// The end of Add Login asks only when the user has opted in to keychain reads.
    func testSignInAsksOnlyWithLiveUsageOn() throws {
        let account = fixture("new-login")
        let off = ClaudeKeychainAccess(
            settings: try settings(readsKeychain: false),
            probe: { _ in
                XCTFail("an opted-out sign-in touched the keychain")
                return .needsGrant
            },
            grant: { _ in false }
        )
        off.requestAccessAfterSignIn(account)

        let asked = expectation(description: "opted-in sign-in asked")
        let on = ClaudeKeychainAccess(
            settings: try settings(readsKeychain: true),
            probe: { _ in .needsGrant },
            grant: { _ in
                asked.fulfill()
                return true
            },
            refreshUsage: { _ in }
        )
        on.requestAccessAfterSignIn(account)
        wait(for: [asked], timeout: 5)
    }

    // MARK: - Re-reading After a Grant

    /// The reading on screen is the stale one the user just acted on, so a grant waives the
    /// per-account floor — but never a pause the endpoint asked for.
    func testGrantRefreshWaivesTheFloorButNotTheServersPause() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let refuse = OSAllocatedUnfairLock(initialState: false)
        let reading = usage(source: .api)
        let service = AccountUsageService(observesActivity: false) { _ in
            calls.withLock { $0 += 1 }
            if refuse.withLock({ $0 }) { throw UsageFetchError.rateLimited(retryAfter: 600) }
            return reading
        }
        let account = fixture("floor")

        await settle(service, account)
        await settle(service, account, force: true)
        XCTAssertEqual(calls.withLock { $0 }, 1, "the floor did not hold for an ordinary force")

        service.refreshAfterCredentialChange(account)
        await settle(service, account)
        XCTAssertEqual(calls.withLock { $0 }, 2, "a grant did not re-read at once")

        refuse.withLock { $0 = true }
        service.refreshAfterCredentialChange(account)
        await settle(service, account)
        XCTAssertEqual(calls.withLock { $0 }, 3)
        service.refreshAfterCredentialChange(account)
        await settle(service, account)
        XCTAssertEqual(calls.withLock { $0 }, 3, "a grant spent the endpoint's 429 pause")
    }

    // MARK: - Surfaces

    /// The popover says what is wrong beside the stale reading and names where that reading
    /// really came from.
    func testPopoverOffersTheGrantAndNamesTheSnapshotSource() throws {
        let account = fixture("popover")
        let controller = AccountUsagePopoverViewController(
            account: account,
            isEmbedded: true,
            readingProvider: { _ in .current(self.usage(source: .profileSnapshot)) },
            limitsProvider: { _ in [] },
            nowProvider: { self.now.addingTimeInterval(2 * 86_400) },
            keychainAccess: ClaudeKeychainAccess(
                settings: try settings(readsKeychain: true),
                observedAvailability: { _ in .needsGrant }
            )
        )
        _ = controller.view

        XCTAssertTrue(controller.offersKeychainGrantForTesting)
        XCTAssertEqual(
            controller.footerTextForTesting,
            "Updated 2d ago · from the Claude CLI's last saved reading"
        )
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])

        let granted = AccountUsagePopoverViewController(
            account: account,
            isEmbedded: true,
            readingProvider: { _ in .current(self.usage(source: .localCache)) },
            limitsProvider: { _ in [] },
            nowProvider: { self.now },
            keychainAccess: ClaudeKeychainAccess(
                settings: try settings(readsKeychain: true),
                observedAvailability: { _ in .granted }
            )
        )
        _ = granted.view
        XCTAssertFalse(granted.offersKeychainGrantForTesting)
        XCTAssertEqual(granted.footerTextForTesting, "Updated just now · via Claude's status-line feed")
    }

    /// Only the waiting login's card carries the row, and its height is measured with it.
    func testFleetOffersTheGrantOnlyOnTheWaitingLoginsCard() throws {
        let waiting = fixture("fleet-waiting")
        let readable = fixture("fleet-readable")
        let fleet = AccountUsageFleetView(
            maximumHeight: 600,
            limitsProvider: { _ in [] },
            keychainAccess: ClaudeKeychainAccess(
                settings: try settings(readsKeychain: true),
                observedAvailability: { $0 == waiting.configPath ? .needsGrant : .granted }
            )
        )
        let items = [waiting, readable].map {
            AccountUsageFleetItem(
                account: $0,
                reading: .current(usage(source: .api)),
                isCurrent: false,
                allowsHandoff: false
            )
        }
        fleet.show(items, at: now)
        fleet.frame = NSRect(x: 0, y: 0, width: Design.AccountUsageFleet.popoverWidth, height: 600)
        fleet.layoutSubtreeIfNeeded()

        XCTAssertEqual(fleet.keychainGrantAccountIDsForTesting, [waiting.id])
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: fleet), [])
    }

    // MARK: - Rendered State

    /// The popover and a fleet card with the grant offered beside a days-old snapshot, light and
    /// dark — the state a login added after the switch went on now shows instead of a silent
    /// stale reading.
    func testRendersTheKeychainGrantNoticeToImages() throws {
        guard let directoryPath = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .flatMap({ $0.isEmpty ? nil : $0 })
        else {
            throw XCTSkip("Set THREADING_RENDER_OUT to capture keychain grant evidence")
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(.system)
        defer { AppThemeLibrary.apply(previousTheme) }

        let waiting = fixture("rinda01")
        let readable = fixture("work")
        let access = ClaudeKeychainAccess(
            settings: try settings(readsKeychain: true),
            observedAvailability: { $0 == waiting.configPath ? .needsGrant : .granted }
        )
        let stale = usage(source: .profileSnapshot)
        let later = now.addingTimeInterval(2 * 86_400)

        for (name, appearanceName) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", NSAppearance.Name.darkAqua)
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var popoverPNG: Data?
            var fleetPNG: Data?
            appearance.performAsCurrentDrawingAppearance {
                let controller = AccountUsagePopoverViewController(
                    account: waiting,
                    readingProvider: { _ in .current(stale) },
                    limitsProvider: { _ in [] },
                    nowProvider: { later },
                    keychainAccess: access
                )
                popoverPNG = render(controller.view, width: UsagePopoverDefaults.width, appearance: appearance)

                let fleet = AccountUsageFleetView(
                    maximumHeight: 600,
                    limitsProvider: { _ in [] },
                    keychainAccess: access
                )
                fleet.show([waiting, readable].map {
                    AccountUsageFleetItem(
                        account: $0,
                        reading: .current($0 == waiting ? stale : usage(source: .api)),
                        isCurrent: false,
                        allowsHandoff: false
                    )
                }, at: later)
                fleetPNG = render(fleet, width: Design.AccountUsageFleet.popoverWidth, appearance: appearance)
            }
            try XCTUnwrap(popoverPNG).write(
                to: directory.appendingPathComponent("keychain-grant-popover-\(name).png")
            )
            try XCTUnwrap(fleetPNG).write(
                to: directory.appendingPathComponent("keychain-grant-fleet-\(name).png")
            )
        }
    }

    private func render(_ view: NSView, width: CGFloat, appearance: NSAppearance) -> Data? {
        let host = ThemedSurfaceView()
        host.applySurface(fill: Design.Surface.elevated, radius: .fixed(0))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.widthAnchor.constraint(equalToConstant: width)
        ])
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(x: 0, y: 0, width: width, height: view.fittingSize.height)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.appearance = appearance
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: host), [])
        guard let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }

    // MARK: - Fixtures

    private func settle(
        _ service: AccountUsageService,
        _ account: AgentAccount,
        force: Bool = false
    ) async {
        await withCheckedContinuation { continuation in
            service.refresh(account, force: force) { continuation.resume() }
        }
    }

    private func settings(readsKeychain: Bool) throws -> AppSettings {
        let suite = "claude-keychain-access-tests-\(UUID().uuidString)"
        suites.append(suite)
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        settings.readsClaudeLoginFromKeychain = readsKeychain
        return settings
    }

    private func fixture(_ name: String) -> AgentAccount {
        AgentAccount(
            provider: .claude,
            handle: AccountHandle(storedName: "keychain-\(name)"),
            configPath: "/fixtures/keychain-\(name)",
            displayName: name
        )
    }

    private func usage(source: AccountUsage.Source) -> AccountUsage {
        AccountUsage(
            windows: [AccountUsage.Window(
                id: "7d",
                label: "Weekly",
                fraction: 0.4,
                resetsAt: now.addingTimeInterval(3 * 86_400),
                windowDuration: 7 * 86_400
            )],
            planLabel: nil,
            observedAt: now,
            source: source
        )
    }
}
