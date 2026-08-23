import AppKit
import Darwin
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest
@testable import Threading

/// A host-backed `TerminalSession` meeting the real `threading-ptyd`.
///
/// The fake-link tests next door pin what the session does with each frame; this one pins that the
/// frames are the ones the shipping daemon actually speaks, over a real unix socket, with a real
/// `forkpty` child. It is the thin layer above `PTYHostDaemonTests` — the daemon is launched by
/// hand against a scratch socket, exactly as that suite does, because registration with launchd is
/// a later slice and a test must never bind the rendezvous the developer's running app is using.
///
/// Skips when the helper is not in the bundle. Nothing here needs a window.
@MainActor
final class PTYHostSessionDaemonTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let helperName = "threading-ptyd"
        static let frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        /// Bounded: each covers a process launch plus a socket round trip.
        static let listenTimeout: TimeInterval = 10
        static let childTimeout: TimeInterval = 15
        static let exitTimeout: TimeInterval = 15
    }

    // MARK: - Fixture state

    private var directory: URL!
    private var daemon: DaemonProcess?
    private var session: TerminalSession?
    private var recorder: ExitRecorder?
    private var window: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `sockaddr_un.sun_path` holds 104 bytes and the temporary directory is already about
        // half of it, so the fixture's own names stay short.
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ptys-\(UInt32.random(in: 0..<0xFFFF_FFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        session?.terminate()
        session = nil
        recorder = nil
        window?.orderOut(nil)
        window = nil
        daemon?.terminate()
        daemon = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    // MARK: - Tests

    /// A real agent session's pty lives in the daemon, renders in this process, and stops when
    /// the session does.
    ///
    /// The two assertions are the two halves of the slice: what the emulator shows proves the
    /// bytes crossed the socket and were fed through the seam, and the child's pid being gone
    /// proves `terminate()` reached the daemon rather than a `LocalProcess` that was never
    /// started. `sleep 30` is what makes the second one mean something — a child that had already
    /// exited would pass a weaker test by accident.
    func testARealDaemonRunsTheSessionsChildAndTerminateEndsIt() throws {
        let socketPath = try startDaemon()

        let recorder = ExitRecorder()
        self.recorder = recorder
        let session = makeSession()
        session.delegate = recorder
        session.hostTransportFactory = { events in
            let client = PTYHostClient(socketPath: socketPath, build: "test", events: events)
            try client.connect()
            return client
        }

        session.start(plan: AgentLaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", "printf hi; sleep 30"],
            resumeState: .unavailable
        ))
        XCTAssertTrue(session.isHostBacked, "the launch did not reach the daemon")

        XCTAssertTrue(
            pump(until: { session.shellPid > 0 }, timeout: Fixture.childTimeout),
            "the daemon never reported the child's pid"
        )
        let childPid = session.shellPid

        XCTAssertTrue(
            pump(
                until: { session.visibleScreenLines().contains { $0.contains("hi") } },
                timeout: Fixture.childTimeout
            ),
            "what the child printed never reached this session's emulator"
        )

        session.terminate()
        XCTAssertTrue(
            pump(until: { !recorder.exitCodes.isEmpty }, timeout: Fixture.exitTimeout),
            "the daemon never reported the ending"
        )
        XCTAssertTrue(
            pump(until: { Darwin.kill(childPid, 0) != 0 }, timeout: Fixture.exitTimeout),
            "pid \(childPid) is still alive after the session stopped"
        )
        XCTAssertFalse(session.isRunning)
    }

    // MARK: - Helpers

    private func startDaemon() throws -> String {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(Fixture.helperName, isDirectory: false)
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: helper.path),
            "no \(Fixture.helperName) in this bundle — build the Threading target, which embeds "
                + "it through the Embed Extension Helpers phase, and run the hosted test target"
        )

        let socketPath = directory.appendingPathComponent("d.sock").path
        let daemon = try DaemonProcess(
            helper: helper,
            socketPath: socketPath,
            stateDirectory: directory.appendingPathComponent("s", isDirectory: true)
        )
        self.daemon = daemon

        let listening = pump(
            until: { PTYHostClient.probe(socketPath: socketPath, build: "probe") == .ready },
            timeout: Fixture.listenTimeout
        )
        guard listening else {
            XCTFail("the daemon never bound \(socketPath): \(daemon.diagnosticText)")
            throw XCTSkip("no daemon to talk to")
        }
        return socketPath
    }

    private func makeSession() -> TerminalSession {
        let session = TerminalSession(
            frame: Fixture.frame,
            identity: .agentSession(SessionID())
        )
        // Unshown and borderless: the grid has to be a real one, because the daemon takes it as
        // the child's `winsize` and 2×1 is a terminal an agent's TUI cannot draw in.
        let host = NSWindow(
            contentRect: Fixture.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        host.contentView = session.terminalView
        window = host
        session.terminalView.layoutSubtreeIfNeeded()
        self.session = session
        return session
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }
}

// MARK: - The daemon, as the process it ships as

/// `threading-ptyd`, launched by hand against a scratch socket.
///
/// A local copy rather than a shared fixture: `PTYHostDaemonTests` owns one of these and keeps it
/// private on purpose — that suite drives the wire directly and this one drives a session, and a
/// shared harness would have to grow both jobs.
private final class DaemonProcess: @unchecked Sendable {

    private let process = Process()
    private let diagnostics = Pipe()
    private let lock = NSLock()
    private var collected = Data()

    init(helper: URL, socketPath: String, stateDirectory: URL) throws {
        process.executableURL = helper
        process.arguments = ["--socket", socketPath, "--state", stateDirectory.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardError = diagnostics
        process.standardOutput = FileHandle.nullDevice

        // Drained rather than left to fill: a pipe nobody reads is a process that eventually
        // blocks writing to it.
        diagnostics.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.lock.lock()
            self?.collected.append(data)
            self?.lock.unlock()
        }

        try process.run()
    }

    func terminate() {
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        diagnostics.fileHandleForReading.readabilityHandler = nil
    }

    var diagnosticText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: collected, as: UTF8.self)
    }
}

/// The session's ending, and nothing else.
@MainActor
private final class ExitRecorder: TerminalSessionDelegate {
    private(set) var exitCodes: [Int32?] = []

    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {
        exitCodes.append(exitCode)
    }
}
