import AppKit
import UserNotifications
import XCTest
@testable import Threading

/// The Privacy page is an inventory of what the OS lets Threading do, so the thing under test is
/// mostly *honesty*: that it reports a grant it can read, admits the one it cannot, and never
/// asks for anything merely because someone opened a settings page.
@MainActor
final class PrivacyPreferencesTests: XCTestCase {

    // MARK: - Fixtures

    /// A reader whose every answer is stated by the test, so an assertion never depends on what
    /// this particular Mac happens to have approved in System Settings.
    private func reader(
        accessibility: Bool = false,
        screenRecording: Bool = false,
        notifications: SystemPrivacyStatus = .askedWhenNeeded,
        probeCount: ProbeCount? = nil
    ) -> SystemPrivacyStatusReader {
        SystemPrivacyStatusReader(
            accessibilityTrusted: {
                probeCount?.accessibility += 1
                return accessibility
            },
            screenRecordingAllowed: {
                probeCount?.screenRecording += 1
                return screenRecording
            },
            notificationStatus: { completion in
                probeCount?.notifications += 1
                completion(notifications)
            }
        )
    }

    private final class ProbeCount {
        var accessibility = 0
        var screenRecording = 0
        var notifications = 0
    }

    /// Tall enough to contain the whole page. The page is a scroll view, so it has no height of
    /// its own to be sized to — a host that is too short silently crops the bottom, and the
    /// render test would keep passing on a picture missing its newest rows.
    /// `testTheRenderCoversTheWholePage` is what stops that happening again.
    private static let fixtureHeight: CGFloat = 1800
    private static let hostedWindow = NSWindow(
        contentRect: NSRect(
            x: 0,
            y: 0,
            width: SettingsUIDefaults.pageWidth,
            height: fixtureHeight
        ),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )

    private func page(
        _ reader: SystemPrivacyStatusReader,
        height: CGFloat = PrivacyPreferencesTests.fixtureHeight,
        refreshInterval: TimeInterval = PrivacyPageDefaults.refreshInterval
    ) -> PrivacyPreferencesViewController {
        let controller = PrivacyPreferencesViewController(
            reader: reader,
            refreshInterval: refreshInterval
        )
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: SettingsUIDefaults.pageWidth,
            height: height
        )
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    /// A window the page can be *in* without being on anyone's screen — the same fixture the
    /// rest of this target uses, and never ordered front. The page only re-reads a grant while
    /// it is in a window, so the watching tests need one; nothing about them needs it visible.
    /// The host itself is reused so AppKit never has to retire it while XCTest is draining the
    /// case's autorelease pool. Its page is replaced per test, preserving state isolation while
    /// bounding the live fixture count at one.
    private func hosted(_ controller: NSViewController) -> NSWindow {
        let window = Self.hostedWindow
        window.contentView?.subviews.forEach { $0.removeFromSuperview() }
        window.setContentSize(controller.view.frame.size)
        window.contentView?.addSubview(controller.view)
        return window
    }

