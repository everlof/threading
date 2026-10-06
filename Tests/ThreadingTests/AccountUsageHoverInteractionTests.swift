import AppKit
import XCTest
@testable import Threading

/// Drive the shipping toolbar anchor, customization shell and child popover together. A
/// grant button tested only in its content controller cannot catch dismissal on anchor exit.
@MainActor
final class AccountUsageHoverInteractionTests: HostedStoreTestCase {

    func testHoverGrantCanBeReachedAndClickedInMainWindow() async throws {
        let refreshed = expectation(description: "clicked grant refreshed this account")
        let fixture = try makeFixture { refreshed.fulfill() }
        let panel = try openByHover(fixture)
        defer { fixture.item.configure(account: nil) }
        let tracking = try XCTUnwrap(descendants(in: panel.contentView!).first {
            $0 is HoverTrackingView
        } as? HoverTrackingView)
        let button = try XCTUnwrap(descendants(in: panel.contentView!).first {
            $0.accessibilityIdentifier() == "usage.keychainGrant"
        } as? ThemedButton)

        fixture.item.mouseExited(with: hoverEvent(.mouseExited, in: fixture.window))
        XCTAssertTrue(panel.parent === fixture.window, "leaving the badge dismissed Allow…")
        tracking.mouseEntered(with: hoverEvent(.mouseEntered, in: panel))
        await elapseCloseGrace()
        XCTAssertTrue(panel.parent === fixture.window, "resting on the popup must hold it open")

        let root = try XCTUnwrap(panel.contentView)
        let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        XCTAssertTrue(root.hitTest(button.convert(center, to: root)) === button)
        button.mouseDown(with: try clickEvent(.leftMouseDown, on: button))
        button.mouseUp(with: try clickEvent(.leftMouseUp, on: button))
        await fulfillment(of: [refreshed], timeout: 2)

        tracking.mouseExited(with: hoverEvent(.mouseExited, in: panel))
        await elapseCloseGrace()
        XCTAssertNil(panel.parent, "leaving the popup must still dismiss an unpinned reading")
    }

    func testClickPinsTheSameHoverPopoverUntilEscape() async throws {
        let fixture = try makeFixture()
        let panel = try openByHover(fixture)
        defer { fixture.item.configure(account: nil) }

        XCTAssertTrue(fixture.item.performPrimaryAction())
        XCTAssertTrue(fixture.window.childWindows?.contains(panel) == true)
        fixture.item.mouseExited(with: hoverEvent(.mouseExited, in: fixture.window))
        await elapseCloseGrace()
        XCTAssertTrue(panel.parent === fixture.window, "clicking the badge must keep it pinned")

        panel.cancelOperation(nil)
        XCTAssertNil(panel.parent, "Escape must close the pinned popup")
    }

