import Foundation
import ThreadingPTYHostKit
import XCTest
@testable import Threading

/// A probe that counts, so "this branch was decided without asking a daemon" is an assertion
/// rather than a hope.
private final class CountingProbe: @unchecked Sendable {

    private let lock = NSLock()
    private var callCount = 0
    private var lastRequestStorage: PTYHostProbeRequest?
    private let outcome: PTYHostProbeOutcome

    init(answering outcome: PTYHostProbeOutcome) {
        self.outcome = outcome
    }

    var probe: PTYHostProbe {
        PTYHostProbe { [self] request in
            lock.lock()
            callCount += 1
            lastRequestStorage = request
            lock.unlock()
            return outcome
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    var lastRequest: PTYHostProbeRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequestStorage
    }
}

/// Every way the background PTY host can be unavailable, forced without a daemon.
///
/// The point of the split between `PTYHostDecision` and `PTYHostAvailability.resolve` is exactly
/// this file: a degrade path nobody can reach in a test is a degrade path nobody has checked, and
/// four of the six here would otherwise need a daemon arranged to be absent in a specific way.
final class PTYHostAvailabilityTests: XCTestCase {

    // MARK: - Fixtures

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PTYHostAvailabilityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    private var missingHelper: URL {
        scratch.appendingPathComponent("Nowhere.app/Contents/Helpers/threading-ptyd")
    }

    private func presentHelper() throws -> URL {
        let helper = scratch
            .appendingPathComponent("Present.app/Contents/Helpers", isDirectory: true)
            .appendingPathComponent(PTYHostDefaults.helperName)
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        return helper
    }

    private func decision(
        isEnabled: Bool,
        helperURL: URL,
        socketPath: String?,
        socketPathBytes: Int = 60
    ) -> PTYHostDecision {
        PTYHostDecision(
            isEnabled: isEnabled,
            helperURL: helperURL,
            socketPath: socketPath,
            socketPathBytes: socketPathBytes,
            build: "1.2.3 (456)"
        )
    }

    // MARK: - The branches that answer without a peer

    func testTheSettingBeingOffIsDecidedBeforeAnythingElse() {
        let probe = CountingProbe(answering: .ready)

        // Everything else is *also* wrong here — no addressable socket, no helper — and the
        // answer is still `disabled`. That is what makes the ordering claim testable: the cheap
        // answer is the first one, so a launch with the feature off costs a defaults read.
        let availability = PTYHostAvailability.resolve(
            decision(isEnabled: false, helperURL: missingHelper, socketPath: nil),
            probing: probe.probe
        )

        XCTAssertEqual(availability, .unavailable(.disabled))
        XCTAssertEqual(probe.count, 0, "a disabled host must not connect to anything")
        XCTAssertNil(availability.socketPath)
        XCTAssertFalse(availability.isAvailable)
    }

    func testAnUnaddressableSocketPathIsRefusedWithoutConnecting() {
        let probe = CountingProbe(answering: .ready)

        let availability = PTYHostAvailability.resolve(
            decision(
                isEnabled: true,
                helperURL: missingHelper,
                socketPath: nil,
                socketPathBytes: 140
            ),
            probing: probe.probe
        )

        XCTAssertEqual(availability, .unavailable(.socketPathTooLong(bytes: 140)))
        XCTAssertEqual(probe.count, 0)
    }

    func testAMissingHelperIsRefusedWithoutConnecting() {
        let probe = CountingProbe(answering: .ready)

        let availability = PTYHostAvailability.resolve(
            decision(isEnabled: true, helperURL: missingHelper, socketPath: "/tmp/ptyd.sock"),
            probing: probe.probe
        )

        XCTAssertEqual(availability, .unavailable(.helperMissing))
        XCTAssertEqual(probe.count, 0, "a daemon that is not installed cannot be listening")
    }

    // MARK: - The branch that needs a peer

    func testAConnectionThatIsRefusedReadsAsNotRunning() throws {
        let probe = CountingProbe(answering: .notRunning)

        let availability = PTYHostAvailability.resolve(
            decision(
                isEnabled: true,
                helperURL: try presentHelper(),
                socketPath: "/tmp/ptyd.sock"
            ),
            probing: probe.probe
        )

        XCTAssertEqual(availability, .unavailable(.notRunning))
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(probe.lastRequest?.socketPath, "/tmp/ptyd.sock")
        XCTAssertEqual(probe.lastRequest?.build, "1.2.3 (456)")
    }

    func testADaemonTheGateRefusesIsAProtocolMismatchAndNotAnAbsence() throws {
        for compatibility in [PTYHostCompatibility.peerTooOld, .selfTooOld] {
            let probe = CountingProbe(answering: .mismatched(compatibility))

            let availability = PTYHostAvailability.resolve(
                decision(
                    isEnabled: true,
                    helperURL: try presentHelper(),
                    socketPath: "/tmp/ptyd.sock"
                ),
                probing: probe.probe
            )

            XCTAssertEqual(availability, .unavailable(.protocolMismatch(compatibility)))
            XCTAssertNil(
                availability.socketPath,
                "a refused daemon must not be attached to or spawned into"
            )
        }
    }

