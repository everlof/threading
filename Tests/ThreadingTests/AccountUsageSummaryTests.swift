import XCTest
@testable import Threading

final class AccountUsageSummaryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// The cache has four real states, not two unrelated optional values. In particular, a
    /// failed refresh after a success must preserve the last good usage while naming it stale.
    func testCachedReadingTransitionsKeepLastGoodUsageWithoutInventingInvalidPairs() {
        let first = makeUsage(windows: [
            window(id: "5h", fraction: 0.43, resetsIn: 3600)
        ])
        let replacement = makeUsage(windows: [
            window(id: "5h", fraction: 0.48, resetsIn: 3600)
        ])
        let offline = UsageFetchError.network("offline")

        var reading = AccountUsageReading.notFetched
        XCTAssertFalse(reading.hasResult)
        XCTAssertNil(reading.usage)
        XCTAssertNil(reading.error)

        reading = reading.recording(.failure(offline))
        XCTAssertTrue(reading.hasResult)
        XCTAssertNil(reading.usage)
        XCTAssertEqual(reading.error, offline)

        reading = reading.recording(.success(first))
        XCTAssertEqual(reading, .current(first))

        reading = reading.recording(.failure(offline))
        XCTAssertEqual(reading, .stale(first, error: offline))
        XCTAssertEqual(reading.usage, first)
        XCTAssertEqual(reading.error, offline)

        reading = reading.recording(.success(replacement))
        XCTAssertEqual(reading, .current(replacement))
        XCTAssertNil(reading.error)
    }

    func testSummaryNamesEveryWindowWithItsValue() {
        let usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.43, resetsIn: 3600),
            window(id: "7d", fraction: 0.73, resetsIn: 86_400)
        ])

        XCTAssertEqual(usage.compactSummary(at: now), "5h 43% · 7d 73%")
    }

    /// The pill's rule, applied to text: a window past its reset kept its identity but not
    /// its number, which belongs to the window before it.
    func testExpiredWindowLosesItsNumberButKeepsItsName() {
        let usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.43, resetsIn: -60),
            window(id: "7d", fraction: 0.73, resetsIn: 86_400)
        ])

        XCTAssertEqual(usage.compactSummary(at: now), "5h — · 7d 73%")
    }

    func testUnknownFractionReadsAsUnknown() {
        let usage = makeUsage(windows: [window(id: "5h", fraction: nil, resetsIn: 3600)])
        XCTAssertEqual(usage.compactSummary(at: now), "5h —")
    }

    /// Nothing to say, so a caller shows no line at all rather than an empty one.
    func testNoWindowsHasNoSummary() {
        XCTAssertNil(makeUsage(windows: []).compactSummary(at: now))
    }

    func testPercentIsRounded() {
        let usage = makeUsage(windows: [window(id: "5h", fraction: 0.436, resetsIn: 3600)])
        XCTAssertEqual(usage.compactSummary(at: now), "5h 44%")
    }

    // MARK: - Model Limits

    /// The reason a per-model limit is kept out of `windows`: the toolbar's peak must report
    /// the *account's* pressure. A spent model limit says one model is finished, not that the
    /// plan is — folding it in would put the pill in the red over a model the session may not
    /// even be using.
    func testModelLimitDoesNotDistortTheAccountsPeak() {
        var usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.10, resetsIn: 3600),
            window(id: "7d", fraction: 0.22, resetsIn: 86_400)
        ])
        usage.modelWindows = [window(id: "GPT-5.3-Codex-Spark", fraction: 1.0, resetsIn: 3600)]

        XCTAssertEqual(usage.peakWindow(at: now)?.id, "7d")
        XCTAssertEqual(usage.compactSummary(at: now), "5h 10% · 7d 22%")
    }

    /// …and the other half of that rule: the window that stops *this* session is the account's
    /// own or the one metering the model it runs, whichever is fuller. The pill gauges this,
    /// because a weekly window at 22% is comfortable as an account and spent as a session.
    func testBindingWindowIncludesTheModelTheSessionRuns() {
        var usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.10, resetsIn: 3600),
            window(id: "7d", fraction: 0.22, resetsIn: 86_400)
        ])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 86_400)]

        XCTAssertEqual(usage.bindingWindow(at: now, metering: "claude-fable-5[1m]")?.id, "Fable")
        XCTAssertEqual(
            usage.compactSummary(at: now, metering: "claude-fable-5[1m]"),
            "5h 10% · 7d 22% · 7d Fable 89%"
        )
    }

    /// One vocabulary for every written-out window: a length, and the model it meters when it
    /// meters one. A scoped window printing as its model alone put a name in a list of durations,
    /// and left `Fable 89%` with nothing to say which period it covered.
    func testAScopedWindowIsNamedByLengthAndModel() {
        XCTAssertEqual(
            scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 86_400).compactName,
            "7d Fable"
        )
        XCTAssertEqual(
            scopedWindow(
                model: "Fable",
                fraction: 0.89,
                resetsIn: 86_400,
                duration: UsageDefaults.fiveHourSeconds
            ).compactName,
            "5h Fable"
        )
        XCTAssertEqual(window(id: "7d", fraction: 0.22, resetsIn: 86_400).compactName, "7d")
    }

    /// A provider that reports a scoped limit without saying how long its window is leaves the
    /// model's name as the only thing that identifies it — which is what gets printed, rather
    /// than a length invented to fill the slot.
    func testAScopedWindowOfUnknownLengthKeepsItsModelName() {
        let unsized = scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 86_400, duration: nil)
        XCTAssertEqual(unsized.compactName, "Fable")
    }

    /// Another model's limit is not this session's problem, and naming no model at all is not a
    /// licence to guess — both read as the account's own windows.
    func testBindingWindowIgnoresLimitsForOtherModels() {
        var usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.10, resetsIn: 3600),
            window(id: "7d", fraction: 0.22, resetsIn: 86_400)
        ])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 86_400)]

        XCTAssertEqual(usage.bindingWindow(at: now, metering: "claude-opus-4-8")?.id, "7d")
        XCTAssertEqual(usage.bindingWindow(at: now, metering: nil)?.id, "7d")
        XCTAssertEqual(usage.compactSummary(at: now, metering: nil), "5h 10% · 7d 22%")
    }

    /// A scoped window past its reset is skipped like any other: its percentage describes the
    /// window before it, and gauging the ring from it would show pressure that has gone.
    func testExpiredModelWindowDoesNotBind() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.22, resetsIn: 86_400)])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: -60)]

        XCTAssertEqual(usage.bindingWindow(at: now, metering: "fable")?.id, "7d")
        XCTAssertEqual(usage.compactSummary(at: now, metering: "fable"), "7d 22% · 7d Fable —")
    }

    // MARK: - Account Menu

    /// The line under each login where an account is picked. It carries the plan, every window
    /// metering the model that would run, and when the tight one comes back — because that is
    /// the moment the numbers change a decision, and the toolbar only speaks afterwards.
    @MainActor
    func testAccountMenuLineNamesPlanWindowsAndTheBindingReset() {
        var usage = AccountUsage(
            windows: [
                window(id: "5h", fraction: 0.07, resetsIn: 3600),
                window(id: "7d", fraction: 0.56, resetsIn: 54_000)
            ],
            planLabel: "Max",
            observedAt: now,
            source: .localCache
        )
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 54_000)]

        var item = ThemedMenuItem(title: "Everlof")
        AccountUsageMenu.apply(usage, to: &item, metering: "claude-fable-5[1m]", at: now)

        XCTAssertEqual(item.titleDetail, "Max")
        XCTAssertEqual(item.metrics.map(\.label), ["5h", "7d"])
        XCTAssertEqual(item.metrics.map(\.value), ["7%", "56%"])
        // The scoped window is the one thing a shared column cannot hold, so it — and only it —
        // takes the row's second line.
        XCTAssertEqual(item.subtitle, "7d Fable 89%")
        XCTAssertEqual(item.trailingDetail, "7d Fable · 15h")
        // The same row without a name in front of it — what a surface that has already said
        // whose account this is puts in a tooltip.
        XCTAssertEqual(
            AccountUsageMenu.summary(for: usage, metering: "claude-fable-5[1m]", at: now),
            "Max, 5h 7%, 7d 56%, 7d Fable · 15h, 7d Fable 89%"
        )
        XCTAssertEqual(
            item.spokenSummary,
            "Everlof, Max, 5h 7%, 7d 56%, 7d Fable · 15h, 7d Fable 89%"
        )
    }

    /// The account is picked before the model, so the line names a scoped window the account's
    /// *configured* default would never reach. Withholding it is what made a login whose Fable
    /// window was nearly spent read exactly like one that was barely touched.
    @MainActor
    func testAccountMenuNamesScopedWindowsTheChosenModelDoesNotMeter() {
        var usage = AccountUsage(
            windows: [
                window(id: "5h", fraction: 0.11, resetsIn: 3600),
                window(id: "7d", fraction: 0.62, resetsIn: 54_000)
            ],
            planLabel: "Max",
            observedAt: now,
            source: .localCache
        )
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 54_000)]

        // Metering Opus: Fable is named, but 7d is still what binds — and what the reset column
        // and the ring both answer for.
        var item = ThemedMenuItem(title: "Everlof")
        AccountUsageMenu.apply(usage, to: &item, metering: "opus[1m]", at: now)

        XCTAssertEqual(item.subtitle, "7d Fable 89%")
        XCTAssertEqual(item.trailingDetail, "7d · 15h")
        XCTAssertEqual(usage.bindingWindow(at: now, metering: "opus[1m]")?.id, "7d")
    }

    /// A session already running a model is measured against that model and nothing else: the
    /// mirrored reading stays narrow, because there another model's limit is not its problem.
    func testARunningSessionsReadingStaysNarrow() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.62, resetsIn: 54_000)])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 54_000)]

        XCTAssertEqual(usage.compactSummary(at: now, metering: "opus[1m]"), "7d 62%")
        XCTAssertEqual(
            usage.compactSummary(at: now, metering: "opus[1m]", scoped: .all),
            "7d 62% · 7d Fable 89%"
        )
    }

    // MARK: - Model Menu

    /// A model row states only what meters *it* beyond the account — the shared windows are the
    /// header's, stated once — and when its own window is the binding one, its countdown. Bare
    /// beside a single reading: naming the window there repeats a name three inches from itself.
    @MainActor
    func testModelRowStatesOnlyItsOwnScopedWindows() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.62, resetsIn: 54_000)])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 54_000)]

        XCTAssertEqual(
            AccountUsageMenu.modelSummary(for: usage, running: "claude-fable-5[1m]", at: now),
            "7d Fable 89% · resets in 15h"
        )
    }

    /// A model the plan meters no differently says nothing of its own. That emptiness means
    /// "nothing beyond the header", not a failed lookup — the reason repeating the account's
    /// windows per row was retired: on an account with no scoped window at all it printed one
    /// sentence five times, which reads as a rendering bug, not as five models.
    @MainActor
    func testModelRowWithoutAScopedWindowSaysNothingBeyondTheHeader() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.62, resetsIn: 54_000)])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 54_000)]

        XCTAssertNil(AccountUsageMenu.modelSummary(for: usage, running: "claude-opus-4-8", at: now))
        // The row that leaves the choice to the CLI, on an account naming no default: nothing is
        // known about the model, so nothing scoped can honestly be said about it either.
        XCTAssertNil(AccountUsageMenu.modelSummary(for: usage, running: nil, at: now))
        // And an account with no windows at all keeps the same silence.
        XCTAssertNil(
            AccountUsageMenu.modelSummary(for: makeUsage(windows: []), running: "opus", at: now)
        )
    }

    /// The countdown belongs to the window that stops the work. When the account's own window
    /// binds, its reset already trails the header — the row repeats neither the number nor the
    /// wait.
    @MainActor
    func testModelRowCountdownAppearsOnlyWhenItsOwnWindowBinds() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.62, resetsIn: 54_000)])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.30, resetsIn: 54_000)]

        XCTAssertEqual(
            AccountUsageMenu.modelSummary(for: usage, running: "fable", at: now),
            "7d Fable 30%"
        )
    }

    /// A row naming more than one window attributes its countdown — an unattributed one is read
    /// as belonging to whichever was written last, and the binding window is not always that.
    @MainActor
    func testModelRowWithTwoScopedWindowsNamesTheCountdownsWindow() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.22, resetsIn: 54_000)])
        usage.modelWindows = [
            scopedWindow(
                model: "Fable",
                fraction: 0.89,
                resetsIn: 54_000,
                duration: UsageDefaults.fiveHourSeconds
            ),
            scopedWindow(model: "Fable", fraction: 0.40, resetsIn: 86_400)
        ]

        XCTAssertEqual(
            AccountUsageMenu.modelSummary(for: usage, running: "fable", at: now),
            "5h Fable 89% · 7d Fable 40% · 5h Fable resets in 15h"
        )
    }

    /// An expired scoped window loses its number here too, and stops binding the countdown —
    /// a reset that has already happened is not a wait, and the account window that binds
    /// instead keeps its reset in the header.
    @MainActor
    func testExpiredModelRowKeepsItsWindowAndDropsTheNumber() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.62, resetsIn: 54_000)])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: -60)]

        XCTAssertEqual(
            AccountUsageMenu.modelSummary(for: usage, running: "fable", at: now),
            "7d Fable —"
        )
    }

    /// The header above the rows: the plan and the account's own windows with their binding
    /// reset — and none of the scoped ones, which belong to the rows that answer for their
    /// models. A header restating them would put the same number on screen twice in one menu.
    @MainActor
    func testModelMenuHeaderStatesTheSharedWindowsAndNotTheScopedOnes() {
        var usage = AccountUsage(
            windows: [
                window(id: "5h", fraction: 0.41, resetsIn: 3600),
                window(id: "7d", fraction: 0.77, resetsIn: 54_000)
            ],
            planLabel: "Max",
            observedAt: now,
            source: .localCache
        )
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 54_000)]

        XCTAssertEqual(
            AccountUsageMenu.modelMenuHeaderSegments(for: usage, at: now).map(\.text).joined(),
            "Max · 5h 41% · 7d 77% · 7d resets in 15h"
        )
    }

    /// A header with nothing to say is no header at all — the same silence the rows keep.
    @MainActor
    func testModelMenuHeaderSaysNothingWithoutWindows() {
        XCTAssertTrue(
            AccountUsageMenu.modelMenuHeaderSegments(for: makeUsage(windows: []), at: now).isEmpty
        )
    }

    /// A scoped window is identified by its model, so its *length* is recovered from the window
    /// it is measured in.
    func testWindowIDIsRecoveredFromItsLength() {
        XCTAssertEqual(UsageDefaults.windowID(forDuration: UsageDefaults.fiveHourSeconds), "5h")
        XCTAssertEqual(UsageDefaults.windowID(forDuration: UsageDefaults.sevenDaySeconds), "7d")
        XCTAssertEqual(UsageDefaults.windowID(forDuration: 12 * 3600), "12h")
        XCTAssertEqual(UsageDefaults.windowID(forDuration: 3 * 86_400), "3d")
        XCTAssertNil(UsageDefaults.windowID(forDuration: nil))
        XCTAssertNil(UsageDefaults.windowID(forDuration: 0))
    }

    /// A row states only what it has. No plan means no qualifier after the name; no windows
    /// means no columns and no reset — and, crucially, no subtitle either, so the row keeps the
    /// single-line height rather than reserving a second line for nothing.
    @MainActor
    func testAccountRowOmitsWhatItCannotSay() {
        var item = ThemedMenuItem(title: "Everlof")
        AccountUsageMenu.apply(
            makeUsage(windows: [window(id: "7d", fraction: 0.56, resetsIn: 54_000)]),
            to: &item,
            at: now
        )
        XCTAssertNil(item.titleDetail)
        XCTAssertEqual(item.metrics.map(\.label), ["7d"])
        XCTAssertEqual(item.trailingDetail, "7d · 15h")
        XCTAssertNil(item.subtitle)

        var empty = ThemedMenuItem(title: "Everlof")
        AccountUsageMenu.apply(makeUsage(windows: []), to: &empty, at: now)
        XCTAssertTrue(empty.metrics.isEmpty)
        XCTAssertNil(empty.trailingDetail)
        XCTAssertNil(empty.subtitle)
        XCTAssertEqual(empty.spokenSummary, "Everlof")
    }

    /// Provider cardinality belongs to the virtual popover, not to the fixed menu row. The row
    /// retains a constant number of metric/attributed values and says what it omitted.
    @MainActor
    func testProviderSizedWindowsStayBoundedInCompactMenus() {
        let windows = (0..<2_000).map { index in
            window(id: "W\(index)", fraction: 0.42, resetsIn: 54_000)
        }
        var usage = makeUsage(windows: windows)
        usage.modelWindows = (0..<2_000).map { index in
            AccountUsage.Window(
                id: "Fable-\(index)",
                label: "7d · Fable-\(index)",
                fraction: 0.43,
                resetsAt: now.addingTimeInterval(54_000),
                windowDuration: UsageDefaults.sevenDaySeconds
            )
        }

        var item = ThemedMenuItem(title: "Provider Scale")
        AccountUsageMenu.apply(usage, to: &item, at: now)

        XCTAssertEqual(item.metrics.count, UsageReadingLabel.maximumReadings)
        XCTAssertLessThanOrEqual(item.subtitleSegments?.count ?? 0, 12)
        XCTAssertTrue(
            item.subtitle?.contains(L10n.format("%d more windows", 1_997)) == true
        )
        XCTAssertLessThan(item.spokenSummary.count, 300)

        let scoped = AccountUsageMenu.scopedSegments(for: usage, at: now)
        XCTAssertLessThan(scoped.count, 12)
        XCTAssertTrue(
            scoped.map(\.text).joined().contains(L10n.format("%d more windows", 1_997))
        )
    }

    /// Banked resets are stated only when the account has some — a zero is what every account
    /// without them reports, and announcing it on all of them is noise.
    func testResetCreditsReadOnlyWhenPresent() {
        XCTAssertEqual(UsageFormat.resetCredits(1), "1 limit reset banked")
        XCTAssertEqual(UsageFormat.resetCredits(3), "3 limit resets banked")
    }

    func testNextExpiringResetCreditUsesOnlyAvailableDatedCredits() {
        var usage = makeUsage(windows: [])
        usage.resetCreditDetails = [
            .init(
                id: "spent",
                title: "Spent",
                grantedAt: nil,
                expiresAt: now.addingTimeInterval(60),
                status: "used"
            ),
            .init(
                id: "later",
                title: "Later",
                grantedAt: nil,
                expiresAt: now.addingTimeInterval(3_600),
                status: "available"
            ),
            .init(
                id: "soon",
                title: "Soon",
                grantedAt: nil,
                expiresAt: now.addingTimeInterval(600),
                status: "AVAILABLE"
            ),
            .init(
                id: "undated",
                title: "Undated",
                grantedAt: nil,
                expiresAt: nil,
                status: "available"
            )
        ]

        XCTAssertEqual(usage.nextExpiringResetCredit?.id, "soon")
    }

    // MARK: - Toned Segments

    /// The menu line's grammar: names and separators recede, a calm value keeps the line's own
    /// ink, and only a window under pressure takes its severity colour — the pill's rule,
    /// transplanted. The tint is a second signal on top of the number, never a replacement.
    @MainActor
    func testMenuSegmentsTintOnlyThePressuredValues() {
        var usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.43, resetsIn: 3600),
            window(id: "7d", fraction: 0.80, resetsIn: 86_400)
        ])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.95, resetsIn: 86_400)]

        var item = ThemedMenuItem(title: "Everlof")
        AccountUsageMenu.apply(usage, to: &item, at: now)

        XCTAssertEqual(item.metrics.map(\.tone), [.standard, .warning])
        // The scoped window keeps the same rule on the second line it fell to.
        XCTAssertEqual(tone(of: "95%", in: item.subtitleSegments ?? []), .critical)
        XCTAssertEqual(tone(of: "7d Fable ", in: item.subtitleSegments ?? []), .muted)
    }

    /// A column's bar and the number beside it come from one reading, so they cannot disagree
    /// about whether there is anything to report. An expired window prints `—` and draws an
    /// empty track — never a full one, which is what a fraction carried over from the *previous*
    /// window would have drawn.
    @MainActor
    func testAColumnsBarAndItsNumberAgreeAboutAnExpiredWindow() throws {
        let usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.9, resetsIn: -60),
            window(id: "7d", fraction: 0.37, resetsIn: 54_000)
        ])

        var item = ThemedMenuItem(title: "Keller Ines")
        AccountUsageMenu.apply(usage, to: &item, at: now)

        let expired = try XCTUnwrap(item.metrics.first)
        XCTAssertEqual(expired.value, UsageDefaults.unknownValue)
        XCTAssertNil(expired.fraction)
        XCTAssertEqual(expired.tone, .standard)

        XCTAssertEqual(item.metrics.last?.value, "37%")
        XCTAssertEqual(item.metrics.last?.fraction, 0.37)
        // The expired window is not what binds, so the reset column answers for the live one.
        XCTAssertEqual(item.trailingDetail, "7d · 15h")
    }

    /// The plain line a tooltip and VoiceOver get is the row's own parts joined, so the two
    /// cannot disagree — the numbers are columns and a drawn bar now, and neither consumer sees
    /// either of those.
    @MainActor
    func testTheSpokenLineIsTheRowsOwnParts() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.56, resetsIn: 54_000)])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: nil, resetsIn: -60)]

        var item = ThemedMenuItem(title: "Everlof")
        AccountUsageMenu.apply(usage, to: &item, at: now)

        XCTAssertEqual(item.spokenSummary, "Everlof, 7d 56%, 7d · 15h, 7d Fable —")
        // `summary` is that same assembly with no name in front of it, rather than a second
        // derivation of the same facts that could drift from what the row draws.
        XCTAssertEqual(
            AccountUsageMenu.summary(for: usage, metering: nil, at: now),
            "7d 56%, 7d · 15h, 7d Fable —"
        )
        XCTAssertEqual(
            AccountUsageMenu.modelSummarySegments(for: usage, running: "fable", at: now).map(\.text).joined(),
            AccountUsageMenu.modelSummary(for: usage, running: "fable", at: now)
        )
    }

    private func tone(
        of text: String,
        in segments: [ThemedMenuSubtitleSegment]
    ) -> ThemedMenuSubtitleSegment.Tone? {
        segments.first { $0.text == text }?.tone
    }

    // MARK: - Helpers

    private func window(
        id: String,
        fraction: Double?,
        resetsIn: TimeInterval,
        duration: TimeInterval? = nil
    ) -> AccountUsage.Window {
        AccountUsage.Window(
            id: id,
            label: id,
            fraction: fraction,
            resetsAt: now.addingTimeInterval(resetsIn),
            windowDuration: duration
        )
    }

    /// A model-scoped window as a provider builds one: identified by its model, and knowing the
    /// length it is measured in — which is what lets it be *named* like the account's own.
    private func scopedWindow(
        model: String,
        fraction: Double?,
        resetsIn: TimeInterval,
        duration: TimeInterval? = UsageDefaults.sevenDaySeconds
    ) -> AccountUsage.Window {
        AccountUsage.Window(
            id: model,
            label: "\(UsageDefaults.weeklyLabel)\(UsageDefaults.segmentSeparator)\(model)",
            fraction: fraction,
            resetsAt: now.addingTimeInterval(resetsIn),
            windowDuration: duration,
            scopeName: model
        )
    }

    private func makeUsage(windows: [AccountUsage.Window]) -> AccountUsage {
        AccountUsage(windows: windows, planLabel: nil, observedAt: now, source: .api)
    }
}
