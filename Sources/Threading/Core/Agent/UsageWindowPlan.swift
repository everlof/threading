import Foundation

// MARK: - Usage Window Schedule

/// The working day a usage-window poke is planned around.
///
/// Minutes from midnight rather than `Date`s, because the schedule outlives every particular day
/// and a stored wall-clock time that drifts with daylight saving is a bug nobody notices until
/// October.
struct UsageWindowSchedule: Codable, Equatable {

    /// Whether the poke runs at all. Off until the user turns it on, always.
    var isEnabled: Bool

    /// When the working day starts and ends, as minutes from local midnight.
    var startMinute: Int
    var endMinute: Int

    /// Which days it applies to, as `Calendar` weekday numbers (1 = Sunday).
    var weekdays: Set<Int>

    /// The accounts allowed to be poked, by their stored identifier.
    ///
    /// Opt-in per login rather than "every account Threading found". One person's second login
    /// is a work account they touch on Tuesdays, and poking it daily would spend a weekly limit
    /// nobody was going to use — quite apart from how a fleet of accounts waking together at
    /// 07:00 looks from the other side.
    var accountIDs: Set<String>

    static let `default` = UsageWindowSchedule(
        isEnabled: false,
        startMinute: UsageWindowDefaults.defaultStartMinute,
        endMinute: UsageWindowDefaults.defaultEndMinute,
        weekdays: UsageWindowDefaults.defaultWeekdays,
        accountIDs: []
    )

    /// The working interval on the day containing `date`, in the given calendar.
    ///
    /// Nil when the day is not one of the scheduled weekdays, or when the two times do not make
    /// an interval — an end before a start is a half-entered setting, not an overnight shift.
    func workday(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard weekdays.contains(calendar.component(.weekday, from: date)) else { return nil }
        guard endMinute > startMinute else { return nil }

        let midnight = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .minute, value: startMinute, to: midnight),
              let end = calendar.date(byAdding: .minute, value: endMinute, to: midnight)
        else { return nil }

        return DateInterval(start: start, end: end)
    }
}

// MARK: - Usage Window Decision

/// What the planner concluded, and why.
///
/// The reason is not debugging garnish. A feature that spends the user's limits has to be able to
/// say, on the day it did nothing, which rule stopped it — otherwise "it didn't work" and "it
/// correctly declined" look identical from the outside, and the only way to tell them apart is to
/// read the code.
enum UsageWindowDecision: Equatable {
    case poke
    case hold(UsageWindowHold)
}

/// Every reason a poke does not fire. Ordered as the planner asks them, cheapest first.
enum UsageWindowHold: Equatable {
    /// Turned off, or this account was never opted in.
    case disabled
    /// Not one of the scheduled weekdays.
    case notScheduledToday
    /// Today's allowance of pokes is spent.
    case dailyLimitReached(Int)
    /// No usage reading, so whether a window is open is unknown. Never poke blind.
    case usageUnknown
    /// A window is already open; a second message would not start another one.
    case windowOpen(resetsAt: Date)
    /// A poke has just fired and the reading has not caught up. Without this the next tick would
    /// see the same expired window and poke again, which is how a once-a-day feature becomes a
    /// once-a-minute one.
    case settling
    /// The account is being used right now, so the next message opens the window for free.
    case working
    /// This account never reaches its short limit, so moving the window's phase gains nothing.
    case neverExhausts
    /// Earlier than the day's poke time.
    case beforePokeTime(Date)
    /// Too little of the working day is left to use a fresh window.
    case tailTooShort(remaining: TimeInterval)
    /// The weekly limit is running ahead of the clock, so a window pulled forward is a week
    /// spent faster rather than a day spent better.
    case weeklyAheadOfPace(fraction: Double)
}

// MARK: - Usage Window Plan

/// The arithmetic behind the poke. Pure, so every rule is testable without a clock, a network or
/// an account.
///
/// **What a poke actually buys.** A window opens on the account's first message and resets a
/// fixed span later, so its phase belongs to whoever sends that message. Nothing about a poke
/// raises a limit: the same span still yields the same allowance, and the weekly cap above it
/// does not move at all. What changes is *where the boundaries fall*. A window that opens when
/// you sit down resets while you are still working and leaves its last hours to the evening; one
/// opened `windowLength - burn` earlier is exhausted exactly as it resets, and pulls the next
/// boundary far enough forward that a third window's worth of work fits inside the working day.
///
/// Measured against a nine-hour day and a three-hour burn, that is seven productive hours instead
/// of six. It is also a week spent one seventh faster, which is why `weeklyAheadOfPace` exists.
enum UsageWindowPlan {

    // MARK: - Lead

