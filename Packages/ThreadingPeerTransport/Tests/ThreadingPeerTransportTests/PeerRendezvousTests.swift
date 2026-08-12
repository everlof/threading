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

    func testControlPlaneEndpointRequiresHTTPSOutsideLoopback() throws {
        XCTAssertEqual(
            try PeerControlPlaneServiceEndpoint(
                XCTUnwrap(URL(string: "https://REMOTE.Threading.Example/"))
            ).baseURL.absoluteString,
            "https://remote.threading.example"
        )
        XCTAssertNoThrow(try PeerControlPlaneServiceEndpoint(
            XCTUnwrap(URL(string: "http://127.0.0.1:8787"))
        ))
        for rejected in [
            "http://remote.threading.example",
            "https://user:password@remote.threading.example",
            "https://remote.threading.example/api",
            "https://remote.threading.example/?token=secret",
        ] {
            XCTAssertThrowsError(try PeerControlPlaneServiceEndpoint(
                XCTUnwrap(URL(string: rejected))
            ))
        }
    }

    func testControlPlaneBearerIsValidatedRedactedAndCodable() throws {
        let bearer = try PeerControlPlaneBearer("th_device_abc-123")
        XCTAssertEqual(bearer.description, "<redacted>")
        XCTAssertFalse(String(describing: bearer).contains("abc-123"))
        XCTAssertEqual(
            try JSONDecoder().decode(
                PeerControlPlaneBearer.self,
                from: JSONEncoder().encode(bearer)
            ),
            bearer
        )
        for rejected in ["", "contains space", "contains\nnewline"] {
            XCTAssertThrowsError(try PeerControlPlaneBearer(rejected))
        }
        XCTAssertThrowsError(try PeerControlPlaneBearer(
            String(repeating: "x", count: PeerControlPlaneBounds.maximumBearerBytes + 1)
        ))
    }
}
