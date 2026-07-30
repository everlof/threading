import XCTest
@testable import Threading

final class RemoteRingBufferTests: XCTestCase {

    private func data(_ string: String) -> Data { Data(string.utf8) }

    func testEmptyBufferSnapshotsToNothing() {
        let ring = RemoteRingBuffer(capacity: 8)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.snapshot(), Data())
    }

    func testBelowCapacitySnapshotsEverythingInOrder() {
        var ring = RemoteRingBuffer(capacity: 8)
        ring.append(data("abc"))
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.snapshot(), data("abc"))
    }

    func testExactlyCapacityKeepsAll() {
        var ring = RemoteRingBuffer(capacity: 4)
        ring.append(data("abcd"))
        XCTAssertEqual(ring.snapshot(), data("abcd"))
    }

    func testSingleWriteLargerThanCapacityKeepsTheTail() {
        var ring = RemoteRingBuffer(capacity: 4)
        ring.append(data("abcdefg"))
        XCTAssertEqual(ring.snapshot(), data("defg"))
    }

    func testWrapAroundAcrossAppendsKeepsTheNewestBytes() {
        var ring = RemoteRingBuffer(capacity: 4)
        ring.append(data("abc"))
        ring.append(data("de"))
        // "abcde" written into a 4-byte ring leaves the last four bytes, in order.
        XCTAssertEqual(ring.snapshot(), data("bcde"))
    }

    func testManySmallAppendsConvergeOnTheLastNBytes() {
        var ring = RemoteRingBuffer(capacity: 5)
        for character in "abcdefghij" { ring.append(data(String(character))) }
        XCTAssertEqual(ring.count, 5)
        XCTAssertEqual(ring.snapshot(), data("fghij"))
    }

    func testSnapshotIsStableAcrossRepeatedReads() {
        var ring = RemoteRingBuffer(capacity: 4)
        ring.append(data("xyz"))
        XCTAssertEqual(ring.snapshot(), ring.snapshot())
    }
}
