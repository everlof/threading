import XCTest

@testable import ThreadingRemoteKit

/// Mirror frames share the events socket with a decoder every shipped phone already runs, so these
/// tests spell the bytes out: a renamed key would otherwise pass here and drop sockets in the field.
final class RemoteMirrorTests: XCTestCase {
    private let render = RemoteMirrorRenderDTO(
        sessionID: "6f1c2a8e-0000-4000-8000-000000000001",
        browserTabID: "6f1c2a8e-0000-4000-8000-000000000002",
        url: "http://localhost:5173/"
    )

    func testStateFrameKeepsItsWireShape() throws {
        let state = RemoteMirrorStateDTO(
            mirrorID: "m-1", mirrorRevision: 3, sourceTitle: "Festina",
            render: render, mode: .interactive, offerAgeMilliseconds: 1_200, rejoin: false
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "mirrorState")
        XCTAssertEqual(object["mirrorID"] as? String, "m-1")
        XCTAssertEqual(object["mirrorRevision"] as? Int, 3)
        XCTAssertEqual(object["mode"] as? String, "interactive")
        XCTAssertEqual(object["offerAgeMilliseconds"] as? Int, 1_200)
        XCTAssertEqual(object["rejoin"] as? Bool, false)
        let render = try XCTUnwrap(object["render"] as? [String: Any])
        XCTAssertEqual(render["kind"] as? String, "web")
        XCTAssertEqual(render["url"] as? String, "http://localhost:5173/")
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteMirrorStateDTO.self, from: JSONEncoder().encode(state)),
            state
        )
    }

    /// The phone's events envelope decodes `session`, `revision`, `streamID`, `sequence` and
    /// `terminal` with fixed shapes before it switches on `type`. A mirror frame using any of those
    /// names with another shape would make every shipped phone drop its socket.
    func testFramesNeverUseAKeyTheEventsEnvelopeDecodesWithAFixedShape() throws {
        let reserved: Set<String> = [
            "session", "revision", "streamID", "sequence", "terminal", "removedSessionID",
            "removedTerminalID",
        ]
        let frames: [Data] = [
            try JSONEncoder().encode(RemoteMirrorStateDTO(
                mirrorID: "m", mirrorRevision: 1, sourceTitle: "t", render: render,
                mode: .viewOnly, offerAgeMilliseconds: 0, rejoin: true
            )),
            try JSONEncoder().encode(RemoteMirrorEndedDTO(mirrorID: "m", reason: .stoppedOnMac)),
        ]
        for frame in frames {
            let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any]).keys
            XCTAssertTrue(reserved.isDisjoint(with: keys), "\(keys) collides with the events envelope")
        }
    }

    func testANewerMacsModeAndReasonStayReadable() throws {
        let json = #"""
        {"type":"mirrorEnded","mirrorID":"m","reason":"somethingNew"}
        """#
        let ended = try JSONDecoder().decode(RemoteMirrorEndedDTO.self, from: Data(json.utf8))
        XCTAssertEqual(ended.reason, .unknown("somethingNew"))
        XCTAssertEqual(RemoteMirrorMode(rawValue: "split"), .unknown("split"))
    }

    func testSignalsKeepTheirWireVocabulary() {
        XCTAssertEqual(
            RemoteMirrorSignal.allCases.map(\.rawValue),
            ["mirrorHello", "mirrorJoin", "mirrorHold", "mirrorPresence", "mirrorLeave"]
        )
        XCTAssertEqual(RemoteMirrorFrame.allCases.map(\.rawValue), ["mirrorState", "mirrorEnded"])
        XCTAssertEqual(RemoteMirrorHoldReason.allCases.map(\.rawValue), ["inUse", "disabled", "waiting"])
        XCTAssertEqual(RemoteRESTFeature.mirror.rawValue, "mirror")
    }

    func testTitlesAreBoundedOnACharacterBoundaryAndOneLine() {
        XCTAssertEqual(RemoteMirror.boundedTitle("Festina\nsecond line"), "Festina")
        let long = String(repeating: "å", count: 200)
        let bounded = RemoteMirror.boundedTitle(long)
        XCTAssertLessThanOrEqual(bounded.utf8.count, RemoteMirror.maximumTitleBytes)
        XCTAssertTrue(bounded.hasSuffix("…"))
    }
}
