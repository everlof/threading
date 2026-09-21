#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest
#if !SWIFT_PACKAGE
@testable import Threading
#endif

/// `threading-ptyd`, exercised as the process it ships as.
///
/// Every test here runs the real daemon out of `Contents/Helpers` against a scratch socket and a
/// scratch state directory, and speaks the real codec to it over a real unix socket.
///
/// **The same file is the Linux daemon's test suite.** `Targets/PTYHost/Package.swift` compiles
/// it through a symlink, where `SWIFT_PACKAGE` is defined: the daemon is the SwiftPM-built binary
/// beside the test bundle, the one test that needs the app's restart path is left out, and the
/// cleanup below speaks the protocol itself because there is no app client to borrow.
/// `scripts/test-ptyd-linux.sh` runs it in a Linux container. Nothing is
/// stubbed on either side, because the two things worth getting wrong are both mechanism: what a
/// `forkpty` child actually observes, and what a byte stream actually does across a detach.
///
/// **The assertions are about what the child observed**, not about how many frames went past. A
/// resize is asserted by asking the child for `stty size`; a survival is asserted by the child's
/// pid being the same one; an exit is asserted by the status the shell was told to produce. A
/// frame count would pass just as happily against a daemon that sent the right frames and did
/// nothing to the terminal.
///
/// Nothing here needs a window, and every wait is bounded.
final class PTYHostDaemonTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        /// Generous: each bounds a process launch plus a socket round trip, and the point of
        /// every assertion is *that it happens at all*, never how quickly.
        static let replyTimeout: TimeInterval = 10
        /// A child that has to be scheduled, run a program and write to a terminal.
        static let childTimeout: TimeInterval = 15
        static let exitTimeout: TimeInterval = 15
        /// The daemon's own foreground poll is 1 Hz, so a change has to survive at least one.
        static let foregroundTimeout: TimeInterval = 8
        /// A child that ignores TERM still expires if an assertion prevents the kill request.
        static let stubbornChildIterations = 600

        static let helperName = "threading-ptyd"
        /// The package build's way to name the daemon under test. Unused by the hosted target.
        static let helperOverrideKey = "THREADING_PTYD_EXECUTABLE"
        /// The package build's statement of the three generation values the binary under test was
        /// built with — the same names as the Xcode build settings. An absent one was not given.
        /// Unused by the hosted target.
        static let expectedShortVersionKey = "MARKETING_VERSION"
        static let expectedBundleVersionKey = "CURRENT_PROJECT_VERSION"
        static let expectedSourceRevisionKey = "THREADING_SOURCE_REVISION"
        /// The daemon's `EX_TEMPFAIL`: another daemon owns the state directory.
        static let stateDirectoryHeldExitCode: Int32 = 75
        static let shell = "/bin/sh"

        /// Larger than the daemon's 512 KiB ring, so the replay has to be a cut.
        static let overflowBytes = 700_000
    }

    // MARK: - Fixture state

    private var directory: URL!
    private var daemons: [DaemonProcess] = []
    private var clients: [PTYHostTestClient] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `sockaddr_un.sun_path` holds 104 bytes (108 on Linux) and the system temporary directory
        // is already about half of that, so the fixture's own names stay to a handful of
        // characters.
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ptyd-\(UInt32.random(in: 0..<0xFFFF_FFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for client in clients { client.hangUp() }
        clients.removeAll()
        // Restart tests keep both `Process` wrappers for one rendezvous. Only the newest one owns
        // the live endpoint; shutting both down would start a needless recovery daemon after the
        // first shutdown had already drained it.
        var endpoints: [String: DaemonProcess] = [:]
        for daemon in daemons { endpoints[daemon.socketPath] = daemon }
        for daemon in endpoints.values {
            XCTAssertTrue(
                daemon.shutdown(),
                "scratch PTY daemon did not drain: \(daemon.diagnosticText)"
            )
        }
        for daemon in daemons { daemon.finishDiagnostics() }
        daemons.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - Spawning, output and input

    func testSpawnsAChildAndStreamsWhatItPrinted() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        let spawned = try spawn(on: client, id: id, script: "printf hi")
        XCTAssertGreaterThan(spawned.pid, 0, "a spawned child has a pid")
        XCTAssertGreaterThan(
            spawned.startTime.seconds,
            0,
            "the kernel start time is the other half of the pid's identity"
        )

        try client.waitForOutput(containing: "hi", timeout: Fixture.childTimeout)
    }

    func testTakesInputAndTheChildActsOnIt() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        _ = try spawn(on: client, id: id, script: "while read -r line; do printf \"[$line]\"; done")
        client.sendInput("ping\n")
        try client.waitForOutput(containing: "[ping]", timeout: Fixture.childTimeout)
    }

    // MARK: - The pipe channel

    /// A conversation's CLI, on three pipes, with the two output streams kept apart.
    ///
    /// The separation is the assertion and not a detail: the transports parse standard output a
    /// line of JSON at a time, and a diagnostic line merged into it is a malformed record rather
    /// than a message. The wire keeps them apart with a flag, so a build that does not know the
    /// flag reads diagnostics as output instead of dropping the connection.
    func testAPipesChildKeepsItsTwoOutputStreamsApart() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        let spawned = try spawnPipes(
            on: client,
            id: id,
            script: "printf 'to-stdout'; printf 'to-stderr' >&2"
        )
        XCTAssertGreaterThan(spawned.pid, 0, "a spawned child has a pid")

        try client.waitForOutput(containing: "to-stdout", timeout: Fixture.childTimeout)
        try client.waitForErrorOutput(containing: "to-stderr", timeout: Fixture.childTimeout)
        XCTAssertFalse(
            client.text.contains("to-stderr"),
            "a diagnostic merged into the parsed stream is a malformed record"
        )
    }

    /// Standard input reaches the child, and **closing** it is what ends the conversation.
    ///
    /// The graceful shutdown every native transport performs is `close(stdin)`, which is a
    /// descriptor event with no byte to carry it — which is the whole reason `closeInput` is a
    /// frame of its own rather than something a byte stream could express.
    func testAPipesChildReadsItsInputAndEndsWhenTheInputIsClosed() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        _ = try spawnPipes(
            on: client,
            id: id,
            script: "while read -r line; do printf \"[$line]\"; done; printf done"
        )
        client.sendInput("ping\n")
        try client.waitForOutput(containing: "[ping]", timeout: Fixture.childTimeout)

        client.send(.closeInput(PTYHostCloseInput(id: id)))
        try client.waitForOutput(containing: "done", timeout: Fixture.childTimeout)
        let exited = try nextExit(on: client)
        XCTAssertEqual(exited.status, 0, "end of input is an ordinary ending, not a failure")
    }

    /// A pipes session has no terminal, so a `resize` is an error the connection survives.
    ///
    /// A close would be the wrong answer twice over: the frame is well formed and the stream is
    /// still readable, and closing here would end somebody's conversation over a caller's slip.
    func testAPipesSessionRefusesAResizeAndKeepsWorking() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        _ = try spawnPipes(
            on: client,
            id: id,
            script: "while read -r line; do printf \"[$line]\"; done"
        )
        client.send(.resize(PTYHostResize(id: id, grid: PTYHostGrid(cols: 100, rows: 40))))

        let refusal = try client.nextControl(timeout: Fixture.replyTimeout) {
            if case .error = $0 { return true }
            return false
        }
        guard case .error(let failure) = refusal else {
            throw PTYHostTestFailure("expected an error frame, got \(refusal)")
        }
        XCTAssertEqual(failure.code, .unsupportedChannel)

        client.sendInput("still-here\n")
        try client.waitForOutput(containing: "[still-here]", timeout: Fixture.childTimeout)
        XCTAssertFalse(client.isClosed, "a wrong-channel frame is not a poisoned one")
    }

    /// What a rejoining watcher is owed: `CAN`, alone on its line, then whole lines.
    ///
    /// A pipes session is **always** a cut — there is no emulator anywhere to seed an exact
    /// replay from — and a tail beginning mid-line would hand a fresh parser one guaranteed
    /// malformed line, which reads as a provider protocol error rather than as a cut.
    func testAPipesRejoinIsACutThatBeginsAtALineBoundary() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        // Comfortably past the ring, so the tail is certainly cut mid-line before trimming.
        // `awk` rather than a shell loop: sixty thousand `printf` processes is a minute of
        // scheduling, and what this test is about is the byte the daemon trims to.
        _ = try spawnPipes(
            on: client,
            id: id,
            script: "awk 'BEGIN { for (i = 0; i < 60000; i++) printf \"{\\\"line\\\":%d}\\n\", i }'"
                + "; sleep 30"
        )
        try client.waitForBytes(atLeast: Fixture.overflowBytes, timeout: Fixture.childTimeout)
        client.hangUp()

        let rejoined = try connect(to: daemon)
        let attached = try attach(on: rejoined, id: id)
        XCTAssertEqual(attached.replay, .cut, "a pipes session has no screen to seed from")

        // Enough of the replay to hold a whole line after the marker; the tail itself is the
        // ring's, and the assertion below is about where it starts rather than how long it is.
        try rejoined.waitForBytes(atLeast: 4096, timeout: Fixture.childTimeout)
        let replay = rejoined.bytes
        XCTAssertEqual(replay.first, 0x18, "the cut marker leads")
        XCTAssertEqual(
            replay.dropFirst().first,
            UInt8(ascii: "\n"),
            "the marker keeps a line of its own, so the first byte after it starts a line"
        )
        let lines = String(decoding: replay.dropFirst(2), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(
            lines.first?.hasPrefix("{\"line\":") ?? false,
            "the first replayed line is whole: \(lines.first ?? "")"
        )
    }

    /// The summary says which transport a child is speaking, because the app cannot infer it —
    /// and a pipes session reports no window size rather than a plausible one it does not have.
    func testASummarySaysWhichChannelItsSessionIsOn() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let terminal = Self.newIdentity()
        let conversation = Self.newIdentity()

        _ = try spawn(on: client, id: terminal, script: "sleep 30")
        let second = try connect(to: daemon)
        _ = try spawnPipes(on: second, id: conversation, script: "sleep 30")

        client.send(.list)
        let summaries = try nextSessions(on: client)
        let byIdentity = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })

        XCTAssertEqual(byIdentity[terminal]?.resolvedChannel, .pty)
        XCTAssertEqual(byIdentity[terminal]?.grid.cols, 80)
        XCTAssertEqual(byIdentity[conversation]?.resolvedChannel, .pipes)
        XCTAssertEqual(
            byIdentity[conversation]?.grid,
            PTYHostGrid(cols: 0, rows: 0),
            "a window size it does not have is a fact somebody would act on"
        )
    }

    // MARK: - The window size

    /// A `resize` reaches the child; an `attach` deliberately does not.
    ///
    /// Both halves are asserted the same way — by asking the child what its terminal says it is —
    /// because the second one is the whole point of the durable grid: reattaching a Threading
    /// that has just restarted must not reflow an agent that kept working the whole time.
    func testResizeReachesTheChildAndAnAttachDoesNot() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        // Each probe is answered with its own marker, so a replayed answer to an earlier probe
        // can never be mistaken for the answer to this one.
        _ = try spawn(
            on: client,
            id: id,
            script: "while read -r line; do printf \"%s \" \"$line\"; stty size; done",
            grid: PTYHostGrid(cols: 80, rows: 24)
        )

        client.sendInput("first\n")
        try client.waitForOutput(containing: "first 24 80", timeout: Fixture.childTimeout)

        client.send(.resize(PTYHostResize(
            id: id,
            grid: PTYHostGrid(cols: 100, rows: 40, xpixel: 800, ypixel: 640)
        )))
        client.sendInput("second\n")
        try client.waitForOutput(containing: "second 40 100", timeout: Fixture.childTimeout)

        // A new watcher arrives. It is told the grid; it does not impose one.
        client.hangUp()
        let rejoined = try connect(to: daemon)
        let attached = try attach(on: rejoined, id: id)
        XCTAssertEqual(attached.grid.cols, 100)
        XCTAssertEqual(attached.grid.rows, 40)
        XCTAssertEqual(attached.grid.xpixel, 800, "the pixel pair travels with the cell pair")

        rejoined.sendInput("third\n")
        try rejoined.waitForOutput(containing: "third 40 100", timeout: Fixture.childTimeout)
    }

    /// A `resize` is answered with the grid the terminal actually took, on the connection that
    /// asked for it.
    ///
    /// The frame `resize` did without in version 1, and the one thing the app cannot work out for
    /// itself: a write across a socket may be refused, so "the child is on this grid" has to be
    /// something the daemon says rather than something the app assumes. The acknowledgement is
    /// asserted beside the child's own `stty size`, because a daemon that answered the frame and
    /// did nothing to the terminal would pass either assertion alone.
    func testAResizeIsAnsweredWithTheGridTheTerminalTook() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        _ = try spawn(
            on: client,
            id: id,
            script: "while read -r line; do printf \"%s \" \"$line\"; stty size; done",
            grid: PTYHostGrid(cols: 80, rows: 24)
        )

        let wanted = PTYHostGrid(cols: 100, rows: 40, xpixel: 800, ypixel: 640)
        client.send(.resize(PTYHostResize(id: id, grid: wanted)))

        let resized = try nextResized(on: client)
        XCTAssertEqual(resized.id, id, "an acknowledgement names the session it is about")
        XCTAssertEqual(
            resized.grid,
            wanted,
            "the answer is the grid that reached TIOCSWINSZ, pixels included"
        )

        client.sendInput("after\n")
        try client.waitForOutput(containing: "after 40 100", timeout: Fixture.childTimeout)

        // And what was acknowledged is what a later watcher inherits: the acknowledgement and the
        // durable grid are the same fact, not two that could drift.
        client.send(.list)
        let sessions = try nextSessions(on: client)
        XCTAssertEqual(sessions.first?.grid, wanted)
    }

    // MARK: - Endings

    func testReportsAnOrdinaryExitStatus() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        _ = try spawn(on: client, id: id, script: "printf bye; exit 7")
        try client.waitForOutput(containing: "bye", timeout: Fixture.childTimeout)

        let exited = try nextExit(on: client)
        XCTAssertEqual(exited.status, 7)
        XCTAssertFalse(exited.signalled)
    }

    func testReportsASignalledChildAsSignalled() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        _ = try spawn(
            on: client,
            id: id,
            script: "trap '' TERM; printf READY; i=0; while [ \"$i\" -lt \(Fixture.stubbornChildIterations) ]; "
                + "do i=$((i + 1)); sleep 0.2; done"
        )
        try client.waitForOutput(containing: "READY", timeout: Fixture.childTimeout)
        client.send(.kill(PTYHostKill(id: id, escalate: true)))

        let exited = try nextExit(on: client)
        XCTAssertTrue(exited.signalled, "a child that ignored SIGTERM is escalated to SIGKILL")
        XCTAssertEqual(exited.status, SIGKILL)
    }

    /// The exit is reported after the output that preceded it, not instead of it.
    func testTheLastOutputArrivesBeforeTheExit() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        _ = try spawn(on: client, id: id, script: "printf FAREWELL; exit 0")
        _ = try nextExit(on: client)
        XCTAssertTrue(
            client.text.contains("FAREWELL"),
            "the child's last write must have been delivered by the time its ending was"
        )
    }

    /// A checkout move stops one incarnation and immediately starts the next with the same
    /// logical identity. The daemon serializes that handoff: no refusal can push the replacement
    /// back into Threading's process, and the two children never overlap.
    #if !SWIFT_PACKAGE
    func testRestartStopReachesAHostedChildWithoutAnAppRuntime() throws {
        let daemon = try startDaemon()
        let originalClient = try connect(to: daemon)
        let sessionID = SessionID()
        let id = PTYHostSessionIdentity.agentSession(sessionID)
        let original = try spawn(on: originalClient, id: id, script: "printf READY; sleep 60")
        try originalClient.waitForOutput(containing: "READY", timeout: Fixture.childTimeout)
        let decision = PTYHostDecision(
            isEnabled: true, helperURL: URL(fileURLWithPath: Fixture.shell),
            socketPath: daemon.socketPath, socketPathBytes: daemon.socketPath.utf8.count,
            build: "restart-test"
        )
        XCTAssertTrue(SessionTerminalRestart.stopHosted(
            sessionID: sessionID, decision: decision, survey: .connecting(),
            stopper: { identity, socket, build in
                PTYHostSessionStop.run(identity, socketPath: socket, build: build)
            }
        ))
        let replacement = try connect(to: daemon)
        let spawned = try spawn(on: replacement, id: id, script: "printf RESUMED; sleep 60", replaceExisting: true)
        XCTAssertNotEqual(spawned.pid, original.pid)
        try replacement.waitForOutput(containing: "RESUMED", timeout: Fixture.childTimeout)
    }
    #endif

    func testAKilledSessionIsAtomicallyReplacedUnderTheSameIdentity() throws {
        let daemon = try startDaemon()
        let first = try connect(to: daemon)
        let id = Self.newIdentity()
        let original = try spawn(on: first, id: id, script: "printf FIRST; sleep 60")
        try first.waitForOutput(containing: "FIRST", timeout: Fixture.childTimeout)

        let replacement = try connect(to: daemon)
        // The replacement deliberately arrives before any kill frame from the old connection.
        // Its own intent must make the daemon order the stop and spawn atomically.
        let spawned = try spawn(
            on: replacement,
            id: id,
            script: "printf SECOND; sleep 60",
            replaceExisting: true
        )
        XCTAssertNotEqual(spawned.pid, original.pid)
        try replacement.waitForOutput(containing: "SECOND", timeout: Fixture.childTimeout)
        XCTAssertEqual(try nextExit(on: first).id, id)
    }

    func testAHealthySessionStillRefusesASecondSpawnWithTheSameIdentity() throws {
        let daemon = try startDaemon()
        let first = try connect(to: daemon)
        let id = Self.newIdentity()
        _ = try spawn(on: first, id: id, script: "sleep 60")

        let second = try connect(to: daemon)
        second.send(.spawn(PTYHostSpawnRequest(
            id: id,
            channel: .pty(grid: PTYHostGrid(cols: 80, rows: 24, xpixel: 0, ypixel: 0)),
            executable: Fixture.shell,
            arguments: ["-c", "sleep 60"],
            environment: Self.childEnvironment,
            cwd: NSTemporaryDirectory()
        )))
        let frame = try second.nextControl(timeout: Fixture.replyTimeout) {
            if case .spawnRefused = $0 { return true }
            return false
        }
        guard case .spawnRefused(let refusal) = frame else {
            return XCTFail("expected a spawn refusal, got \(frame)")
        }
        XCTAssertEqual(refusal.reason, .alreadyExists)
    }

    // MARK: - Surviving the client

    /// The whole feature, in one test: the client goes away mid-stream and the child does not.
    func testTheChildSurvivesItsClientAndTheRingHoldsWhatWasMissed() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        let spawned = try spawn(
            on: client,
            id: id,
            script: "printf BEFORE; sleep 1; printf AFTER; sleep 30"
        )
        try client.waitForOutput(containing: "BEFORE", timeout: Fixture.childTimeout)

        // Not a detach: the socket simply dies, which is what a crashed or killed app looks like.
        client.hangUp()

        let rejoined = try connect(to: daemon)
        let attached = try attach(on: rejoined, id: id)
        XCTAssertEqual(attached.pid, spawned.pid, "the same child, not a new one")
        XCTAssertEqual(attached.replay, .cut, "a close without seeds is answered with a cut")

        // The bytes written while nobody was attached are in the ring, so the rejoining watcher
        // still sees them.
        try rejoined.waitForOutput(containing: "AFTER", timeout: Fixture.childTimeout)
        XCTAssertTrue(rejoined.text.contains("BEFORE"), "and everything before them")
    }

    /// A write larger than the ring cannot be replayed exactly, and says so.
    func testAWriteLargerThanTheRingReplaysACutWithALeadingCancel() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        _ = try spawn(
            on: client,
            id: id,
            script: "head -c \(Fixture.overflowBytes) /dev/zero | tr '\\0' x; printf TAILMARK; sleep 30"
        )
        try client.waitForOutput(containing: "TAILMARK", timeout: Fixture.childTimeout)
        client.hangUp()

        let rejoined = try connect(to: daemon)
        let budget = 32 * 1024
        let attached = try attach(on: rejoined, id: id, budget: budget)
        XCTAssertEqual(attached.replay, .cut)
        XCTAssertEqual(attached.replayByteCount, budget + 1)
        XCTAssertGreaterThan(
            attached.totalBytesWritten,
            UInt64(Fixture.overflowBytes),
            "the ring counts bytes it no longer holds"
        )

        try rejoined.waitForBytes(atLeast: budget + 1, timeout: Fixture.childTimeout)
        XCTAssertEqual(
            rejoined.bytes.first,
            0x18,
            "CAN first: cutting the head off the ring means the replay can begin inside an "
                + "escape sequence too"
        )
        XCTAssertEqual(
            rejoined.bytes.count,
            budget + 1,
            "the stated budget bounds the tail, and the cut marker is the one byte on top of it"
        )
    }

    /// A detach hands over what only the app can compute, and the next attach is exact.
    func testDetachSeedsMakeTheNextAttachExactAndReplayNothingTwice() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        _ = try spawn(on: client, id: id, script: "printf ALPHA; sleep 1; printf BETA; sleep 30")
        try client.waitForOutput(containing: "ALPHA", timeout: Fixture.childTimeout)

        let applied = UInt64(client.bytes.count)
        client.send(.detach(PTYHostDetach(
            id: id,
            screenSeed: Data("<SEED>".utf8),
            modeSeed: Data("<MODES>".utf8),
            ringOffset: applied
        )))

        // BETA is written a second later, while nobody is attached, so it is exactly what the
        // rejoin owes. The wait is a plain sleep because there is nothing to ask: probing with
        // an attach would itself be a watcher arriving and leaving, and a connection that closes
        // without a detach clears the seed this test is about.
        Thread.sleep(forTimeInterval: 2.5)

        let rejoined = try connect(to: daemon)
        let attached = try attach(on: rejoined, id: id)
        XCTAssertEqual(attached.replay, .exact(fromOffset: applied))
        XCTAssertEqual(attached.replayByteCount, Data("<SEED>BETA<MODES>".utf8).count)

        try rejoined.waitForOutput(containing: "<MODES>", timeout: Fixture.childTimeout)
        let replay = rejoined.text
        XCTAssertEqual(
            replay,
            "<SEED>BETA<MODES>",
            "the screen seed, then exactly the bytes missed, then the modes last"
        )
        XCTAssertFalse(replay.contains("ALPHA"), "nothing the watcher had already applied")
    }

    // MARK: - The foreground process group

    /// The one question the app can no longer answer for itself about a hosted session.
    ///
    /// `set -m` turns job control on in a non-interactive shell, so the foreground command runs
    /// in a process group of its own and takes the terminal — which is exactly the change a title
    /// or a bell needs to attribute, and exactly what `tcgetpgrp` reports.
    func testTheForegroundGroupChangesWhenTheChildRunsAnotherProgram() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()

        let spawned = try spawn(on: client, id: id, script: "set -m; sleep 3; exec cat")

        // Two distinct groups is the whole claim: the shell itself, and the job it gave the
        // terminal to. Which arrives first is a matter of when the child got as far as taking
        // its controlling terminal, so the assertion is about the set rather than the order.
        var groups: Set<pid_t> = []
        while groups.count < 2 {
            groups.insert(try nextForeground(
                on: client,
                timeout: Fixture.foregroundTimeout
            ).processGroup)
        }
        XCTAssertTrue(
            groups.contains(spawned.pid),
            "forkpty makes the child a session leader, so one of them is the child itself"
        )
        XCTAssertEqual(groups.count, 2, "and the other is the job that took the terminal")
    }

    // MARK: - Robustness

    /// A poisoned frame closes one connection. It never exits the daemon, and it never touches
    /// another client — a restart storm from a malformed frame is the failure this avoids.
    func testAnOversizeFrameClosesOnlyThePoisonedConnection() throws {
        let daemon = try startDaemon()
        let healthy = try connect(to: daemon)
        let id = Self.newIdentity()
        _ = try spawn(on: healthy, id: id, script: "while read -r line; do printf \"[$line]\"; done")

        let poisoned = try connect(to: daemon)
        poisoned.sendOversizeHeader(declaring: 2 * 1024 * 1024)
        try waitUntil(timeout: Fixture.replyTimeout, "the poisoned connection is closed") {
            poisoned.isClosed
        }

        // The other one is still streaming, and the daemon is still there to answer.
        healthy.sendInput("still here\n")
        try healthy.waitForOutput(containing: "[still here]", timeout: Fixture.childTimeout)
        healthy.send(.list)
        _ = try nextSessions(on: healthy)
        XCTAssertTrue(daemon.isRunning, "a bad frame never exits the daemon")
    }

    /// A frame naming a session this connection is not bound to is a disagreement about what it
    /// is attached to, so it is refused and the connection ends.
    func testAResizeNamingAnotherSessionIsRefusedAndClosesTheConnection() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()
        _ = try spawn(on: client, id: id, script: "sleep 30")

        client.send(.resize(PTYHostResize(
            id: Self.newIdentity(),
            grid: PTYHostGrid(cols: 10, rows: 10)
        )))
        let error = try nextError(on: client)
        XCTAssertEqual(error.code, .notAttached)
        XCTAssertEqual(error.detail, "sessionMismatch")
        try waitUntil(timeout: Fixture.replyTimeout, "the mismatched connection is closed") {
            client.isClosed
        }
        XCTAssertTrue(daemon.isRunning)
    }

    // MARK: - One daemon per state directory

    /// A daemon refuses a state directory another daemon owns, and touches nothing of the owner's.
    ///
    /// Without the lock the second daemon's startup recovery read the owner's live
    /// `sessions.jsonl`, took its running agent for a crashed predecessor's orphan and killed the
    /// agent's group. The intruder is given a socket of its own on purpose: the refusal is about
    /// the state, not the rendezvous. The owner is then killed the way a crash kills it, because
    /// the lock is only right if the kernel gives it back however the owner ends.
    ///
    /// The agent is left **detached** while the intruder starts, which is also the case that
    /// matters — a daemon holding agents nobody is watching. It is detached for a second reason:
    /// under Docker Desktop's x86_64 emulation, launching a process from the test closed the test's
    /// own open socket (measured, and not on arm64 or macOS), so no watcher is open across that
    /// launch.
    func testASecondDaemonRefusesAStateDirectoryAnotherDaemonOwns() throws {
        let owner = try startDaemon()
        let spawner = try connect(to: owner)
        let id = Self.newIdentity()
        let spawned = try spawn(on: spawner, id: id, script: "printf READY; sleep 60")
        try spawner.waitForOutput(containing: "READY", timeout: Fixture.childTimeout)
        spawner.hangUp()

        let intruder = try DaemonProcess(
            helper: try helperURL(),
            socketPath: directory.appendingPathComponent("x.sock").path,
            stateDirectory: owner.stateDirectory,
            ringBudget: nil
        )
        // Not in `daemons`: it owns no endpoint the teardown should drain. If the lock ever
        // regresses it is a live daemon, and it must not outlive the test.
        defer {
            intruder.terminateIfRunning()
            intruder.finishDiagnostics()
        }
        XCTAssertTrue(
            intruder.waitUntilExited(timeout: Fixture.replyTimeout),
            "a daemon on an owned state directory exits instead of serving: \(intruder.diagnosticText)"
        )
        XCTAssertEqual(intruder.terminationStatus, Fixture.stateDirectoryHeldExitCode)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: intruder.socketPath),
            "the refused daemon bound nothing"
        )
        XCTAssertEqual(DaemonTestPOSIX.kill(spawned.pid, 0), 0, "the owner's agent is still running")
        let client = try connect(to: owner)
        client.send(.list)
        let held = try nextSessions(on: client)
        XCTAssertEqual(held.map(\.id), [id])
        XCTAssertNil(held.first?.exit)

        owner.crash()
        client.hangUp()
        try waitUntil(timeout: Fixture.exitTimeout, "the owner is gone") { !owner.isRunning }
        let successor = try startDaemon(reusing: owner)
        let observer = try connect(to: successor, greeting: false)
        observer.send(.hello(PTYHostHello(build: "test", pid: getpid())))
        _ = try nextHello(on: observer)
        XCTAssertEqual(try nextLost(on: observer).ids, [id], "a crashed owner's lock is released")
    }

    #if SWIFT_PACKAGE
    /// A Linux binary has no `Info.plist`, so its generation is whatever its build defined — and
    /// `? (?)` when the build defined nothing, never a guess that could match an app's.
    ///
    /// Hosted runs do not need this: `PTYHostDaemonIntegrationTests` pins the embedded plist's
    /// generation to the app's.
    func testHelloCarriesTheGenerationTheBuildWasGiven() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon, greeting: false)
        client.send(.hello(PTYHostHello(build: "test", pid: getpid())))
        let environment = ProcessInfo.processInfo.environment
        let expected = PTYHostGeneration.string(
            shortVersion: environment[Fixture.expectedShortVersionKey],
            bundleVersion: environment[Fixture.expectedBundleVersionKey],
            sourceRevision: environment[Fixture.expectedSourceRevisionKey]
        )
        XCTAssertEqual(try nextHello(on: client).build, expected)
    }
    #endif

    /// The version pair is the gate, and it is the first thing that happens on a connection.
    func testAnIncompatibleHelloIsRefusedAndAFrameBeforeHelloIsNotAnswered() throws {
        let daemon = try startDaemon()

        let future = try connect(to: daemon, greeting: false)
        future.send(.hello(PTYHostHello(
            protocolVersion: 99,
            minimumSupported: 99,
            build: "future",
            pid: getpid()
        )))
        let refusal = try nextHelloRefusal(on: future)
        XCTAssertEqual(refusal.compatibility, .selfTooOld)
        XCTAssertEqual(refusal.update, .daemon, "the daemon is the one that has to be replaced")

        let impatient = try connect(to: daemon, greeting: false)
        impatient.send(.list)
        let error = try nextError(on: impatient)
        XCTAssertEqual(error.detail, "beforeHello")
        try waitUntil(timeout: Fixture.replyTimeout, "the ungreeted connection is closed") {
            impatient.isClosed
        }
    }

    // MARK: - Retirement

    /// `retire` unlinks the socket **now**, so a replacement binary can bind it, and the daemon
    /// finishes what it is holding before exiting.
    func testRetireUnlinksTheSocketAtOnceAndExitsAfterTheLastChild() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()
        _ = try spawn(on: client, id: id, script: "sleep 1")

        client.send(.retire)
        try waitUntil(timeout: Fixture.replyTimeout, "the socket is unlinked") {
            !FileManager.default.fileExists(atPath: daemon.socketPath)
        }
        XCTAssertTrue(daemon.isRunning, "retiring is not exiting: it is still serving its child")

        let exited = try nextExit(on: client)
        XCTAssertEqual(exited.status, 0)
        XCTAssertTrue(
            daemon.waitUntilExited(timeout: Fixture.exitTimeout),
            "a retired daemon exits when its last session ends"
        )
    }

    // MARK: - What a restart could not account for

    /// The honest half of the failure model.
    ///
    /// The daemon is killed the way a crash kills it, and the next one reads its ledger, probes
    /// each pid **with** its kernel start time, and says what it cannot account for. The survivor
    /// is ended here as well, because a child of a dead daemon has no master anybody holds: there
    /// is nothing to attach to it, and the app's orphan sweep skips host-held children by design,
    /// so this is the only place that can end it.
    func testARestartSaysWhatItLostAndReclaimsAChildThatOutlivedItsHost() throws {
        let daemon = try startDaemon()
        let client = try connect(to: daemon)
        let id = Self.newIdentity()
        let spawned = try spawn(on: client, id: id, script: "sleep 60")

        daemon.crash()
        client.hangUp()
        try waitUntil(timeout: Fixture.exitTimeout, "the first daemon is gone") {
            !daemon.isRunning
        }

        let restarted = try startDaemon(reusing: daemon)
        let rejoined = try connect(to: restarted, greeting: false)
        rejoined.send(.hello(PTYHostHello(build: "test", pid: getpid())))
        _ = try nextHello(on: rejoined)

        let lost = try nextLost(on: rejoined)
        XCTAssertEqual(lost.ids, [id], "the session the previous daemon never recorded an end for")
        XCTAssertNotNil(lost.incidentID)
        XCTAssertNotNil(lost.detectedAt)

        let observer = try connect(to: restarted, greeting: false)
        observer.send(.hello(PTYHostHello(build: "test", pid: getpid())))
        _ = try nextHello(on: observer)
        let repeated = try nextLost(on: observer)
        XCTAssertEqual(repeated.incidentID, lost.incidentID)
        XCTAssertEqual(repeated.detectedAt, lost.detectedAt)

        try waitUntil(timeout: Fixture.exitTimeout, "the orphaned child is reclaimed") {
            DaemonTestPOSIX.kill(spawned.pid, 0) != 0 && errno == ESRCH
        }
    }

    func testARestartReportsOneLossForSeveralIncarnationsOfOneIdentity() throws {
        let daemon = try startDaemon()
        let first = try connect(to: daemon)
        let id = Self.newIdentity()
        _ = try spawn(on: first, id: id, script: "exit 0")
        _ = try nextExit(on: first)

        let second = try connect(to: daemon)
        try waitUntil(timeout: Fixture.replyTimeout, "the observed exit is released") {
            second.send(.list)
            return try nextSessions(on: second).isEmpty
        }
        let running = try spawn(on: second, id: id, script: "sleep 60")

        daemon.crash()
        first.hangUp()
        second.hangUp()
        try waitUntil(timeout: Fixture.exitTimeout, "the first daemon is gone") {
            !daemon.isRunning
        }

        let restarted = try startDaemon(reusing: daemon)
        let rejoined = try connect(to: restarted, greeting: false)
        rejoined.send(.hello(PTYHostHello(build: "test", pid: getpid())))
        _ = try nextHello(on: rejoined)
        XCTAssertEqual(try nextLost(on: rejoined).ids, [id])
        try waitUntil(timeout: Fixture.exitTimeout, "the orphaned replacement is reclaimed") {
            DaemonTestPOSIX.kill(running.pid, 0) != 0 && errno == ESRCH
        }
    }

    // MARK: - The aggregate ring bound

    /// A per-session cap is not an aggregate one, and the session nobody is watching is the one
    /// that gives memory back.
    func testTheAggregateRingCapShrinksTheOldestDetachedSessionFirst() throws {
        // One and a half rings, so the second session cannot fit beside the first.
        let daemon = try startDaemon(ringBudget: 786_432)

        let detachedClient = try connect(to: daemon)
        let detachedID = Self.newIdentity()
        _ = try spawn(on: detachedClient, id: detachedID, script: "sleep 30")
        detachedClient.send(.detach(PTYHostDetach(
            id: detachedID,
            screenSeed: Data(),
            modeSeed: Data(),
            ringOffset: 0
        )))

        let attachedClient = try connect(to: daemon)
        let attachedID = Self.newIdentity()
        _ = try spawn(on: attachedClient, id: attachedID, script: "sleep 30")

        attachedClient.send(.journalTail(PTYHostJournalTail(maxBytes: 64 * 1024)))
        let lines = try nextJournal(on: attachedClient).lines
        let shrinks = lines.filter { $0.contains("ringShrunk") && $0.contains("\"from\"") }
        XCTAssertEqual(shrinks.count, 1, "one session gave memory back, and it is journalled")
        XCTAssertTrue(
            shrinks.allSatisfy { $0.contains(detachedID.description) },
            "the detached one — shrinking a session somebody is watching costs a rejoin they see"
        )
        XCTAssertFalse(
            shrinks.contains { $0.contains(attachedID.description) },
            "never the attached one"
        )
    }

    // MARK: - Helpers

    private static func newIdentity() -> PTYHostSessionIdentity {
        PTYHostSessionIdentity.agentSession(SessionID(UUID()))
    }

    private func helperURL() throws -> URL {
        #if SWIFT_PACKAGE
        // A named binary first, so the Linux lane can run this suite against the static release
        // artifact it is about to hand out rather than only against the debug build.
        if let named = ProcessInfo.processInfo.environment[Fixture.helperOverrideKey] {
            let url = URL(fileURLWithPath: named)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw PTYHostTestFailure("\(Fixture.helperOverrideKey) names \(named), which is not executable")
            }
            return url
        }
        // Otherwise SwiftPM's product beside the test bundle: the bundle *is* that directory on
        // Linux, and sits inside it as `….xctest` on macOS.
        let bundle = Bundle(for: PTYHostDaemonTests.self).bundleURL
        let candidates = [bundle, bundle.deletingLastPathComponent()].map {
            $0.appendingPathComponent(Fixture.helperName, isDirectory: false)
        }
        guard let url = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw XCTSkip("no \(Fixture.helperName) beside the test bundle — `swift build` first")
        }
        return url
        #else
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(Fixture.helperName, isDirectory: false)
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: url.path),
            "no \(Fixture.helperName) in this bundle — build the Threading target, which embeds "
                + "it through the Embed Extension Helpers phase, and run the hosted test target"
        )
        return url
        #endif
    }

    @discardableResult
    private func startDaemon(ringBudget: Int? = nil) throws -> DaemonProcess {
        let index = daemons.count
        let daemon = try DaemonProcess(
            helper: try helperURL(),
            socketPath: directory.appendingPathComponent("d\(index).sock").path,
            stateDirectory: directory.appendingPathComponent("s\(index)", isDirectory: true),
            ringBudget: ringBudget
        )
        daemons.append(daemon)
        try daemon.waitUntilListening(timeout: Fixture.replyTimeout)
        return daemon
    }

    /// A second daemon on the first one's socket and state directory — the `KeepAlive` restart.
    private func startDaemon(reusing previous: DaemonProcess) throws -> DaemonProcess {
        let daemon = try DaemonProcess(
            helper: try helperURL(),
            socketPath: previous.socketPath,
            stateDirectory: previous.stateDirectory,
            ringBudget: nil
        )
        daemons.append(daemon)
        try daemon.waitUntilListening(timeout: Fixture.replyTimeout)
        return daemon
    }

    private func connect(to daemon: DaemonProcess, greeting: Bool = true) throws -> PTYHostTestClient {
        let client = try PTYHostTestClient(socketPath: daemon.socketPath)
        clients.append(client)
        if greeting {
            client.send(.hello(PTYHostHello(build: "test", pid: getpid())))
            _ = try nextHello(on: client)
        }
        return client
    }

    @discardableResult
    private func spawn(
        on client: PTYHostTestClient,
        id: PTYHostSessionIdentity,
        script: String,
        grid: PTYHostGrid = PTYHostGrid(cols: 80, rows: 24),
        replaceExisting: Bool = false
    ) throws -> PTYHostSpawned {
        client.send(.spawn(PTYHostSpawnRequest(
            id: id,
            channel: .pty(grid: grid),
            executable: Fixture.shell,
            arguments: ["-c", script],
            environment: Self.childEnvironment,
            cwd: NSTemporaryDirectory(),
            replaceExisting: replaceExisting
        )))
        let frame = try client.nextControl(timeout: Fixture.replyTimeout) {
            if case .spawned = $0 { return true }
            if case .spawnRefused = $0 { return true }
            return false
        }
        guard case .spawned(let body) = frame else {
            throw PTYHostTestFailure("the daemon refused the spawn: \(frame)")
        }
        return body
    }

    /// The same spawn on three pipes: no grid, because there is no terminal to size.
    @discardableResult
    private func spawnPipes(
        on client: PTYHostTestClient,
        id: PTYHostSessionIdentity,
        script: String
    ) throws -> PTYHostSpawned {
        client.send(.spawn(PTYHostSpawnRequest(
            id: id,
            channel: .pipes,
            executable: Fixture.shell,
            arguments: ["-c", script],
            environment: Self.childEnvironment,
            cwd: NSTemporaryDirectory()
        )))
        let frame = try client.nextControl(timeout: Fixture.replyTimeout) {
            if case .spawned = $0 { return true }
            if case .spawnRefused = $0 { return true }
            return false
        }
        guard case .spawned(let body) = frame else {
            throw PTYHostTestFailure("the daemon refused the spawn: \(frame)")
        }
        return body
    }

    private func attach(
        on client: PTYHostTestClient,
        id: PTYHostSessionIdentity,
        budget: Int? = nil
    ) throws -> PTYHostAttached {
        client.send(.attach(PTYHostAttach(id: id, replayBudget: budget)))
        let frame = try client.nextControl(timeout: Fixture.replyTimeout) {
            if case .attached = $0 { return true }
            if case .error = $0 { return true }
            return false
        }
        guard case .attached(let body) = frame else {
            throw PTYHostTestFailure("the daemon refused the attach: \(frame)")
        }
        return body
    }

    private func nextHello(on client: PTYHostTestClient) throws -> PTYHostHello {
        let frame = try client.nextControl(timeout: Fixture.replyTimeout) {
            if case .hello = $0 { return true }
            if case .helloRefused = $0 { return true }
            return false
        }
        guard case .hello(let body) = frame else {
            throw PTYHostTestFailure("the daemon refused the hello: \(frame)")
        }
        return body
    }

    private func nextHelloRefusal(on client: PTYHostTestClient) throws -> PTYHostHelloRefusal {
        let frame = try client.nextControl(timeout: Fixture.replyTimeout) {
            if case .helloRefused = $0 { return true }
            return false
        }
        guard case .helloRefused(let body) = frame else { throw PTYHostTestFailure("\(frame)") }
        return body
    }

    private func nextExit(on client: PTYHostTestClient) throws -> PTYHostExited {
        let frame = try client.nextControl(timeout: Fixture.exitTimeout) {
            if case .exited = $0 { return true }
            return false
        }
        guard case .exited(let body) = frame else { throw PTYHostTestFailure("\(frame)") }
        return body
    }

    private func nextForeground(
        on client: PTYHostTestClient,
        timeout: TimeInterval = Fixture.replyTimeout
    ) throws -> PTYHostForeground {
        let frame = try client.nextControl(timeout: timeout) {
            if case .foreground = $0 { return true }
            return false
        }
        guard case .foreground(let body) = frame else { throw PTYHostTestFailure("\(frame)") }
        return body
    }

    private func nextResized(on client: PTYHostTestClient) throws -> PTYHostResized {
        let frame = try client.nextControl(timeout: Fixture.replyTimeout) {
            if case .resized = $0 { return true }
            if case .error = $0 { return true }
            return false
        }
        guard case .resized(let body) = frame else { throw PTYHostTestFailure("\(frame)") }
        return body
    }

    private func nextError(on client: PTYHostTestClient) throws -> PTYHostErrorFrame {
        let frame = try client.nextControl(timeout: Fixture.replyTimeout) {
            if case .error = $0 { return true }
            return false
        }
        guard case .error(let body) = frame else { throw PTYHostTestFailure("\(frame)") }
        return body
    }

    private func nextLost(on client: PTYHostTestClient) throws -> PTYHostLost {
        let frame = try client.nextControl(timeout: Fixture.replyTimeout) {
            if case .lost = $0 { return true }
            return false
        }
        guard case .lost(let body) = frame else { throw PTYHostTestFailure("\(frame)") }
        return body
    }

    private func nextSessions(on client: PTYHostTestClient) throws -> [PTYHostSessionSummary] {
        let frame = try client.nextControl(timeout: Fixture.replyTimeout) {
            if case .sessions = $0 { return true }
            return false
        }
        guard case .sessions(let body) = frame else { throw PTYHostTestFailure("\(frame)") }
        return body
    }

    private func nextJournal(on client: PTYHostTestClient) throws -> PTYHostJournal {
        let frame = try client.nextControl(timeout: Fixture.replyTimeout) {
            if case .journal = $0 { return true }
            return false
        }
        guard case .journal(let body) = frame else { throw PTYHostTestFailure("\(frame)") }
        return body
    }

    /// The environment the daemon is handed for a child. Composed here rather than inherited,
    /// because that is the contract: the daemon adds nothing and removes nothing.
    private static var childEnvironment: [String] {
        var environment = [
            "TERM=xterm-256color",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL=C"
        ]
        if let token = ProcessInfo.processInfo.environment["THREADING_TEST_RUN_TOKEN"] {
            environment.append("THREADING_TEST_RUN_TOKEN=\(token)")
        }
        return environment
    }

    private func waitUntil(
        timeout: TimeInterval,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () throws -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("timed out waiting until \(what)", file: file, line: line)
    }
}

