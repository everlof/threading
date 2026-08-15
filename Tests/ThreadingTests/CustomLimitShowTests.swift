import AppKit
import XCTest
@testable import Threading

/// Drawing the user's own line where the reading is.
///
/// The rule this whole tier rests on is that a limit changes the **tint and the track**, never the
/// length or the printed number. A bar drawing full at 40% would lie about the figure beside it,
/// and a rule that could make a gauge lie is worse than no rule — so the assertions here are as
/// much about what stays put as about what moves.
@MainActor
final class CustomLimitShowTests: XCTestCase {

    private enum Render {
        static let width: CGFloat = 200
        static let height = UsageBarDefaults.height

        static var directory: URL {
            // Non-empty, deliberately: an override set to "" resolves to `/`, and the failure
            // that produces is a read-only-volume error three frames deep in a PNG write rather
            // than anything that names the environment.
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    private let weekly = UsageDefaults.weeklyWindowID
    private let fiveHour = UsageDefaults.fiveHourWindowID

    // MARK: - Which Line Binds

    func testTheTightestLineOnAWindowIsTheOneDrawn() throws {
        let loose = CustomLimit(windowID: weekly, bound: 0.9)
        let tight = CustomLimit(windowID: weekly, bound: 0.5)
        let elsewhere = CustomLimit(windowID: fiveHour, bound: 0.2)

        XCTAssertEqual(
            CustomLimitBounds.tightest(on: weekly, in: [loose, tight, elsewhere])?.id,
            tight.id
        )
        XCTAssertEqual(
            CustomLimitBounds.tightest(on: fiveHour, in: [loose, tight, elsewhere])?.id,
            elsewhere.id,
            "a rule names its window, so another window's tighter line must not bind this one"
        )
    }

    /// A rule at the provider's own line has no line of its own to draw. A tick at 100% would
    /// mark the end of the bar as though the user had put it there, and an alert-only rule made
    /// to fire one notification must not add furniture to a gauge.
    func testARuleAtTheProvidersOwnLineDrawsNothing() {
        let everyTenth = CustomLimit.everyStep(
            windowID: weekly,
            step: CustomLimitDefaults.tenPercentStep
        )

        XCTAssertNil(CustomLimitBounds.tightest(on: weekly, in: [everyTenth]))
        XCTAssertEqual(
            CustomLimitBounds.effectiveBound(on: weekly, in: [everyTenth]),
            1.0,
            "with no line of the user's, the effective bound is the shipped formula exactly"
        )
    }

    /// A metric this build cannot evaluate cannot be drawn either: a pace share's bound is a
    /// share of *elapsed time*, and a fixed tick at that number is a line nobody drew.
    func testAnUnsupportedMetricDrawsNoLine() {
        let pace = CustomLimit(windowID: weekly, metric: .paceShare, bound: 0.5)

        XCTAssertNil(CustomLimitBounds.tightest(on: weekly, in: [pace]))
        XCTAssertEqual(CustomLimitBounds.effectiveBound(on: weekly, in: [pace]), 1.0)
    }

    // MARK: - The Tint

    /// The whole point of the tier: a login fenced off at half reads as nearly spent while the
    /// provider still reads it as comfortable.
    func testSeverityIsMeasuredAgainstTheUsersLine() {
        let half = [CustomLimit(windowID: weekly, bound: 0.5)]

        XCTAssertEqual(UsageSeverity.from(fraction: 0.47), .normal)
        XCTAssertEqual(CustomLimitBounds.severity(of: 0.47, on: weekly, in: half), .critical)
        XCTAssertEqual(CustomLimitBounds.severity(of: 0.2, on: weekly, in: half), .normal)
    }

    /// With no rule the answer is the one the app has always given, to the letter.
    func testWithNoLineTheSeverityIsUnchanged() {
        for fraction in [0.0, 0.3, 0.8, 0.95, 1.0] {
            XCTAssertEqual(
                CustomLimitBounds.severity(of: fraction, on: weekly, in: []),
                UsageSeverity.from(fraction: fraction)
            )
        }
    }

    /// An unknown reading takes no pressure from a rule. A missing fraction is not consumption,
    /// and a bar tinted from one would be reporting spend that was never observed.
    func testAnUnknownReadingTakesNoTintFromALine() {
        let half = [CustomLimit(windowID: weekly, bound: 0.5)]
        XCTAssertEqual(CustomLimitBounds.severity(of: nil, on: weekly, in: half), .normal)
    }

    // MARK: - The Track

    /// The line is drawn as a change in the *track*: full strength up to it, quiet past it.
    ///
    /// Asserted in pixels rather than on the view tree, because the claim is about what a reader
    /// sees. Two identical 2pt ticks on a 6pt bar would satisfy any structural assertion and be
    /// unreadable.
    func testTheTrackGoesQuietPastTheUsersLine() throws {
        let bar = UsageBarView()
        bar.fraction = 0
        bar.capMark = 0.5
        let host = hosted(bar)

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let before = try distanceFromGround(at: Render.width * 0.25, in: rep, host: host)
        let after = try distanceFromGround(at: Render.width * 0.85, in: rep, host: host)

        XCTAssertGreaterThan(
            before,
            after,
            "the track past the user's line is not quieter than the track before it"
        )
        XCTAssertGreaterThan(after, 0, "the remainder was drawn away entirely; the window is still that long")
    }

    /// Without a line the track is one strength end to end, exactly as it has always been.
    func testWithoutALineTheTrackIsUniform() throws {
        let bar = UsageBarView()
        bar.fraction = 0
        bar.capMark = nil
        let host = hosted(bar)

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let before = try distanceFromGround(at: Render.width * 0.25, in: rep, host: host)
        let after = try distanceFromGround(at: Render.width * 0.85, in: rep, host: host)

        XCTAssertEqual(before, after, accuracy: 0.02)
    }

    /// Consumption past the line still draws past it. That spend really happened, and a gauge may
    /// not quieten a number the account actually reached.
    func testFillPastTheLineIsStillDrawnAtFullStrength() throws {
        let bar = UsageBarView()
        bar.tint = .systemRed
        bar.fraction = 0.9
        bar.capMark = 0.5
        let host = hosted(bar)

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let insideTheLine = try colour(at: Render.width * 0.25, in: rep, host: host)
        let pastTheLine = try colour(at: Render.width * 0.75, in: rep, host: host)

        XCTAssertEqual(insideTheLine.redComponent, pastTheLine.redComponent, accuracy: 0.02)
        XCTAssertEqual(insideTheLine.greenComponent, pastTheLine.greenComponent, accuracy: 0.02)
        XCTAssertEqual(insideTheLine.blueComponent, pastTheLine.blueComponent, accuracy: 0.02)
    }

    /// The bar's *length* is the provider's figure and nothing else touches it.
    func testTheFillLengthIgnoresTheLineEntirely() {
        let bar = UsageBarView()
        let host = hosted(bar)

        bar.apply(fraction: 0.4, tint: .systemGreen, timeMark: nil, capMark: 0.5, animated: false)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.displayedFraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(bar.drawnFillWidth, Render.width * 0.4, accuracy: 0.5)
        XCTAssertEqual(bar.drawnCapTrackWidth, Render.width * 0.5, accuracy: 0.5)

        bar.apply(fraction: 0.4, tint: .systemGreen, timeMark: nil, capMark: nil, animated: false)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.displayedFraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(bar.drawnFillWidth, Render.width * 0.4, accuracy: 0.5)
        XCTAssertEqual(bar.drawnCapTrackWidth, 0, "the line was removed and its track stayed")
    }

    // MARK: - The Row

    /// The row prints the provider's percentage and takes the user's tint — both at once, which
    /// is the sentence this tier is.
    func testTheRowKeepsTheProvidersNumberAndTakesTheUsersTint() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let window = AccountUsage.Window(
            id: weekly,
            label: UsageDefaults.weeklyLabel,
            fraction: 0.47,
            resetsAt: now.addingTimeInterval(86_400),
            windowDuration: UsageDefaults.sevenDaySeconds
        )
        let row = UsageWindowRow(
            window: window,
            now: now,
            limits: [CustomLimit(windowID: weekly, bound: 0.5)]
        )
        _ = hosted(row, height: 60)

        let labels = descendants(of: row).compactMap { $0 as? NSTextField }
        XCTAssertTrue(
            labels.contains { $0.stringValue == "47%" },
            "the row stopped printing the provider's own figure"
        )
        XCTAssertTrue(
            labels.contains { $0.stringValue == UsageDefaults.weeklyLabel },
            "the row stopped naming its window"
        )
    }