    func testShortWindowListsFitWithoutScrollingInMainWindowPopover() throws {
        let previousTheme = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previousTheme) }
        for theme in [AppTheme.system, AppThemeStyles.cappuccino, AppThemeStyles.win98] {
            AppThemeLibrary.apply(theme)
            for windowCount in [1, 2] {
                let fixture = try makeFixture(windowCount: windowCount)
                defer { fixture.item.configure(account: nil) }
                let panel = try openByHover(fixture)
                let root = try XCTUnwrap(panel.contentView)
                root.layoutSubtreeIfNeeded()
                let content = try XCTUnwrap((root as? ThemedPopoverChromeView)?.contentView)
                XCTAssertEqual(
                    content.frame.height, content.fittingSize.height, accuracy: 0.5,
                    "the popover must open at its final content height"
                )
                let scroll = try XCTUnwrap(descendants(in: root).first {
                    ($0 as? ThemedScrollView)?.documentView is ThemedTableView
                } as? ThemedScrollView)
                let table = try XCTUnwrap(scroll.documentView as? ThemedTableView)
                XCTAssertEqual(
                    scroll.contentView.bounds.height,
                    table.rect(ofRow: windowCount - 1).maxY,
                    accuracy: 0.5,
                    "a short list must fit its rows without retaining estimated empty space"
                )
                let overflow = max(0, table.frame.height - scroll.contentView.bounds.height)
                XCTAssertEqual(overflow, 0, accuracy: 0.5,
                               "\(theme.id.rawValue), \(windowCount) windows: rows \(table.frame.height), viewport \(scroll.contentView.bounds.height)")
                XCTAssertTrue(scroll.verticalScroller?.isHidden == true,
                              "a list that fits must not keep a scrollbar")
            }
        }
    }

    /// Capture the popup through its real chrome and toolbar placement in the main shell.
    func testRendersNativeGrantInMainWindowPopover() throws {
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"])
        let previousTheme = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previousTheme) }
        for (name, theme, appearanceName, windowCount) in [
            ("system-light", AppTheme.system, NSAppearance.Name.aqua, 1),
            ("system-dark", AppTheme.system, NSAppearance.Name.darkAqua, 1),
            ("cyberpunk", AppThemeStyles.cyberpunk, NSAppearance.Name.darkAqua, 1),
            ("cappuccino-two-windows", AppThemeStyles.cappuccino, NSAppearance.Name.darkAqua, 2)
        ] {
            AppThemeLibrary.apply(theme)
            let fixture = try makeFixture(windowCount: windowCount)
            fixture.window.appearance = NSAppearance(named: appearanceName)
            AppThemeRefresh.repaint(fixture.window.contentView!)
            // The theme sweep refreshes the reading before the pointer opens it.
            fixture.item.isHidden = false
            let panel = try openByHover(fixture)
            defer { fixture.item.configure(account: nil) }
            let root = try XCTUnwrap(panel.contentView)
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(ThemeBoundaryAudit.violations(in: root), [])
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: directory).appendingPathComponent(
                    "account-usage-hover-grant-\(name).png"
                )
            )
        }
    }

    private struct Fixture {
        let window: NSWindow
        let item: AccountUsageItemView
    }

    private func makeFixture(
        windowCount: Int = 1,
        onRefresh: @escaping () -> Void = {}
    ) throws -> Fixture {
        let suite = "account-usage-hover-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        settings.readsClaudeLoginFromKeychain = true
        let account = AgentAccount(
            provider: .claude,
            handle: AccountHandle(storedName: suite),
            configPath: "/fixtures/\(suite)",
            displayName: "Waiting login"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = AccountUsage(
            windows: (0..<windowCount).map { index in
                AccountUsage.Window(
                    id: index == 0 ? "5h" : "7d",
                    label: index == 0 ? "5-hour" : "Weekly",
                    fraction: index == 0 ? (windowCount == 1 ? 0.51 : 0.97) : 0.90,
                    resetsAt: now.addingTimeInterval(3_600),
                    windowDuration: index == 0 ? 18_000 : 604_800
                )
            },
            planLabel: nil,
            observedAt: now,
            source: windowCount == 1 ? .profileSnapshot : .localCache
        )
        AccountUsageService.shared.acceptAuthoritative(usage, for: account)
        let access = ClaudeKeychainAccess(
            settings: settings,
            observedAvailability: { _ in .needsGrant },
            probe: { _ in .needsGrant },
            grant: { _ in true },
            refreshUsage: {
                XCTAssertEqual($0.id, account.id)
                onRefresh()
            }
        )
        let item = AccountUsageItemView(
            customizationLookup: { _ in .empty },
            usagePopoverContentProvider: {
                AccountUsagePopoverViewController(
                    account: $0, isEmbedded: true,
                    readingProvider: { _ in .current(usage) },
                    limitsProvider: { _ in [] },
                    nowProvider: { now },
                    keychainAccess: access
                )
            }
        )
        let shell = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(shell.window)
        window.setContentSize(NSSize(width: 1_100, height: 700))
        let original = shell.accountUsageItemView
        let stack = try XCTUnwrap(shell.paneHeaderStackView)
        let index = try XCTUnwrap(stack.arrangedSubviews.firstIndex(of: original))
        stack.removeArrangedSubview(original)
        original.removeFromSuperview()
        stack.insertArrangedSubview(item, at: index)
        shell.materializedAccountUsageItemView = item
        item.configure(account: account)
        window.contentView?.layoutSubtreeIfNeeded()
        return Fixture(window: window, item: item)
    }

    private func openByHover(_ fixture: Fixture) throws -> NSWindow {
        fixture.item.mouseEntered(with: hoverEvent(.mouseEntered, in: fixture.window))
        return try XCTUnwrap(fixture.window.childWindows?.last)
    }

    private func elapseCloseGrace() async {
        try? await Task.sleep(for: .seconds(AccountUsageItemDefaults.popoverPolicy.closeGrace + 0.1))
    }

    private func hoverEvent(_ type: NSEvent.EventType, in window: NSWindow) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        )!
    }

    private func clickEvent(_ type: NSEvent.EventType, on button: ThemedButton) throws -> NSEvent {
        let window = try XCTUnwrap(button.window)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }
}
