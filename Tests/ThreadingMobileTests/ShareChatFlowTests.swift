import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// Share Chat is one sheet with two stages. These hold the transition between them without
/// standing a sheet up, which is the whole reason the stage lives in a model rather than in
/// `@State` beside a presentation binding.
@MainActor
final class ShareChatFlowTests: XCTestCase {
    private let chatTitle = "Remote access review"

    // MARK: - Fixtures

    private func makeFlow(
        isChatRunning: Bool = true,
        mint: @escaping ShareChatFlow.Mint
    ) -> ShareChatFlow {
        ShareChatFlow(chatTitle: chatTitle, isChatRunning: isChatRunning, mint: mint)
    }

    private func link(for role: ShareChatRole) -> SharedSessionLink {
        SharedSessionLink(
            sessionTitle: chatTitle,
            url: URL(string: "https://192.168.1.181:8760/#invitation")!,
            capability: role.capability.rawValue,
            canApprovePermissions: role.canApprovePermissions,
            expiresAt: Date(timeIntervalSince1970: 2_000_000)
        )
    }

    // MARK: - The stage transition

    /// The chooser used to dismiss itself and present a second sheet. Choosing a role now moves
    /// the same flow to the stage that hands the invitation over.
    func testChoosingARoleMovesTheSameFlowToTheLinkStage() async {
        let flow = makeFlow { self.link(for: $0) }
        XCTAssertTrue(flow.stage.isChoosingRole)

        await flow.choose(.collaborate)

        XCTAssertFalse(flow.stage.isChoosingRole)
        XCTAssertEqual(flow.stage.link?.capability, RemoteCapability.interact.rawValue)
        XCTAssertEqual(flow.stage.link?.sessionTitle, chatTitle)
    }

    /// Each of the three grants has to arrive at the mint as itself. Approval in particular is a
    /// separate right carried beside the capability, not a third capability.
    func testEachGrantMintsTheCapabilityAndApprovalScopeItNames() async {
        var asked: [ShareChatRole] = []
        let expected: [(ShareChatRole, RemoteCapability, Bool)] = [
            (.view, .view, false),
            (.collaborate, .interact, false),
            (.collaborateAndApprove, .interact, true),
        ]

        for (role, capability, approves) in expected {
            let flow = makeFlow { chosen in
                asked.append(chosen)
                return self.link(for: chosen)
            }

            await flow.choose(role)

            XCTAssertEqual(flow.stage.link?.capability, capability.rawValue, "\(role)")
            XCTAssertEqual(flow.stage.link?.canApprovePermissions, approves, "\(role)")
        }

        XCTAssertEqual(asked, expected.map(\.0))
    }

    /// A second tap while the first request is in flight would mint a second invitation to the
    /// same chat, and the person would hand out whichever one they happened to be looking at.
    ///
    /// The second tap is made from inside the first request rather than from a second task, so
    /// "while it is in flight" is a fact of the test rather than a race it hopes to win.
    func testASecondChoiceIsRefusedWhileOneIsInFlight() async {
        var mints = 0
        var pending: ShareChatFlow?
        let flow = makeFlow { role in
            mints += 1
            XCTAssertEqual(pending?.isMinting, true)
            XCTAssertEqual(pending?.isEnabled(.view), false)
            await pending?.choose(.view)
            return self.link(for: role)
        }
        pending = flow

        await flow.choose(.collaborate)

        XCTAssertEqual(mints, 1)
        XCTAssertEqual(flow.stage.link?.capability, RemoteCapability.interact.rawValue)
    }

    /// Once the link exists the chooser is gone, so a stale tap arriving from it cannot replace
    /// the invitation the reader is already holding.
    func testChoosingAgainFromTheLinkStageChangesNothing() async {
        let flow = makeFlow { self.link(for: $0) }
        await flow.choose(.collaborateAndApprove)

        await flow.choose(.view)

        XCTAssertEqual(flow.stage.link?.capability, RemoteCapability.interact.rawValue)
        XCTAssertTrue(flow.stage.link?.canApprovePermissions == true)
    }

