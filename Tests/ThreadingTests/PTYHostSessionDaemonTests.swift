import AppKit
import Darwin
import Dispatch
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
        /// A genuinely different window, so the resize under test is a real change.
        static let widerFrame = NSRect(x: 0, y: 0, width: 900, height: 620)
        /// Bounded: each covers a process launch plus a socket round trip.
        static let listenTimeout: TimeInterval = 10
        static let childTimeout: TimeInterval = 15
        static let exitTimeout: TimeInterval = 15
        /// Long enough that "the child never learned" means it rather than "not yet".
        static let quietWindow: TimeInterval = 2
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

    /// A window size the transport refused still reaches the child.
    ///
    /// This is the bug, reproduced end to end: `resize` is fire-and-forget and has no retry of
    /// its own, so one refused write left the daemon's pty on an old grid while this process's
    /// emulator moved to the new one — measured on a live machine as a 111×81 pty under a
    /// 210-column pane, with the agent's own lines wrapped mid-word by the emulator's autowrap.
    /// In-process the same seam is a synchronous `ioctl` that cannot fail after the emulator has
    /// resized, which is why only the host-backed path could ever diverge.
    ///
    /// Both halves are asserted on what the **child** observed, through `stty size`: that it is
    /// still on the old grid while nothing is flowing, and that it lands on the new one once
    /// there is evidence the transport is current again. A frame count would say neither.
    func testAWindowSizeTheTransportRefusedStillReachesTheChild() throws {
        let socketPath = try startDaemon()
        let log = directory.appendingPathComponent("winsize.log", isDirectory: false)
        let refusals = ResizeRefusals()

        let session = makeSession()
        session.hostTransportFactory = { events in
            let client = PTYHostClient(socketPath: socketPath, build: "test", events: events)
            try client.connect()
            return RefusingResizeTransport(client: client, refusals: refusals)
        }
        // Silent until it is spoken to: it writes every size change to a file and prints only
        // what it is sent, so a quiet window is genuinely quiet and the output that converges
        // the link arrives exactly when this test asks for it.
        session.start(plan: AgentLaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", Self.sizeLoggingScript(log: log)],
            resumeState: .unavailable
        ))
        XCTAssertTrue(session.isHostBacked, "the launch did not reach the daemon")
        XCTAssertTrue(
            pump(until: { self.sizeLines(in: log).count >= 1 }, timeout: Fixture.childTimeout),
            "the child never reported the size it was spawned at"
        )
        let spawnedAt = try XCTUnwrap(sizeLines(in: log).last)

        // The window moves, and the frame that would carry it is dropped on the floor.
        session.terminalView.frame = Fixture.widerFrame
        session.terminalView.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            pump(until: { refusals.count >= 1 }, timeout: Fixture.childTimeout),
            "the fixture has to have refused the resize this test is about"
        )
        refusals.stop()

        let wanted = session.terminalView.terminalDimensions
        _ = pump(until: { false }, timeout: Fixture.quietWindow)
        XCTAssertEqual(
            sizeLines(in: log),
            [spawnedAt],
            "a dropped resize is a child still on the old grid — the symptom this fixes"
        )
        XCTAssertNotEqual(
            "\(wanted.rows) \(wanted.cols)",
            spawnedAt,
            "the emulator has to have moved, or there is no divergence to reconcile"
        )
        XCTAssertTrue(session.isRunning, "a window size that could not be written is not an end")

        // Anything arriving proves the transport is current, and the grid nobody forgot is sent.
        session.terminalView.sendUserText("probe\r")
        XCTAssertTrue(
            pump(until: { self.sizeLines(in: log).count >= 2 }, timeout: Fixture.childTimeout),
            "the window size that was dropped never reached the child"
        )
        XCTAssertEqual(
            sizeLines(in: log).last,
            "\(wanted.rows) \(wanted.cols)",
            "the child has to end on the grid the window actually has"
        )

        _ = pump(until: { false }, timeout: Fixture.quietWindow)
        XCTAssertEqual(
            sizeLines(in: log).count,
            2,
            "one window change is one change of the child's size, not a retry loop"
        )
    }

    // MARK: - Helpers

    /// Polls its own window size into `log` and echoes whatever it is sent.
    ///
    /// The poll rather than a `SIGWINCH` trap because the size is the fact that matters, and it
    /// depends on no shell's trap semantics; the `read` is what lets a test decide when output
    /// flows, since a pty echoes and any output at all is evidence the link is current.
    private static func sizeLoggingScript(log: URL) -> String {
        "last=; while :; do now=$(stty size); "
            + "if [ \"$now\" != \"$last\" ]; then printf '%s\\n' \"$now\" >> \(log.path); "
            + "last=$now; fi; if read -t 1 line; then printf '[%s]' \"$line\"; fi; done"
    }

    /// The size lines the child has written. `stty size` prints "rows cols".
    private func sizeLines(in log: URL) -> [String] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                let parts = line.split(separator: " ")
                return parts.count == 2 && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
            }
    }

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

// MARK: - A transport that drops a resize

/// How many resizes to refuse, and how many were.
///
/// A class because the factory that reads it is `@Sendable` and the test that asks is not: the
/// same shape `TransportBox` uses next door for the same reason.
private final class ResizeRefusals: @unchecked Sendable {
    private let lock = NSLock()
    private var refuses = true
    private var refused = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return refused
    }

    /// Stop refusing. What follows is an ordinary client on an ordinary connection.
    func stop() {
        lock.lock()
        refuses = false
        lock.unlock()
    }

    /// Answers whether this one is refused, counting it if it is.
    func refusesNext() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if refuses { refused += 1 }
        return refuses
    }
}

/// The shipping client with one hole in it: `resize` throws while the fixture says so.
///
/// A decorator rather than a fake, because what is under test is the *daemon's* pty and the
/// child's own `stty size` — everything except the one write has to be the real thing, over a
/// real socket, or the reconciliation would be proven against a simulation of the failure it
/// exists for. `PTYHostClientError.notReady` is what a real client throws for a transport that
/// is not current, which is the failure the diagnosis measured.
private final class RefusingResizeTransport: PTYHostSessionTransport, @unchecked Sendable {

    private let client: PTYHostClient
    private let refusals: ResizeRefusals

    init(client: PTYHostClient, refusals: ResizeRefusals) {
        self.client = client
        self.refusals = refusals
    }

    var queue: DispatchQueue { client.queue }

    func spawn(_ request: PTYHostSpawnRequest) throws { try client.spawn(request) }
    func attach(_ request: PTYHostAttach) throws { try client.attach(request) }
    func detach(_ request: PTYHostDetach) throws { try client.detach(request) }
    func closeInput(_ request: PTYHostCloseInput) throws { try client.closeInput(request) }
    func kill(_ request: PTYHostKill) throws { try client.kill(request) }
    func sendInput(_ bytes: Data) throws { try client.sendInput(bytes) }
    func drainWrites(until deadline: Date) -> Bool { client.drainWrites(until: deadline) }
    func close() { client.close() }

    func resize(_ request: PTYHostResize) throws {
        guard !refusals.refusesNext() else { throw PTYHostClientError.notReady }
        try client.resize(request)
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
