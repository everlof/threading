import AppKit

/// The custom-time sheet body used by AppKit and the Linux AppKit shim. Hosts own only
/// presentation and input delivery; this view owns the lists, selection, summary and actions.
@MainActor
final class ScheduleMomentPickerView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column { case day, time }

    private let options: ScheduleMomentOptions
    private let openedAt: Date
    private let summaryText: (Date, Date) -> String
    private let canConfirm: (Date, Date) -> Bool
    private var dayIndex = 0
    private var minutes = ScheduleMomentDefaults.defaultMinutes
    private var visibleTimes: [ScheduleMomentOptions.Time] = []
    private var rewritingSelection = false
    private var activeColumn: Column = .time
    private var needsInitialScroll = true

    private let dayTable = ThemedTableView(frame: .zero)
    private let timeTable = ThemedTableView(frame: .zero)
    private let dayScroll = ThemedScrollView(frame: .zero)
    private let timeScroll = ThemedScrollView(frame: .zero)
    private let headingLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let dayCaption = NSTextField(labelWithString: "")
    private let timeCaption = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let cancelButton = ThemedButton()
    private let confirmButton = ThemedButton()
#if !os(Linux)
    private let appEvents = AppEventObservations()
#endif

    var onConfirm: ((Date) -> Void)?
    var onCancel: (() -> Void)?

    var selectedMoment: Date? { options.date(dayAt: dayIndex, minutes: minutes) }
    var dayCount: Int { options.days.count }
    var timeCount: Int { visibleTimes.count }
    var selectedDay: Int { dayIndex }
    var selectedTime: Int { visibleTimes.firstIndex { $0.minutes == minutes } ?? -1 }
    var selectedTimeTitle: String? {
        visibleTimes.indices.contains(timeTable.selectedRow)
            ? visibleTimes[timeTable.selectedRow].title : nil
    }
    var dayTitles: [String] { options.days.map(\.title) }
    var summaryValue: String { summary.stringValue }
    var confirmIsEnabled: Bool { confirmButton.isEnabled }
    var timeTitles: [String] { visibleTimes.map(\.title) }
    var preferredFirstResponder: NSView { timeTable }
    var cancelFrame: NSRect { cancelButton.convert(cancelButton.bounds, to: self) }
    var confirmFrame: NSRect { confirmButton.convert(confirmButton.bounds, to: self) }

    init(title: String, note: String, confirmTitle: String,
         now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current,
         summaryText: ((Date, Date) -> String)? = nil,
         canConfirm: @escaping (Date, Date) -> Bool = { moment, openedAt in moment > openedAt }) {
        openedAt = now
        self.summaryText = summaryText ?? { date, _ in
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        self.canConfirm = canConfirm
        options = ScheduleMomentOptions(now: now, calendar: calendar, locale: locale)
        super.init(frame: NSRect(x: 0, y: 0,
            width: ScheduleMomentPickerLayout.sheetWidth,
            height: ScheduleMomentPickerLayout.sheetHeight))
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Surface.background, radius: .fixed(0))

        if let selection = options.defaultSelection {
            dayIndex = selection.dayIndex
            minutes = selection.minutes
        }
        visibleTimes = options.times(onDayAt: dayIndex)

        headingLabel.stringValue = title
        headingLabel.applyFont(.heading)
        headingLabel.textColor = Design.Text.label
        noteLabel.stringValue = note
        noteLabel.applyFont(.subheading)
        noteLabel.textColor = Design.Text.secondary
        noteLabel.maximumNumberOfLines = 0
        noteLabel.preferredMaxLayoutWidth = ScheduleMomentPickerLayout.sheetWidth
            - 2 * Design.Spacing.pane
        let headings = ScheduleMomentPickerLayout.headings(headingLabel, noteLabel)

        dayCaption.stringValue = ScheduleMomentPickerStrings.dayCaption
        dayCaption.applyFont(.subheading)
        dayCaption.textColor = Design.Text.secondary
        timeCaption.stringValue = ScheduleMomentPickerStrings.timeCaption
        timeCaption.applyFont(.subheading)
        timeCaption.textColor = Design.Text.secondary
        configure(dayTable, in: dayScroll, rowHeight: ScheduleMomentPickerLayout.dayRowHeight,
                  column: ScheduleMomentPickerColumn.day,
                  label: ScheduleMomentPickerStrings.dayCaption)
        configure(timeTable, in: timeScroll, rowHeight: ScheduleMomentPickerLayout.timeRowHeight,
                  column: ScheduleMomentPickerColumn.time,
                  label: ScheduleMomentPickerStrings.timeCaption)
        let lists = ScheduleMomentPickerLayout.lists(
            dayCaption: dayCaption, dayScroll: dayScroll,
            timeCaption: timeCaption, timeScroll: timeScroll
        )

        summary.applyFont(.body)
        summary.textColor = Design.Text.label
        cancelButton.title = ScheduleMomentPickerStrings.cancel
        cancelButton.emphasis = .secondary
        confirmButton.title = confirmTitle
        confirmButton.emphasis = .primary
#if os(Linux)
        cancelButton.action = { [weak self] in self?.onCancel?() }
        confirmButton.action = { [weak self] in
            guard let self, let date = self.selectedMoment else { return }
            self.onConfirm?(date)
        }
#else
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"
        confirmButton.target = self
        confirmButton.action = #selector(confirmPressed)
        confirmButton.keyEquivalent = "\r"
#endif
        let footer = ScheduleMomentPickerLayout.footer(
            spacer: NSView(), cancel: cancelButton, confirm: confirmButton
        )
        ScheduleMomentPickerLayout.attach(
            headings: headings, lists: lists, summary: summary, footer: footer, to: self
        )
        dayTable.reloadData()
        timeTable.reloadData()
        restoreSelection()
        // Match the Mac sheet's initial first responder. Programmatic selection notifications
        // during setup must not decide which list subsequent arrow keys navigate.
        activeColumn = .time
        refreshSummary()
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
#if !os(Linux)
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
#endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

#if !os(Linux)
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AppThemeRefresh.repaint(self)
        applyTheme()
    }
