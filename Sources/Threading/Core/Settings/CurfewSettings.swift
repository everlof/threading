import Foundation

// MARK: - Quiet Hours

/// The standing nightly window every session follows unless it is exempt.
///
/// Stored as two minutes-of-day rather than as dates, because it is a *rule* rather than an
/// instance: "held between 04:00 and 08:00" survives a relaunch, a time-zone change and the two
/// nights a year that are 23 or 25 hours long, none of which a stored pair of `Date`s does.
///
/// **`end <= start` crosses midnight**, which is the ordinary case: a window that begins at
/// 23:00 and ends at 07:00 is one window, not two, and the session held at 02:00 is being held
/// by a window that began yesterday. Every question below therefore looks at yesterday's window
/// as well as today's.
///
/// All of the arithmetic goes through `Calendar`. Adding 86,400 seconds to yesterday's start is
/// an hour wrong on the two nights that matter most here — a spring-forward night is exactly the
/// night somebody set a 04:00 curfew for — and `date(byAdding: .minute)` is wrong in the same
/// way, because time units add elapsed time while a wall-clock rule wants the same reading on
/// the clock. `nextDate(after:matching:)` is what answers "04:00 on this day", including the
/// day when 04:00 does not exist.
struct QuietHours: Codable, Equatable, Sendable {

    // MARK: - Properties

    var isEnabled: Bool

    /// Minutes since midnight, `0 ..< 1440`.
    var startMinute: Int
    var endMinute: Int

    // MARK: - Initialization

    init(
        isEnabled: Bool = false,
        startMinute: Int = CurfewDefaults.quietHoursStartMinute,
        endMinute: Int = CurfewDefaults.quietHoursEndMinute
    ) {
        self.isEnabled = isEnabled
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    static let `default` = QuietHours()

    // MARK: - Public Methods

    /// The window `now` is inside, if any.
    ///
    /// Half-open on purpose: a session is held **at** the start and free **at** the end. The end
    /// is the moment the curfew lifts, so treating it as still inside would hold every session
    /// one evaluation longer than the user asked for, every night.
    func window(containing now: Date, calendar: Calendar = .current) -> DateInterval? {
        guard isEnabled else { return nil }

        // Today's window first, then yesterday's — a window that crosses midnight *began*
        // yesterday, and 02:00 belongs to it rather than to the one starting tonight.
        for dayOffset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now),
                  let interval = window(startingOnDayOf: day, calendar: calendar) else { continue }
            if interval.start <= now && now < interval.end { return interval }
        }
        return nil
    }

    /// The next window that has not started yet.
    ///
    /// Strictly in the future, so a caller that already asked `window(containing:)` and got
    /// nothing gets the window to *arm* for rather than the one it is standing in.
    func nextWindow(after now: Date, calendar: Calendar = .current) -> DateInterval? {
        guard isEnabled else { return nil }

        // Today's window may still be ahead (asked at noon about a 23:00 start); tomorrow's
        // answers the rest. The third day is slack for a transition that moves a start across
        // midnight, and costs one comparison.
        for dayOffset in [0, 1, 2] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now),
                  let interval = window(startingOnDayOf: day, calendar: calendar) else { continue }
            if interval.start > now { return interval }
        }
        return nil
    }

    // MARK: - Private Methods

    /// The window that begins on the calendar day of `date`.
    private func window(startingOnDayOf date: Date, calendar: Calendar) -> DateInterval? {
        guard let start = Self.moment(startMinute, onDayOf: date, calendar: calendar) else {
            return nil
        }
        // `end <= start` is the midnight-crossing case, and equality is a whole day rather than
        // an empty window: "from 04:00 to 04:00" is a session held around the clock.
        let crossesMidnight = endMinute <= startMinute
        let endDay = crossesMidnight
            ? calendar.date(byAdding: .day, value: 1, to: date)
            : date
        guard let endDay,
              let wallClockEnd = Self.moment(endMinute, onDayOf: endDay, calendar: calendar) else {
            return nil
        }

        let end: Date
        if wallClockEnd > start {
            end = wallClockEnd
        } else if !crossesMidnight,
                  wallClockEnd == start,
                  endMinute > startMinute {
            // Two different readings inside a spring-forward gap both resolve to the first real
            // moment after it. Preserve the configured span in that one degenerate case instead
            // of silently dropping the night's window. Other transition windows keep their
            // chosen wall-clock end above, even when their elapsed duration is 23 or 25 hours.
            end = start.addingTimeInterval(
                TimeInterval(endMinute - startMinute) * QuietHoursDefaults.secondsPerMinute
            )
        } else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }

    /// A minute-of-day on one calendar day, as a moment.
    ///
    /// Searched forward from just before that day's start rather than set on it: `date(from:)`
    /// and `date(bySettingHour:…of:)` disagree about a time that does not exist on a
    /// spring-forward day, while `matchingPolicy: .nextTime` has one answer — the first moment
    /// after the missing one — which is the reading a nightly window wants. Starting the search
    /// one second before midnight is what keeps a 00:00 window on the day it names instead of
    /// the next one, since the search is strictly forward.
    private static func moment(
        _ minuteOfDay: Int,
        onDayOf date: Date,
        calendar: Calendar
    ) -> Date? {
        let dayStart = calendar.startOfDay(for: date)
        return calendar.nextDate(
            after: dayStart.addingTimeInterval(QuietHoursDefaults.searchLeadIn),
            matching: DateComponents(
                hour: minuteOfDay / CurfewDefaults.minutesPerHour,
                minute: minuteOfDay % CurfewDefaults.minutesPerHour
            ),
            matchingPolicy: .nextTime,
            direction: .forward
        )
    }
}

