import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

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

enum ScheduleMomentDefaults {
    static let dayCount = 14
    static let step = 15
    static let minutesInADay = 24 * 60

    /// Where the time list opens: the same nine o'clock the presets aim at, so the sheet and
    /// the menu agree about when a working day starts.
    static let defaultMinutes = SnoozeWallClockMoments.morningHour * 60

    static let dayNameTemplate = "EEEE"
    static let dayDetailTemplate = "dMMM"
}