    func testACompatibleDaemonIsAvailableAtItsSocket() throws {
        let probe = CountingProbe(answering: .ready)

        let availability = PTYHostAvailability.resolve(
            decision(
                isEnabled: true,
                helperURL: try presentHelper(),
                socketPath: "/tmp/ptyd.sock"
            ),
            probing: probe.probe
        )

        XCTAssertEqual(availability, .available(socketPath: "/tmp/ptyd.sock"))
        XCTAssertTrue(availability.isAvailable)
        XCTAssertNil(availability.unavailability)
    }

    // MARK: - The registration cases

    func testTheRegistrationCasesAreNeverProducedByTheProbe() throws {
        // `notRegistered` and `notFound` exist so the registration slice can distinguish "launchd
        // has seen this label and it is off" from "launchd has never seen it". Nothing in this
        // probe may invent either: it has no `SMAppService`, deliberately.
        let outcomes: [PTYHostProbeOutcome] = [.ready, .notRunning, .mismatched(.peerTooOld)]
        for outcome in outcomes {
            let availability = PTYHostAvailability.resolve(
                decision(
                    isEnabled: true,
                    helperURL: try presentHelper(),
                    socketPath: "/tmp/ptyd.sock"
                ),
                probing: PTYHostProbe.answering(outcome)
            )
            XCTAssertNotEqual(availability, .unavailable(.notRegistered))
            XCTAssertNotEqual(availability, .unavailable(.notFound))
        }
    }

    func testEveryReasonJournalsAStructuralToken() {
        XCTAssertEqual(PTYHostUnavailability.disabled.token, "disabled")
        XCTAssertEqual(
            PTYHostUnavailability.socketPathTooLong(bytes: 140).token,
            "socketPathTooLong"
        )
        XCTAssertEqual(PTYHostUnavailability.helperMissing.token, "helperMissing")
        XCTAssertEqual(PTYHostUnavailability.notRunning.token, "notRunning")
        XCTAssertEqual(
            PTYHostUnavailability.protocolMismatch(.selfTooOld).token,
            "protocolMismatch.selfTooOld"
        )
        XCTAssertEqual(PTYHostUnavailability.notRegistered.token, "notRegistered")
        XCTAssertEqual(PTYHostUnavailability.notFound.token, "notFound")
    }

    // MARK: - The composition

    @MainActor
    func testLiveReadsTheInjectedSettingsAndBundleAndNothingElse() throws {
        let suiteName = "PTYHostAvailabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.ptyHostEnabled, "the hidden key ships off")

        let offProbe = CountingProbe(answering: .ready)
        XCTAssertEqual(
            PTYHostAvailability.live(settings: settings, bundle: .main, probe: offProbe.probe),
            .unavailable(.disabled)
        )
        XCTAssertEqual(offProbe.count, 0)

        settings.ptyHostEnabled = true
        let emptyBundle = try makeBundle(withHelper: false)
        let missingProbe = CountingProbe(answering: .ready)
        XCTAssertEqual(
            PTYHostAvailability.live(
                settings: settings,
                bundle: emptyBundle,
                probe: missingProbe.probe
            ),
            .unavailable(.helperMissing)
        )
        XCTAssertEqual(missingProbe.count, 0)

        let fullBundle = try makeBundle(withHelper: true)
        let readyProbe = CountingProbe(answering: .ready)
        XCTAssertEqual(
            PTYHostAvailability.live(
                settings: settings,
                bundle: fullBundle,
                probe: readyProbe.probe
            ),
            .available(socketPath: PTYHostLocation.socketPath)
        )
        XCTAssertEqual(readyProbe.count, 1)
        XCTAssertEqual(
            readyProbe.lastRequest?.build,
            "7.7.7 (777)",
            "hello's build comes from the bundle the caller named, not from Bundle.main"
        )
    }

    @MainActor
    func testTheDecisionSnapshotNamesTheBundlesHelperAndTheRendezvous() throws {
        let suiteName = "PTYHostAvailabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.ptyHostEnabled = true
        let bundle = try makeBundle(withHelper: true)

        let snapshot = PTYHostDecision.live(settings: settings, bundle: bundle)

        XCTAssertTrue(snapshot.isEnabled)
        XCTAssertEqual(
            snapshot.helperURL,
            bundle.bundleURL
                .appendingPathComponent(PTYHostDefaults.helpersDirectoryPath, isDirectory: true)
                .appendingPathComponent(PTYHostDefaults.helperName)
        )
        XCTAssertEqual(snapshot.socketPath, PTYHostLocation.socketPath)
        XCTAssertEqual(snapshot.socketPathBytes, PTYHostLocation.socketPath.utf8.count)
        XCTAssertEqual(snapshot.build, "7.7.7 (777)")
    }

    // MARK: - Helpers

    private func makeBundle(withHelper: Bool) throws -> Bundle {
        let root = scratch
            .appendingPathComponent("Bundle-\(UUID().uuidString.prefix(8)).app", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "codes.threading.tests.ptyhost",
            "CFBundleShortVersionString": "7.7.7",
            "CFBundleVersion": "777"
        ]
        try PropertyListSerialization
            .data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if withHelper {
            let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8)
                .write(to: helpers.appendingPathComponent(PTYHostDefaults.helperName))
        }
        return try XCTUnwrap(Bundle(url: root))
    }
}