// MARK: - Quiet Hours Defaults

enum QuietHoursDefaults {

    /// How far before a day's first moment the search for a time of day begins. See
    /// `QuietHours.moment(_:onDayOf:calendar:)`.
    static let searchLeadIn: TimeInterval = -1

    /// Converts the stored minute-of-day span into elapsed time for a collapsed skipped hour.
    static let secondsPerMinute: TimeInterval = 60
}

// MARK: - Curfew Preferences

/// The app-wide half of the feature: the margins every curfew inherits, the wrap-up it sends,
/// and the standing window it applies nightly.
///
/// One record rather than four keys, so a single decode answers everything the Settings page,
/// the resolution chain and the engine ask, and so a half-written change cannot leave the
/// margins from one build beside the window of another.
struct CurfewPreferences: Codable, Equatable, Sendable {

    /// How long before the deadline the wrap-up goes out. `nil` is off — no wrap-up at all.
    var windDownMargin: TimeInterval?

    /// How long after the deadline a turn still in flight is left alone. `nil` is **never
    /// interrupt**: the hold still applies and Threading stops spending the session, but nothing
    /// is typed into it.
    var grace: TimeInterval?

    /// The wrap-up template, with `CurfewDefaults.timePlaceholder` standing in for the time.
    var windDownText: String

    var quietHours: QuietHours

    /// Whether a curfew that has given up also ends the agent.
    ///
    /// **Off unless the user says otherwise.** The shipped ladder stops at an interrupt: the
    /// whole feature exists so somebody can read the conversation in the morning, and ending a
    /// process nobody asked to end is the one step of this that cannot be taken back. Switched
    /// on, the escalation still *terminates* rather than discards — the final screen stays and
    /// the session resumes by its ordinary affordance.
    var stopsAgentOnGiveUp: Bool

    init(
        windDownMargin: TimeInterval? = CurfewDefaults.windDownMargin,
        grace: TimeInterval? = CurfewDefaults.grace,
        windDownText: String = CurfewDefaults.windDownText,
        quietHours: QuietHours = .default,
        stopsAgentOnGiveUp: Bool = false
    ) {
        self.windDownMargin = windDownMargin
        self.grace = grace
        self.windDownText = windDownText
        self.quietHours = quietHours
        self.stopsAgentOnGiveUp = stopsAgentOnGiveUp
    }

    static let `default` = CurfewPreferences()

    // MARK: - Codable

