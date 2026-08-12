import Foundation
import XCTest
@testable import ThreadingPeerTransport

final class PeerRendezvousTests: XCTestCase {
    func testReadyEnvelopeRoundTripsOnlyBoundedICEConfiguration() throws {
        let now = Date()
        let server = try PeerIceServer(
            urls: ["stun:stun.example.test:3478", "turns:turn.example.test:5349"],
            username: "temporary-user",
            credential: "temporary-password"
        )
        let envelope = try PeerRendezvousEnvelope(
            kind: .ready,
            sessionID: "session-1",
            expiresAt: now.addingTimeInterval(120),
            iceServers: [server],
            now: now
        )

        let encoded = try envelope.encoded()
        XCTAssertLessThan(encoded.count, PeerRendezvousBounds.maximumEnvelopeBytes)
        XCTAssertEqual(try PeerRendezvousEnvelope.decode(encoded), envelope)
    }

    func testEnvelopeRejectsExtraneousFieldsAndExpiredCredentials() throws {
        XCTAssertThrowsError(
            try PeerRendezvousEnvelope(
                kind: .hostHello,
                hostID: "host-1",
                deviceID: "unexpected"
            )
        ) { error in
            XCTAssertEqual(error as? PeerRendezvousError, .invalidEnvelope)
        }

        let now = Date()
        XCTAssertThrowsError(
            try PeerRendezvousEnvelope(
                kind: .ready,
                sessionID: "session-1",
                expiresAt: now.addingTimeInterval(-60),
                iceServers: [try PeerIceServer(urls: ["stun:stun.example.test:3478"])],
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? PeerRendezvousError, .invalidExpiry)
        }

        let unknownFieldJSON = """
        {"version":1,"kind":"hostHello","hostID":"host-1","unknown":true}
        """
        XCTAssertThrowsError(
            try PeerRendezvousEnvelope.decode(Data(unknownFieldJSON.utf8))
        ) { error in
            XCTAssertEqual(error as? PeerRendezvousError, .invalidEnvelope)
        }

        XCTAssertThrowsError(
            try PeerRendezvousEnvelope(kind: .hostHello, hostID: "host with spaces")
        ) { error in
            XCTAssertEqual(error as? PeerRendezvousError, .invalidEnvelope)
        }
    }

    func testDecodingCannotBypassDescriptionCandidateOrICEServerBounds() throws {
        let oversizedSDP = String(
            repeating: "s",
            count: PeerTransportBounds.maximumSessionDescriptionBytes + 1
        )
        let descriptionJSON = """
        {"kind":"offer","sdp":"\(oversizedSDP)"}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PeerSessionDescription.self,
                from: Data(descriptionJSON.utf8)
            )
        )

        let oversizedCandidate = String(
            repeating: "c",
            count: PeerIceCandidate.maximumSDPBytes + 1
        )
        let candidateJSON = """
        {"sdp":"\(oversizedCandidate)","sdpMLineIndex":0}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(PeerIceCandidate.self, from: Data(candidateJSON.utf8))
        )

        let iceJSON = """
        {"urls":["https://not-an-ice-server.example"]}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(PeerIceServer.self, from: Data(iceJSON.utf8))
        )
    }

    func testEnvelopeSizeIsCheckedBeforeJSONDecoding() {
        let oversized = Data(count: PeerRendezvousBounds.maximumEnvelopeBytes + 1)
        XCTAssertThrowsError(try PeerRendezvousEnvelope.decode(oversized)) { error in
            XCTAssertEqual(
                error as? PeerRendezvousError,
                .envelopeTooLarge(
                    actual: oversized.count,
                    limit: PeerRendezvousBounds.maximumEnvelopeBytes
                )
            )
        }
    }
}
