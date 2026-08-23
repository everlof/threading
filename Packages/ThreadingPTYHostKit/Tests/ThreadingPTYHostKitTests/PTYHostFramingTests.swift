import XCTest
@testable import ThreadingPTYHostKit

/// A `SOCK_STREAM` unix socket has no message boundaries, so every test here is about a read
/// boundary landing somewhere inconvenient. The decoder is driven with bytes, never with frames.
final class PTYHostFramingTests: XCTestCase {

    private func bytes(_ string: String) -> Data { Data(string.utf8) }

    private func frames(_ outcome: PTYHostFrameDecoder.Outcome, file: StaticString = #filePath, line: UInt = #line) throws -> [PTYHostWireFrame] {
        switch outcome {
        case .frames(let frames): return frames
        case .refused(let refusal): XCTFail("refused: \(refusal)", file: file, line: line); return []
        }
    }

    // MARK: - Header

    func testTheHeaderIsEightLittleEndianBytesFollowedByThePayload() throws {
        let encoded = try PTYHostFraming.encode(kind: .output, payload: bytes("hi"))
        XCTAssertEqual(encoded.count, PTYHostFramingDefaults.headerBytes + 2)
        XCTAssertEqual([UInt8](encoded), [0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x68, 0x69])
    }

    /// The reserved pair is written as zero and ignored on the way in, so a later build can give
    /// it a meaning without every earlier build refusing the frame.
    func testANonZeroReservedFieldIsIgnoredRatherThanRefused() throws {
        var encoded = [UInt8](try PTYHostFraming.encode(kind: .control, payload: bytes("{}")))
        encoded[2] = 0xAB
        encoded[3] = 0xCD
        var decoder = PTYHostFrameDecoder()
        let decoded = try frames(decoder.accept(Data(encoded)))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].payload, bytes("{}"))
    }

    /// `flags` travels untouched: bit 0 is reserved for the compression tag, and turning that on
    /// later must be a change in one consumer rather than a change to the header.
    func testFlagsSurviveTheRoundTripUninterpreted() throws {
        let encoded = try PTYHostFraming.encode(
            kind: .output,
            flags: PTYHostFramingDefaults.compressionFlag,
            payload: bytes("x")
        )
        var decoder = PTYHostFrameDecoder()
        let decoded = try frames(decoder.accept(encoded))
        XCTAssertEqual(decoded.first?.flags, 0x01)
    }

    // MARK: - Reassembly

    func testAFrameSplitAcrossThreeReadsReassembles() throws {
        let payload = bytes("the quick brown fox")
        let encoded = try PTYHostFraming.encode(kind: .control, payload: payload)
        var decoder = PTYHostFrameDecoder()

        // A cut inside the header, then a cut inside the payload.
        XCTAssertEqual(try frames(decoder.accept(encoded.prefix(3))), [])
        XCTAssertEqual(try frames(decoder.accept(encoded.dropFirst(3).prefix(9))), [])
        let done = try frames(decoder.accept(encoded.dropFirst(12)))
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].kind, .control)
        XCTAssertEqual(done[0].payload, payload)
        XCTAssertEqual(decoder.bufferedBytes, 0)
    }

    func testTwoFramesArrivingInOneReadBothDecodeInOrder() throws {
        var stream = Data()
        stream.append(try PTYHostFraming.encode(kind: .control, payload: bytes("first")))
        stream.append(try PTYHostFraming.encode(kind: .input, payload: bytes("second")))

        var decoder = PTYHostFrameDecoder()
        let decoded = try frames(decoder.accept(stream))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].kind, .control)
        XCTAssertEqual(decoded[0].payload, bytes("first"))
        XCTAssertEqual(decoded[1].kind, .input)
        XCTAssertEqual(decoded[1].payload, bytes("second"))
    }

    /// The read boundary a stream socket is most likely to produce: a whole frame plus the head
    /// of the next one.
    func testAWholeFrameFollowedByHalfOfTheNextDeliversOnlyTheFirst() throws {
        let first = try PTYHostFraming.encode(kind: .output, payload: bytes("aaaa"))
        let second = try PTYHostFraming.encode(kind: .output, payload: bytes("bbbb"))

        var decoder = PTYHostFrameDecoder()
        var stream = first
        stream.append(second.prefix(5))
        let decoded = try frames(decoder.accept(stream))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].payload, bytes("aaaa"))
        XCTAssertEqual(decoder.bufferedBytes, 5)

        let rest = try frames(decoder.accept(second.dropFirst(5)))
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest[0].payload, bytes("bbbb"))
    }

    func testAByteAtATimeStillReassembles() throws {
        let encoded = try PTYHostFraming.encode(kind: .control, payload: bytes("drip"))
        var decoder = PTYHostFrameDecoder()
        var delivered: [PTYHostWireFrame] = []
        for byte in encoded {
            delivered += try frames(decoder.accept(Data([byte])))
        }
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].payload, bytes("drip"))
    }

    func testAnEmptyPayloadIsAFrameRatherThanNothing() throws {
        let encoded = try PTYHostFraming.encode(kind: .control, payload: Data())
        var decoder = PTYHostFrameDecoder()
        let decoded = try frames(decoder.accept(encoded))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].payload, Data())
    }

    func testAnEmptyReadIsNotAnEventAtAll() throws {
        var decoder = PTYHostFrameDecoder()
        XCTAssertEqual(try frames(decoder.accept(Data())), [])
        XCTAssertFalse(decoder.isRefused)
    }

    func testArbitraryBytesSurviveFramingUnchanged() throws {
        let raw = Data([0x00, 0xFF, 0x1B, 0x5B, 0x32, 0x4A, 0x00, 0xC3])
        let encoded = try PTYHostFraming.encode(kind: .output, payload: raw)
        var decoder = PTYHostFrameDecoder()
        XCTAssertEqual(try frames(decoder.accept(encoded)).first?.payload, raw)
    }

    // MARK: - Refusals

    /// Refused from the header alone. A cap on what is delivered is not a cap on what is read,
    /// so the payload must never be buffered: the decoder holds nothing afterwards.
    func testAnOversizeLengthIsRefusedFromTheHeaderWithoutBufferingThePayload() {
        var header = Data([PTYHostFrameKind.output.rawValue, 0, 0, 0])
        let length = UInt32(PTYHostFramingDefaults.maximumPayloadBytes + 1)
        header.append(contentsOf: [
            UInt8(truncatingIfNeeded: length),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 24)
        ])

        var decoder = PTYHostFrameDecoder()
        XCTAssertEqual(decoder.accept(header), .refused(.oversizePayload(length: length)))
        XCTAssertEqual(decoder.bufferedBytes, 0)
        XCTAssertTrue(decoder.isRefused)
    }

    /// Exactly at the bound is accepted; the refusal is for what is past it.
    func testAPayloadOfExactlyTheMaximumIsAccepted() throws {
        var decoder = PTYHostFrameDecoder(maximumPayloadBytes: 16)
        let encoded = try PTYHostFraming.encode(kind: .output, payload: Data(repeating: 0x41, count: 16))
        XCTAssertEqual(try frames(decoder.accept(encoded)).first?.payload.count, 16)
    }

    func testAnUnknownKindIsRefused() {
        var decoder = PTYHostFrameDecoder()
        let header = Data([0x09, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(decoder.accept(header), .refused(.unknownKind(0x09)))
    }

    /// There is no resynchronisation point in a length-prefixed stream, so a refusal is
    /// terminal: the caller closes the connection and every later read says the same thing.
    func testARefusalIsTerminalAndRepeatsItself() throws {
        var decoder = PTYHostFrameDecoder()
        XCTAssertEqual(decoder.accept(Data([0x09, 0, 0, 0, 0, 0, 0, 0])), .refused(.unknownKind(0x09)))
        let good = try PTYHostFraming.encode(kind: .control, payload: bytes("{}"))
        XCTAssertEqual(decoder.accept(good), .refused(.unknownKind(0x09)))
    }

    /// A valid frame that arrived in the same read as a poisoned one is dropped with it: the
    /// caller is closing, and half a read is an invitation to act on it.
    func testFramesAheadOfARefusalInTheSameReadAreNotDelivered() throws {
        var stream = try PTYHostFraming.encode(kind: .control, payload: bytes("good"))
        stream.append(Data([0x09, 0, 0, 0, 0, 0, 0, 0]))
        var decoder = PTYHostFrameDecoder()
        XCTAssertEqual(decoder.accept(stream), .refused(.unknownKind(0x09)))
    }

    /// The length check is stated before the kind check, because a 2 GiB length with a valid
    /// kind is precisely the frame that must never be buffered.
    func testAnOversizeLengthIsRefusedEvenWhenTheKindIsAlsoUnknown() {
        var header = Data([0x09, 0, 0, 0])
        header.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x7F])
        var decoder = PTYHostFrameDecoder()
        XCTAssertEqual(decoder.accept(header), .refused(.oversizePayload(length: 0x7FFF_FFFF)))
    }

    /// Oversize is refused on the way out too, and typed the same way: the alternatives are a
    /// silently truncated stream or a daemon a large repaint can kill.
    func testEncodingRefusesAnOversizePayloadRatherThanTruncatingOrTrapping() {
        let payload = Data(repeating: 0x41, count: PTYHostFramingDefaults.maximumPayloadBytes + 1)
        XCTAssertThrowsError(try PTYHostFraming.encode(kind: .output, payload: payload)) { error in
            XCTAssertEqual(
                error as? PTYHostFramingRefusal,
                .oversizePayload(length: UInt32(PTYHostFramingDefaults.maximumPayloadBytes + 1))
            )
        }
    }

    /// The buffer is compacted once per read rather than once per frame, and it must end a read
    /// holding only what is genuinely unfinished — otherwise a long-lived connection accumulates
    /// every byte it ever received.
    func testManyFramesInOneReadLeaveNothingBuffered() throws {
        var stream = Data()
        for index in 0..<64 {
            stream.append(try PTYHostFraming.encode(kind: .output, payload: bytes("frame-\(index)")))
        }
        var decoder = PTYHostFrameDecoder()
        let decoded = try frames(decoder.accept(stream))
        XCTAssertEqual(decoded.count, 64)
        XCTAssertEqual(decoded.last?.payload, bytes("frame-63"))
        XCTAssertEqual(decoder.bufferedBytes, 0)
    }

    func testEveryKindByteRoundTrips() throws {
        for kind in PTYHostFrameKind.allCases {
            let encoded = try PTYHostFraming.encode(kind: kind, payload: bytes("x"))
            var decoder = PTYHostFrameDecoder()
            XCTAssertEqual(try frames(decoder.accept(encoded)).first?.kind, kind)
        }
    }
}
