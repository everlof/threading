import SwiftUI
import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// The identity picker's value rules. The system menu it replaces folded every login's reading
/// into its title and drew every runtime with the same sparkle; what a row leads with, what it
/// says beneath its name, and which model it is ringed for are pinned here.
final class MobileIdentityPickerTests: XCTestCase {

    func testHostPresentationPreservesHiddenLabelsAndSurfaceOverrides() throws {
        let chooser = RemoteSessionAccountDTO(name: "Research", glyph: "DV", isEmoji: false,
            hue: nil, backgroundHex: "#F4C95D", foregroundHex: "#000000",
            badgeHidden: false, displayLabel: "")
        let usage = RemoteSessionAccountDTO(name: "Research", glyph: "🦊", isEmoji: true,
            hue: nil, badgeHidden: false, displayLabel: "R&D")
        let account = RemoteAccountChoiceDTO(id: "work", name: "Research",
            presentation: chooser, appearances: ["usage": usage], models: [], defaultModelID: nil)
        XCTAssertEqual(account.visibleName, "")
        XCTAssertEqual(account.appearance(in: .usage), usage)
        XCTAssertEqual(account.appearance(in: .details), chooser)
        XCTAssertEqual(try JSONDecoder().decode(RemoteAccountChoiceDTO.self,
            from: JSONEncoder().encode(account)), account)
    }

    // MARK: - What a login's disc shows

    func testAnEmojiLeadsTheDiscBeforeAnyInitial() {
        XCTAssertEqual(
            MobileAccountGlyph.resolve(emoji: "🧪", email: "vera@example.com", name: "Vera"),
            .emoji("🧪")
        )
    }

    func testAJoinedEmojiIsKeptWholeAndStrayWhitespaceIsNot() {
        XCTAssertEqual(
            MobileAccountGlyph.resolve(emoji: " 👩‍💻", email: nil, name: "Vera"),
            .emoji("👩‍💻")
        )
    }

    /// The Mac's `AccountBadge.initial(for:)` order: the address first, because one person keeps
    /// one address across the agents they are logged into while a derived name can differ.
    func testTheInitialComesFromTheAddressBeforeTheName() {
        XCTAssertEqual(
            MobileAccountGlyph.resolve(emoji: nil, email: "everlof@gmail.com", name: "David"),
            .initial("E")
        )
        XCTAssertEqual(
            MobileAccountGlyph.resolve(emoji: nil, email: nil, name: "david"),
            .initial("D")
        )
        XCTAssertEqual(
            MobileAccountGlyph.resolve(emoji: nil, email: "", name: "  vera keller"),
            .initial("V")
        )
    }

    func testALoginWithNothingToInitialFallsToAMarkRatherThanAnEmptyDisc() {
        XCTAssertEqual(
            MobileAccountGlyph.resolve(emoji: "", email: nil, name: "   "),
            .symbol(MobileAccountGlyph.fallbackSymbol)
        )
        XCTAssertEqual(
            MobileAccountGlyph.resolve(emoji: nil, email: "@", name: "—"),
            .symbol(MobileAccountGlyph.fallbackSymbol)
        )
    }

    // MARK: - What it says beneath the name

    /// The rings are drawn from the reading scoped to the draft's model; the words under the
    /// name are that same reading, not the catalogue's account-wide line.
    func testTheWordsUnderANameAreTheReadingItsRingsStandFor() {
        let account = Fixture.account(id: "a", usageSummary: "5h 31% · 7d 56% · 7d Fable 82%")
        let reading = MobileAccountUsageReading(rings: [], summary: "5h 31% · 7d 56%")

        XCTAssertEqual(
            MobileAccountUsageWords.resolve(account: account, reading: reading),
            .reading("5h 31% · 7d 56%")
        )
    }

    func testAHostWithoutWindowsStillSaysItsAccountWideSummary() {
        let account = Fixture.account(id: "a", usageSummary: "5h 31% · 7d 56%")

        XCTAssertEqual(
            MobileAccountUsageWords.resolve(account: account, reading: nil),
            .reading("5h 31% · 7d 56%")
        )
    }