    // MARK: - Failure

    /// A refused mint leaves the reader on the stage they were on, with the reason on the sheet
    /// that asked rather than on the dashboard behind it.
    func testAFailedMintStaysOnTheChooserAndSaysWhy() async {
        struct Refused: LocalizedError {
            var errorDescription: String? { "The Mac refused the request" }
        }
        let flow = makeFlow { _ in throw Refused() }

        await flow.choose(.collaborate)

        XCTAssertTrue(flow.stage.isChoosingRole)
        XCTAssertEqual(flow.errorMessage, "The Mac refused the request")
        XCTAssertFalse(flow.isMinting)
    }

    /// A cancelled request is not a failure to report: it is the sheet going away.
    func testACancelledMintReportsNothing() async {
        let flow = makeFlow { _ in throw CancellationError() }

        await flow.choose(.collaborate)

        XCTAssertTrue(flow.stage.isChoosingRole)
        XCTAssertNil(flow.errorMessage)
    }

    // MARK: - The blocked chat

    /// A chat that has never run has nothing to watch, and a viewer cannot wake it. That is the
    /// one grant a dormant chat cannot offer; the other two start it.
    func testADormantChatOffersEverythingButTheViewOnlyGrant() {
        let flow = makeFlow(isChatRunning: false) { self.link(for: $0) }

        XCTAssertFalse(flow.isEnabled(.view))
        XCTAssertTrue(flow.isEnabled(.collaborate))
        XCTAssertTrue(flow.isEnabled(.collaborateAndApprove))
    }

    /// The dimmed row is explained rather than left to be guessed at, and a running chat says
    /// nothing extra.
    func testOnlyADormantChatCarriesTheNotice() {
        XCTAssertEqual(
            makeFlow(isChatRunning: false) { self.link(for: $0) }.blockedNotice,
            ShareChatRole.unavailableUntilRunning
        )
        XCTAssertNil(makeFlow { self.link(for: $0) }.blockedNotice)
    }

    /// Dimming a row has to mean the tap does nothing, not merely that it looks quiet.
    func testTheBlockedGrantCannotBeMintedByTappingItAnyway() async {
        var mints = 0
        let flow = makeFlow(isChatRunning: false) { role in
            mints += 1
            return self.link(for: role)
        }

        await flow.choose(.view)

        XCTAssertEqual(mints, 0)
        XCTAssertTrue(flow.stage.isChoosingRole)
    }

    // MARK: - The words

    /// Every sentence the chooser sets is a catalog key with a Swedish translation behind it.
    /// The role titles and their one-line descriptions cross the boundary as `String`s, which is
    /// the shape that silently ships English inside a Swedish app when a key is missing.
    func testTheChoosersSentencesAreTranslatedRatherThanEnglishSourceText() throws {
        let swedish = try XCTUnwrap(Bundle.main.path(forResource: "sv", ofType: "lproj").map {
            Bundle(path: $0)
        } ?? nil)

        var keys = ["Choose what this person can do.", "Start the chat first to share it view-only."]
        for role in ShareChatRole.allCases {
            keys.append(contentsOf: [role.title, role.detail])
        }

        for key in keys {
            XCTAssertNotEqual(
                swedish.localizedString(forKey: key, value: key, table: "Localizable"),
                key,
                "missing Swedish for: \(key)"
            )
        }
    }

    /// Three grants, each with its own glyph, its own name and its own line. Two rows wearing
    /// the same mark or saying the same thing is a chooser that cannot be chosen from.
    func testEachGrantIsToldApartByItsMarkItsNameAndItsLine() {
        XCTAssertEqual(Set(ShareChatRole.allCases.map(\.systemImage)).count, 3)
        XCTAssertEqual(Set(ShareChatRole.allCases.map(\.title)).count, 3)
        XCTAssertEqual(Set(ShareChatRole.allCases.map(\.detail)).count, 3)
    }
}