    /// Hand-written for one key, and only for that key.
    ///
    /// A synthesized decode of a non-optional `Bool` throws `keyNotFound` on every record written
    /// before this switch existed, and `RecoverableDefaultsStore` answers a throw by quarantining
    /// the value and standing the defaults up — so adding the switch would silently reset the
    /// margins, the wrap-up text and the standing window of everyone who had set them. The other
    /// four keys decode exactly as they always did, so a record this build cannot read stays a
    /// record this build refuses rather than one it quietly rewrites.
    enum CodingKeys: String, CodingKey {
        case windDownMargin
        case grace
        case windDownText
        case quietHours
        case stopsAgentOnGiveUp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windDownMargin = try container.decodeIfPresent(TimeInterval.self, forKey: .windDownMargin)
        grace = try container.decodeIfPresent(TimeInterval.self, forKey: .grace)
        windDownText = try container.decode(String.self, forKey: .windDownText)
        quietHours = try container.decode(QuietHours.self, forKey: .quietHours)
        stopsAgentOnGiveUp = try container
            .decodeIfPresent(Bool.self, forKey: .stopsAgentOnGiveUp) ?? false
    }
}

// MARK: - Curfew Settings

/// Where the curfew defaults and the standing quiet hours are kept.
///
/// Through `PreferenceStore` rather than `UserDefaults.standard`, for the reason
/// `UsageWindowSettings` documents and this setting makes sharper still: the test bundle is
/// hosted in the app, so `.standard` here would be the developer's own preferences, and a test
/// that switched quiet hours on would be arming a nightly hold — and, past the grace, an Escape
/// typed into a terminal — on the copy of Threading they are actually working in. The redirect
/// makes that impossible to write by accident, and `SessionCurfewCenter` refuses to start under
/// a test bundle as well, because one guard for a feature that types into somebody's session is
/// not enough.
@MainActor
final class CurfewSettings {

    // MARK: - Singleton

    static let shared = CurfewSettings()

    // MARK: - Properties

    private let persistence: RecoverableDefaultsStore<CurfewPreferences>

    /// Decoded once and written through: the engine reads this on every evaluation and the
    /// Settings page on every layout pass, neither of which should pay for JSON.
    private var cached: CurfewPreferences

    // MARK: - Initialization

    init(defaults: UserDefaults = PreferenceStore.shared) {
        let persistence = RecoverableDefaultsStore<CurfewPreferences>(
            defaults: defaults,
            key: Keys.curfewPreferences,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
        self.persistence = persistence
        self.cached = persistence.load(
            defaultValue: .default,
            validate: Self.validate
        ).value
    }

    // MARK: - Public Methods

    /// The standing preferences. Read-modify-write: every writer changes one field of the record
    /// it just read, so two surfaces editing different fields cannot erase each other.
    ///
    /// An invalid record is **refused rather than clamped**. A margin silently rounded to the
    /// nearest offered choice would be a setting that does not say what it does, and this one
    /// decides when the app stops spending somebody's session.
    var preferences: CurfewPreferences {
        get { cached }
        set {
            guard newValue != cached else { return }
            do {
                try Self.validate(newValue)
            } catch {
                ThreadingLogger.session.error("Refusing invalid curfew preferences")
                return
            }
            guard persistence.save(newValue) else { return }
            cached = newValue
            NotificationCenter.default.post(CurfewSettingsDidChange())
        }
    }

    // MARK: - Private Methods

    private enum ValidationError: Error {
        case invalidPreferences
    }

    private static func validate(_ preferences: CurfewPreferences) throws {
        let text = preferences.windDownText
        guard (0 ..< CurfewDefaults.minutesPerDay).contains(preferences.quietHours.startMinute),
              (0 ..< CurfewDefaults.minutesPerDay).contains(preferences.quietHours.endMinute),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= CurfewDefaults.maximumWindDownTextBytes,
              CurfewDefaults.windDownMarginChoices.contains(preferences.windDownMargin),
              CurfewDefaults.graceChoices.contains(preferences.grace) else {
            throw ValidationError.invalidPreferences
        }
    }

    private enum Keys {
        static let curfewPreferences = "curfewPreferences"
    }
}

// MARK: - Events

struct CurfewSettingsDidChange: AppEvent {
    static let name = Notification.Name("ThreadingCurfewSettingsDidChange")
}