// MARK: - Failure

private struct PTYHostTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - The daemon under test

/// One `threading-ptyd` process, with its scratch socket and scratch state directory.
private final class DaemonProcess: @unchecked Sendable {

    // MARK: - Properties

    let socketPath: String
    let stateDirectory: URL

    private let process = Process()
    private let helper: URL
    private let ringBudget: Int?
    private let diagnostics = Pipe()
    private let lock = NSLock()
    private var collected = Data()

    // MARK: - Initialization

    init(helper: URL, socketPath: String, stateDirectory: URL, ringBudget: Int?) throws {
        self.helper = helper
        self.socketPath = socketPath
        self.stateDirectory = stateDirectory
        self.ringBudget = ringBudget

        process.executableURL = helper
        process.arguments = ["--socket", socketPath, "--state", stateDirectory.path]
        var environment = ["PATH": "/usr/bin:/bin"]
        if let ringBudget {
            environment["THREADING_PTY_HOST_RING_BUDGET"] = String(ringBudget)
        }
        if let token = ProcessInfo.processInfo.environment["THREADING_TEST_RUN_TOKEN"] {
            environment["THREADING_TEST_RUN_TOKEN"] = token
        }
        process.environment = environment
        process.standardError = diagnostics
        process.standardOutput = FileHandle.nullDevice

        // Drained rather than left to fill: the daemon's bounded stderr mirror is small, but a
        // pipe nobody reads is a process that eventually blocks writing to it.
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

    // MARK: - Public Methods

    var isRunning: Bool { process.isRunning }

    /// Meaningful once the process has exited.
    var terminationStatus: Int32 { process.terminationStatus }

    /// `SIGTERM`, for a daemon a test started but that holds nothing worth draining.
    func terminateIfRunning() {
        guard process.isRunning else { return }
        process.terminate()
        _ = waitUntilExited(timeout: PTYHostTestProcessCleanup.childTimeout)
    }

    /// Ready means *connectable*, not "the file is there".
    ///
    /// A daemon that was killed leaves its socket file behind, and the next one unlinks and
    /// rebinds it — so a restart test that waited for the file would find the dead one's and
    /// race the new bind.
    func waitUntilListening(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let probe = try? PTYHostTestClient(socketPath: socketPath) {
                probe.hangUp()
                return
            }
            if !process.isRunning {
                throw PTYHostTestFailure("the daemon exited before listening: \(diagnosticText)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw PTYHostTestFailure("the daemon never bound \(socketPath): \(diagnosticText)")
    }

    func waitUntilExited(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// What a crash looks like: no chance to write anything down, no chance to say goodbye.
    func crash() {
        guard process.isRunning else { return }
        DaemonTestPOSIX.kill(process.processIdentifier, SIGKILL)
    }

    /// Drains the endpoint through the shipping protocol. If the daemon already crashed before
    /// the test reached its recovery assertion, a replacement is launched on the same state
    /// directory first; startup then validates pid/start-time pairs and reclaims every survivor.
    func shutdown() -> Bool {
        if process.isRunning {
            let drained = PTYHostTestProcessCleanup.stopSessionsAndRetire(socketPath: socketPath)
            let exited = waitUntilExited(timeout: PTYHostTestProcessCleanup.childTimeout)
            return drained && exited
        }

        if PTYHostTestProcessCleanup.daemonIsReady(socketPath: socketPath) {
            return PTYHostTestProcessCleanup.stopSessionsAndRetire(socketPath: socketPath)
        }

        guard let recovery = try? DaemonProcess(
            helper: helper,
            socketPath: socketPath,
            stateDirectory: stateDirectory,
            ringBudget: ringBudget
        ), tryRecoveryListening(recovery) else {
            return false
        }
        let drained = PTYHostTestProcessCleanup.stopSessionsAndRetire(socketPath: socketPath)
        let exited = recovery.waitUntilExited(timeout: PTYHostTestProcessCleanup.childTimeout)
        recovery.finishDiagnostics()
        return drained && exited
    }

    func finishDiagnostics() {
        diagnostics.fileHandleForReading.readabilityHandler = nil
    }

    private func tryRecoveryListening(_ recovery: DaemonProcess) -> Bool {
        do {
            try recovery.waitUntilListening(timeout: PTYHostTestProcessCleanup.replyTimeout)
            return true
        } catch {
            return false
        }
    }

    var diagnosticText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: collected, as: UTF8.self)
    }
}

// MARK: - The client under test

/// A client of the daemon that speaks the shipping codec over a real unix socket.
///
/// Blocking POSIX socket plus one reader thread, rather than `DispatchIO`: a test wants to say
/// "wait until this frame arrives" and a condition variable says that directly.
private final class PTYHostTestClient: @unchecked Sendable {

    // MARK: - Properties

    private let descriptor: Int32
    private let condition = NSCondition()
    private var decoder = PTYHostFrameDecoder()
    private var controls: [PTYHostFrame] = []
    private var received = Data()
    /// Only a `.pipes` session ever fills this: a pseudo-terminal has one stream by
    /// construction, so a pty session's frames never carry the standard-error flag.
    private var receivedErrors = Data()
    private var closed = false

    private static let encoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()

    // MARK: - Initialization

    init(socketPath: String) throws {
        descriptor = socket(AF_UNIX, DaemonTestPOSIX.streamSocketType, 0)
        guard descriptor >= 0 else { throw PTYHostTestFailure("socket() failed") }

        // Without this a write to a socket the daemon has already closed would raise `SIGPIPE`
        // in the *test host*, which is a crash rather than a failure. Linux has no such socket
        // option; there every write says `MSG_NOSIGNAL` instead (`DaemonTestPOSIX.send`).
        #if canImport(Darwin)
        var suppress: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &suppress,
            socklen_t(MemoryLayout<Int32>.size)
        )
        #endif

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let bytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw PTYHostTestFailure("socket path is \(bytes.count) bytes, too long to connect to")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                DaemonTestPOSIX.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            DaemonTestPOSIX.close(descriptor)
            throw PTYHostTestFailure("connect() failed: \(String(cString: strerror(errno)))")
        }

        Thread.detachNewThread { [self] in read() }
    }

