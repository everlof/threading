import ThreadingRemoteKit
import XCTest
@testable import Threading

/// The five reasons a viewport request can be refused, which the wire used to compress into one
/// word. A support report could say a viewport was rejected and nothing else, so the phone and
/// the journal both had to guess whether the grid was wrong or the connection was routed nowhere.
final class RemoteViewportRefusalTests: XCTestCase {

    private let routed = UUID().uuidString

    func testAnAcceptedRequestCarriesTheParsedSessionAndGrid() {
        let request = RemoteAccessServer.viewportRequest(
            cols: 80,
            rows: 24,
            routedSessionID: routed
        )

        XCTAssertEqual(
            request,
            .accepted(cols: 80, rows: 24, sessionID: SessionID(uuidString: routed)!)
        )
    }

    func testEachClauseNamesItself() {
        XCTAssertEqual(
            RemoteAccessServer.viewportRequest(cols: nil, rows: 24, routedSessionID: routed),
            .refused(.missingSize)
        )
        XCTAssertEqual(
            RemoteAccessServer.viewportRequest(cols: 80, rows: nil, routedSessionID: routed),
            .refused(.missingSize)
        )
        XCTAssertEqual(
            RemoteAccessServer.viewportRequest(cols: 80, rows: 24, routedSessionID: nil),
            .refused(.unroutedConnection)
        )
        XCTAssertEqual(
            RemoteAccessServer.viewportRequest(cols: 80, rows: 24, routedSessionID: "not-a-uuid"),
            .refused(.malformedSessionID)
        )
        XCTAssertEqual(
            RemoteAccessServer.viewportRequest(cols: 19, rows: 24, routedSessionID: routed),
            .refused(.columnsOutOfRange)
        )
        XCTAssertEqual(
            RemoteAccessServer.viewportRequest(cols: 241, rows: 24, routedSessionID: routed),
            .refused(.columnsOutOfRange)
        )
        XCTAssertEqual(
            RemoteAccessServer.viewportRequest(cols: 80, rows: 3, routedSessionID: routed),
            .refused(.rowsOutOfRange)
        )
        XCTAssertEqual(
            RemoteAccessServer.viewportRequest(cols: 80, rows: 161, routedSessionID: routed),
            .refused(.rowsOutOfRange)
        )
    }

    /// The accepted range is published once. The browser client clamps against the same numbers,
    /// so a bound stated twice would eventually be two different bounds.
    func testTheEdgesOfThePublishedRangeAreAccepted() {
        for (cols, rows) in [(20, 4), (240, 160)] {
            XCTAssertEqual(
                RemoteAccessServer.viewportRequest(
                    cols: cols,
                    rows: rows,
                    routedSessionID: routed
                ),
                .accepted(cols: cols, rows: rows, sessionID: SessionID(uuidString: routed)!)
            )
        }
        XCTAssertEqual(RemoteViewportRefusal.columns, 20...240)
        XCTAssertEqual(RemoteViewportRefusal.rows, 4...160)
    }

    /// An older host omits the field entirely, and the client must still read the code.
    func testTheRefusalTravelsBesideTheCodeAndStaysOptional() throws {
        let encoded = try JSONEncoder().encode(
            RemoteErrorDTO(code: "invalidViewport", detail: RemoteViewportRefusal.rowsOutOfRange.rawValue)
        )
        let decoded = try JSONDecoder().decode(RemoteErrorDTO.self, from: encoded)
        XCTAssertEqual(decoded.code, "invalidViewport")
        XCTAssertEqual(decoded.detail, "rowsOutOfRange")

        let legacy = try JSONDecoder().decode(
            RemoteErrorDTO.self,
            from: Data(#"{"type":"error","code":"invalidViewport"}"#.utf8)
        )
        XCTAssertNil(legacy.detail)
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(RemoteErrorDTO(code: "forbidden")), as: UTF8.self)
                .contains("detail"),
            "A refusal with nothing to add must not put a null on the wire."
        )
    }
}
