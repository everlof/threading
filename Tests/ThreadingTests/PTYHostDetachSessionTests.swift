import AppKit
import Darwin
import Dispatch
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest
@testable import Threading

/// Handing a session over instead of ending it, and taking one back, driven by a fake link.
///
/// **No daemon, no socket, no pty and no window on screen.** `PTYHostDaemonTests` already proves
/// the daemon's half of `detach`/`attach` against the real binary; what is worth asserting here is
/// what the *session* sends and what its emulator does with what comes back — above all that a
/// quit hands the child over rather than killing it, and that taking one back does not reflow an
/// agent that has been working at its own grid the whole time.
@MainActor
final class PTYHostDetachSessionTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        static let frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        /// A genuinely different frame, so a resize reaches the seam rather than deciding
        /// nothing moved.
        static let resizedFrame = NSRect(x: 0, y: 0, width: 900, height: 620)
        /// Deliberately unlike anything this frame implies, so adopting it is observable.
        static let hostGrid = PTYHostGrid(cols: 37, rows: 11, xpixel: 296, ypixel: 176)
        static let childPid: pid_t = 42_424
        static let settle: TimeInterval = 0.2
    }

    // MARK: - Fixture state

    private var sessions: [TerminalSession] = []
    private var recorders: [DetachRecorder] = []
    private var windows: [NSWindow] = []

    override func tearDown() {
        for session in sessions { session.terminate() }
        sessions.removeAll()
        recorders.removeAll()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Detach

    /// A quit sends `detach`, with both seeds and the offset this watcher had applied.
    ///
    /// The offset is the whole mechanism behind the next launch's exact replay, so it is asserted
    /// as a number rather than as "something was sent": one byte out and the rejoin either
    /// duplicates a byte or skips one.
    func testDetachSendsBothSeedsAndTheOffsetThisWatcherHadApplied() throws {
        let hosted = try startHostBackedSession()
        hosted.transport.send(output: Array("hello world".utf8))
        settle()

        XCTAssertTrue(hosted.session.detachFromHost(by: Date().addingTimeInterval(1)))

        let detach = try XCTUnwrap(hosted.transport.detaches.first)
        XCTAssertEqual(hosted.transport.detaches.count, 1)
        XCTAssertEqual(detach.id, hosted.identity)
        XCTAssertEqual(
            detach.ringOffset,
            UInt64("hello world".utf8.count),
            "the offset is the daemon's own byte count as of the last byte this watcher applied"
        )
        XCTAssertFalse(
            detach.screenSeed.isEmpty,
            "the daemon has no emulator, so the repaint is this process's to compute or nobody's"
        )
        XCTAssertFalse(detach.modeSeed.isEmpty)
    }

    /// Handing a session over is not ending it: nothing is killed and nobody is told it stopped.
    func testDetachNeitherKillsTheChildNorReportsAnEnding() throws {
        let hosted = try startHostBackedSession()

        XCTAssertTrue(hosted.session.detachFromHost(by: Date().addingTimeInterval(1)))
        settle()

        XCTAssertTrue(hosted.transport.kills.isEmpty, "a quit must not end somebody's agent")
        XCTAssertTrue(hosted.recorder.exitCodes.isEmpty, "nothing exited")
        XCTAssertFalse(hosted.session.isHostBacked)
        XCTAssertFalse(hosted.session.isRunning)
        XCTAssertNil(
            hosted.session.terminalView.hostTransport,
            "no keystroke may leave for a child this process no longer watches"
        )
    }

    /// An in-process session has nothing to hand over, and is still ended by the ordinary stop.
    ///
    /// The other half of the quit path: `terminateAll` falls through to `terminate()` for exactly
    /// the sessions that answer false here.
    func testAnInProcessSessionHasNothingToHandOverAndIsStillTerminated() throws {
        let session = makeSession()
        session.start(plan: AgentLaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            resumeState: .unavailable
        ))
        XCTAssertFalse(session.isHostBacked)
        XCTAssertTrue(session.terminalView.process.running)
        let childPid = session.shellPid
        XCTAssertGreaterThan(childPid, 0)

        XCTAssertFalse(
            session.detachFromHost(by: Date().addingTimeInterval(1)),
            "there is no daemon holding this child, so there is nothing to hand over"
        )
        XCTAssertTrue(session.isRunning, "a refused hand-over must not have stopped anything")

        session.terminate()
        XCTAssertTrue(
            waitUntil { Darwin.kill(childPid, 0) != 0 },
            "pid \(childPid) is still alive after an in-process session was terminated"
        )
    }

    // MARK: - Attach

    /// The daemon's grid is adopted, and the resize it would otherwise provoke never leaves.
    ///
    /// Telling the daemon the size it has just told us would raise `SIGWINCH` on an agent that has
    /// been working at that size all along, which is precisely the reflow reattaching must not
    /// cause. SwiftTerm reports the adopting resize through `onMain`, a turn later, by which time
    /// the link is installed — so this is a real frame that a real launch would have sent.
    func testAttachAdoptsTheHostsGridAndSendsNoResizeBack() throws {
        let attached = try reattachSession()
        settle()

        XCTAssertEqual(attached.session.terminalView.terminalDimensions.cols, Fixture.hostGrid.cols)
        XCTAssertEqual(attached.session.terminalView.terminalDimensions.rows, Fixture.hostGrid.rows)
        XCTAssertTrue(
            attached.transport.resizes.isEmpty,
            "an attach never resizes, and adopting a grid is not a window having changed"
        )
        XCTAssertEqual(attached.transport.attaches.count, 1)
        XCTAssertEqual(attached.transport.attaches.first?.id, attached.identity)
    }

    /// A genuinely different window is a real change and is sent exactly once.
    func testAWindowThatMovedWhileThreadingWasClosedSendsOneResize() throws {
        let attached = try reattachSession()
        settle()
        XCTAssertTrue(attached.transport.resizes.isEmpty)

        attached.session.terminalView.frame = Fixture.resizedFrame
        attached.session.terminalView.layoutSubtreeIfNeeded()
        settle()

        XCTAssertEqual(
            attached.transport.resizes.count,
            1,
            "one window change is one resize — not none, and not one per layout pass"
        )
        let resize = try XCTUnwrap(attached.transport.resizes.first)
        XCTAssertNotEqual(resize.grid.cols, Fixture.hostGrid.cols)
        XCTAssertGreaterThan(resize.grid.xpixel, 0, "the pixel pair travels with the cell pair")
    }

    /// The pid the daemon reports is what keeps the working directory and the process inspector
    /// answering for a session this process did not start.
    func testTheAttachedFrameRestoresTheChildsPid() throws {
        let attached = try reattachSession()
        XCTAssertEqual(attached.session.shellPid, Fixture.childPid)
        XCTAssertTrue(attached.session.isHostBacked)
        XCTAssertTrue(attached.session.isRunning)
        XCTAssertEqual(attached.recorder.startCount, 1)
    }

    // MARK: - The replay

    /// A cut replay is history and is not answered; the live output behind it is.
    ///
    /// P1's rule at the seam a reattach actually crosses, counted the only way it can be: by what
    /// left towards the child. A stale `DA` reply reaching a program that already had one is
    /// worse than silence, and swallowing a live query for one main-queue turn is the safe
    /// direction to err in.
    func testACutReplayAnswersNothingAndTheLiveOutputBehindItIsAnswered() throws {
        let attached = try reattachSession(replay: .cut)
        attached.transport.send(output: Self.deviceAttributesQuery)
        settle()

        XCTAssertTrue(
            attached.transport.inputs.isEmpty,
            "a replayed DA2 is history, and answering it sends a stale reply to a live program"
        )

        attached.transport.send(output: Self.deviceAttributesQuery)
        settle()
        XCTAssertEqual(
            attached.transport.inputs.count,
            1,
            "suppression must not outlive the replay it was for"
        )
    }

    /// An exact replay carries bytes no emulator has ever seen, so it **must** be answered.
    func testAnExactReplayIsAnsweredOnce() throws {
        let attached = try reattachSession(replay: .exact(fromOffset: 0))
        attached.transport.send(output: Self.deviceAttributesQuery)
        settle()

        XCTAssertEqual(
            attached.transport.inputs.count,
            1,
            "a query nobody has answered yet is answered exactly once, late"
        )
    }

    /// A watcher that rejoined counts from where the daemon said it was.
    func testAnAttachedWatcherCountsFromTheHostsOwnByteCount() throws {
        let attached = try reattachSession(replay: .none, totalBytesWritten: 900)
        attached.transport.send(output: Array("abc".utf8))
        settle()

        XCTAssertTrue(attached.session.detachFromHost(by: Date().addingTimeInterval(1)))
        let detach = try XCTUnwrap(attached.transport.detaches.first)
        XCTAssertEqual(
            detach.ringOffset,
            903,
            "an empty replay means every byte since is a ring byte, so the count stays exact"
        )
    }

    // MARK: - Helpers

    private static let deviceAttributesQuery: [UInt8] = Array("\u{1b}[>c".utf8)

    private static let plan = AgentLaunchPlan(
        executable: "/bin/sh",
        arguments: ["-l", "-c", "exit 0"],
        resumeState: .unavailable
    )

    private struct HostedSession {
        let session: TerminalSession
        let transport: FakeDetachTransport
        let recorder: DetachRecorder
        let identity: PTYHostSessionIdentity
    }

    private func makeSession() -> TerminalSession {
        let session = TerminalSession(
            frame: Fixture.frame,
            identity: .agentSession(SessionID())
        )
        // Unshown and borderless: the grid has to be a real one, and a detached view constrains
        // nothing. Nothing is ordered on screen.
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

    /// A session whose child the daemon spawned for it a moment ago.
    private func startHostBackedSession() throws -> HostedSession {
        let prepared = prepareSession()
        prepared.session.start(plan: Self.plan)

        let transport = try XCTUnwrap(prepared.box.transport, "the launch never reached the host")
        _ = try XCTUnwrap(transport.spawnRequest)
        let identity = PTYHostSessionIdentity(prepared.session.identity)
        transport.send(.spawned(PTYHostSpawned(
            id: identity,
            pid: Fixture.childPid,
            startTime: PTYHostProcessStartTime(seconds: 1, microseconds: 2)
        )))
        settle()
        return HostedSession(
            session: prepared.session,
            transport: transport,
            recorder: prepared.recorder,
            identity: identity
        )
    }

    /// A session taken back from a daemon that has been holding it.
    private func reattachSession(
        replay: PTYHostReplay = .none,
        totalBytesWritten: UInt64 = 0
    ) throws -> HostedSession {
        let prepared = prepareSession()
        XCTAssertTrue(prepared.session.attachToHost(grid: Fixture.hostGrid))

        let transport = try XCTUnwrap(prepared.box.transport, "the attach never reached the host")
        let identity = PTYHostSessionIdentity(prepared.session.identity)
        transport.send(.attached(PTYHostAttached(
            id: identity,
            pid: Fixture.childPid,
            grid: Fixture.hostGrid,
            replay: replay,
            totalBytesWritten: totalBytesWritten
        )))
        settle()
        return HostedSession(
            session: prepared.session,
            transport: transport,
            recorder: prepared.recorder,
            identity: identity
        )
    }

    private func prepareSession() -> (
        session: TerminalSession,
        box: FakeDetachTransportBox,
        recorder: DetachRecorder
    ) {
        let session = makeSession()
        let recorder = DetachRecorder()
        recorders.append(recorder)
        session.delegate = recorder

        let box = FakeDetachTransportBox()
        session.hostTransportFactory = { events in
            let transport = FakeDetachTransport(events: events)
            box.adopt(transport)
            return transport
        }
        return (session, box, recorder)
    }

    private func settle(_ seconds: TimeInterval = Fixture.settle) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }
}

