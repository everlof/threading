import AppKit
import Darwin
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest
@testable import Threading

/// What the child receives after it has been handed back, against the real `threading-ptyd`.
///
/// The sibling suite next door pins the *screen* a rejoin reproduces and the grid the child ends
/// on. This one pins the other direction — every byte that travels **upstream** once a reattached
/// terminal is selected, focused and resized — because that is the direction a defect in the
/// replay is invisible in: the screen can be perfect while an escape sequence the replay armed
/// makes the agent quit.
///
/// The child records its own standard input rather than being asked what it saw, so the assertion
/// is on bytes a program actually received rather than on frames somebody sent.
@MainActor
final class PTYHostReattachInputDaemonTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let helperName = "threading-ptyd"
        static let frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        static let widerFrame = NSRect(x: 0, y: 0, width: 900, height: 620)
        static let listenTimeout: TimeInterval = 10
        static let childTimeout: TimeInterval = 20
        /// A settle long enough that "nothing arrived" means it.
        static let quietWindow: TimeInterval = 2

        /// The opt-in that drives the developer's own agent CLI. Never set in `fast`.
        static let realAgentGate = "THREADING_PTY_REAL_AGENT"
        static let realAgentCommandKey = "THREADING_PTY_REAL_AGENT_COMMAND"
        static let realAgentDirectoryKey = "THREADING_PTY_REAL_AGENT_DIRECTORY"
        /// A real TUI needs longer than a `printf` to boot, hand over and settle.
        static let realAgentSettle: TimeInterval = 6
        /// How long the reattached CLI is watched for an ending it must not have.
        static let realAgentWatch: TimeInterval = 20
    }

    // MARK: - Fixture state

    private var directory: URL!
    private var daemon: DaemonInputProcess?
    private var sessions: [TerminalSession] = []
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ptyi-\(UInt32.random(in: 0..<0xFFFF_FFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for session in sessions { session.terminate() }
        _ = pump(
            until: { self.sessions.allSatisfy { !$0.isHostBacked } },
            timeout: PTYHostTestProcessCleanup.childTimeout
        )
        sessions.removeAll()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let daemon {
            XCTAssertTrue(
                daemon.shutdown(),
                "scratch PTY daemon did not drain: \(daemon.diagnosticText)"
            )
        }
        daemon = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    // MARK: - Tests

    /// Selecting, focusing and resizing a reattached terminal sends the child **nothing**.
    ///
    /// This is the shape of the defect it was written for: four reattached Claude sessions each
    /// exited 0 a second or two after being selected in the sidebar. Claude Code ends its process
    /// on an end of file at an empty prompt, so any byte the app volunteers on its own — a focus
    /// report a replayed `DECSET 1004` armed, a stale answer to a query that is already history —
    /// is a candidate. The assertion is therefore the strongest one available: the child's own
    /// standard input has to be silent across the whole selection gesture.
    func testSelectingAFocusedReattachedTerminalSendsTheChildNothing() throws {
        let socketPath = try startDaemon()
        let log = directory.appendingPathComponent("input.bin", isDirectory: false)

        let first = try makeSession()
        first.hostTransportFactory = factory(socketPath: socketPath)
        first.start(plan: plan(armedChildScript(recordingTo: log)))
        XCTAssertTrue(first.isHostBacked, "the launch did not reach the daemon")
        XCTAssertTrue(
            pump(until: { first.visibleScreenLines().contains { $0.contains("READY") } }),
            "the child never armed its modes"
        )
        // Whatever the live arming provoked belongs to the session that was here; the rejoin owns
        // everything after this mark.
        _ = pump(until: { false }, timeout: Fixture.quietWindow)
        let beforeReattach = recordedByteCount(at: log)

        // The quit, with the seeds only a live emulator can produce.
        XCTAssertTrue(first.detachFromHost(by: Date().addingTimeInterval(2)))

        // The relaunch: a fresh session on the same conversation, exactly as a new process builds
        // one.
        let holdings = try holdings(socketPath: socketPath)
        let summary = try XCTUnwrap(holdings.sessions.first)
        XCTAssertNil(summary.exit, "the child is supposed to have kept working")

        let second = try makeSession(identity: first.identity)
        second.hostTransportFactory = factory(socketPath: socketPath)
        XCTAssertTrue(second.attachToHost(grid: summary.grid))
        XCTAssertTrue(
            pump(until: { second.visibleScreenLines().contains { $0.contains("READY") } }),
            "the replay never reached the rejoined emulator"
        )

        // Selecting the row: the terminal takes focus, and then the pane it lands in is a
        // different width from the one the last launch had.
        // `hasFocus` reads through `isKeyWindow`, which an unshown fixture never has; the fact
        // this test needs is the one the emulator is told — `setTerminalFocus`, which
        // `becomeFirstResponder` calls — so the responder is what is asserted.
        let window = try XCTUnwrap(windows.last)
        XCTAssertTrue(window.makeFirstResponder(second.terminalView))
        XCTAssertTrue(
            window.firstResponder === second.terminalView,
            "the reattached terminal never became first responder"
        )
        // Looking away and back again: a sidebar selection resigns one terminal and focuses the
        // next, and a focus *report* is a pair rather than a single byte run.
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertTrue(window.makeFirstResponder(second.terminalView))
        window.setContentSize(Fixture.widerFrame.size)
        second.terminalView.layoutSubtreeIfNeeded()
        _ = pump(until: { false }, timeout: Fixture.quietWindow)

        let sent = recordedBytes(at: log, from: beforeReattach)
        XCTAssertEqual(
            sent,
            [],
            "a reattached terminal that is merely looked at must send its child nothing; it "
                + "received \(escaped(sent))"
        )
        XCTAssertTrue(
            second.isHostBacked,
            "the child ended during a selection gesture that sent it \(escaped(sent))"
        )
    }

    /// A reattached session that keeps painting reads as **working**, and never as dormant.
    ///
    /// The sidebar's only signal for a session the daemon kept is the bytes its child is still
    /// writing: a turn that began before the relaunch raised its `turnStarted` hook into a socket
    /// nobody was listening on. The launch grace has to cover the replay and end with it, which is
    /// the edge the link reports here — wired exactly as `AgentSessionViewController` wires it.
    func testAReattachedSessionThatKeepsPaintingReadsAsWorking() throws {
        let socketPath = try startDaemon()

        let first = try makeSession()
        first.hostTransportFactory = factory(socketPath: socketPath)
        // A screenful up front so the replay is a real repaint, then a steady trickle that is the
        // agent working: the two runs a reattach has to tell apart.
        first.start(plan: plan(
            "printf 'BOOTED\\r\\n'; i=0; while [ \"$i\" -lt 600 ]; do "
                + "printf 'PAINT %s: %s\\r\\n' \"$i\" "
                + "'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; "
                + "i=$((i + 1)); sleep 0.2; done"
        ))
        XCTAssertTrue(
            pump(until: { first.visibleScreenLines().contains { $0.contains("PAINT") } }),
            "the child never painted"
        )
        XCTAssertTrue(first.detachFromHost(by: Date().addingTimeInterval(2)))

        let holdings = try holdings(socketPath: socketPath)
        let summary = try XCTUnwrap(holdings.sessions.first)
        XCTAssertNil(summary.exit, "the child is supposed to have kept working")

        let tracker = SessionActivityTracker()
        tracker.markDormant()

        let second = try makeSession(identity: first.identity)
        second.onRawOutput = { data in
            MainActor.assumeIsolated { _ = tracker.recordOutput(byteCount: data.count) }
        }
        second.onHostAttachReplayFinished = { tracker.endUnattendedLaunchGrace() }
        second.hostTransportFactory = factory(socketPath: socketPath)
        XCTAssertTrue(second.attachToHost(grid: summary.grid))
        // The order `reattachToBackgroundHost` uses.
        tracker.markRunning()
        tracker.noteUnattendedLaunch()

        XCTAssertNotEqual(
            tracker.activity,
            .dormant,
            "dormant must never survive an attach the daemon accepted"
        )
        XCTAssertTrue(
            pump(until: { tracker.activity == .working }),
            "a reattached session whose child keeps painting has to read as working; it read "
                + "\(tracker.activity)"
        )
    }

    /// The same gesture against the real agent CLI, opt-in.
    ///
    /// The synthetic child above proves what the *app* volunteers. This one proves what the CLI
    /// does with it, which is the other half of the report the defect came in as: four reattached
    /// Claude sessions exited 0 within seconds of being selected while every reattached Codex
    /// session survived. It spends no provider turn — the CLI is started and left at its idle
    /// prompt — but it does write a conversation record under the developer's own account, so it
    /// is gated rather than part of `fast`.
    func testARealAgentCLISurvivesBeingReattachedAndSelected() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Fixture.realAgentGate] == "1",
            "set \(Fixture.realAgentGate)=1 to drive the developer's own agent CLI"
        )
        let command = try XCTUnwrap(
            ProcessInfo.processInfo.environment[Fixture.realAgentCommandKey],
            "\(Fixture.realAgentCommandKey) names the CLI to run"
        )
        let workingDirectory = ProcessInfo.processInfo
            .environment[Fixture.realAgentDirectoryKey] ?? FileManager.default.currentDirectoryPath
        let socketPath = try startDaemon()

        let first = try makeSession()
        first.hostTransportFactory = factory(socketPath: socketPath)
        // A login shell, because the CLI lives in `~/.local/bin` or a Node prefix and a GUI
        // process does not inherit an interactive `PATH` — the same reason `AgentLauncher` uses
        // one.
        first.start(plan: AgentLaunchPlan(
            executable: "/bin/bash",
            arguments: ["-l", "-c", "cd \(workingDirectory) && exec \(command)"],
            resumeState: .unavailable
        ))
        XCTAssertTrue(first.isHostBacked, "the launch did not reach the daemon")
        XCTAssertTrue(
            pump(
                until: { first.visibleScreenLines().contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } },
                timeout: Fixture.childTimeout
            ),
            "the agent CLI never painted anything"
        )
        _ = pump(until: { false }, timeout: Fixture.realAgentSettle)
        print("PTYHostReattachInputDaemonTests live screen: \(first.visibleScreenLines().suffix(8))")

        XCTAssertTrue(first.detachFromHost(by: Date().addingTimeInterval(2)))
        _ = pump(until: { false }, timeout: Fixture.realAgentSettle)

        let holdings = try holdings(socketPath: socketPath)
        let summary = try XCTUnwrap(holdings.sessions.first)
        XCTAssertNil(summary.exit, "the CLI did not survive the quit at all")

        let second = try makeSession(identity: first.identity)
        var sent: [UInt8] = []
        second.terminalView.onInputBytes = { sent.append(contentsOf: $0) }
        second.hostTransportFactory = factory(socketPath: socketPath)
        XCTAssertTrue(second.attachToHost(grid: summary.grid))
        _ = pump(until: { false }, timeout: Fixture.realAgentSettle)
        print("PTYHostReattachInputDaemonTests rejoined screen: \(second.visibleScreenLines().suffix(8))")
        print("PTYHostReattachInputDaemonTests summary: \(summary.executable) pid \(summary.pid) grid \(summary.grid)")

        let window = try XCTUnwrap(windows.last)
        XCTAssertTrue(window.makeFirstResponder(second.terminalView))
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertTrue(window.makeFirstResponder(second.terminalView))
        window.setContentSize(Fixture.widerFrame.size)
        second.terminalView.layoutSubtreeIfNeeded()

        let ended = pump(until: { !second.isHostBacked }, timeout: Fixture.realAgentWatch)
        print("PTYHostReattachInputDaemonTests upstream bytes: \(escaped(sent))")
        print("PTYHostReattachInputDaemonTests screen: \(second.visibleScreenLines().suffix(6))")
        XCTAssertFalse(
            ended,
            "the agent CLI ended after being reattached and selected; it was sent \(escaped(sent))"
        )
    }

    // MARK: - Private Methods — the child

    /// A child that arms the modes an agent CLI arms and then records every byte it is sent.
    ///
    /// `stty raw -echo` for the reason the sibling suite gives about echo, plus one of its own:
    /// canonical mode would eat an end of file rather than record it, which is exactly the byte
    /// this test exists to catch.
    private func armedChildScript(recordingTo log: URL) -> String {
        // Mouse tracking, SGR encoding, bracketed paste, application cursor keys, focus
        // reporting and the kitty keyboard flags: the set a full-screen agent CLI turns on at
        // startup, which is also the set `RemoteTerminalModeSeed` states to a rejoining watcher.
        "stty raw -echo; "
            + "printf '\\033[?1002h\\033[?1006h\\033[?2004h\\033[?1h\\033[?1004h\\033[>1u'; "
            + "printf 'READY\\r\\n'; "
            + "exec cat > \(log.path)"
    }

    private func recordedByteCount(at log: URL) -> Int {
        (try? Data(contentsOf: log))?.count ?? 0
    }

    private func recordedBytes(at log: URL, from offset: Int) -> [UInt8] {
        guard let data = try? Data(contentsOf: log), data.count > offset else { return [] }
        return [UInt8](data.dropFirst(offset))
    }

    /// `od -c`'s answer, in a sentence: an assertion that fails has to name the bytes.
    private func escaped(_ bytes: [UInt8]) -> String {
        bytes
            .map { byte in
                switch byte {
                case 0x1b: return "ESC"
                case 0x20...0x7e: return String(UnicodeScalar(byte))
                default: return String(format: "\\x%02x", byte)
                }
            }
            .joined()
    }

    // MARK: - Private Methods — the fixture

    private func plan(_ script: String) -> AgentLaunchPlan {
        AgentLaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", script],
            resumeState: .unavailable
        )
    }

    private func factory(socketPath: String) -> PTYHostTransportFactory {
        PTYHostPolicy.attachingTransportFactory(socketPath: socketPath)
    }

    private func holdings(socketPath: String) throws -> PTYHostHoldings {
        let decision = PTYHostDecision(
            isEnabled: true,
            helperURL: try helperURL(),
            socketPath: socketPath,
            socketPathBytes: socketPath.utf8.count,
            build: "test"
        )
        return try XCTUnwrap(
            PTYHostHoldingsSurvey.connecting().holdings(for: decision),
            "the daemon did not say what it was holding"
        )
    }

    private func helperURL() throws -> URL {
        let app = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for root in [Bundle.main.bundleURL, app] {
            let helper = root
                .appendingPathComponent("Contents/Helpers", isDirectory: true)
                .appendingPathComponent(Fixture.helperName, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
        }
        throw XCTSkip("no \(Fixture.helperName) in this bundle")
    }

    private func startDaemon() throws -> String {
        let helper = try helperURL()
        let socketPath = directory.appendingPathComponent("d.sock").path
        let daemon = try DaemonInputProcess(
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

    private func makeSession(
        identity: TerminalInstanceIdentity = .agentSession(SessionID())
    ) throws -> TerminalSession {
        let session = TerminalSession(frame: Fixture.frame, identity: identity)
        let host = NSWindow(
            contentRect: Fixture.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        host.contentView = session.terminalView
        windows.append(host)
        session.terminalView.layoutSubtreeIfNeeded()
        sessions.append(session)
        return session
    }

    @discardableResult
    private func pump(
        until condition: () -> Bool,
        timeout: TimeInterval = Fixture.childTimeout
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }
}

// MARK: - The daemon, as the process it ships as

/// `threading-ptyd` on a scratch socket. A local copy for the reason the sibling suites give:
/// each drives the daemon from a different height, and a shared harness would grow all their jobs.
private final class DaemonInputProcess: @unchecked Sendable {

    private let process = Process()
    private let socketPath: String
    private let diagnostics = Pipe()
    private let lock = NSLock()
    private var collected = Data()

    init(helper: URL, socketPath: String, stateDirectory: URL) throws {
        self.socketPath = socketPath
        process.executableURL = helper
        process.arguments = ["--socket", socketPath, "--state", stateDirectory.path]
        var environment = ["PATH": "/usr/bin:/bin"]
        if let token = ProcessInfo.processInfo.environment["THREADING_TEST_RUN_TOKEN"] {
            environment["THREADING_TEST_RUN_TOKEN"] = token
        }
        process.environment = environment
        process.standardError = diagnostics
        process.standardOutput = FileHandle.nullDevice

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

    func shutdown() -> Bool {
        let drained = PTYHostTestProcessCleanup.stopSessionsAndRetire(socketPath: socketPath)
        let exited = waitUntilExited(timeout: PTYHostTestProcessCleanup.childTimeout)
        if !exited, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = waitUntilExited(timeout: 1)
        }
        diagnostics.fileHandleForReading.readabilityHandler = nil
        return drained && exited
    }

    private func waitUntilExited(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    var diagnosticText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: collected, as: UTF8.self)
    }
}
