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
        let registration = makeRegistration(service)

        XCTAssertEqual(
            registration.register(request()),
            .skipped(.alreadySettled),
            "launchd already holds the job; the ordinary launch costs one status read"
        )
        XCTAssertEqual(service.registrations, 0)
    }

    func testAFirstLaunchRegistersAndReportsWhatLaunchdSaidAfterwards() {
        let service = RecordingAgentService(status: .notFound, afterRegister: .enabled)
        XCTAssertEqual(makeRegistration(service).register(request()), .registered)
        XCTAssertEqual(service.registrations, 1)

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
        let registration = makeRegistration(service)

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

    func testTheRemovalDecisionTreatsSilenceAsNothingHeld() {
        XCTAssertEqual(PTYHostRegistration.removalDecision(heldSessions: nil), .unregister)
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
                    heldSessions: held
                ),
                .leave(.sameBuild),
                "replacing a process with its own image buys nothing"
            )
        }
    }

    func testAnIdleStaleDaemonIsRetiredAndABusyOneIsNot() {
        XCTAssertEqual(
            PTYHostUpgradePolicy.decide(
                peerBuild: "1.0 (411)",
                ownBuild: "1.0 (412)",
                compatibility: .compatible,
                heldSessions: 0
            ),
            .retire,
            "launchd binds the registration to the path, so nothing else will end the old binary"
        )
        XCTAssertEqual(
            PTYHostUpgradePolicy.decide(
                peerBuild: "1.0 (411)",
                ownBuild: "1.0 (412)",
                compatibility: .compatible,
                heldSessions: 3
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
                    heldSessions: held
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

    private func makeRegistration(_ service: RecordingAgentService) -> PTYHostRegistration {
        PTYHostRegistration(
            service: service,
            eventLog: EventLog(directory: scratch),
            fileProbe: .live
        )
    }

    private func decision(
        isEnabled: Bool = true,
        socketPath: String? = "/tmp/ptyd.sock",
        socketPathBytes: Int = 16
    ) -> PTYHostDecision {
        PTYHostDecision(
            isEnabled: isEnabled,
            helperURL: helper,
            socketPath: socketPath,
            socketPathBytes: socketPathBytes,
            build: "1.0 (412)"
        )
    }

    private func request(
        isEnabled: Bool = true,
        socketPath: String? = "/tmp/ptyd.sock",
        socketPathBytes: Int = 16,
        isRecovery: Bool = false,
        isHostedTest: Bool = false
    ) -> PTYHostRegistrationRequest {
        PTYHostRegistrationRequest(
            decision: decision(
                isEnabled: isEnabled,
                socketPath: socketPath,
                socketPathBytes: socketPathBytes
            ),
            isRecovery: isRecovery,
            isHostedTest: isHostedTest
        )
    }
}