    // MARK: - Public Methods

    func send(_ frame: PTYHostFrame) {
        guard let payload = try? Self.encoder.encode(frame),
              let framed = try? PTYHostFraming.encode(kind: .control, payload: payload) else {
            return
        }
        write(framed)
    }

    func sendInput(_ text: String) {
        guard let framed = try? PTYHostFraming.encode(
            kind: .input,
            payload: Data(text.utf8)
        ) else { return }
        write(framed)
    }

    /// A header alone, declaring a payload past the wire's bound. The daemon has to refuse it
    /// from the header, before a payload byte is buffered.
    func sendOversizeHeader(declaring length: Int) {
        var header = Data([PTYHostFrameKind.output.rawValue, 0, 0, 0])
        let declared = UInt32(length)
        header.append(UInt8(truncatingIfNeeded: declared))
        header.append(UInt8(truncatingIfNeeded: declared >> 8))
        header.append(UInt8(truncatingIfNeeded: declared >> 16))
        header.append(UInt8(truncatingIfNeeded: declared >> 24))
        write(header)
    }

    /// Closes the socket with no detach and no goodbye — a crashed or killed client.
    func hangUp() {
        condition.lock()
        let alreadyClosed = closed
        closed = true
        condition.broadcast()
        condition.unlock()
        guard !alreadyClosed else { return }
        DaemonTestPOSIX.shutdownReadWrite(descriptor)
    }

