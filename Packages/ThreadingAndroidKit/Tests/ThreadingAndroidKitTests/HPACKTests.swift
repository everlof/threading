import XCTest
@testable import ThreadingAndroidKit

final class HPACKTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    /// RFC 7541 C.4: requests with Huffman coding, decoded by one decoder so the dynamic table
    /// carries across.
    func testDecodesRFCHuffmanRequestSequence() throws {
        var decoder = HPACKDecoder()
        XCTAssertEqual(try decoder.decode(bytes("828684418cf1e3c2e5f23a6ba0ab90f4ff")), [
            HTTP2Header(":method", "GET"), HTTP2Header(":scheme", "http"),
            HTTP2Header(":path", "/"), HTTP2Header(":authority", "www.example.com"),
        ])
        XCTAssertEqual(decoder.dynamicTableSizeForTesting, 57)
        XCTAssertEqual(try decoder.decode(bytes("828684be5886a8eb10649cbf")), [
            HTTP2Header(":method", "GET"), HTTP2Header(":scheme", "http"),
            HTTP2Header(":path", "/"), HTTP2Header(":authority", "www.example.com"),
            HTTP2Header("cache-control", "no-cache"),
        ])
        XCTAssertEqual(try decoder.decode(bytes("828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf")), [
            HTTP2Header(":method", "GET"), HTTP2Header(":scheme", "https"),
            HTTP2Header(":path", "/index.html"), HTTP2Header(":authority", "www.example.com"),
            HTTP2Header("custom-key", "custom-value"),
        ])
        XCTAssertEqual(decoder.dynamicTableSizeForTesting, 164)
    }

    /// RFC 7541 C.6: responses with Huffman coding and eviction in a 256-octet table.
    func testDecodesRFCHuffmanResponsesWithEviction() throws {
        var decoder = HPACKDecoder(maximumTableSize: 256)
        let first = try decoder.decode(bytes(
            "488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3"
        ))
        XCTAssertEqual(first, [
            HTTP2Header(":status", "302"), HTTP2Header("cache-control", "private"),
            HTTP2Header("date", "Mon, 21 Oct 2013 20:13:21 GMT"), HTTP2Header("location", "https://www.example.com"),
        ])
        XCTAssertEqual(decoder.dynamicTableSizeForTesting, 222)
        let second = try decoder.decode(bytes("4883640effc1c0bf"))
        XCTAssertEqual(second.first, HTTP2Header(":status", "307"))
        XCTAssertEqual(decoder.dynamicTableSizeForTesting, 222)
    }

    /// Bytes produced by Python's `hpack` encoder (indexing + Huffman), the representation a
    /// gRPC server actually sends: a response head, then its trailers, then a second response
    /// that refers back to the dynamic table.
    func testDecodesAnIndependentEncodersGRPCResponses() throws {
        var decoder = HPACKDecoder()
        XCTAssertEqual(try decoder.decode(bytes(
            "885f8b1d75d0620d263d4c4d6564408a9acac8b16a21e435537f863485a9264faf408e9acac8b0c842d6958b510f21aa9b903485a9264fafa90b2d03497ea6f66aff"
        )), [
            HTTP2Header(":status", "200"), HTTP2Header("content-type", "application/grpc"),
            HTTP2Header("grpc-encoding", "identity"), HTTP2Header("grpc-accept-encoding", "identity,deflate,gzip"),
        ])
        let trailers = try decoder.decode(bytes(
            "40889acac8b21234da8f820b9f40899acac8b5254207317facd06420d54ca2672a9fe876a673d86f63498f57fa52728e42d8a783267510525b6193e94258590b524c3a10bf"
        ))
        XCTAssertEqual(GRPCStatus.from(trailers: trailers), GRPCStatus(
            code: .unauthenticated, message: "Missing the 'authorization' header with security credentials."
        ))
        XCTAssertEqual(try decoder.decode(bytes("88c2")).last, HTTP2Header("content-type", "application/grpc"))
    }

    func testHuffmanRoundTripsEveryByte() throws {
        let input = (0...255).map { UInt8($0) } + Array("grpc-message: hello".utf8)
        XCTAssertEqual(try HPACKHuffman.decode(HPACKHuffman.encode(input)), input)
    }

    func testRefusesHuffmanPaddingThatIsNotEOS() {
        // "a" is 00011; padding with zeros instead of ones is invalid.
        XCTAssertThrowsError(try HPACKHuffman.decode([0b0001_1000]))
    }

    func testEncoderOutputDecodes() throws {
        let headers = GRPCRequestHeaders.make(
            authority: "127.0.0.1:8554", path: "/android.emulation.control.EmulatorController/getStatus",
            metadata: [HTTP2Header("authorization", "Bearer abc.def.ghi")]
        )
        var decoder = HPACKDecoder()
        XCTAssertEqual(try decoder.decode(HPACKEncoder.encode(headers)), headers)
        XCTAssertEqual(decoder.dynamicTableSizeForTesting, 0, "the encoder must never index")
    }

    func testBoundsTheHeaderList() {
        var decoder = HPACKDecoder(maximumHeaderListSize: 64)
        let block = HPACKEncoder.encode([HTTP2Header("x-large", String(repeating: "v", count: 100))])
        XCTAssertThrowsError(try decoder.decode(block)) { error in
            XCTAssertEqual(error as? HPACKError, .headerListTooLarge(maximum: 64))
        }
    }

    func testRefusesATableSizeUpdateAboveTheAdvertisedSize() {
        var decoder = HPACKDecoder(maximumTableSize: 4_096)
        var block: [UInt8] = []
        HPACKInteger.encode(8_192, prefixBits: 5, firstByteFlags: 0x20, into: &block)
        XCTAssertThrowsError(try decoder.decode(block))
    }
}
