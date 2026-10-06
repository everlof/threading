import Foundation
import ThreadingExtensionKit
import XCTest
@testable import ThreadingRemoteKit

/// The welcome's shared grammar (`ThemeWelcomeGrammar`): tokens and refusals, rendering against
/// a fixed moment, which lines are eligible, conditions at their edges, the weighted pick and
/// the stored form of a line. The Mac's `ThemeWelcome` and the phone's new-chat screen both read
/// lines through this one definition, so its behaviour is pinned here, beside it.
///
/// Every clock is stated — a fixed date, a Gregorian calendar in a named zone and a named
/// locale — so nothing here depends on when or where the suite runs.
final class ThemeWelcomeGrammarTests: XCTestCase {
    private typealias Grammar = ThemeWelcomeGrammar

    // MARK: - Fixtures

    private static func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// Monday 5 October 2026, 14:05 in `zone`.
    private static func date(
        _ year: Int = 2026, _ month: Int = 10, _ day: Int = 5,
        hour: Int = 14, minute: Int = 5, zone: String = "UTC"
    ) -> Date {
        calendar(zone).date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private static func context(
        _ date: Date = date(),
        zone: String = "UTC",
        locale: String = "en_GB",
        project: String? = nil,
        user: String? = "Ada",
        working: Int = 0,
        waiting: Int = 0,
        facts: [ExtensionFactKey: String] = [:]
    ) -> Grammar.Context {
        Grammar.Context(
            date: date,
            calendar: calendar(zone),
            locale: Locale(identifier: locale),
            project: project,
            user: user,
            working: working,
            waiting: waiting,
            daypartName: { "the \($0.rawValue)" },
            facts: facts
        )
    }

    private static func day(_ wire: String) -> Grammar.MonthDay {
        Grammar.MonthDay(wireValue: wire)!
    }

    /// SplitMix64: a seeded generator, so a weighted pick is the same pick on every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    // MARK: - Grammar

    func testEveryTokenParsesAndTheListNamesThemAll() throws {
        let line = "{time} {date} {weekday} {month} {day} {year} {daypart} {project} {user} "
            + "{working} {waiting} {days_until:12-24} {fact:ci.status}"
        let tokens = try Grammar.Template.parse(line).compactMap { piece -> Grammar.Template.Token? in
            if case .token(let token) = piece { return token }
            return nil
        }
        XCTAssertEqual(tokens, [
            .time, .date, .weekday, .month, .day, .year, .daypart, .project, .user, .working,
            .waiting, .daysUntil(Self.day("12-24")), .fact(ExtensionFactKey(id: "ci.status"))
        ])
        XCTAssertEqual(Grammar.Template.Token.names.count, tokens.count)
        XCTAssertEqual(try Grammar.Template.parse("{ TIME }"), [.token(.time)],
                       "names are case- and space-tolerant")
    }

    func testAMalformedLineSaysWhatIsWrongWithIt() {
        typealias ParseError = Grammar.Template.ParseError
        func error(_ text: String) -> ParseError? {
            let outcome = Result { try Grammar.Template.parse(text) }
            guard case .failure(let failure) = outcome else { return nil }
            return failure as? ParseError
        }
        XCTAssertEqual(error("Hello {name}"), .unknownToken("name"))
        XCTAssertEqual(error("Hello {}"), .unknownToken(""))
        XCTAssertEqual(error("Hello {time"), .unterminatedToken)
        XCTAssertEqual(error("Hello {"), .unterminatedToken)
        XCTAssertEqual(error("Hello }"), .strayClosingBrace)
        XCTAssertEqual(error("{time:HH}"), .badArgument(token: "time", argument: "HH"))
        XCTAssertEqual(error("{days_until:13-01}"), .badArgument(token: "days_until", argument: "13-01"))
        XCTAssertEqual(error("{days_until:02-30}"), .badArgument(token: "days_until", argument: "02-30"))
        XCTAssertEqual(error("{days_until}"), .badArgument(token: "days_until", argument: ""),
                       "a known name missing its date is a bad argument, not an unknown token")
    }

    // MARK: - Facts

    /// `{fact:KEY}` names a fact by the SDK's own key rules — a contribution identifier of at
    /// most 128 bytes, with an optional `@VERSION` in plain digits — and nothing looser.
    func testAFactTokenNamesAKeyByTheSDKsRules() throws {
        func token(_ text: String) throws -> Grammar.Template.Token? {
            guard case .token(let token) = try Grammar.Template.parse(text).first else { return nil }
            return token
        }
        XCTAssertEqual(try token("{fact:ci.status}"), .fact(.init(id: "ci.status", version: 1)))
        XCTAssertEqual(try token("{fact:ci.status@2}"), .fact(.init(id: "ci.status", version: 2)))
        XCTAssertEqual(try token("{ FACT : weather.now-c }"), .fact(.init(id: "weather.now-c")),
                       "the name is case- and space-tolerant like every other")
        XCTAssertEqual(try token("{fact:project.branch}"), .fact(.init(id: "project.branch")),
                       "a host-owned key is a key like any other; the host decides what it reads")
        let longest = "a" + String(repeating: "b", count: ExtensionFactKey.maximumIDBytes - 1)
        XCTAssertEqual(try token("{fact:\(longest)@1000000}"), .fact(.init(id: longest, version: 1_000_000)))

        func refusal(_ text: String) -> Grammar.Template.ParseError? {
            let outcome = Result { try Grammar.Template.parse(text) }
            guard case .failure(let failure) = outcome else { return nil }
            return failure as? Grammar.Template.ParseError
        }
        XCTAssertEqual(refusal("{fact}"), .badArgument(token: "fact", argument: ""),
                       "a fact with no key is a bad argument, not an unknown token")
        for argument in [
            "CI.status", "9lives", "-ci", "ci status", "ci_status", "ci.status@", "ci.status@0",
            "ci.status@-1", "ci.status@+2", "ci.status@1000001", "ci.status@12345678",
            "ci.status@2@3", "ci.status@ 2", "@2", longest + "b",
        ] {
            XCTAssertEqual(refusal("{fact:\(argument)}"),
                           .badArgument(token: "fact", argument: argument), argument)
        }
        XCTAssertTrue(Grammar.Template.Token.factKeyRule.contains("\(ExtensionFactKey.maximumIDBytes)"))
    }

    /// A fact is filled from the words the host supplies, and a line whose fact the host does not
    /// state — or states as blank — is ineligible, as `{project}` without a project is. Facts move
    /// when their provider publishes, so they never put a line on the clock.
    func testAFactLineRendersTheHostsWordsAndIsIneligibleWithoutThem() {
        let status = ExtensionFactKey(id: "ci.status")
        let weather = ExtensionFactKey(id: "weather.now", version: 2)
        let lines: [Grammar.Line] = [
            .init(text: "CI is {fact:ci.status}."),
            .init(text: "{fact:weather.now@2} outside, CI {fact:ci.status}"),
            .init(text: "Plain.")
        ]
        XCTAssertEqual(Grammar.eligible(lines, at: Self.context()).map(\.text), ["Plain."],
                       "a host with no facts — the phone — shows no fact line")
        XCTAssertEqual(
            Grammar.eligible(lines, at: Self.context(facts: [status: "passing"])).map(\.text),
            ["CI is passing.", "Plain."]
        )
        XCTAssertEqual(
            Grammar.eligible(lines, at: Self.context(facts: [status: "passing", weather: "12 °C"]))
                .map(\.text),
            ["CI is passing.", "12 °C outside, CI passing", "Plain."]
        )
        XCTAssertNil(Grammar.Template.render("CI {fact:ci.status}", context: Self.context(facts: [status: " \n"])),
                     "a blank value is no value")
        XCTAssertNil(Grammar.Template.render("{fact:ci.status@2}", context: Self.context(facts: [status: "v1"])),
                     "a version is part of the key")

        XCTAssertFalse(Grammar.Template.followsClock("CI {fact:ci.status}"))
        XCTAssertTrue(Grammar.Template.followsClock("{time}: CI {fact:ci.status}"))
        XCTAssertEqual(Grammar.Template.factKeys(in: "{fact:ci.status} {fact:weather.now@2} {fact:ci.status}"),
                       [status, weather], "in order, each once")
        XCTAssertEqual(Grammar.Template.factKeys(in: "{{fact:ci.status}}"), [], "a doubled brace is text")
        XCTAssertEqual(Grammar.Template.factKeys(in: "Broken {fact:ci.status"), [])
        XCTAssertEqual(Grammar.factKeys(in: lines), [status, weather])

        let beyond = (0..<Grammar.Limits.maximumLines).map { Grammar.Line(text: "Line \($0)") }
            + [Grammar.Line(text: "{fact:late.key}")]
        XCTAssertEqual(Grammar.factKeys(in: beyond), [],
                       "keys past the bounded pool are never read, as their lines are never judged")
    }

    func testDoubledBracesAreLiteralAndRenderAsOne() throws {
        XCTAssertEqual(
            try Grammar.Template.parse("{{literal}} {user}"),
            [.literal("{literal} "), .token(.user)]
        )
        XCTAssertEqual(Grammar.Template.render("{{literal}} {user}", context: Self.context()),
                       "{literal} Ada")
        XCTAssertEqual(Grammar.Template.render("}} and {{", context: Self.context()), "} and {")
        XCTAssertEqual(Grammar.Template.render("Plain words", context: Self.context()), "Plain words")
        XCTAssertNil(Grammar.Template.render("Broken {", context: Self.context()),
                     "a line that does not parse renders as nothing, never as its source")
    }

    func testOnlyTheWrittenMonthDayFormParses() {
        XCTAssertEqual(Grammar.MonthDay(wireValue: "12-24"), .init(month: 12, day: 24))
        XCTAssertEqual(Grammar.MonthDay(wireValue: "1-1"), .init(month: 1, day: 1))
        XCTAssertEqual(Grammar.MonthDay(wireValue: " 02-29 "), .init(month: 2, day: 29),
                       "a leap day is writable")
        for refused in ["02-30", "13-01", "00-10", "04-31", "-12-24", "12--24", "+1-1", "1224",
                        "12-24-1", "012-24", "ab-cd", ""] {
            XCTAssertNil(Grammar.MonthDay(wireValue: refused), refused)
        }
        XCTAssertEqual(Grammar.MonthDay(month: 3, day: 7).wireValue, "03-07")
    }

    func testOnlyTheClockTokensFollowTheClock() {
        XCTAssertTrue(Grammar.Template.followsClock("It is {time}"))
        XCTAssertTrue(Grammar.Template.followsClock("{days_until:12-24} sleeps"))
        XCTAssertFalse(Grammar.Template.followsClock("Hello {user} in {project}"))
        XCTAssertFalse(Grammar.Template.followsClock("No tokens {{here}}"))
        XCTAssertFalse(Grammar.Template.followsClock("Broken {time"))
        XCTAssertTrue(Grammar.Template.uses("Hi {user}") { $0 == .user })
        XCTAssertFalse(Grammar.Template.uses("Hi {{user}}") { $0 == .user },
                       "a doubled brace is literal text, not the token")
    }

    // MARK: - Rendering

    func testTokensRenderFromAFixedMomentInTheStatedLocale() {
        let context = Self.context(project: "Threading", working: 3, waiting: 1)
        func render(_ text: String) -> String? { Grammar.Template.render(text, context: context) }

        XCTAssertEqual(render("{time}"), "14:05")
        XCTAssertEqual(render("{date}"), "5 October")
        XCTAssertEqual(render("{weekday}, {day} {month} {year}"), "Monday, 5 October 2026")
        XCTAssertEqual(render("Good {daypart}"), "Good the afternoon",
                       "the daypart word is the host's, supplied through the context")
        XCTAssertEqual(render("{user} in {project}"), "Ada in Threading")
        XCTAssertEqual(render("{working} working, {waiting} waiting"), "3 working, 1 waiting")

        let swedish = Self.context(locale: "sv_SE")
        XCTAssertEqual(Grammar.Template.render("{weekday}", context: swedish), "måndag")
    }

    func testTheClockIsReadInTheCalendarsZone() {
        // 23:30 UTC on the 5th is half past one on the 6th in Stockholm (CEST).
        let moment = Self.date(hour: 23, minute: 30)
        let stockholm = Self.context(moment, zone: "Europe/Stockholm")
        XCTAssertEqual(Grammar.Template.render("{time} {day}", context: stockholm), "01:30 6")
        XCTAssertEqual(Grammar.Template.render("{daypart}", context: stockholm), "the night")
    }

    func testDaysUntilCountsWholeDaysToTheNextOccurrence() {
        func days(_ target: String, from date: Date, zone: String = "UTC") -> String? {
            Grammar.Template.render("{days_until:\(target)}", context: Self.context(date, zone: zone))
        }
        let today = Self.date()
        XCTAssertEqual(days("10-05", from: today), "0", "the day itself is 0, not a year away")
        XCTAssertEqual(days("10-06", from: today), "1")
        XCTAssertEqual(days("12-24", from: today), "80")
        XCTAssertEqual(days("01-01", from: today), "88", "a date already passed waits for next year")
        XCTAssertEqual(days("10-04", from: today), "364")
        XCTAssertEqual(days("02-29", from: today), "512",
                       "a leap day waits for the next leap year rather than landing on 1 March")
        XCTAssertEqual(days("02-29", from: Self.date(2028, 2, 29)), "0")
        XCTAssertEqual(days("02-29", from: Self.date(2028, 3, 1)), "1460")
        XCTAssertEqual(days("12-24", from: Self.date(hour: 0, minute: 30, zone: "Europe/Stockholm"),
                            zone: "Europe/Stockholm"), "80",
                       "the autumn clock change does not cost a day")
    }

    // MARK: - Eligibility

    func testAProjectOrUserLineIsIneligibleWithoutItsValue() {
        let lines: [Grammar.Line] = [.init(text: "Back to {project}?"), .init(text: "Hello, {user}")]
        XCTAssertEqual(Grammar.eligible(lines, at: Self.context()).map(\.text), ["Hello, Ada"])
        XCTAssertEqual(Grammar.eligible(lines, at: Self.context(project: "")).map(\.text), ["Hello, Ada"])
        XCTAssertEqual(
            Grammar.eligible(lines, at: Self.context(project: "Threading")).map(\.text),
            ["Back to Threading?", "Hello, Ada"]
        )
        XCTAssertEqual(Grammar.eligible(lines, at: Self.context(user: nil)).map(\.text), [],
                       "no given name — a guest's phone — makes {user} lines ineligible")
    }

    func testOnlyTheFirstBoundedLinesAreConsidered() {
        let lines = (0..<(Grammar.Limits.maximumLines + 6)).map { Grammar.Line(text: "Line \($0)") }
        XCTAssertEqual(Grammar.eligible(lines, at: Self.context()).count, Grammar.Limits.maximumLines)
    }

    func testHourRangesWrapMidnight() {
        let night = Grammar.Hours(from: 22, to: 4)
        for hour in [22, 23, 0, 3, 4] { XCTAssertTrue(night.contains(hour), "\(hour)") }
        for hour in [5, 12, 21] { XCTAssertFalse(night.contains(hour), "\(hour)") }
        let office = Grammar.Hours(from: 9, to: 17)
        XCTAssertTrue(office.contains(9))
        XCTAssertTrue(office.contains(17), "the last hour is inclusive")
        XCTAssertFalse(office.contains(18))
        XCTAssertTrue(Grammar.Hours(from: 7, to: 7).contains(7))
        XCTAssertFalse(Grammar.Hours(from: 22, to: 24).isValid)

        let condition = Grammar.Condition(hours: night)
        XCTAssertTrue(condition.matches(Self.date(hour: 23, minute: 59), calendar: Self.calendar()))
        XCTAssertTrue(condition.matches(Self.date(hour: 0, minute: 0), calendar: Self.calendar()))
        XCTAssertFalse(condition.matches(Self.date(hour: 12, minute: 0), calendar: Self.calendar()))
    }

    func testDateSpansWrapTheYear() {
        let holidays = Grammar.DateSpan(from: Self.day("12-28"), to: Self.day("01-03"))
        for (month, day) in [(12, 28), (12, 31), (1, 1), (1, 3)] {
            XCTAssertTrue(holidays.contains(month: month, day: day), "\(month)-\(day)")
        }
        for (month, day) in [(12, 27), (1, 4), (6, 15)] {
            XCTAssertFalse(holidays.contains(month: month, day: day), "\(month)-\(day)")
        }
        let christmas = Grammar.DateSpan(from: Self.day("12-24"), to: Self.day("12-26"))
        XCTAssertTrue(christmas.contains(month: 12, day: 25))
        XCTAssertFalse(christmas.contains(month: 12, day: 27))

        let condition = Grammar.Condition(dates: [holidays])
        XCTAssertTrue(condition.matches(Self.date(2026, 12, 31), calendar: Self.calendar()))
        XCTAssertTrue(condition.matches(Self.date(2027, 1, 2), calendar: Self.calendar()))
        XCTAssertFalse(condition.matches(Self.date(2027, 1, 4), calendar: Self.calendar()))
    }

    func testEveryStatedFacetMustHoldAndAnyValueWithinOneDoes() {
        let calendar = Self.calendar()
        let fridayEvening = Self.date(2026, 10, 9, hour: 19)
        XCTAssertTrue(Grammar.Condition(dayparts: [.evening, .night], weekdays: [.fri])
            .matches(fridayEvening, calendar: calendar))
        XCTAssertFalse(Grammar.Condition(dayparts: [.morning], weekdays: [.fri])
            .matches(fridayEvening, calendar: calendar), "the daypart facet fails")
        XCTAssertFalse(Grammar.Condition(weekdays: [.sat, .sun])
            .matches(fridayEvening, calendar: calendar))
        XCTAssertTrue(Grammar.Condition(months: [9, 10]).matches(fridayEvening, calendar: calendar))
        XCTAssertFalse(Grammar.Condition(months: [12]).matches(fridayEvening, calendar: calendar))
        XCTAssertTrue(Grammar.Condition().matches(fridayEvening, calendar: calendar),
                      "no facet stated is always")

        XCTAssertEqual(Grammar.Daypart.of(hour: 4), .night)
        XCTAssertEqual(Grammar.Daypart.of(hour: 5), .morning)
        XCTAssertEqual(Grammar.Daypart.of(hour: 12), .afternoon)
        XCTAssertEqual(Grammar.Daypart.of(hour: 17), .evening)
        XCTAssertEqual(Grammar.Daypart.of(hour: 23), .night)

        let lines: [Grammar.Line] = [
            .init(text: "Weekend at last", when: .init(weekdays: [.sat, .sun])),
            .init(text: "Friday night", when: .init(dayparts: [.evening], weekdays: [.fri]))
        ]
        XCTAssertEqual(Grammar.eligible(lines, at: Self.context(fridayEvening)).map(\.text), ["Friday night"])
    }

    // MARK: - Selection

    func testThePickIsWeightedAndDeterministicForASeed() throws {
        let light = Grammar.Line(text: "Light")
        let heavy = Grammar.Line(text: "Heavy", weight: 3)
        let lines = [light, heavy]
        let context = Self.context()

        var generator = SeededGenerator(state: 2026)
        let draws = 4_000
        var heavyCount = 0
        for _ in 0..<draws {
            if try XCTUnwrap(Grammar.pick(lines, at: context, using: &generator)) == heavy { heavyCount += 1 }
        }
        let share = Double(heavyCount) / Double(draws)
        XCTAssertEqual(share, 0.75, accuracy: 0.03, "weight 3 against weight 1 is three picks in four")

        var first = SeededGenerator(state: 7)
        var second = SeededGenerator(state: 7)
        let a = (0..<20).map { _ in Grammar.pick(lines, at: context, using: &first)?.text }
        let b = (0..<20).map { _ in Grammar.pick(lines, at: context, using: &second)?.text }
        XCTAssertEqual(a, b, "the same seed picks the same lines")

        XCTAssertNil(Grammar.pick([.init(text: "In {project}")], at: context, using: &generator),
                     "nothing eligible picks nothing")
        XCTAssertEqual(Grammar.pick([.init(text: "Only", weight: 0)], at: context, using: &generator)?.text,
                       "Only", "a weight below the floor still counts once rather than never")
    }

    func testASharedPoolGivesTheHostLineOneShareOfTheDraw() throws {
        let lines = [Grammar.Line(text: "Theme", weight: 3)]
        let context = Self.context()
        var generator = SeededGenerator(state: 11)
        let draws = 4_000
        var hostCount = 0
        for _ in 0..<draws where Grammar.pickSharing(
            lines, includesHostLine: true, at: context, using: &generator
        ) == nil {
            hostCount += 1
        }
        XCTAssertEqual(Double(hostCount) / Double(draws), 0.25, accuracy: 0.03,
                       "the host's line is one more candidate of weight 1 beside weight 3")
        for _ in 0..<50 {
            XCTAssertNotNil(Grammar.pickSharing(lines, includesHostLine: false, at: context, using: &generator))
        }
        XCTAssertNil(Grammar.pickSharing([.init(text: "{project}")], includesHostLine: false,
                                         at: context, using: &generator),
                     "with nothing eligible the host's line stands")
    }

    // MARK: - Stored form

    /// The Mac stores lines inside a theme document and sends them to the phone; both read the
    /// one Codable here, so the bytes are pinned rather than only the round trip.
    func testALineWritesOnlyWhatIsNotDefault() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plain = try String(decoding: encoder.encode(Grammar.Line(text: "Hi")), as: UTF8.self)
        XCTAssertEqual(plain, #"{"text":"Hi"}"#)
        let full = Grammar.Line(text: "Wake up, {user}…", when: .init(
            dayparts: [.night, .evening], hours: .init(from: 22, to: 4), weekdays: [.sun, .fri],
            dates: [.init(from: Self.day("12-24"), to: Self.day("12-26")),
                    .init(from: Self.day("01-01"), to: Self.day("01-01"))],
            months: [12, 1]
        ), weight: 3)
        XCTAssertEqual(
            try String(decoding: encoder.encode(full), as: UTF8.self),
            #"{"text":"Wake up, {user}…","weight":3,"when":{"dates":[{"from":"12-24","to":"12-26"},"#
                + #"{"from":"01-01"}],"dayparts":["evening","night"],"hours":{"from":22,"to":4},"#
                + #""months":[1,12],"weekdays":["fri","sun"]}}"#,
            "sets are written in a fixed order and a one-day span names only its first day"
        )
        XCTAssertEqual(try JSONDecoder().decode(Grammar.Line.self, from: encoder.encode(full)), full)
        XCTAssertEqual(
            try JSONDecoder().decode(Grammar.Line.self, from: Data(#"{"text":"x","when":{}}"#.utf8)),
            Grammar.Line(text: "x", when: Grammar.Condition()),
            "an empty condition reads, and is not written back"
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            Grammar.Line.self, from: Data(#"{"text":"x","when":{"dates":[{"from":"13-01"}]}}"#.utf8)
        ), "an impossible day is not a date")
        XCTAssertThrowsError(try JSONDecoder().decode(
            Grammar.Line.self, from: Data(#"{"text":"x","when":{"dayparts":["dusk"]}}"#.utf8)
        ), "a daypart this build does not know is not read as another")
    }
}
