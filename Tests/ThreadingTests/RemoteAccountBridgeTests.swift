import AppKit
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// A phone row shows which login a chat runs on, and it has to be *the same* login the Mac sidebar
/// shows in the same colours. The Mac resolves the chip and sends it, so this is where the two
/// screens are held together: the glyph and the hue on the wire are the ones `AccountBadge` draws.
@MainActor
final class RemoteAccountBridgeTests: XCTestCase {

    private func account(
        handle: AccountHandle,
        emoji: String? = nil,
        displayName: String = "claude-ikeller"
    ) -> AgentAccount {
        AgentAccount(
            provider: .claude,
            handle: handle,
            configPath: "/tmp/threading-tests/\(handle.name)",
            displayName: displayName,
            emoji: emoji
        )
    }

    // MARK: - What the wire carries

    func testAChosenEmojiIsSentAsTheChipAndBringsItsOwnColour() throws {
        let identity = RemoteAccountBridge.identity(
            for: account(handle: AccountHandle(storedName: "claude-sandbox"), emoji: "🧪")
        )

        XCTAssertEqual(identity.glyph, "🧪")
        XCTAssertTrue(identity.isEmoji)
        XCTAssertNil(identity.hue, "an emoji chip draws no disc, so it needs no hue")
    }

    /// The initial and the disc's hue are `AccountBadge`'s own, not a second implementation. Two
    /// hash functions agreeing today is exactly the kind of thing that stops agreeing after an edit.
    func testAnInitialChipCarriesTheSameGlyphAndHueTheSidebarDraws() throws {
        let login = account(handle: AccountHandle(storedName: "claude-ikeller"))
        let identity = RemoteAccountBridge.identity(for: login)

        XCTAssertFalse(identity.isEmoji)
        XCTAssertEqual(identity.glyph, AccountBadge.initial(for: login))
        XCTAssertEqual(
            try XCTUnwrap(identity.hue),
            Double(AccountBadge.hue(for: login)),
            accuracy: 0.0001
        )
    }

    func testTheHueIsAFractionOfTheWheelAndStableForOneLogin() throws {
        let login = account(handle: AccountHandle(storedName: "claude-nhartley"))
        let hue = try XCTUnwrap(RemoteAccountBridge.identity(for: login).hue)

        XCTAssertGreaterThanOrEqual(hue, 0)
        XCTAssertLessThan(hue, 1)
        XCTAssertEqual(hue, try XCTUnwrap(RemoteAccountBridge.identity(for: login).hue))
    }

    /// Two logins that share an initial still differ by colour — the reason the disc is hashed at
    /// all. Without this a sidebar of `D`s says nothing more than a sidebar of blanks.
    func testTwoLoginsSharingAnInitialStillDifferByColour() throws {
        let first = account(handle: AccountHandle(storedName: "claude-nhartley"))
        let second = account(handle: AccountHandle(storedName: "claude-dahlberg"))

        XCTAssertNotEqual(
            try XCTUnwrap(RemoteAccountBridge.identity(for: first).hue),
            try XCTUnwrap(RemoteAccountBridge.identity(for: second).hue)
        )
    }

    // MARK: - Which rows get one

    /// The default login gets no chip on the Mac, because the agent's own mark already says
    /// everything the row knows. The phone follows that rule rather than inventing a second one —
    /// and answering nil before any account directory is scanned is also what keeps the projection
    /// cheap for the rows that are on the standard login, which is most of them.
    func testTheStandardLoginSendsNoAccountAtAll() {
        XCTAssertNil(RemoteAccountBridge.identity(for: session(handle: .standard)))
    }

    /// A runtime with no account routing has nothing to say either, and asking would log the
    /// absence of a feature once per row per reconfigure.
    func testARuntimeWithoutAccountRoutingSendsNoAccount() {
        for kind in AgentKind.allCases where !kind.supportsAccounts {
            XCTAssertNil(
                RemoteAccountBridge.identity(for: session(
                    kind: kind,
                    handle: AccountHandle(storedName: "\(kind.rawValue)-alternate")
                )),
                "\(kind.displayName) does not route accounts, so a chip would be invented"
            )
        }
    }

    // MARK: - Helpers

    private func session(
        kind: AgentKind = .claude,
        handle: AccountHandle
    ) -> AgentSession {
        AgentSession(kind: kind, title: "Session", accountHandle: handle)
    }
}