    /// How long before the working day starts the window should open.
    ///
    /// `windowLength - burn`, and the derivation is the whole feature. When the window opens
    /// exactly `burn` before you run out of work to spend it on, two things happen at once: none
    /// of it is wasted before you arrive, and its reset lands on the moment you would otherwise
    /// have sat capped waiting for one.
    ///
    /// Lead too short and the morning ends in a wait. Lead too long and the window expires before
    /// the first message, which is identical to not poking at all — the case that makes this a
    /// derived number rather than one to type into a box.
    ///
    /// Without a measured burn there is no honest lead, only a plausible one, so the default is
    /// used and the UI says it is assumed.
    static func lead(burn: TimeInterval?, windowLength: TimeInterval) -> TimeInterval {
        guard let burn, burn > 0 else { return UsageWindowDefaults.assumedLead }
        return min(max(windowLength - burn, 0), windowLength)
    }

    /// When the poke should fire on the day containing `date`, or nil when that day is not
    /// scheduled.
    static func pokeTime(
        on date: Date,
        schedule: UsageWindowSchedule,
        burn: TimeInterval?,
        windowLength: TimeInterval,
        calendar: Calendar = .current
    ) -> Date? {
        guard let workday = schedule.workday(containing: date, calendar: calendar) else {
            return nil
        }
        return workday.start.addingTimeInterval(-lead(burn: burn, windowLength: windowLength))
    }

    // MARK: - Decision

    /// Everything the decision is made from, gathered by the caller so the rules themselves stay
    /// pure.
    struct Input {
        var now: Date
        var schedule: UsageWindowSchedule
        var accountID: String
        /// Working time needed to spend one window, when it has been measured.
        var burn: TimeInterval?
        /// The account's anchored short window, as last read. Nil when nothing has been read.
        var shortWindow: AccountUsage.Window?
        /// The weekly window, for the pace guard. Nil when the provider reports none.
        var weeklyWindow: AccountUsage.Window?
        /// Whether a session on this account has been busy recently — if so, the user's own next
        /// message opens the window and the poke would be paying for something free.
        var isWorking: Bool
        var pokesToday: Int
        var calendar: Calendar = .current
    }

    /// Whether to poke now, and if not, which rule said no.
    static func decide(_ input: Input) -> UsageWindowDecision {
        let schedule = input.schedule

        guard schedule.isEnabled, schedule.accountIDs.contains(input.accountID) else {
            return .hold(.disabled)
        }
        guard let workday = schedule.workday(containing: input.now, calendar: input.calendar) else {
            return .hold(.notScheduledToday)
        }
        guard input.pokesToday < UsageWindowDefaults.dailyLimit else {
            return .hold(.dailyLimitReached(input.pokesToday))
        }

        // Reading the window is what separates this from a cron job. Without one, whether a
        // window is open is a guess, and a poke on a guess is the wasteful half of the time.
        guard let window = input.shortWindow else { return .hold(.usageUnknown) }

        if let resetsAt = window.resetsAt, resetsAt > input.now {
            return .hold(.windowOpen(resetsAt: resetsAt))
        }
        // A working account opens its own window with the next thing it sends. This is also what
        // keeps the rule that reopens a window expiring at lunchtime from firing at every other
        // boundary of the day.
        if input.isWorking { return .hold(.working) }

        let windowLength = window.windowDuration ?? UsageDefaults.fiveHourSeconds

        // Someone who never reaches the short limit has nothing to gain and a weekly limit to
        // lose. Saying so is more useful than firing daily and claiming credit.
        if let burn = input.burn, burn >= windowLength { return .hold(.neverExhausts) }

        let pokeTime = workday.start
            .addingTimeInterval(-lead(burn: input.burn, windowLength: windowLength))
        guard input.now >= pokeTime else { return .hold(.beforePokeTime(pokeTime)) }

        // A window opened with an hour of the day left is an hour used and four spent on the
        // evening. The bar is the burn itself, held between a floor and the window's own length:
        // enough working time left to actually drain what is being opened.
        let remaining = workday.end.timeIntervalSince(input.now)
        let tail = minimumTail(burn: input.burn, windowLength: windowLength)
        guard remaining >= tail else { return .hold(.tailTooShort(remaining: max(remaining, 0))) }

        if let weekly = input.weeklyWindow,
           let spent = weekly.fraction,
           let elapsed = weekly.elapsedFraction(at: input.now),
           spent > elapsed + UsageWindowDefaults.weeklyPaceTolerance {
            return .hold(.weeklyAheadOfPace(fraction: spent))
        }

        return .poke
    }

    /// How much working day a fresh window needs in front of it to be worth opening.
    static func minimumTail(burn: TimeInterval?, windowLength: TimeInterval) -> TimeInterval {
        guard let burn, burn > 0 else { return UsageWindowDefaults.minimumTailFloor }
        return min(max(burn, UsageWindowDefaults.minimumTailFloor), windowLength)
    }

    // MARK: - Outlook

    /// How a day plays out under one anchor: the windows it produces and how much of each is
    /// usable. This is what the settings diagram draws, and what the claim above is tested
    /// against.
    struct Outlook: Equatable {

        /// One window, and the part of it that falls inside the working day with allowance left
        /// to spend.
        struct Window: Equatable {
            let interval: DateInterval
            /// The stretch actually worked through. Nil when the window falls entirely outside
            /// the working day.
            let productive: DateInterval?
            /// The stretch inside the working day spent waiting for the next reset.
            let capped: DateInterval?
        }

