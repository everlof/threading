import AppKit
import XCTest
import os
@testable import Threading

@MainActor
final class AccountUsageFleetTests: XCTestCase {
    private final class RefreshConcurrencyProbe: @unchecked Sendable {
        private struct State {
            var active = 0
            var peak = 0
            var started = 0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var peak: Int { state.withLock { $0.peak } }
        var started: Int { state.withLock { $0.started } }

        func fetch(_ account: AgentAccount) async throws -> AccountUsage {
            state.withLock { value in
                value.active += 1
                value.started += 1
                value.peak = max(value.peak, value.active)
            }
            defer { state.withLock { $0.active -= 1 } }
            try await Task.sleep(nanoseconds: 20_000_000)
            throw UsageFetchError.noCredential("fixture")
        }
    }

    private struct RenderFixture {
        let name: String
        let theme: AppTheme
        let appearance: NSAppearance.Name
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSummaryCountsAccountsWithoutAveragingUnlikeWindows() {
        let items = [
            item("ready", fraction: 0.20, resetsIn: 7_200),
            item("constrained", fraction: UsageDefaults.warningFraction, resetsIn: 3_600),
            item("unknown-value", fraction: nil, resetsIn: 1_800),
            item("not-fetched", reading: .notFetched)
        ]

        let summary = AccountUsageFleetSummary(items: items, now: now)

        XCTAssertEqual(summary.accountCount, 4)
        XCTAssertEqual(summary.readyCount, 1)
        XCTAssertEqual(summary.constrainedCount, 1)
        XCTAssertEqual(summary.unknownCount, 2)
        XCTAssertEqual(summary.nextReset, now.addingTimeInterval(1_800))
    }

    func testOrderingKeepsCurrentAccountFirstThenUsesStableProviderAndNameOrder() {
        let current = item("z-current", provider: .codex, isCurrent: true)
        let claudeB = item("b", provider: .claude)
        let claudeA = item("a", provider: .claude)
        let codexA = item("a-codex", provider: .codex)

        let ordered = AccountUsageFleetView.stablyOrdered([
            codexA, claudeB, current, claudeA
        ])

        XCTAssertEqual(ordered.map(\.account.id), [
            current.account.id,
            claudeA.account.id,
            claudeB.account.id,
            codexA.account.id
        ])
    }

    func testFleetViewportStaysBoundedAsAccountCountGrows() {
        let fleet = AccountUsageFleetView(maximumHeight: 260)
        fleet.show((0..<120).map { index in
            item("account-\(index)", fraction: Double(index % 70) / 100)
        }, at: now)

        XCTAssertEqual(fleet.itemCountForTesting, 120)
        XCTAssertEqual(fleet.viewportHeightForTesting, 260)

        fleet.frame = NSRect(x: 0, y: 0, width: 380, height: 320)
        fleet.layoutSubtreeIfNeeded()
        XCTAssertLessThan(fleet.visibleCellCountForTesting, fleet.itemCountForTesting)
    }

    func testPinnedPopoverKeepsVerticalScrollingInsteadOfHandingItToAMissingPage() {
        let controller = AccountUsageFleetPopoverViewController(
            currentAccountID: nil,
            handoffAccountIDs: [],
            accountsProvider: { [] },
            readingProvider: { _ in .notFetched },
            refreshProvider: { _ in },
            nowProvider: { self.now }
        )

        _ = controller.view

        XCTAssertEqual(controller.fleetVerticalScrollHandoffForTesting, .never)
    }

    func testSettingsFleetUsesThePageAsItsOnlyVerticalScrollOwner() {
        let fleet = AccountUsageFleetView(scrollHost: .nestedPage)

        XCTAssertFalse(fleet.hasInternalScrollViewForTesting)
        XCTAssertEqual(fleet.verticalScrollHandoffForTesting, .always)
    }

    func testSettingsFleetContributesItsCompleteLogicalHeightInsteadOfClippingCards() {
        let fleet = AccountUsageFleetView(scrollHost: .nestedPage)
        fleet.show((0..<5).map { index in
            item("settings-\(index)", fraction: Double(index + 1) / 10)
        }, at: now)

        XCTAssertGreaterThan(
            fleet.viewportHeightForTesting,
            Design.AccountUsageFleet.settingsMaximumHeight,
            "the Settings account run was capped into a second viewport"
        )
    }

