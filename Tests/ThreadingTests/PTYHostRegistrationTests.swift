import Foundation
import ServiceManagement
import ThreadingPTYHostKit
import XCTest
@testable import Threading

// MARK: - A launchd that is not launchd

/// The `SMAppService` seam, recorded.
///
/// **Nothing in this file may reach the real one.** A hosted test bundle lives inside the shipping
/// app, so `SMAppService.agent(plistName:)` here would address the developer's own Threading, and
/// `unregister()` kills the running helper — a test that tidied up after itself would stop
/// whatever their app was doing. The registration probe that *did* register for real used a
/// throwaway bundle with a `-probe` label and unregistered afterwards; nothing in the test target
/// does.
private final class RecordingAgentService: PTYHostAgentService, @unchecked Sendable {

    private let lock = NSLock()
    private var statusStorage: PTYHostRegistrationStatus
    private var afterRegister: PTYHostRegistrationStatus?
    private var registerError: Error?
    private var unregisterError: Error?
    private var registerCalls = 0
    private var unregisterCalls = 0
    private var statusReads = 0

    init(
        status: PTYHostRegistrationStatus,
        afterRegister: PTYHostRegistrationStatus? = nil,
        registerError: Error? = nil,
        unregisterError: Error? = nil
    ) {
        self.statusStorage = status
        self.afterRegister = afterRegister
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    var status: PTYHostRegistrationStatus {
        lock.lock()
        defer { lock.unlock() }
        statusReads += 1
        return statusStorage
    }

    func register() throws {
        lock.lock()
        registerCalls += 1
        let failure = registerError
        if failure == nil, let afterRegister { statusStorage = afterRegister }
        lock.unlock()
        if let failure { throw failure }
    }

    func unregister() throws {
        lock.lock()
        unregisterCalls += 1
        let failure = unregisterError
        if failure == nil { statusStorage = .notRegistered }
        lock.unlock()
        if let failure { throw failure }
    }

    var registrations: Int {
        lock.lock()
        defer { lock.unlock() }
        return registerCalls
    }

    var unregistrations: Int {
        lock.lock()
        defer { lock.unlock() }
        return unregisterCalls
    }

    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return statusReads
    }
}

/// A receipt filesystem that never leaves the test process.
private final class RecordingReceiptStore: @unchecked Sendable {
    private let lock = NSLock()
    private var receipt: PTYHostRegistrationReceipt?
    private var loadCalls = 0
    private var saveCalls = 0
    private var removeCalls = 0

    var store: PTYHostRegistrationReceiptStore {
        PTYHostRegistrationReceiptStore(
            load: { [weak self] _ in
                guard let self else { return nil }
                lock.lock()
                defer { lock.unlock() }
                loadCalls += 1
                return receipt
            },
            save: { [weak self] receipt, _ in
                guard let self else { return }
                lock.lock()
                saveCalls += 1
                self.receipt = receipt
                lock.unlock()
            },
            remove: { [weak self] _ in
                guard let self else { return }
                lock.lock()
                removeCalls += 1
                receipt = nil
                lock.unlock()
            }
        )
    }

    func seed(_ receipt: PTYHostRegistrationReceipt) {
        lock.lock()
        self.receipt = receipt
        lock.unlock()
    }

    var calls: (loads: Int, saves: Int, removes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (loadCalls, saveCalls, removeCalls)
    }

    var saved: PTYHostRegistrationReceipt? {
        lock.lock()
        defer { lock.unlock() }
        return receipt
    }
}

// MARK: - Tests

/// Registering the launchd agent that starts `threading-ptyd`, and deciding what to do about a
/// daemon the last bundle left behind.
///
/// Everything here is decided from values — a status, a request, a build string, a session count —
/// so every branch is reachable with no launchd, no daemon, no socket and no window. That is the
/// point rather than a convenience: the interesting cases are a Mac that requires approval, a
/// recovery launch and a stale daemon holding somebody's agents, and none of the three can be
/// arranged on demand.
final class PTYHostRegistrationTests: XCTestCase {

    // MARK: - Fixtures