    func testAFailedReadingSaysSoAndAPendingOneSaysThat() {
        XCTAssertEqual(
            MobileAccountUsageWords.resolve(
                account: Fixture.account(id: "a", usageError: "offline"),
                reading: nil
            ),
            .unavailable
        )
        XCTAssertEqual(
            MobileAccountUsageWords.resolve(account: Fixture.account(id: "a"), reading: nil),
            .loading
        )
        XCTAssertEqual(
            MobileAccountUsageWords.unavailable.text,
            MobileL10n.string("Usage unavailable")
        )
        XCTAssertEqual(MobileAccountUsageWords.loading.text, MobileL10n.string("Loading usage…"))
    }

    // MARK: - Which model a row is ringed for

    /// The checked row wears the rings the toolbar disc wears — the draft's model, Fable's own
    /// window inside the account's — while every other login is ringed for its own default,
    /// which is what a switch to it would actually spend.
    func testTheChosenLoginIsRingedForTheDraftsModelAndTheOthersForTheirOwnDefault() {
        let now = Date()
        let chosen = Fixture.account(id: "default", windows: Fixture.windows(now: now))
        let other = Fixture.account(id: "keller", windows: Fixture.windows(now: now))

        let chosenReading = MobileIdentityPickerReading.resolve(
            account: chosen,
            selectedAccountID: "default",
            draftModelID: "claude-fable-5",
            now: now
        )
        let otherReading = MobileIdentityPickerReading.resolve(
            account: other,
            selectedAccountID: "default",
            draftModelID: "claude-fable-5",
            now: now
        )

        XCTAssertEqual(chosenReading?.rings.map(\.id), ["7d", "5h", "fable"])
        XCTAssertEqual(otherReading?.rings.map(\.id), ["7d", "5h"])
        XCTAssertEqual(
            chosenReading,
            MobileAccountUsageReading.resolve(account: chosen, model: "claude-fable-5", now: now),
            "the checked row and the disc that opened the picker are one reading"
        )
    }

    // MARK: - The runtime strip

    /// Two runtimes are two halves of the plate, not two fifths and a gap; once the strip wraps,
    /// every row holds five and the last is padded so no tile widens.
    func testASingleRowSharesThePlateAndAWrappedStripPadsItsLastRow() {
        XCTAssertEqual(MobileIdentityPickerStrip.rows([1, 2], tilesPerRow: 5), [[1, 2]])
        XCTAssertEqual(
            MobileIdentityPickerStrip.rows([1, 2, 3, 4, 5], tilesPerRow: 5),
            [[1, 2, 3, 4, 5]]
        )
        XCTAssertEqual(
            MobileIdentityPickerStrip.rows([1, 2, 3, 4, 5, 6, 7], tilesPerRow: 5),
            [[1, 2, 3, 4, 5], [6, 7, nil, nil, nil]]
        )
        XCTAssertTrue(MobileIdentityPickerStrip.rows([Int](), tilesPerRow: 5).isEmpty)
        XCTAssertTrue(MobileIdentityPickerStrip.rows([1], tilesPerRow: 0).isEmpty)
    }

    // MARK: - Every point in the surface belongs to an item

    /// The complaint the arithmetic exists for: with a button per tile, the target was each
    /// tile's own drawn frame, so the group's margin and the gaps between plates swallowed
    /// touches that plainly pointed at a runtime. Dividing the surface leaves no dead point in
    /// it — this sweeps the whole strip at two-point steps and expects every one of them to land
    /// on a runtime.
    func testNoPointInsideAFullStripFallsBetweenTiles() {
        let size = CGSize(width: 324, height: 68)
        var missed: [CGPoint] = []
        for x in stride(from: CGFloat(0), to: size.width, by: 2) {
            for y in stride(from: CGFloat(0), to: size.height, by: 2) {
                let point = CGPoint(x: x, y: y)
                if MobileIdentityPickerHitTest.tile(
                    at: point, in: size, tilesPerRow: 5, count: 5
                ) == nil {
                    missed.append(point)
                }
            }
        }
        XCTAssertEqual(missed, [], "every point inside the strip belongs to a runtime")
    }

