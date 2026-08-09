import AppKit

// MARK: - Schedule Message Alert

/// "Custom time…": a day, a time, and the one sentence that keeps both honest.
///
/// Two pop-ups rather than a calendar widget, which is what the reference does and what the
/// theme boundary requires anyway — `NSDatePicker` is banned by `scripts/config/theme-boundary.json`, and
/// a picker whose bezel came from the system would sit in a Swiss Minimalist sheet looking like a
/// form field somebody forgot.
///
/// **It names the time zone, and it names the limitation.** Slack's own dialog states the zone
/// because a scheduled time is otherwise ambiguous; this states it for the same reason, and adds
/// the sentence Slack has no need for — Threading is not a server, and a moment that passes while
/// the app is closed is one it will ask about rather than act on.
@MainActor
enum ScheduleMessageAlert {

    // MARK: - Public Methods

    /// Asks for a moment. Answers nil if the sheet was cancelled.
    static func present(
        over window: NSWindow?,
        title: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        completion: @escaping (Date?) -> Void
    ) {
        let alert = ThemedAlert()
        alert.messageText = title
        alert.informativeText = [
            L10n.format("Time zone: %@", TimeZone.current.localizedName(
                for: .generic,
                locale: locale
            ) ?? TimeZone.current.identifier),
            L10n.string("Sends while Threading is running.")
        ].joined(separator: "\n")
        alert.alertStyle = .informational

        let days = dayOptions(now: now, calendar: calendar, locale: locale)
        let times = timeOptions(calendar: calendar, locale: locale)

        let dayPopUp = ThemedPopUp()
        for day in days {
            dayPopUp.addItem(ThemedMenuItem(title: day.title, representedValue: day.date))
        }
        dayPopUp.selectItem(at: 0)

        let timePopUp = ThemedPopUp()
        for time in times {
            timePopUp.addItem(ThemedMenuItem(title: time.title, representedValue: time.minutes))
        }
        timePopUp.selectItem(
            at: times.firstIndex { $0.minutes == ScheduleAlertDefaults.defaultMinutes } ?? 0
        )

        let row = NSStackView(views: [dayPopUp, timePopUp])
        row.orientation = .horizontal
        row.spacing = Design.Spacing.medium
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(
            greaterThanOrEqualToConstant: ScheduleAlertDefaults.accessoryWidth
        ).isActive = true
        alert.accessoryView = row

        alert.addButton(withTitle: L10n.string("Schedule Message"))
        alert.addButton(withTitle: L10n.string("Cancel"))

        let resolve: (NSApplication.ModalResponse) -> Void = { response in
            guard response == ThemedAlert.firstButtonResponse,
                  let day = dayPopUp.selectedItem?.representedValue as? Date,
                  let minutes = timePopUp.selectedItem?.representedValue as? Int else {
                return completion(nil)
            }
            completion(
                calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: day))
            )
        }

        guard let window else { return resolve(alert.runModal()) }
        alert.beginSheetModal(for: window, completionHandler: resolve)
    }

    // MARK: - Options

    struct DayOption: Equatable {
        let title: String
        let date: Date
    }

    struct TimeOption: Equatable {
        let title: String
        let minutes: Int
    }

    /// Today, Tomorrow, then named days out to a fortnight.
    ///
    /// Two weeks rather than a year: past that the answer is not "a day of the week" any more,
    /// and a list somebody has to scroll is a worse question than the one they came to answer.
    static func dayOptions(
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [DayOption] {
        var calendar = calendar
        calendar.locale = locale

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(ScheduleAlertDefaults.dayTemplate)

        return (0..<ScheduleAlertDefaults.dayCount).compactMap { offset in
            guard let date = calendar.date(
                byAdding: .day,
                value: offset,
                to: calendar.startOfDay(for: now)
            ) else { return nil }

            let title: String
            switch offset {
            case 0: title = L10n.string("Today")
            case 1: title = L10n.string("Tomorrow")
            default: title = formatter.string(from: date)
            }
            return DayOption(title: title, date: date)
        }
    }

    /// Every quarter hour, written in the user's own clock convention — so a 24-hour locale
    /// reads `09:00` and never `9:00 AM`.
    static func timeOptions(
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [TimeOption] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none

        let reference = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return stride(
            from: 0,
            to: ScheduleAlertDefaults.minutesInADay,
            by: ScheduleAlertDefaults.step
        ).compactMap { minutes in
            guard let date = calendar.date(byAdding: .minute, value: minutes, to: reference) else {
                return nil
            }
            return TimeOption(title: formatter.string(from: date), minutes: minutes)
        }
    }
}

// MARK: - Defaults

enum ScheduleAlertDefaults {
    static let dayCount = 14
    static let step = 15
    static let minutesInADay = 24 * 60

    /// Where the time pop-up opens: the same nine o'clock the presets aim at, so the sheet and
    /// the menu agree about when a working day starts.
    static let defaultMinutes = PresetDefaults.morningHour * 60

    static let dayTemplate = "EEEEdMMM"
    static let accessoryWidth: CGFloat = 320
}