    private var scratch: URL!
    private var helper: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PTYHostRegistrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        helper = scratch.appendingPathComponent(PTYHostDefaults.helperName)
        FileManager.default.createFile(
            atPath: helper.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: - Status mapping

    func testEveryServiceManagementStatusBecomesOneAvailabilityAnswer() {
        // The raw values are launchd's, read back from a real registration on 2026-08-23:
        // notRegistered(0), enabled(1), requiresApproval(2), notFound(3).
        XCTAssertEqual(PTYHostRegistrationStatus(SMAppService.Status.enabled), .enabled)
        XCTAssertEqual(
            PTYHostRegistrationStatus(SMAppService.Status.requiresApproval),
            .requiresApproval
        )
        XCTAssertEqual(
            PTYHostRegistrationStatus(SMAppService.Status.notRegistered),
            .notRegistered
        )
        XCTAssertEqual(PTYHostRegistrationStatus(SMAppService.Status.notFound), .notFound)

        // `enabled` is a candidate, not an answer: whether a daemon is listening is the socket
        // probe's question. Everything else is a reason the Advanced page and the journal can say
        // out loud, and the two launchd-set ones are distinguishable because only one of them is
        // fixed by registering again.
        XCTAssertNil(PTYHostRegistrationStatus.enabled.unavailability)
        XCTAssertEqual(
            PTYHostRegistrationStatus.requiresApproval.unavailability,
            .requiresApproval
        )
        XCTAssertEqual(PTYHostRegistrationStatus.notRegistered.unavailability, .notRegistered)
        XCTAssertEqual(PTYHostRegistrationStatus.notFound.unavailability, .notFound)
        XCTAssertEqual(PTYHostRegistrationStatus.unknown(99).unavailability, .notRegistered)

        XCTAssertTrue(PTYHostRegistrationStatus.enabled.isRegistered)
        XCTAssertTrue(
            PTYHostRegistrationStatus.requiresApproval.isRegistered,
            "approval pending is held by launchd; another register() is not the fix"
        )
        XCTAssertFalse(PTYHostRegistrationStatus.notRegistered.isRegistered)
        XCTAssertFalse(PTYHostRegistrationStatus.notFound.isRegistered)
        XCTAssertFalse(PTYHostRegistrationStatus.unknown(99).isRegistered)

        XCTAssertEqual(PTYHostRegistrationStatus.unknown(99).token, "unknown.99")
        XCTAssertEqual(PTYHostUnavailability.requiresApproval.token, "requiresApproval")
    }

    // MARK: - Registering

    func testRegisteringAnEnabledLaunchIsIdempotent() {
        let service = RecordingAgentService(status: .enabled)
        let receipts = RecordingReceiptStore()
        receipts.seed(PTYHostRegistrationReceipt(request: request()))
        let registration = makeRegistration(service, receiptStore: receipts.store)

        XCTAssertEqual(
            registration.register(request()),
            .skipped(.alreadySettled),
            "launchd already holds this exact job; the ordinary launch does not register again"
        )
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(receipts.calls.loads, 1)
    }

    func testAnEnabledRegistrationWithoutACurrentReceiptRequiresSafeReplacement() {
        let service = RecordingAgentService(status: .enabled)
        let receipts = RecordingReceiptStore()
        let registration = makeRegistration(service, receiptStore: receipts.store)

        XCTAssertEqual(registration.register(request()), .replacementRequired)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(service.unregistrations, 0, "detection alone never kills the old helper")

        let oldRequest = request(build: "0.9 (99)")
        receipts.seed(PTYHostRegistrationReceipt(request: oldRequest))
        XCTAssertEqual(
            registration.register(request()),
            .replacementRequired,
            "an offline bundle replacement at the same path still changes its generation"
        )
    }

    func testAFirstLaunchRegistersAndReportsWhatLaunchdSaidAfterwards() {
        let service = RecordingAgentService(status: .notFound, afterRegister: .enabled)
        let receipts = RecordingReceiptStore()
        XCTAssertEqual(
            makeRegistration(service, receiptStore: receipts.store).register(request()),
            .registered
        )
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(receipts.saved, PTYHostRegistrationReceipt(request: request()))

        let approving = RecordingAgentService(status: .notFound, afterRegister: .requiresApproval)
        XCTAssertEqual(makeRegistration(approving).register(request()), .awaitingApproval)

        // Nothing threw and the job is still off. A managed Mac may simply refuse, and that is
        // not a failure to report as one.
        let refusing = RecordingAgentService(status: .notFound, afterRegister: .notRegistered)
        XCTAssertEqual(
            makeRegistration(refusing).register(request()),
            .refused(.notRegistered)
        )
    }

    func testApprovalPendingIsNotRegisteredTwice() {
        let service = RecordingAgentService(status: .requiresApproval)
        let receipts = RecordingReceiptStore()
        receipts.seed(PTYHostRegistrationReceipt(request: request()))
        XCTAssertEqual(
            makeRegistration(service, receiptStore: receipts.store).register(request()),
            .awaitingApproval
        )
        XCTAssertEqual(service.registrations, 0)
    }

    func testAStaleApprovalPendingRegistrationUsesTheSafeReplacementPath() {
        let service = RecordingAgentService(
            status: .requiresApproval,
            afterRegister: .requiresApproval
        )
        let receipts = RecordingReceiptStore()
        receipts.seed(PTYHostRegistrationReceipt(request: request(build: "old")))
        let registration = makeRegistration(service, receiptStore: receipts.store)

        XCTAssertEqual(registration.register(request()), .replacementRequired)
        XCTAssertEqual(service.unregistrations, 0, "detection never removes even an idle job")

        XCTAssertEqual(registration.replaceAfterDaemonExited(request()), .awaitingApproval)
        XCTAssertEqual(service.unregistrations, 1)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(receipts.saved, PTYHostRegistrationReceipt(request: request()))
    }

    func testReceiptIdentityChangesWhenTheHelperIsRebuiltInPlace() throws {
        let first = PTYHostRegistrationReceipt(request: request())
        try Data("#!/bin/sh\nprintf rebuilt\n".utf8).write(to: helper)
        let second = PTYHostRegistrationReceipt(request: request())

        XCTAssertNotEqual(first.helper, second.helper)
        XCTAssertNotEqual(first, second, "a same-version in-place rebuild still needs re-register")
    }

    func testLiveReceiptStoreIsAtomicRoundTrippableAndOwnerOnly() throws {
        let directory = scratch.appendingPathComponent("receipt", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directory.path
        )
        let url = directory.appendingPathComponent("registration.json")
        let receipt = PTYHostRegistrationReceipt(request: request())

        try PTYHostRegistrationReceiptStore.live.save(receipt, to: url)

        XCTAssertEqual(PTYHostRegistrationReceiptStore.live.load(from: url), receipt)
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)

        try PTYHostRegistrationReceiptStore.live.remove(at: url)
        XCTAssertNil(PTYHostRegistrationReceiptStore.live.load(from: url))
    }

    func testSafeReplacementUnregistersThenRegistersAndMovesTheReceipt() {
        let service = RecordingAgentService(status: .enabled, afterRegister: .enabled)
        let receipts = RecordingReceiptStore()
        receipts.seed(PTYHostRegistrationReceipt(request: request(build: "old")))
        let registration = makeRegistration(service, receiptStore: receipts.store)

        XCTAssertEqual(registration.register(request()), .replacementRequired)
        XCTAssertEqual(registration.replaceAfterDaemonExited(request()), .registered)
        XCTAssertEqual(service.unregistrations, 1)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(receipts.saved, PTYHostRegistrationReceipt(request: request()))
    }

    func testAThrowingRegisterIsAnOutcomeRatherThanAFailedLaunch() {
        let service = RecordingAgentService(
            status: .notFound,
            registerError: NSError(domain: "SMAppServiceErrorDomain", code: 1)
        )
        XCTAssertEqual(makeRegistration(service).register(request()), .failed(code: 1))
    }

    // MARK: - The refusals

