import AppKit
import XCTest
@testable import Threading

@MainActor
final class AccountIdentityMenuLayoutTests: HostedStoreTestCase {
    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    func testOverflowReadingsAndResetRemainAvailableAtLargeTextSizes() throws {
        for textSize in [AppTextSize.standard, .extraLarge] {
            try DesignSettings.withSettings(StubDesignSettings(appTextSize: textSize)) {
                for width: CGFloat in [440, 320, 180] {
                    let original = menuEntries()
                    let fitted = ThemedMenuMetrics.entries(original, fitting: width)
                    let accounts = fitted.compactMap(\.item).prefix(3)
                    for (account, source) in zip(accounts, original.compactMap(\.item).prefix(3)) {
                        for metric in source.metrics {
                            XCTAssertTrue(account.spokenSummary.contains("\(metric.label) \(metric.value)"))
                        }
                        XCTAssertTrue(account.spokenSummary.contains("30d · 29d 23h"))
                    }
                    let monthly = try XCTUnwrap(accounts.last)
                    XCTAssertTrue(monthly.spokenSummary.contains("30d 42%"))
                    XCTAssertEqual(
                        fitted.compactMap(\.item).map(\.title),
                        original.compactMap(\.item).map(\.title)
                    )
                    XCTAssertEqual(
                        ThemedMenuMetrics.entries(fitted, fitting: width).compactMap(\.item).map(\.spokenSummary),
                        fitted.compactMap(\.item).map(\.spokenSummary),
                        "a second projection must not duplicate overflow readings"
                    )
                }
            }
        }
    }

    func testUsageColumnsCannotEraseAccountOrActionTitles() throws {
        for theme in [AppTheme.system, AppThemeStyles.cyberpunk, AppThemeStyles.win98] {
            AppThemePalette.set(theme)
            for width: CGFloat in [440, 320] {
                let entries = menuEntries()
                let blank = entries.map { entry -> ThemedMenuEntry in
                    guard let item = entry.item else { return entry }
                    var empty = ThemedMenuItem(title: "", image: item.image)
                    empty.metrics = item.metrics
                    empty.trailingDetail = item.trailingDetail
                    return .item(empty)
                }
                let surface = ThemedMenuReferenceFixture.make(
                    entries: entries, size: NSSize(width: width, height: 420)
                )
                let emptySurface = ThemedMenuReferenceFixture.make(
                    entries: blank, size: NSSize(width: width, height: 420)
                )
                let rows = descendants(surface).filter { $0.accessibilityRole() == .menuItem }
                let emptyRows = descendants(emptySurface).filter { $0.accessibilityRole() == .menuItem }
                XCTAssertEqual(rows.count, 5)
                for (row, emptyRow) in zip(rows, emptyRows) {
                    let actual = try bitmap(of: row)
                    let empty = try bitmap(of: emptyRow)
                    // Compare title ink with the identical unnamed row. Icons, bars, numbers
                    // and chrome cannot make this pass when the words have disappeared.
                    var differences = 0
                    for x in 0..<min(actual.pixelsWide, empty.pixelsWide) {
                        for y in 0..<min(actual.pixelsHigh, empty.pixelsHigh) {
                            if actual.colorAt(x: x, y: y) != empty.colorAt(x: x, y: y) {
                                differences += 1
                            }
                        }
                    }
                    XCTAssertGreaterThan(
                        differences, 0,
                        "\(theme.name), \(width)pt: \(row.accessibilityTitle() ?? "") drew no title"
                    )
                }
            }
        }
    }

    func testRendersAccountIdentityMenuInShippingShell() throws {
        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ThreadingRenders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1120, height: 820))
        let root = try XCTUnwrap(window.contentView)
        let composer = controller.containerViewController.composerViewController.view
        let source = try XCTUnwrap(descendants(composer).first {
            $0.accessibilityIdentifier() == "composer.session-start.identity"
        })
        let greeting = try XCTUnwrap(descendants(composer).compactMap {
            $0 as? MorphingMultilineTitleLabel
        }.first)
        greeting.setStringValue("What are we building today?", animated: false)

        for theme in [AppTheme.system, AppThemeStyles.cyberpunk, AppThemeStyles.win98] {
            AppThemePalette.set(theme)
            root.appearance = NSAppearance(named: theme == AppThemeStyles.win98 ? .aqua : .darkAqua)
            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()
            let token = ThemedMenuPresenter.present(
                ThemedMenuPresentation(entries: menuEntries(), minimumWidth: 0),
                from: source, selectedEntryIndex: 1,
                onChoose: { _, _ in }, onDismiss: {}
            )
            defer { ThemedMenuPresenter.dismiss(token) }
            markNeedingLayout(root)
            root.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
                to: output.appendingPathComponent("account-identity-menu-\(theme.id.rawValue).png")
            )
        }
    }

    private func menuEntries() -> [ThemedMenuEntry] {
        func account(_ title: String, _ provider: AgentKind, _ windows: [String]) -> ThemedMenuEntry {
            var item = ThemedMenuItem(title: title, image: AccountMarkImage.make(for: provider))
            item.metrics = windows.map {
                ThemedMenuMetric(label: $0, value: "42%", fraction: 0.42)
            }
            item.trailingDetail = "30d · 29d 23h"
            return .item(item)
        }
        return [
            .header("Claude Code"),
            account("Everlof", .claude, ["5h", "7d"]),
            account("Nova Hartley", .claude, ["5h", "7d"]),
            .header("Codex"),
            account("Personal", .codex, ["30d"]),
            .separator,
            .item(ThemedMenuItem(title: "Grok", image: AccountMarkImage.make(for: .grok))),
            .item(ThemedMenuItem(title: "OpenCode", image: AccountMarkImage.make(for: .openCode)))
        ]
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func markNeedingLayout(_ view: NSView) {
        view.needsLayout = true
        view.subviews.forEach(markNeedingLayout)
    }

    private func bitmap(of view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = view.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(view.bounds)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}
