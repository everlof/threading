import Darwin
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest
@testable import Threading

/// The client against the real `threading-ptyd`.
///
/// **Skipped until the daemon ships.** `Targets/PTYHost` is a later slice, so
/// `Contents/Helpers/threading-ptyd` is not in the bundle yet and every case here reports as
/// skipped. That is deliberate: the alternative is either no coverage of the real binary, or a
/// red suite for work that has not been done. When the daemon's copy phase lands, these start
/// running with no edit.
///
/// Everything else about the client is covered against the in-process fake in
/// `PTYHostClientTests`, which needs no binary, no `SMAppService` and no window.
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
        XCTAssertFalse(hello.build.isEmpty)

        let session = PTYHostSessionIdentity.agentSession(SessionID())
        try client.spawn(
            PTYHostSpawnRequest(
                id: session,
                channel: .pty(grid: PTYHostGrid(cols: 80, rows: 24, xpixel: 640, ypixel: 384)),
                executable: "/bin/sh",
                // Slice 4 owns the argv contract; if it differs, this is the one line to change.
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
        process.arguments = [MCPBridgeDefaults.socketArgument, socketPath]
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
            \(PTYHostDefaults.helperName) did not bind \(socketPath). Slice 4 owns its command \
            line; this test expects `\(MCPBridgeDefaults.socketArgument) <path>`.
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