    func testRecoveryModeNeverRegisters() {
        let service = RecordingAgentService(status: .notFound, afterRegister: .enabled)
        let registration = makeRegistration(service)

        XCTAssertEqual(
            registration.register(request(isRecovery: true)),
            .skipped(.recoveryMode)
        )
        XCTAssertEqual(
            registration.unregister(request(isRecovery: true), heldSessions: 0),
            .skipped(.recoveryMode)
        )
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(service.unregistrations, 0)
        XCTAssertEqual(
            service.reads,
            0,
            "recovery does not even ask launchd what it thinks"
        )
    }

    func testAHostedTestBundleNeverRegisters() {
        let service = RecordingAgentService(status: .notFound, afterRegister: .enabled)
        let receipts = RecordingReceiptStore()
        let registration = makeRegistration(service, receiptStore: receipts.store)

        XCTAssertEqual(
            registration.register(request(isHostedTest: true)),
            .skipped(.hostedTest)
        )
        XCTAssertEqual(
            registration.unregister(request(isHostedTest: true), heldSessions: 0),
            .skipped(.hostedTest)
        )
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(service.unregistrations, 0)
        XCTAssertEqual(receipts.calls.loads, 0)
        XCTAssertEqual(receipts.calls.saves, 0)
        XCTAssertEqual(receipts.calls.removes, 0)
    }

    func testTheKeyBeingOffAndAnUnusableRendezvousBothRefuseBeforeLaunchd() {
        let service = RecordingAgentService(status: .notFound, afterRegister: .enabled)
        let registration = makeRegistration(service)

        XCTAssertEqual(
            registration.register(request(isEnabled: false)),
            .skipped(.disabled),
            "the hidden key is decided first and touches nothing"
        )

        // A daemon that cannot bind exits at start-up and KeepAlive restarts it once per
        // ThrottleInterval, forever. Not registering is the right answer to a home directory
        // longer than sockaddr_un can carry.
        XCTAssertEqual(
            registration.register(request(socketPath: nil, socketPathBytes: 140)),
            .skipped(.socketPathTooLong(bytes: 140))
        )

        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(service.reads, 0)
    }

    func testABundleWithNoDaemonInItRegistersNothing() {
        let service = RecordingAgentService(status: .notFound, afterRegister: .enabled)
        let registration = PTYHostRegistration(
            service: service,
            eventLog: EventLog(directory: scratch),
            fileProbe: .nothingIsThere
        )
        XCTAssertEqual(registration.register(request()), .skipped(.helperMissing))
        XCTAssertEqual(service.registrations, 0)
    }

    // MARK: - Unregistering

    func testUnregisteringLeavesTheAppOnTheInProcessPath() {
        let service = RecordingAgentService(status: .enabled)
        let registration = makeRegistration(service)

        XCTAssertEqual(registration.unregister(request(), heldSessions: 0), .unregistered)
        XCTAssertEqual(service.unregistrations, 1)

        // What the app then sees: launchd knows the label and it is off, which is a reason the
        // journal can name — and one that resolves to the same in-process `forkpty` every other
        // unavailability resolves to.
        XCTAssertEqual(registration.unavailability, .notRegistered)
        XCTAssertFalse(PTYHostAvailability.unavailable(.notRegistered).isAvailable)

        // And with the key off, the availability decision refuses before it can even ask for a
        // daemon: an unreachable probe would trap if anything connected.
        XCTAssertEqual(
            PTYHostAvailability.resolve(
                decision(isEnabled: false),
                probing: .unreachable()
            ),
            .unavailable(.disabled)
        )
    }

    func testUnregisteringIsSkippedWhenLaunchdIsNotHoldingTheJob() {
        let service = RecordingAgentService(status: .notFound)
        XCTAssertEqual(
            makeRegistration(service).unregister(request(), heldSessions: nil),
            .skipped(.alreadySettled)
        )
        XCTAssertEqual(service.unregistrations, 0)
    }

    func testADaemonHoldingSessionsKeepsItsRegistration() {
        let service = RecordingAgentService(status: .enabled)
        let registration = makeRegistration(service)

        XCTAssertEqual(
            registration.unregister(request(), heldSessions: 2),
            .leftForRunningSessions(2),
            "unregister() kills the running helper, and the helper is holding someone's agents"
        )
        XCTAssertEqual(service.unregistrations, 0)
    }

    func testTheRemovalDecisionTreatsSilenceAsUncertainty() {
        XCTAssertEqual(
            PTYHostRegistration.removalDecision(heldSessions: nil),
            .leaveUnanswered,
            "a retiring daemon has no socket but may still hold live sessions"
        )
        XCTAssertEqual(PTYHostRegistration.removalDecision(heldSessions: 0), .unregister)
        XCTAssertEqual(
            PTYHostRegistration.removalDecision(heldSessions: 1),
            .leave(heldSessions: 1)
        )
        XCTAssertEqual(
            PTYHostRegistration.removalDecision(heldSessions: 40),
            .leave(heldSessions: 40)
        )
    }

    // MARK: - The upgrade policy

    func testTheSameBuildIsLeftAloneHoweverIdleItIs() {
        for held in [0, 1, 8] {
            XCTAssertEqual(
                PTYHostUpgradePolicy.decide(
                    peerBuild: "1.0 (412)",
                    ownBuild: "1.0 (412)",
                    compatibility: .compatible,
                    activeSessions: held
                ),
                .leave(.sameBuild),
                "replacing a process with its own image buys nothing"
            )
        }
    }

    func testAStaleRegistrationRefreshesEvenWhenTheDaemonGenerationMatches() {
        XCTAssertEqual(
            PTYHostUpgradePolicy.decide(
                peerBuild: "1.0 (412)",
                ownBuild: "1.0 (412)",
                compatibility: .compatible,
                activeSessions: 0,
                requiresRegistrationRefresh: true
            ),
            .retire
        )
        XCTAssertEqual(
            PTYHostUpgradePolicy.decide(
                peerBuild: "1.0 (412)",
                ownBuild: "1.0 (412)",
                compatibility: .compatible,
                activeSessions: 31,
                requiresRegistrationRefresh: true
            ),
            .leave(.holdsSessions(31)),
            "registration provenance never outranks live work"
        )
    }

