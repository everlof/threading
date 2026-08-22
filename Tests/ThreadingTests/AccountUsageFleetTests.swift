import AppKit
import XCTest
@testable import Threading

@MainActor
final class AccountUsageFleetTests: XCTestCase {
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
            item("dblock", fraction: 0.02, resetsIn: 14_100),
            item("vlundborg", fraction: 0.26, resetsIn: 6 * 86_400),
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