    func testTheFirstAndLastColumnsReachTheirOwnEdges() {
        let size = CGSize(width: 300, height: 68)
        XCTAssertEqual(
            MobileIdentityPickerHitTest.tile(
                at: CGPoint(x: 0, y: 0), in: size, tilesPerRow: 5, count: 5
            ),
            0
        )
        XCTAssertEqual(
            MobileIdentityPickerHitTest.tile(
                at: CGPoint(x: 299.5, y: 67.5), in: size, tilesPerRow: 5, count: 5
            ),
            4
        )
        // The seam between two tiles belongs to the one on its trailing side, and never to
        // neither.
        XCTAssertEqual(
            MobileIdentityPickerHitTest.tile(
                at: CGPoint(x: 60, y: 34), in: size, tilesPerRow: 5, count: 5
            ),
            1
        )
    }

    func testASecondRowIsAddressedByItsOwnBand() {
        let size = CGSize(width: 300, height: 136)
        XCTAssertEqual(
            MobileIdentityPickerHitTest.tile(
                at: CGPoint(x: 30, y: 10), in: size, tilesPerRow: 5, count: 7
            ),
            0
        )
        XCTAssertEqual(
            MobileIdentityPickerHitTest.tile(
                at: CGPoint(x: 30, y: 100), in: size, tilesPerRow: 5, count: 7
            ),
            5
        )
        // A wrapped strip's last row is padded with blanks. A finger there is on nothing rather
        // than on the runtime that happens to be first.
        XCTAssertNil(
            MobileIdentityPickerHitTest.tile(
                at: CGPoint(x: 250, y: 100), in: size, tilesPerRow: 5, count: 7
            )
        )
    }

    /// Outside is nil rather than the nearest edge, so a drag that wanders off the surface holds
    /// the item it last crossed instead of snapping the choice somewhere the finger has left.
    func testAPointOutsideTheSurfaceBelongsToNothing() {
        let size = CGSize(width: 300, height: 68)
        for point in [
            CGPoint(x: -1, y: 10),
            CGPoint(x: 10, y: -1),
            CGPoint(x: 300, y: 10),
            CGPoint(x: 10, y: 68),
        ] {
            XCTAssertNil(
                MobileIdentityPickerHitTest.tile(
                    at: point, in: size, tilesPerRow: 5, count: 5
                ),
                "\(point) is outside the strip"
            )
        }
        XCTAssertNil(
            MobileIdentityPickerHitTest.tile(
                at: CGPoint(x: 10, y: 10), in: .zero, tilesPerRow: 5, count: 5
            )
        )
        XCTAssertNil(
            MobileIdentityPickerHitTest.tile(
                at: CGPoint(x: 10, y: 10), in: size, tilesPerRow: 0, count: 5
            )
        )
    }

    func testALoginRowOwnsItsOwnBandAndNothingBelowTheLast() {
        XCTAssertEqual(MobileIdentityPickerHitTest.row(at: 0, rowHeight: 56, count: 3), 0)
        XCTAssertEqual(MobileIdentityPickerHitTest.row(at: 55.9, rowHeight: 56, count: 3), 0)
        XCTAssertEqual(MobileIdentityPickerHitTest.row(at: 56, rowHeight: 56, count: 3), 1)
        XCTAssertEqual(MobileIdentityPickerHitTest.row(at: 167.9, rowHeight: 56, count: 3), 2)
        XCTAssertNil(MobileIdentityPickerHitTest.row(at: 168, rowHeight: 56, count: 3))
        XCTAssertNil(MobileIdentityPickerHitTest.row(at: -1, rowHeight: 56, count: 3))
        XCTAssertNil(MobileIdentityPickerHitTest.row(at: 10, rowHeight: 0, count: 3))
        XCTAssertNil(MobileIdentityPickerHitTest.row(at: 10, rowHeight: 56, count: 0))
    }

