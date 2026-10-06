import Foundation
import ThreadingExtensionKit

// MARK: - Theme Welcome Grammar

/// The part of a theme's welcome both ends read the same way: the `{token}` grammar a greeting
/// or caption line is written in, the conditions that make a line eligible, and the weighted
/// pick among the eligible ones.
///
/// It lives here, Foundation-only, because the Mac's new-session composer and the phone's
/// new-chat screen both show a theme's lines, each on its own clock, calendar and locale. One
/// definition means a line that renders on the Mac renders the same way on the phone, and a
/// condition that holds at nine on a Friday holds there too. The Mac's `ThemeWelcome` names
/// these types through nested typealiases, so its own spelling (`ThemeWelcome.Template`,
/// `ThemeWelcome.Line`) and its stored form are unchanged.
///
/// Nothing here is drawing: styles, inks, marks and backdrops are each end's own. Nor is anything
/// here a fact store: a `{fact:KEY}` token names an extension fact by the SDK's own key
/// (`ExtensionFactKey`), and the host that shows the line supplies the value already worded.
public enum ThemeWelcomeGrammar {

    // MARK: Limits

    /// The bounds the grammar itself relies on. The Mac's `ThemeWelcomeLimits` restates these
    /// beside the ones only it draws with (mark sides, scales, scrims).
    public enum Limits {
        /// A pool large enough for a year of dated lines and still bounded to scan per arrival.
        public static let maximumLines = 64
        /// The hero floats in the room above the prompt; a longer line wraps past what it holds.
        public static let maximumLineLength = 160
        public static let weights = 1...10
        public static let hours = 0...23
        public static let months = 1...12
        public static let maximumDateSpans = 12
    }

    // MARK: Line

    public struct Line: Equatable, Sendable {
        /// The author's text with `{token}`s (`ThemeWelcomeGrammar.Template`).
        public var text: String
        /// When the line may be shown. Absent means always.
        public var when: Condition?
        /// How often the line is picked relative to the other eligible ones.
        public var weight: Int

        public init(text: String, when: Condition? = nil, weight: Int = 1) {
            self.text = text
            self.when = when
            self.weight = weight
        }
    }

    // MARK: Conditions

    /// When a line may be shown. Every stated facet must match; within a facet any value does.
    public struct Condition: Equatable, Sendable {
        public var dayparts: Set<Daypart>
        public var hours: Hours?
        public var weekdays: Set<Weekday>
        public var dates: [DateSpan]
        public var months: Set<Int>

        public init(
            dayparts: Set<Daypart> = [],
            hours: Hours? = nil,
            weekdays: Set<Weekday> = [],
            dates: [DateSpan] = [],
            months: Set<Int> = []
        ) {
            self.dayparts = dayparts
            self.hours = hours
            self.weekdays = weekdays
            self.dates = dates
            self.months = months
        }

        public var isEmpty: Bool {
            dayparts.isEmpty && hours == nil && weekdays.isEmpty && dates.isEmpty && months.isEmpty
        }

        public func matches(_ date: Date, calendar: Calendar) -> Bool {
            let parts = calendar.dateComponents([.hour, .weekday, .month, .day], from: date)
            guard let hour = parts.hour, let weekday = parts.weekday,
                  let month = parts.month, let day = parts.day else { return false }
            if !dayparts.isEmpty, !dayparts.contains(Daypart.of(hour: hour)) { return false }
            if let hours, !hours.contains(hour) { return false }
            if !weekdays.isEmpty, !weekdays.contains(where: { $0.calendarWeekday == weekday }) {
                return false
            }
            if !months.isEmpty, !months.contains(month) { return false }
            if !dates.isEmpty,
               !dates.contains(where: { $0.contains(month: month, day: day) }) { return false }
            return true
        }
    }

    /// The four parts of the day the app's own greeting already speaks in.
    public enum Daypart: String, Codable, CaseIterable, Sendable {
        case morning, afternoon, evening, night

        public static func of(hour: Int) -> Daypart {
            switch hour {
            case 5...11: return .morning
            case 12...16: return .afternoon
            case 17...22: return .evening
            default: return .night
            }
        }
    }

    public enum Weekday: String, Codable, CaseIterable, Sendable {
        case mon, tue, wed, thu, fri, sat, sun

        /// `Calendar`'s numbering, where Sunday is 1.
        public var calendarWeekday: Int {
            switch self {
            case .sun: return 1
            case .mon: return 2
            case .tue: return 3
            case .wed: return 4
            case .thu: return 5
            case .fri: return 6
            case .sat: return 7
            }
        }
    }

