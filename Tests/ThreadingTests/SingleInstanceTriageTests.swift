import XCTest
@testable import Threading

/// The whole table a launch that lost the lock decides from, plus the staleness judgment it
/// rests on. No lock, no process and no window: the rule is a pure function precisely so it can
/// be held to every row, including the ones that are hard to stage for real.
final class SingleInstanceTriageTests: XCTestCase {

    private func card(
        pid: Int32 = 4_242,
        bundlePath: String = "/Applications/Threading.app"
    ) -> SingleInstanceOwnerCard {
        SingleInstanceOwnerCard(
            pid: pid,
            startTime: ProcessStartTime(seconds: 1_700, microseconds: 42),
            bundlePath: bundlePath,
            version: "1.0 (1)",
            writtenAt: "2026-01-01T00:00:00Z"
        )
    }

    // MARK: - The verdict table

    func testNoCardAtAllSaysNothingAndOffersNothing() {
        XCTAssertEqual(
            SingleInstanceTriage.verdict(card: nil, ownerIdentity: .confirmed, heartbeatAge: 0),
            .alertOnly(.noOwnerCard)
        )
    }

    /// The machine would not say. Neither remedy is safe on that.
    func testAnIdentityTheMachineWillNotConfirmSaysNothingAndOffersNothing() {
        XCTAssertEqual(
            SingleInstanceTriage.verdict(
                card: card(),
                ownerIdentity: .unreadable,
                heartbeatAge: 600
            ),
            .alertOnly(.ownerIdentityUnreadable)
        )
    }

    /// The overnight lockout, as a verdict. The owner is provably gone and the lock is provably
    /// held — we are only here because our own acquire was refused — so something the owner
    /// spawned inherited its descriptor and is still holding it.
    func testAnOwnerThatIsGoneWhileItsLockIsHeldMeansSomethingInheritedTheDescriptor() {
        for age in [nil, 0, 5, 900] as [TimeInterval?] {
            XCTAssertEqual(
                SingleInstanceTriage.verdict(
                    card: card(pid: 91, bundlePath: "/Applications/Threading.app"),
                    ownerIdentity: .gone,
                    heartbeatAge: age
                ),
                .orphanedLockHolders(ownerPID: 91, bundlePath: "/Applications/Threading.app"),
                "a dead owner's heartbeat says nothing about who holds the lock"
            )
        }
    }

    /// A healthy-looking card with no heartbeat beside it. Silence is not evidence of death:
    /// an owner from before the heartbeat existed looks exactly like this.
    func testAMissingHeartbeatUnderAValidCardSaysNothingAndOffersNothing() {
        XCTAssertEqual(
            SingleInstanceTriage.verdict(
                card: card(),
                ownerIdentity: .confirmed,
                heartbeatAge: nil
            ),
            .alertOnly(.heartbeatMissing)
        )
    }

    func testAFreshHeartbeatMeansSwitchToTheOwner() {
        XCTAssertEqual(
            SingleInstanceTriage.verdict(
                card: card(pid: 77, bundlePath: "/Applications/Threading.app"),
                ownerIdentity: .confirmed,
                heartbeatAge: 1
            ),
            .activateOwner(pid: 77, bundlePath: "/Applications/Threading.app")
        )
    }

    /// The boundary itself belongs to the living: exactly the threshold is not yet stale.
    func testTheStalenessThresholdItselfStillMeansSwitchToTheOwner() {
        XCTAssertEqual(
            SingleInstanceTriage.verdict(
                card: card(pid: 77),
                ownerIdentity: .confirmed,
                heartbeatAge: SingleInstanceDefaults.staleThreshold
            ),
            .activateOwner(pid: 77, bundlePath: "/Applications/Threading.app")
        )
    }

    func testAStoppedHeartbeatUnderAValidCardOffersTheTakeover() {
        XCTAssertEqual(
            SingleInstanceTriage.verdict(
                card: card(pid: 77, bundlePath: "/Users/somebody/DerivedData/Threading.app"),
                ownerIdentity: .confirmed,
                heartbeatAge: 900
            ),
            .offerTakeover(
                pid: 77,
                bundlePath: "/Users/somebody/DerivedData/Threading.app",
                staleness: 900
            )
        )
    }

    /// The one row that must never appear: a takeover offered on anything but a verified
    /// identity. Asserted as a property of the whole table rather than of one case.
    func testNothingDestructiveIsEverOfferedWithoutAVerifiedIdentity() {
        for age in [nil, 0, 1, 29, 30, 31, 10_000] as [TimeInterval?] {
            for identity in [SingleInstanceTriage.OwnerIdentity.gone, .unreadable] {
                for owner in [nil, card()] {
                    let verdict = SingleInstanceTriage.verdict(
                        card: owner,
                        ownerIdentity: identity,
                        heartbeatAge: age
                    )
                    if case .offerTakeover = verdict {
                        XCTFail("a takeover was offered for \(identity) at \(String(describing: age))")
                    }
                    if case .activateOwner = verdict {
                        XCTFail("an owner nobody confirmed was activated")
                    }
                }
            }
        }
    }

    // MARK: - Identity

    func testIdentityHoldsOnlyWhenBothHalvesOfThePairMatch() {
        let owner = card(pid: 4_242)

        XCTAssertEqual(SingleInstanceTriage.identity(of: owner) { _ in
            .running(owner.startTime)
        }, .confirmed)
        // A recycled pid reads as gone rather than as unreadable: the *owner* is certainly not
        // running, and nothing downstream ever signals that number.
        XCTAssertEqual(SingleInstanceTriage.identity(of: owner) { _ in
            .running(ProcessStartTime(seconds: 1_700, microseconds: 43))
        }, .gone)
        XCTAssertEqual(SingleInstanceTriage.identity(of: owner) { _ in .absent }, .gone)
        XCTAssertEqual(SingleInstanceTriage.identity(of: owner) { _ in .unreadable }, .unreadable)
    }