    var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    var bytes: Data {
        condition.lock()
        defer { condition.unlock() }
        return received
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    /// What arrived on the child's standard error, kept apart from its standard output because
    /// merging the two would corrupt the newline-delimited JSON a conversation transport parses.
    var errorBytes: Data {
        condition.lock()
        defer { condition.unlock() }
        return receivedErrors
    }

    var errorText: String { String(decoding: errorBytes, as: UTF8.self) }

    func waitForErrorOutput(containing needle: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if String(decoding: receivedErrors, as: UTF8.self).contains(needle) { return }
            guard condition.wait(until: deadline) else {
                throw PTYHostTestFailure(
                    "the child never produced \(needle) on standard error; it produced "
                        + String(decoding: receivedErrors.suffix(200), as: UTF8.self)
                            .debugDescription
                )
            }
        }
    }

    func resetOutput() {
        condition.lock()
        received = Data()
        condition.unlock()
    }

    func nextControl(
        timeout: TimeInterval,
        matching: (PTYHostFrame) -> Bool
    ) throws -> PTYHostFrame {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let index = controls.firstIndex(where: matching) {
                return controls.remove(at: index)
            }
            guard condition.wait(until: deadline) else {
                throw PTYHostTestFailure("no matching control frame arrived; had \(controls)")
            }
        }
    }

    func waitForOutput(containing needle: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if String(decoding: received, as: UTF8.self).contains(needle) { return }
            guard condition.wait(until: deadline) else {
                throw PTYHostTestFailure(
                    "the child never produced \(needle); it produced "
                        + String(decoding: received.suffix(200), as: UTF8.self).debugDescription
                )
            }
        }
    }

    func waitForBytes(atLeast count: Int, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if received.count >= count { return }
            guard condition.wait(until: deadline) else {
                throw PTYHostTestFailure("only \(received.count) of \(count) bytes arrived")
            }
        }
    }

    // MARK: - Private Methods

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                DaemonTestPOSIX.read(descriptor, $0.baseAddress, $0.count)
            }
            guard count > 0 else {
                condition.lock()
                closed = true
                condition.broadcast()
                condition.unlock()
                DaemonTestPOSIX.close(descriptor)
                return
            }
            let incoming = Data(buffer[0..<count])
            condition.lock()
            switch decoder.accept(incoming) {
            case .frames(let frames):
                for frame in frames {
                    switch frame.kind {
                    case .control:
                        if let control = try? Self.jsonDecoder.decode(
                            PTYHostFrame.self,
                            from: frame.payload
                        ) {
                            controls.append(control)
                        }
                    case .output:
                        if frame.flags & PTYHostFramingDefaults.standardErrorFlag != 0 {
                            receivedErrors.append(frame.payload)
                        } else {
                            received.append(frame.payload)
                        }
                    case .input:
                        break
                    }
                }
            case .refused:
                closed = true
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    private func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = DaemonTestPOSIX.send(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                return
            }
        }
    }
}

