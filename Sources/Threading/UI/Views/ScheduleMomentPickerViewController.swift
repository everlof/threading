import AppKit

/// AppKit sheet presentation for the shared custom-time view. The view owns the two lists,
/// selection, summary and actions; this controller owns only the native sheet lifecycle.
@MainActor
final class ScheduleMomentPickerViewController: NSViewController {
    private let heading: String
    private let note: String
    private let confirmTitle: String
    private let now: Date
    private let calendar: Calendar
    private let locale: Locale

    var onPick: ((Date?) -> Void)?

    private var pickerView: ScheduleMomentPickerView {
        return view as! ScheduleMomentPickerView
    }

    init(title: String, note: String, confirmTitle: String,
         now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
        heading = title
        self.note = note
        self.confirmTitle = confirmTitle
        self.now = now
        self.calendar = calendar
        self.locale = locale
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func present(over presenter: NSViewController, title: String,
                        informativeText: String? = nil,
                        confirmTitle: String = ScheduleMomentPickerStrings.scheduleMessage,
                        now: Date = Date(), calendar: Calendar = .current,
                        locale: Locale = .current,
                        completion: @escaping (Date?) -> Void) {
        let picker = ScheduleMomentPickerViewController(
            title: title,
            note: ScheduleMomentPickerStrings.note(informativeText, locale: locale),
            confirmTitle: confirmTitle, now: now, calendar: calendar, locale: locale)
        picker.onPick = { [weak presenter, weak picker] date in
            if let presenter, let picker { presenter.dismiss(picker) }
            completion(date)
        }
        presenter.presentAsSheet(picker)
    }

    override func loadView() {
        let picker = ScheduleMomentPickerView(
            title: heading, note: note, confirmTitle: confirmTitle,
            now: now, calendar: calendar, locale: locale,
            summaryText: { moment, openedAt in
                ScheduledTiming.sentence(for: moment, from: openedAt)
            },
            canConfirm: { _, _ in true })
        picker.onConfirm = { [weak self] date in self?.onPick?(date) }
        picker.onCancel = { [weak self] in self?.onPick?(nil) }
        view = picker
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(pickerView.preferredFirstResponder)
        pickerView.showSelectedTime()
    }

    var selectedMoment: Date? { pickerView.selectedMoment }
    var visibleTimeTitlesForTesting: [String] { pickerView.timeTitles }
    var selectedTimeTitleForTesting: String? { pickerView.selectedTimeTitle }
    var dayTitlesForTesting: [String] { pickerView.dayTitles }
    var confirmButtonIsEnabledForTesting: Bool { pickerView.confirmIsEnabled }
    var summaryForTesting: String { pickerView.summaryValue }

    func selectDay(at index: Int) { pickerView.selectDay(index) }
    func selectTime(minutes value: Int) { pickerView.selectTime(minutes: value) }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
                   row: Int) -> NSView? {
        pickerView.tableView(tableView, viewFor: column, row: row)
    }

    @objc func confirm() {
        guard let moment = pickerView.selectedMoment else { return }
        onPick?(moment)
    }

    @objc func cancel() { onPick?(nil) }
}
