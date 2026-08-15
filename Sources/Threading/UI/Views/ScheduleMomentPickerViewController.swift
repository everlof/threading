import AppKit

// MARK: - The Options

/// Which day and which quarter hour may be chosen, and where a freshly opened sheet lands.
///
/// Pure, so every rule below is a test rather than something only a screenshot can disprove.
/// Two facts live here that the surface must not re-decide:
///
/// - **A moment already gone is not offered.** `ScheduledMessageStore` refuses `dueAt <= now`
///   with `.inThePast`, so a list that keeps this morning's nine o'clock in it at four in the
///   afternoon is a list whose top half answers with a refusal sheet. Today's spent quarter
///   hours are dropped, and a today with nothing left in it drops out of the day list entirely
///   rather than sitting there as a day whose times are all gone.
/// - **`Calendar` places the wall-clock time**, never minutes added to midnight. Adding 570
///   minutes to the start of a spring-forward Sunday lands at ten o'clock, which is the one
///   direction that matters for a working-day start; `date(bySettingHour:minute:second:of:)`
///   answers with the hour the row is named after. The same call resolves the hour a transition
///   skips to the next real moment, so an unpickable row never becomes an unschedulable send.
struct ScheduleMomentOptions {

    // MARK: - Values

    /// One day, as the list says it: the name that identifies it, and the date under it.
    struct Day: Equatable {
        /// `Today`, `Tomorrow`, or the day's own name.
        let title: String
        /// The date itself — `15 Aug` — under the name, because "Saturday" alone is a promise
        /// somebody has to count on a calendar to check.
        let detail: String
        /// The start of that day, in the caller's calendar.
        let date: Date
    }

    /// One quarter hour, written in the user's own clock convention — so a 24-hour locale reads
    /// `09:00` and never `9:00 AM`.
    struct Time: Equatable {
        let title: String
        /// Minutes past midnight. The durable half of a row: a title is a rendering of it.
        let minutes: Int
    }

    /// A day and a time, as one answer.
    struct Selection: Equatable {
        let dayIndex: Int
        let minutes: Int
    }

    // MARK: - Properties

    /// The days with at least one quarter hour still ahead of them, nearest first.
    let days: [Day]

    private let allTimes: [Time]
    private let now: Date
    private let calendar: Calendar

    // MARK: - Initialization

