import AppKit
@testable import Threading
import ThreadingExtensionKit
import XCTest

/// The welcome's model (`ThemeWelcome`): the token grammar, rendering against a fixed moment,
/// which lines are eligible, conditions at their edges, the weighted pick and the stored form.
///
/// Every clock is stated — a fixed date, a Gregorian calendar in a named zone and a named
/// locale — so nothing here depends on when or where the suite runs.
final class ThemeWelcomeTests: XCTestCase {

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
        waiting: Int = 0
    ) -> ThemeWelcome.Context {
        ThemeWelcome.Context(
            date: date,
            calendar: calendar(zone),
            locale: Locale(identifier: locale),
            project: project,
            user: user,
            working: working,
            waiting: waiting,
            daypartName: { "the \($0.rawValue)" }
        )
    }

    private static func day(_ wire: String) -> ThemeWelcome.MonthDay {
        ThemeWelcome.MonthDay(wireValue: wire)!
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
            + "{working} {waiting} {days_until:12-24} {fact:ci.status@2}"
        let tokens = try ThemeWelcome.Template.parse(line).compactMap { piece -> ThemeWelcome.Template.Token? in
            if case .token(let token) = piece { return token }
            return nil
        }
        XCTAssertEqual(tokens, [
            .time, .date, .weekday, .month, .day, .year, .daypart, .project, .user, .working,
            .waiting, .daysUntil(Self.day("12-24")), .fact(ExtensionFactKey(id: "ci.status", version: 2))
        ])
        XCTAssertEqual(ThemeWelcome.Template.Token.names.count, tokens.count)
        XCTAssertEqual(try ThemeWelcome.Template.parse("{ TIME }"), [.token(.time)],
                       "names are case- and space-tolerant")
    }

    func testAMalformedLineSaysWhatIsWrongWithIt() {
        typealias ParseError = ThemeWelcome.Template.ParseError
        func error(_ text: String) -> ParseError? {
            let outcome = Result { try ThemeWelcome.Template.parse(text) }
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

    func testDoubledBracesAreLiteralAndRenderAsOne() throws {
        XCTAssertEqual(
            try ThemeWelcome.Template.parse("{{literal}} {user}"),
            [.literal("{literal} "), .token(.user)]
        )
        XCTAssertEqual(ThemeWelcome.Template.render("{{literal}} {user}", context: Self.context()),
                       "{literal} Ada")
        XCTAssertEqual(ThemeWelcome.Template.render("}} and {{", context: Self.context()), "} and {")
        XCTAssertEqual(ThemeWelcome.Template.render("Plain words", context: Self.context()), "Plain words")
        XCTAssertNil(ThemeWelcome.Template.render("Broken {", context: Self.context()),
                     "a line that does not parse renders as nothing, never as its source")
    }

    func testOnlyTheWrittenMonthDayFormParses() {
        XCTAssertEqual(ThemeWelcome.MonthDay(wireValue: "12-24"), .init(month: 12, day: 24))
        XCTAssertEqual(ThemeWelcome.MonthDay(wireValue: "1-1"), .init(month: 1, day: 1))
        XCTAssertEqual(ThemeWelcome.MonthDay(wireValue: " 02-29 "), .init(month: 2, day: 29),
                       "a leap day is writable")
        for refused in ["02-30", "13-01", "00-10", "04-31", "-12-24", "12--24", "+1-1", "1224",
                        "12-24-1", "012-24", "ab-cd", ""] {
            XCTAssertNil(ThemeWelcome.MonthDay(wireValue: refused), refused)
        }
        XCTAssertEqual(ThemeWelcome.MonthDay(month: 3, day: 7).wireValue, "03-07")
    }

    func testOnlyTheClockTokensFollowTheClock() {
        XCTAssertTrue(ThemeWelcome.Template.followsClock("It is {time}"))
        XCTAssertTrue(ThemeWelcome.Template.followsClock("{days_until:12-24} sleeps"))
        XCTAssertFalse(ThemeWelcome.Template.followsClock("Hello {user} in {project}"))
        XCTAssertFalse(ThemeWelcome.Template.followsClock("No tokens {{here}}"))
        XCTAssertFalse(ThemeWelcome.Template.followsClock("Broken {time"))
    }

    // MARK: - Rendering

    func testTokensRenderFromAFixedMomentInTheStatedLocale() {
        let context = Self.context(project: "Threading", working: 3, waiting: 1)
        func render(_ text: String) -> String? { ThemeWelcome.Template.render(text, context: context) }

        XCTAssertEqual(render("{time}"), "14:05")
        XCTAssertEqual(render("{date}"), "5 October")
        XCTAssertEqual(render("{weekday}, {day} {month} {year}"), "Monday, 5 October 2026")
        XCTAssertEqual(render("Good {daypart}"), "Good the afternoon",
                       "the daypart word is the host's, supplied through the context")
        XCTAssertEqual(render("{user} in {project}"), "Ada in Threading")
        XCTAssertEqual(render("{working} working, {waiting} waiting"), "3 working, 1 waiting")

        let swedish = Self.context(locale: "sv_SE")
        XCTAssertEqual(ThemeWelcome.Template.render("{weekday}", context: swedish), "måndag")
    }

    func testTheClockIsReadInTheCalendarsZone() {
        // 23:30 UTC on the 5th is half past one on the 6th in Stockholm (CEST).
        let moment = Self.date(hour: 23, minute: 30)
        let stockholm = Self.context(moment, zone: "Europe/Stockholm")
        XCTAssertEqual(ThemeWelcome.Template.render("{time} {day}", context: stockholm), "01:30 6")
        XCTAssertEqual(ThemeWelcome.Template.render("{daypart}", context: stockholm), "the night")
    }

    func testDaysUntilCountsWholeDaysToTheNextOccurrence() {
        func days(_ target: String, from date: Date, zone: String = "UTC") -> String? {
            ThemeWelcome.Template.render("{days_until:\(target)}", context: Self.context(date, zone: zone))
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

    func testAProjectLineIsIneligibleWithoutAProject() {
        let wording = ThemeWelcome.Wording(lines: [
            .init(text: "Back to {project}?"),
            .init(text: "Hello, {user}")
        ])
        XCTAssertEqual(wording.eligible(at: Self.context()).map(\.text), ["Hello, Ada"])
        XCTAssertEqual(wording.eligible(at: Self.context(project: "")).map(\.text), ["Hello, Ada"])
        XCTAssertEqual(
            wording.eligible(at: Self.context(project: "Threading")).map(\.text),
            ["Back to Threading?", "Hello, Ada"]
        )
        XCTAssertEqual(wording.eligible(at: Self.context(user: nil)).map(\.text), [],
                       "a person with no given name makes {user} lines ineligible too")
    }

    func testOnlyTheFirstBoundedLinesAreConsidered() {
        let wording = ThemeWelcome.Wording(lines: (0..<(ThemeWelcomeLimits.maximumLines + 6)).map {
            .init(text: "Line \($0)")
        })
        XCTAssertEqual(wording.eligible(at: Self.context()).count, ThemeWelcomeLimits.maximumLines)
    }

    func testHourRangesWrapMidnight() {
        let night = ThemeWelcome.Hours(from: 22, to: 4)
        for hour in [22, 23, 0, 3, 4] { XCTAssertTrue(night.contains(hour), "\(hour)") }
        for hour in [5, 12, 21] { XCTAssertFalse(night.contains(hour), "\(hour)") }
        let office = ThemeWelcome.Hours(from: 9, to: 17)
        XCTAssertTrue(office.contains(9))
        XCTAssertTrue(office.contains(17), "the last hour is inclusive")
        XCTAssertFalse(office.contains(18))
        XCTAssertTrue(ThemeWelcome.Hours(from: 7, to: 7).contains(7))
        XCTAssertFalse(ThemeWelcome.Hours(from: 22, to: 24).isValid)

        let condition = ThemeWelcome.Condition(hours: night)
        XCTAssertTrue(condition.matches(Self.date(hour: 23, minute: 59), calendar: Self.calendar()))
        XCTAssertTrue(condition.matches(Self.date(hour: 0, minute: 0), calendar: Self.calendar()))
        XCTAssertFalse(condition.matches(Self.date(hour: 12, minute: 0), calendar: Self.calendar()))
    }

    func testDateSpansWrapTheYear() {
        let holidays = ThemeWelcome.DateSpan(from: Self.day("12-28"), to: Self.day("01-03"))
        for (month, day) in [(12, 28), (12, 31), (1, 1), (1, 3)] {
            XCTAssertTrue(holidays.contains(month: month, day: day), "\(month)-\(day)")
        }
        for (month, day) in [(12, 27), (1, 4), (6, 15)] {
            XCTAssertFalse(holidays.contains(month: month, day: day), "\(month)-\(day)")
        }
        let christmas = ThemeWelcome.DateSpan(from: Self.day("12-24"), to: Self.day("12-26"))
        XCTAssertTrue(christmas.contains(month: 12, day: 25))
        XCTAssertFalse(christmas.contains(month: 12, day: 27))

        let condition = ThemeWelcome.Condition(dates: [holidays])
        XCTAssertTrue(condition.matches(Self.date(2026, 12, 31), calendar: Self.calendar()))
        XCTAssertTrue(condition.matches(Self.date(2027, 1, 2), calendar: Self.calendar()))
        XCTAssertFalse(condition.matches(Self.date(2027, 1, 4), calendar: Self.calendar()))
    }

    func testEveryStatedFacetMustHoldAndAnyValueWithinOneDoes() {
        let calendar = Self.calendar()
        let fridayEvening = Self.date(2026, 10, 9, hour: 19)
        XCTAssertTrue(ThemeWelcome.Condition(dayparts: [.evening, .night], weekdays: [.fri])
            .matches(fridayEvening, calendar: calendar))
        XCTAssertFalse(ThemeWelcome.Condition(dayparts: [.morning], weekdays: [.fri])
            .matches(fridayEvening, calendar: calendar), "the daypart facet fails")
        XCTAssertFalse(ThemeWelcome.Condition(weekdays: [.sat, .sun])
            .matches(fridayEvening, calendar: calendar))
        XCTAssertTrue(ThemeWelcome.Condition(months: [9, 10]).matches(fridayEvening, calendar: calendar))
        XCTAssertFalse(ThemeWelcome.Condition(months: [12]).matches(fridayEvening, calendar: calendar))
        XCTAssertTrue(ThemeWelcome.Condition().matches(fridayEvening, calendar: calendar),
                      "no facet stated is always")

        XCTAssertEqual(ThemeWelcome.Daypart.of(hour: 4), .night)
        XCTAssertEqual(ThemeWelcome.Daypart.of(hour: 5), .morning)
        XCTAssertEqual(ThemeWelcome.Daypart.of(hour: 12), .afternoon)
        XCTAssertEqual(ThemeWelcome.Daypart.of(hour: 17), .evening)
        XCTAssertEqual(ThemeWelcome.Daypart.of(hour: 23), .night)

        let wording = ThemeWelcome.Wording(lines: [
            .init(text: "Weekend at last", when: .init(weekdays: [.sat, .sun])),
            .init(text: "Friday night", when: .init(dayparts: [.evening], weekdays: [.fri]))
        ])
        XCTAssertEqual(wording.eligible(at: Self.context(fridayEvening)).map(\.text), ["Friday night"])
    }

    // MARK: - Selection

    func testThePickIsWeightedAndDeterministicForASeed() throws {
        let light = ThemeWelcome.Line(text: "Light")
        let heavy = ThemeWelcome.Line(text: "Heavy", weight: 3)
        let wording = ThemeWelcome.Wording(lines: [light, heavy])
        let context = Self.context()

        var generator = SeededGenerator(state: 2026)
        let draws = 4_000
        var heavyCount = 0
        for _ in 0..<draws {
            if try XCTUnwrap(wording.pick(at: context, using: &generator)) == heavy { heavyCount += 1 }
        }
        let share = Double(heavyCount) / Double(draws)
        XCTAssertEqual(share, 0.75, accuracy: 0.03, "weight 3 against weight 1 is three picks in four")

        var first = SeededGenerator(state: 7)
        var second = SeededGenerator(state: 7)
        let a = (0..<20).map { _ in wording.pick(at: context, using: &first)?.text }
        let b = (0..<20).map { _ in wording.pick(at: context, using: &second)?.text }
        XCTAssertEqual(a, b, "the same seed picks the same lines")

        let ineligible = ThemeWelcome.Wording(lines: [.init(text: "In {project}")])
        XCTAssertNil(ineligible.pick(at: context, using: &generator), "nothing eligible picks nothing")

        let only = ThemeWelcome.Wording(lines: [.init(text: "Only", weight: 0)])
        XCTAssertEqual(only.pick(at: context, using: &generator)?.text, "Only",
                       "a weight below the floor still counts once rather than never")
    }

    // MARK: - Stored form

    func testAFullWelcomeRoundTripsAndOmitsWhatIsDefault() throws {
        let welcome = ThemeWelcome(
            backdrop: ThemeBackdrop(
                gradient: .init(stops: [
                    .init(color: try XCTUnwrap(NSColor(hex: "#000000")), position: 0),
                    .init(color: try XCTUnwrap(NSColor(hex: "#003300")), position: 1)
                ], angleDegrees: 160),
                image: .init(asset: "dark-welcome.png", mode: .fill, opacity: 0.3)
            ),
            mark: .mascot,
            markSize: 56,
            greeting: .init(
                lines: [
                    .init(text: "Wake up, {user}…", when: .init(
                        dayparts: [.night], hours: .init(from: 22, to: 4), weekdays: [.fri],
                        dates: [.init(from: Self.day("12-24"), to: Self.day("12-26"))], months: [12]
                    ), weight: 3),
                    .init(text: "Follow the white rabbit.")
                ],
                includesAppLines: true,
                style: .init(scale: 1.4, weight: .bold, ink: .role(.accent),
                             fontFamily: "Menlo", typeface: .monospaced)
            ),
            caption: .init(lines: [.init(text: "{days_until:12-24} days to go")],
                           style: .init(ink: .color(try XCTUnwrap(NSColor(hex: "#00FF00"))))),
            scrim: .init(hero: 0.4, prompt: 0.6)
        )
        let data = try JSONEncoder().encode(welcome)
        XCTAssertEqual(try JSONDecoder().decode(ThemeWelcome.self, from: data), welcome)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["markSize"] as? Double, 56, "storage is camelCase like the rest of the variant")
        let greeting = try XCTUnwrap(object["greeting"] as? [String: Any])
        XCTAssertEqual(greeting["includesAppLines"] as? Bool, true)
        let lines = try XCTUnwrap(greeting["lines"] as? [[String: Any]])
        XCTAssertEqual(lines[0]["weight"] as? Int, 3)
        XCTAssertNil(lines[1]["weight"], "the default weight is not written")
        XCTAssertNil(lines[1]["when"], "an unconditional line writes no condition")
        let when = try XCTUnwrap(lines[0]["when"] as? [String: Any])
        XCTAssertEqual((when["dates"] as? [[String: String]])?.first, ["from": "12-24", "to": "12-26"])
        let caption = try XCTUnwrap(object["caption"] as? [String: Any])
        XCTAssertNil(caption["includesAppLines"], "false is not written")

        let variant = try XCTUnwrap(AppThemeStyles.threading.variant(.dark)).replacingWelcome(welcome)
        let decoded = try JSONDecoder().decode(AppTheme.Variant.self, from: JSONEncoder().encode(variant))
        XCTAssertEqual(decoded.welcome, welcome)
        XCTAssertNil(try XCTUnwrap(AppThemeStyles.threading.variant(.dark)).welcome,
                     "no stock theme states a welcome")
    }

    func testAShapeThisBuildCannotReadDropsOnlyWhatItSpoils() throws {
        let variant = try XCTUnwrap(AppThemeStyles.threading.variant(.dark))
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(variant)) as? [String: Any]
        )
        document["welcome"] = [
            "mark": "hologram",
            "markSize": 48,
            "greeting": ["lines": "not a list"],
            "caption": ["lines": [["text": "Still here"]]],
            "scrim": ["hero": 0.3]
        ] as [String: Any]
        let decoded = try JSONDecoder().decode(
            AppTheme.Variant.self, from: JSONSerialization.data(withJSONObject: document)
        )
        let welcome = try XCTUnwrap(decoded.welcome)
        XCTAssertNil(welcome.mark, "a mark this build cannot draw is dropped")
        XCTAssertNil(welcome.greeting, "a greeting in a shape this build cannot read is dropped")
        XCTAssertEqual(welcome.markSize, 48)
        XCTAssertEqual(welcome.caption?.lines.map(\.text), ["Still here"])
        XCTAssertEqual(welcome.scrim, .init(hero: 0.3))
        XCTAssertEqual(decoded.material, variant.material, "the variant around it is kept")

        document["welcome"] = 42
        let unreadable = try JSONDecoder().decode(
            AppTheme.Variant.self, from: JSONSerialization.data(withJSONObject: document)
        )
        XCTAssertNil(unreadable.welcome)
        XCTAssertEqual(Set(unreadable.roles.keys), Set(variant.roles.keys))

        document["welcome"] = [String: Any]()
        let empty = try JSONDecoder().decode(
            AppTheme.Variant.self, from: JSONSerialization.data(withJSONObject: document)
        )
        XCTAssertNil(empty.welcome, "an empty block reads as none")
        XCTAssertNil(variant.replacingWelcome(ThemeWelcome()).welcome)
    }
}