// MARK: - The fake link

/// What the session sent, and what the daemon would have said back.
///
/// A second fake beside `PTYHostSessionTests`' rather than a shared one: that suite is about a
/// spawn and this one is about a hand-over, and the frames each needs to record differ. Both drive
/// the four event closures from the transport's own queue — the queue a real client delivers on —
/// so the main-queue hop under test is the production one.
private final class FakeDetachTransport: PTYHostSessionTransport, @unchecked Sendable {

    let queue = DispatchQueue(label: "codes.threading.tests.ptyhost.detach")

    private let events: PTYHostClient.Events
    private let lock = NSLock()
    private var frames: [PTYHostFrame] = []
    private var inputStorage: [Data] = []
    private var closedStorage = false

    init(events: PTYHostClient.Events) {
        self.events = events
    }

    // MARK: - PTYHostSessionTransport

    func spawn(_ request: PTYHostSpawnRequest) throws { record(.spawn(request)) }
    func attach(_ request: PTYHostAttach) throws { record(.attach(request)) }
    func resize(_ request: PTYHostResize) throws { record(.resize(request)) }
    func detach(_ request: PTYHostDetach) throws { record(.detach(request)) }

    /// Meaningless on a terminal, and never sent by one — recorded so the test can say so.
    func closeInput(_ request: PTYHostCloseInput) throws { record(.closeInput(request)) }

