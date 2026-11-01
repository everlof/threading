import ThreadingRemoteKit
import XCTest

@testable import Threading

/// Mirror's Mac half: one click starts it with no question on either side, the phone decides
/// whether it may take the screen, and every end reaches both sides.
@MainActor
final class PhoneMirrorCoordinatorTests: XCTestCase {
    private var harness: Harness!

    override func setUp() async throws {
        harness = Harness()
    }

    override func tearDown() async throws {
        harness = nil
    }

    // MARK: - Starting

    func testStartingOnAConnectedPhoneSendsTheStateAtOnceAndAsksNothing() throws {
        let phone = harness.connect(.phone)
        let outcome = harness.coordinator.start(harness.source)

        guard case let .started(mirrorID) = outcome else { return XCTFail("\(outcome)") }
        let state = try XCTUnwrap(phone.states().last)
        XCTAssertEqual(state.mirrorID, mirrorID)
        XCTAssertEqual(state.render.url, "http://localhost:5173/")
        XCTAssertEqual(state.offerAgeMilliseconds, 0)
        XCTAssertFalse(state.rejoin)
        XCTAssertEqual(harness.status, .connecting)
        XCTAssertTrue(harness.invites.isEmpty, "a connected phone gets the stage, not a notification")

        harness.coordinator.phoneJoined(.phone, mirrorID: mirrorID)
        XCTAssertEqual(harness.status, .showing)
    }

    func testAPhoneAwayFromTheAppGetsOneInviteThatNamesThePageOnlyWithPreviewConsent() throws {
        harness.inviteTargets = [.init(.phone, previews: false)]
        harness.coordinator.start(harness.source)

        let invite = try XCTUnwrap(harness.invites.last)
        XCTAssertEqual(invite.kind, .mirrorInvite)
        XCTAssertEqual(invite.body, "Tap to show")
        XCTAssertFalse(invite.body.contains("Festina"))
        XCTAssertEqual(invite.titleLocalization?.key, "Mirror from %@")
        XCTAssertEqual(harness.status, .notified)

        harness.coordinator.stop(mirrorID: try XCTUnwrap(harness.mirrorID))
        harness.inviteTargets = [.init(.phone, previews: true)]
        harness.coordinator.start(harness.source)
        XCTAssertEqual(harness.invites.last?.body, "Festina — tap to show")
    }

    func testWithoutPushOrAConnectionTheChipSaysToOpenThreading() {
        harness.inviteTargets = [.init(.phone, previews: true, canPush: false)]
        harness.coordinator.start(harness.source)
        XCTAssertEqual(harness.status, .openOnPhone)
        XCTAssertTrue(harness.invites.isEmpty)
    }

    func testARefusedPushFallsBackToOpenThreading() {
        harness.inviteTargets = [.init(.phone, previews: true)]
        harness.pushAccepted = false
        harness.coordinator.start(harness.source)
        XCTAssertEqual(harness.status, .openOnPhone)
    }

    func testNoPhoneMeansNothingStarts() {
        XCTAssertEqual(harness.coordinator.start(harness.source), .noPhone)
        XCTAssertFalse(harness.coordinator.hasSessions)
    }

    // MARK: - The phone's answer

    func testJoiningWithdrawsTheInviteAndItIsNoLongerCurrent() throws {
        harness.inviteTargets = [.init(.phone, previews: true)]
        harness.coordinator.start(harness.source)
        let invite = try XCTUnwrap(harness.invites.last)
        XCTAssertTrue(harness.coordinator.isInviteCurrent(eventID: invite.id))

        let phone = harness.connect(.phone)
        XCTAssertEqual(phone.states().count, 1, "the hello delivers the pending mirror")
        harness.coordinator.phoneJoined(.phone, mirrorID: try XCTUnwrap(harness.mirrorID))

        XCTAssertFalse(harness.coordinator.isInviteCurrent(eventID: invite.id))
        XCTAssertEqual(harness.withdrawn.map(\.eventID), [invite.id])
    }

    func testAPhoneInUseHoldsTheOfferAndTheChipSaysSo() throws {
        harness.connect(.phone)
        harness.coordinator.start(harness.source)
        harness.coordinator.phoneHeld(.phone, mirrorID: try XCTUnwrap(harness.mirrorID), reason: .inUse)
        XCTAssertEqual(harness.status, .inUse)
    }