    /// A quieter stretch of a 6pt bar reaches nobody who is not looking at it, so the rule names
    /// itself in the row's tooltip and in what the row is read out as.
    func testTheRuleNamesItselfWhereTheBarCannot() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let window = AccountUsage.Window(
            id: weekly,
            label: UsageDefaults.weeklyLabel,
            fraction: 0.47,
            resetsAt: now.addingTimeInterval(86_400),
            windowDuration: UsageDefaults.sevenDaySeconds
        )

        let capped = UsageWindowRow(
            window: window,
            now: now,
            limits: [CustomLimit(windowID: weekly, bound: 0.5)]
        )
        XCTAssertEqual(capped.toolTip, "Keep Weekly under 50%")
        let spoken = try XCTUnwrap(capped.accessibilityLabel())
        XCTAssertTrue(spoken.contains("47%"), spoken)
        XCTAssertTrue(spoken.contains("Keep Weekly under 50%"), spoken)

        let plain = UsageWindowRow(window: window, now: now)
        XCTAssertNil(plain.toolTip, "a window nobody has drawn a line on acquired a tooltip")
        XCTAssertEqual(plain.accessibilityLabel(), "Weekly 47%")
    }

    // MARK: - The Identity Menu

    /// The menu where an account is *chosen* is where a fenced-off login has to read as
    /// pressured — the moment the number changes a decision.
    ///
    /// The column keeps its label, its value and its bar's length: a column that shortened or
    /// renumbered itself under a rule would be answering a different question from the one the
    /// other logins' columns answer, on the one surface where two logins are read side by side.
    func testTheIdentityMenusColumnKeepsItsNumberAndTakesTheUsersTone() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let usage = AccountUsage(
            windows: [
                AccountUsage.Window(
                    id: weekly,
                    label: UsageDefaults.weeklyLabel,
                    fraction: 0.47,
                    resetsAt: now.addingTimeInterval(86_400),
                    windowDuration: UsageDefaults.sevenDaySeconds
                )
            ],
            planLabel: "Max",
            observedAt: now,
            source: .api
        )

