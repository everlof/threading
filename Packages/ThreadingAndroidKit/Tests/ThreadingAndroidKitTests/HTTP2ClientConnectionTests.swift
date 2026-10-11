import XCTest
@testable import ThreadingAndroidKit

final class HTTP2ClientConnectionTests: XCTestCase {
    private func frames(_ bytes: [UInt8]) throws -> [HTTP2Frame] {
        var reader = HTTP2FrameReader(maximumFrameSize: HTTP2Frame.largestMaximumFrameSize)
        reader.append(bytes)
        var result: [HTTP2Frame] = []
        while let frame = try reader.nextFrame() { result.append(frame) }
        return result
    }

    private func started() -> HTTP2ClientConnection {
        var connection = HTTP2ClientConnection()
        connection.start()
        _ = connection.takeOutput()
        return connection
    }

    func testStartSendsPrefaceSettingsAndTheEnlargedConnectionWindow() throws {
        var connection = HTTP2ClientConnection()
        connection.start()
        let output = connection.takeOutput()
        XCTAssertEqual(Array(output.prefix(24)), HTTP2ClientConnection.preface)
        let sent = try frames(Array(output.dropFirst(24)))
        XCTAssertEqual(sent.map(\.type), [.settings, .windowUpdate])
        XCTAssertEqual(sent[1].streamID, 0)
        XCTAssertEqual(BigEndian.uint32(sent[1].payload, at: 0), UInt32((16 << 20) - 65_535))
    }

