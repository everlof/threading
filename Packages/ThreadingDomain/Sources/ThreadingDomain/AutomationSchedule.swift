import Foundation

public enum AutomationScheduleError: Error { case invalid(String) }

public struct AutomationSchedule: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case daily, weekdays, weekly, interval }
    public var kind: Kind
    public var timeZone: String
    public var hour: Int
    public var minute: Int
    /// Calendar weekday: Sunday = 1, Saturday = 7.
    public var days: [Int]
    public var intervalMinutes: Int
    public var anchor: Date

    /// The anchor is kept to whole seconds because that is all the wire form carries; a value
    /// that changed across one encode/decode would read as an edit. A missing anchor means the
    /// Unix epoch here and when decoding, so both spellings describe the same recurrence.
    public init(kind: Kind, timeZone: String, hour: Int = 9, minute: Int = 0,
                days: [Int] = [], intervalMinutes: Int = 60, anchor: Date = Date(timeIntervalSince1970: 0)) {
        self.kind = kind; self.timeZone = timeZone; self.hour = hour; self.minute = minute
        self.days = days; self.intervalMinutes = intervalMinutes
        self.anchor = Self.wholeSeconds(anchor)
    }

    private enum CodingKeys: String, CodingKey { case kind, timeZone, hour, minute, days, intervalMinutes, anchor }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        timeZone = try c.decode(String.self, forKey: .timeZone)
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 9
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        days = try c.decodeIfPresent([Int].self, forKey: .days) ?? []
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 60
        if let raw = try c.decodeIfPresent(String.self, forKey: .anchor) {
            guard let date = ISO8601DateFormatter().date(from: raw) else { throw AutomationScheduleError.invalid("anchor") }
            anchor = Self.wholeSeconds(date)
        } else { anchor = Date(timeIntervalSince1970: 0) }
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(timeZone, forKey: .timeZone)
        try c.encode(hour, forKey: .hour); try c.encode(minute, forKey: .minute)
        try c.encode(days, forKey: .days); try c.encode(intervalMinutes, forKey: .intervalMinutes)
        try c.encode(ISO8601DateFormatter().string(from: anchor), forKey: .anchor)
    }

    public func validate() throws {
        guard TimeZone(identifier: timeZone) != nil,
              (0...23).contains(hour), (0...59).contains(minute),
              days.count <= 7, Set(days).count == days.count,
              days.allSatisfy({ (1...7).contains($0) }),
              (1...525_600).contains(intervalMinutes), anchor.timeIntervalSince1970.isFinite,
              anchor >= .distantPast, anchor <= .distantFuture,
              kind != .weekly || days.count == 1,
              kind != .weekdays || !days.isEmpty else {
            throw AutomationScheduleError.invalid("schedule fields")
        }
    }

    public func next(after date: Date) throws -> Date {
        try validate()
        try Self.requireSupported(date)
        if kind == .interval {
            let seconds = Double(intervalMinutes) * 60
            let step = max(0, floor(date.timeIntervalSince(anchor) / seconds) + 1)
            return anchor.addingTimeInterval(step * seconds)
        }
        // Search a whole local day at a time, from its start. `nextDate(after:)` called from
        // inside a repeated (fall-back) hour returns the hour's *second* copy even with
        // `.first`, so a run that fired on the first copy would fire again an hour later.
        // Starting each search before the day's first copy can only ever find that copy.
        let calendar = calendar()
        var dayStart = calendar.startOfDay(for: date)
        for _ in 0..<3 {
            let candidate = try firstOccurrence(onOrAfter: dayStart, calendar)
            if candidate > date { return candidate }
            guard let following = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: candidate)) else { break }
            dayStart = calendar.startOfDay(for: following)
        }
        throw AutomationScheduleError.invalid("schedule has no next occurrence")
    }

    /// The most recent occurrence at or before `date`, or nil when the recurrence has not begun.
    /// A catch-up run is labelled with this rather than with the oldest moment it missed.
    public func latest(onOrBefore date: Date) throws -> Date? {
        try validate()
        try Self.requireSupported(date)
        if kind == .interval {
            let seconds = Double(intervalMinutes) * 60
            let step = floor(date.timeIntervalSince(anchor) / seconds)
            return step < 0 ? nil : anchor.addingTimeInterval(step * seconds)
        }
        // Walking back one local day at a time, the first day whose earliest occurrence is not
        // after `date` holds the latest one: any later occurrence would sit on a day already seen.
        let calendar = calendar()
        let today = calendar.startOfDay(for: date)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let candidate = try firstOccurrence(onOrAfter: calendar.startOfDay(for: day), calendar)
            if candidate <= date { return candidate }
        }
        return nil
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func firstOccurrence(onOrAfter dayStart: Date, _ calendar: Calendar) throws -> Date {
        let weekdays: [Int?] = kind == .daily ? [nil] : days.map { Optional($0) }
        let dates = weekdays.compactMap { weekday in
            calendar.nextDate(
                after: dayStart.addingTimeInterval(-1),
                matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward
            )
        }
        guard let first = dates.min() else {
            throw AutomationScheduleError.invalid("schedule has no next occurrence")
        }
        return first
    }

    private static func requireSupported(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite, date >= .distantPast, date <= .distantFuture else {
            throw AutomationScheduleError.invalid("date outside supported calendar")
        }
    }

    private static func wholeSeconds(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite ? Date(timeIntervalSince1970: seconds.rounded(.down)) : date
    }

}
