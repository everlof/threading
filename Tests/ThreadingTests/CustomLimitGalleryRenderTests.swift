import AppKit
import XCTest
@testable import Threading

/// Every surface a user-authored limit reaches, drawn light and dark.
///
/// One test per place the feature is *visible*, because the rule this whole feature rests on is a
/// visual one — a limit adds a marker and tint and never changes the number — and that claim can
/// only be reviewed in a picture. The assertions beside each render catch what an image cannot: a
/// surface that drew nothing at all.
///
/// The parked row and the strip are here for a second reason. Their whole design is "not the
/// triangle", and whether two marks read as different kinds of thing is not something an
/// assertion about a symbol name can answer.
@MainActor
final class CustomLimitGalleryRenderTests: XCTestCase {

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    private let now = Date(timeIntervalSince1970: 1_770_000_000)
    private let weekly = UsageDefaults.weeklyWindowID
    private let fiveHour = UsageDefaults.fiveHourWindowID

    // MARK: - Fixtures

    private func weeklyWindow(fraction: Double, elapsed: Double = 0.4) -> AccountUsage.Window {
        AccountUsage.Window(
            id: weekly,
            label: UsageDefaults.weeklyLabel,
            fraction: fraction,
            resetsAt: now.addingTimeInterval(UsageDefaults.sevenDaySeconds * (1 - elapsed)),
            windowDuration: UsageDefaults.sevenDaySeconds
        )
    }

    private func fiveHourWindow(fraction: Double) -> AccountUsage.Window {
        AccountUsage.Window(
            id: fiveHour,
            label: UsageDefaults.fiveHourLabel,
            fraction: fraction,
            resetsAt: now.addingTimeInterval(2 * 3_600),
            windowDuration: UsageDefaults.fiveHourSeconds
        )
    }

    private func usage() -> AccountUsage {
        AccountUsage(
            windows: [fiveHourWindow(fraction: 0.22), weeklyWindow(fraction: 0.47)],
            planLabel: "Max",
            observedAt: now,
            source: .api
        )
    }

    /// The line every picture here is drawn against: keep the weekly under half.
    private var rule: CustomLimit { CustomLimit(windowID: weekly, bound: 0.5, tier: .park) }

    // MARK: - The Popover's Bars

