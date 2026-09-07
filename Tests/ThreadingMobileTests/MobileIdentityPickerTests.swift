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
