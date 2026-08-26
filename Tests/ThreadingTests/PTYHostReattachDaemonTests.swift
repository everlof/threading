import AppKit
import Darwin
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest
@testable import Threading

/// Quitting and coming back, against the real `threading-ptyd`.
///
/// The fake-link suites next door pin what a session *sends*; this one pins what a person would
/// see and what the child actually observed. Every assertion is therefore about one of two things:
/// the emulator's own screen after a rejoin, and what reached the child — a size line it wrote
/// down, or an answer to a query. Frame counts prove neither.
///
/// The daemon is launched by hand against a scratch socket, exactly as `PTYHostDaemonTests` does,
/// because a test must never bind the rendezvous the developer's running app is using. Skips when
/// the helper is not in the bundle. Nothing here needs a window on screen.
@MainActor
final class PTYHostReattachDaemonTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let helperName = "threading-ptyd"
        static let frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        /// A genuinely different window, for the one resize a moved window is allowed.
        static let widerFrame = NSRect(x: 0, y: 0, width: 900, height: 620)
        /// A third size, unlike either of the others: the window a relaunch comes back into.
        static let smallerFrame = NSRect(x: 0, y: 0, width: 460, height: 300)
        static let listenTimeout: TimeInterval = 10
        static let childTimeout: TimeInterval = 20
        /// Longer than the child's own pause, so the bytes it wrote while nobody watched are in
        /// the ring before the rejoin asks for them.
        static let detachedPause: TimeInterval = 4.5
        /// A settle long enough that "nothing happened" means it.
        static let quietWindow: TimeInterval = 2
        /// Comfortably past the 512 KiB ring, so the rejoin cannot be exact.
        static let overflowBytes = 1_200_000
        /// A failed test may never reach teardown. Pollers therefore expire on their own after
        /// two minutes instead of becoming permanent launchd-owned fork loops.
        static let sizePollIterations = 600
    }

    // MARK: - Fixture state

    private var directory: URL!
    private var daemon: DaemonHelperProcess?
    private var sessions: [TerminalSession] = []
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `sockaddr_un.sun_path` holds 104 bytes and the temporary directory is already about
        // half of it, so the fixture's own names stay short.
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ptyr-\(UInt32.random(in: 0..<0xFFFF_FFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for session in sessions { session.terminate() }
        let linksEnded = pump(
            until: { self.sessions.allSatisfy { !$0.isHostBacked } },
            timeout: PTYHostTestProcessCleanup.childTimeout
        )
        XCTAssertTrue(linksEnded, "host-backed test sessions did not report their ending")
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

    // MARK: - The exact rejoin

    /// A quit and a relaunch reproduce the screen with no loss and no cut marker, and the query
    /// that arrived while nobody was attached is answered once, late.
    ///
    /// Both halves of D7 in one run, because they are the same claim: the bytes written while the
    /// app was gone have never reached an emulator, so they are owed in full *and* they are owed
    /// their answers. `CAN` is what a lossy rejoin looks like, so its absence is the assertion
    /// that the replay was exact rather than a tail.
    func testAQuitAndARelaunchReplayExactlyAndAnswerTheQueryThatArrivedWhileAway() throws {
        let socketPath = try startDaemon()

        let first = try makeSession()
        first.hostTransportFactory = factory(socketPath: socketPath)
        // `stty -echo` because the line discipline would otherwise echo the emulator's own reply
        // back onto the screen, which is real terminal behaviour and would make the screen
        // comparison below a comparison of the answer rather than of the handover.
        first.start(plan: plan(
            "stty -echo; printf ALPHA; sleep 3; printf '\\033[>c'; sleep 8; "
                + "printf '\\033[>c'; sleep 60"
        ))
        XCTAssertTrue(first.isHostBacked, "the launch did not reach the daemon")
        XCTAssertTrue(
            pump(until: { first.visibleScreenLines().contains { $0.contains("ALPHA") } }),
            "what the child printed never reached the first session's emulator"
        )
        let before = first.visibleScreenLines()

        // The quit.
        XCTAssertTrue(first.detachFromHost(by: Date().addingTimeInterval(2)))
        // The child writes its first query in here, into a ring nobody is reading.
        Thread.sleep(forTimeInterval: Fixture.detachedPause)

        // The relaunch: a brand new session, exactly as a fresh process would build one.
        let holdings = try holdings(socketPath: socketPath)
        let summary = try XCTUnwrap(holdings.sessions.first)
        XCTAssertNil(summary.exit, "the child is supposed to have kept working")

        // The same conversation, on a new surface: a relaunch builds this session's
        // controller afresh, and the id is what the daemon is holding the child under.
        let second = try makeSession(identity: first.identity)
        var fed = Data()
        second.onRawOutput = { fed.append($0) }
        var answers: [Data] = []
        second.terminalView.onInputBytes = { answers.append(Data($0)) }
        second.hostTransportFactory = factory(socketPath: socketPath)
        XCTAssertTrue(second.attachToHost(grid: summary.grid))

        XCTAssertTrue(
            pump(until: { !answers.isEmpty }),
            "the query that arrived while nobody was attached was never answered"
        )
        XCTAssertEqual(
            answers.count,
            1,
            "a query is answered once — the offset is what proves those bytes are new"
        )
        XCTAssertEqual(
            second.visibleScreenLines().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            before.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            "the rejoined emulator has to show the screen the quit handed over"
        )
        // The *first* byte, not "contains": `RemoteTerminalModeSeed` opens with `CAN` of its own,
        // for its own reason, so a cut is told from an exact replay by where the marker is.
        XCTAssertEqual(
            fed.first,
            PTYHostReattachDaemonTests.escape,
            "an exact replay opens with the screen seed; a cut opens with the marker"
        )

        // And the live query behind it is answered too, exactly once more.
        XCTAssertTrue(
            pump(until: { answers.count == 2 }, timeout: Fixture.childTimeout),
            "a live query after the rejoin still has to be answered"
        )
        XCTAssertEqual(answers.count, 2)
    }

    /// A ring that wrapped while nobody was attached is a cut, and the emulator recovers.
    ///
    /// The accepted loss, and the assertion is that it *is* a loss rather than a lie: the marker
    /// is there, the current screen is right, and nothing was answered on the way — history is not
    /// a live query, and a stale reply reaching a program that already had one is worse than
    /// silence.
    func testARingThatWrappedWhileAwayReplaysACutAndTheEmulatorRecovers() throws {
        let socketPath = try startDaemon()
        let overflowComplete = directory.appendingPathComponent("overflow.done")

        let first = try makeSession()
        first.hostTransportFactory = factory(socketPath: socketPath)
        first.start(plan: plan(
            "printf ALPHA; sleep 2; printf '\\033[>c'; "
                + "head -c \(Fixture.overflowBytes) /dev/zero | tr '\\\\0' x; "
                + "printf '\\r\\nTAILMARK'; : > \(overflowComplete.path); sleep 60"
        ))
        XCTAssertTrue(
            pump(until: { first.visibleScreenLines().contains { $0.contains("ALPHA") } }),
            "the child never started"
        )
        XCTAssertTrue(first.detachFromHost(by: Date().addingTimeInterval(2)))
        XCTAssertTrue(
            pump(
                until: { FileManager.default.fileExists(atPath: overflowComplete.path) },
                timeout: Fixture.childTimeout
            ),
            "the child did not finish writing enough bytes to wrap the ring"
        )

        let holdings = try holdings(socketPath: socketPath)
        let summary = try XCTUnwrap(holdings.sessions.first)

        // The same conversation, on a new surface: a relaunch builds this session's
        // controller afresh, and the id is what the daemon is holding the child under.
        let second = try makeSession(identity: first.identity)
        var fed = Data()
        second.onRawOutput = { fed.append($0) }
        var answers: [Data] = []
        second.terminalView.onInputBytes = { answers.append(Data($0)) }
        second.hostTransportFactory = factory(socketPath: socketPath)
        XCTAssertTrue(second.attachToHost(grid: summary.grid))

        XCTAssertTrue(
            pump(
                until: { second.visibleScreenLines().contains { $0.contains("TAILMARK") } },
                timeout: Fixture.childTimeout
            ),
            "the rejoined emulator never recovered the current screen"
        )
        XCTAssertEqual(
            fed.first,
            PTYHostReattachDaemonTests.cancel,
            "a rejoin that could not be proved exact owes the watcher an explicit cut, first — "
                + "cutting the head off the ring means the replay can begin inside a sequence too"
        )
        XCTAssertTrue(
            answers.isEmpty,
            "a replayed query is history, and answering it sends a stale reply to a live program"
        )
    }

    // MARK: - The durable grid

    /// The child's own terminal never changes size across a whole quit-and-relaunch, and changes
    /// exactly once when the window it comes back to is genuinely different.
    ///
    /// Asserted on what the *child* wrote down rather than on what crossed the wire, because that
    /// is the only assertion that can tell a daemon which resized the terminal from one that sent
    /// the right frames — and because a replayed screen would put an earlier size line back on
    /// this emulator, so the screen cannot be the witness here.
    ///
    /// The child polls `stty size` and appends a line only when the answer changes, rather than
    /// trapping `SIGWINCH`: the size is the fact that matters — a signal carrying the size the
    /// terminal already had would cost nothing — and a poll depends on no shell's trap semantics.
    func testTheGridSurvivesARelaunchWithTheChildObservingNoWindowChange() throws {
        let socketPath = try startDaemon()
        let log = directory.appendingPathComponent("winsize.log", isDirectory: false)

        let first = try makeSession()
        first.hostTransportFactory = factory(socketPath: socketPath)
        first.start(plan: plan(
            "last=; i=0; while [ \"$i\" -lt \(Fixture.sizePollIterations) ]; do now=$(stty size); "
                + "if [ \"$now\" != \"$last\" ]; then printf '%s\\n' \"$now\" >> \(log.path); "
                + "last=$now; fi; i=$((i + 1)); sleep 0.2; done"
        ))
        XCTAssertTrue(
            pump(until: { self.sizeLines(in: log) >= 1 }),
            "the child never reported the size it was spawned at"
        )
        XCTAssertEqual(sizeLines(in: log), 1, "a spawn sets the winsize; it does not change it")

        XCTAssertTrue(first.detachFromHost(by: Date().addingTimeInterval(2)))

        // The relaunch, into a window of exactly the size the last one had.
        let holdings = try holdings(socketPath: socketPath)
        let summary = try XCTUnwrap(holdings.sessions.first)
        // The same conversation, on a new surface: a relaunch builds this session's
        // controller afresh, and the id is what the daemon is holding the child under.
        let second = try makeSession(identity: first.identity)
        second.hostTransportFactory = factory(socketPath: socketPath)
        XCTAssertTrue(second.attachToHost(grid: summary.grid))
        _ = pump(until: { false }, timeout: Fixture.quietWindow)

        XCTAssertEqual(
            sizeLines(in: log),
            1,
            "reattaching a Threading that has just restarted must not reflow an agent that kept "
                + "working the whole time"
        )
        XCTAssertEqual(second.terminalView.terminalDimensions.cols, summary.grid.cols)
        XCTAssertEqual(second.terminalView.terminalDimensions.rows, summary.grid.rows)

        // And a window that genuinely moved is a real change, once.
        second.terminalView.frame = Fixture.widerFrame
        second.terminalView.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            pump(until: { self.sizeLines(in: log) >= 2 }),
            "a genuinely different window has to reach the child"
        )
        _ = pump(until: { false }, timeout: Fixture.quietWindow)
        XCTAssertEqual(sizeLines(in: log), 2, "one window change is one change of the child's size")
    }

    /// A link that was lost takes its unsent window size with it, and the child still ends on
    /// the grid the window has when somebody is watching it again.
    ///
    /// The transport is killed under a live session, which is what a crash, a daemon that stopped
    /// reading, or a socket that went away all look like from here: the child keeps working at
    /// the last grid it was told, and this app has no way to tell it anything. What closes the
    /// gap is the reattach — the daemon's grid arrives in `attached` and is compared with the one
    /// this window actually has, so exactly one resize follows a window that is genuinely
    /// different and none follows one that is not.
    func testAChildEndsOnTheGridTheWindowHasAfterItsLinkWasLost() throws {
        let socketPath = try startDaemon()
        let log = directory.appendingPathComponent("winsize.log", isDirectory: false)

        let box = ClientBox()
        let first = try makeSession()
        first.hostTransportFactory = factory(socketPath: socketPath, box: box)
        first.start(plan: plan(
            "last=; i=0; while [ \"$i\" -lt \(Fixture.sizePollIterations) ]; do now=$(stty size); "
                + "if [ \"$now\" != \"$last\" ]; then printf '%s\\n' \"$now\" >> \(log.path); "
                + "last=$now; fi; i=$((i + 1)); sleep 0.2; done"
        ))
        XCTAssertTrue(
            pump(until: { self.sizeLines(in: log) >= 1 }),
            "the child never reported the size it was spawned at"
        )

        first.terminalView.frame = Fixture.widerFrame
        first.terminalView.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            pump(until: { self.sizeLines(in: log) >= 2 }),
            "an ordinary window change has to reach the child"
        )
        let wide = first.terminalView.terminalDimensions

        // The link goes away under a working child.
        try XCTUnwrap(box.client).close()
        XCTAssertTrue(
            pump(until: { !first.isRunning }),
            "a link that dropped is still the end of this terminal"
        )

        let holdings = try holdings(socketPath: socketPath)
        let summary = try XCTUnwrap(holdings.sessions.first)
        XCTAssertNil(summary.exit, "the child is supposed to have kept working")
        XCTAssertEqual(
            summary.grid.cols,
            wide.cols,
            "the daemon keeps the last grid it was told, indefinitely"
        )

        // The relaunch, into a window that is a different size again.
        let second = try makeSession(identity: first.identity)
        second.hostTransportFactory = factory(socketPath: socketPath, box: ClientBox())
        XCTAssertTrue(second.attachToHost(grid: summary.grid))
        XCTAssertTrue(pump(until: { second.shellPid > 0 }), "the daemon never handed it back")

        second.terminalView.frame = Fixture.smallerFrame
        second.terminalView.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            pump(until: { self.sizeLines(in: log) >= 3 }),
            "the window this session came back into never reached the child"
        )
        let now = second.terminalView.terminalDimensions
        XCTAssertEqual(
            lastSizeLine(in: log),
            "\(now.rows) \(now.cols)",
            "the child has to end on the grid the window actually has"
        )
        _ = pump(until: { false }, timeout: Fixture.quietWindow)
        XCTAssertEqual(sizeLines(in: log), 3, "one window change is one change of the child's size")
    }

    // MARK: - Measurement

    /// D14's measurement: taking eight sessions back against starting eight.
    ///
    /// Opt-in, because it is a wall-clock benchmark rather than a behaviour test, and because the
    /// three series together spend about a minute. `THREADING_PTY_HOST_REATTACH_STRESS=1` runs it;
    /// `..._SESSIONS` and `..._RUNS` narrow it to one point.
    ///
    /// **Both sides run the same cheap child** — `/bin/sh -c cat` — on purpose. A real relaunch is
    /// `--resume` into an agent CLI whose own boot dominates everything either path does, and
    /// measuring that would be measuring Claude. What is being compared here is *our* two paths:
    /// one connect, one `list` and eight attaches against eight `forkpty`s. The numbers and what
    /// they do **not** cover are recorded in `docs/architecture/performance.md`.
    func testStressReattachAgainstRelaunchWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment[Stress.gate] == "1",
            "set \(Stress.gate)=1 to measure taking sessions back against starting them"
        )
        let count = environment[Stress.sessions].flatMap(Int.init) ?? Stress.defaultSessions
        let runs = environment[Stress.runs].flatMap(Int.init) ?? Stress.defaultRuns
        let socketPath = try startDaemon()

        var hostSpawn: [TimeInterval] = []
        var reattach: [TimeInterval] = []
        var localSpawn: [TimeInterval] = []

        for _ in 0..<runs {
            // 1. Eight children in the daemon. The surfaces are built *before* the clock starts:
            //    manufacturing a fixture is not the operation, and every series pays it equally.
            var spawned: [TerminalSession] = []
            for _ in 0..<count {
                let session = try makeSession()
                session.hostTransportFactory = factory(socketPath: socketPath)
                spawned.append(session)
            }
            let identities = spawned.map(\.identity)
            let spawnStart = Date()
            for session in spawned { session.start(plan: plan(Stress.script)) }
            XCTAssertTrue(pump(until: { spawned.allSatisfy { $0.shellPid > 0 } }))
            hostSpawn.append(Date().timeIntervalSince(spawnStart))

            // 2. The quit. Not timed: it is bounded by a deadline rather than by work.
            for session in spawned {
                XCTAssertTrue(session.detachFromHost(by: Date().addingTimeInterval(2)))
            }

            // 3. The relaunch, from the question a launch actually asks to all eight ready.
            var taken: [TerminalSession] = []
            for identity in identities {
                let session = try makeSession(identity: identity)
                session.hostTransportFactory = factory(socketPath: socketPath)
                taken.append(session)
            }
            let reattachStart = Date()
            let held = try holdings(socketPath: socketPath)
            let grids = Dictionary(
                held.sessions.map { ($0.id.identity, $0.grid) },
                uniquingKeysWith: { first, _ in first }
            )
            for session in taken {
                XCTAssertTrue(session.attachToHost(grid: try XCTUnwrap(grids[session.identity])))
            }
            XCTAssertTrue(pump(until: { taken.allSatisfy { $0.shellPid > 0 } }))
            reattach.append(Date().timeIntervalSince(reattachStart))
            for session in taken { session.terminate() }

            // 4. The same eight children, started in this process — today's relaunch with the
            //    agent's own boot taken out of it.
            var local: [TerminalSession] = []
            for _ in 0..<count { local.append(try makeSession()) }
            let localStart = Date()
            for session in local { session.start(plan: plan(Stress.script)) }
            XCTAssertTrue(pump(until: { local.allSatisfy { $0.shellPid > 0 } }))
            localSpawn.append(Date().timeIntervalSince(localStart))
            for session in local { session.terminate() }
        }

        print(
            """
            pty-host-reattach-stress sessions=\(count) runs=\(runs) \
            reattach_median_ms=\(Self.milliseconds(median(reattach))) \
            host_spawn_median_ms=\(Self.milliseconds(median(hostSpawn))) \
            local_spawn_median_ms=\(Self.milliseconds(median(localSpawn)))
            """
        )
    }

    private enum Stress {
        static let gate = "THREADING_PTY_HOST_REATTACH_STRESS"
        static let sessions = "THREADING_PTY_HOST_REATTACH_STRESS_SESSIONS"
        static let runs = "THREADING_PTY_HOST_REATTACH_STRESS_RUNS"
        static let defaultSessions = 8
        static let defaultRuns = 5
        /// Cheap, quiet, and it keeps its pty open until somebody ends it.
        static let script = "cat"
    }

    private func median(_ samples: [TimeInterval]) -> TimeInterval {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private static func milliseconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds * 1000)
    }

    // MARK: - Helpers

    private static let cancel: UInt8 = 0x18
    /// `RemoteScreenSeed`'s first byte: the repaint opens by entering the alternate buffer.
    private static let escape: UInt8 = 0x1B

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

    /// The same shipping factory, keeping the client so a test can take the link away.
    private func factory(socketPath: String, box: ClientBox) -> PTYHostTransportFactory {
        { events in
            let client = PTYHostClient(socketPath: socketPath, build: "test", events: events)
            try client.connect()
            box.adopt(client)
            return client
        }
    }

    /// The shipping survey against the scratch daemon.
    ///
    /// Blocking, which production forbids on the main actor and a test may do: the client answers
    /// on its own queue, so nothing here waits on the main queue it is holding.
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

    /// How many size lines the child has written. `stty size` prints "rows cols".
    private func sizeLines(in log: URL) -> Int {
        writtenSizes(in: log).count
    }

    /// The last size the child observed, which is the one that says where it ended up.
    private func lastSizeLine(in log: URL) -> String? {
        writtenSizes(in: log).last
    }

    private func writtenSizes(in log: URL) -> [String] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                let parts = line.split(separator: " ")
                return parts.count == 2 && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
            }
    }

    /// Where the shipping daemon is, whichever way this suite was started.
    ///
    /// `Bundle.main` is Threading.app under `xcodebuild test` and the *tool* under the direct
    /// `xcrun xctest` invocation `performance.md` uses to give an env-gated workload its gate past
    /// a sanitizing test plan. The test bundle is inside the app either way, so it is the anchor
    /// that answers in both.
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
        throw XCTSkip(
            "no \(Fixture.helperName) in this bundle — build the Threading target, which embeds "
                + "it through the Embed Extension Helpers phase, and run the hosted test target"
        )
    }

    private func startDaemon() throws -> String {
        let helper = try helperURL()
        let socketPath = directory.appendingPathComponent("d.sock").path
        let daemon = try DaemonHelperProcess(
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
        let session = TerminalSession(
            frame: Fixture.frame,
            identity: identity
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

// MARK: - The link a test can take away

/// Holds the client the factory built, across the `@Sendable` boundary the factory is.
private final class ClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: PTYHostClient?

    var client: PTYHostClient? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func adopt(_ client: PTYHostClient) {
        lock.lock()
        storage = client
        lock.unlock()
    }
}

// MARK: - The daemon, as the process it ships as

/// `threading-ptyd`, launched by hand against a scratch socket.
///
/// A local copy rather than a shared fixture, for the reason `PTYHostSessionDaemonTests` gives
/// beside its own: each of these suites drives the daemon from a different height, and a shared
/// harness would have to grow all of their jobs.
private final class DaemonHelperProcess: @unchecked Sendable {

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

    func shutdown() -> Bool {
        let drained = PTYHostTestProcessCleanup.stopSessionsAndRetire(socketPath: socketPath)
        let exited = waitUntilExited(timeout: PTYHostTestProcessCleanup.childTimeout)
        if !exited, process.isRunning {
            // Last resort for a broken fixture. Every test child has a finite lifetime and the
            // runner's token guard owns the remaining process tree; ordinary cleanup never takes
            // this branch because killing the daemon before its groups is the leak being fixed.
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
