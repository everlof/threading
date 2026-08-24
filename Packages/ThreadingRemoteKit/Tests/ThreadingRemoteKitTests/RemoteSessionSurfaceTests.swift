import XCTest
@testable import ThreadingRemoteKit

/// The surface used to be a bare string compared against literals in both apps. These tests hold
/// the two properties that made the type worth introducing without breaking the protocol: the wire
/// still carries the same words, and a word this build does not know still decodes.
final class RemoteSessionSurfaceTests: XCTestCase {

    func testTheWireStillCarriesThePlainWords() throws {
        XCTAssertEqual(RemoteSessionSurface.terminal.rawValue, "terminal")
        XCTAssertEqual(RemoteSessionSurface.conversation.rawValue, "conversation")

        let encoded = try JSONEncoder().encode(RemoteSessionSurface.conversation)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"conversation\"")
    }

    func testASessionSummaryDecodesTheSameJSONAsBefore() throws {
        let json = """
            {
              "id": "s",
              "title": "Session",
              "agentKind": "claude",
              "surface": "conversation",
              "state": "idle",
              "projectName": "Project"
            }
            """
        let summary = try JSONDecoder().decode(
            RemoteSessionSummaryDTO.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(summary.surface, .conversation)
        XCTAssertNotEqual(summary.surface, .terminal)
        XCTAssertEqual(summary.state, .idle)
    }

    func testSessionActivityUsesTypedKnownCasesWithoutChangingTheWire() throws {
        let known: [RemoteSessionActivity] = [
            .dormant, .idle, .working, .awaitingUser, .needsAttention, .limitReached,
        ]

        for state in known {
            let encoded = try JSONEncoder().encode(state)
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(state.rawValue)\"")
            XCTAssertEqual(
                try JSONDecoder().decode(RemoteSessionActivity.self, from: encoded),
                state
            )
            XCTAssertTrue(state.isKnown)
        }
    }

    func testAnUnknownSessionActivitySurvivesVersionSkew() throws {
        let encoded = Data(#""coordinating""#.utf8)
        let state = try JSONDecoder().decode(RemoteSessionActivity.self, from: encoded)

        XCTAssertEqual(state, .unknown("coordinating"))
        XCTAssertEqual(state.rawValue, "coordinating")
        XCTAssertFalse(state.isKnown)
        XCTAssertEqual(try JSONEncoder().encode(state), encoded)
    }

    /// A newer Mac may show something this build has never heard of. The row has to survive it:
    /// listing one unknown surface must not fail the whole payload, and re-encoding must not
    /// quietly rewrite it as a surface we do happen to know.
    func testAnUnknownSurfaceListsAndRoundTripsWithoutBecomingAKnownOne() throws {
        let json = """
            {
              "id": "s",
              "title": "Session",
              "agentKind": "claude",
              "surface": "notebook",
              "state": "idle",
              "projectName": "Project"
            }
            """
        let summary = try JSONDecoder().decode(
            RemoteSessionSummaryDTO.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(summary.surface.rawValue, "notebook")
        XCTAssertNotEqual(summary.surface, .terminal)
        XCTAssertNotEqual(summary.surface, .conversation)
        XCTAssertFalse(summary.surface.isKnown)

        let roundTrip = try JSONDecoder().decode(
            RemoteSessionSummaryDTO.self,
            from: JSONEncoder().encode(summary)
        )
        XCTAssertEqual(roundTrip.surface.rawValue, "notebook")
    }

    /// Leniency runs one way. A listing tolerates an unknown surface; a *launch* naming one is
    /// refused, which is what `RemoteAccessServer` gates its 400 on.
    func testOnlyTheSurfacesThisBuildCanHostAreKnown() {
        XCTAssertTrue(RemoteSessionSurface.terminal.isKnown)
        XCTAssertTrue(RemoteSessionSurface.conversation.isKnown)
        XCTAssertFalse(RemoteSessionSurface(rawValue: "notebook").isKnown)
        XCTAssertFalse(RemoteSessionSurface(rawValue: "").isKnown)
        XCTAssertEqual(RemoteSessionSurface.known, [.terminal, .conversation])
    }

    // MARK: - Account identity

    func testAnAccountChipRoundTripsItsGlyphAndHue() throws {
        let summary = RemoteSessionSummaryDTO(
            id: "s",
            title: "Session",
            agentKind: "claude",
            surface: .terminal,
            state: .idle,
            projectName: "Project",
            account: RemoteSessionAccountDTO(
                name: "Vera Keller",
                glyph: "V",
                isEmoji: false,
                hue: 0.72
            )
        )

        let roundTrip = try JSONDecoder().decode(
            RemoteSessionSummaryDTO.self,
            from: JSONEncoder().encode(summary)
        )
        XCTAssertEqual(roundTrip.account?.name, "Vera Keller")
        XCTAssertEqual(roundTrip.account?.glyph, "V")
        XCTAssertEqual(roundTrip.account?.isEmoji, false)
        XCTAssertEqual(roundTrip.account?.hue, 0.72)
    }

    /// Every host that predates the field, and every session on the CLI's default login, sends no
    /// account at all — the phone draws the provider's mark with no chip, as the Mac sidebar does.
    func testAHostWithoutTheAccountFieldStillDecodes() throws {
        let json = """
            {
              "id": "s",
              "title": "Session",
              "agentKind": "codex",
              "surface": "terminal",
              "state": "idle",
              "projectName": "Project"
            }
            """
        let summary = try JSONDecoder().decode(
            RemoteSessionSummaryDTO.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(summary.account)
    }
}