    init(now: Date, calendar: Calendar = .current, locale: Locale = .current) {
        var calendar = calendar
        calendar.locale = locale
        let times = Self.quarterHours(calendar: calendar, locale: locale)
        self.now = now
        self.calendar = calendar
        self.allTimes = times

        // The zone travels with the calendar. A formatter takes the system's own unless told
        // otherwise, and one reading a date the calendar placed in a different zone names the
        // day before it — which is a wrong row title in the app and an unrepeatable test.
        let names = DateFormatter()
        names.locale = locale
        names.calendar = calendar
        names.timeZone = calendar.timeZone
        names.setLocalizedDateFormatFromTemplate(ScheduleMomentDefaults.dayNameTemplate)

        let dates = DateFormatter()
        dates.locale = locale
        dates.calendar = calendar
        dates.timeZone = calendar.timeZone
        dates.setLocalizedDateFormatFromTemplate(ScheduleMomentDefaults.dayDetailTemplate)

        let midnight = calendar.startOfDay(for: now)
        self.days = (0..<ScheduleMomentDefaults.dayCount).compactMap { offset -> Day? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: midnight) else {
                return nil
            }
            // Only the first day can have run out; every later one is offered whole. Asking the
            // question of all of them anyway keeps the rule in one place.
            guard !Self.available(times, on: date, after: now, calendar: calendar).isEmpty else {
                return nil
            }

            let title: String
            switch offset {
            case 0: title = L10n.string("Today")
            case 1: title = L10n.string("Tomorrow")
            default: title = names.string(from: date)
            }
            return Day(title: title, detail: dates.string(from: date), date: date)
        }
    }

    // MARK: - Public Methods

    /// The quarter hours still ahead on the day at `index`.
    func times(onDayAt index: Int) -> [Time] {
        guard days.indices.contains(index) else { return [] }
        return Self.available(allTimes, on: days[index].date, after: now, calendar: calendar)
    }

    /// The moment a day and a time name together.
    func date(dayAt index: Int, minutes: Int) -> Date? {
        guard days.indices.contains(index) else { return nil }
        return Self.moment(minutes, on: days[index].date, calendar: calendar)
    }

    /// Where the sheet opens: nine o'clock on the nearest day that still has it, and otherwise
    /// the nearest quarter hour that day has left. The morning is the same one the presets aim
    /// at, so the menu and the sheet agree about when a working day starts; the fallback is
    /// what keeps an afternoon "Custom time…" from opening on a row it cannot use.
    var defaultSelection: Selection? {
        guard !days.isEmpty else { return nil }
        let available = times(onDayAt: 0)
        guard let first = available.first else { return nil }
        let morning = available.first { $0.minutes == ScheduleMomentDefaults.defaultMinutes }
        return Selection(dayIndex: 0, minutes: (morning ?? first).minutes)
    }

    // MARK: - Private Methods

    private static func quarterHours(calendar: Calendar, locale: Locale) -> [Time] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none

        // A fixed reference day rather than today's: the titles are a clock face, and reading
        // them off a day with a transition in it would name one of them twice.
        let reference = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return stride(
            from: 0,
            to: ScheduleMomentDefaults.minutesInADay,
            by: ScheduleMomentDefaults.step
        ).compactMap { minutes in
            guard let date = calendar.date(byAdding: .minute, value: minutes, to: reference) else {
                return nil
            }
            return Time(title: formatter.string(from: date), minutes: minutes)
        }
    }

    private static func available(
        _ times: [Time],
        on day: Date,
        after now: Date,
        calendar: Calendar
    ) -> [Time] {
        times.filter { time in
            guard let moment = moment(time.minutes, on: day, calendar: calendar) else {
                return false
            }
            return moment > now
        }
    }

    private static func moment(_ minutes: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: day,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

// MARK: - The Sheet

/// "Custom time…": a day, a quarter hour, and the sentence that says what was chosen.
///
/// **A sheet with two lists, not an alert with two pop-ups.** It was the latter, and the
/// dropdown was the bug: `ThemedMenuPresenter` draws its panel *inside the window it was opened
/// from*, which for an alert is a borderless panel sized to its own text — so a list of ninety-six
/// quarter hours opened with room for one and a half rows of it, above a sheet too small to say
/// what it was asking. Growing the alert cannot fix that; a day's worth of quarter hours will
/// outgrow any dialog a dropdown can be opened inside. Lists that *are* the sheet scroll instead
/// of opening, take a mouse wheel and a typed `14`, and show fifteen answers at once.
///
/// **It names the time zone, and it names the limitation.** Slack's own dialog states the zone
/// because a scheduled time is otherwise ambiguous; this states it for the same reason, and adds
/// the sentence Slack has no need for — Threading is not a server, and a moment that passes while
/// the app is closed is one it will ask about rather than act on.
@MainActor
final class ScheduleMomentPickerViewController: NSViewController {

    // MARK: - Properties

    private let options: ScheduleMomentOptions
    private let heading: String
    private let note: String
    private let confirmTitle: String
    private let now: Date

    private var dayIndex = 0
    private var minutes = ScheduleMomentDefaults.defaultMinutes
    private var visibleTimes: [ScheduleMomentOptions.Time] = []
    private var isRewritingList = false

    private let headingLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let dayCaption = NSTextField(labelWithString: "")
    private let timeCaption = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let dayTable = ThemedTableView()
    private let timeTable = ThemedTableView()
    private let confirmButton = ThemedButton()
    private let appEvents = AppEventObservations()

    /// The chosen moment, or nil when Cancel closes the sheet.
    var onPick: ((Date?) -> Void)?

    // MARK: - Initialization

    init(
        title: String,
        note: String,
        confirmTitle: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) {
        self.heading = title
        self.note = note
        self.confirmTitle = confirmTitle
        self.now = now
        self.options = ScheduleMomentOptions(now: now, calendar: calendar, locale: locale)
        super.init(nibName: nil, bundle: nil)

        if let selection = options.defaultSelection {
            dayIndex = selection.dayIndex
            minutes = selection.minutes
        }
        visibleTimes = options.times(onDayAt: dayIndex)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Presentation

    /// Asks for a moment over the view controller that owns the screen behind it. Answers nil
    /// if the sheet was cancelled, which is the contract every call site already had.
    static func present(
        over presenter: NSViewController,
        title: String,
        informativeText: String? = nil,
        confirmTitle: String = ScheduleMomentPickerStrings.scheduleMessage,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        completion: @escaping (Date?) -> Void
    ) {
        let picker = ScheduleMomentPickerViewController(
            title: title,
            note: ScheduleMomentPickerStrings.note(informativeText, locale: locale),
            confirmTitle: confirmTitle,
            now: now,
            calendar: calendar,
            locale: locale
        )
        picker.onPick = { [weak presenter, weak picker] date in
            if let presenter, let picker { presenter.dismiss(picker) }
            completion(date)
        }
        presenter.presentAsSheet(picker)
    }

    // MARK: - Lifecycle

    override func loadView() {
        let surface = ThemedSurfaceView()
        surface.frame = NSRect(
            x: 0,
            y: 0,
            width: ScheduleMomentPickerLayout.sheetWidth,
            height: ScheduleMomentPickerLayout.sheetHeight
        )
        surface.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        view = surface
        setupViews()
        rewritingLists {
            dayTable.reloadData()
            timeTable.reloadData()
            restoreSelection()
        }
        refreshSummary()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
        applyTheme()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(timeTable)
        // The chosen hour is a long way down a day's worth of quarter hours, and a list that
        // opens at midnight reads as a list with nothing selected in it.
        showSelectedTime()
    }

    // MARK: - Setup

    private func setupViews() {
        headingLabel.stringValue = heading
        headingLabel.applyFont(.heading)

        noteLabel.stringValue = note
        noteLabel.applyFont(.subheading)
        noteLabel.maximumNumberOfLines = 0
        noteLabel.preferredMaxLayoutWidth = ScheduleMomentPickerLayout.sheetWidth
            - 2 * Design.Spacing.pane

        let headings = NSStackView(views: [headingLabel, noteLabel])
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = Design.Spacing.hairline

        summaryLabel.applyFont(.body)

        let stack = NSStackView(views: [headings, makeLists(), summaryLabel, makeFooter()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.setCustomSpacing(Design.Spacing.large, after: headings)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            stack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            stack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.pane
            )
        ])
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// The two lists, each under its own name. The captions are what keep a column of `09:00`s
    /// from having to be recognised: a list of times beside a list of days is only obvious to
    /// somebody who already knows what the sheet asks.
    private func makeLists() -> NSView {
        dayCaption.stringValue = ScheduleMomentPickerStrings.dayCaption
        dayCaption.applyFont(.subheading)
        timeCaption.stringValue = ScheduleMomentPickerStrings.timeCaption
        timeCaption.applyFont(.subheading)

        let days = makeList(
            dayTable,
            column: ScheduleMomentPickerColumn.day,
            rowHeight: ScheduleMomentPickerLayout.dayRowHeight,
            accessibilityLabel: ScheduleMomentPickerStrings.dayCaption
        )
        let times = makeList(
            timeTable,
            column: ScheduleMomentPickerColumn.time,
            rowHeight: ScheduleMomentPickerLayout.timeRowHeight,
            accessibilityLabel: ScheduleMomentPickerStrings.timeCaption
        )

        let dayColumn = NSStackView(views: [dayCaption, days])
        dayColumn.orientation = .vertical
        dayColumn.alignment = .leading
        dayColumn.spacing = Design.Spacing.small
        days.widthAnchor.constraint(equalTo: dayColumn.widthAnchor).isActive = true

        let timeColumn = NSStackView(views: [timeCaption, times])
        timeColumn.orientation = .vertical
        timeColumn.alignment = .leading
        timeColumn.spacing = Design.Spacing.small
        times.widthAnchor.constraint(equalTo: timeColumn.widthAnchor).isActive = true

        let row = NSStackView(views: [dayColumn, timeColumn])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        dayColumn.widthAnchor.constraint(
            equalToConstant: ScheduleMomentPickerLayout.dayColumnWidth
        ).isActive = true
        timeColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func makeList(
        _ table: ThemedTableView,
        column: NSUserInterfaceItemIdentifier,
        rowHeight: CGFloat,
        accessibilityLabel: String
    ) -> NSView {
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.rowHeight = rowHeight
        table.style = .inset
        // **Not `allowsEmptySelection = false`.** A list that refuses an empty selection picks
        // its first row back for itself after a reload, and posts that choice late enough to
        // land after the sheet's own — which opened the time list on the first quarter hour
        // while the sheet said nine o'clock underneath it. The selection is restored explicitly
        // here instead; `restoreSelection` is the only thing that decides it.
        table.doubleAction = #selector(confirm)
        table.target = self
        table.setAccessibilityLabel(accessibilityLabel)
        table.addTableColumn(NSTableColumn(identifier: column))

        let scrollView = ThemedScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: ScheduleMomentPickerLayout.minimumListHeight
        ).isActive = true
        return scrollView
    }

    private func makeFooter() -> NSView {
        confirmButton.title = confirmTitle
        confirmButton.isProminent = true
        confirmButton.keyEquivalent = "\r"
        confirmButton.target = self
        confirmButton.action = #selector(confirm)

        let cancelButton = ThemedButton(
            title: ScheduleMomentPickerStrings.cancel,
            target: self,
            action: #selector(cancel)
        )
        cancelButton.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [spacer, cancelButton, confirmButton])
        footer.orientation = .horizontal
        footer.spacing = Design.Spacing.small
        return footer
    }

    // MARK: - Selection

    /// The moment the two lists name together, or nil while there is nothing to schedule.
    var selectedMoment: Date? {
        options.date(dayAt: dayIndex, minutes: minutes)
    }

    var visibleTimeTitlesForTesting: [String] { visibleTimes.map(\.title) }
    var selectedTimeTitleForTesting: String? {
        timeTable.selectedRow >= 0 && visibleTimes.indices.contains(timeTable.selectedRow)
            ? visibleTimes[timeTable.selectedRow].title
            : nil
    }
    var dayTitlesForTesting: [String] { options.days.map(\.title) }
    var confirmButtonIsEnabledForTesting: Bool { confirmButton.isEnabled }
    var summaryForTesting: String { summaryLabel.stringValue }

    /// Chooses a day, keeping the time where it can and moving it forward where it cannot —
    /// today's list starts later than tomorrow's, and a selection that survived into a shorter
    /// list would be a row nobody picked.
    func selectDay(at index: Int) {
        guard options.days.indices.contains(index) else { return }
        dayIndex = index
        let times = options.times(onDayAt: index)
        if !times.contains(where: { $0.minutes == minutes }) {
            minutes = (times.first { $0.minutes >= minutes } ?? times.first)?.minutes ?? minutes
        }
        visibleTimes = times
        rewritingLists {
            timeTable.reloadData()
            restoreSelection()
        }
        refreshSummary()
        showSelectedTime()
    }

    func selectTime(minutes value: Int) {
        guard visibleTimes.contains(where: { $0.minutes == value }) else { return }
        minutes = value
        rewritingLists { restoreSelection() }
        refreshSummary()
    }

    private func restoreSelection() {
        if options.days.indices.contains(dayIndex) {
            dayTable.selectRowIndexes(IndexSet(integer: dayIndex), byExtendingSelection: false)
        } else {
            dayTable.deselectAll(nil)
        }

        guard let row = visibleTimes.firstIndex(where: { $0.minutes == minutes }) else {
            timeTable.deselectAll(nil)
            return
        }
        timeTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func showSelectedTime() {
        guard let row = visibleTimes.firstIndex(where: { $0.minutes == minutes }) else { return }
        timeTable.scrollRowToVisible(row)
    }

    private func rewritingLists(_ work: () -> Void) {
        isRewritingList = true
        work()
        isRewritingList = false
    }

    /// The receipt, restated as the two lists change: the absolute moment and how far away it
    /// is, in the same words the scheduled strip will use once the sheet is gone.
    private func refreshSummary() {
        guard let moment = selectedMoment else {
            summaryLabel.stringValue = ScheduleMomentPickerStrings.nothingToSchedule
            confirmButton.isEnabled = false
            return
        }
        summaryLabel.stringValue = ScheduledTiming.sentence(for: moment, from: now)
        confirmButton.isEnabled = true
    }

    // MARK: - Theme

    private func applyTheme() {
        headingLabel.textColor = Design.Text.label
        noteLabel.textColor = Design.Text.secondary
        dayCaption.textColor = Design.Text.secondary
        timeCaption.textColor = Design.Text.secondary
        summaryLabel.textColor = Design.Text.label
        // Row heights follow the theme's own line boxes, so a face with a taller metric does not
        // overlap the row under it. Only the viewport is rebuilt.
        dayTable.rowHeight = ScheduleMomentPickerLayout.dayRowHeight
        timeTable.rowHeight = ScheduleMomentPickerLayout.timeRowHeight
        rewritingLists {
            dayTable.reloadData()
            timeTable.reloadData()
            restoreSelection()
        }
    }

    // MARK: - Actions

    @objc func confirm() {
        guard let moment = selectedMoment else { return }
        onPick?(moment)
    }

    @objc func cancel() {
        onPick?(nil)
    }

    // MARK: - Rows

    /// A day's name over its date, centred in the slot the selection fills.
    ///
    /// **The pair is centred by a constraint, not by the stack.** A vertical `NSStackView` built
    /// from `init(views:)` puts everything in its leading gravity area, which is the top — so the
    /// two labels sat against the row's top edge with the row's whole spare height left under
    /// them. Every assertion about this row passed: the ink was there, in the right order, at the
    /// right size. What it looked like was a selection plate with its text shoved into the top of
    /// it, and a first row whose name touched the panel's own border. `dayRowHeight` states a
    /// floor as well as a computed height, so the spare space is real and has to be spent
    /// deliberately rather than all at one end.
    private func makeDayRow(_ day: ScheduleMomentOptions.Day) -> NSView {
        let title = NSTextField(labelWithString: day.title)
        title.applyFont(.body)
        title.textColor = Design.Text.label

        let detail = NSTextField(labelWithString: day.detail)
        detail.applyFont(.subheading)
        detail.textColor = Design.Text.tertiary

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSView()
        cell.addSubview(labels)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(
                equalTo: cell.leadingAnchor,
                constant: Design.Spacing.small
            ),
            labels.trailingAnchor.constraint(
                lessThanOrEqualTo: cell.trailingAnchor,
                constant: -Design.Spacing.small
            ),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            // A row that somehow holds more than it was measured for grows the cell honestly
            // rather than drawing over its neighbour.
            labels.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor)
        ])
        return cell
    }

    private func makeTimeRow(_ time: ScheduleMomentOptions.Time) -> NSView {
        let title = NSTextField(labelWithString: time.title)
        // Tabular figures: a column of clock faces whose digits shift width is a column that
        // reads as ragged even though every string is the same length.
        title.applyFont(.numericBody)
        title.textColor = Design.Text.label

        let row = NSStackView(views: [title])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Design.Spacing.small,
            bottom: 0,
            right: Design.Spacing.small
        )
        return row
    }
}