    func testAnIdleStaleDaemonIsRetiredAndABusyOneIsNot() {
        XCTAssertEqual(
            PTYHostUpgradePolicy.decide(
                peerBuild: "1.0 (411)",
                ownBuild: "1.0 (412)",
                compatibility: .compatible,
                activeSessions: 0
            ),
            .retire,
            "launchd binds the registration to the path, so nothing else will end the old binary"
        )
        XCTAssertEqual(
            PTYHostUpgradePolicy.decide(
                peerBuild: "1.0 (411)",
                ownBuild: "1.0 (412)",
                compatibility: .compatible,
                activeSessions: 3
            ),
            .leave(.holdsSessions(3))
        )
    }

    func testAnIncompatiblePeerIsRefusedAndNeverRetiredByThisPolicy() {
        // `peerTooOld` was already sent `retire` by the handshake; saying it again here would be
        // a second retirement. `selfTooOld` must never be retired at all — that would take
        // working agents down in order to install an older host.
        for compatibility in [PTYHostCompatibility.peerTooOld, .selfTooOld] {
            for held in [0, 5] {
                let decision = PTYHostUpgradePolicy.decide(
                    peerBuild: "9.9 (999)",
                    ownBuild: "1.0 (412)",
                    compatibility: compatibility,
                    activeSessions: held
                )
                XCTAssertEqual(decision, .refuse(compatibility))
                XCTAssertFalse(decision.retires)
            }
        }
    }

    func testTheDecisionTokensAreCausesRatherThanSentences() {
        XCTAssertEqual(PTYHostUpgradeDecision.retire.token, "retire")
        XCTAssertEqual(PTYHostUpgradeDecision.leave(.sameBuild).token, "leave.sameBuild")
        XCTAssertEqual(
            PTYHostUpgradeDecision.leave(.holdsSessions(2)).token,
            "leave.holdsSessions"
        )
        XCTAssertEqual(
            PTYHostUpgradeDecision.refuse(.selfTooOld).token,
            "refuse.selfTooOld"
        )
        XCTAssertEqual(PTYHostRegistrationOutcome.registered.token, "registered")
        XCTAssertEqual(
            PTYHostRegistrationOutcome.skipped(.recoveryMode).token,
            "skipped.recoveryMode"
        )
    }

    // MARK: - Eventual upgrade retirement

    func testABusyStaleDaemonIsRecheckedUntilItsLastLiveSessionEnds() {
        let recording = RecordingUpgradeProbe([
            .leave(.holdsSessions(2)),
            .leave(.holdsSessions(1)),
            .retire
        ])
        let monitor = PTYHostUpgradeMonitor(probe: recording.probe)
        let request = PTYHostUpgradeRequest(
            socketPath: "/tmp/offline-upgrade.sock",
            ownBuild: "2.0 (200)"
        )

        monitor.begin(request)
        monitor.hostMayHaveDrained()
        monitor.hostMayHaveDrained()
        monitor.hostMayHaveDrained()

        XCTAssertEqual(recording.requests, [request, request, request])
    }

    func testATransientSilenceDoesNotForgetAnAlreadyObservedStaleDaemon() {
        let recording = RecordingUpgradeProbe([
            .leave(.holdsSessions(1)),
            nil,
            .retire
        ])
        let monitor = PTYHostUpgradeMonitor(probe: recording.probe)
        let request = PTYHostUpgradeRequest(socketPath: "/tmp/ptyd.sock", ownBuild: "new")

        monitor.begin(request)
        monitor.hostMayHaveDrained()
        monitor.hostMayHaveDrained()

        XCTAssertEqual(recording.requests.count, 3)
    }