    /// Where a limit is read at length: a colored line keyed once below the group, with the
    /// provider's own percentage in the tint the *user's* line earns it.
    func testRendersTheWindowRows() throws {
        try draw("limits-window-rows") { appearance in
            let rows = [
                UsageWindowRow(window: self.fiveHourWindow(fraction: 0.22), now: self.now),
                UsageWindowRow(
                    window: self.weeklyWindow(fraction: 0.47),
                    now: self.now,
                    limits: [self.rule]
                )
            ]
            let content: [NSView] = rows
            let column = NSStackView(views: content + [UsageLimitLegendView()])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = Design.Spacing.medium
            for row in rows {
                row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
            _ = appearance
            return (column, NSSize(width: 260, height: 140))
        }
    }

    // MARK: - The Identity Menu

    /// Where an account is *chosen*, which is the moment the number changes a decision. Two
    /// logins, the same 47% weekly, one of them fenced at half.
    func testRendersTheIdentityMenuColumns() throws {
        try draw("limits-identity-menu") { _ in
            var free = ThemedMenuItem(title: "Personal")
            AccountUsageMenu.apply(self.usage(), to: &free, at: self.now)

            var fenced = ThemedMenuItem(title: "Shared with Ada")
            AccountUsageMenu.apply(
                self.usage(),
                to: &fenced,
                at: self.now,
                limits: [self.rule]
            )

            let rows = NSStackView(views: [
                Self.metricRow(free),
                Self.metricRow(fenced)
            ])
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = Design.Spacing.small
            return (rows, NSSize(width: 320, height: 90))
        }
    }

    // MARK: - The Toolbar Pill

    /// The always-visible surface, which a rule reaches **only** by asking. Both pills print the
    /// same numbers; only the opted-in one takes the tint.
    func testRendersTheToolbarPill() throws {
        var loud = rule
        loud.showsInToolbar = true
        let plain = AccountUsageItemView()
        let capped = AccountUsageItemView()

        try draw("limits-toolbar-pill", after: { [usage = usage(), now] _ in
            plain.isHidden = false
            capped.isHidden = false
            plain.show(usage: usage, limits: [], at: now)
            capped.show(usage: usage, limits: [loud], at: now)
        }) { _ in
            // Shown *before* measuring: the width is pinned from the fitting size, and an empty
            // pill fits to its ring. Pinning first and filling afterwards froze both pills at
            // ring width — which the picture showed and no assertion would have.
            plain.show(usage: self.usage(), limits: [], at: self.now)
            capped.show(usage: self.usage(), limits: [loud], at: self.now)

            // Each pill is pinned to its own fitting width. `setContentHuggingPriority` is not
            // what an `NSStackView` lays out by — the trap `SettingsUI.holdsItsWidth` documents —
            // and without this the row stretched the first pill across the whole fixture and
            // squeezed the second to its ring, which is the opposite of what the picture is for.
            for pill in [plain, capped] {
                pill.widthAnchor.constraint(equalToConstant: pill.fittingSize.width).isActive = true
            }
            // A spacer takes the slack, so neither pill is stretched or squeezed by the row it
            // sits in — the pills are what the picture is about.
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let row = NSStackView(views: [plain, capped, spacer])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Design.Spacing.large
            return (row, NSSize(width: 620, height: 44))
        }
    }

    // MARK: - The Strip

    /// The two strips side by side, which is the only way to review the claim that a park is
    /// *not* the triangle: same surface, different mark, different words, and a Continue that
    /// says Anyway.
    func testRendersTheProviderAndParkStrips() throws {
        try draw("limits-strips") { _ in
            let provider = LimitEscapeStripView()
            provider.setOffer(LimitEscapeStripView.Offer(
                source: .provider,
                accountName: "Personal",
                reading: "5h 22% · 7d 47%",
                offersWaitForReset: true,
                resetHint: "in 2h"
            ))

            let park = LimitEscapeStripView()
            park.setOffer(LimitEscapeStripView.Offer(
                source: .ownLimit,
                resetHint: "in 4d"
            ))

            let column = NSStackView(views: [provider, park])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = Design.Spacing.medium
            for strip in [provider, park] {
                strip.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
            return (column, NSSize(width: 620, height: 110))
        }
    }

    // MARK: - The Limit History Chart

    /// The cap drawn as a level the series is read against — horizontal, because a line the user
    /// set is not an event.
    func testRendersTheLimitHistoryCapLine() throws {
        try draw("limits-history-chart") { _ in
            let chart = ThemedTimeSeriesChartView()
            let start = self.now.addingTimeInterval(-4 * 86_400)
            let points = stride(from: 0.0, through: 4.0, by: 0.5).map { day in
                ThemedChartPoint(
                    at: start.addingTimeInterval(day * 86_400),
                    value: min(0.62, 0.05 + day * 0.14)
                )
            }
            chart.setModel(ThemedChartModel(
                title: L10n.string("Weekly"),
                accessibilitySummary: "Weekly is at 62%",
                series: [ThemedChartSeries(
                    id: "weekly",
                    title: UsageDefaults.weeklyLabel,
                    points: points,
                    style: .primary,
                    fillsArea: true
                )],
                valueRules: [ThemedChartValueRule(
                    id: "cap",
                    value: 0.5,
                    title: L10n.format("Your limit · %@", "50%"),
                    kind: .cap
                )],
                xRange: start...self.now,
                yRange: 0...1,
                valueFormat: .percent
            ), animated: false)
            return (chart, NSSize(width: 460, height: 300))
        }
    }

    // MARK: - Assertions The Pictures Cannot Make

    /// Each render above must have drawn something. A blank image is the one failure a reviewer
    /// scrolling a gallery will not notice.
    func testEverySurfaceDrawsSomething() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(source: .ownLimit, resetHint: "in 4d"))
        XCTAssertFalse(strip.isHidden)
        XCTAssertGreaterThan(strip.fittingSize.height, 20)

        let row = UsageWindowRow(
            window: weeklyWindow(fraction: 0.47),
            now: now,
            limits: [rule]
        )
        XCTAssertGreaterThan(row.fittingSize.height, 20)

        // The pill drew as an empty plate the first time, because a themed component takes its
        // ink from the sweep rather than from its initializer. Its *width* is the tell: a pill
        // with no reading is the ring and its padding, and one with a reading is much wider.
        let pill = AccountUsageItemView()
        pill.show(usage: usage(), limits: [], at: now)
        XCTAssertGreaterThan(
            pill.fittingSize.width,
            AccountUsageItemDefaults.ringSize * 3,
            "the usage pill is drawing no reading at all"
        )

        // And the readings are the ones taken at the moment asked for. The first fixture printed
        // `5h — · 7d —`, because the pill's `readings` call took `Date()` while everything around
        // it took the injected `now`: with the two apart, every window reads as expired.
        let spoken = pill.accessibilityLabel() ?? ""
        XCTAssertFalse(
            spoken.contains(UsageDefaults.unknownValue),
            "the pill reported its windows as expired at the moment it was asked about: \(spoken)"
        )
    }

