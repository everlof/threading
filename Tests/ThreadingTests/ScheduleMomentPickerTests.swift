import XCTest
@testable import Threading

/// "Custom time…" — the sheet that replaced an alert whose two pop-ups opened a list of
/// ninety-six quarter hours one and a half rows tall.
///
/// The options are pure, so the rules that used to be invisible until somebody scheduled into
/// yesterday are arithmetic here: nothing already gone is offered, a day with nothing left in it
/// leaves the list, and the hour a row is named after is the hour it schedules — including the
/// Sunday the clocks move.
@MainActor
final class ScheduleMomentPickerTests: XCTestCase {

    // MARK: - Options

    func testSpentQuarterHoursAreNotOffered() {
        let options = ScheduleMomentOptions(
            now: moment(hour: 9, minute: 7),
            calendar: calendar,
            locale: locale
        )

        let today = options.times(onDayAt: 0)
        XCTAssertEqual(today.first?.title, "09:15")
        XCTAssertFalse(
            today.contains { $0.minutes == 9 * 60 },
            "the sheet offered a nine o'clock the store would refuse as already past"
        )
        for time in today {
            XCTAssertGreaterThan(
                options.date(dayAt: 0, minutes: time.minutes) ?? .distantPast,
                moment(hour: 9, minute: 7),
                "\(time.title) is behind the clock"
            )
        }
    }

    func testTomorrowIsOfferedWholeEvenWhileTodayIsNearlyGone() {
        let options = ScheduleMomentOptions(
            now: moment(hour: 23, minute: 20),
            calendar: calendar,
            locale: locale
        )

        XCTAssertEqual(options.days.first?.title, L10n.string("Today"))
        XCTAssertEqual(options.times(onDayAt: 0).map(\.title), ["23:30", "23:45"])
        XCTAssertEqual(options.times(onDayAt: 1).count, 96)
    }

    /// A day with nothing left in it is not a day the sheet can be used on. It used to be the
    /// first row, selected, with an empty list beside it.
    func testTodayLeavesTheListOnceItsLastQuarterHourHasGone() {
        let options = ScheduleMomentOptions(
            now: moment(hour: 23, minute: 50),
            calendar: calendar,
            locale: locale
        )

        XCTAssertEqual(options.days.first?.title, L10n.string("Tomorrow"))
        XCTAssertEqual(options.times(onDayAt: 0).count, 96)
        XCTAssertEqual(options.days.count, ScheduleMomentDefaults.dayCount - 1)
    }

    func testTheSheetOpensAtNineAndOtherwiseAtTheNextQuarterHour() {
        let morning = ScheduleMomentOptions(
            now: moment(hour: 7, minute: 12),
            calendar: calendar,
            locale: locale
        )
        XCTAssertEqual(
            morning.defaultSelection,
            ScheduleMomentOptions.Selection(dayIndex: 0, minutes: 9 * 60)
        )

        let afternoon = ScheduleMomentOptions(
            now: moment(hour: 14, minute: 3),
            calendar: calendar,
            locale: locale
        )
        XCTAssertEqual(
            afternoon.defaultSelection,
            ScheduleMomentOptions.Selection(dayIndex: 0, minutes: 14 * 60 + 15),
            "an afternoon sheet opened on a row it could not schedule"
        )
    }

    /// `Calendar` places the wall-clock hour; minutes added to midnight do not. On the Sunday
    /// Sweden springs forward, 570 minutes past midnight is ten o'clock — an hour late for the
    /// working-day start the row is named after.
    func testAChosenHourSurvivesADaylightSavingTransition() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Stockholm"))