    func testStartingAgainIsAFreshOfferTheIdlePhoneCanTake() throws {
        let phone = harness.connect(.phone)
        harness.coordinator.start(harness.source)
        let first = try XCTUnwrap(harness.mirrorID)
        harness.coordinator.phoneHeld(.phone, mirrorID: first, reason: .inUse)

        harness.clock.now += 40
        harness.coordinator.start(harness.source)
        let second = try XCTUnwrap(harness.mirrorID)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(phone.ended().last, RemoteMirrorEndedDTO(mirrorID: first, reason: .replaced))
        XCTAssertEqual(phone.states().last?.mirrorID, second)
        XCTAssertEqual(phone.states().last?.offerAgeMilliseconds, 0, "fresh, so an idle phone takes it")
    }

    func testStartingAgainOnAJoinedPhoneIsOnlyANewRevision() throws {
        let phone = harness.connect(.phone)
        harness.coordinator.start(harness.source)
        let mirrorID = try XCTUnwrap(harness.mirrorID)
        harness.coordinator.phoneJoined(.phone, mirrorID: mirrorID)
        harness.coordinator.start(harness.source)
        XCTAssertEqual(harness.mirrorID, mirrorID)
        XCTAssertEqual(phone.states().last?.mirrorRevision, 2)
        XCTAssertTrue(phone.ended().isEmpty)
    }

    func testAPhoneWithMirrorOffEndsItAndTheChipSaysWhy() throws {
        harness.connect(.phone, availability: .disabled)
        XCTAssertTrue(harness.coordinator.candidates().isEmpty, "a phone that switched Mirror off is no candidate")
        harness.coordinator.start(harness.source, on: .phone)
        XCTAssertEqual(harness.chip?.status, .ended(.disabled))
        XCTAssertNil(harness.chip?.mirrorID)
    }

    func testLeavingOnThePhoneLeavesANoticeWithMirrorAgain() throws {
        harness.connect(.phone)
        harness.coordinator.start(harness.source)
        harness.coordinator.phoneLeft(.phone, mirrorID: try XCTUnwrap(harness.mirrorID))
        XCTAssertEqual(harness.chip?.status, .ended(.endedOnPhone))
        XCTAssertFalse(harness.coordinator.hasSessions)
    }

    func testStoppingOnTheMacTellsThePhoneAndLeavesNoNotice() throws {
        let phone = harness.connect(.phone)
        harness.coordinator.start(harness.source)
        let mirrorID = try XCTUnwrap(harness.mirrorID)
        harness.coordinator.stop(mirrorID: mirrorID)
        XCTAssertEqual(phone.ended().last, RemoteMirrorEndedDTO(mirrorID: mirrorID, reason: .stoppedOnMac))
        XCTAssertNil(harness.chip)
        XCTAssertTrue(harness.source.observerCount == 0, "the page is no longer followed")
    }

    // MARK: - Away and back

    func testAJoinedPhoneThatLeavesTheAppIsAwayAndRejoinsDirectly() throws {
        let phone = harness.connect(.phone)
        harness.coordinator.start(harness.source)
        let mirrorID = try XCTUnwrap(harness.mirrorID)
        harness.coordinator.phoneJoined(.phone, mirrorID: mirrorID)

        harness.coordinator.channelClosed(phone)
        XCTAssertEqual(harness.status, .away)

        let back = harness.connect(.phone)
        XCTAssertEqual(back.states().last?.rejoin, true)
        XCTAssertEqual(harness.status, .showing)
    }

    func testAStageTheMacNoLongerRunsIsEndedOnHello() {
        let phone = harness.connect(.phone, showing: "gone")
        XCTAssertEqual(phone.ended(), [RemoteMirrorEndedDTO(mirrorID: "gone", reason: .expired)])
    }

    func testAnUnjoinedOfferExpiresAndAnAwayMirrorWaitsHalfAnHour() throws {
        harness.connect(.phone)
        harness.coordinator.start(harness.source)
        harness.clock.fire(after: RemoteMirror.offerLifetime)
        XCTAssertEqual(harness.chip?.status, .ended(.expired))

        let phone = harness.connect(.phone)
        harness.coordinator.start(harness.source)
        harness.coordinator.phoneJoined(.phone, mirrorID: try XCTUnwrap(harness.mirrorID))
        harness.clock.fire(after: RemoteMirror.offerLifetime)
        XCTAssertEqual(harness.status, .showing, "a joined mirror does not expire as an offer")
        harness.coordinator.channelClosed(phone)
        harness.clock.fire(after: RemoteMirror.awayLifetime)
        XCTAssertEqual(harness.chip?.status, .ended(.expired))
    }