    /// An inclusive range of hours, 0…23. `from` after `to` wraps midnight (22–2).
    public struct Hours: Equatable, Codable, Sendable {
        public var from: Int
        public var to: Int

        public init(from: Int, to: Int) {
            self.from = from
            self.to = to
        }

        public func contains(_ hour: Int) -> Bool {
            from <= to ? (from...to).contains(hour) : (hour >= from || hour <= to)
        }

        public var isValid: Bool {
            Limits.hours.contains(from) && Limits.hours.contains(to)
        }
    }

    /// An inclusive range of calendar days, written `MM-DD`, in any year. `from` after `to`
    /// wraps the new year (`12-28` to `01-03`).
    public struct DateSpan: Equatable, Sendable {
        public var from: MonthDay
        public var to: MonthDay

        public init(from: MonthDay, to: MonthDay) {
            self.from = from
            self.to = to
        }

        public func contains(month: Int, day: Int) -> Bool {
            let value = MonthDay(month: month, day: day).ordinal
            return from.ordinal <= to.ordinal
                ? (from.ordinal...to.ordinal).contains(value)
                : (value >= from.ordinal || value <= to.ordinal)
        }
    }

    public struct MonthDay: Equatable, Hashable, Sendable {
        public var month: Int
        public var day: Int

        public init(month: Int, day: Int) {
            self.month = month
            self.day = day
        }

        /// Parses `MM-DD` (`12-24`, `1-1`). Nil for anything else or an impossible day.
        ///
        /// Each half is one or two ASCII digits and nothing else: a default `split` drops empty
        /// pieces and `Int` accepts a sign, which together read `-12-24`, `12--24` and `+1-+1`
        /// as dates an author never wrote.
        public init?(wireValue: String) {
            let parts = wireValue.trimmingCharacters(in: .whitespaces)
                .split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts.allSatisfy({ part in
                      (1...2).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isWholeNumber }
                  }),
                  let month = Int(parts[0]), let day = Int(parts[1]),
                  (1...12).contains(month),
                  (1...Self.daysInMonth[month - 1]).contains(day) else { return nil }
            self.init(month: month, day: day)
        }

        public var wireValue: String { String(format: "%02d-%02d", month, day) }
        var ordinal: Int { month * 100 + day }

