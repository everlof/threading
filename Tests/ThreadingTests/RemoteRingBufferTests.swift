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

    /// Reading the ring must not consume it: every joining client is sent the same bytes.
    func testSnapshotDoesNotConsumeWhatItRead() {
        var ring = RemoteRingBuffer(capacity: 4)
        ring.append(data("xyz"))
        XCTAssertEqual(ring.snapshot(), data("xyz"))
        XCTAssertEqual(ring.snapshot(), data("xyz"), "reading the ring emptied it")
        XCTAssertEqual(ring.count, 3)
    }

    // MARK: - Boundaries

    func testAnEmptyAppendLeavesTheRingUntouched() {
        var ring = RemoteRingBuffer(capacity: 4)
        ring.append(data("ab"))
        ring.append(Data())
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring.snapshot(), data("ab"))
    }

    /// The degenerate ring: every write wraps, so `head` returns to 0 on every byte.
    func testACapacityOfOneKeepsOnlyTheNewestByte() {
        var ring = RemoteRingBuffer(capacity: 1)
        ring.append(data("a"))
        XCTAssertEqual(ring.snapshot(), data("a"))
        ring.append(data("bcd"))
        XCTAssertEqual(ring.count, 1)
        XCTAssertEqual(ring.snapshot(), data("d"))
    }

    /// The exact boundary between the two branches in `append`: the second write lands the
    /// ring on `filled == capacity` without ever taking the oversized-write path.
    func testFillingExactlyToCapacityAcrossTwoAppends() {
        var ring = RemoteRingBuffer(capacity: 6)
        ring.append(data("abcd"))
        ring.append(data("ef"))
        XCTAssertEqual(ring.count, 6)
        XCTAssertEqual(ring.snapshot(), data("abcdef"))
    }

    /// An oversized write arriving when `head` is mid-ring — a TUI repainting over a wrapped
    /// buffer. The tail branch resets `head`, so a stale offset would rotate the replay and
    /// hand the client a screen cut in half.
    func testAnOversizedWriteAfterWrappingReplacesEverythingInOrder() {
        var ring = RemoteRingBuffer(capacity: 4)
        ring.append(data("abc"))
        ring.append(data("de"))
        XCTAssertEqual(ring.snapshot(), data("bcde"), "precondition: the ring has wrapped")

        ring.append(data("0123456"))
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.snapshot(), data("3456"))
    }

    /// The ring holds raw PTY bytes and is replayed verbatim, so it must be byte-transparent —
    /// NUL padding and invalid UTF-8 are ordinary terminal output, not something to sanitise.
    func testArbitraryBytesSurviveTheRingUnchanged() {
        var ring = RemoteRingBuffer(capacity: 8)
        let raw = Data([0x00, 0xFF, 0x1B, 0x5B, 0x32, 0x4A, 0x00, 0xC3])
        ring.append(raw)
        XCTAssertEqual(ring.snapshot(), raw)

        ring.append(Data([0xFE]))
        XCTAssertEqual(ring.snapshot(), Data([0xFF, 0x1B, 0x5B, 0x32, 0x4A, 0x00, 0xC3, 0xFE]))
    }
}