    func testSettingsFleetVirtualizesAgainstThePageViewport() throws {
        let fleet = AccountUsageFleetView(scrollHost: .nestedPage)
        fleet.show((0..<120).map { index in
            item("settings-\(String(format: "%03d", index))", fraction: 0.20)
        }, at: now)

        let page = try XCTUnwrap(SettingsUI.page([
            SettingsUI.section("Current capacity", fleet, localizesTitle: false)
        ]) as? ThemedScrollView)
        let viewport = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(
            contentRect: viewport,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = page
        page.layoutSubtreeIfNeeded()

        // The embedded table waits for this real outer clip before binding. Let that deferred
        // bind run, just as the production Settings shell does after installing its page.
        let didBind = expectation(description: "bind behind Settings page viewport layout")
        DispatchQueue.main.async { didBind.fulfill() }
        wait(for: [didBind], timeout: 1)
        page.layoutSubtreeIfNeeded()
        page.displayIfNeeded()

        let initialIDs = Set(fleet.materializedAccountIDsForTesting)
        XCTAssertEqual(fleet.itemCountForTesting, 120)
        XCTAssertGreaterThan(initialIDs.count, 0)
        XCTAssertLessThan(initialIDs.count, fleet.itemCountForTesting)

        page.contentView.scroll(to: NSPoint(
            x: 0,
            y: fleet.viewportHeightForTesting / 2
        ))
        page.reflectScrolledClipView(page.contentView)
        page.layoutSubtreeIfNeeded()
        page.displayIfNeeded()

        let didScroll = expectation(description: "recycle fleet rows at page scroll position")
        DispatchQueue.main.async { didScroll.fulfill() }
        wait(for: [didScroll], timeout: 1)
        page.layoutSubtreeIfNeeded()
        page.displayIfNeeded()

        let deepIDs = Set(fleet.materializedAccountIDsForTesting)
        XCTAssertGreaterThan(deepIDs.count, 0)
        XCTAssertLessThan(deepIDs.count, fleet.itemCountForTesting)
        XCTAssertTrue(initialIDs.isDisjoint(with: deepIDs))
        withExtendedLifetime(window) {}
    }

    func testFleetUsesOneFooterLegendForItsRepeatedCustomLimitMarkers() {
        let capped = item("capped", fraction: 0.47)
        let fleet = AccountUsageFleetView(limitsProvider: { accountID in
            accountID == capped.account.id
                ? [CustomLimit(windowID: "5h", bound: 0.5)]
                : []
        })

        fleet.show([capped], at: now)
        XCTAssertTrue(fleet.showsLimitLegendForTesting)

        fleet.show([item("plain", fraction: 0.47)], at: now)
        XCTAssertFalse(fleet.showsLimitLegendForTesting)
    }

    func testOneReadingUpdatePreservesFleetOrderAndUpdatesOnlyItsAggregateContribution() {
        let fleet = AccountUsageFleetView(maximumHeight: 260)
        let initial = (0..<120).map { index in
            item("account-\(index)", fraction: 0.20, resetsIn: 7_200 + Double(index))
        }
        fleet.show(initial, at: now)
        let order = fleet.orderedAccountIDsForTesting
        let target = initial[73]
        let replacement = AccountUsageReading.current(AccountUsage(
            windows: [AccountUsage.Window(
                id: "5h",
                label: "5-hour",
                fraction: 0.94,
                resetsAt: now.addingTimeInterval(300),
                windowDuration: 5 * 3_600
            )],
            planLabel: "Pro",
            observedAt: now,
            source: .api
        ))

        XCTAssertTrue(fleet.update(reading: replacement, for: target.account.id))

        XCTAssertEqual(fleet.orderedAccountIDsForTesting, order)
        XCTAssertEqual(fleet.summaryForTesting.readyCount, 119)
        XCTAssertEqual(fleet.summaryForTesting.constrainedCount, 1)
        XCTAssertEqual(fleet.summaryForTesting.nextReset, now.addingTimeInterval(300))
    }

    func testAllAccountRefreshUsesABoundedProviderWorkPool() async {
        let concurrency = 4
        let probe = RefreshConcurrencyProbe()
        let service = AccountUsageService(
            maximumConcurrentRefreshes: concurrency,
            observesActivity: false,
            fetcher: { try await probe.fetch($0) }
        )
        let accounts = (0..<120).map { index in
            AgentAccount(
                provider: .claude,
                handle: AccountHandle(storedName: "bounded-\(index)"),
                configPath: "/tmp/bounded-\(index)",
                displayName: "Account \(index)"
            )
        }
        let settled = expectation(description: "every queued refresh settled")
        settled.expectedFulfillmentCount = accounts.count

        for account in accounts {
            service.refresh(account, force: true) { settled.fulfill() }
        }
        await fulfillment(of: [settled], timeout: 10)

        XCTAssertEqual(probe.started, accounts.count)
        XCTAssertEqual(probe.peak, concurrency)
    }

    func testPopoverUsageEventReadsOnlyTheChangedIdentity() {
        let accounts = fixtureAccounts(count: 120, prefix: "popover")
        var reads: [AccountID] = []
        let controller = AccountUsageFleetPopoverViewController(
            currentAccountID: nil,
            handoffAccountIDs: [],
            accountsProvider: { accounts },
            readingProvider: { account in
                reads.append(account.id)
                return .notFetched
            },
            refreshProvider: { _ in },
            nowProvider: { self.now }
        )
        _ = controller.view
        reads.removeAll()

        NotificationCenter.default.post(AccountUsageDidChange(accountID: accounts[73].id))

        XCTAssertEqual(reads, [accounts[73].id])
    }

    func testUsageSettingsEventReadsOnlyTheChangedIdentity() {
        let accounts = fixtureAccounts(count: 120, prefix: "settings")
        var reads: [AccountID] = []
        let controller = UsagePreferencesViewController(
            accountsProvider: { accounts },
            readingProvider: { account in
                reads.append(account.id)
                return .notFetched
            },
            refreshProvider: { _, _ in }
        )
        _ = controller.view
        reads.removeAll()

        NotificationCenter.default.post(AccountUsageDidChange(accountID: accounts[41].id))

        XCTAssertEqual(reads, [accounts[41].id])
    }

    func testUsageSettingsPlacesAnalyticsBeforeTheVariableAccountFleet() throws {
        let controller = UsagePreferencesViewController(
            accountsProvider: { self.fixtureAccounts(count: 5, prefix: "order") },
            readingProvider: { _ in .notFetched },
            refreshProvider: { _, _ in }
        )
        let root = controller.view
        let stacks = descendants(of: root).compactMap { $0 as? NSStackView }
        let body = try XCTUnwrap(stacks.first { stack in
            stack.arrangedSubviews.contains { $0 is UsageDashboardView }
                && stack.arrangedSubviews.contains { section in
                    descendants(of: section).contains { $0 is AccountUsageFleetView }
                }
        })
        let dashboardIndex = try XCTUnwrap(
            body.arrangedSubviews.firstIndex { $0 is UsageDashboardView }
        )
        let capacityIndex = try XCTUnwrap(
            body.arrangedSubviews.firstIndex { section in
                descendants(of: section).contains { $0 is AccountUsageFleetView }
            }
        )

        XCTAssertLessThan(dashboardIndex, capacityIndex)
    }

    func testOptionClickSelectsAllAccountsWithoutTakingOverControlClick() {
        XCTAssertEqual(AccountUsageItemView.clickPresentation(for: []), .currentAccount)
        XCTAssertEqual(
            AccountUsageItemView.clickPresentation(for: [.control]),
            .currentAccount
        )
        XCTAssertEqual(
            AccountUsageItemView.clickPresentation(for: [.option]),
            .allAccounts
        )
        XCTAssertEqual(
            AccountUsageItemView.clickPresentation(for: [.option, .shift]),
            .allAccounts
        )
    }

    func testRendersPinnedAllAccountFleetPopoverSurface() throws {
        let directory = renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        let items = [
            item("Default", fraction: 0.75, isCurrent: true),
            item("nhartley", fraction: 0.02, resetsIn: 14_100),
            item("ikeller", fraction: 0.26, resetsIn: 6 * 86_400),
            item("Work", provider: .codex, fraction: 0.41),
            item("Personal", provider: .codex, fraction: 0.94)
        ]
        let currentID = items[0].account.id
        let handoffIDs = Set(items.dropFirst().prefix(2).map(\.account.id))
        let fixtures = [
            RenderFixture(name: "system-dark", theme: .system, appearance: .darkAqua),
            RenderFixture(
                name: "cyberpunk",
                theme: AppThemeStyles.cyberpunk,
                appearance: .darkAqua
            )
        ]

        for fixture in fixtures {
            let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                AppThemePalette.set(fixture.theme)
                let controller = AccountUsageFleetPopoverViewController(
                    currentAccountID: currentID,
                    handoffAccountIDs: handoffIDs,
                    accountsProvider: { items.map(\.account) },
                    readingProvider: { account in
                        items.first { $0.account.id == account.id }?.reading ?? .notFetched
                    },
                    refreshProvider: { _ in },
                    limitsProvider: { accountID in
                        accountID == currentID
                            ? [CustomLimit(windowID: "5h", bound: 0.5)]
                            : []
                    },
                    nowProvider: { self.now }
                )
                let content = controller.view
                let host = NSView(frame: NSRect(
                    origin: .zero,
                    size: controller.preferredContentSize
                ))
                host.appearance = appearance
                // The real popover chrome provides the opaque elevated surface below this
                // controller. System's panel token is intentionally a translucent ink wash, so
                // rendering it directly over transparency would be a white-on-white falsehood.
                host.applySurface(fill: Design.Surface.elevated, radius: .fixed(0))
                content.appearance = appearance
                content.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(content)
                NSLayoutConstraint.activate([
                    content.topAnchor.constraint(equalTo: host.topAnchor),
                    content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    content.trailingAnchor.constraint(equalTo: host.trailingAnchor)
                ])

                let window = NSWindow(
                    contentRect: host.bounds,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.contentView = host
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()
                // Laying out the virtual table materializes its first viewport of recycled rows.
                // Refresh once more so those newly-created controls inherit the fixture's Dark
                // Aqua appearance just as ThemedPopover does after attaching real chrome.
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()
                data = png(of: host)
                window.close()
            }
            let url = directory.appendingPathComponent(
                "account-usage-fleet-popover-\(fixture.name).png"
            )
            try XCTUnwrap(data, "No fleet popover render for \(fixture.name)").write(to: url)
        }
    }

    private func item(
        _ name: String,
        provider: AgentKind = .claude,
        fraction: Double? = 0.20,
        resetsIn: TimeInterval = 3_600,
        reading: AccountUsageReading? = nil,
        isCurrent: Bool = false
    ) -> AccountUsageFleetItem {
        let account = AgentAccount(
            provider: provider,
            handle: AccountHandle(storedName: name),
            configPath: "/tmp/usage-fleet-\(name)",
            displayName: name
        )
        let resolvedReading = reading ?? .current(AccountUsage(
            windows: [
                AccountUsage.Window(
                    id: "5h",
                    label: "5-hour",
                    fraction: fraction,
                    resetsAt: now.addingTimeInterval(resetsIn),
                    windowDuration: 5 * 3_600
                )
            ],
            planLabel: "Pro",
            observedAt: now,
            source: .api
        ))
        return AccountUsageFleetItem(
            account: account,
            reading: resolvedReading,
            isCurrent: isCurrent,
            allowsHandoff: false
        )
    }

    private func fixtureAccounts(count: Int, prefix: String) -> [AgentAccount] {
        (0..<count).map { index in
            AgentAccount(
                provider: .claude,
                handle: AccountHandle(storedName: "\(prefix)-\(index)"),
                configPath: "/tmp/\(prefix)-\(index)",
                displayName: "Account \(index)"
            )
        }
    }

    private func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants(of:))
    }

    private var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingUsageFleetRenders", isDirectory: true)
    }

    private func png(of view: NSView) -> Data? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }
}