    func testEveryPointAcrossALoginCellBelongsToItsRow() {
        let size = CGSize(width: 324, height: 168)
        var missed: [CGPoint] = []
        for x in stride(from: CGFloat(0), to: size.width, by: 2) {
            for y in stride(from: CGFloat(0), to: size.height, by: 2) {
                let point = CGPoint(x: x, y: y)
                if MobileIdentityPickerHitTest.row(
                    at: point,
                    in: size,
                    rowHeight: 56,
                    count: 3
                ) == nil {
                    missed.append(point)
                }
            }
        }
        XCTAssertEqual(missed, [], "the blank width around row content remains tappable")
    }

    func testALoginPointOutsideTheSurfaceBelongsToNothing() {
        let size = CGSize(width: 324, height: 168)
        for point in [
            CGPoint(x: -1, y: 28),
            CGPoint(x: 324, y: 28),
            CGPoint(x: 162, y: -1),
            CGPoint(x: 162, y: 168),
        ] {
            XCTAssertNil(
                MobileIdentityPickerHitTest.row(
                    at: point,
                    in: size,
                    rowHeight: 56,
                    count: 3
                )
            )
        }
    }

    /// A drag that crosses the strip visits every runtime in order, which is what makes the
    /// selection tick at each crossing rather than jumping.
    func testADragAcrossTheStripVisitsEveryRuntimeInOrder() {
        let size = CGSize(width: 300, height: 68)
        var visited: [Int] = []
        for x in stride(from: CGFloat(0), to: size.width, by: 1) {
            guard let index = MobileIdentityPickerHitTest.tile(
                at: CGPoint(x: x, y: 34), in: size, tilesPerRow: 5, count: 5
            ) else { continue }
            if visited.last != index { visited.append(index) }
        }
        XCTAssertEqual(visited, [0, 1, 2, 3, 4])
    }

    // MARK: - When a login comes back, and where its clock stands

    /// The row's bar and reset are the longest window's — the outermost ring — written as the
    /// moment and the wait. The five-hour window is left to its ring.
    func testTheRowStatesTheLongestWindowsResetAsAMomentAndAWait() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reading = MobileAccountUsageReading.resolve(
            account: Fixture.account(id: "a", windows: [
                Fixture.window("5h", fraction: 0.07, resetsIn: 2 * 3600, now: now),
                Fixture.window("7d", fraction: 0.38, resetsIn: 3 * 86400 + 4 * 3600, now: now),
            ]),
            model: nil,
            now: now
        )
        let clock = MobileIdentityPickerClock.resolve(reading, now: now)
        let resetsAt = now.addingTimeInterval(3 * 86400 + 4 * 3600)