    private func retireHosted(
        _ controller: PrivacyPreferencesViewController,
        from window: NSWindow
    ) {
        controller.viewWillDisappear()
        window.orderOut(nil)
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func row(
        _ permission: SystemPrivacyPermission,
        in controller: NSViewController
    ) throws -> NSView {
        let identifier = "settings.privacy.\(permission.rawValue)"
        return try XCTUnwrap(
            descendants(in: controller.view).first {
                $0.accessibilityIdentifier() == identifier
            },
            "the page has no row for \(permission.rawValue)"
        )
    }

    private func labels(in view: NSView) -> [String] {
        ([view] + descendants(in: view))
            .compactMap { ($0 as? NSTextField)?.stringValue }
    }

    // MARK: - The Model

    func testEveryGrantNamesTheSettingsPaneThatOwnsIt() {
        let urls = SystemPrivacyPermission.allCases.compactMap(\.settingsURL)
        XCTAssertEqual(
            urls.count,
            SystemPrivacyPermission.allCases.count,
            "a permission offers an Open Settings button that would go nowhere"
        )
        XCTAssertEqual(
            Set(urls.map(\.absoluteString)).count,
            urls.count,
            "two permissions point at the same pane, so one of them sends the user to the wrong "
                + "switch"
        )
        for url in urls {
            XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        }
    }

    /// `.provisional` delivers quietly rather than not at all. Reporting it as anything but
    /// allowed would tell a user a notification cannot arrive when one already can.
    func testNotificationAuthorizationMapsOntoWhatTheUserCanObserve() {
        XCTAssertEqual(SystemPrivacyStatus(.authorized), .allowed)
        XCTAssertEqual(SystemPrivacyStatus(.provisional), .allowed)
        XCTAssertEqual(SystemPrivacyStatus(.denied), .notAllowed)
        XCTAssertEqual(SystemPrivacyStatus(.notDetermined), .askedWhenNeeded)
    }

    func testTheReaderReportsEachGrantItCanRead() {
        var statuses: [SystemPrivacyPermission: SystemPrivacyStatus] = [:]
        reader(accessibility: true, screenRecording: false, notifications: .notAllowed)
            .load { statuses = $0 }

        XCTAssertEqual(statuses[.accessibility], .allowed)
        XCTAssertEqual(statuses[.screenRecording], .notAllowed)
        XCTAssertEqual(statuses[.notifications], .notAllowed)
        XCTAssertEqual(
            statuses.count,
            SystemPrivacyPermission.allCases.count,
            "a permission is listed on the page but has no status to show"
        )
    }

    /// The whole reason `askedWhenNeeded` exists. There is no API that reports the folder grant
    /// without requesting it, and requesting it would put a system prompt on screen because the
    /// user opened a settings page — the opposite of what the page is for.
    func testTheFolderGrantIsReportedAsUnreadableRatherThanProbed() {
        XCTAssertFalse(SystemPrivacyPermission.filesAndFolders.isStatusReadable)

        var statuses: [SystemPrivacyPermission: SystemPrivacyStatus] = [:]
        reader(accessibility: true, screenRecording: true, notifications: .allowed)
            .load { statuses = $0 }

        XCTAssertEqual(
            statuses[.filesAndFolders],
            .askedWhenNeeded,
            "the folder grant claims a status it cannot know without prompting"
        )
    }

    func testOpeningThePageReadsEachGrantExactlyOnce() {
        let probes = ProbeCount()
        _ = page(reader(probeCount: probes))

        XCTAssertEqual(probes.accessibility, 1)
        XCTAssertEqual(probes.screenRecording, 1)
        XCTAssertEqual(probes.notifications, 1)
    }

    // MARK: - Staying True While It Is Open

    /// A reader whose answer the test can change halfway through, standing in for the user
    /// flipping the switch in System Settings.
    private final class LiveGrant {
        var isAllowed = false
        var reads = 0
        var onRead: (() -> Void)?
    }

    private func liveReader(_ grant: LiveGrant) -> SystemPrivacyStatusReader {
        SystemPrivacyStatusReader(
            accessibilityTrusted: {
                grant.reads += 1
                grant.onRead?()
                return grant.isAllowed
            },
            screenRecordingAllowed: { false },
            notificationStatus: { $0(.askedWhenNeeded) }
        )
    }

    /// The page invites the change and then used to ignore it: the row says "You allow
    /// Threading in System Settings", the button opens that pane, and coming back left the word
    /// reading "Not allowed" until the page was navigated away from and back. `viewWillAppear`
    /// does not fire for a page that never left.
    func testAGrantAllowedInSystemSettingsIsReportedOnComingBack() throws {
        let grant = LiveGrant()
        let controller = page(liveReader(grant))
        let window = hosted(controller)
        defer { retireHosted(controller, from: window) }
        controller.viewDidAppear()

        XCTAssertTrue(labels(in: try row(.accessibility, in: controller)).contains("Not allowed"))

        grant.isAllowed = true
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )

        XCTAssertTrue(
            labels(in: try row(.accessibility, in: controller)).contains("Allowed"),
            "the page kept reporting the old answer after the user granted it and came back"
        )
        withExtendedLifetime(window) {}
    }

