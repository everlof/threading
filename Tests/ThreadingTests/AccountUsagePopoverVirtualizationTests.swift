import AppKit
import XCTest
@testable import Threading

/// A provider may report a model-scoped limit for every model it exposes. The account popover
/// keeps the complete value inventory, but only its bounded viewport may own native bar rows.
@MainActor
final class AccountUsagePopoverVirtualizationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testProviderWindowsMaterializeOnlyInsideThePopoverViewport() throws {
        let account = fixtureAccount
        var reading = fixtureReading(count: 2_000, fractionOffset: 0)
        let controller = AccountUsagePopoverViewController(
            account: account,
            isEmbedded: true,
            readingProvider: { _ in reading }
        )
        let host = laidOut(controller.view, width: UsagePopoverDefaults.contentWidth, height: 360)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        controller.scrollWindowToVisibleForTesting(1_800)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.virtualWindowCountForTesting, 2_001)
        XCTAssertGreaterThan(controller.materializedWindowCountForTesting, 0)
        XCTAssertLessThan(
            controller.materializedWindowCountForTesting,
            40,
            "the popover retained provider windows that cannot contribute pixels"
        )

        let origin = controller.windowScrollOriginForTesting
        XCTAssertGreaterThan(origin.y, 0)
        reading = fixtureReading(count: 2_000, fractionOffset: 0.1)
        controller.refreshForTesting()
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.windowScrollOriginForTesting.x, origin.x, accuracy: 0.5)
        XCTAssertEqual(controller.windowScrollOriginForTesting.y, origin.y, accuracy: 0.5)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }

    /// The production controller at its shipping width, scrolled into a provider-sized model
    /// inventory. Both appearances exercise the fixed header/footer around the virtual viewport.
    func testRendersVirtualAccountUsagePopoverToImages() throws {
        guard let directoryPath = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] else {
            throw XCTSkip("Set THREADING_RENDER_OUT to capture account usage popover evidence")
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(.system)
        defer { AppThemeLibrary.apply(previousTheme) }

        for (name, appearanceName) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", NSAppearance.Name.darkAqua)
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                let controller = AccountUsagePopoverViewController(
                    account: fixtureAccount,
                    readingProvider: { _ in self.fixtureReading(count: 30, fractionOffset: 0) }
                )
                let host = laidOut(controller.view, width: UsagePopoverDefaults.width, height: 400)
                let window = NSWindow(
                    contentRect: host.bounds,
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.appearance = appearance
                controller.view.appearance = appearance
                controller.scrollWindowToVisibleForTesting(18)
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()
                data = png(of: host)
                window.close()
                XCTAssertEqual(ThemeBoundaryAudit.violations(in: host), [])
            }
            let filename = "account-usage-window-popover-\(name).png"
            try XCTUnwrap(data, "Failed to render \(filename)").write(
                to: directory.appendingPathComponent(filename)
            )
        }
    }

    private var fixtureAccount: AgentAccount {
        AgentAccount(
            provider: .codex,
            handle: AccountHandle(storedName: "virtual-popover"),
            configPath: "/tmp/virtual-popover",
            displayName: "Provider Scale"
        )
    }

    private func fixtureReading(
        count: Int,
        fractionOffset: Double
    ) -> AccountUsageReading {
        var usage = AccountUsage(
            windows: [window(index: -1, fraction: 0.31 + fractionOffset)],
            planLabel: "Pro",
            observedAt: now,
            source: .api
        )
        usage.modelWindows = (0..<count).map { index in
            window(index: index, fraction: Double(index % 80) / 100 + fractionOffset)
        }
        return .current(usage)
    }

    private func window(index: Int, fraction: Double) -> AccountUsage.Window {
        let name = index < 0 ? "5h" : "model-\(index)"
        return AccountUsage.Window(
            id: name,
            label: index < 0 ? "5-hour" : "Weekly · Model \(index)",
            fraction: min(fraction, 1),
            resetsAt: now.addingTimeInterval(7_200 + Double(max(index, 0))),
            windowDuration: index < 0 ? 5 * 3_600 : 7 * 86_400,
            scopeName: index < 0 ? nil : name
        )
    }

    private func laidOut(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let host = ThemedSurfaceView()
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.applySurface(fill: Design.Surface.elevated, radius: .fixed(0))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func png(of view: NSView) -> Data? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }
}
