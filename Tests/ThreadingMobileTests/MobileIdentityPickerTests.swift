import SwiftUI
import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// The identity picker's value rules. The system menu it replaces folded every login's reading
/// into its title and drew every runtime with the same sparkle; what a row leads with, what it
/// says beneath its name, and which model it is ringed for are pinned here.
final class MobileIdentityPickerTests: XCTestCase {

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