    /// Activation covers coming back from System Settings, and nothing covers the rest: a TCC
    /// dialog is put up by another process, so an approval given to one an *agent* raised can
    /// land without Threading ever having resigned active.
    func testAnOpenPageLooksAgainWithoutBeingTouched() throws {
        let grant = LiveGrant()
        let controller = page(liveReader(grant), refreshInterval: 0.05)
        let window = hosted(controller)
        defer { retireHosted(controller, from: window) }
        controller.viewDidAppear()

        let looked = expectation(description: "the page reads the grant again on its own")
        looked.assertForOverFulfill = false
        grant.isAllowed = true
        grant.onRead = { looked.fulfill() }

        wait(for: [looked], timeout: 2)

        XCTAssertTrue(
            labels(in: try row(.accessibility, in: controller)).contains("Allowed"),
            "the page looked again and still showed the old answer"
        )
        withExtendedLifetime(window) {}
    }

    /// A settings page is cached and kept alive after being navigated away from, so "still
    /// polling" is a real failure mode rather than a theoretical one — the page would go on
    /// reading grants for the rest of the app's life.
    func testANavigatedAwayPageStopsLookingAltogether() {
        let grant = LiveGrant()
        let controller = page(liveReader(grant), refreshInterval: 0.05)
        let window = hosted(controller)
        defer { retireHosted(controller, from: window) }
        controller.viewDidAppear()
        controller.viewWillDisappear()

        let before = grant.reads
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        let settled = expectation(description: "several poll intervals pass")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(grant.reads, before, "the page went on reading grants after it left")
        withExtendedLifetime(window) {}
    }