    func testTheInviteIsWithdrawnAfterTwoMinutes() throws {
        harness.inviteTargets = [.init(.phone, previews: true)]
        harness.coordinator.start(harness.source)
        let invite = try XCTUnwrap(harness.invites.last)
        harness.clock.fire(after: TimeInterval(RemoteMirror.inviteLifetime))
        XCTAssertEqual(harness.withdrawn.map(\.eventID), [invite.id])
        XCTAssertEqual(harness.status, .openOnPhone)
    }

    // MARK: - Revisions

    func testABurstOfChangesBecomesOneRevision() throws {
        let phone = harness.connect(.phone)
        harness.coordinator.start(harness.source)
        harness.source.url = URL(string: "http://localhost:5173/menu")!
        for _ in 0..<5 { harness.source.emit(.document) }
        harness.clock.fire(after: PhoneMirrorDefaults.revisionCoalescing)

        let states = phone.states()
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states.last?.mirrorRevision, 2)
        XCTAssertEqual(states.last?.render.url, "http://localhost:5173/menu")
    }

    func testATitleChangeKeepsTheRevision() throws {
        let phone = harness.connect(.phone)
        harness.coordinator.start(harness.source)
        harness.source.title = "Festina · Menu"
        harness.source.emit(.title)
        harness.clock.fire(after: PhoneMirrorDefaults.revisionCoalescing)
        XCTAssertEqual(phone.states().last?.mirrorRevision, 1)
        XCTAssertEqual(phone.states().last?.sourceTitle, "Festina · Menu")
    }

    func testAClosedTabEndsTheMirror() {
        let phone = harness.connect(.phone)
        harness.coordinator.start(harness.source)
        harness.sourceAvailable = false
        harness.clock.fire(after: PhoneMirrorDefaults.sourceCheckInterval)
        XCTAssertEqual(phone.ended().last?.reason, .sourceClosed)
    }

    // MARK: - Choosing the phone

    func testTheMostRecentlyActivePhoneIsChosenWithoutAsking() {
        harness.connect(.phone)
        harness.clock.now += 5
        harness.connect(.otherPhone)
        XCTAssertEqual(harness.coordinator.candidates().map(\.device), [.otherPhone, .phone])
    }

    func testMovingToAnotherPhoneEndsTheFirstAsReplaced() throws {
        let first = harness.connect(.phone)
        let second = harness.connect(.otherPhone)
        harness.coordinator.start(harness.source, on: .phone)
        let mirrorID = try XCTUnwrap(harness.mirrorID)
        harness.coordinator.move(mirrorID: mirrorID, to: .otherPhone)
        XCTAssertEqual(first.ended().last, RemoteMirrorEndedDTO(mirrorID: mirrorID, reason: .replaced))
        XCTAssertEqual(second.states().count, 1)
    }
}

// MARK: - Fixture

private extension PhoneMirrorDevice {
    static let phone = PhoneMirrorDevice(shareID: "owner-1", deviceID: "device-1")
    static let otherPhone = PhoneMirrorDevice(shareID: "owner-2", deviceID: "device-2")
}

@MainActor
private final class Harness {
    let clock = FakeClock()
    let source = FakeBrowser()
    var sourceAvailable = true
    var inviteTargets: [RemoteMirrorInviteTarget] = []
    var pushAccepted = true
    private(set) var invites: [RemoteNotificationEventDTO] = []
    private(set) var withdrawn: [RemoteNotificationRetractionDTO] = []
    private var channels: [FakeChannel] = []
    let defaults: UserDefaults
    lazy var coordinator = PhoneMirrorCoordinator(environment: .init(
        now: { [clock] in clock.date },
        schedule: { [clock] seconds, work in clock.schedule(after: seconds, work) },
        hostID: { "host-1" },
        hostName: { "MacBook Pro" },
        source: { [weak self] _ in
            guard let self, self.sourceAvailable else { return nil }
            return PhoneMirrorSourceSnapshot(url: self.source.url, title: self.source.title, browser: self.source)
        },
        inviteTargets: { [weak self] in self?.inviteTargets ?? [] },
        sendInvite: { [weak self] event, _, completion in
            guard let self else { return }
            self.invites.append(event)
            completion(.init(accepted: self.pushAccepted, statusCode: 200, providerTrace: nil))
        },
        withdrawInvite: { [weak self] retraction, _ in self?.withdrawn.append(retraction) },
        deviceName: { _ in "Davids iPhone" },
        defaults: defaults,
        didChange: {}
    ))

