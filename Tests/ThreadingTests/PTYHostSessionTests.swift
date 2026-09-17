import AppKit
import Darwin
import Dispatch
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest
@testable import Threading

/// A `TerminalSession` whose child lives in `threading-ptyd`, driven by a fake link.
///
/// **No daemon, no socket, no pty and no window.** Everything below `PTYHostSessionTransport` was
/// already proven by `PTYHostClientTests` against a real codec and by `PTYHostDaemonTests` against
/// the real binary; what is worth asserting here is what the *session* does with it — and the
/// claim host-backing makes is that the answer is "exactly what it did before". So every
/// assertion below is written against the behaviour the in-process path already has: the same two
/// activity callbacks in the same order, a keystroke that reaches the child, a resize that carries
/// pixels, a termination that goes through one ending.
@MainActor
final class PTYHostSessionTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        /// A genuinely different grid, so `processSizeChange` reaches the delegate rather than
        /// deciding nothing moved.
        static let resizedFrame = NSRect(x: 0, y: 0, width: 900, height: 620)
        /// Long enough for a queued main-queue hop, short enough that a wedge is a failure rather
        /// than a wait.
        static let settle: TimeInterval = 0.2
        static let childPid: pid_t = 42_424
        static let otherGroup: pid_t = 51_512
    }

    // MARK: - Fixture state

    private var sessions: [TerminalSession] = []
    private var recorders: [Recorder] = []
    private var windows: [NSWindow] = []

    override func tearDown() {
        for session in sessions { session.terminate() }
        sessions.removeAll()
        recorders.removeAll()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Output

    /// Bytes from the host render into the emulator and fire the **same two callbacks in the same
    /// order** the local path fires: the count first, then the bytes.
    ///
    /// The order is the whole assertion. `SessionActivityTracker` reads the count and the remote
    /// mirror reads the bytes, and a session that swapped them would still look right on screen
    /// while a phone watching it received a repaint the Mac had not yet counted.
    func testFedBytesRenderAndFireTheActivityHooksInTheLocalOrder() throws {
        let link = try startHostBackedSession()
        let recorder = link.recorder

        var order: [String] = []
        recorder.onOutputCount = { order.append("count:\($0)") }
        link.session.onRawOutput = { order.append("bytes:\($0.count)") }

        link.transport.send(output: Array("hello".utf8))
        settle()

        XCTAssertEqual(
            order,
            ["count:5", "bytes:5"],
            "the fed path must fire onOutput before onOutputBytes, as the local path does"
        )
        XCTAssertTrue(
            link.session.visibleScreenLines().contains { $0.contains("hello") },
            "the bytes never reached the emulator this session still owns"
        )
    }

    /// Several parsed frames in one burst are one main-actor report and one pair of callbacks.
    ///
    /// A hop per frame would put a terminal's whole output rate on the main queue, which is the
    /// shape `performance.md`'s scaling gate refuses.
    func testABurstOfFramesCoalescesIntoOneMainActorReport() throws {
        let link = try startHostBackedSession()
        var counts: [Int] = []
        link.recorder.onOutputCount = { counts.append($0) }

        link.transport.send(output: Array("one".utf8))
        link.transport.send(output: Array("two".utf8))
        link.transport.send(output: Array("three".utf8))
        settle()

        XCTAssertEqual(counts.reduce(0, +), 11, "no byte may be dropped by the coalescer")
        XCTAssertLessThan(
            counts.count,
            3,
            "three frames arriving together must not cost three main-queue hops"
        )
    }

    /// Parsing is the byte-sized half of output delivery and must not wait behind AppKit work.
    ///
    /// `FakeHostTransport.send(output:)` enters the transport queue synchronously while this
    /// test deliberately keeps the main actor on the current turn. A host path that schedules
    /// the whole feed on main leaves `bytesFed` at zero here; the local-process path parses on
    /// its IO worker, and the hosted path has to preserve that boundary. Activity callbacks
    /// remain main-actor work and are asserted separately after the run loop advances.
    func testLiveOutputParsesBeforeTheMainActorDeliveryTurn() throws {
        let link = try startHostBackedSession()
        let bytes = Array("codex repaint".utf8)
        var counts: [Int] = []
        link.recorder.onOutputCount = { counts.append($0) }
        link.session.terminalView.resetDiagnostics()

        link.transport.send(output: bytes)

        XCTAssertEqual(
            link.session.terminalView.diagnostics.bytesFed,
            bytes.count,
            "PTY-host parsing must run on the transport queue, before main-actor reporting"
        )
        XCTAssertTrue(
            counts.isEmpty,
            "activity callbacks still belong to the coalesced main-actor delivery"
        )

        settle()
        XCTAssertEqual(counts, [bytes.count])
    }

    // MARK: - Input

    /// A keystroke becomes an `input` frame, and never a write to the view's own `LocalProcess`.
    ///
    /// The second half matters as much as the first: the class is unchanged and its inherited
    /// process is still there, so the thing that keeps a host-backed keystroke from vanishing into
    /// a child that was never started is the branch in `send(source:data:)`.
    func testAKeystrokeBecomesAnInputFrameAndNotAProcessWrite() throws {
        let link = try startHostBackedSession()

        link.session.terminalView.sendUserText("ls\r")
        settle()

        XCTAssertEqual(
            link.transport.inputs.map { String(decoding: $0, as: UTF8.self) },
            ["ls\r"]
        )
        XCTAssertFalse(
            link.session.terminalView.process.running,
            "a host-backed terminal must never have started a local child"
        )
        XCTAssertEqual(link.session.terminalView.process.shellPid, 0)
    }

    // MARK: - Query replies

    func testACutReplayBellIsSilentButANewLiveBellStillArrives() throws {
        let hosted = try makeHostedTerminalView()
        var bells = 0
        hosted.view.onBell = { bells += 1 }
        hosted.view.feedFromHost([0x07], answersQueries: false)
        settle()
        XCTAssertEqual(bells, 0, "history cannot ring or raise a fresh attention episode")

        hosted.view.feedFromHost([0x07], answersQueries: true)
        settle()
        XCTAssertEqual(bells, 1, "a new bell must survive the end of replay suppression")
    }

    /// A live `DA2` is answered; a replayed one is not.
    ///
    /// P1's rule, asserted the only way it can be: by counting what left towards the child. The
    /// exact-replay branch carries bytes no emulator has ever seen and must answer them; the cut
    /// branch is history, and a stale `DA` reply arriving at a program that already got one is
    /// worse than silence.
    func testADeviceAttributesQueryIsAnsweredLiveAndSuppressedOnAReplay() throws {
        let answered = try makeHostedTerminalView()
        answered.view.feedFromHost(Self.deviceAttributesQuery, answersQueries: true)
        settle()
        XCTAssertEqual(
            answered.inputs.count,
            1,
            "a live DA2 must be answered through the host's input frame"
        )

        let suppressed = try makeHostedTerminalView()
        suppressed.view.feedFromHost(Self.deviceAttributesQuery, answersQueries: false)
        settle()
        XCTAssertEqual(
            suppressed.inputs.count,
            0,
            "a replayed DA2 is history, and answering it sends a stale reply to a live program"
        )

        // And the suppression is exactly as wide as the feed that asked for it.
        suppressed.view.feedFromHost(Self.deviceAttributesQuery, answersQueries: true)
        settle()
        XCTAssertEqual(suppressed.inputs.count, 1, "suppression must not outlive its own feed")
    }

    // MARK: - The window size

    /// A frame change emits a `resize` carrying the whole `winsize`, pixels included.
    ///
    /// A program that asks for pixel dimensions is told zero if they are dropped in transit, which
    /// is why the grid on the wire is four numbers rather than two.
    func testAFrameResizeEmitsAResizeFrameWithPixelDimensions() throws {
        let link = try startHostBackedSession()
        let before = link.transport.resizes.count

        link.session.terminalView.frame = Fixture.resizedFrame
        link.session.terminalView.layoutSubtreeIfNeeded()
        settle()

        let resize = try XCTUnwrap(link.transport.resizes.dropFirst(before).first)
        XCTAssertGreaterThan(resize.grid.cols, 0)
        XCTAssertGreaterThan(resize.grid.rows, 0)
        XCTAssertGreaterThan(
            resize.grid.xpixel,
            0,
            "ws_xpixel is part of the window size and has to cross the wire"
        )
        XCTAssertGreaterThan(resize.grid.ypixel, 0)
    }

    /// A window size the view produced while the spawn was still in flight is not lost: it is
    /// held and sent the moment the daemon says the session exists.
    ///
    /// The view lays out during a launch, so this is the ordinary case rather than a corner one.
    /// A `resize` before `spawned` names a session the daemon has not created yet, and the frame
    /// is fire-and-forget — nothing would say it had been thrown away — so the grid is recorded
    /// first and delivered at the convergence point.
    func testAResizeDuringTheSpawnIsHeldAndSentWhenTheChildExists() throws {
        let pending = try startHostBackedSession(confirmingSpawn: false)

        pending.session.terminalView.frame = Fixture.resizedFrame
        pending.session.terminalView.layoutSubtreeIfNeeded()
        settle()
        XCTAssertTrue(
            pending.transport.resizes.isEmpty,
            "there is no session on the other end to resize until the daemon says there is"
        )

        let wanted = pending.session.terminalView.terminalDimensions
        pending.transport.send(.spawned(PTYHostSpawned(
            id: pending.identity,
            pid: Fixture.childPid,
            startTime: PTYHostProcessStartTime(seconds: 1, microseconds: 2)
        )))
        settle()

        XCTAssertEqual(
            pending.transport.resizes.count,
            1,
            "the grid the view settled on has to reach the child, once"
        )
        XCTAssertEqual(pending.transport.resizes.first?.grid.cols, wanted.cols)
        XCTAssertEqual(pending.transport.resizes.first?.grid.rows, wanted.rows)
    }

    /// A resize the transport refused is not an ending, and it is not forgotten either.
    ///
    /// This is the bug the reconciliation exists for, at the seam where it starts: `resize` has
    /// an answering frame but no retry of its own, so a refused write used to leave the child on
    /// one grid and the emulator on another until the window happened to move again — and the
    /// agent's own lines came back wrapped mid-word. Bytes arriving are the evidence that the
    /// transport is current again.
    func testARefusedResizeIsNotAnEndingAndReachesTheChildAfterwards() throws {
        let link = try startHostBackedSession()
        link.transport.refuseResizes(true)

        link.session.terminalView.frame = Fixture.resizedFrame
        link.session.terminalView.layoutSubtreeIfNeeded()
        settle()

        let wanted = link.session.terminalView.terminalDimensions
        XCTAssertEqual(link.transport.refusedResizes, 1, "the fixture has to have dropped one")
        XCTAssertTrue(link.transport.resizes.isEmpty, "nothing can have reached the daemon")
        XCTAssertTrue(
            link.recorder.exitCodes.isEmpty,
            "a window size that could not be written is not a terminal that died"
        )
        XCTAssertTrue(link.session.isHostBacked)

        link.transport.refuseResizes(false)
        link.transport.send(output: Array("working".utf8))
        settle()

        XCTAssertEqual(
            link.transport.resizes.count,
            1,
            "the grid the view is on has to reach the child once the transport is current"
        )
        XCTAssertEqual(link.transport.resizes.first?.grid.cols, wanted.cols)
        XCTAssertEqual(link.transport.resizes.first?.grid.rows, wanted.rows)

        // And it is one frame, not a retry loop: the daemon's answer ends the exchange.
        link.transport.send(.resized(PTYHostResized(
            id: link.identity,
            grid: try XCTUnwrap(link.transport.resizes.first?.grid)
        )))
        link.transport.send(output: Array("more".utf8))
        settle()
        XCTAssertEqual(link.transport.resizes.count, 1)
    }

    /// The daemon holding the grid already is the end of it: nothing is sent for a size it has
    /// just reported, and nothing is sent twice for a size it has acknowledged.
    func testAGridTheHostAlreadyHoldsIsNeverSentBack() throws {
        let link = try startHostBackedSession()
        let before = link.transport.resizes.count

        guard case .pty(let inForce)? = link.transport.spawnRequest?.channel else {
            return XCTFail("version 1 spawns a pseudo-terminal")
        }
        link.transport.send(.resized(PTYHostResized(id: link.identity, grid: inForce)))
        link.transport.send(output: Array("idle".utf8))
        settle()

        XCTAssertEqual(
            link.transport.resizes.count,
            before,
            "an acknowledgement of the grid in force is not a reason to send anything"
        )
    }

    // MARK: - The spawn

    /// The daemon is handed the app's own launch, verbatim, and the real grid.
    func testTheSpawnCarriesThePlanTheEnvironmentAndTheLaidOutGrid() throws {
        let link = try startHostBackedSession()
        let spawn = try XCTUnwrap(link.transport.spawnRequest)

        XCTAssertEqual(spawn.executable, Self.plan.executable)
        XCTAssertEqual(spawn.arguments, Self.plan.arguments)
        XCTAssertEqual(spawn.execName, "sh")
        XCTAssertNil(spawn.cwd, "a terminal launch carries its directory inside the command line")
        XCTAssertEqual(
            Set(spawn.environment),
            Set(link.session.buildEnvironment()),
            "the daemon adds nothing, so the app has to compose all of it"
        )

        guard case .pty(let grid) = spawn.channel else {
            return XCTFail("version 1 spawns a pseudo-terminal")
        }
        XCTAssertGreaterThan(grid.cols, 2, "SwiftTerm's unlaid-out clamp must never be spawned")
        XCTAssertGreaterThan(grid.rows, 1)
    }

    /// The pid the daemon reports is what keeps the working directory and the process inspector
    /// answering for a session whose pty moved out of this process.
    func testTheReportedPidBecomesTheSessionsShellPid() throws {
        let link = try startHostBackedSession()
        XCTAssertEqual(link.session.shellPid, Fixture.childPid)
        XCTAssertEqual(link.recorder.startCount, 1)
        XCTAssertTrue(link.session.isHostBacked)
    }

    // MARK: - The foreground group

    /// `tcgetpgrp` has no socket equivalent, so the daemon pushes the answer instead.
    ///
    /// Both halves of the nil rule are asserted, because they are the same rule the local reading
    /// follows: the session's own command holding the terminal is *not* another program.
    func testAForegroundFrameDecidesWhetherAnotherProgramHoldsTheTerminal() throws {
        let link = try startHostBackedSession()

        XCTAssertFalse(
            link.session.foregroundIsAnotherProgram(),
            "nothing has been reported yet, and -1 is not a descriptor to guess from"
        )

        link.transport.send(.foreground(PTYHostForeground(
            id: link.identity,
            processGroup: Fixture.childPid
        )))
        settle()
        XCTAssertFalse(
            link.session.foregroundIsAnotherProgram(),
            "the session's own command in the foreground is not another program"
        )

        link.transport.send(.foreground(PTYHostForeground(
            id: link.identity,
            processGroup: Fixture.otherGroup
        )))
        settle()
        XCTAssertTrue(link.session.foregroundIsAnotherProgram())
        XCTAssertTrue(
            link.session.refreshForegroundProcess(),
            "the once-a-second reading follows the pushed frame too"
        )
        XCTAssertTrue(link.session.hasForegroundProcess)
    }

    // MARK: - Endings

    /// An `exited` frame drives the same ending an in-process exit drives.
    func testAnExitedFrameDrivesTheTerminationPath() throws {
        let link = try startHostBackedSession()
        let drained = expectation(description: "the host may now be idle")
        drained.assertForOverFulfill = true
        let observations = AppEventObservations()
        observations.observe(PTYHostMayHaveDrained.self) { _ in drained.fulfill() }

        link.transport.send(.exited(PTYHostExited(id: link.identity, status: 3, signalled: false)))
        settle()
        wait(for: [drained], timeout: Fixture.settle)

        XCTAssertEqual(link.recorder.exitCodes, [3])
        XCTAssertFalse(link.session.isRunning)
        XCTAssertFalse(link.session.isHostBacked)
        XCTAssertEqual(link.session.shellPid, 0)
        XCTAssertTrue(
            link.transport.isClosed,
            "the connection has to go with the session it was one session's connection for"
        )
    }

    /// A selected host is an ownership promise. A refusal remains a launch failure instead of
    /// silently creating an app-owned child that the next app restart would kill.
    func testASpawnRefusalDoesNotFallBackToAnInProcessLaunch() throws {
        let session = makeSession()
        let recorder = Recorder()
        recorders.append(recorder)
        session.delegate = recorder

        let box = TransportBox()
        session.hostTransportFactory = { events in
            let transport = FakeHostTransport(events: events)
            box.adopt(transport)
            return transport
        }
        // A child that outlives the run-loop turn below, so "the launch happened" is observable.
        session.start(plan: Self.livePlan)
        let transport = try XCTUnwrap(box.transport)
        XCTAssertTrue(session.isHostBacked)

        transport.send(.spawnRefused(PTYHostSpawnRefused(
            id: PTYHostSessionIdentity(session.identity),
            reason: .capacity
        )))
        settle()

        XCTAssertTrue(recorder.exitCodes.isEmpty, "a refusal is not an ending")
        XCTAssertFalse(session.isHostBacked)
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.terminalView.process.running)
        XCTAssertEqual(recorder.launchFailures.map(\.cause), ["spawnRefused.capacity"])
    }

    /// A signalled child has no exit code, on both paths — `LocalProcess.exitCode(fromWaitStatus:)`
    /// answers nil for exactly this case, and the delegate contract says nil means "no status".
    func testASignalledChildIsReportedWithNoExitCode() throws {
        let link = try startHostBackedSession()

        link.transport.send(.exited(PTYHostExited(id: link.identity, status: 9, signalled: true)))
        settle()

        XCTAssertEqual(link.recorder.exitCodes.count, 1)
        XCTAssertNil(link.recorder.exitCodes.first ?? nil)
    }

    /// Stopping a host-backed session sends `kill` and never touches the view's own process.
    ///
    /// Until the detach slice lands this is also what keeps a stopped session from leaving an
    /// agent running in a process nothing references.
    func testTerminateSendsKillAndLeavesTheViewsProcessAlone() throws {
        let link = try startHostBackedSession()

        link.session.terminate()
        settle()

        XCTAssertEqual(link.transport.kills.count, 1)
        XCTAssertEqual(link.transport.kills.first?.id, link.identity)
        XCTAssertFalse(link.session.isRunning)
        XCTAssertNil(
            link.session.terminalView.hostTransport,
            "no keystroke may leave for a child that is being ended"
        )

        // The ending still arrives, because a watcher is owed it.
        link.transport.send(.exited(PTYHostExited(id: link.identity, status: 0, signalled: false)))
        settle()
        XCTAssertEqual(link.recorder.exitCodes, [0])
    }

    /// A link that drops ends the terminal rather than leaving it looking alive.
    func testALinkThatClosesEndsTheSessionWithNoExitStatus() throws {
        let link = try startHostBackedSession()

        link.transport.drop(.readFailed(errno: EPIPE))
        settle()

        XCTAssertEqual(link.recorder.exitCodes.count, 1)
        XCTAssertNil(link.recorder.exitCodes.first ?? nil)
        XCTAssertFalse(link.session.isHostBacked)
    }

    /// On a remote host a dropped link is the path ending, not the agent: the delegate is asked to
    /// reconnect and no exit is recorded, while the terminal stops claiming a live child.
    func testARemoteLinkThatClosesAsksToReconnectInsteadOfEnding() throws {
        let link = try startHostBackedSession(placement: .remote(environment: []))
        link.recorder.reconnects = true

        link.transport.drop(.readFailed(errno: EPIPE))
        settle()

        XCTAssertEqual(link.recorder.lostHostCauses.count, 1)
        XCTAssertTrue(link.recorder.exitCodes.isEmpty, "a dropped tunnel is not an exit")
        XCTAssertFalse(link.session.isRunning)
        XCTAssertFalse(link.session.isHostBacked)
        XCTAssertNil(link.session.terminalView.hostTransport)
    }

    /// A delegate that cannot reconnect gets today's ending.
    func testARemoteLinkThatClosesEndsWhenNobodyReconnects() throws {
        let link = try startHostBackedSession(placement: .remote(environment: []))

        link.transport.drop(.readFailed(errno: EPIPE))
        settle()

        XCTAssertEqual(link.recorder.lostHostCauses.count, 1)
        XCTAssertEqual(link.recorder.exitCodes.count, 1)
    }

    /// A remote child that really exits ends the session; reconnecting is only for a lost path.
    func testARemoteExitIsAnEndingNotALostConnection() throws {
        let link = try startHostBackedSession(placement: .remote(environment: []))
        link.recorder.reconnects = true

        link.transport.send(.exited(PTYHostExited(id: link.identity, status: 9, signalled: true)))
        settle()

        XCTAssertTrue(link.recorder.lostHostCauses.isEmpty)
        XCTAssertEqual(link.recorder.exitCodes.count, 1)
    }

    /// A local host's dropped link never asks to reconnect.
    func testALocalLinkThatClosesNeverAsksToReconnect() throws {
        let link = try startHostBackedSession()
        link.recorder.reconnects = true

        link.transport.drop(.readFailed(errno: EPIPE))
        settle()

        XCTAssertTrue(link.recorder.lostHostCauses.isEmpty)
        XCTAssertEqual(link.recorder.exitCodes.count, 1)
    }

    func testReconnectBackoffGrowsAndHoldsAtItsCeiling() {
        let delays = (0..<10).map(RemoteReconnectDefaults.delay(afterAttempt:))
        XCTAssertEqual(delays.first, RemoteReconnectDefaults.delays.first)
        XCTAssertEqual(delays.last, RemoteReconnectDefaults.delays.last)
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertEqual(RemoteReconnectDefaults.delay(afterAttempt: -1), RemoteReconnectDefaults.delays.first)
    }

    // MARK: - Degrading

    /// A factory failure cannot silently change a durable launch into an app-owned one.
    func testAFactoryThatThrowsRefusesTheLaunchWithoutFallingBack() throws {
        let session = makeSession()
        let recorder = Recorder()
        recorders.append(recorder)
        session.delegate = recorder
        session.hostTransportFactory = { _ in throw PTYHostClientError.connectTimedOut }
        session.start(plan: Self.plan)

        // Asserted before the run loop turns: the shell is `exit 0` and the point is which path
        // started it, not how long it lived.
        XCTAssertFalse(session.isHostBacked)
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.terminalView.process.running)
        XCTAssertEqual(recorder.launchFailures.map(\.cause), ["link.connectTimedOut"])
    }

    /// A session with no factory at all is byte-for-byte today's session.
    func testWithoutAFactoryNothingAboutTheLaunchChanges() throws {
        let session = makeSession()
        session.start(plan: Self.plan)

        XCTAssertFalse(session.isHostBacked)
        XCTAssertTrue(session.terminalView.process.running)
        XCTAssertGreaterThan(session.shellPid, 0)
        session.terminate()
    }

    // MARK: - The policy

    /// Session, then the hidden global, then off — the tri-state `fastMode` established.
    func testThePolicyResolvesSessionThenGlobalThenOff() {
        XCTAssertFalse(PTYHostPolicy.hostsSession(nil, whenEnabled: false))
        XCTAssertTrue(PTYHostPolicy.hostsSession(nil, whenEnabled: true))
        XCTAssertTrue(PTYHostPolicy.hostsSession(true, whenEnabled: false))
        XCTAssertTrue(PTYHostPolicy.hostsSession(true, whenEnabled: true))
        XCTAssertFalse(PTYHostPolicy.hostsSession(false, whenEnabled: false))
        XCTAssertFalse(
            PTYHostPolicy.hostsSession(false, whenEnabled: true),
            "a conversation that said no keeps saying no when the default changes"
        )
    }

    /// The same matrix through a stored conversation and an injected settings suite.
    func testThePolicyReadsTheSessionsOverrideOverTheHiddenGlobal() throws {
        let suiteName = "PTYHostSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        var session = AgentSession(kind: .claude, title: "t")
        XCTAssertNil(session.backgroundHost, "a new conversation inherits")
        XCTAssertFalse(PTYHostPolicy.hostsSession(session, settings: settings))

        settings.ptyHostEnabled = true
        XCTAssertTrue(PTYHostPolicy.hostsSession(session, settings: settings))

        session.backgroundHost = false
        XCTAssertFalse(PTYHostPolicy.hostsSession(session, settings: settings))
    }

    /// The surface clamp, and the fact that a refused surface costs nothing to refuse.
    func testOnlyAnAgentSessionIsEverHostBacked() throws {
        let suiteName = "PTYHostSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.ptyHostEnabled = true

        let session = AgentSession(kind: .claude, title: "t")
        for identity: TerminalInstanceIdentity in [
            .projectTerminal(TerminalID()),
            .sessionShell(SessionID()),
            .ephemeral(UUID())
        ] {
            guard case .local = PTYHostPolicy.launchRoute(
                for: identity,
                session: session,
                settings: settings,
                bundle: .main,
                probe: .unreachable()
            ) else {
                return XCTFail("\(identity) still polls a descriptor a hosted session lacks")
            }
        }
    }

    /// Not selecting hosting stays local; selecting it and finding no daemon is a typed refusal.
    func testAnUnavailableRequestedHostRefusesInsteadOfChangingOwnership() throws {
        let suiteName = "PTYHostSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        let session = AgentSession(kind: .claude, title: "t")
        // Off: decided before anything is opened, which is what makes asking on a launch cheap.
        guard case .local = PTYHostPolicy.launchRoute(
            for: .agentSession(SessionID()),
            session: session,
            settings: settings,
            bundle: .main,
            probe: .unreachable()
        ) else { return XCTFail("an unselected host should preserve the local launch") }

        settings.ptyHostEnabled = true
        guard case .unavailable(let failure) = PTYHostPolicy.launchRoute(
            for: .agentSession(SessionID()),
            session: session,
            settings: settings,
            bundle: .main,
            probe: .answering(.notRunning)
        ) else { return XCTFail("a requested unavailable host should refuse") }
        XCTAssertEqual(failure.cause, "notRunning")
    }

    func testANewSessionIsRefusedWhileAdmissionIsWithheld() throws {
        let suiteName = "PTYHostSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.ptyHostEnabled = true
        let admission = PTYHostNewSessionAdmission()
        admission.resolve(.withheld)

        guard case .unavailable(let failure) = PTYHostPolicy.launchRoute(
            for: .agentSession(SessionID()),
            session: AgentSession(kind: .codex, title: "t"),
            settings: settings,
            bundle: .main,
            probe: .unreachable(),
            eventLog: EventLog(directory: FileManager.default.temporaryDirectory),
            newSessionAdmission: admission
        ) else { return XCTFail("a withheld durable route should refuse") }
        XCTAssertEqual(failure.cause, "upgradePending")
    }

    // MARK: - The record

    /// The opt-in survives a round trip, and a record written before it existed reads as inherit.
    func testTheOptInRoundTripsAndOlderRecordsDecodeAsInherit() throws {
        var session = AgentSession(kind: .claude, title: "t")
        session.backgroundHost = true

        let encoded = try JSONEncoder().encode(session)
        XCTAssertEqual(
            try JSONDecoder().decode(AgentSession.self, from: encoded).backgroundHost,
            true
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["backgroundHost"] as? Bool, true)
        object.removeValue(forKey: "backgroundHost")
        let older = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(
            older.backgroundHost,
            "an absent key is no opinion, not a decision to stay in-process"
        )

        // And an explicit refusal is not the same value as no opinion.
        session.backgroundHost = false
        let refused = try JSONDecoder().decode(
            AgentSession.self,
            from: try JSONEncoder().encode(session)
        )
        XCTAssertEqual(refused.backgroundHost, false)
    }

    // MARK: - Helpers

    private static let deviceAttributesQuery: [UInt8] = Array("\u{1b}[>c".utf8)

    /// A child that is still there a run-loop turn later.
    private static let livePlan = AgentLaunchPlan(
        executable: "/bin/sh",
        arguments: ["-c", "sleep 5"],
        resumeState: .unavailable
    )

    private static let plan = AgentLaunchPlan(
        executable: "/bin/sh",
        arguments: ["-l", "-c", "exit 0"],
        resumeState: .unavailable
    )

    private struct HostedSession {
        let session: TerminalSession
        let transport: FakeHostTransport
        let recorder: Recorder
        let identity: PTYHostSessionIdentity
    }

    private func makeSession() -> TerminalSession {
        let session = TerminalSession(
            frame: Fixture.frame,
            identity: .agentSession(SessionID())
        )
        // An unshown, borderless host: the grid has to be real for the spawn to be honest, and a
        // detached view constrains nothing. Nothing is ordered on screen.
        let window = NSWindow(
            contentRect: Fixture.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = session.terminalView
        windows.append(window)
        session.terminalView.layoutSubtreeIfNeeded()
        sessions.append(session)
        return session
    }

    private func startHostBackedSession(
        confirmingSpawn: Bool = true,
        placement: PTYHostPlacement = .local
    ) throws -> HostedSession {
        let session = makeSession()
        session.hostPlacement = placement
        let recorder = Recorder()
        recorders.append(recorder)
        session.delegate = recorder

        let box = TransportBox()
        session.hostTransportFactory = { events in
            let transport = FakeHostTransport(events: events)
            box.adopt(transport)
            return transport
        }
        session.start(plan: Self.plan)

        let transport = try XCTUnwrap(box.transport, "the launch never reached the host")
        let identity = PTYHostSessionIdentity(session.identity)
        if confirmingSpawn {
            transport.send(.spawned(PTYHostSpawned(
                id: identity,
                pid: Fixture.childPid,
                startTime: PTYHostProcessStartTime(seconds: 1, microseconds: 2)
            )))
        }
        settle()

        return HostedSession(
            session: session,
            transport: transport,
            recorder: recorder,
            identity: identity
        )
    }

    /// A bare view wearing a host transport, for the assertions that are about the view alone.
    private func makeHostedTerminalView() throws -> (view: EmojiFixedTerminalView, inputs: Inbox) {
        let view = EmojiFixedTerminalView(frame: Fixture.frame)
        let window = NSWindow(
            contentRect: Fixture.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = view
        windows.append(window)
        view.layoutSubtreeIfNeeded()

        let inbox = Inbox()
        view.hostTransport = TerminalHostTransport(
            sendInput: { inbox.append($0) },
            sendWindowSize: { _ in true },
            kill: {}
        )
        return (view, inbox)
    }

    /// One turn of the main queue, which is where every delivery lands.
    private func settle(_ seconds: TimeInterval = Fixture.settle) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}

// MARK: - The fake link

/// What the session sent, and what the daemon would have said back.
///
/// Every member of `PTYHostSessionTransport` is recorded rather than performed, and the four event
/// closures are driven from the transport's own queue — the queue a real client delivers on — so
/// the main-queue hop under test is the production one.
private final class FakeHostTransport: PTYHostSessionTransport, @unchecked Sendable {

    let queue = DispatchQueue(label: "codes.threading.tests.ptyhost.fake")

    private let events: PTYHostClient.Events
    private let lock = NSLock()
    private var frames: [PTYHostFrame] = []
    private var inputStorage: [Data] = []
    private var closedStorage = false
    private var refusesResizesStorage = false
    private var refusedResizeCount = 0

    init(events: PTYHostClient.Events) {
        self.events = events
    }

    // MARK: - PTYHostSessionTransport

    func spawn(_ request: PTYHostSpawnRequest) throws { record(.spawn(request)) }
    func attach(_ request: PTYHostAttach) throws { record(.attach(request)) }

    /// Refuses while `refusesResizes` is set, exactly as a real client refuses a write on a
    /// transport that is not ready — the one failure a window size has to survive.
    func resize(_ request: PTYHostResize) throws {
        lock.lock()
        let refuses = refusesResizesStorage
        if refuses { refusedResizeCount += 1 }
        lock.unlock()
        if refuses { throw PTYHostClientError.notReady }
        record(.resize(request))
    }
    func detach(_ request: PTYHostDetach) throws { record(.detach(request)) }

    /// Meaningless on a terminal, and never sent by one — recorded so the test can say so.
    func closeInput(_ request: PTYHostCloseInput) throws { record(.closeInput(request)) }
    func kill(_ request: PTYHostKill) throws { record(.kill(request)) }

    /// Nothing is queued, so everything is always written.
    func drainWrites(until deadline: Date) -> Bool { true }

    func sendInput(_ bytes: Data) throws {
        lock.lock()
        inputStorage.append(bytes)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closedStorage = true
        lock.unlock()
    }

    // MARK: - What the session sent

    var inputs: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return inputStorage
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedStorage
    }

    /// How many resizes were refused, so a test can say the drop it is about really happened.
    var refusedResizes: Int {
        lock.lock()
        defer { lock.unlock() }
        return refusedResizeCount
    }

    func refuseResizes(_ refuses: Bool) {
        lock.lock()
        refusesResizesStorage = refuses
        lock.unlock()
    }

    var spawnRequest: PTYHostSpawnRequest? {
        sent.compactMap { frame -> PTYHostSpawnRequest? in
            guard case .spawn(let request) = frame else { return nil }
            return request
        }.first
    }

    var resizes: [PTYHostResize] {
        sent.compactMap { frame -> PTYHostResize? in
            guard case .resize(let request) = frame else { return nil }
            return request
        }
    }

    var kills: [PTYHostKill] {
        sent.compactMap { frame -> PTYHostKill? in
            guard case .kill(let request) = frame else { return nil }
            return request
        }
    }

    var attaches: [PTYHostAttach] {
        sent.compactMap { frame -> PTYHostAttach? in
            guard case .attach(let request) = frame else { return nil }
            return request
        }
    }

    var detaches: [PTYHostDetach] {
        sent.compactMap { frame -> PTYHostDetach? in
            guard case .detach(let request) = frame else { return nil }
            return request
        }
    }

    // MARK: - What the daemon would say

    func send(_ frame: PTYHostFrame) {
        queue.sync { events.frame(frame) }
    }

    func send(output bytes: [UInt8]) {
        queue.sync { events.output(Data(bytes)) }
    }

    func drop(_ error: PTYHostClientError?) {
        queue.sync { events.closed(error) }
    }

    // MARK: - Private Methods

    private var sent: [PTYHostFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    private func record(_ frame: PTYHostFrame) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }
}

