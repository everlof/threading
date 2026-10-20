#if os(Linux)
import AppKit

/// The Linux sheet body for the shared custom-time choices. The SDL host supplies only its
/// window, input events, and bitmap frame; the two lists and their content stay in Design.
@MainActor
final class LinuxScheduleMomentPickerView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column { case day, time }

    private let options: ScheduleMomentOptions
    private let openedAt: Date
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
    private let summary = NSTextField(labelWithString: "")
    private let cancelButton = ThemedButton()
    private let confirmButton = ThemedButton()

    var onConfirm: ((Date) -> Void)?
    var onCancel: (() -> Void)?

    var selectedMoment: Date? { options.date(dayAt: dayIndex, minutes: minutes) }
    var dayCount: Int { options.days.count }
    var timeCount: Int { visibleTimes.count }
    var selectedDay: Int { dayIndex }
    var selectedTime: Int { visibleTimes.firstIndex { $0.minutes == minutes } ?? -1 }
    var cancelFrame: NSRect { cancelButton.convert(cancelButton.bounds, to: self) }
    var confirmFrame: NSRect { confirmButton.convert(confirmButton.bounds, to: self) }

    init(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
        openedAt = now
        options = ScheduleMomentOptions(now: now, calendar: calendar, locale: locale)
        super.init(frame: NSRect(x: 0, y: 0,
            width: ScheduleMomentPickerLayout.sheetWidth,
            height: ScheduleMomentPickerLayout.sheetHeight))
        translatesAutoresizingMaskIntoConstraints = false
        setAppliedSurface(fill: Design.Surface.background, radius: 0,
                          border: Design.Surface.border)

        if let selection = options.defaultSelection {
            dayIndex = selection.dayIndex
            minutes = selection.minutes
        }
        visibleTimes = options.times(onDayAt: dayIndex)

        let title = L10n.string("Snooze session")
        let heading = NSTextField(labelWithString: title)
        heading.font = Design.Typography.heading()
        heading.textColor = Design.Text.label
        let note = NSTextField(wrappingLabelWithString:
            ScheduleMomentPickerStrings.note(
                L10n.string("The session keeps running while snoozed."), locale: locale))
        note.applyFont(.subheading)
        note.textColor = Design.Text.secondary
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = ScheduleMomentPickerLayout.sheetWidth
            - 2 * Design.Spacing.pane
        let headings = ScheduleMomentPickerLayout.headings(heading, note)

        let dayCaption = NSTextField(labelWithString: ScheduleMomentPickerStrings.dayCaption)
        dayCaption.applyFont(.subheading)
        dayCaption.textColor = Design.Text.secondary
        let timeCaption = NSTextField(labelWithString: ScheduleMomentPickerStrings.timeCaption)
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
        cancelButton.action = { [weak self] in self?.onCancel?() }
        confirmButton.title = L10n.string("Snooze")
        confirmButton.emphasis = .primary
        confirmButton.action = { [weak self] in
            guard let self, let date = self.selectedMoment else { return }
            self.onConfirm?(date)
        }
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
        refreshSummary(locale: locale)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        if needsInitialScroll, timeScroll.contentView.bounds.height > 0 {
            needsInitialScroll = false
            timeTable.scrollRowToVisible(selectedTime)
        }
    }

    private func configure(_ table: NSTableView, in scroll: ThemedScrollView,
                           rowHeight: CGFloat, column: NSUserInterfaceItemIdentifier,
                           label: String) {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = rowHeight
        table.style = .inset
        table.setAccessibilityLabel(label)
        table.addTableColumn(NSTableColumn(identifier: column))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.setAppliedSurface(fill: Design.Surface.panel,
                                 radius: Design.Radius.panel,
                                 border: Design.Surface.border)
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

    private func refreshSummary(locale: Locale = .current) {
        guard let date = selectedMoment else {
            summary.stringValue = ScheduleMomentPickerStrings.nothingToSchedule
            confirmButton.isEnabled = false
            return
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        summary.stringValue = formatter.string(from: date)
        confirmButton.isEnabled = date > openedAt
    }

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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LinuxScheduleMomentPickerRowView(frame: .zero)
    }

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

@MainActor
private final class LinuxScheduleMomentPickerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: Design.Spacing.tight, dy: 1),
                                 xRadius: Design.Radius.control,
                                 yRadius: Design.Radius.control)
        Design.Surface.controlHover.setFill()
        plate.fill()
    }
}
#endif
