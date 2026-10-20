import AppKit

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

        summaryLabel.applyFont(.body)
        ScheduleMomentPickerLayout.attach(
            headings: ScheduleMomentPickerLayout.headings(headingLabel, noteLabel),
            lists: makeLists(), summary: summaryLabel, footer: makeFooter(), to: view
        )
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

        return ScheduleMomentPickerLayout.lists(
            dayCaption: dayCaption, dayScroll: days,
            timeCaption: timeCaption, timeScroll: times
        )
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
        scrollView.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )
        ScheduleMomentPickerLayout.prepareList(scrollView)
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
        return ScheduleMomentPickerLayout.footer(
            spacer: spacer, cancel: cancelButton, confirm: confirmButton
        )
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
            return ScheduleMomentPickerRows.makeDayRow(options.days[row])
        }
        guard visibleTimes.indices.contains(row) else { return nil }
        return ScheduleMomentPickerRows.makeTimeRow(visibleTimes[row])
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