    /// This process is the one identity available to assert against the real machine.
    func testTheLiveProbeAcceptsThisProcessAndRejectsAnImpossiblePid() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let startTime = try XCTUnwrap(ProcessUtility.startTime(forPid: pid))

        XCTAssertEqual(SingleInstanceTriage.identity(of: SingleInstanceOwnerCard(
            pid: pid,
            startTime: startTime,
            bundlePath: Bundle.main.bundlePath,
            version: "1.0 (1)",
            writtenAt: "2026-01-01T00:00:00Z"
        )), .confirmed)

        XCTAssertEqual(SingleInstanceTriage.identity(of: SingleInstanceOwnerCard(
            pid: -1,
            startTime: startTime,
            bundlePath: Bundle.main.bundlePath,
            version: "1.0 (1)",
            writtenAt: "2026-01-01T00:00:00Z"
        )), .gone)
    }

    // MARK: - Staleness

    func testStalenessIsJudgedAgainstTheThresholdAndNothingElse() {
        XCTAssertFalse(SingleInstanceHeartbeat.isStale(age: 0))
        XCTAssertFalse(SingleInstanceHeartbeat.isStale(
            age: SingleInstanceDefaults.staleThreshold
        ))
        XCTAssertTrue(SingleInstanceHeartbeat.isStale(
            age: SingleInstanceDefaults.staleThreshold + 0.001
        ))
    }

    /// No heartbeat file is not a stale heartbeat. The distinction is the whole fail-closed
    /// posture: nothing can be said about an owner that never wrote one.
    func testAnAbsentHeartbeatIsNotStale() {
        XCTAssertFalse(SingleInstanceHeartbeat.isStale(age: nil))
    }

    /// A clock that moved backwards produces a negative age. That reads as fresh, for the same
    /// reason: a system clock change must not authorise a kill.
    func testAHeartbeatFromTheFutureIsNotStale() {
        XCTAssertFalse(SingleInstanceHeartbeat.isStale(age: -3_600))
    }

    func testTheAgeOfAnAbsentFileIsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-heartbeat-\(UUID().uuidString)")
        XCTAssertNil(SingleInstanceHeartbeat.age(of: missing))
    }

    func testTheAgeOfAFileIsMeasuredFromItsModificationTime() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-heartbeat-\(UUID().uuidString)")
        try Data("beat".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let written = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )
        let age = try XCTUnwrap(
            SingleInstanceHeartbeat.age(of: url, now: written.addingTimeInterval(120))
        )
        XCTAssertEqual(age, 120, accuracy: 0.001)
    }

    // MARK: - The question

    /// The one destructive answer this surface offers, held to what it costs rather than to what
    /// it fixes — and to the register, which is what puts Return on Quit.
    @MainActor
    func testTheTakeoverQuestionSaysWhatIsLostAndDefaultsToQuitting() {
        let request = AppDelegate.singleInstanceTakeoverConfirmation(staleness: 47.4)

        XCTAssertEqual(request.prompt, .takeOverSingleInstanceLock)
        XCTAssertTrue(request.prompt.defaultsToCancel)
        XCTAssertNil(request.prompt.suppression,
                     "suppressed, this would end a running Threading with no question asked")
        // The staleness is rounded into the sentence, so the user is told how dead it looked
        // rather than merely that it looked dead. Asserted on the number rather than on any
        // English around it, which a translated build would not have.
        XCTAssertTrue(request.message.contains("47"))
        XCTAssertEqual(request.cancelTitle, L10n.string("Quit"))
        XCTAssertEqual(request.confirmTitle, L10n.string("End It and Continue"))
        XCTAssertEqual(request.style, .critical)
    }

    /// The second destructive answer, on the other branch: the owner is gone and its leftover
    /// agent processes are what have to end.
    @MainActor
    func testTheOrphanQuestionNamesWhatItWillEndAndDefaultsToQuitting() {
        let holders = [
            AgentChildRecord(
                pid: 11,
                startTime: ProcessStartTime(seconds: 11, microseconds: 1),
                sessionID: nil,
                executable: "claude",
                recordedAt: Date(timeIntervalSince1970: 0)
            ),
            AgentChildRecord(
                pid: 12,
                startTime: ProcessStartTime(seconds: 12, microseconds: 1),
                sessionID: nil,
                executable: "node",
                recordedAt: Date(timeIntervalSince1970: 0)
            )
        ]
        let request = AppDelegate.orphanedLockReleaseConfirmation(holders: holders)

        XCTAssertEqual(request.prompt, .endOrphanedAgentProcesses)
        XCTAssertTrue(request.prompt.defaultsToCancel)
        XCTAssertNil(request.prompt.suppression)
        XCTAssertTrue(request.message.contains("claude"))
        XCTAssertTrue(request.message.contains("node"))
        XCTAssertTrue(request.message.contains("2"))
        XCTAssertEqual(request.cancelTitle, L10n.string("Quit"))
    }

    @MainActor
    func testStartingTheHeartbeatWritesOneImmediatelyAndStoppingIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-heartbeat-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(SingleInstanceDefaults.heartbeatFileName)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let heartbeat = SingleInstanceHeartbeat(url: url)
        heartbeat.start()
        defer { heartbeat.stop() }

        let age = try XCTUnwrap(SingleInstanceHeartbeat.age(of: url))
        XCTAssertLessThan(age, SingleInstanceDefaults.staleThreshold)

        heartbeat.stop()
        heartbeat.stop()
    }
}
