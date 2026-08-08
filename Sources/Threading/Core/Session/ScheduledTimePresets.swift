import Foundation

// MARK: - Scheduled Time Preset

/// One offer in the schedule menu: a moment, what to call it, and what it was aimed at.
struct ScheduledTimePreset: Equatable, Sendable, Identifiable {
    let id: String
    let title: String

    /// The reading beside the title — an absolute time, or a window's reset and how far off it
    /// is. Nil where the title already says everything ("Tomorrow at 9:00 AM").
    let detail: String?

    let date: Date
    let anchor: ScheduledMessage.Anchor
}

// MARK: - Scheduled Time Presets

/// The moments the schedule menu offers, computed rather than listed.
///
/// A pure function of `(now, calendar, locale)` and a usage reading, so every rule below is a
/// test and none of it lives in a view.
///
/// **`Calendar` does the arithmetic, never `+ 86_400`.** "Tomorrow at 9:00" one day before a DST
/// transition is 23 or 25 hours away, and a preset built by adding a day's worth of seconds is
/// silently an hour wrong twice a year — in the direction that matters, since the whole point of
/// the 9:00 preset is to land at the start of a working day.
enum ScheduledTimePresets {

    // MARK: - Wall Clock

    /// The three time-of-day offers, filtered to those still in the future.
    static func wallClock(
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [ScheduledTimePreset] {
        var calendar = calendar
        calendar.locale = locale

        var presets: [ScheduledTimePreset] = []

        // The one Slack has no use for and a coding agent does: "start on this after my
        // meeting". Rounded up to the next five minutes, because a menu offering 13:07 is
        // reporting a computation rather than making an offer.
        if let hour = roundedHourAhead(from: now, calendar: calendar) {
            presets.append(
                ScheduledTimePreset(
                    id: PresetDefaults.inAnHourID,
                    title: L10n.string("In an hour"),
                    detail: time(hour, locale: locale),
                    date: hour,
                    anchor: .wallClock
                )
            )
        }

        if let tomorrow = nextOccurrence(
            ofHour: PresetDefaults.morningHour,
            after: now,
            calendar: calendar
        ) {
            presets.append(
                ScheduledTimePreset(
                    id: PresetDefaults.tomorrowID,
                    title: L10n.format("Tomorrow at %@", time(tomorrow, locale: locale)),
                    detail: nil,
                    date: tomorrow,
                    anchor: .wallClock
                )
            )

            // Suppressed when it would name the same day twice: on a Sunday, "Monday" *is*
            // tomorrow, and a menu offering one moment under two names is a menu with a bug in
            // it rather than a choice.
            if let monday = nextMonday(after: now, calendar: calendar),
               !calendar.isDate(monday, inSameDayAs: tomorrow) {
                presets.append(
                    ScheduledTimePreset(
                        id: PresetDefaults.mondayID,
                        title: L10n.format("Monday at %@", time(monday, locale: locale)),
                        detail: nil,
                        date: monday,
                        anchor: .wallClock
                    )
                )
            }
        }

        return presets.filter { $0.date > now }
    }

    // MARK: - Usage Windows

    /// "Send this the moment my limit resets" — one offer per window that has a reset to aim at.
    ///
    /// The preset a coding-agent composer wants most and Slack would never have. `AccountUsage`
    /// already models exactly what this needs, so nothing here reads a provider: the 5-hour and
    /// weekly windows come from `windows`, and a model-scoped window comes from `modelWindows`
    /// when it is the one metering what this session will actually run.
    ///
    /// A window with no `resetsAt`, or whose reset has already passed, is **absent** rather than
    /// disabled — the same silence every other usage surface keeps when it has nothing to report.
    static func usageResets(
        usage: AccountUsage?,
        metering model: String?,
        now: Date,
        locale: Locale = .current
    ) -> [ScheduledTimePreset] {
        guard let usage else { return [] }

        let scoped = model.flatMap { model in
            usage.modelWindows.first { window in
                window.scopeName.map { ModelName.scope($0, meters: model) } ?? false
            }
        }

        return (usage.windows + [scoped].compactMap { $0 })
            .compactMap { window -> ScheduledTimePreset? in
                guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
                return ScheduledTimePreset(
                    id: "\(PresetDefaults.resetIDPrefix)\(window.id)",
                    title: L10n.format("When the %@ window resets", window.compactName),
                    detail: "\(UsageFormat.absolute(resetsAt, from: now))"
                        + " · \(UsageFormat.resets(until: resetsAt, from: now))",
                    // A window's boundary is not the moment to arrive at: a send landing on the
                    // same second the provider rolls its counter is a send racing it. A minute
                    // past costs nothing and is the difference between a wasted turn and a turn.
                    date: resetsAt.addingTimeInterval(PresetDefaults.resetPadding),
                    anchor: .usageWindowReset(windowID: window.id)
                )
            }
    }

    // MARK: - Private Methods

    private static func roundedHourAhead(from now: Date, calendar: Calendar) -> Date? {
        let target = now.addingTimeInterval(PresetDefaults.anHour)
        let minute = calendar.component(.minute, from: target)
        let step = PresetDefaults.roundingMinutes
        let rounded = ((minute + step - 1) / step) * step
        let stepped = calendar.date(byAdding: .minute, value: rounded - minute, to: target)
            ?? target
        // Truncated rather than `bySetting:`, which searches forward for the next matching
        // second and would push a 13:05:00 answer to 13:06:00.
        return calendar.date(
            from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: stepped)
        )
    }

    private static func nextOccurrence(
        ofHour hour: Int,
        after now: Date,
        calendar: Calendar
    ) -> Date? {
        calendar.nextDate(
            after: now,
            matching: DateComponents(hour: hour, minute: 0),
            matchingPolicy: .nextTime
        )
    }

    private static func nextMonday(after now: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(
            after: now,
            matching: DateComponents(
                hour: PresetDefaults.morningHour,
                minute: 0,
                weekday: PresetDefaults.mondayWeekday
            ),
            matchingPolicy: .nextTime
        )
    }

    /// The user's own clock convention, so a 24-hour locale reads `09:00` and never `9:00 AM`.
    static func time(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Defaults

enum PresetDefaults {

    /// Where a working day is taken to begin. Not configurable yet, and deliberately the same
    /// hour Slack picks: a preset is a good guess offered quickly, and the custom sheet is what
    /// exists for anyone whose morning is somewhere else.
    static let morningHour = 9

    /// `Calendar`'s Gregorian weekday numbering, where Sunday is 1.
    static let mondayWeekday = 2

    static let anHour: TimeInterval = 60 * 60
    static let roundingMinutes = 5

    /// How far past a window's stated reset a send is aimed. See `usageResets`.
    static let resetPadding: TimeInterval = 60

    static let inAnHourID = "in-an-hour"
    static let tomorrowID = "tomorrow"
    static let mondayID = "monday"
    static let resetIDPrefix = "reset."
}