    func testTheFallbackRetiresDetachedWorkWhoseExitTheAppCouldNotObserve() {
        let recording = RecordingUpgradeProbe([
            .leave(.holdsSessions(1)),
            .retire
        ])
        let scheduler = RecordingUpgradeRetryScheduler()
        let monitor = PTYHostUpgradeMonitor(
            probe: recording.probe,
            scheduleRetry: scheduler.schedule
        )
        let request = PTYHostUpgradeRequest(socketPath: "/tmp/detached.sock", ownBuild: "new")

        monitor.begin(request)
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.runNext()

        XCTAssertEqual(recording.requests, [request, request])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testFallbackSilenceReschedulesButSessionEdgesDoNotMultiplyTimers() {
        let recording = RecordingUpgradeProbe([
            .leave(.holdsSessions(2)),
            .leave(.holdsSessions(1)),
            nil,
            .retire
        ])
        let scheduler = RecordingUpgradeRetryScheduler()
        let monitor = PTYHostUpgradeMonitor(
            probe: recording.probe,
            scheduleRetry: scheduler.schedule
        )

        monitor.begin(PTYHostUpgradeRequest(socketPath: "/tmp/ptyd.sock", ownBuild: "new"))
        monitor.hostMayHaveDrained()
        XCTAssertEqual(scheduler.pendingCount, 1, "the exit edge reuses the existing backstop")

        scheduler.runNext()
        XCTAssertEqual(scheduler.pendingCount, 1, "transient silence keeps one backstop alive")

        scheduler.runNext()
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(recording.requests.count, 4)
    }

    func testASettledOrCancelledUpgradeIgnoresLaterSessionEndings() {
        for first in [
            PTYHostUpgradeDecision.leave(.sameBuild),
            .retire,
            .refuse(.selfTooOld)
        ] {
            let recording = RecordingUpgradeProbe([first])
            let monitor = PTYHostUpgradeMonitor(probe: recording.probe)
            monitor.begin(PTYHostUpgradeRequest(socketPath: "/tmp/ptyd.sock", ownBuild: "new"))
            monitor.hostMayHaveDrained()
            XCTAssertEqual(recording.requests.count, 1)
        }

        let recording = RecordingUpgradeProbe([.leave(.holdsSessions(1)), .retire])
        let scheduler = RecordingUpgradeRetryScheduler()
        let monitor = PTYHostUpgradeMonitor(
            probe: recording.probe,
            scheduleRetry: scheduler.schedule
        )
        monitor.begin(PTYHostUpgradeRequest(socketPath: "/tmp/ptyd.sock", ownBuild: "new"))
        monitor.cancel()
        monitor.hostMayHaveDrained()
        scheduler.runNext()
        XCTAssertEqual(recording.requests.count, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testReenablingAfterCancellationStartsAFreshUpgradeAndReusesTheSafeTimer() {
        let recording = RecordingUpgradeProbe([
            .leave(.holdsSessions(1)),
            .leave(.holdsSessions(1)),
            .retire
        ])
        let scheduler = RecordingUpgradeRetryScheduler()
        let monitor = PTYHostUpgradeMonitor(
            probe: recording.probe,
            scheduleRetry: scheduler.schedule
        )
        let request = PTYHostUpgradeRequest(socketPath: "/tmp/ptyd.sock", ownBuild: "new")

        monitor.begin(request)
        monitor.cancel()
        monitor.begin(request)
        XCTAssertEqual(recording.requests.count, 2, "re-enabling surveys immediately")
        XCTAssertEqual(scheduler.pendingCount, 1, "the old safe timer covers the new hold")

        scheduler.runNext()
        XCTAssertEqual(recording.requests.count, 3)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testAnInitialSilenceDoesNotCreateAPermanentUpgradePoll() {
        let recording = RecordingUpgradeProbe([nil, .retire])
        let monitor = PTYHostUpgradeMonitor(probe: recording.probe)
        monitor.begin(PTYHostUpgradeRequest(socketPath: "/tmp/absent.sock", ownBuild: "new"))
        monitor.hostMayHaveDrained()

        XCTAssertEqual(recording.requests.count, 1)
    }

    func testRegistrationRefreshWaitsForBusyWorkThenRunsAfterConfirmedRetirement() {
        let recording = RecordingUpgradeProbe(progress: [
            .settled(.leave(.holdsSessions(31))),
            .retirementConfirmed
        ])
        let refresh = RecordingRegistrationRefresh([true])
        let monitor = PTYHostUpgradeMonitor(
            probe: recording.probe,
            refreshRegistration: refresh.callback
        )
        let registrationRequest = request()
        let upgrade = PTYHostUpgradeRequest(
            socketPath: "/tmp/stale-derived-data.sock",
            ownBuild: "new",
            registrationRequest: registrationRequest
        )

        monitor.begin(upgrade)
        XCTAssertEqual(refresh.requests.count, 0, "31 live sessions keep the old job untouched")
        monitor.hostMayHaveDrained()
        XCTAssertEqual(refresh.requests, [registrationRequest])
        monitor.hostMayHaveDrained()
        XCTAssertEqual(refresh.requests.count, 1, "a completed handoff is exactly once")
    }

    func testANewSessionCannotKeepAStaleGenerationBusyForever() {
        let recording = RecordingUpgradeProbe(progress: [
            .settled(.leave(.holdsSessions(1))),
            .retirementConfirmed
        ])
        let admission = PTYHostNewSessionAdmission()
        let monitor = PTYHostUpgradeMonitor(
            probe: recording.probe,
            setNewSessionAdmission: { admission.resolve($0) }
        )

        monitor.begin(PTYHostUpgradeRequest(socketPath: "/tmp/stale.sock", ownBuild: "new"))
        XCTAssertFalse(
            admission.current.permitsHostedSpawn,
            "existing sessions may drain, but a new spawn must not extend the stale generation"
        )

        monitor.hostMayHaveDrained()
        XCTAssertTrue(admission.current.permitsHostedSpawn)
    }

    /// "Nobody has asked yet" and "we asked and the answer was no" are different refusals, and
    /// only the first is `registrationRefreshing`.
    ///
    /// Measured on 2026-08-26: a compatible daemon of another build held thirty agents all day,
    /// and every new conversation was journalled as running in-process because a *registration*
    /// was refreshing. Nothing was. A cause that names the wrong condition sends the next person
    /// to look in the wrong subsystem.
    func testTheAdmissionGateSaysWhichOfItsTwoRefusalsThisIs() {
        let recording = RecordingUpgradeProbe(progress: [
            .settled(.leave(.holdsSessions(1)))
        ])
        let admission = PTYHostNewSessionAdmission()
        let monitor = PTYHostUpgradeMonitor(
            probe: recording.probe,
            setNewSessionAdmission: { admission.resolve($0) }
        )

        XCTAssertEqual(
            PTYHostNewSessionAdmission.State.unresolved.token,
            PTYHostUnavailability.registrationRefreshing.token
        )
        XCTAssertEqual(PTYHostNewSessionAdmission.State.withheld.token, "upgradePending")

        monitor.begin(PTYHostUpgradeRequest(socketPath: "/tmp/stale.sock", ownBuild: "new"))

        XCTAssertEqual(
            admission.current,
            .withheld,
            "the survey answered; the refusal is an upgrade waiting for work to drain"
        )
    }

    /// A survey that reaches the decision it reached last time is not news.
    ///
    /// The 30-second backstop wrote `PTY host connected` and `PTY host upgrade decision` every
    /// tick for the whole life of an app whose daemon was never going to be free — 5,760 lines a
    /// day saying `leave.holdsSessions`, which is how a journal stops being read.
    func testARecheckThatChangesNothingIsNotJournalledAgain() {
        let recording = RecordingUpgradeProbe(progress: [
            .settled(.leave(.holdsSessions(2))),
            .settled(.leave(.holdsSessions(2))),
            .settled(.leave(.holdsSessions(1)))
        ])
        let monitor = PTYHostUpgradeMonitor(probe: recording.probe)

        monitor.begin(PTYHostUpgradeRequest(socketPath: "/tmp/stale.sock", ownBuild: "new"))
        monitor.hostMayHaveDrained()
        monitor.hostMayHaveDrained()

        XCTAssertEqual(
            recording.journalledDecisions,
            [.leave(.holdsSessions(2)), .leave(.holdsSessions(1))],
            "the repeat says nothing new; the count moving does"
        )
    }

    /// The backstop doubles towards a bound rather than polling at a fixed interval.
    ///
    /// It exists for a *detached* child this launch could not adopt and therefore cannot observe
    /// ending. Thirty seconds is prompt when a drain might be seconds away and a poll once it has
    /// plainly not been; an ending posts `PTYHostMayHaveDrained` and puts it back to prompt.
    func testTheBackstopBacksOffAndAnEndingMakesItPromptAgain() {
        let recording = RecordingUpgradeProbe(progress: Array(
            repeating: .settled(.leave(.holdsSessions(1))),
            count: 8
        ))
        let scheduler = RecordingUpgradeRetryScheduler()
        let monitor = PTYHostUpgradeMonitor(
            probe: recording.probe,
            scheduleRetry: scheduler.schedule
        )

        monitor.begin(PTYHostUpgradeRequest(socketPath: "/tmp/stale.sock", ownBuild: "new"))
        for _ in 0..<4 { scheduler.runNext() }

        XCTAssertEqual(
            scheduler.delays,
            [30, 60, 120, 240, 300].map(TimeInterval.init),
            "a busy daemon costs fewer connects the longer it stays busy"
        )

        monitor.hostMayHaveDrained()
        scheduler.runNext()

        XCTAssertEqual(
            scheduler.delays.last,
            PTYHostRegistrationDefaults.upgradeRetryInterval,
            "an ending is evidence the count moved, so the next backstop is prompt again"
        )
    }

    func testAStaleRegistrationWithNoProcessIsReclaimedAfterInitialSilence() {
        let recording = RecordingUpgradeProbe(progress: [.noAnswer])
        let refresh = RecordingRegistrationRefresh([true])
        let monitor = PTYHostUpgradeMonitor(
            probe: recording.probe,
            registeredProcessProbe: PTYHostRegisteredProcessProbe { .notRunning },
            refreshRegistration: refresh.callback
        )
        let registrationRequest = request()

        monitor.begin(PTYHostUpgradeRequest(
            socketPath: "/tmp/deleted-derived-data.sock",
            ownBuild: "new",
            registrationRequest: registrationRequest
        ))

        XCTAssertEqual(refresh.requests, [registrationRequest])
    }

    func testLaunchctlProcessAnswersAreParsedConservatively() {
        let identity = PTYHostProcessIdentity(
            pid: 5229,
            startTime: ProcessStartTime(seconds: 1_777_000_000, microseconds: 42)
        )
        let kernel = PTYHostKernelProcessProbe(
            identify: { $0 == identity.pid ? identity : nil },
            matches: { $0 == identity }
        )

        XCTAssertEqual(
            PTYHostRegisteredProcessProbe.interpret(
                output: "state = running\n\tpid = 5229\n",
                terminationStatus: 0,
                kernel: kernel
            ),
            .running(identity)
        )
        XCTAssertEqual(
            PTYHostRegisteredProcessProbe.interpret(
                output: "state = waiting\n",
                terminationStatus: 0,
                kernel: kernel
            ),
            .notRunning
        )
        XCTAssertEqual(
            PTYHostRegisteredProcessProbe.interpret(
                output: "state = running\n",
                terminationStatus: 0,
                kernel: kernel
            ),
            .unknown,
            "a truncated running answer is not absence proof"
        )
        XCTAssertEqual(
            PTYHostRegisteredProcessProbe.interpret(
                output: "unexpected output\n",
                terminationStatus: 0,
                kernel: kernel
            ),
            .unknown,
            "changed-format output is not permission to unregister"
        )
        XCTAssertEqual(
            PTYHostRegisteredProcessProbe.interpret(
                output: "Could not find service codes.threading.ptyd\n",
                terminationStatus: 113,
                kernel: kernel
            ),
            .notRunning
        )
        XCTAssertEqual(
            PTYHostRegisteredProcessProbe.interpret(
                output: "pid = 5229\npid = 5230\n",
                terminationStatus: 0,
                kernel: kernel
            ),
            .unknown,
            "two process answers are never absence proof"
        )
        XCTAssertEqual(
            PTYHostRegisteredProcessProbe.interpret(
                output: "pid = -1\n",
                terminationStatus: 0,
                kernel: kernel
            ),
            .unknown
        )
        XCTAssertEqual(
            PTYHostRegisteredProcessProbe.interpret(
                output: "permission denied\n",
                terminationStatus: 1,
                kernel: kernel
            ),
            .unknown
        )
    }

    func testASilentRegisteredProcessIsNeverKilledAndRefreshesOnlyAfterThatProcessExits() {
        let identity = PTYHostProcessIdentity(
            pid: 5229,
            startTime: ProcessStartTime(seconds: 1_777_000_000, microseconds: 42)
        )
        let recording = RecordingUpgradeProbe(progress: [.noAnswer, .noAnswer, .noAnswer])
        let kernel = RecordingKernelProcessProbe(matches: [true, false])
        let refresh = RecordingRegistrationRefresh([true])
        let monitor = PTYHostUpgradeMonitor(
            probe: recording.probe,
            registeredProcessProbe: PTYHostRegisteredProcessProbe { .running(identity) },
            kernelProcessProbe: kernel.probe,
            refreshRegistration: refresh.callback
        )
        let upgrade = PTYHostUpgradeRequest(
            socketPath: "/tmp/retiring.sock",
            ownBuild: "new",
            registrationRequest: request()
        )

        monitor.begin(upgrade)
        monitor.hostMayHaveDrained()
        XCTAssertEqual(refresh.requests.count, 0, "a live pid/start-time pair is left to drain")
        monitor.hostMayHaveDrained()
        XCTAssertEqual(refresh.requests.count, 1)
        XCTAssertEqual(kernel.identities, [identity, identity])
    }

    func testARetirementRaceTracksTheExactDaemonUntilTheRacedSessionEnds() {
        let identity = PTYHostProcessIdentity(
            pid: 900,
            startTime: ProcessStartTime(seconds: 1_777_000_001, microseconds: 7)
        )
        let recording = RecordingUpgradeProbe(progress: [
            .retirementPending(identity),
            .noAnswer
        ])
        let kernel = RecordingKernelProcessProbe(matches: [false])
        let refresh = RecordingRegistrationRefresh([true])
        let monitor = PTYHostUpgradeMonitor(
            probe: recording.probe,
            kernelProcessProbe: kernel.probe,
            refreshRegistration: refresh.callback
        )

        monitor.begin(PTYHostUpgradeRequest(
            socketPath: "/tmp/raced.sock",
            ownBuild: "new",
            registrationRequest: request()
        ))
        XCTAssertEqual(refresh.requests.count, 0)
        monitor.hostMayHaveDrained()
        XCTAssertEqual(refresh.requests.count, 1)
    }

    func testARegistrationRefreshFailureKeepsOneBoundedRetry() {
        let recording = RecordingUpgradeProbe(progress: [.noAnswer, .noAnswer])
        let scheduler = RecordingUpgradeRetryScheduler()
        let refresh = RecordingRegistrationRefresh([false, true])
        let admission = PTYHostNewSessionAdmission()
        let monitor = PTYHostUpgradeMonitor(
            probe: recording.probe,
            scheduleRetry: scheduler.schedule,
            registeredProcessProbe: PTYHostRegisteredProcessProbe { .notRunning },
            refreshRegistration: refresh.callback,
            setNewSessionAdmission: { admission.resolve($0) }
        )

        monitor.begin(PTYHostUpgradeRequest(
            socketPath: "/tmp/registration-retry.sock",
            ownBuild: "new",
            registrationRequest: request()
        ))
        XCTAssertEqual(refresh.requests.count, 1)
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertFalse(admission.current.permitsHostedSpawn)

        scheduler.runNext()
        XCTAssertEqual(refresh.requests.count, 2)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertTrue(admission.current.permitsHostedSpawn)
    }

    // MARK: - The shipped plist

    func testTheBundleShipsTheLaunchAgentPlistTheRegistrationAddresses() throws {
        let url = Bundle.main.bundleURL
            .appendingPathComponent(
                PTYHostRegistrationDefaults.launchAgentsDirectoryPath,
                isDirectory: true
            )
            .appendingPathComponent(PTYHostRegistrationDefaults.plistName, isDirectory: false)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            """
            \(PTYHostRegistrationDefaults.plistName) is not in Contents/Library/LaunchAgents. \
            SMAppService.agent(plistName:) reads the file from there, so a missing copy phase is \
            a registration that cannot happen rather than one that fails.
            """
        )

        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url),
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(
            plist["Label"] as? String,
            PTYHostRegistrationDefaults.label,
            "the label launchd uses and the file SMAppService reads have to name one service"
        )

        // BundleProgram rather than Program: bundle-relative, so the autoinstall swap and any
        // future Sparkle update leave the registration valid rather than pointing at a path that
        // no longer exists.
        let program = try XCTUnwrap(plist["BundleProgram"] as? String)
        XCTAssertEqual(
            program,
            "\(PTYHostDefaults.helpersDirectoryPath)/\(PTYHostDefaults.helperName)"
        )
        XCTAssertFalse(program.hasPrefix("/"), "an absolute program would not survive a swap")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(
                atPath: Bundle.main.bundleURL.appendingPathComponent(program).path
            ),
            "the plist names a helper the copy phase must have embedded"
        )

        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            [program, PTYHostDefaultLocations.defaultLocationsArgument],
            """
            launchd passes ProgramArguments to execvp verbatim and expands no `~`, so the plist \
            asks the daemon to derive its own paths instead of naming a home directory it cannot \
            know.
            """
        )

        XCTAssertEqual(plist["KeepAlive"] as? Bool, true, "KeepAlive is how an upgrade lands")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, false)
        XCTAssertEqual(plist["ThrottleInterval"] as? Int, 10)
        XCTAssertEqual(plist["ExitTimeOut"] as? Int, 10)
        XCTAssertEqual(
            plist["ProcessType"] as? String,
            "Interactive",
            "a process holding someone's working agents must not be filed as background"
        )
        XCTAssertEqual(
            plist["AssociatedBundleIdentifiers"] as? [String],
            [Bundle.main.bundleIdentifier ?? "codes.threading"],
            "what makes the Login Items row read as Threading rather than a loose helper"
        )
        XCTAssertNil(
            plist["StandardOutPath"],
            "the daemon keeps its own pruned journal in pty/; a launchd redirect would be a "
                + "second file no retention rule covers"
        )
        XCTAssertNil(plist["StandardErrorPath"])
    }

    func testTheDaemonsDerivedPathsAreTheOnesTheAppLooksAt() throws {
        // The flag in the plist is only correct if both processes land in the same place. The app
        // composes from `AppDataLocations`; the daemon derives from the package's names; nothing
        // links the two but this assertion.
        // The app takes the directory and socket names straight from the package, so those two
        // cannot drift. The application directory's name is the one genuine second copy — a
        // Foundation-only package cannot see `ProjectIconDefaults` without being able to see the
        // rest of the app — and this is where a divergence fails, rather than at the first launch
        // nobody could connect.
        XCTAssertEqual(
            PTYHostDefaultLocations.applicationDirectoryName,
            ProjectIconDefaults.applicationDirectoryName
        )

        let derived = try XCTUnwrap(PTYHostDefaultLocations.directory())
        XCTAssertEqual(
            derived.standardizedFileURL,
            AppDataLocations.supportDirectory
                .appendingPathComponent(PTYHostDefaults.directoryName, isDirectory: true)
                .standardizedFileURL,
            """
            The daemon would bind a rendezvous the app is not looking at. Note this compares the \
            *production* location on both sides: `PTYHostLocation.directory` redirects under a \
            hosted test bundle and the daemon started by launchd never does.
            """
        )
        XCTAssertEqual(
            try XCTUnwrap(PTYHostDefaultLocations.socketPath()),
            derived.appendingPathComponent(PTYHostDefaults.socketFileName).path
        )
    }

    // MARK: - The coordinator

    @MainActor
    func testTheCoordinatorTouchesLaunchdFromNoTestHost() {
        let service = RecordingAgentService(status: .notFound, afterRegister: .enabled)
        let coordinator = PTYHostRegistrationCoordinator(
            registration: PTYHostRegistration(
                service: service,
                eventLog: EventLog(directory: scratch),
                fileProbe: .everythingIsThere
            ),
            eventLog: EventLog(directory: scratch)
        )
        let suiteName = "PTYHostRegistrationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not make a scratch defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.ptyHostEnabled = true

        coordinator.start(settings: settings)

        XCTAssertTrue(StateManager.isHostedTest, "this suite is hosted in the shipping app")
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(
            service.reads,
            0,
            "the hosted-test guard is ahead of every call, including the status read"
        )
    }

    // MARK: - Helpers

    private func makeRegistration(
        _ service: RecordingAgentService,
        receiptStore: PTYHostRegistrationReceiptStore = .live
    ) -> PTYHostRegistration {
        PTYHostRegistration(
            service: service,
            eventLog: EventLog(directory: scratch),
            fileProbe: .live,
            receiptStore: receiptStore
        )
    }

    private func decision(
        isEnabled: Bool = true,
        socketPath: String? = "/tmp/ptyd.sock",
        socketPathBytes: Int = 16,
        build: String = "1.0 (412)"
    ) -> PTYHostDecision {
        PTYHostDecision(
            isEnabled: isEnabled,
            helperURL: helper,
            socketPath: socketPath,
            socketPathBytes: socketPathBytes,
            build: build
        )
    }

    private func request(
        isEnabled: Bool = true,
        socketPath: String? = "/tmp/ptyd.sock",
        socketPathBytes: Int = 16,
        build: String = "1.0 (412)",
        isRecovery: Bool = false,
        isHostedTest: Bool = false
    ) -> PTYHostRegistrationRequest {
        PTYHostRegistrationRequest(
            decision: decision(
                isEnabled: isEnabled,
                socketPath: socketPath,
                socketPathBytes: socketPathBytes,
                build: build
            ),
            isRecovery: isRecovery,
            isHostedTest: isHostedTest,
            receiptURL: scratch.appendingPathComponent("registration.json")
        )
    }
}

