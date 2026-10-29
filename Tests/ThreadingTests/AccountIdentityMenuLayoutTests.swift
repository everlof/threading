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
                        // Whether a reading kept its meter or was written into the subtitle,
                        // its number and its countdown are still on the row.
                        for metric in source.metrics {
                            XCTAssertTrue(account.spokenSummary.contains("\(metric.label) \(metric.value)"))
                            XCTAssertTrue(account.spokenSummary.contains(try XCTUnwrap(metric.detail)))
                        }
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

    func testUsageMetersCannotEraseAccountOrActionTitles() throws {
        for theme in [AppTheme.system, AppThemeStyles.cyberpunk, AppThemeStyles.win98] {
            AppThemePalette.set(theme)
            for width: CGFloat in [440, 320] {
                // Both surfaces are made from rows already fitted to this width, so the unnamed
                // copy keeps exactly the named row's meters and subtitle. The floor that decides
                // between them is measured from the names, and a menu with no names would
                // otherwise decide differently — and pass on that difference instead of on ink.
                let entries = ThemedMenuMetrics.entries(menuEntries(), fitting: width)
                let blank = entries.map { entry -> ThemedMenuEntry in
                    guard let item = entry.item else { return entry }
                    var empty = ThemedMenuItem(title: "", subtitle: item.subtitle, image: item.image)
                    if let segments = item.subtitleSegments { empty.setSubtitle(segments) }
                    empty.metrics = item.metrics
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

        let renders: [(AppTheme, NSAppearance.Name, String)] = [
            (.system, .darkAqua, "dark"),
            (.system, .aqua, "light"),
            (AppThemeStyles.cyberpunk, .darkAqua, "dark"),
            (AppThemeStyles.win98, .aqua, "light")
        ]
        for (theme, appearance, tone) in renders {
            AppThemePalette.set(theme)
            root.appearance = NSAppearance(named: appearance)
            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()
            let token = ThemedMenuPresenter.present(
                ThemedMenuPresentation(entries: loginEntries(), minimumWidth: 0),
                from: source, selectedEntryIndex: Self.selectedLogin,
                onChoose: { _, _ in }, onDismiss: {}
            )
            defer { ThemedMenuPresenter.dismiss(token) }
            markNeedingLayout(root)
            root.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
                to: output.appendingPathComponent(
                    "account-identity-menu-\(theme.id.rawValue)-\(tone).png"
                )
            )
        }
    }

    /// Every login's windows keep their own lines at the width the panel is sized to: `5h`
    /// beside the name and `7d` directly under it, on every row, at one x — including the row
    /// whose plan has no 5-hour window, which leaves the top line empty rather than moving its
    /// weekly reading up.
    ///
    /// The reported menu read `5h` at the right of every row and `7d` under every name. The
    /// panel is sized to its widest text plus the readings, and the fitting pass then asked a
    /// 96pt floor of names that needed less — so readings measured to fit were judged not to,
    /// and the second one was written into the subtitle. Short names are the stress, which is
    /// why these are the real ones' lengths, and the text size widens every cell the block is
    /// measured from. No minimum width: the chip's own is narrower than any panel these rows
    /// make, so it would add nothing but a way for the test to pass on borrowed room.
    func testEveryLoginsWindowsKeepTheirLinesAtThePanelsOwnWidth() throws {
        for textSize in [AppTextSize.standard, .extraLarge] {
            try DesignSettings.withSettings(StubDesignSettings(appTextSize: textSize)) {
                let entries = loginEntries()
                let width = ThemedMenuMetrics.width(
                    for: entries, minimum: 0, selectedEntryIndex: Self.selectedLogin
                )
                let fitted = ThemedMenuMetrics.entries(
                    entries, fitting: width, selectedEntryIndex: Self.selectedLogin
                )
                for (source, shown) in zip(entries.compactMap(\.item), fitted.compactMap(\.item)) {
                    XCTAssertEqual(
                        shown.metrics.map(\.label), source.metrics.map(\.label),
                        "\(textSize): \(shown.title) wrote a reading into its subtitle"
                    )
                    XCTAssertEqual(shown.subtitle, source.subtitle)
                }

                let surface = ThemedMenuReferenceFixture.make(
                    entries: entries,
                    size: NSSize(width: width, height: ThemedMenuMetrics.height(for: fitted)),
                    selectedEntryIndex: Self.selectedLogin
                )
                let rows = Self.claudeLogins.map {
                    ThemedMenuReferenceFixture.meterLines(in: surface, entryIndex: $0)
                }
                let codexRows = Self.codexLogins.map {
                    ThemedMenuReferenceFixture.meterLines(in: surface, entryIndex: $0)
                }
                XCTAssertEqual(
                    (rows + codexRows).map { $0.map(\.label) },
                    [["5h", "7d"], ["7d"], ["5h", "7d"], ["5h", "7d"], ["5h", "7d"], ["5h", "7d"],
                     ["7d"], ["5h", "7d"]]
                )

                // One x and one length for every bar in the menu, so they compare by length.
                let bars = (rows + codexRows).flatMap { $0.map(\.barRect) }
                let first = try XCTUnwrap(bars.first)
                for bar in bars {
                    XCTAssertEqual(bar.minX, first.minX, accuracy: 0.01)
                    XCTAssertEqual(bar.width, first.width, accuracy: 0.01)
                }

                // Within a row, the 5-hour meter is on the title's line and the weekly one on
                // the line under it.
                let both = try XCTUnwrap(rows.first { $0.count == 2 })
                let up: CGFloat = surface.isFlipped ? -1 : 1
                XCTAssertGreaterThan(
                    (both[0].barRect.midY - both[1].barRect.midY) * up,
                    ThemedMenuMetrics.metricBarHeight,
                    "the 5h meter must sit above the 7d one"
                )
                // And every row's 7d is on that same second line: consecutive logins' weekly
                // bars are exactly one row apart, so the weekly-only row did not move its
                // reading up beside its name.
                let weekly = rows.compactMap { $0.first { $0.label == "7d" }?.barRect.midY }
                for (upper, lower) in zip(weekly, weekly.dropFirst()) {
                    XCTAssertEqual(
                        abs(upper - lower), ThemedMenuMetrics.subtitleRowHeight, accuracy: 0.01,
                        "\(textSize): a 7d meter left the line every other row keeps it on"
                    )
                }
            }
        }
    }

    /// The clock's tick is drawn where the window's time stands — cut through the bar so it
    /// reads over a fill of nearly its own ink, and standing proud of the bar at both ends.
    ///
    /// Asserted on pixels, because every way of getting this wrong passes a geometry check: a
    /// tick drawn under the fill instead of over it, a knockout painted in the wrong colour, a
    /// tick in the track's own ink. The fill here runs past the tick, which is the case the
    /// knockout exists for.
    func testTheClockTickIsDrawnWhereTheWindowsTimeStands() throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let meter = try renderedMeter(fraction: 0.8, timeMark: 0.5, appearance: appearance)
            let bar = meter.line.barRect
            let tick = try XCTUnwrap(meter.line.tickRect)
            XCTAssertEqual(tick.midX, bar.minX + bar.width * 0.5, accuracy: 1)
            XCTAssertGreaterThan(tick.height, bar.height, "the tick must stand proud of the bar")

            // Proud of the bar: ink where the tick crosses the strip beside the bar, the panel a
            // few points along the same strip. Half a point off the bar, which is inside the
            // tick's straight run — its rounded end is antialiased at any scale.
            let beside = bar.minY - ThemedMenuMetrics.metricTickOverhang / 4
            let panel = try meter.colour(tick.midX + 6, beside)
            XCTAssertGreaterThan(
                distance(try meter.colour(tick.midX, beside), panel), 0.6,
                "\(appearance.rawValue): no tick stands beside the bar"
            )
            // Cut through the fill: the knockout beside the tick is the panel again, while the
            // fill a little further back is not.
            let knockout = try meter.colour(
                tick.minX - ThemedMenuMetrics.metricTickKnockout / 2, bar.midY
            )
            XCTAssertLessThan(
                distance(knockout, panel), 0.1,
                "\(appearance.rawValue): the tick is not cut through the fill"
            )
            XCTAssertGreaterThan(
                distance(try meter.colour(tick.minX - 4, bar.midY), panel), 0.3,
                "\(appearance.rawValue): the fill is missing behind the tick"
            )
        }
    }

    /// A tick in the last few points of its bar ends the bar there. The cut either side of it
    /// left a sliver of fill beyond it — two pixels of red past the tick on a spent week, read as
    /// a stray dot rather than as the rest of a window.
    func testATickNearItsWindowsEndEndsTheBar() throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let meter = try renderedMeter(fraction: 1, timeMark: 0.94, appearance: appearance)
            let bar = meter.line.barRect
            let tick = try XCTUnwrap(meter.line.tickRect)
            XCTAssertLessThan(
                bar.maxX - tick.maxX - ThemedMenuMetrics.metricTickKnockout, bar.height,
                "the fixture must leave a sliver shorter than the bar's own height to remove"
            )

            let panel = try meter.colour(bar.minX + 8, bar.minY - 1)
            XCTAssertLessThan(
                distance(try meter.colour(bar.maxX - 0.5, bar.midY), panel), 0.1,
                "\(appearance.rawValue): a sliver of fill was left past the tick"
            )
            XCTAssertGreaterThan(
                distance(try meter.colour(tick.minX - 4, bar.midY), panel), 0.3,
                "\(appearance.rawValue): the fill before the tick is missing too"
            )
        }
    }

    /// One meter, drawn the way the menu's other pixel tests draw: in an unshown window of the
    /// appearance under test, over the app's own background, built and repainted *under* that
    /// appearance. Setting a built surface's appearance afterwards re-resolved the row's inks and
    /// left the panel dark, which put light-mode black on near-black.
    private func renderedMeter(
        fraction: Double,
        timeMark: Double,
        appearance name: NSAppearance.Name
    ) throws -> RenderedMeter {
        var item = ThemedMenuItem(title: "studio-01")
        item.metrics = [ThemedMenuMetric(
            label: "5h", value: "80%", fraction: fraction, timeMark: timeMark, detail: "2h 30m"
        )]
        let entries: [ThemedMenuEntry] = [.item(item)]
        let size = NSSize(
            width: ThemedMenuMetrics.width(for: entries, minimum: 0),
            height: ThemedMenuMetrics.height(for: entries)
        )
        let appearance = try XCTUnwrap(NSAppearance(named: name))

        var rendered: RenderedMeter?
        let render: @MainActor () -> Void = {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance
            let root = ThemedSurfaceView()
            root.translatesAutoresizingMaskIntoConstraints = true
            root.frame = NSRect(origin: .zero, size: size)
            root.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            window.contentView = root
            root.addSubview(ThemedMenuReferenceFixture.make(entries: entries, size: size))
            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()

            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds),
                  let line = ThemedMenuReferenceFixture.meterLines(in: root, entryIndex: 0).first
            else { return }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            rendered = RenderedMeter(
                bounds: root.bounds, isFlipped: root.isFlipped, bitmap: bitmap, line: line
            )
        }
        appearance.performAsCurrentDrawingAppearance {
            MainActor.assumeIsolated(render)
        }
        return try XCTUnwrap(rendered, "\(name.rawValue): the meter did not render")
    }

    /// The view's geometry is copied out where it was drawn, on the main actor, so sampling is
    /// plain arithmetic on values rather than a reach back into an isolated view.
    private struct RenderedMeter {
        let bounds: NSRect
        let isFlipped: Bool
        let bitmap: NSBitmapImageRep
        let line: ThemedMenuMeterLine

        /// The colour at a point in the drawn view's own coordinates.
        func colour(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            let scale = CGFloat(bitmap.pixelsWide) / bounds.width
            let row = isFlipped ? y : bounds.height - y
            return try XCTUnwrap(
                bitmap.colorAt(x: Int(x * scale), y: Int(row * scale))?.usingColorSpace(.sRGB)
            )
        }
    }

    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    private func menuEntries() -> [ThemedMenuEntry] {
        func account(_ title: String, _ provider: AgentKind, _ windows: [String]) -> ThemedMenuEntry {
            var item = ThemedMenuItem(title: title, image: AccountMarkImage.make(for: provider))
            item.metrics = windows.map {
                ThemedMenuMetric(
                    label: $0, value: "42%", fraction: 0.42, timeMark: 0.6,
                    detail: "29d 23h", spokenDetail: "resets in 29d 23h"
                )
            }
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

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// `studio-01`, the login the composer is on.
    private static let selectedLogin = 3
    private static let claudeLogins = [1, 2, 3, 4, 5, 6]
    private static let codexLogins = [8, 9]

    /// The menu from the report that asked for the stacked meters, assembled the way the
    /// composer assembles it: six Claude logins and two Codex ones, in every state a row can be in
    /// — both windows live, a plan with only a weekly window, windows whose reset has passed, a
    /// spent week, a fresh 5-hour window — then the runtimes with no login to offer.
    private func loginEntries() -> [ThemedMenuEntry] {
        let now = Self.now
        let minute: TimeInterval = 60
        let hour = 60 * minute
        let day = 24 * hour
        func window(_ id: String, _ fraction: Double, resetsIn: TimeInterval) -> AccountUsage.Window {
            AccountUsage.Window(
                id: id,
                label: UsageDefaults.label(forWindowID: id),
                fraction: fraction,
                resetsAt: now.addingTimeInterval(resetsIn),
                windowDuration: UsageDefaults.duration(forWindowID: id)
            )
        }
        func login(
            _ name: String,
            _ provider: AgentKind,
            plan: String? = nil,
            _ windows: [AccountUsage.Window]
        ) -> ThemedMenuEntry {
            var item = ThemedMenuItem(title: name, image: AccountMarkImage.make(for: provider))
            AccountUsageMenu.apply(
                AccountUsage(windows: windows, planLabel: plan, observedAt: now, source: .api),
                to: &item,
                at: now
            )
            return .item(item)
        }
        func runtime(_ kind: AgentKind) -> ThemedMenuEntry {
            .item(ThemedMenuItem(
                title: kind.displayName,
                subtitle: "Not installed",
                image: AccountMarkImage.make(for: kind)
            ))
        }

        return [
            .header("Claude Code"),
            login("Nova Hartley", .claude, [
                window("5h", 0.3, resetsIn: -10 * minute), window("7d", 0.2, resetsIn: -10 * minute)
            ]),
            login("Keller Ines", .claude, [window("7d", 0.13, resetsIn: 6 * day + hour)]),
            login("studio-01", .claude, [
                window("5h", 0.46, resetsIn: 13 * minute),
                window("7d", 0.35, resetsIn: 4 * day + 2 * hour)
            ]),
            login("studio-02", .claude, [
                window("5h", 0.01, resetsIn: 4 * hour + 40 * minute),
                window("7d", 0.41, resetsIn: 2 * day + 5 * hour)
            ]),
            login("bench-01", .claude, [
                window("5h", 0.82, resetsIn: 3 * hour + 50 * minute),
                window("7d", 0.47, resetsIn: 5 * day + 11 * hour)
            ]),
            login("bench-02", .claude, [
                window("5h", 0.4, resetsIn: -hour), window("7d", 1, resetsIn: 9 * hour + 33 * minute)
            ]),
            .header("Codex"),
            login("Everlof", .codex, plan: "Pro", [window("7d", 1, resetsIn: 5 * day + 23 * hour)]),
            login("David", .codex, plan: "Team", [
                window("5h", 0, resetsIn: 4 * hour + 59 * minute),
                window("7d", 0, resetsIn: 6 * day + 23 * hour)
            ]),
            .separator,
            runtime(.grok),
            runtime(.openCode),
            runtime(.cursor)
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