// MARK: - POSIX spellings

/// The few calls Darwin and Linux spell differently, qualified because `PTYHostTestClient` has
/// `read` and `write` methods of its own.
private enum DaemonTestPOSIX {

    @discardableResult
    static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.kill(pid, signal)
        #else
        return Glibc.kill(pid, signal)
        #endif
    }

    static func close(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #else
        _ = Glibc.close(descriptor)
        #endif
    }

    static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(descriptor, buffer, count)
        #else
        return Glibc.read(descriptor, buffer, count)
        #endif
    }

    static func connect(
        _ descriptor: Int32,
        _ address: UnsafePointer<sockaddr>,
        _ length: socklen_t
    ) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(descriptor, address, length)
        #else
        return Glibc.connect(descriptor, address, length)
        #endif
    }

    /// A write that cannot raise `SIGPIPE`: the socket option covers it on Darwin, and on Linux
    /// the flag has to be named on every call.
    static func send(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(descriptor, buffer, count)
        #else
        return Glibc.send(descriptor, buffer, count, Int32(MSG_NOSIGNAL))
        #endif
    }

    /// `shutdown(SHUT_RDWR)`. Glibc imports the constant as `Int`.
    static func shutdownReadWrite(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = shutdown(descriptor, SHUT_RDWR)
        #else
        _ = shutdown(descriptor, Int32(SHUT_RDWR))
        #endif
    }

    static var streamSocketType: Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #else
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }
}

