import XCTest
@testable import Threading

/// A joining client states how much terminal replay it can usefully keep, and the Mac decides
/// how much of the ring it is owed: nothing, the ring whole, or a CAN-prefixed tail that a fresh
/// repaint follows. The decision and the budget policy are tested directly, because the failures
/// they prevent — a client whose parser starts mid-sequence, or one refused a budget it could
/// have been given — are invisible until a person looks at a phone. When the repaint is sent is
/// `attachTerminal`'s business, not this decision's.
@MainActor
final class RemoteTerminalReplayTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let cancel: UInt8 = 0x18
        static let budget = 16 * 1024
    }

    // MARK: - Replay composition

    func testAClientThatStatesNoBudgetGetsTheRingWhole() {
        let ring = Self.ring(bytes: 4 * Fixture.budget)

        XCTAssertEqual(
            RemoteSessionMirrorRegistry.terminalReplay(ring: ring, budget: nil),
            .whole(ring),
            "Nothing was cut, so nothing needs restating"
        )
    }

    func testAnEmptyRingReplaysNothingAtAll() {
        XCTAssertEqual(
            RemoteSessionMirrorRegistry.terminalReplay(ring: Data(), budget: Fixture.budget),
            .nothing
        )
        XCTAssertEqual(
            RemoteSessionMirrorRegistry.terminalReplay(ring: Data(), budget: nil),
            .nothing
        )
    }

    func testARingInsideTheBudgetIsSentUncutAndUnannounced() {
        let ring = Self.ring(bytes: Fixture.budget - 1)

        XCTAssertEqual(
            RemoteSessionMirrorRegistry.terminalReplay(ring: ring, budget: Fixture.budget),
            .whole(ring),
            "An uncut ring is byte-for-byte what it always was, with no CAN in front of it"
        )
    }

    func testARingAtExactlyTheBudgetIsStillSentWhole() {
        let ring = Self.ring(bytes: Fixture.budget)

        XCTAssertEqual(
            RemoteSessionMirrorRegistry.terminalReplay(ring: ring, budget: Fixture.budget),
            .whole(ring)
        )
    }

    func testACutRingCarriesItsNewestBytesBehindCAN() throws {
        let ring = Self.ring(bytes: 3 * Fixture.budget)

        let replay = RemoteSessionMirrorRegistry.terminalReplay(
            ring: ring,
            budget: Fixture.budget
        )

        guard case .cut(let tail) = replay else {
            return XCTFail("A ring larger than the budget must be cut, got \(replay)")
        }
        XCTAssertEqual(tail.first, Fixture.cancel, "The cut can land inside an escape sequence")
        XCTAssertEqual(tail.count, Fixture.budget + 1)
        XCTAssertEqual(Array(tail.dropFirst()), Array(ring.suffix(Fixture.budget)))
    }

    func testANonPositiveBudgetIsReadAsNoBudgetRatherThanNoHistory() {
        let ring = Self.ring(bytes: Fixture.budget)

        XCTAssertEqual(
            RemoteSessionMirrorRegistry.terminalReplay(ring: ring, budget: 0),
            .whole(ring)
        )
        XCTAssertEqual(
            RemoteSessionMirrorRegistry.terminalReplay(ring: ring, budget: -1),
            .whole(ring)
        )
    }

    // MARK: - Inbound policy

    func testOnlyAMissingOrNonPositiveBudgetCountsAsNoStatement() {
        XCTAssertNil(RemoteInboundPolicy.normalizedTerminalReplayBudget(nil))
        XCTAssertNil(RemoteInboundPolicy.normalizedTerminalReplayBudget(0))
        XCTAssertNil(RemoteInboundPolicy.normalizedTerminalReplayBudget(-1))
    }

    func testATinyBudgetIsClampedUpRatherThanDiscarded() {
        XCTAssertEqual(
            RemoteInboundPolicy.normalizedTerminalReplayBudget(8 * 1024),
            RemoteAccessDefaults.minimumTerminalReplayBudgetBytes,
            "A small ask costs scrollback, not screen exactness, so it stays a statement"
        )
        XCTAssertEqual(
            RemoteInboundPolicy.normalizedTerminalReplayBudget(1),
            RemoteAccessDefaults.minimumTerminalReplayBudgetBytes
        )
    }

    func testAStatedBudgetIsHonouredUpToTheRingAndNoFurther() {
        XCTAssertEqual(
            RemoteInboundPolicy.normalizedTerminalReplayBudget(
                RemoteAccessDefaults.minimumTerminalReplayBudgetBytes
            ),
            RemoteAccessDefaults.minimumTerminalReplayBudgetBytes
        )
        XCTAssertEqual(
            RemoteInboundPolicy.normalizedTerminalReplayBudget(128 * 1024),
            128 * 1024
        )
        XCTAssertEqual(
            RemoteInboundPolicy.normalizedTerminalReplayBudget(10 * 1024 * 1024),
            RemoteAccessDefaults.ringBufferBytes,
            "There is no more history to ask for than the ring holds"
        )
    }

    // MARK: - Private Methods

    /// Bytes that are distinguishable at every offset, so a suffix assertion cannot pass on the
    /// wrong window.
    private static func ring(bytes count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }
}