    func testAcknowledgesServerSettingsAndPings() throws {
        var connection = started()
        let settings = HTTP2Frame(type: .settings, streamID: 0, payload: [0, 4, 0, 1, 0, 0]).encoded()
        let ping = HTTP2Frame(type: .ping, streamID: 0, payload: [1, 2, 3, 4, 5, 6, 7, 8]).encoded()
        XCTAssertEqual(try connection.receive(settings + ping), [])
        let replies = try frames(connection.takeOutput())
        XCTAssertEqual(replies.map(\.type), [.settings, .ping])
        XCTAssertTrue(replies[0].hasFlag(HTTP2Flag.ack))
        XCTAssertTrue(replies[1].hasFlag(HTTP2Flag.ack))
        XCTAssertEqual(replies[1].payload, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testAUnaryExchangeDeliversHeadersDataAndTrailersThenRetiresTheStream() throws {
        var connection = started()
        let stream = try connection.openStream(headers: [HTTP2Header(":method", "POST")], endStream: false)
        try connection.send(GRPCMessageDeframer.frame([0x08, 0x01]), on: stream, endStream: true)
        let request = try frames(connection.takeOutput())
        XCTAssertEqual(request.map(\.type), [.headers, .data])
        XCTAssertTrue(request[0].hasFlag(HTTP2Flag.endHeaders))
        XCTAssertTrue(request[1].hasFlag(HTTP2Flag.endStream))

        let head = HTTP2Frame(type: .headers, flags: HTTP2Flag.endHeaders, streamID: stream,
                              payload: HPACKEncoder.encode([HTTP2Header(":status", "200")])).encoded()
        let body = HTTP2Frame(type: .data, streamID: stream, payload: GRPCMessageDeframer.frame([0x0A, 0x00])).encoded()
        let trailers = HTTP2Frame(type: .headers, flags: HTTP2Flag.endHeaders | HTTP2Flag.endStream, streamID: stream,
                                  payload: HPACKEncoder.encode([HTTP2Header("grpc-status", "0")])).encoded()
        let events = try connection.receive(head + body + trailers)
        XCTAssertEqual(events.count, 3)
        guard case .data(_, let bytes, false) = events[1] else { return XCTFail("expected data") }
        XCTAssertEqual(bytes, [0, 0, 0, 0, 2, 0x0A, 0x00])
        XCTAssertEqual(connection.openStreamCount, 0)
        // The data frame's window is replenished at connection and stream level.
        let updates = try frames(connection.takeOutput()).filter { $0.type == .windowUpdate }
        XCTAssertEqual(Set(updates.map(\.streamID)), [0, stream])
    }

    func testHeldBodyWaitsForTheWindowThenFlushes() throws {
        var connection = started()
        // The server shrinks every stream's window to 4 bytes.
        _ = try connection.receive(HTTP2Frame(type: .settings, streamID: 0, payload: [0, 4, 0, 0, 0, 4]).encoded())
        _ = connection.takeOutput()
        let stream = try connection.openStream(headers: [HTTP2Header(":method", "POST")], endStream: false)
        try connection.send([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], on: stream, endStream: true)
        let first = try frames(connection.takeOutput()).filter { $0.type == .data }
        XCTAssertEqual(first.map(\.payload.count), [4])
        XCTAssertFalse(first[0].hasFlag(HTTP2Flag.endStream))

        let update = HTTP2Frame(type: .windowUpdate, streamID: stream, payload: BigEndian.bytes(UInt32(100))).encoded()
        _ = try connection.receive(update)
        let rest = try frames(connection.takeOutput()).filter { $0.type == .data }
        XCTAssertEqual(rest.map(\.payload), [[5, 6, 7, 8, 9, 10]])
        XCTAssertTrue(rest[0].hasFlag(HTTP2Flag.endStream))
    }

    func testReassemblesContinuationAndRefusesAnInterruptedBlock() throws {
        var connection = started()
        let stream = try connection.openStream(headers: [HTTP2Header(":method", "POST")], endStream: true)
        let block = HPACKEncoder.encode([HTTP2Header(":status", "200"), HTTP2Header("grpc-status", "0")])
        let head = HTTP2Frame(type: .headers, flags: HTTP2Flag.endStream, streamID: stream, payload: Array(block.prefix(2))).encoded()
        let tail = HTTP2Frame(type: .continuation, flags: HTTP2Flag.endHeaders, streamID: stream, payload: Array(block.dropFirst(2))).encoded()
        let events = try connection.receive(head + tail)
        XCTAssertEqual(events, [.headers(streamID: stream, headers: [
            HTTP2Header(":status", "200"), HTTP2Header("grpc-status", "0"),
        ], endStream: true)])

        var interrupted = started()
        let other = try interrupted.openStream(headers: [HTTP2Header(":method", "POST")], endStream: true)
        let partial = HTTP2Frame(type: .headers, streamID: other, payload: Array(block.prefix(2))).encoded()
        let ping = HTTP2Frame(type: .ping, streamID: 0, payload: Array(repeating: 0, count: 8)).encoded()
        XCTAssertThrowsError(try interrupted.receive(partial + ping))
    }

    func testGoAwayFailsTheStreamsTheServerNeverProcessed() throws {
        var connection = started()
        let first = try connection.openStream(headers: [HTTP2Header(":method", "POST")], endStream: true)
        let second = try connection.openStream(headers: [HTTP2Header(":method", "POST")], endStream: true)
        let goAway = HTTP2Frame(type: .goAway, streamID: 0, payload: BigEndian.bytes(first) + BigEndian.bytes(UInt32(0))).encoded()
        let events = try connection.receive(goAway)
        XCTAssertEqual(events, [.streamReset(streamID: second, errorCode: 0), .goAway(lastStreamID: first, errorCode: 0)])
        XCTAssertTrue(connection.isClosed)
        XCTAssertThrowsError(try connection.openStream(headers: [], endStream: true))
    }

    func testRefusesAFrameLargerThanAdvertisedBeforeBufferingIt() {
        var reader = HTTP2FrameReader(maximumFrameSize: 16_384)
        reader.append([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
        XCTAssertThrowsError(try reader.nextFrame()) { error in
            XCTAssertEqual(error as? HTTP2Error, .frameTooLarge(65_536))
        }
    }

    func testGRPCDeframerSplitsMessagesAcrossChunksAndBoundsThem() throws {
        var deframer = GRPCMessageDeframer(maximumMessageSize: 8)
        let framed = GRPCMessageDeframer.frame([1, 2, 3]) + GRPCMessageDeframer.frame([4])
        XCTAssertEqual(try deframer.append(Array(framed.prefix(6))), [])
        XCTAssertEqual(try deframer.append(Array(framed.dropFirst(6))), [[1, 2, 3], [4]])
        XCTAssertFalse(deframer.hasPartialMessage)
        XCTAssertThrowsError(try deframer.append(GRPCMessageDeframer.frame(Array(repeating: 0, count: 9))))
    }
}