        // Saturday 29 March 2025; the clocks move forward at 02:00 on the Sunday.
        let saturday = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2025, month: 3, day: 29, hour: 12
        )))
        let options = ScheduleMomentOptions(now: saturday, calendar: calendar, locale: locale)
        let sunday = try XCTUnwrap(options.date(dayAt: 1, minutes: 9 * 60))

        XCTAssertEqual(calendar.component(.hour, from: sunday), 9)
        XCTAssertEqual(calendar.component(.minute, from: sunday), 0)

        let naive = try XCTUnwrap(calendar.date(
            byAdding: .minute,
            value: 9 * 60,
            to: calendar.startOfDay(for: options.days[1].date)
        ))
        XCTAssertNotEqual(naive, sunday, "the transition was arithmetic rather than a calendar's")
    }

    // MARK: - The Sheet

    func testChoosingADayMovesATimeThatDayNoLongerHas() {
        let picker = makePicker(now: moment(hour: 14, minute: 0))
        picker.loadView()

        picker.selectDay(at: 1)
        picker.selectTime(minutes: 15)
        XCTAssertFalse(picker.summaryForTesting.isEmpty)

        picker.selectDay(at: 0)
        XCTAssertEqual(
            picker.visibleTimeTitlesForTesting.first,
            "14:15",
            "today kept a quarter hour that had already gone"
        )
        XCTAssertTrue(picker.confirmButtonIsEnabledForTesting)
        let chosen = picker.selectedMoment
        XCTAssertEqual(chosen, expected(hour: 14, minute: 15))
    }

    func testConfirmAnswersTheChosenMomentAndCancelAnswersNothing() {
        let picker = makePicker(now: moment(hour: 7, minute: 0))
        picker.loadView()

        var answers: [Date?] = []
        picker.onPick = { answers.append($0) }

        picker.selectTime(minutes: 17 * 60 + 30)
        picker.confirm()
        picker.cancel()

        XCTAssertEqual(answers.count, 2)
        XCTAssertEqual(answers.first ?? nil, expected(hour: 17, minute: 30))
        XCTAssertNil(answers.last ?? nil)
    }

    func testTheSheetSaysWhichDayAndTimeItIsAsking() {
        let picker = makePicker(now: moment(hour: 7, minute: 0))
        picker.loadView()

        XCTAssertEqual(
            Array(picker.dayTitlesForTesting.prefix(2)),
            [L10n.string("Today"), L10n.string("Tomorrow")]
        )
        // 07:15 through 23:45 — everything today has left at seven in the morning.
        XCTAssertEqual(picker.visibleTimeTitlesForTesting.count, 67)
        XCTAssertFalse(picker.summaryForTesting.isEmpty, "the sheet chose a moment it did not state")
    }

    /// The row the list highlights is the moment the sheet would schedule. A list that refuses
    /// an empty selection re-picks its first row after a reload and posts it late, which opened
    /// the time list on the next quarter hour while the sheet said nine o'clock underneath it.
    func testTheHighlightedRowIsTheMomentTheSheetWouldSchedule() {
        let picker = makePicker(now: moment(hour: 7, minute: 0))
        picker.loadView()
        picker.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(picker.selectedTimeTitleForTesting, "09:00")
        XCTAssertEqual(picker.selectedMoment, expected(hour: 9, minute: 0))
    }

    /// The name and the date sit in the middle of the slot the selection fills, not against its
    /// top edge.
    ///
    /// A vertical `NSStackView` built from `init(views:)` puts its arranged views in the leading
    /// gravity area, which for a vertical stack is the top — so the pair sat at the top of the
    /// row with all of `dayRowHeight`'s spare height under it. Nothing failed: the ink was there,
    /// in order, at the right size. It read as a selection plate with its text shoved into the
    /// corner of it, and as a first row whose name touched the panel's own border.
    func testADayRowCentresItsNameAndDateInTheRow() throws {
        let picker = makePicker(now: moment(hour: 7, minute: 0))
        picker.loadView()
        picker.view.layoutSubtreeIfNeeded()

        let days = try XCTUnwrap(
            descendants(of: picker.view).compactMap { $0 as? ThemedTableView }.first
        )
        let cell = try XCTUnwrap(picker.tableView(
            days,
            viewFor: days.tableColumns.first,
            row: 0
        ))
        cell.setFrameSize(NSSize(
            width: ScheduleMomentPickerLayout.dayColumnWidth,
            height: days.rowHeight
        ))
        cell.layoutSubtreeIfNeeded()

        let labels = descendants(of: cell).compactMap { $0 as? NSTextField }
        XCTAssertEqual(labels.count, 2, "a day row states its name and its date")

        let ink = labels.reduce(NSRect.null) { union, label in
            union.union(cell.convert(label.bounds, from: label))
        }
        XCTAssertGreaterThan(ink.height, 0)
        XCTAssertEqual(
            ink.midY,
            cell.bounds.midY,
            accuracy: 1,
            "the labels sit \(ink.minY)pt from the bottom and \(cell.bounds.maxY - ink.maxY)pt "
                + "from the top of a \(cell.bounds.height)pt row"
        )
        XCTAssertGreaterThan(
            cell.bounds.maxY - ink.maxY,
            Design.Spacing.tight,
            "the top line of the row is against its own edge"
        )
    }

    /// The component contract every themed surface carries, on the sheet that is now the whole
    /// answer rather than an accessory inside an alert.
    func testPickerPassesTheThemeBoundaryAndRendersDistinctLiveThemes() throws {
        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }

        let picker = makePicker(now: moment(hour: 7, minute: 0))
        picker.loadView()
        picker.view.layoutSubtreeIfNeeded()

        let lists = descendants(of: picker.view).compactMap { $0 as? ThemedTableView }
        XCTAssertEqual(
            lists.compactMap { $0.accessibilityLabel() },
            [L10n.string("Day"), L10n.string("Time")]
        )
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: picker.view), [])

        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map {
            URL(fileURLWithPath: $0)
        } ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let variants: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua)
        ]
        var renders = Set<Data>()
        for (name, theme, appearance) in variants {
            // One loaded sheet receives each change: recreating it would not prove the lists
            // follow a theme switched while they are open.
            AppThemeLibrary.apply(theme)
            picker.view.appearance = NSAppearance(named: appearance)
            picker.view.layoutSubtreeIfNeeded()
            let twoLines = Design.Typography.lineHeight(of: Design.Typography.body())
                + Design.Typography.lineHeight(of: Design.Typography.subheading())
                + Design.Spacing.hairline
                + 2 * Design.Spacing.small
            XCTAssertGreaterThanOrEqual(
                lists[0].rowHeight,
                twoLines,
                "\(name): adjacent day rows overlap"
            )
            XCTAssertGreaterThanOrEqual(
                lists[1].rowHeight,
                Design.Typography.lineHeight(of: Design.Typography.numericBody()),
                "\(name): adjacent time rows overlap"
            )
            let data = try renderedPNG(of: picker.view)
            renders.insert(data)
            try data.write(to: directory.appendingPathComponent("schedule-moment-\(name).png"))
        }

        XCTAssertEqual(renders.count, variants.count, "the open sheet ignored a theme change")
    }

    // MARK: - Helpers

    private var locale: Locale { Locale(identifier: "en_GB") }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private func moment(hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: hour,
            minute: minute
        )) ?? Date()
    }

    private func expected(hour: Int, minute: Int) -> Date? {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: hour,
            minute: minute
        ))
    }

    private func makePicker(now: Date) -> ScheduleMomentPickerViewController {
        ScheduleMomentPickerViewController(
            title: L10n.string("Schedule session"),
            note: ScheduleMomentPickerStrings.note(nil, locale: locale),
            confirmTitle: ScheduleMomentPickerStrings.scheduleMessage,
            now: now,
            calendar: calendar,
            locale: locale
        )
    }

    private func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    private func renderedPNG(of view: NSView) throws -> Data {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
