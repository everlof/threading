import Foundation

/// The line the empty composer greets with.
///
/// A fixed heading read twice is furniture; a greeting that knows it is Friday evening — but
/// only *sometimes* mentions it — stays worth a glance. The variety is the point, so the rule
/// is written here once: when the date offers a special (a holiday, a Friday, a weekend), the
/// pick favours it without being owned by it, and on an ordinary Tuesday most greetings say
/// nothing about the clock at all.
///
/// The date is a parameter and the randomness is injected, so production reads the clock at
/// the call site and a test passes a fixed date with a seeded generator — the logic itself
/// never asks what time it is.
enum ComposerGreeting {

    // MARK: - Selection odds

    private enum Odds {
        /// When the calendar offers a special, how often the greeting takes it.
        static let special = 0.6
        /// Otherwise, how often the greeting mentions the time of day rather than nothing.
        static let daypart = 0.4
    }

    // MARK: - Dayparts

    enum Daypart: Equatable {
        case morning, afternoon, evening, lateNight

        static func of(hour: Int) -> Daypart {
            switch hour {
            case 5...11: .morning
            case 12...16: .afternoon
            case 17...22: .evening
            default: .lateNight
            }
        }
    }

    /// Everything the given moment could say, split by how it would say it. The testable core:
    /// specials fire on their dates and are empty on an ordinary day.
    struct Candidates: Equatable {
        let plain: [String]
        let daypart: [String]
        let special: [String]
    }

    // MARK: - Message

    static func message(
        on date: Date,
        calendar: Calendar,
        using generator: inout some RandomNumberGenerator
    ) -> String {
        let candidates = candidates(for: date, calendar: calendar)
        if !candidates.special.isEmpty, Double.random(in: 0..<1, using: &generator) < Odds.special {
            return pick(from: candidates.special, using: &generator)
        }
        if Double.random(in: 0..<1, using: &generator) < Odds.daypart {
            return pick(from: candidates.daypart, using: &generator)
        }
        return pick(from: candidates.plain, using: &generator)
    }

    /// The production spelling: this moment, the system generator.
    static func message() -> String {
        var generator = SystemRandomNumberGenerator()
        return message(on: Date(), calendar: .current, using: &generator)
    }

    private static func pick(
        from pool: [String],
        using generator: inout some RandomNumberGenerator
    ) -> String {
        pool.randomElement(using: &generator) ?? L10n.string("What are we building today?")
    }

    // MARK: - Pools

    static func candidates(for date: Date, calendar: Calendar) -> Candidates {
        let hour = calendar.component(.hour, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let daypart = Daypart.of(hour: hour)
        let isFriday = weekday == 6
        let isWeekend = calendar.isDateInWeekend(date)

        var special: [String] = []

        switch (month, day) {
        case (1, 1):
            special.append(L10n.string("New year, new threads."))
        case (6, 19...26):
            special.append(L10n.string("Midsummer light — long days, long sessions."))
        case (10, 31):
            special.append(L10n.string("Spooky season. Fear no merge conflict."))
        case (12, 24...25):
            special.append(L10n.string("Merry Christmas — threads under the tree."))
        case (12, 26...30):
            special.append(L10n.string("The quiet week between the years."))
        case (12, 31):
            special.append(L10n.string("The last hours of the year. Make them count."))
            if daypart == .lateNight || daypart == .evening {
                special.append(L10n.string("Seeing the year out in good company."))
            }
        default:
            break
        }

        if isFriday {
            special.append(L10n.string("It's Friday — ship it or shelve it?"))
            if daypart == .evening {
                special.append(L10n.string("Friday evening — one last push, or a fresh start?"))
            }
        }
        if isWeekend {
            special.append(L10n.string("Weekend project time."))
            if daypart == .morning {
                special.append(L10n.string("A weekend morning — unhurried, and all yours."))
            }
        }

        return Candidates(
            plain: [
                L10n.string("What are we building today?"),
                L10n.string("Ready when you are."),
                L10n.string("Pick up where you left off, or start something new."),
                L10n.string("A blank line is a good place to begin."),
                L10n.string("What's on your mind?"),
                L10n.string("Let's make something."),
                L10n.string("Where to next?"),
                L10n.string("Type a brief, start a thread.")
            ],
            daypart: daypartPool(for: daypart),
            special: special
        )
    }

    private static func daypartPool(for daypart: Daypart) -> [String] {
        switch daypart {
        case .morning:
            [
                L10n.string("Good morning. Coffee, then code?"),
                L10n.string("Morning — the day is still unwritten."),
                L10n.string("An early start. Let's use it.")
            ]
        case .afternoon:
            [
                L10n.string("Good afternoon. Where were we?"),
                L10n.string("The afternoon is young."),
                L10n.string("A fine hour to ship something.")
            ]
        case .evening:
            [
                L10n.string("Good evening. One more thing before the day ends?"),
                L10n.string("The evening session — the quiet hours."),
                L10n.string("Winding down, or winding up?")
            ]
        case .lateNight:
            [
                L10n.string("Late night. The best ideas keep odd hours."),
                L10n.string("Burning the midnight oil?"),
                L10n.string("Quiet out there. Perfect.")
            ]
        }
    }
}