#if SWIFT_PACKAGE
// MARK: - Cleanup without the app

/// The package build's `PTYHostTestProcessCleanup`.
///
/// The hosted target's version drives the app's `PTYHostClient`, which a package cannot link. This
/// is the same drain — end every live detached session with the shipping attach-then-kill, then
/// retire — spoken with this file's own client, so a scratch daemon never strands a process group
/// on the machine running the tests.
private enum PTYHostTestProcessCleanup {
    static let childTimeout: TimeInterval = 8
    static let replyTimeout: TimeInterval = 3

    static func daemonIsReady(socketPath: String) -> Bool {
        guard let client = greeted(socketPath: socketPath) else { return false }
        client.hangUp()
        return true
    }

    @discardableResult
    static func stopSessionsAndRetire(
        socketPath: String,
        timeout: TimeInterval = childTimeout
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var drained = false

        while Date() < deadline {
            guard let held = sessions(socketPath: socketPath) else {
                drained = !daemonIsReady(socketPath: socketPath)
                break
            }
            let live = held.filter { $0.exit == nil }
            if live.isEmpty {
                drained = true
                break
            }
            var attemptedStop = false
            for session in live where !session.isAttached {
                attemptedStop = true
                stop(session.id, socketPath: socketPath)
            }
            if !attemptedStop { Thread.sleep(forTimeInterval: 0.05) }
        }

        guard let client = greeted(socketPath: socketPath) else { return drained }
        client.send(.retire)
        client.hangUp()
        return drained
    }