/// Holds the transport the factory built, across the `@Sendable` boundary the factory is.
private final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: FakeHostTransport?

    var transport: FakeHostTransport? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func adopt(_ transport: FakeHostTransport) {
        lock.lock()
        storage = transport
        lock.unlock()
    }
}

/// Bytes a view sent towards its host.
private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func append(_ bytes: Data) {
        lock.lock()
        storage.append(bytes)
        lock.unlock()
    }
}

/// The session's delegate, recording exactly the edges this slice is about.
@MainActor
private final class Recorder: NSObject, TerminalSessionDelegate {
    var onOutputCount: ((Int) -> Void)?
    private(set) var exitCodes: [Int32?] = []
    private(set) var launchFailures: [PTYHostLaunchError] = []
    private(set) var startCount = 0

    func terminalSessionDidStart(_ session: TerminalSession) {
        startCount += 1
    }

    func terminalSession(_ session: TerminalSession, didFailToStart failure: PTYHostLaunchError) {
        launchFailures.append(failure)
    }

    func terminalSession(_ session: TerminalSession, didProduceOutputOf byteCount: Int) {
        onOutputCount?(byteCount)
    }

    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {
        exitCodes.append(exitCode)
    }

    var reconnects = false
    private(set) var lostHostCauses: [String] = []

    func terminalSessionDidLoseRemoteHost(_ session: TerminalSession, cause: String) -> Bool {
        lostHostCauses.append(cause)
        return reconnects
    }
}