        let windows: [Window]

        /// Total working time with allowance to spend — the number the two anchors are compared
        /// on.
        var productiveTime: TimeInterval {
            windows.compactMap(\.productive?.duration).reduce(0, +)
        }

        /// Total working time spent waiting for a reset.
        var cappedTime: TimeInterval {
            windows.compactMap(\.capped?.duration).reduce(0, +)
        }
    }

    /// Projects a day from the moment its first window opens.
    ///
    /// The model is deliberately the simplest one that reproduces the effect: a window yields
    /// `burn` of work and then nothing until it resets, and work happens whenever the working day
    /// and an unspent window overlap. Real days are lumpier, but every lump moves both anchors
    /// equally, and it is the *difference* between two anchors that this exists to show.
    static func outlook(
        anchor: Date,
        workday: DateInterval,
        burn: TimeInterval,
        windowLength: TimeInterval
    ) -> Outlook {
        guard windowLength > 0, workday.duration > 0 else { return Outlook(windows: []) }

        var windows: [Outlook.Window] = []
        var start = anchor

        while start < workday.end, windows.count < UsageWindowDefaults.maximumOutlookWindows {
            let interval = DateInterval(start: start, duration: windowLength)
            let overlap = interval.intersection(with: workday)

            if let overlap, overlap.duration > 0 {
                let worked = min(burn, overlap.duration)
                let productive = worked > 0
                    ? DateInterval(start: overlap.start, duration: worked)
                    : nil
                let idle = overlap.duration - worked
                let capped = idle > 0
                    ? DateInterval(
                        start: overlap.start.addingTimeInterval(worked),
                        duration: idle
                    )
                    : nil
                windows.append(Outlook.Window(
                    interval: interval,
                    productive: productive,
                    capped: capped
                ))
            } else {
                windows.append(Outlook.Window(
                    interval: interval,
                    productive: nil,
                    capped: nil
                ))
            }

            start = interval.end
        }

        return Outlook(windows: windows)
    }

    /// The pair the settings diagram shows: the same day anchored where the first message would
    /// have landed, and anchored where the poke puts it.
    static func comparison(
        workday: DateInterval,
        burn: TimeInterval,
        windowLength: TimeInterval
    ) -> (unpoked: Outlook, poked: Outlook) {
        let lead = lead(burn: burn, windowLength: windowLength)
        return (
            outlook(
                anchor: workday.start,
                workday: workday,
                burn: burn,
                windowLength: windowLength
            ),
            outlook(
                anchor: workday.start.addingTimeInterval(-lead),
                workday: workday,
                burn: burn,
                windowLength: windowLength
            )
        )
    }
}

// MARK: - Usage Window Defaults

enum UsageWindowDefaults {
    /// 09:00 to 18:00, weekdays. A starting point to move, not a claim about anyone's day.
    static let defaultStartMinute = 9 * 60
    static let defaultEndMinute = 18 * 60
    static let defaultWeekdays: Set<Int> = [2, 3, 4, 5, 6]

    /// The lead used until a burn has been measured. Two hours is `5h - 3h`, and three hours is
    /// what a working session spends a window in often enough to be a reasonable placeholder —
    /// but it is a placeholder, and the page says so rather than presenting it as a measurement.
    static let assumedLead: TimeInterval = 2 * 3600

    /// The most pokes one account may fire in a day, enforced below the rules.
    ///
    /// Three, which is one more than a nine-hour day needs. This is not a tuning knob; it is the
    /// backstop that keeps a bug in the rules above from turning a scheduled poke into a poller,
    /// which is the shape that would deserve every bit of trouble it got.
    static let dailyLimit = 3

    /// Working time a fresh window needs in front of it, when no burn has been measured.
    static let minimumTailFloor: TimeInterval = 90 * 60

    /// How far ahead of the clock the weekly limit may run before the poke stands down. A tenth
    /// of a week is about the noise in an ordinary Monday.
    static let weeklyPaceTolerance = 0.10

    /// A day cannot hold more windows than this; the guard is against a zero-length window
    /// looping, not against long days.
    static let maximumOutlookWindows = 12

    /// How often the runner asks the planner. A minute, like the usage pill's own timer: the
    /// decision changes on the clock, and every expensive part of it is guarded separately.
    static let tickInterval: TimeInterval = 60

    /// How long after a poke the account is left alone while the reading catches up. The usage
    /// endpoint is polled, not pushed, so the window that just opened is invisible for a while
    /// and every tick inside that gap would otherwise reach the same conclusion again.
    static let settleInterval: TimeInterval = 10 * 60

    /// How long a poke may take before it is killed. Generous for one short message on a slow
    /// morning; short enough that a wedged CLI does not sit there until lunch.
    static let pokeTimeout: TimeInterval = 120

    /// How many past pokes the ledger keeps. Enough to see a working week.
    static let ledgerLimit = 20
}
