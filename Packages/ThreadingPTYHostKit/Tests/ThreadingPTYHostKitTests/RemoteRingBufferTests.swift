import XCTest
@testable import ThreadingPTYHostKit

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

    // MARK: - Exact rejoin

    /// The counter is the whole mechanism behind an exact rejoin, so it counts bytes the ring
    /// itself no longer holds.
    func testTotalBytesWrittenCountsEveryByteIncludingOverwrittenOnes() {
        var ring = RemoteRingBuffer(capacity: 4)
        XCTAssertEqual(ring.totalBytesWritten, 0)
        ring.append(data("abc"))
        XCTAssertEqual(ring.totalBytesWritten, 3)
        ring.append(data("de"))
        XCTAssertEqual(ring.totalBytesWritten, 5, "wrapping must not roll the counter back")
        ring.append(data("0123456"))
        XCTAssertEqual(ring.totalBytesWritten, 12, "an oversized write counts in full")
        XCTAssertEqual(ring.count, 4)
    }

    func testAnEmptyAppendDoesNotMoveTheCounter() {
        var ring = RemoteRingBuffer(capacity: 4)
        ring.append(data("ab"))
        ring.append(Data())
        XCTAssertEqual(ring.totalBytesWritten, 2)
    }

    func testTotalBytesWrittenIsMonotonicAcrossManyWraps() {
        var ring = RemoteRingBuffer(capacity: 3)
        var last: UInt64 = 0
        for character in "abcdefghijklmnop" {
            ring.append(data(String(character)))
            XCTAssertGreaterThan(ring.totalBytesWritten, last)
            last = ring.totalBytesWritten
        }
        XCTAssertEqual(last, 16)
        XCTAssertEqual(ring.snapshot(), data("nop"))
    }

    /// The exact branch: a watcher that left at offset 3 is owed exactly the bytes after it.
    func testSnapshotFromAnOffsetStillInTheRingIsExact() {
        var ring = RemoteRingBuffer(capacity: 8)
        ring.append(data("abc"))
        let offset = ring.totalBytesWritten
        ring.append(data("defg"))
        XCTAssertEqual(ring.snapshot(from: offset), data("defg"))
    }

    /// The exact boundary: `behind == count` is still exact, one byte more is not.
    func testSnapshotFromTheOldestByteStillHeldIsExact() {
        var ring = RemoteRingBuffer(capacity: 4)
        ring.append(data("abcdef"))
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.totalBytesWritten, 6)
        XCTAssertEqual(ring.snapshot(from: 2), data("cdef"), "behind == count is exact")
        XCTAssertNil(ring.snapshot(from: 1), "one byte past the ring cannot be proven")
    }

    /// A watcher that missed nothing gets nothing, which is different from being refused.
    func testSnapshotFromTheCurrentOffsetIsEmptyRatherThanNil() {
        var ring = RemoteRingBuffer(capacity: 8)
        ring.append(data("abc"))
        XCTAssertEqual(ring.snapshot(from: ring.totalBytesWritten), Data())
    }

    /// A ring that wrapped past the watcher's offset must refuse rather than hand back a tail
    /// that looks complete: the caller owes a `CAN` and a repaint instead.
    func testSnapshotRefusesAnOffsetTheRingHasOverwritten() {
        var ring = RemoteRingBuffer(capacity: 4)
        ring.append(data("abcd"))
        let offset = ring.totalBytesWritten
        ring.append(data("efghij"))
        XCTAssertNil(ring.snapshot(from: offset - 4))
        XCTAssertEqual(ring.snapshot(from: offset + 2), data("ghij"))
    }

    /// An offset ahead of the ring is a disagreement about history, not a small clamp.
    func testSnapshotRefusesAnOffsetAheadOfWhatWasWritten() {
        var ring = RemoteRingBuffer(capacity: 8)
        ring.append(data("abc"))
        XCTAssertNil(ring.snapshot(from: 4))
    }

    /// An empty ring answers the only offset it has, and refuses every other.
    func testSnapshotFromOnAnUntouchedRing() {
        let ring = RemoteRingBuffer(capacity: 4)
        XCTAssertEqual(ring.snapshot(from: 0), Data())
        XCTAssertNil(ring.snapshot(from: 1))
    }

    /// Reading an exact slice must not consume or rotate the ring.
    func testSnapshotFromLeavesTheRingIntact() {
        var ring = RemoteRingBuffer(capacity: 6)
        ring.append(data("abcd"))
        ring.append(data("efgh"))
        XCTAssertEqual(ring.snapshot(), data("cdefgh"))
        XCTAssertEqual(ring.snapshot(from: 4), data("efgh"))
        XCTAssertEqual(ring.snapshot(), data("cdefgh"))
        XCTAssertEqual(ring.snapshot(from: 4), data("efgh"))
    }
}
