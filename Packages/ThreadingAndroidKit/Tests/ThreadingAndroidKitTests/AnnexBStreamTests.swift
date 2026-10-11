import XCTest
@testable import ThreadingAndroidKit

final class AnnexBStreamTests: XCTestCase {
    private func fixture() throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/screenrecord-540x1200", withExtension: "h264"))
        return [UInt8](try Data(contentsOf: url))
    }

    /// The fixture is a real `screenrecord --output-format=h264 --size 540x1200` of a still
    /// screen: parameter sets and exactly one IDR picture, after which the device sent nothing.
    func testAStillScreensOnlyPictureNeedsTheFlush() throws {
        var stream = AnnexBStream()
        let units = try stream.append(try fixture())
        XCTAssertEqual(units, [], "the only picture has no following start code")
        let unit = try XCTUnwrap(stream.flush().first)
        XCTAssertTrue(unit.isKeyFrame)
        XCTAssertTrue(unit.parameterSetsChanged)
        XCTAssertEqual(unit.sequenceParameterSet?.first.map { $0 & 0x1F }, 7)
        XCTAssertEqual(unit.pictureParameterSet?.first.map { $0 & 0x1F }, 8)
        // AVCC: the first length prefix covers exactly the first NAL.
        let length = Int(BigEndian.uint32(unit.avcc, at: 0))
        XCTAssertLessThanOrEqual(length + 4, unit.avcc.count)
        XCTAssertEqual(stream.flush(), [])
    }

    func testChunkedDeliveryYieldsTheSameUnits() throws {
        let bytes = try fixture()
        var whole = AnnexBStream()
        var expected = try whole.append(bytes)
        expected += whole.flush()

        var chunked = AnnexBStream()
        var units: [H264AccessUnit] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + 777)
            units += try chunked.append(Array(bytes[offset..<end]))
            offset = end
        }
        units += chunked.flush()
        XCTAssertEqual(units, expected)
    }

    func testSeparatesConsecutivePicturesAndKeepsParameterSets() throws {
        let sps: [UInt8] = [0, 0, 0, 1, 0x67, 0x42, 0xC0, 0x29]
        let pps: [UInt8] = [0, 0, 0, 1, 0x68, 0xCE, 0x01]
        let idr: [UInt8] = [0, 0, 0, 1, 0x65, 0x88, 0x10]
        let p1: [UInt8] = [0, 0, 1, 0x41, 0x9A, 0x22]
        let p2: [UInt8] = [0, 0, 1, 0x41, 0x9B, 0x33]
        var stream = AnnexBStream()
        // p2 is still the unterminated tail, so p1 cannot be known complete yet either.
        let units = try stream.append(sps + pps + idr + p1 + p2)
        XCTAssertEqual(units.map(\.isKeyFrame), [true])
        XCTAssertTrue(units[0].parameterSetsChanged)
        let flushed = stream.flush()
        XCTAssertEqual(flushed.map(\.avcc), [[0, 0, 0, 3, 0x41, 0x9A, 0x22], [0, 0, 0, 3, 0x41, 0x9B, 0x33]])
        XCTAssertEqual(flushed.map(\.parameterSetsChanged), [false, false])
    }

    func testBoundsAnUnterminatedUnit() {
        var stream = AnnexBStream()
        XCTAssertThrowsError(try stream.append([0, 0, 1, 0x65] + Array(repeating: 0xFF, count: AnnexBStream.maximumAccessUnitBytes)))
    }
}