#endif

    override func layout() {
        super.layout()
        if needsInitialScroll, timeScroll.contentView.bounds.height > 0 {
            needsInitialScroll = false
            timeTable.scrollRowToVisible(selectedTime)
        }
    }

#if !os(Linux)
    @objc private func cancelPressed() { onCancel?() }
    @objc private func confirmPressed() {
        guard let date = selectedMoment else { return }
        onConfirm?(date)
    }
#endif

    private func configure(_ table: NSTableView, in scroll: ThemedScrollView,
                           rowHeight: CGFloat, column: NSUserInterfaceItemIdentifier,
                           label: String) {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = rowHeight
        table.style = .inset
        table.headerView = nil
        table.setAccessibilityLabel(label)
        table.addTableColumn(NSTableColumn(identifier: column))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.applySurface(fill: Design.Surface.panel,
                            radius: .panel, border: Design.Surface.border)
        ScheduleMomentPickerLayout.prepareList(scroll)
    }

    func selectDay(_ index: Int) {
        guard options.days.indices.contains(index) else { return }
        dayIndex = index
        let times = options.times(onDayAt: index)
        if !times.contains(where: { $0.minutes == minutes }) {
            minutes = (times.first { $0.minutes >= minutes } ?? times.first)?.minutes ?? minutes
        }
        visibleTimes = times
        rewritingSelection = true
        timeTable.reloadData()
        restoreSelection()
        rewritingSelection = false
        timeTable.scrollRowToVisible(selectedTime)
        refreshSummary()
    }

    func selectTime(_ index: Int) {
        guard visibleTimes.indices.contains(index) else { return }
        minutes = visibleTimes[index].minutes
        rewritingSelection = true
        restoreSelection()
        rewritingSelection = false
        refreshSummary()
    }

    func selectTime(minutes value: Int) {
        guard let index = visibleTimes.firstIndex(where: { $0.minutes == value }) else { return }
        selectTime(index)
    }

    func showSelectedTime() {
        guard selectedTime >= 0 else { return }
        timeTable.scrollRowToVisible(selectedTime)
    }

    func moveSelection(by step: Int) {
        switch activeColumn {
        case .day: selectDay(max(0, min(dayCount - 1, dayIndex + step)))
        case .time: selectTime(max(0, min(timeCount - 1, selectedTime + step)))
        }
    }

    func switchColumn() {
        activeColumn = activeColumn == .day ? .time : .day
    }

    private func restoreSelection() {
        dayTable.selectRowIndexes(IndexSet(integer: dayIndex), byExtendingSelection: false)
        if selectedTime >= 0 {
            timeTable.selectRowIndexes(IndexSet(integer: selectedTime), byExtendingSelection: false)
        } else {
            timeTable.deselectAll(nil)
        }
    }

    private func refreshSummary() {
        guard let date = selectedMoment else {
            summary.stringValue = ScheduleMomentPickerStrings.nothingToSchedule
            confirmButton.isEnabled = false
            return
        }
        summary.stringValue = summaryText(date, openedAt)
        confirmButton.isEnabled = canConfirm(date, openedAt)
    }

#if !os(Linux)
    private func applyTheme() {
        headingLabel.textColor = Design.Text.label
        noteLabel.textColor = Design.Text.secondary
        dayCaption.textColor = Design.Text.secondary
        timeCaption.textColor = Design.Text.secondary
        summary.textColor = Design.Text.label
        dayTable.rowHeight = ScheduleMomentPickerLayout.dayRowHeight
        timeTable.rowHeight = ScheduleMomentPickerLayout.timeRowHeight
        rewritingSelection = true
        dayTable.reloadData()
        timeTable.reloadData()
        restoreSelection()
        rewritingSelection = false
    }
#endif

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === dayTable ? dayCount : timeCount
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
                   row: Int) -> NSView? {
        if tableView === dayTable {
            guard options.days.indices.contains(row) else { return nil }
            return ScheduleMomentPickerRows.makeDayRow(options.days[row])
        }
        guard visibleTimes.indices.contains(row) else { return nil }
        return ScheduleMomentPickerRows.makeTimeRow(visibleTimes[row])
    }

#if !os(Linux)
    func tableView(_ tableView: NSTableView,
                   typeSelectStringFor column: NSTableColumn?, row: Int) -> String? {
        if tableView === dayTable {
            guard options.days.indices.contains(row) else { return nil }
            return options.days[row].title
        }
        guard visibleTimes.indices.contains(row) else { return nil }
        return visibleTimes[row].title
    }
#endif

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rewritingSelection, let table = notification.object as? NSTableView else { return }
        if table === dayTable {
            activeColumn = .day
            selectDay(table.selectedRow)
        } else if table === timeTable {
            activeColumn = .time
            selectTime(table.selectedRow)
        }
    }
}