    /// The poll would otherwise rewrite four identical labels twenty times a minute, which
    /// re-announces every row to VoiceOver for nothing.
    func testAnUnchangedGrantDoesNotRewriteItsRow() throws {
        let grant = LiveGrant()
        let controller = page(liveReader(grant))
        let window = hosted(controller)
        defer { retireHosted(controller, from: window) }
        controller.viewDidAppear()

        let label = try XCTUnwrap(
            descendants(in: try row(.accessibility, in: controller))
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "Not allowed" }
        )
        label.stringValue = "sentinel"

        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )

        XCTAssertEqual(label.stringValue, "sentinel", "an unchanged row was written again")
        withExtendedLifetime(window) {}
    }

    // MARK: - The Page

    func testEachRowStatesItsStatusInWords() throws {
        let controller = page(
            reader(accessibility: true, screenRecording: false, notifications: .notAllowed)
        )

        XCTAssertTrue(
            labels(in: try row(.accessibility, in: controller)).contains("Allowed"),
            "an allowed grant is shown by colour alone"
        )
        XCTAssertTrue(
            labels(in: try row(.screenRecording, in: controller)).contains("Not allowed")
        )
        XCTAssertTrue(
            labels(in: try row(.notifications, in: controller)).contains("Not allowed")
        )
        XCTAssertTrue(
            labels(in: try row(.filesAndFolders, in: controller))
                .contains("Asked when needed")
        )
    }

    func testEachRowCarriesTitleAndStatusToVoiceOver() throws {
        let controller = page(reader(accessibility: true, notifications: .allowed))

        XCTAssertEqual(
            try row(.accessibility, in: controller).accessibilityLabel(),
            "Accessibility permission: Allowed"
        )
        XCTAssertEqual(
            try row(.filesAndFolders, in: controller).accessibilityLabel(),
            "Files & Folders permission: Asked when needed"
        )
    }

    /// Four buttons all reading "Open Settings" tell an assistive user nothing about which pane
    /// they open, and the button is the only control on the page. The context has to live in
    /// AXHelp: `ThemedButton` publishes its words as AXTitle and returns nil for AXDescription,
    /// so a label set here would be dropped without anyone noticing.
    func testTheSettingsButtonsAreDistinguishableWithoutSight() throws {
        let controller = page(reader())

        let hints = try SystemPrivacyPermission.allCases.map { permission -> String in
            let identifier = "settings.privacy.\(permission.rawValue).open"
            let button = try XCTUnwrap(
                descendants(in: controller.view).first {
                    $0.accessibilityIdentifier() == identifier
                },
                "no Open Settings button for \(permission.rawValue)"
            )
            XCTAssertEqual(
                button.accessibilityHelp(),
                button.toolTip,
                "the pointer and VoiceOver are told different things about the same button"
            )
            return button.accessibilityHelp() ?? ""
        }

        XCTAssertEqual(Set(hints).count, hints.count, "the buttons share one description")
        XCTAssertTrue(hints.allSatisfy { $0.contains("System Settings") })
        XCTAssertTrue(hints.contains("Open Accessibility in System Settings"))
    }

    func testThePageIsDiscoverableFromTheSettingsCatalogue() throws {
        let definition = try XCTUnwrap(SettingsPages.page(id: SettingsPages.privacyID))
        XCTAssertEqual(definition.title, "Privacy")
        XCTAssertTrue(
            SettingsPages.sidebarItems.contains { $0.id == SettingsPages.privacyID },
            "Privacy is not offered in the settings sidebar"
        )
        XCTAssertTrue(
            definition.searchableText.localizedCaseInsensitiveContains("keychain"),
            "searching the settings sidebar for a credential store does not find this page"
        )
    }

    /// Caught by looking at a render, not by an assertion anyone would have written first: two
    /// of the informational rows wrapped into a column a third of the card wide while their
    /// longer siblings filled it, because the horizontal stack left its slack unassigned. The
    /// numbers below are deliberately loose — this pins "uses the width it was given", not a
    /// particular wrap.
    func testEveryWrappingDetailUsesTheWidthItIsGiven() throws {
        let controller = page(reader())
        let cards = descendants(in: controller.view).compactMap { $0 as? SettingsCard }
        // A floor, not an equality: this guards against measuring an empty page, and a page
        // gaining a card is not a reason for a layout test to fail. The `measured` count below
        // is what actually proves something was inspected.
        XCTAssertGreaterThanOrEqual(cards.count, 3, "the page lost the cards this measures")

        var measured = 0
        for card in cards {
            let details = descendants(in: card)
                .compactMap { $0 as? NSTextField }
                .filter { $0.stringValue.count > 80 }

            for field in details {
                measured += 1
                XCTAssertGreaterThan(
                    field.frame.width,
                    card.frame.width * 0.6,
                    "\"\(field.stringValue.prefix(40))…\" wrapped into a narrow column while "
                        + "the rest of its row sat empty"
                )
            }
        }
        XCTAssertGreaterThan(measured, 5, "too little wrapping text found to be measuring much")
    }

    /// The render exists so appearance gets reviewed; a fixture shorter than the page turns it
    /// into a review of the top two thirds. Adding a card without raising the height fails here
    /// rather than quietly shipping an unreviewed row — which is exactly what happened when the
    /// "Leaving This Mac" card was added and the 1100pt host cropped its last two rows.
    func testTheRenderCoversTheWholePage() throws {
        let controller = page(reader())
        let cards = descendants(in: controller.view).compactMap { $0 as? SettingsCard }
        let last = try XCTUnwrap(cards.last, "the page has no cards")

        let bottom = last.convert(last.bounds, to: controller.view).maxY
        XCTAssertLessThanOrEqual(
            bottom,
            Self.fixtureHeight,
            "the page is \(Int(bottom))pt tall but the render host is "
                + "\(Int(Self.fixtureHeight))pt — raise fixtureHeight or the bottom rows are "
                + "never in the picture"
        )
    }

    func testThePageStaysInsideTheThemeBoundary() {
        let controller = page(reader())
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }

    func testTheStatusIndicatorFollowsALiveThemeSwitch() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let controller = page(reader(accessibility: true))

        let glyph = try XCTUnwrap(
            ([try row(.accessibility, in: controller)]
                + descendants(in: try row(.accessibility, in: controller)))
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "●" },
            "the row has no status indicator"
        )
        let underCyberpunk = try XCTUnwrap(glyph.textColor?.usingColorSpace(.sRGB))

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        AppThemeRefresh.repaint(controller.view)
        let underSwiss = try XCTUnwrap(glyph.textColor?.usingColorSpace(.sRGB))

        XCTAssertNotEqual(
            underCyberpunk,
            underSwiss,
            "the status indicator kept its old theme's colour through a live switch"
        )
    }

    // MARK: - Rendered State

    /// Whether four permission rows read as a scannable list or as a wall of grey is not a claim
    /// any constraint assertion settles. `THREADING_RENDER_OUT` redirects the output.
    func testPrivacyPageRendersInBothAppearances() throws {
        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let output {
            try FileManager.default.createDirectory(
                at: output,
                withIntermediateDirectories: true
            )
        }

        for (name, appearanceName) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", .darkAqua)
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var png: Data?

            appearance.performAsCurrentDrawingAppearance {
                let controller = self.page(
                    self.reader(
                        accessibility: true,
                        screenRecording: false,
                        notifications: .allowed
                    ),
                    height: Self.fixtureHeight
                )
                let host = NSView(frame: controller.view.frame)
                controller.view.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(controller.view)
                NSLayoutConstraint.activate([
                    controller.view.topAnchor.constraint(equalTo: host.topAnchor),
                    controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
                ])
                host.appearance = appearance
                controller.view.appearance = appearance
                host.wantsLayer = true
                host.layer?.backgroundColor = Design.Surface.ground.cgColor
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()

                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    return
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                png = rep.representation(using: .png, properties: [:])
            }

            let rendered = try XCTUnwrap(png, "the \(name) page produced no image")
            XCTAssertGreaterThan(rendered.count, 20_000, "\(name) privacy page rendered empty")

            let attachment = XCTAttachment(data: rendered, uniformTypeIdentifier: "public.png")
            attachment.name = "privacy-settings-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)

            if let output {
                try rendered.write(
                    to: output.appendingPathComponent("privacy-settings-\(name).png")
                )
            }
        }
    }

    // MARK: - Claude Keychain Row

    /// A page whose keychain answers are all stated by the test, on a defaults suite that is
    /// not the developer's own — the same hermetic rules as `reader`, for the same reason.
    private func keychainPage(
        enabled: Bool = false,
        accounts: [AgentAccount] = [],
        availability:
            @escaping @Sendable (String) -> ClaudeKeychainCredentials.Availability = { _ in .missing },
        grant: @escaping @Sendable (String) -> Bool = { _ in
            XCTFail("nothing here may request keychain access")
            return false
        },
        prefetch: @escaping () -> Void = {},
        suiteName: String = "privacy-keychain-tests-\(UUID().uuidString)"
    ) throws -> (page: PrivacyPreferencesViewController, settings: AppSettings, cleanup: () -> Void) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(defaults: defaults)
        settings.readsClaudeLoginFromKeychain = enabled

        let controller = PrivacyPreferencesViewController(
            reader: reader(),
            settings: settings,
            claudeAccounts: { accounts },
            keychainAvailability: availability,
            keychainGrant: grant,
            prefetchUsage: prefetch
        )
        controller.view.frame = NSRect(
            x: 0, y: 0, width: 640, height: Self.fixtureHeight
        )
        controller.view.layoutSubtreeIfNeeded()

        return (controller, settings, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func toggle(in page: PrivacyPreferencesViewController) throws -> ThemedToggle {
        let toggles = descendants(of: page.view).compactMap { $0 as? ThemedToggle }
        return try XCTUnwrap(toggles.first, "the live-usage row carries the page's one toggle")
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Off by default: reading someone else's credential is opt-in however good the reason.
    func testKeychainReadingIsOffByDefault() throws {
        let (page, settings, cleanup) = try keychainPage()
        defer { cleanup() }

        XCTAssertFalse(settings.readsClaudeLoginFromKeychain)
        XCTAssertEqual(try toggle(in: page).state, .off)
    }

    /// Turning it on records the choice and asks for exactly the grants that are missing —
    /// an account already granted, or with no keychain login at all, gets no prompt.
    func testEnablingGrantsOnlyTheLoginsThatNeedIt() throws {
        let granted = account(handle: "claude", path: "/fixtures/claude")
        let ungranted = account(handle: "claude-two", path: "/fixtures/claude-two")
        let absent = account(handle: "claude-three", path: "/fixtures/claude-three")

        var requested: [String] = []
        let asked = expectation(description: "grant flow ran")

        let (page, settings, cleanup) = try keychainPage(
            accounts: [granted, ungranted, absent],
            availability: { path in
                switch path {
                case granted.configPath: return .granted
                case ungranted.configPath: return .needsGrant
                default: return .missing
                }
            },
            grant: { path in
                requested.append(path)
                return true
            },
            prefetch: { asked.fulfill() }
        )
        defer { cleanup() }

        let control = try toggle(in: page)
        control.state = .on
        control.sendAction(control.action, to: control.target)

        wait(for: [asked], timeout: 5)
        XCTAssertTrue(settings.readsClaudeLoginFromKeychain)
        XCTAssertEqual(
            requested,
            [ungranted.configPath],
            "only the login that needed a grant may be asked for one"
        )
    }

    /// Turning it off is only the bit — no keychain traffic of any kind. The page's initial
    /// refresh probes legitimately (the status line has to say where the grant stands), so the
    /// prohibition starts at the flip, not at the build.
    func testDisablingTouchesNothing() throws {
        let initialProbe = expectation(description: "the on-state page probed once")
        initialProbe.assertForOverFulfill = false
        nonisolated(unsafe) var flipped = false

        let (page, settings, cleanup) = try keychainPage(
            enabled: true,
            accounts: [account(handle: "claude", path: "/fixtures/claude")],
            availability: { _ in
                XCTAssertFalse(flipped, "switching off must not probe the keychain")
                initialProbe.fulfill()
                return .granted
            }
        )
        defer { cleanup() }
        wait(for: [initialProbe], timeout: 5)

        flipped = true
        let control = try toggle(in: page)
        control.state = .off
        control.sendAction(control.action, to: control.target)

        XCTAssertFalse(settings.readsClaudeLoginFromKeychain)
    }

    /// The status sentence, at each of its three truths.
    func testKeychainStatusNamesWhatIsActuallyReadable() {
        XCTAssertEqual(
            PrivacyPreferencesViewController.keychainStatus(for: []),
            "On — no Claude sign-in found in the keychain."
        )
        XCTAssertEqual(
            PrivacyPreferencesViewController.keychainStatus(for: [.missing, .missing]),
            "On — no Claude sign-in found in the keychain."
        )
        XCTAssertEqual(
            PrivacyPreferencesViewController.keychainStatus(for: [.granted, .granted, .missing]),
            "On — reading 2 of 2 logins."
        )
        XCTAssertEqual(
            PrivacyPreferencesViewController.keychainStatus(for: [.granted, .needsGrant]),
            "On — reading 1 of 2 logins. Toggle off and on to be asked again for the rest."
        )
    }

    private func account(handle: String, path: String) -> AgentAccount {
        AgentAccount(
            provider: .claude,
            handle: .named(handle),
            configPath: path
        )
    }
}
