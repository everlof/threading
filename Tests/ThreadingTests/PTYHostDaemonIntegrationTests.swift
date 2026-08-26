import Darwin
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest
@testable import Threading

/// The client against the real `threading-ptyd`.
///
/// **Skips when the helper is not in the bundle**, rather than failing. The daemon is its own
/// target and its own copy phase, and a build that has not embedded it yet — a bisect, a
/// partially applied tree, a configuration that skips helpers — must report "not here" rather
/// than "broken". When it is there, this is the only place the app's client meets a real
/// `forkpty` child.
///
/// Everything else about the client is covered against the in-process fake in
/// `PTYHostClientTests`, which needs no binary, no `SMAppService` and no window. This class is
/// deliberately thin for that reason: it proves the two processes agree, not what either does.
///
/// It never uses `PTYHostLocation.socketPath`. A test that started a daemon on the real
/// rendezvous would be a second listener at the address the developer's running app uses.
final class PTYHostDaemonIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    private var scratch: URL!
    private var daemon: Process?
    private var client: PTYHostClient?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let helper = PTYHostLocation.helperURL(in: .main)
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: helper.path),
            "\(PTYHostDefaults.helperName) is not in the bundle yet; the daemon is a later slice"
        )
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PTYHostDaemon-\(getpid())-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: PTYHostDefaults.directoryPermissions]
        )
    }

    override func tearDownWithError() throws {
        client?.close()
        client = nil
        if let daemon, daemon.isRunning {
            daemon.terminate()
            daemon.waitUntilExit()
        }
        daemon = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: - Tests

    func testARealDaemonAnswersHelloAndRunsAChildToCompletion() throws {
        let socketPath = try startDaemon()
        let recorder = PTYHostEventRecorder()
        let client = PTYHostClient(
            socketPath: socketPath,
            build: PTYHostBuild.string(for: .main),
            events: recorder.events,
            eventLog: EventLog(directory: scratch)
        )
        self.client = client

        let hello = try client.connect()
        XCTAssertEqual(hello.protocolVersion, PTYHostProtocol.current)
        XCTAssertGreaterThan(hello.pid, 0)
        XCTAssertEqual(
            hello.build,
            PTYHostBuild.string(for: .main),
            "the app and helper embedded by one bundle must advertise one generation"
        )

        let session = PTYHostSessionIdentity.agentSession(SessionID())
        try client.spawn(
            PTYHostSpawnRequest(
                id: session,
                channel: .pty(grid: PTYHostGrid(cols: 80, rows: 24, xpixel: 640, ypixel: 384)),
                executable: "/bin/sh",
                // `arguments` excludes argv[0]; the daemon inserts `execName ?? executable`.
                arguments: ["-c", "printf hi"],
                environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin"],
                cwd: NSTemporaryDirectory()
            )
        )

        XCTAssertTrue(recorder.waitForFrames(1), "the daemon must answer spawn")
        guard case .spawned(let spawned)? = recorder.frames.first else {
            return XCTFail("spawn must be answered with spawned: \(recorder.frames)")
        }
        XCTAssertEqual(spawned.id, session)
        XCTAssertGreaterThan(spawned.pid, 0)

        XCTAssertTrue(
            recorder.waitForOutput(2),
            "the child's own bytes must reach the watcher"
        )
        XCTAssertTrue(String(decoding: recorder.output, as: UTF8.self).contains("hi"))

        XCTAssertTrue(waitFor { recorder.frames.contains { if case .exited = $0 { return true }; return false } })
    }

    func testASecondConnectionCanAttachToASessionTheFirstSpawned() throws {
        let socketPath = try startDaemon()
        let build = PTYHostBuild.string(for: .main)
        let journal = EventLog(directory: scratch)

        let spawnRecorder = PTYHostEventRecorder()
        let spawner = PTYHostClient(
            socketPath: socketPath,
            build: build,
            events: spawnRecorder.events,
            eventLog: journal
        )
        self.client = spawner
        try spawner.connect()

        let session = PTYHostSessionIdentity.agentSession(SessionID())
        try spawner.spawn(
            PTYHostSpawnRequest(
                id: session,
                channel: .pty(grid: PTYHostGrid(cols: 80, rows: 24)),
                executable: "/bin/sh",
                arguments: ["-c", "printf hi; sleep 5"],
                environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin"],
                cwd: NSTemporaryDirectory()
            )
        )
        XCTAssertTrue(spawnRecorder.waitForOutput(2))

        let attachRecorder = PTYHostEventRecorder()
        let watcher = PTYHostClient(
            socketPath: socketPath,
            build: build,
            events: attachRecorder.events,
            eventLog: journal
        )
        defer { watcher.close() }
        try watcher.connect()
        try watcher.attach(PTYHostAttach(id: session))

        XCTAssertTrue(attachRecorder.waitForFrames(1))
        guard case .attached(let attached)? = attachRecorder.frames.first else {
            return XCTFail("attach must be answered with attached: \(attachRecorder.frames)")
        }
        XCTAssertEqual(attached.id, session)
        XCTAssertEqual(attached.grid.cols, 80)

        try watcher.kill(PTYHostKill(id: session, escalate: true))
    }

    // MARK: - The upgrade handshake

    /// P2, end to end: replacing the bundle leaves launchd's registration pointing at a path
    /// whose binary has changed, and the daemon already running keeps executing the old image.
    /// Nothing in the OS ends it. This is the ask that does.
    func testAStaleDaemonHoldingNothingIsRetiredAndExitsOnItsOwn() throws {
        let socketPath = try startDaemon()

        let decision = PTYHostUpgradeCheck.run(
            socketPath: socketPath,
            ownBuild: "slice8-a-different-build (999)",
            eventLog: EventLog(directory: scratch)
        )
        XCTAssertEqual(decision, .retire)

        // The unlink is immediate and is the point of the frame: a replacement binary has to be
        // able to bind the path while this process is still finishing its work.
        XCTAssertTrue(
            waitFor { !FileManager.default.fileExists(atPath: socketPath) },
            "a retiring daemon unlinks its rendezvous before it drains"
        )
        XCTAssertTrue(
            waitFor { self.daemon?.isRunning == false },
            "a retiring daemon holding nothing exits, which is what lets KeepAlive exec the new binary"
        )
    }

    /// The other half, and the reason `retire` is not a kill: a daemon of the wrong build that is
    /// holding somebody's agents keeps them.
    func testAStaleDaemonIsLeftWhileItsSessionRunsAndRetiresAfterThatSessionEnds() throws {
        let socketPath = try startDaemon()
        let journal = EventLog(directory: scratch)
        let recorder = PTYHostEventRecorder()
        let holder = PTYHostClient(
            socketPath: socketPath,
            build: PTYHostBuild.string(for: .main),
            events: recorder.events,
            eventLog: journal
        )
        self.client = holder
        try holder.connect()
        let held = PTYHostSessionIdentity.agentSession(SessionID())
        try holder.spawn(
            PTYHostSpawnRequest(
                id: held,
                channel: .pty(grid: PTYHostGrid(cols: 80, rows: 24)),
                executable: "/bin/sh",
                arguments: ["-c", "printf hi; sleep 30"],
                environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin"],
                cwd: NSTemporaryDirectory()
            )
        )
        XCTAssertTrue(recorder.waitForOutput(2), "the child has to be running to be held")

        XCTAssertEqual(
            PTYHostUpgradeCheck.run(
                socketPath: socketPath,
                ownBuild: "slice8-a-different-build (999)",
                eventLog: journal
            ),
            .leave(.holdsSessions(1))
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socketPath),
            "nothing was retired, so the rendezvous is still there"
        )
        XCTAssertEqual(daemon?.isRunning, true)

        // And the count that decision rested on is the one the removal decision reads, which is
        // what stops turning the hidden key off from killing a working agent.
        XCTAssertEqual(
            PTYHostUpgradeCheck.activeSessions(
                socketPath: socketPath,
                ownBuild: PTYHostBuild.string(for: .main),
                eventLog: journal
            ),
            1
        )
        XCTAssertEqual(
            PTYHostRegistration.removalDecision(heldSessions: 1),
            .leave(heldSessions: 1)
        )

        // Ended here rather than left for teardown: killing the daemon orphans its children, and
        // a `sleep` reparented to launchd outlives this process (the R4 finding). Use the same
        // attach-then-kill path as the background-sessions surface so its upgrade edge is part of
        // the real-daemon proof too.
        let drained = expectation(description: "the stop path announces a possible idle host")
        drained.assertForOverFulfill = true
        let token = NotificationCenter.default.addObserver(
            forName: PTYHostMayHaveDrained.name,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.object is PTYHostMayHaveDrained else { return }
            drained.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertTrue(
            PTYHostSessionStop.run(
                held,
                socketPath: socketPath,
                build: PTYHostBuild.string(for: .main),
                eventLog: journal
            )
        )
        wait(for: [drained], timeout: 1)
        XCTAssertTrue(
            waitFor {
                recorder.frames.contains { frame in
                    if case .exited(let ending) = frame { return ending.id == held }
                    return false
                }
            },
            "the active-session count cannot fall until the daemon delivered the child's exit"
        )

        XCTAssertEqual(
            PTYHostUpgradeCheck.activeSessions(
                socketPath: socketPath,
                ownBuild: PTYHostBuild.string(for: .main),
                eventLog: journal
            ),
            0,
            "an exit retained for a late watcher is not live work that an upgrade can kill"
        )
        XCTAssertEqual(
            PTYHostUpgradeCheck.run(
                socketPath: socketPath,
                ownBuild: "slice8-a-different-build (999)",
                eventLog: journal
            ),
            .retire
        )
        XCTAssertTrue(
            waitFor { self.daemon?.isRunning == false },
            "the stale daemon must converge to the installed generation after its work ends"
        )
    }

    /// The ordinary launch: the daemon is the one this build installed, so there is nothing to do
    /// and nothing is said.
    func testADaemonOfThisBuildIsLeftAlone() throws {
        let socketPath = try startDaemon()
        let journal = EventLog(directory: scratch)

        let client = PTYHostClient(
            socketPath: socketPath,
            build: PTYHostBuild.string(for: .main),
            events: .ignored,
            eventLog: journal
        )
        let hello = try client.connect()
        client.close()

        XCTAssertEqual(
            PTYHostUpgradeCheck.run(
                socketPath: socketPath,
                ownBuild: hello.build,
                eventLog: journal
            ),
            .leave(.sameBuild)
        )
        XCTAssertEqual(daemon?.isRunning, true)
    }

    /// Nothing is listening. Every caller's answer to that is to leave the daemon alone, which is
    /// also what happens when there was never a daemon at all.
    func testNothingListeningIsNotADecision() {
        let socketPath = scratch.appendingPathComponent("absent.sock").path
        XCTAssertNil(
            PTYHostUpgradeCheck.run(
                socketPath: socketPath,
                ownBuild: PTYHostBuild.string(for: .main),
                eventLog: EventLog(directory: scratch)
            )
        )
        XCTAssertNil(
            PTYHostUpgradeCheck.activeSessions(
                socketPath: socketPath,
                ownBuild: PTYHostBuild.string(for: .main),
                eventLog: EventLog(directory: scratch)
            )
        )
    }

    // MARK: - Helpers

    /// Starts the shipped daemon against a scratch rendezvous.
    ///
    /// Never the real one: a test must not bind the socket the developer's running app is
    /// listening on, which is the same reason `PTYHostLocation` redirects under a hosted bundle.
    private func startDaemon() throws -> String {
        let socketPath = scratch.appendingPathComponent(PTYHostDefaults.socketFileName).path
        try XCTSkipUnless(
            socketPath.utf8.count <= PTYHostDefaults.maximumSocketPathBytes,
            "the scratch rendezvous does not fit sockaddr_un on this machine"
        )

        let process = Process()
        process.executableURL = PTYHostLocation.helperURL(in: .main)
        process.arguments = [
            PTYHostDefaults.socketArgument, socketPath,
            PTYHostDefaults.stateArgument, scratch.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        daemon = process

        let bound = waitFor(timeout: 10) {
            FileManager.default.fileExists(atPath: socketPath)
        }
        XCTAssertTrue(
            bound,
            """
            \(PTYHostDefaults.helperName) did not bind \(socketPath). Its command line is \
            `\(PTYHostDefaults.socketArgument) <path> \(PTYHostDefaults.stateArgument) <dir>`.
            """
        )
        return socketPath
    }

    private func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }
}