    // MARK: - Helpers

    /// One row of a menu item's metric columns, drawn the way the menu draws them.
    private static func metricRow(_ item: ThemedMenuItem) -> NSView {
        let column = NSStackView(views: item.metrics.map { metric in
            let label = NSTextField(labelWithString: "\(metric.label)  \(metric.value)")
            label.applyFont(.numericControl())
            label.textColor = Self.ink(for: metric.tone)
            return label
        })
        column.orientation = .horizontal
        column.alignment = .firstBaseline
        column.spacing = Design.Spacing.medium

        let title = NSTextField(labelWithString: item.title)
        title.applyFont(.body)
        title.textColor = Design.Text.label

        let row = NSStackView(views: [title, column])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Design.Spacing.large
        return row
    }

    private static func ink(for tone: ThemedMenuSubtitleSegment.Tone) -> NSColor {
        switch tone {
        case .standard: return Design.Text.label
        case .muted: return Design.Text.secondary
        case .warning: return Design.Status.warning
        case .critical: return Design.Status.negative
        }
    }

    /// Draws one fixture light and dark and writes both.
    private func draw(
        _ name: String,
        after repaint: ((NSView) -> Void)? = nil,
        _ build: @escaping (NSAppearance) -> (NSView, NSSize)
    ) throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let (view, size) = build(appearance)

            let host = NSView(frame: NSRect(origin: .zero, size: size))
            host.wantsLayer = true
            host.appearance = appearance
            view.appearance = appearance
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(
                    equalTo: host.leadingAnchor,
                    constant: Design.Spacing.inset
                ),
                view.trailingAnchor.constraint(
                    equalTo: host.trailingAnchor,
                    constant: -Design.Spacing.inset
                ),
                view.centerYAnchor.constraint(equalTo: host.centerYAnchor)
            ])

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                // A `ThemedComponent` takes its ink from the sweep, not from its initializer, so
                // a fixture that skips this draws a correctly-laid-out control in no colour at
                // all — which is how the toolbar pill first rendered as an empty plate.
                AppThemeRefresh.repaint(host)
                // Some components re-derive their content from their model inside `applyInk` —
                // the toolbar pill re-runs `render()` there and hides itself when it has no
                // account. A fixture that supplies content has to supply it *after* the sweep,
                // or the sweep is the last word and the picture is blank.
                repaint?(host)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }
            }

            try XCTUnwrap(data, "Failed to render \(name) in \(suffix)")
                .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