        /// February counts 29 so a leap-day greeting is writable; it simply never matches in a
        /// common year.
        static let daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    }

    // MARK: Templates

    /// The `{token}` grammar a line is written in. `{{` and `}}` are literal braces; a token
    /// is a name and, for those that take one, an argument after a colon (`{days_until:12-24}`).
    public enum Template {

        public enum Token: Equatable, Sendable {
            /// The time, as the device showing the line writes it (14:05, 2:05 PM).
            case time
            /// The date, without the year (5 October).
            case date
            case weekday
            case month
            case day
            case year
            /// The part of the day in the host's words (morning, afternoon, evening, night).
            case daypart
            /// The composer's project. A line using it is not shown without one.
            case project
            /// The person's given name.
            case user
            /// How many sessions are working right now.
            case working
            /// How many sessions are waiting on the person.
            case waiting
            /// Whole days until the next occurrence of a date; 0 on the day itself.
            case daysUntil(MonthDay)
            /// A value an extension publishes (`{fact:ci.status}`, `{fact:ci.status@2}`), as the
            /// host that shows the line reads and words it. A line using one is not shown while
            /// no fresh value is published — and never where the host states no facts.
            case fact(ExtensionFactKey)

            /// Whether the rendered value moves with the clock while the composer is open, so
            /// the host re-renders the line on the minute.
            public var followsClock: Bool {
                switch self {
                case .time, .date, .weekday, .month, .day, .year, .daypart, .daysUntil: return true
                // A fact moves when its provider publishes, not with the clock; the host
                // re-renders on its own change notice instead.
                case .project, .user, .working, .waiting, .fact: return false
                }
            }

            /// The names an author writes, in the order the tool description lists them.
            public static let names = [
                "time", "date", "weekday", "month", "day", "year", "daypart",
                "project", "user", "working", "waiting", "days_until", "fact"
            ]

            /// How a `{fact:…}` argument is written, in the words a refusal uses: the SDK's own
            /// rules for a fact key (`ExtensionFactKey.validationIssues`), plus an optional
            /// `@VERSION` that defaults to 1.
            public static var factKeyRule: String {
                let versions = ExtensionFactKey.versionRange
                return "a fact key: a lowercase letter, then lowercase letters, digits, '-' or '.', "
                    + "at most \(ExtensionFactKey.maximumIDBytes) bytes, optionally followed by "
                    + "@VERSION (\(versions.lowerBound)–\(versions.upperBound); 1 when omitted)"
            }

            /// Parses `KEY` or `KEY@VERSION` by the SDK's rules for a fact key. The version is
            /// plain ASCII digits: `Int` alone would also read a sign.
            public static func factKey(_ source: String) -> ExtensionFactKey? {
                let parts = source.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
                var version = 1
                if parts.count == 2 {
                    let digits = parts[1]
                    guard !digits.isEmpty,
                          digits.count <= String(ExtensionFactKey.versionRange.upperBound).count,
                          digits.allSatisfy({ $0.isASCII && $0.isWholeNumber }),
                          let value = Int(digits) else { return nil }
                    version = value
                }
                let key = ExtensionFactKey(id: String(parts[0]), version: version)
                return key.validationIssues().isEmpty ? key : nil
            }
        }

        public enum Piece: Equatable, Sendable {
            case literal(String)
            case token(Token)
        }

        public enum ParseError: Error, Equatable, Sendable {
            case unknownToken(String)
            case unterminatedToken
            case strayClosingBrace
            case badArgument(token: String, argument: String)
        }

        /// Splits a line into literal text and tokens, or explains why it is not one.
        public static func parse(_ text: String) throws -> [Piece] {
            var pieces: [Piece] = []
            var literal = ""
            var index = text.startIndex
            func flush() {
                if !literal.isEmpty { pieces.append(.literal(literal)); literal = "" }
            }
            while index < text.endIndex {
                let character = text[index]
                let next = text.index(after: index)
                if character == "{" {
                    if next < text.endIndex, text[next] == "{" {
                        literal.append("{")
                        index = text.index(after: next)
                        continue
                    }
                    guard let close = text[next...].firstIndex(of: "}") else {
                        throw ParseError.unterminatedToken
                    }
                    flush()
                    pieces.append(.token(try token(String(text[next..<close]))))
                    index = text.index(after: close)
                } else if character == "}" {
                    guard next < text.endIndex, text[next] == "}" else {
                        throw ParseError.strayClosingBrace
                    }
                    literal.append("}")
                    index = text.index(after: next)
                } else {
                    literal.append(character)
                    index = next
                }
            }
            flush()
            return pieces
        }

        private static func token(_ source: String) throws -> Token {
            let parts = source.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let name = parts.first?.lowercased() ?? ""
            let argument = parts.count > 1 ? parts[1] : nil
            switch (name, argument) {
            case ("time", nil): return .time
            case ("date", nil): return .date
            case ("weekday", nil): return .weekday
            case ("month", nil): return .month
            case ("day", nil): return .day
            case ("year", nil): return .year
            case ("daypart", nil): return .daypart
            case ("project", nil): return .project
            case ("user", nil): return .user
            case ("working", nil): return .working
            case ("waiting", nil): return .waiting
            case ("days_until", let argument?):
                guard let day = MonthDay(wireValue: argument) else {
                    throw ParseError.badArgument(token: name, argument: argument)
                }
                return .daysUntil(day)
            case ("days_until", nil), ("fact", nil):
                // A known name missing its argument is a bad argument, not an unknown token: the
                // author spelled the token right and the message should say what it lacks.
                throw ParseError.badArgument(token: name, argument: "")
            case ("fact", let argument?):
                guard let key = Token.factKey(argument) else {
                    throw ParseError.badArgument(token: name, argument: argument)
                }
                return .fact(key)
            case (_, let argument?) where Token.names.contains(name):
                throw ParseError.badArgument(token: name, argument: argument)
            default:
                throw ParseError.unknownToken(source)
            }
        }

        /// The line as shown at `context`, or nil when a token it uses has no value there (a
        /// `{project}` line in a composer with no project) — such a line is not eligible.
        public static func render(_ text: String, context: Context) -> String? {
            guard let pieces = try? parse(text) else { return nil }
            var result = ""
            for piece in pieces {
                switch piece {
                case .literal(let value):
                    result += value
                case .token(let token):
                    guard let value = context.value(for: token) else { return nil }
                    result += value
                }
            }
            return result
        }

        public static func followsClock(_ text: String) -> Bool {
            uses(text) { $0.followsClock }
        }

        /// The fact keys `text` names, in order, each once. None for a line that does not parse.
        public static func factKeys(in text: String) -> [ExtensionFactKey] {
            var keys: [ExtensionFactKey] = []
            for case .token(.fact(let key)) in (try? parse(text)) ?? [] where !keys.contains(key) {
                keys.append(key)
            }
            return keys
        }

        /// Whether `text` names a token `matching` accepts. A line that does not parse names none.
        public static func uses(_ text: String, where matching: (Token) -> Bool) -> Bool {
            ((try? parse(text)) ?? []).contains {
                if case .token(let token) = $0 { return matching(token) }
                return false
            }
        }
    }

    // MARK: Context

    /// Everything a token can be filled from, gathered by the host when the composer is shown.
    /// Localized words (the daypart) are supplied rather than looked up, so the grammar has no
    /// dependency on either app's string catalogue.
    public struct Context {
        public var date: Date
        public var calendar: Calendar
        public var locale: Locale
        public var project: String?
        public var user: String?
        public var working: Int
        public var waiting: Int
        public var daypartName: (Daypart) -> String
        /// What each `{fact:KEY}` reads, already worded by the host: it reads its own fact store
        /// and formats the value by its own rules before it builds the context. A key absent
        /// here — or worded as blank — makes its line ineligible, as `{project}` without a
        /// project is. Empty by default, which is how a host with no facts (the phone) states it.
        public var facts: [ExtensionFactKey: String]

        public init(
            date: Date,
            calendar: Calendar,
            locale: Locale,
            project: String? = nil,
            user: String? = nil,
            working: Int = 0,
            waiting: Int = 0,
            daypartName: @escaping (Daypart) -> String = { $0.rawValue },
            facts: [ExtensionFactKey: String] = [:]
        ) {
            self.date = date
            self.calendar = calendar
            self.locale = locale
            self.project = project
            self.user = user
            self.working = working
            self.waiting = waiting
            self.daypartName = daypartName
            self.facts = facts
        }

        func value(for token: Template.Token) -> String? {
            switch token {
            case .time:
                return formatted(dateStyle: .none, timeStyle: .short)
            case .date:
                return formatted(template: "dMMMM")
            case .weekday:
                return formatted(template: "EEEE")
            case .month:
                return formatted(template: "MMMM")
            case .day:
                return String(calendar.component(.day, from: date))
            case .year:
                return String(calendar.component(.year, from: date))
            case .daypart:
                return daypartName(Daypart.of(hour: calendar.component(.hour, from: date)))
            case .project:
                return project.flatMap { $0.isEmpty ? nil : $0 }
            case .user:
                return user.flatMap { $0.isEmpty ? nil : $0 }
            case .working:
                return String(working)
            case .waiting:
                return String(waiting)
            case .daysUntil(let target):
                return daysUntil(target).map(String.init)
            case .fact(let key):
                return facts[key].flatMap {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                }
            }
        }

        private func formatted(dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
            return formatter.string(from: date)
        }

        private func formatted(template: String) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }

        /// Days from today to the next `target` (today counts 0). A February 29 target waits
        /// for the next leap year rather than landing on March 1.
        private func daysUntil(_ target: MonthDay) -> Int? {
            let today = calendar.startOfDay(for: date)
            let components = DateComponents(month: target.month, day: target.day)
            if target == MonthDay(month: calendar.component(.month, from: today),
                                  day: calendar.component(.day, from: today)) {
                return 0
            }
            guard let next = calendar.nextDate(
                after: today, matching: components, matchingPolicy: .strict
            ) else { return nil }
            return calendar.dateComponents([.day], from: today, to: next).day
        }
    }

    // MARK: Selection

    /// The lines that may be shown at `context`, rendered: their conditions hold and every
    /// token they use has a value. Only the first `Limits.maximumLines` are considered.
    public static func eligible(
        _ lines: [Line],
        at context: Context
    ) -> [(line: Line, text: String)] {
        lines.prefix(Limits.maximumLines).compactMap { line in
            if let when = line.when, !when.matches(context.date, calendar: context.calendar) {
                return nil
            }
            guard let text = Template.render(line.text, context: context),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (line, text)
        }
    }

    /// Every fact key the first `Limits.maximumLines` of `lines` name: what a host reads before
    /// it builds a context for them. Bounded by the pool's own caps (64 lines of 160 characters).
    public static func factKeys(in lines: [Line]) -> Set<ExtensionFactKey> {
        lines.prefix(Limits.maximumLines).reduce(into: Set<ExtensionFactKey>()) { keys, line in
            keys.formUnion(Template.factKeys(in: line.text))
        }
    }

    /// One eligible line, weighted, or nil when none is.
    public static func pick(
        _ lines: [Line],
        at context: Context,
        using generator: inout some RandomNumberGenerator
    ) -> Line? {
        let candidates = eligible(lines, at: context)
        let total = candidates.reduce(0) { $0 + max($1.line.weight, 1) }
        guard total > 0 else { return nil }
        var ticket = Int.random(in: 0..<total, using: &generator)
        for candidate in candidates {
            ticket -= max(candidate.line.weight, 1)
            if ticket < 0 { return candidate.line }
        }
        return candidates.last?.line
    }

    /// A greeting pool that may share its draw with the host's own line: one weighted draw over
    /// the eligible lines plus, when `includesHostLine`, one more candidate of weight 1 that
    /// stands for the host's greeting. Nil means the host's line — either it won the draw or no
    /// theme line is eligible. Drawing the host's share first and then among the theme's lines
    /// by their own weights is the same distribution as one draw over both.
    public static func pickSharing(
        _ lines: [Line],
        includesHostLine: Bool,
        at context: Context,
        using generator: inout some RandomNumberGenerator
    ) -> Line? {
        let total = eligible(lines, at: context).reduce(0) { $0 + max($1.line.weight, 1) }
        guard total > 0 else { return nil }
        if includesHostLine, Int.random(in: 0..<(total + 1), using: &generator) == 0 {
            return nil
        }
        return pick(lines, at: context, using: &generator)
    }
}

