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

    /// Capture the popup through its real chrome and toolbar placement in the main shell.
    func testRendersNativeGrantInMainWindowPopover() throws {
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"])
        let previousTheme = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previousTheme) }
        for (name, theme, appearanceName) in [
            ("system-light", AppTheme.system, NSAppearance.Name.aqua),
            ("system-dark", AppTheme.system, NSAppearance.Name.darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, NSAppearance.Name.darkAqua)
        ] {
            AppThemeLibrary.apply(theme)
            let fixture = try makeFixture()
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

    private func makeFixture(onRefresh: @escaping () -> Void = {}) throws -> Fixture {
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
            windows: [AccountUsage.Window(
                id: "5h", label: "5-hour", fraction: 0.51,
                resetsAt: now.addingTimeInterval(3_600), windowDuration: 18_000
            )],
            planLabel: nil,
            observedAt: now,
            source: .profileSnapshot
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