        let plain = try XCTUnwrap(AccountUsageMenu.identityMetrics(for: usage, at: now).first)
        let capped = try XCTUnwrap(
            AccountUsageMenu.identityMetrics(
                for: usage,
                at: now,
                limits: [CustomLimit(windowID: weekly, bound: 0.5)]
            ).first
        )

        XCTAssertEqual(capped.label, plain.label)
        XCTAssertEqual(capped.value, "47%")
        XCTAssertEqual(capped.value, plain.value)
        XCTAssertEqual(capped.fraction, plain.fraction)
        XCTAssertNotEqual(
            capped.tone,
            plain.tone,
            "a login fenced off at half still read as comfortable where it is chosen"
        )
    }

    // MARK: - The Pill

    /// The one surface that cannot be dismissed takes a rule only from a rule that asked.
    ///
    /// Off by default, so a rule created to fire one quiet 50% alert cannot give the toolbar a
    /// new red state its author never wanted.
    func testOnlyARuleThatAskedMayMoveThePill() {
        let quiet = CustomLimit(windowID: weekly, bound: 0.5)
        var loud = quiet
        loud.showsInToolbar = true

        XCTAssertFalse(quiet.showsInToolbar, "a new rule reached the toolbar without asking")
        XCTAssertTrue(CustomLimitBounds.toolbarRules([quiet]).isEmpty)
        XCTAssertEqual(CustomLimitBounds.toolbarRules([quiet, loud]).map(\.id), [loud.id])
    }

    /// The ring gauges whatever stops the work, and a user's line can be what does.
    ///
    /// A weekly at 56% beside a five-hour at 40% under a 45% line: raw, the weekly is fuller;
    /// against the lines actually in force, the five-hour is nearly spent and is what the session
    /// runs out of first.
    func testTheUsersLineCanDecideWhichWindowTheRingGauges() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let windows = [
            AccountUsage.Window(
                id: fiveHour,
                label: UsageDefaults.fiveHourLabel,
                fraction: 0.4,
                resetsAt: now.addingTimeInterval(3_600),
                windowDuration: UsageDefaults.fiveHourSeconds
            ),
            AccountUsage.Window(
                id: weekly,
                label: UsageDefaults.weeklyLabel,
                fraction: 0.56,
                resetsAt: now.addingTimeInterval(86_400),
                windowDuration: UsageDefaults.sevenDaySeconds
            )
        ]

        XCTAssertEqual(
            CustomLimitBounds.bindingWindow(among: windows, in: [], at: now)?.id,
            weekly,
            "with no line drawn the answer must be the shipped one exactly"
        )
        XCTAssertEqual(
            CustomLimitBounds.bindingWindow(
                among: windows,
                in: [CustomLimit(windowID: fiveHour, bound: 0.45)],
                at: now
            )?.id,
            fiveHour
        )
    }

    /// Retinting moves the tint and carries everything else through untouched — the negative half
    /// of this tier, asserted rather than assumed.
    func testRetintingChangesTheToneAndNothingElse() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let windows = [
            AccountUsage.Window(
                id: weekly,
                label: UsageDefaults.weeklyLabel,
                fraction: 0.47,
                resetsAt: now.addingTimeInterval(86_400),
                windowDuration: UsageDefaults.sevenDaySeconds
            )
        ]
        let usage = AccountUsage(windows: windows, planLabel: nil, observedAt: now, source: .api)
        let plain = usage.readings(of: windows, at: now)

        let capped = CustomLimitBounds.retinted(
            plain,
            of: windows,
            in: [CustomLimit(windowID: weekly, bound: 0.5)]
        )

        let before = try XCTUnwrap(plain.first)
        let after = try XCTUnwrap(capped.first)
        XCTAssertEqual(after.name, before.name)
        XCTAssertEqual(after.value, before.value)
        XCTAssertEqual(after.fraction, before.fraction)
        XCTAssertEqual(before.severity, .normal)
        XCTAssertEqual(after.severity, .critical)
    }

    /// The model menu is the one surface where a *scoped* limit is actionable — a spent Fable
    /// window is escaped by picking something else — so a line drawn on one has to be visible
    /// there, and only on the row that model's window belongs to.
    func testAScopedLimitTintsTheModelRowItBelongsTo() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let fable = "fable"
        var usage = AccountUsage(windows: [], planLabel: nil, observedAt: now, source: .api)
        usage.modelWindows = [
            AccountUsage.Window(
                id: fable,
                label: "Weekly · Fable",
                fraction: 0.47,
                resetsAt: now.addingTimeInterval(86_400),
                windowDuration: UsageDefaults.sevenDaySeconds,
                scopeName: "Fable"
            )
        ]

        let plain = AccountUsageMenu.modelSummarySegments(
            for: usage,
            running: fable,
            at: now
        )
        let capped = AccountUsageMenu.modelSummarySegments(
            for: usage,
            running: fable,
            at: now,
            limits: [CustomLimit(windowID: fable, bound: 0.5)]
        )

        XCTAssertEqual(
            capped.map(\.text),
            plain.map(\.text),
            "the line changed what the row says, not only how it says it"
        )
        XCTAssertNotEqual(
            capped.map(\.tone),
            plain.map(\.tone),
            "a scoped window fenced off at half still read as comfortable"
        )
    }

    // MARK: - Images

    /// One window at four readings under one line, so the whole tier can be reviewed at a glance.
    func testRendersTheCappedBarToImages() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let limits = [CustomLimit(windowID: weekly, bound: 0.5)]

        var written = 0
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))

            let rows = [0.1, 0.4, 0.47, 0.8].map { fraction in
                UsageWindowRow(
                    window: AccountUsage.Window(
                        id: weekly,
                        label: UsageDefaults.weeklyLabel,
                        fraction: fraction,
                        resetsAt: now.addingTimeInterval(86_400),
                        windowDuration: UsageDefaults.sevenDaySeconds
                    ),
                    now: now,
                    limits: limits
                )
            }
            let column = NSStackView(views: rows)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = Design.Spacing.medium
            for row in rows {
                row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }

            let host = hosted(column, width: 260, height: 220)
            host.appearance = appearance
            column.appearance = appearance

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                host.layoutSubtreeIfNeeded()
                host.wantsLayer = true
                host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }
            }

            let url = directory.appendingPathComponent("custom-limit-bar-\(name).png")
            try XCTUnwrap(data, "Failed to render the capped bar in \(name)").write(to: url)
            written += 1
        }

        XCTAssertEqual(written, 2)
    }

    // MARK: - Helpers

    @discardableResult
    private func hosted(
        _ view: NSView,
        width: CGFloat = Render.width,
        height: CGFloat = Render.height
    ) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func colour(
        at x: CGFloat,
        in rep: NSBitmapImageRep,
        host: NSView
    ) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let pixel = rep.colorAt(
            x: Int(x * scale),
            y: Int(host.bounds.height / 2 * scale)
        )
        return try XCTUnwrap(pixel?.usingColorSpace(.deviceRGB))
    }

    /// How far a pixel sits from the ground the bar is drawn on — the measure of "how much track
    /// is there", independent of whether a theme's track is lighter or darker than its ground.
    private func distanceFromGround(
        at x: CGFloat,
        in rep: NSBitmapImageRep,
        host: NSView
    ) throws -> CGFloat {
        let ground = try XCTUnwrap(NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB))
        let sample = try colour(at: x, in: rep, host: host)
        return abs(sample.redComponent - ground.redComponent)
            + abs(sample.greenComponent - ground.greenComponent)
            + abs(sample.blueComponent - ground.blueComponent)
    }
}