/// A synchronous upgrade survey script. `PTYHostUpgradeMonitor` is deliberately queue-confined,
/// so the fixture can make every state transition deterministic without sleeps or a daemon.
private final class RecordingUpgradeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: [PTYHostUpgradeProgress]
    private var requestStorage: [PTYHostUpgradeRequest] = []
    private var journalled: [PTYHostUpgradeDecision] = []

    init(_ decisions: [PTYHostUpgradeDecision?]) {
        self.progress = decisions.map { decision in
            guard let decision else { return .noAnswer }
            return decision == .retire ? .retirementConfirmed : .settled(decision)
        }
    }

    init(progress: [PTYHostUpgradeProgress]) {
        self.progress = progress
    }

    var probe: PTYHostUpgradeProbe {
        PTYHostUpgradeProbe { [weak self] request, journalsDecision in
            guard let self else { return .noAnswer }
            let progress = self.answer(request)
            if case .settled(let decision) = progress, journalsDecision(decision) {
                self.lock.lock()
                self.journalled.append(decision)
                self.lock.unlock()
            }
            return progress
        }
    }

    /// The decisions the monitor said were worth a journal line, in order.
    var journalledDecisions: [PTYHostUpgradeDecision] {
        lock.lock()
        defer { lock.unlock() }
        return journalled
    }

    var requests: [PTYHostUpgradeRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    private func answer(_ request: PTYHostUpgradeRequest) -> PTYHostUpgradeProgress {
        lock.lock()
        defer { lock.unlock() }
        requestStorage.append(request)
        guard !progress.isEmpty else {
            XCTFail("upgrade monitor performed an unexpected extra survey")
            return .noAnswer
        }
        return progress.removeFirst()
    }
}