// MARK: - Lists

extension ScheduleMomentPickerViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === dayTable ? options.days.count : visibleTimes.count
    }
}

extension ScheduleMomentPickerViewController: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if tableView === dayTable {
            guard options.days.indices.contains(row) else { return nil }
            return makeDayRow(options.days[row])
        }
        guard visibleTimes.indices.contains(row) else { return nil }
        return makeTimeRow(visibleTimes[row])
    }

    /// Typing `14` walks to two o'clock, the way typing into a pop-up's list did. The lists are
    /// the reason the pop-ups went away, so the one thing those pop-ups were better at comes
    /// with them.
    func tableView(
        _ tableView: NSTableView,
        typeSelectStringFor tableColumn: NSTableColumn?,
        row: Int
    ) -> String? {
        if tableView === dayTable {
            guard options.days.indices.contains(row) else { return nil }
            return options.days[row].title
        }
        guard visibleTimes.indices.contains(row) else { return nil }
        return visibleTimes[row].title
    }

    /// A list that lost its selection keeps the sheet's answer rather than clearing it: a
    /// reload's own bookkeeping is not somebody changing their mind.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRewritingList,
              let table = notification.object as? NSTableView else { return }
        if table === dayTable {
            selectDay(at: table.selectedRow)
            return
        }
        let row = table.selectedRow
        guard visibleTimes.indices.contains(row), visibleTimes[row].minutes != minutes else {
            return
        }
        minutes = visibleTimes[row].minutes
        refreshSummary()
    }
}