    private static func greeted(socketPath: String) -> PTYHostTestClient? {
        guard let client = try? PTYHostTestClient(socketPath: socketPath) else { return nil }
        client.send(.hello(PTYHostHello(build: "test-cleanup", pid: getpid())))
        let answered = try? client.nextControl(timeout: replyTimeout) {
            if case .hello = $0 { return true }
            return false
        }
        guard answered != nil else {
            client.hangUp()
            return nil
        }
        return client
    }

    private static func sessions(socketPath: String) -> [PTYHostSessionSummary]? {
        guard let client = greeted(socketPath: socketPath) else { return nil }
        defer { client.hangUp() }
        client.send(.list)
        guard let frame = try? client.nextControl(timeout: replyTimeout, matching: {
            if case .sessions = $0 { return true }
            return false
        }), case .sessions(let held) = frame else { return nil }
        return held
    }

    private static func stop(_ id: PTYHostSessionIdentity, socketPath: String) {
        guard let client = greeted(socketPath: socketPath) else { return }
        defer { client.hangUp() }
        client.send(.attach(PTYHostAttach(id: id, replayBudget: PTYHostReplayDefaults.minimumBudgetBytes)))
        client.send(.kill(PTYHostKill(id: id, escalate: true)))
        _ = try? client.nextControl(timeout: childTimeout) {
            if case .exited(let ending) = $0 { return ending.id == id }
            return false
        }
    }
}
#endif