// MARK: - Codable

extension ThemeWelcomeGrammar.Line: Codable {
    private enum CodingKeys: String, CodingKey {
        case text, when, weight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        when = try container.decodeIfPresent(ThemeWelcomeGrammar.Condition.self, forKey: .when)
        weight = try container.decodeIfPresent(Int.self, forKey: .weight) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if let when, !when.isEmpty { try container.encode(when, forKey: .when) }
        if weight != 1 { try container.encode(weight, forKey: .weight) }
    }
}

extension ThemeWelcomeGrammar.Condition: Codable {
    private enum CodingKeys: String, CodingKey {
        case dayparts, hours, weekdays, dates, months
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dayparts = Set(try container.decodeIfPresent(
            [ThemeWelcomeGrammar.Daypart].self, forKey: .dayparts
        ) ?? [])
        hours = try container.decodeIfPresent(ThemeWelcomeGrammar.Hours.self, forKey: .hours)
        weekdays = Set(try container.decodeIfPresent(
            [ThemeWelcomeGrammar.Weekday].self, forKey: .weekdays
        ) ?? [])
        dates = try container.decodeIfPresent([ThemeWelcomeGrammar.DateSpan].self, forKey: .dates) ?? []
        months = Set(try container.decodeIfPresent([Int].self, forKey: .months) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let daypartOrder = ThemeWelcomeGrammar.Daypart.allCases
        let weekdayOrder = ThemeWelcomeGrammar.Weekday.allCases
        if !dayparts.isEmpty {
            try container.encode(daypartOrder.filter(dayparts.contains), forKey: .dayparts)
        }
        try container.encodeIfPresent(hours, forKey: .hours)
        if !weekdays.isEmpty {
            try container.encode(weekdayOrder.filter(weekdays.contains), forKey: .weekdays)
        }
        if !dates.isEmpty { try container.encode(dates, forKey: .dates) }
        if !months.isEmpty { try container.encode(months.sorted(), forKey: .months) }
    }
}

extension ThemeWelcomeGrammar.DateSpan: Codable {
    private enum CodingKeys: String, CodingKey {
        case from, to
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fromValue = try container.decode(String.self, forKey: .from)
        let toValue = try container.decodeIfPresent(String.self, forKey: .to) ?? fromValue
        guard let from = ThemeWelcomeGrammar.MonthDay(wireValue: fromValue),
              let to = ThemeWelcomeGrammar.MonthDay(wireValue: toValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .from, in: container, debugDescription: "Dates are written MM-DD."
            )
        }
        self.init(from: from, to: to)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from.wireValue, forKey: .from)
        if to != from { try container.encode(to.wireValue, forKey: .to) }
    }
}