    init() {
        let suite = "PhoneMirrorCoordinatorTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    var chip: PhoneMirrorChipState? {
        coordinator.chipState(forBrowser: ObjectIdentifier(source))
    }

    var status: PhoneMirrorStatus? { chip?.status }
    var mirrorID: String? { chip?.mirrorID }

    @discardableResult
    func connect(
        _ device: PhoneMirrorDevice,
        availability: RemoteMirrorAvailability = .enabled,
        showing: String? = nil
    ) -> FakeChannel {
        let channel = FakeChannel()
        // The coordinator holds a socket weakly, as the server owns it; the fixture plays server.
        channels.append(channel)
        coordinator.phoneSaidHello(device, availability: availability, showing: showing, channel: channel)
        return channel
    }
}

extension PhoneMirrorCoordinator {
    @discardableResult
    fileprivate func start(_ browser: FakeBrowser, on device: PhoneMirrorDevice? = nil) -> PhoneMirrorStartOutcome {
        start(browser.address, on: device)
    }
}

private extension RemoteMirrorInviteTarget {
    init(_ device: PhoneMirrorDevice, previews: Bool, canPush: Bool = true) {
        self.init(
            identity: RemoteNotificationTargetIdentity(
                shareID: device.shareID, deviceID: device.deviceID, participantID: .owner
            ),
            includesPreviews: previews,
            canPush: canPush,
            canRetract: true
        )
    }
}

@MainActor
private final class FakeBrowser: PhoneMirrorObservableSource {
    let address = PhoneMirrorSource(sessionID: SessionID(), tabID: UUID())
    var url = URL(string: "http://localhost:5173/")!
    var title = "Festina"
    private var observers: [UUID: @MainActor (PhoneMirrorSourceChange) -> Void] = [:]
    var observerCount: Int { observers.count }

    func observePhoneMirrorChanges(
        _ handler: @escaping @MainActor (PhoneMirrorSourceChange) -> Void
    ) -> PhoneMirrorSourceObservation {
        let id = UUID()
        observers[id] = handler
        return PhoneMirrorSourceObservation { [weak self] in self?.observers[id] = nil }
    }

    func emit(_ change: PhoneMirrorSourceChange) {
        for handler in observers.values { handler(change) }
    }
}

private final class FakeChannel: PhoneMirrorChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String] = []

    func sendPhoneMirrorFrame(_ text: String) {
        lock.withLock { frames.append(text) }
    }

    /// Frames are encoded on the coordinator's worker; wait for it before reading.
    private func settled() -> [Data] {
        PhoneMirrorCoordinator.frameQueue.sync {}
        return lock.withLock { frames.map { Data($0.utf8) } }
    }

    func states() -> [RemoteMirrorStateDTO] {
        settled().compactMap { try? JSONDecoder().decode(RemoteMirrorStateDTO.self, from: $0) }
            .filter { $0.type == RemoteMirrorFrame.state.rawValue }
    }

    func ended() -> [RemoteMirrorEndedDTO] {
        settled().compactMap { try? JSONDecoder().decode(RemoteMirrorEndedDTO.self, from: $0) }
            .filter { $0.type == RemoteMirrorFrame.ended.rawValue }
    }
}

@MainActor
private final class FakeClock {
    private final class Timer: PhoneMirrorTimer {
        var isCancelled = false
        func cancel() { isCancelled = true }
    }

    var now: TimeInterval = 1_800_000_000
    var date: Date { Date(timeIntervalSince1970: now) }
    private var pending: [(due: TimeInterval, timer: Timer, work: @MainActor () -> Void)] = []

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> PhoneMirrorTimer {
        let timer = Timer()
        pending.append((now + seconds, timer, work))
        return timer
    }

    /// Moves the clock and runs, in order, everything that has come due.
    func fire(after seconds: TimeInterval) {
        now += seconds
        while let index = pending.indices
            .filter({ pending[$0].due <= now })
            .min(by: { pending[$0].due < pending[$1].due }) {
            let item = pending.remove(at: index)
            if !item.timer.isCancelled { item.work() }
        }
    }
}