private final class RecordingKernelProcessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private var identityStorage: [PTYHostProcessIdentity] = []

    init(matches: [Bool]) { answers = matches }

    var probe: PTYHostKernelProcessProbe {
        PTYHostKernelProcessProbe(
            identify: { _ in nil },
            matches: { [weak self] identity in self?.answer(identity) ?? true }
        )
    }

    var identities: [PTYHostProcessIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return identityStorage
    }

    private func answer(_ identity: PTYHostProcessIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        identityStorage.append(identity)
        guard !answers.isEmpty else {
            XCTFail("kernel process probe performed an unexpected extra match")
            return true
        }
        return answers.removeFirst()
    }
}

private final class RecordingRegistrationRefresh: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private var requestStorage: [PTYHostRegistrationRequest] = []

    init(_ answers: [Bool]) { self.answers = answers }

    var callback: @Sendable (PTYHostRegistrationRequest) -> Bool {
        { [weak self] request in self?.answer(request) ?? false }
    }

    var requests: [PTYHostRegistrationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    private func answer(_ request: PTYHostRegistrationRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        requestStorage.append(request)
        guard !answers.isEmpty else {
            XCTFail("registration refresh performed an unexpected extra attempt")
            return false
        }
        return answers.removeFirst()
    }
}

/// A deterministic substitute for the registration queue's delayed retry.
private final class RecordingUpgradeRetryScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@Sendable () -> Void] = []
    private var delayStorage: [TimeInterval] = []

    var schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void {
        { [weak self] delay, work in
            guard let self else { return }
            self.lock.lock()
            self.work.append(work)
            self.delayStorage.append(delay)
            self.lock.unlock()
        }
    }

    /// Every delay the monitor asked for, in order. The backstop doubles, so a busy stale daemon
    /// costs a launch fewer and fewer connects rather than two a minute forever.
    var delays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return delayStorage
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return work.count
    }

    func runNext() {
        lock.lock()
        let next = work.isEmpty ? nil : work.removeFirst()
        lock.unlock()
        next?()
    }
}
