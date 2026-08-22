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

    // MARK: - Curfew Wall Clock

    /// The time-of-day offers for an **end** rather than a start, filtered to the future.
    ///
    /// A different list from `wallClock` because it answers a different question. "Tomorrow at
    /// 09:00" is when somebody wants work to begin; nobody sets a curfew for the middle of the
    /// next working day. What an end wants is a short leash on the session in front of them —
    /// an hour, an afternoon — and the one standing moment a person schedules an end at, which
    /// is bedtime.
    ///
    /// Rounded through the same `roundedHourAhead` arithmetic for the same reason: a menu
    /// offering to end a session at 13:07 is reporting a computation rather than making an
    /// offer.
    static func curfewWallClock(
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [ScheduledTimePreset] {
        var calendar = calendar
        calendar.locale = locale

        var presets: [ScheduledTimePreset] = []

        if let hour = roundedHourAhead(from: now, calendar: calendar) {
            presets.append(
                ScheduledTimePreset(
                    id: PresetDefaults.curfewInAnHourID,
                    title: L10n.string("In an hour"),
                    detail: time(hour, locale: locale),
                    date: hour,
                    anchor: .wallClock
                )
            )
        }

        if let threeHours = roundedAhead(
            from: now,
            by: PresetDefaults.threeHours,
            calendar: calendar
        ) {
            presets.append(
                ScheduledTimePreset(
                    id: PresetDefaults.curfewInThreeHoursID,
                    title: L10n.string("In 3 hours"),
                    detail: time(threeHours, locale: locale),
                    date: threeHours,
                    anchor: .wallClock
                )
            )
        }

        // Tonight is today's evening or nothing at all: past 23:00 the offer would be an offer
        // to end the session tomorrow night, which is a day away from what the word says. The
        // filter below removes it, and `nextOccurrence` is deliberately not used here for that
        // reason — it would happily search into tomorrow.
        if let tonight = calendar.date(
            bySettingHour: PresetDefaults.curfewEveningHour,
            minute: 0,
            second: 0,
            of: now
        ) {
            presets.append(
                ScheduledTimePreset(
                    id: PresetDefaults.curfewTonightID,
                    title: L10n.format("Tonight at %@", time(tonight, locale: locale)),
                    detail: nil,
                    date: tonight,
                    anchor: .wallClock
                )
            )
        }

        return presets.filter { $0.date > now }
    }

    // MARK: - Usage Windows

    /// "Send this the moment my limit resets" — one offer per window that has a reset to aim at.
    ///
    /// The preset a coding-agent composer wants most and Slack would never have. Which windows
    /// are worth aiming at is `resettingWindows`; this decides what to call them and where to
    /// land.
    static func usageResets(
        usage: AccountUsage?,
        metering model: String?,
        now: Date,
        locale: Locale = .current
    ) -> [ScheduledTimePreset] {
        resettingWindows(usage: usage, metering: model, now: now).map { resetting in
            ScheduledTimePreset(
                id: "\(PresetDefaults.resetIDPrefix)\(resetting.window.id)",
                title: L10n.format("When the %@ window resets", resetting.window.compactName),
                detail: reading(of: resetting, from: now),
                // A window's boundary is not the moment to arrive at: a send landing on the
                // same second the provider rolls its counter is a send racing it. A minute
                // past costs nothing and is the difference between a wasted turn and a turn.
                date: resetting.resetsAt.addingTimeInterval(PresetDefaults.resetPadding),
                anchor: .usageWindowReset(windowID: resetting.window.id)
            )
        }
    }

    /// "Spend what is left of this window and stop" — the same windows as `usageResets`, offered
    /// as ends.
    ///
    /// The pairing the whole feature exists for: a five-hour window resets at 04:00 while its
    /// owner is asleep, and they want the session to spend what is left of *this* window without
    /// eating into the fresh one.
    ///
    /// **No `resetPadding` here.** That minute exists so a *send* lands after the provider has
    /// rolled its counter; on an end it points the wrong way, and a curfew a minute past the
    /// boundary is a curfew that lets the session start spending the new window.
    static func curfewUsageResets(
        usage: AccountUsage?,
        metering model: String?,
        now: Date,
        locale: Locale = .current
    ) -> [ScheduledTimePreset] {
        resettingWindows(usage: usage, metering: model, now: now).map { resetting in
            ScheduledTimePreset(
                id: "\(PresetDefaults.curfewResetIDPrefix)\(resetting.window.id)",
                title: L10n.format("Until the %@ window resets", resetting.window.compactName),
                detail: reading(of: resetting, from: now),
                date: resetting.resetsAt,
                anchor: .usageWindowReset(windowID: resetting.window.id)
            )
        }
    }

    // MARK: - Private Methods

    /// One window that has a reset still ahead of it, with that reset unwrapped.
    private struct ResettingWindow {
        let window: AccountUsage.Window
        let resetsAt: Date
    }

    /// The windows worth aiming at, for both the start offers and the end ones.
    ///
    /// Shared so the two lists cannot drift: they must offer the *same* windows under different
    /// verbs, and a scoped window that appeared in one menu and not the other would read as a
    /// missing limit rather than as two rules.
    ///
    /// Nothing here reads a provider: the 5-hour and weekly windows come from `windows`, and a
    /// model-scoped window comes from `modelWindows` when it is the one metering what this
    /// session will actually run. A window with no `resetsAt`, or whose reset has already
    /// passed, is **absent** rather than disabled.
    private static func resettingWindows(
        usage: AccountUsage?,
        metering model: String?,
        now: Date
    ) -> [ResettingWindow] {
        guard let usage else { return [] }

        let scoped = model.flatMap { model in
            usage.modelWindows.first { window in
                window.scopeName.map { ModelName.scope($0, meters: model) } ?? false
            }
        }

        return (usage.windows + [scoped].compactMap { $0 })
            .compactMap { window -> ResettingWindow? in
                guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
                return ResettingWindow(window: window, resetsAt: resetsAt)
            }
    }

    /// The two facts a reset offer states under its title: when, and how far off.
    private static func reading(of resetting: ResettingWindow, from now: Date) -> String {
        "\(UsageFormat.absolute(resetting.resetsAt, from: now))"
            + " · \(UsageFormat.resets(until: resetting.resetsAt, from: now))"
    }

    private static func roundedHourAhead(from now: Date, calendar: Calendar) -> Date? {
        roundedAhead(from: now, by: PresetDefaults.anHour, calendar: calendar)
    }

    /// `offset` from now, rounded up to the next five minutes.
    private static func roundedAhead(
        from now: Date,
        by offset: TimeInterval,
        calendar: Calendar
    ) -> Date? {
        let target = now.addingTimeInterval(offset)
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

    /// The longer of the two short leashes a curfew offers: an afternoon's work rather than the
    /// next hour.
    static let threeHours: TimeInterval = 3 * 60 * 60

    /// What "Tonight" means. Late enough to be an evening rather than a working afternoon, and
    /// early enough that a session ending then is still the same day's work.
    static let curfewEveningHour = 23

    /// How far past a window's stated reset a send is aimed. See `usageResets`.
    static let resetPadding: TimeInterval = 60

    static let inAnHourID = "in-an-hour"
    static let tomorrowID = "tomorrow"
    static let mondayID = "monday"
    static let resetIDPrefix = "reset."

    // The curfew offers carry identifiers of their own rather than sharing the start ones: the
    // two menus are open beside each other on the composer, and a row's identity is what both
    // the selection and every test use to say which of the two it means.
    static let curfewInAnHourID = "curfew.in-an-hour"
    static let curfewInThreeHoursID = "curfew.in-three-hours"
    static let curfewTonightID = "curfew.tonight"
    static let curfewResetIDPrefix = "curfew.reset."
}
