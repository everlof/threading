import Foundation

/// Calendar moments offered by the session Snooze menu on every desktop host. Dates and their
/// displayed words are one policy so DST, Sunday deduplication and menu copy agree.
enum SnoozeWallClockMoments {
    static let morningHour = 9
    enum Kind: Sendable { case inAnHour, tomorrowMorning, mondayMorning }

    struct Moment: Sendable {
        let kind: Kind
        let date: Date
    }

    struct Presentation: Sendable {
        let moment: Moment
        let title: String
        let detail: String?
    }

    static func presentations(for moments: [Moment], locale: Locale = .current) -> [Presentation] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return moments.map { moment in
            let clock = formatter.string(from: moment.date)
            let title: String
            let detail: String?
            switch moment.kind {
            case .inAnHour:
                title = L10n.string("In an hour")
                detail = clock
            case .tomorrowMorning:
                title = L10n.format("Tomorrow at %@", clock)
                detail = nil
            case .mondayMorning:
                title = L10n.format("Monday at %@", clock)
                detail = nil
            }
            return Presentation(moment: moment, title: title, detail: detail)
        }
    }

    static func future(from now: Date, calendar: Calendar = .current) -> [Moment] {
        var result: [Moment] = []
        let target = now.addingTimeInterval(3_600)
        let minute = calendar.component(.minute, from: target)
        let rounded = ((minute + 4) / 5) * 5
        let stepped = calendar.date(byAdding: .minute, value: rounded - minute, to: target)
            ?? target
        if let hour = calendar.date(from: calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: stepped)), hour > now {
            result.append(Moment(kind: .inAnHour, date: hour))
        }
        guard let nextDay = calendar.date(byAdding: .day, value: 1,
            to: calendar.startOfDay(for: now)),
            let tomorrow = calendar.date(bySettingHour: morningHour, minute: 0, second: 0,
                of: nextDay) else {
            return result
        }
        result.append(Moment(kind: .tomorrowMorning, date: tomorrow))
        let mondaySearchStart = calendar.component(.weekday, from: now) == 2
            ? calendar.date(byAdding: .day, value: 1,
                to: calendar.startOfDay(for: now)) ?? now
            : now
        if let monday = calendar.nextDate(after: mondaySearchStart,
            matching: DateComponents(hour: morningHour, minute: 0, weekday: 2),
            matchingPolicy: .nextTime),
           !calendar.isDate(monday, inSameDayAs: tomorrow) {
            result.append(Moment(kind: .mondayMorning, date: monday))
        }
        return result
    }
}