        XCTAssertEqual(clock.window?.name, "7d")
        XCTAssertEqual(clock.reset, .at(resetsAt))
        XCTAssertEqual(
            clock.resetText(at: now),
            resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()) + " · 3d 4h"
        )
        XCTAssertEqual(reading?.summary, "5h 7% · 7d 38%", "the written reading is unchanged")
    }

    /// The moment is as short as the wait beside it leaves unambiguous: the time today, the
    /// weekday for the rest of the week — even a week out, where the weekday is today's — and the
    /// date alone beyond it. A dated `29 Oct at 03:06` crowded the login's name to `Sond…`.
    func testTheMomentIsAsShortAsTheWaitLeavesUnambiguous() throws {
        let noon = try XCTUnwrap(
            Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())
        )
        let today = noon.addingTimeInterval(2 * 3600)
        let weekOut = noon.addingTimeInterval(6 * 86400 + 19 * 3600)
        let later = noon.addingTimeInterval(9 * 86400)

        XCTAssertEqual(
            MobileIdentityPickerClock.moment(today, now: noon),
            today.formatted(.dateTime.hour().minute())
        )
        XCTAssertEqual(
            MobileIdentityPickerClock.moment(weekOut, now: noon),
            weekOut.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        )
        XCTAssertEqual(
            MobileIdentityPickerClock.moment(later, now: noon),
            later.formatted(.dateTime.month(.abbreviated).day())
        )
    }

    /// A five-hour window fuller than the week does not take the row over: it refills on its
    /// own, and its ring already says how full it is.
    func testAFullerShortWindowLeavesTheRowOnTheWeek() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reading = MobileAccountUsageReading.resolve(
            account: Fixture.account(id: "a", windows: [
                Fixture.window("5h", fraction: 0.8, resetsIn: 2 * 3600, now: now),
                Fixture.window("7d", fraction: 0.38, resetsIn: 86400, now: now),
            ]),
            model: nil,
            now: now
        )
        let clock = MobileIdentityPickerClock.resolve(reading, now: now)

        XCTAssertEqual(clock.window?.name, "7d")
        XCTAssertEqual(clock.reset, .at(now.addingTimeInterval(86400)))
    }

    /// A spent window, whichever it is, is when the login comes back: the row turns to it —
    /// its bar and its reset — and to the last of them when more than one is spent.
    func testASpentWindowTakesTheRowUntilItComesBack() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reading = MobileAccountUsageReading.resolve(
            account: Fixture.account(id: "a", windows: [
                Fixture.window("5h", fraction: 0.97, resetsIn: 2 * 3600 + 14 * 60, now: now),
                Fixture.window("7d", fraction: 0.4, resetsIn: 3 * 86400, now: now),
            ]),
            model: nil,
            now: now
        )
        let clock = MobileIdentityPickerClock.resolve(reading, now: now)
        let back = now.addingTimeInterval(2 * 3600 + 14 * 60)

        XCTAssertEqual(clock.window?.name, "5h", "the bar and the reset describe one window")
        XCTAssertEqual(clock.reset, .out(until: back))
        XCTAssertEqual(
            clock.resetText(at: now),
            MobileIdentityPickerClock.moment(back, now: now) + " · 2h 14m"
        )
        XCTAssertEqual(
            clock.spokenReset(at: now),
            MobileL10n.string("Out until %@", MobileProjectDefaultAccounts.resetTime(back, now: now)),
            "VoiceOver hears no tint, so it is told the login is out"
        )

        let both = MobileAccountUsageReading.resolve(
            account: Fixture.account(id: "b", windows: [
                Fixture.window("5h", fraction: 0.97, resetsIn: 3600, now: now),
                Fixture.window("7d", fraction: 1, resetsIn: 3 * 86400, now: now),
            ]),
            model: nil,
            now: now
        )
        let last = MobileIdentityPickerClock.resolve(both, now: now)
        XCTAssertEqual(last.window?.name, "7d")
        XCTAssertEqual(last.reset, .out(until: now.addingTimeInterval(3 * 86400)))

        let unsaid = MobileAccountUsageReading.resolve(
            account: Fixture.account(id: "c", windows: [
                .init(id: "5h", name: "5h", fraction: 1, windowDuration: 5 * 3600),
            ]),
            model: nil,
            now: now
        )
        let out = MobileIdentityPickerClock.resolve(unsaid, now: now)
        XCTAssertEqual(out.reset, .out(until: nil))
        XCTAssertEqual(out.resetText(at: now), MobileL10n.string("Out of usage"))
    }

    /// Past its reset a window's number describes the window before it: its value is `—`, the
    /// clock is not placed on it, it states no reset, and a full one is not out.
    func testAnExpiredWindowNeitherTicksNorResets() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reading = try XCTUnwrap(MobileAccountUsageReading.resolve(
            account: Fixture.account(id: "a", windows: [
                Fixture.window("7d", fraction: 0.97, resetsIn: -60, now: now),
            ]),
            model: nil,
            now: now
        ))
        let week = try XCTUnwrap(reading.windows.first)
        let clock = MobileIdentityPickerClock.resolve(reading, now: now)

        XCTAssertNil(week.fraction)
        XCTAssertEqual(week.value, MobileUsageDefaults.unknownValue)
        XCTAssertNil(week.elapsedFraction(at: now))
        XCTAssertEqual(clock.window?.name, "7d")
        XCTAssertNil(clock.reset)
        XCTAssertNil(clock.resetText(at: now))
    }

    /// The tick is how much of the window's length has gone by: a five-hour window two hours
    /// from its reset is three fifths through.
    func testTheClockTickIsHowFarThroughTheWindowTheClockStands() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reading = try XCTUnwrap(MobileAccountUsageReading.resolve(
            account: Fixture.account(id: "a", windows: [
                Fixture.window("5h", fraction: 0.07, resetsIn: 2 * 3600, now: now),
            ]),
            model: nil,
            now: now
        ))
        let elapsed = try XCTUnwrap(reading.windows.first?.elapsedFraction(at: now))

        XCTAssertEqual(elapsed, 0.6, accuracy: 0.0001)
    }

    /// The clock lives outside the reading, so a reading is one value while time passes — the
    /// chat menu's gauge caches its picture on that equality.
    func testTheReadingDoesNotChangeAsTheClockMoves() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let account = Fixture.account(id: "a", windows: [
            Fixture.window("5h", fraction: 0.07, resetsIn: 2 * 3600, now: now),
        ])

        XCTAssertEqual(
            MobileAccountUsageReading.resolve(account: account, model: nil, now: now),
            MobileAccountUsageReading.resolve(account: account, model: nil, now: now.addingTimeInterval(600))
        )
    }

    /// A model's own window is the disc's innermost ring, not the row's bar, even when it is the
    /// fullest: the bar is the account's, so it compares down the list.
    func testAScopedWindowStaysOnTheDisc() {
        let now = Date()
        let fable = MobileIdentityPickerReading.resolve(
            account: Fixture.account(id: "default", windows: Fixture.windows(now: now)),
            selectedAccountID: "default",
            draftModelID: "claude-fable-5",
            now: now
        )

        XCTAssertEqual(fable?.windows.map(\.name), ["5h", "7d", "7d Fable"])
        XCTAssertEqual(MobileIdentityPickerClock.resolve(fable, now: now).window?.name, "7d")
    }

    /// A host that sends no windows, or a login still being read, keeps its words and states no
    /// reset.
    func testALoginWithoutWindowsKeepsItsWords() {
        let words = MobileAccountUsageReading(rings: [], summary: "5h 31% · 7d 56%")

        XCTAssertEqual(
            MobileIdentityPickerClock.resolve(words, now: Date()),
            MobileIdentityPickerClock(window: nil, reset: nil)
        )
        XCTAssertEqual(
            MobileIdentityPickerClock.resolve(nil, now: Date()),
            MobileIdentityPickerClock(window: nil, reset: nil)
        )
    }

    func testTheSpokenValueAddsWhenTheLoginComesBack() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let account = Fixture.account(id: "a", windows: [
            Fixture.window("7d", fraction: 0.38, resetsIn: 2 * 86400, now: now),
        ])
        let reading = try XCTUnwrap(MobileAccountUsageReading.resolve(account: account, model: nil, now: now))
        let words = MobileAccountUsageWords.resolve(account: account, reading: reading)
        let clock = MobileIdentityPickerClock.resolve(reading, now: now)

        let spoken = words.spoken(with: clock, at: now)
        XCTAssertEqual(spoken, "7d 38% · " + (clock.spokenReset(at: now) ?? ""))
        XCTAssertNotNil(clock.spokenReset(at: now))
        XCTAssertEqual(words.spoken(with: .resolve(nil, now: now), at: now), "7d 38%")
    }

    // MARK: - Rendered state

    /// The picker as it ships, light and dark, over the logins a real Mac reports: a login whose
    /// week has passed its reset, two with both windows, two with only the week — and, in the
    /// second pair of pictures, a chosen login on a model with a window of its own and a login
    /// that is out. The pictures land in `THREADING_RENDER_OUT` when it names a folder.
    @MainActor
    func testRendersTheLoginRowsWithTheirClocksAndCountdowns() throws {
        let now = Date()
        let logins: [RemoteAccountChoiceDTO] = [
            Fixture.account(id: "rinda01", windows: [
                Fixture.window("7d", fraction: 0.91, resetsIn: -3600, now: now),
            ]),
            Fixture.account(id: "rinda02", windows: [
                Fixture.window("5h", fraction: 0.07, resetsIn: 2 * 3600 + 41 * 60, now: now),
                Fixture.window("7d", fraction: 0.38, resetsIn: 4 * 86400 + 2 * 3600, now: now),
            ]),
            Fixture.account(id: "rinda03", windows: [
                Fixture.window("7d", fraction: 0.48, resetsIn: 86400 + 3 * 3600, now: now),
            ]),
            Fixture.account(id: "sonda01", windows: [
                Fixture.window("7d", fraction: 0.01, resetsIn: 6 * 86400 + 20 * 3600, now: now),
            ]),
            Fixture.account(id: "sonda02", windows: [
                Fixture.window("5h", fraction: 0.6, resetsIn: -60, now: now),
                Fixture.window("7d", fraction: 0.79, resetsIn: 2 * 86400 + 6 * 3600, now: now),
            ]),
        ]
        let out = Fixture.account(id: "rinda04", windows: [
            Fixture.window("5h", fraction: 0.97, resetsIn: 2 * 3600 + 14 * 60, now: now),
            Fixture.window("7d", fraction: 0.62, resetsIn: 5 * 86400, now: now),
        ])
        // Five, not six: a sixth login scrolls, and `ImageRenderer` draws no scroll view's content.
        let scoped = [Fixture.account(id: "default", windows: Fixture.windows(now: now)), out]
            + logins.dropFirst(2)

        for (name, dto) in [("light", RemoteAppModel.demoLightTheme), ("dark", RemoteAppModel.demoTheme)] {
            let palette = RemoteThemePalette(dto)
            for (variant, accounts, selected) in [
                ("windows", logins, "rinda02"),
                ("scoped", scoped, "default"),
            ] {
                let picker = MobileIdentityPicker(
                    agents: [
                        RemoteAgentChoiceDTO(
                            id: "claude", name: "Claude Code", accounts: accounts, models: [],
                            defaultModelID: nil, supportsConversation: true
                        ),
                        RemoteAgentChoiceDTO(
                            id: "codex", name: "Codex", accounts: [], models: [],
                            defaultModelID: nil, supportsConversation: true
                        ),
                    ],
                    selectedAgentID: "claude",
                    accounts: accounts,
                    selectedAccountID: selected,
                    draftModelID: "claude-fable-5",
                    onChooseAgent: { _ in },
                    onChooseAccount: { _ in }
                )
                .background(palette.floatingSurface)
                .mobileTheme(palette)
                let renderer = ImageRenderer(content: picker)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage, "\(name) \(variant)")
                try save(image, named: "identity-picker-\(variant)-\(name)")
            }
        }
    }

    private func save(_ image: UIImage, named name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
              !folder.isEmpty else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - Fixture

    private enum Fixture {
        static func account(
            id: String,
            usageSummary: String? = nil,
            usageError: String? = nil,
            windows: [RemoteAccountUsageWindowDTO]? = nil
        ) -> RemoteAccountChoiceDTO {
            RemoteAccountChoiceDTO(
                id: id,
                name: id.capitalized,
                email: nil,
                emoji: nil,
                usageSummary: usageSummary,
                usageFraction: nil,
                usageError: usageError,
                usageWindows: windows,
                models: [],
                defaultModelID: "claude-opus-5"
            )
        }

        static func window(
            _ name: String,
            fraction: Double,
            resetsIn seconds: TimeInterval,
            now: Date
        ) -> RemoteAccountUsageWindowDTO {
            let durations: [String: TimeInterval] = ["5h": 5 * 3600, "7d": 7 * 86400]
            return RemoteAccountUsageWindowDTO(
                id: name,
                name: name,
                fraction: fraction,
                resetsAt: now.timeIntervalSince1970 + seconds,
                windowDuration: durations[name]
            )
        }

        static func windows(now: Date) -> [RemoteAccountUsageWindowDTO] {
            let reset = now.timeIntervalSince1970 + 3600
            return [
                .init(id: "5h", name: "5h", fraction: 0.31, resetsAt: reset, windowDuration: 5 * 3600),
                .init(id: "7d", name: "7d", fraction: 0.56, resetsAt: reset, windowDuration: 7 * 86400),
                .init(
                    id: "fable",
                    name: "7d Fable",
                    fraction: 0.82,
                    resetsAt: reset,
                    windowDuration: 7 * 86400,
                    metersModelIDs: ["claude-fable-5"]
                ),
            ]
        }
    }
}