    func kill(_ request: PTYHostKill) throws { record(.kill(request)) }

    func sendInput(_ bytes: Data) throws {
        lock.lock()
        inputStorage.append(bytes)
        lock.unlock()
    }

    /// Nothing is queued, so everything is always written.
    func drainWrites(until deadline: Date) -> Bool { true }

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

    var spawnRequest: PTYHostSpawnRequest? {
        sent.compactMap { frame -> PTYHostSpawnRequest? in
            guard case .spawn(let request) = frame else { return nil }
            return request
        }.first
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

    // MARK: - What the daemon would say

    func send(_ frame: PTYHostFrame) {
        queue.sync { events.frame(frame) }
    }

    func send(output bytes: [UInt8]) {
        queue.sync { events.output(Data(bytes)) }
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
private final class FakeDetachTransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: FakeDetachTransport?

    var transport: FakeDetachTransport? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func adopt(_ transport: FakeDetachTransport) {
        lock.lock()
        storage = transport
        lock.unlock()
    }
}

/// The session's delegate, recording exactly the edges a hand-over is about.
@MainActor
private final class DetachRecorder: NSObject, TerminalSessionDelegate {
    private(set) var exitCodes: [Int32?] = []
    private(set) var startCount = 0

    func terminalSessionDidStart(_ session: TerminalSession) {
        startCount += 1
    }

    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {
        exitCodes.append(exitCode)
    }
}