// MARK: - Constants

enum ScheduleMomentPickerColumn {
    static let day = NSUserInterfaceItemIdentifier("ScheduleMomentDayColumn")
    static let time = NSUserInterfaceItemIdentifier("ScheduleMomentTimeColumn")
}

@MainActor
enum ScheduleMomentPickerLayout {
    static let sheetWidth: CGFloat = 520
    static let sheetHeight: CGFloat = 460
    /// Wide enough for `Wednesday` over `17 Sept` without truncating either.
    static let dayColumnWidth: CGFloat = 180
    static let minimumListHeight: CGFloat = 240
    static let minimumDayRowHeight: CGFloat = 44
    static let minimumTimeRowHeight: CGFloat = 28

    static var dayRowHeight: CGFloat {
        max(
            minimumDayRowHeight,
            Design.Typography.lineHeight(of: Design.Typography.body())
                + Design.Typography.lineHeight(of: Design.Typography.subheading())
                + Design.Spacing.hairline
                + 2 * Design.Spacing.small
        )
    }

    static var timeRowHeight: CGFloat {
        max(
            minimumTimeRowHeight,
            Design.Typography.lineHeight(of: Design.Typography.numericBody())
                + 2 * Design.Spacing.tight
        )
    }
}

enum ScheduleMomentDefaults {
    static let dayCount = 14
    static let step = 15
    static let minutesInADay = 24 * 60

    /// Where the time list opens: the same nine o'clock the presets aim at, so the sheet and
    /// the menu agree about when a working day starts.
    static let defaultMinutes = PresetDefaults.morningHour * 60

    static let dayNameTemplate = "EEEE"
    static let dayDetailTemplate = "dMMM"
}

enum ScheduleMomentPickerStrings {
    static var scheduleMessage: String { L10n.string("Schedule Message") }
    static var cancel: String { L10n.string("Cancel") }
    static var dayCaption: String { L10n.string("Day") }
    static var timeCaption: String { L10n.string("Time") }
    static var nothingToSchedule: String { L10n.string("No time left today.") }

    /// The time zone, then what the caller wanted said. Two facts on one line: a scheduled time
    /// with no zone beside it is ambiguous, and a Mac that is asleep at nine is not a server.
    static func note(_ informativeText: String?, locale: Locale = .current) -> String {
        let zone = L10n.format(
            "Time zone: %@",
            TimeZone.current.localizedName(for: .generic, locale: locale)
                ?? TimeZone.current.identifier
        )
        let detail = informativeText ?? L10n.string("Sends while Threading is running.")
        return L10n.format("%@ · %@", zone, detail)
    }
}
