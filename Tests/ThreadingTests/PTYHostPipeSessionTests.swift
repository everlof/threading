import Darwin
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest

@testable import Threading

/// A native conversation whose CLI runs in `threading-ptyd`.
///
/// **No daemon, no socket and no window.** The wire below `PTYHostSessionTransport` is already
/// covered by `PTYHostClientTests` and by `PTYHostDaemonTests`, which meets the real binary on a
/// real unix socket; what is worth asserting here is the half the design named as the risky one —
/// that the three transports are handed *the same three descriptors* they always were, so their
/// framing, handshake deadlines, malformed-line counters and exactly-once exit callbacks are
/// untouched by where the child happens to live.
///
/// Every wait is bounded, and nothing here writes to the developer's own ledger.
@MainActor
final class PTYHostPipeSessionTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        /// One dispatch hop plus a pipe write. Generous, because the point of each assertion is
        /// that the bytes arrive at all.
        static let timeout: TimeInterval = 5
        /// The bound `AgentChildProcess.launch` degrades on. Waited out deliberately in one test.
        static let silence: TimeInterval = PTYHostPipeDefaults.spawnTimeout + 3
        static let hostPid: pid_t = 4242
        /// A child that reads its standard input and never ends on its own, for the local
        /// fallback: the assertion is that a real child exists, not what it prints.
        static let localExecutable = "/bin/cat"
    }

    // MARK: - Fixture state

    private var directory: URL!
    private var ledger: AgentChildLedger!
    private var launched: [AgentChildProcess] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ptypipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ledger = AgentChildLedger(url: directory.appendingPathComponent("children.json"))
    }

    override func tearDownWithError() throws {
        for process in launched where process.isRunning { process.terminate() }
        launched.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - The launch

    /// The daemon's answer is what the launch reports: its pid, its start time, its child.
    func testALaunchTheHostAnswersRunsTheChildThere() throws {
        let transport = TransportBox()
        let process = try launch(answering: .spawned, into: transport)

        XCTAssertTrue(process.isHostBacked, "the child is the daemon's")
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(
            process.processIdentifier,
            Fixture.hostPid,
            "the pid is the one the daemon reported, not one read here"
        )

        let request = try XCTUnwrap(transport.transport?.spawnRequest)
        XCTAssertEqual(request.channel, .pipes, "a conversation has no terminal")
        XCTAssertEqual(request.executable, Fixture.localExecutable)
        XCTAssertEqual(request.arguments, ["-u"])
        XCTAssertEqual(
            request.environment,
            ["A=1", "B=2"],
            "sorted, because a launch whose environment order depends on a hash seed is a launch "
                + "that cannot be compared with the one before it"
        )
    }

    /// The ledger records it as the host's, which is what stops every sweeper acting on it.
    ///
    /// Recording it at all is what lets a launch *see* what is running; `owner: .ptyHost` is what
    /// stops the same launch killing it.
    func testTheLedgerRecordsAHostBackedChildAsHeldByTheHost() throws {
        _ = try launch(answering: .spawned, into: TransportBox())

        guard case .loaded(let records) = ledger.consumeInheritedRecords() else {
            return XCTFail("the ledger refused to read back")
        }
        let record = try XCTUnwrap(records.first { $0.pid == Fixture.hostPid })
        XCTAssertEqual(record.resolvedOwner, .ptyHost)
        XCTAssertEqual(
            OrphanedAgentChildSweep.verdict(
                for: record,
                probe: .running(record.startTime)
            ),
            .skip(.heldByHost),
            "ownership is settled before the machine is asked anything"
        )
    }

    /// Every refusal is "run it here instead", and the launch that follows is the one this app
    /// performed before the daemon existed.
    func testASpawnRefusalRunsTheChildInThisProcessInstead() throws {
        let process = try launch(answering: .refused, into: TransportBox())

        XCTAssertFalse(process.isHostBacked)
        XCTAssertTrue(process.isRunning, "a refusal is a degradation, never a launch failure")
        XCTAssertNotEqual(process.processIdentifier, Fixture.hostPid)
    }

    /// A daemon that stops answering costs a launch a fallback rather than a hang.
    ///
    /// `AgentChildProcess.launch` is synchronous by contract — the transports set `isRunning` on
    /// the line after it returns — so the host-backed path has to answer the same question before
    /// it returns, and silence has to be one of the answers.
    func testASilentDaemonDegradesRatherThanHoldingTheLaunch() throws {
        let started = Date()
        let process = try launch(answering: .silence, into: TransportBox())

        XCTAssertFalse(process.isHostBacked)
        XCTAssertTrue(process.isRunning)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            Fixture.silence,
            "the wait is bounded by PTYHostPipeDefaults.spawnTimeout"
        )
    }

    // MARK: - The three descriptors

    /// The transport reads its CLI's standard output through the same `FileHandle` it always did.
    func testWhatTheDaemonSendsArrivesOnTheTransportsOwnDescriptors() throws {
        let box = TransportBox()
        let process = try launch(answering: .spawned, into: box)
        let transport = try XCTUnwrap(box.transport)

        let output = expectation(description: "standard output")
        let errors = expectation(description: "standard error")
        let seen = ByteSink()
        process.standardOutput.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if seen.appendOutput(chunk).contains("{\"type\":\"ready\"}\n") { output.fulfill() }
        }
        process.standardError.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if seen.appendError(chunk).contains("a warning") { errors.fulfill() }
        }

        transport.send(output: Data("{\"type\":\"ready\"}\n".utf8))
        transport.send(standardError: Data("a warning".utf8))
        wait(for: [output, errors], timeout: Fixture.timeout)

        XCTAssertFalse(
            seen.output.contains("a warning"),
            "a diagnostic merged into the parsed stream is a malformed record, not a message"
        )
        process.standardOutput.readabilityHandler = nil
        process.standardError.readabilityHandler = nil
    }

    /// And writes its turns through the same one, which reach the daemon as `input`.
    func testWhatTheTransportWritesReachesTheDaemon() throws {
        let box = TransportBox()
        let process = try launch(answering: .spawned, into: box)
        let transport = try XCTUnwrap(box.transport)

        try process.standardInput.write(contentsOf: Data("{\"turn\":1}\n".utf8))

        let delivered = expectation(description: "input reached the daemon")
        poll(delivered) {
            String(decoding: transport.inputs.reduce(Data(), +), as: UTF8.self)
                .contains("{\"turn\":1}")
        }
        wait(for: [delivered], timeout: Fixture.timeout)
    }

    /// Closing standard input is how every native transport says goodbye, and it is a descriptor
    /// event with no byte to carry it — which is why the wire has a frame for it.
    func testClosingStandardInputSaysSoOnTheWire() throws {
        let box = TransportBox()
        let process = try launch(answering: .spawned, into: box)
        let transport = try XCTUnwrap(box.transport)

        try process.standardInput.close()

        let closed = expectation(description: "closeInput reached the daemon")
        poll(closed) { !transport.closeInputs.isEmpty }
        wait(for: [closed], timeout: Fixture.timeout)
    }

    /// The same `F_SETNOSIGPIPE` on the same descriptor, whichever process the child is in.
    ///
    /// A transport may write into a pipe whose reader has just gone — the child exited between
    /// two writes — and on this descriptor that has to be an ordinary `EPIPE` rather than a
    /// signal that ends Threading.
    func testStandardInputRefusesSignalsOnBothPaths() throws {
        let hosted = try launch(answering: .spawned, into: TransportBox())
        let local = try launch(answering: .refused, into: TransportBox())

        XCTAssertEqual(fcntl(hosted.standardInput.fileDescriptor, F_GETNOSIGPIPE), 1)
        XCTAssertEqual(
            fcntl(local.standardInput.fileDescriptor, F_GETNOSIGPIPE),
            1,
            "the two paths are the same three pipes"
        )
    }

    // MARK: - The ending

    /// One ending, whichever way it arrives.
    ///
    /// The `exited` frame and the connection dropping under it are the same fact seen twice, and
    /// a transport told twice would run its teardown on a conversation it had already closed.
    func testTheExitIsReportedExactlyOnce() throws {
        let box = TransportBox()
        let statuses = StatusSink()
        let drained = expectation(description: "the host may now be idle")
        drained.assertForOverFulfill = true
        let observations = AppEventObservations()
        observations.observe(PTYHostMayHaveDrained.self) { _ in drained.fulfill() }
        _ = try launch(answering: .spawned, into: box, onExit: { statuses.append($0) })
        let transport = try XCTUnwrap(box.transport)

        transport.send(.exited(PTYHostExited(
            id: transport.identity,
            status: 3,
            signalled: false
        )))
        let reported = expectation(description: "the ending arrived")
        poll(reported) { !statuses.statuses.isEmpty }
        wait(for: [reported, drained], timeout: Fixture.timeout)

        transport.drop(nil)
        transport.send(.exited(PTYHostExited(
            id: transport.identity,
            status: 9,
            signalled: true
        )))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(statuses.statuses, [3], "the ending is delivered exactly once")
    }

    /// A link that ended without an `exited` is still an ending, and says which one.
    ///
    /// `128 + SIGHUP` rather than the spawn-failure status: the child lost what it was attached
    /// to, which is exactly what happens when the daemon goes, and reporting "it never started"
    /// would put a launch failure on a conversation that had been running for an hour.
    func testALostLinkIsReportedAsAnEndingRatherThanALaunchFailure() throws {
        let box = TransportBox()
        let statuses = StatusSink()
        _ = try launch(answering: .spawned, into: box, onExit: { statuses.append($0) })
        let transport = try XCTUnwrap(box.transport)

        transport.drop(.notReady)
        let reported = expectation(description: "the ending arrived")
        poll(reported) { !statuses.statuses.isEmpty }
        wait(for: [reported], timeout: Fixture.timeout)

        XCTAssertEqual(statuses.statuses, [PTYHostPipeDefaults.linkLostStatus])
        XCTAssertNotEqual(
            statuses.statuses.first,
            AgentChildProcessDefaults.spawnFailureStatus,
            "a conversation that ran for an hour did not fail to start"
        )
    }

    // MARK: - The hand-over

    /// A quit hands the child over, and every later teardown then does nothing.
    ///
    /// The second half is the one that matters: the quit path detaches every host-backed
    /// conversation and *then* tears every session down, and the second step must not undo the
    /// first.
    func testDetachHandsTheChildOverAndTerminateThenEndsNothing() throws {
        let box = TransportBox()
        let statuses = StatusSink()
        let process = try launch(answering: .spawned, into: box, onExit: { statuses.append($0) })
        let transport = try XCTUnwrap(box.transport)

        XCTAssertTrue(process.detachFromBackgroundHost(
            by: Date().addingTimeInterval(Fixture.timeout),
            ledger: ledger
        ))
        XCTAssertEqual(transport.detaches.count, 1, "the hand-over is deliberate, not a close")
        XCTAssertFalse(process.isRunning, "this process is no longer responsible for it")

        process.terminate()
        XCTAssertTrue(transport.kills.isEmpty, "ending it here is the bug the hand-over prevents")

        guard case .loaded(let records) = ledger.consumeInheritedRecords() else {
            return XCTFail("the ledger refused to read back")
        }
        XCTAssertNil(
            records.first { $0.pid == Fixture.hostPid },
            "the record described what this launch was responsible for, and it no longer is"
        )
        XCTAssertTrue(statuses.statuses.isEmpty, "a hand-over is not an ending")
    }

    /// The seeds a conversation hands over are empty, and that is structural rather than lazy: a
    /// screen seed is a repaint derived from a live emulator, and there is no emulator anywhere.
    func testAHandedOverConversationSeedsNothingBecauseItHasNoScreen() throws {
        let box = TransportBox()
        let process = try launch(answering: .spawned, into: box)
        let transport = try XCTUnwrap(box.transport)

        _ = process.detachFromBackgroundHost(
            by: Date().addingTimeInterval(Fixture.timeout),
            ledger: ledger
        )

        let detach = try XCTUnwrap(transport.detaches.first)
        XCTAssertTrue(detach.screenSeed.isEmpty)
        XCTAssertTrue(detach.modeSeed.isEmpty)
        XCTAssertEqual(detach.ringOffset, 0)
    }

    /// An explicit stop still kills, and it goes through the link because the child is not this
    /// process's to signal.
    func testAnExplicitStopKillsTheChildThroughTheLink() throws {
        let box = TransportBox()
        let process = try launch(answering: .spawned, into: box)
        let transport = try XCTUnwrap(box.transport)

        process.terminate()

        XCTAssertEqual(transport.kills.count, 1)
        XCTAssertTrue(
            transport.kills.first?.escalate ?? false,
            "an agent's own children are in the group, and the group is what is signalled"
        )
    }

    // MARK: - Asking with nobody there

    /// The case this whole slice creates: the CLI is running and Threading is not.
    ///
    /// A conversation's child used to end with the app, so "the app is absent" was a crash story.
    /// Hosted, it is an ordinary quit — the turn goes on, and the next tool it wants is brokered
    /// through a hook whose `curl` reaches nothing. The typed deny is the difference between a
    /// turn that finishes what it can without the tool and one that stalls overnight on a
    /// question nobody is there to answer.
    ///
    /// The exact object is `MCPSessionRegistryTests`'; what is asserted here is that a hosted
    /// conversation is reached by it — same hook file, same fragment, no app.
    func testAToolRequestWithNoAppBehindItIsDeniedInWordsTheModelCanRead() throws {
        let sessionID = SessionID()
        defer { MCPSessionRegistry.remove(sessionID: sessionID) }

        let path = try XCTUnwrap(MCPSessionRegistry.writeHookSettings(
            for: sessionID,
            brokersPermissions: true,
            reportsLifecycle: false
        ))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let settings = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))
        ) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let matchers = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let entries = try XCTUnwrap(matchers.first?["hooks"] as? [[String: Any]])
        let command = try XCTUnwrap(entries.first?["command"] as? String)

        let run = runHook(command, environment: [
            "PATH": "/usr/bin:/bin",
            MCPDefaults.socketEnvironmentKey: "/nonexistent/threading-slice10.sock",
            MCPDefaults.portEnvironmentKey: "",
            MCPDefaults.sessionTokenEnvironmentKey: MCPSessionRegistry.token(for: sessionID)
        ])

        XCTAssertEqual(run.status, 0, "a hook that exits non-zero is read as a failure, not a deny")
        let answer = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(run.output.utf8)) as? [String: Any],
            "the hook printed something the CLI cannot parse: \(run.output)"
        )
        let output = try XCTUnwrap(answer["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["permissionDecision"] as? String, "deny")
        XCTAssertFalse(
            (output["permissionDecisionReason"] as? String ?? "").isEmpty,
            "a deny with no reason is as mute as no answer at all"
        )
    }

    // MARK: - Private Methods

    /// Runs one generated hook command against a `PreToolUse` payload, with the environment a
    /// CLI would have.
    private func runHook(
        _ command: String,
        environment: [String: String]
    ) -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ("\(error)", -1)
        }
        input.fileHandleForWriting.write(
            Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
        )
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    private func launch(
        answering answer: FakePipeTransport.Answer,
        into box: TransportBox,
        onExit: @escaping @Sendable (Int32) -> Void = { _ in }
    ) throws -> AgentChildProcess {
        let sessionID = SessionID()
        let identity = PTYHostSessionIdentity(TerminalInstanceIdentity.agentSession(sessionID))
        let plan = PTYHostChildPlan(
            identity: identity,
            factory: { events in
                let transport = FakePipeTransport(
                    identity: identity,
                    answer: answer,
                    events: events
                )
                box.adopt(transport)
                return transport
            },
            workingDirectory: NSTemporaryDirectory()
        )

        let process = try AgentChildProcess.launch(
            executable: Fixture.localExecutable,
            arguments: ["-u"],
            environment: ["B": "2", "A": "1"],
            sessionID: sessionID,
            ledger: ledger,
            host: plan,
            onExit: onExit
        )
        launched.append(process)
        return process
    }

    /// Fulfils an expectation once a condition holds, without blocking the queue the answer is
    /// delivered on.
    private func poll(_ expectation: XCTestExpectation, until condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(Fixture.timeout)
        func attempt() {
            if condition() {
                expectation.fulfill()
                return
            }
            guard Date() < deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { attempt() }
        }
        DispatchQueue.main.async { attempt() }
    }
}

// MARK: - The fake daemon

/// One conversation's daemon, with no daemon in it.
///
/// Every member of `PTYHostSessionTransport` is recorded rather than performed, and the spawn is
/// answered from the transport's own queue — the queue a real client delivers on — so the
/// synchronous wait under test is the production one.
private final class FakePipeTransport: PTYHostSessionTransport, @unchecked Sendable {

    enum Answer {
        case spawned
        case refused
        case silence
    }

    let identity: PTYHostSessionIdentity

    /// The queue a real client delivers on, which is what the link's own ordering rests on.
    let queue = DispatchQueue(label: "codes.threading.tests.ptyhost.pipes")

    private let answer: Answer
    private let events: PTYHostClient.Events
    private let lock = NSLock()
    private var frames: [PTYHostFrame] = []
    private var inputStorage: [Data] = []
    private var closedStorage = false

    init(identity: PTYHostSessionIdentity, answer: Answer, events: PTYHostClient.Events) {
        self.identity = identity
        self.answer = answer
        self.events = events
    }

    // MARK: - PTYHostSessionTransport

    func spawn(_ request: PTYHostSpawnRequest) throws {
        record(.spawn(request))
        let identity = self.identity
        switch answer {
        case .spawned:
            queue.async { [events] in
                events.frame(.spawned(PTYHostSpawned(
                    id: identity,
                    pid: 4242,
                    startTime: PTYHostProcessStartTime(seconds: 1, microseconds: 2)
                )))
            }
        case .refused:
            queue.async { [events] in
                events.frame(.spawnRefused(PTYHostSpawnRefused(
                    id: identity,
                    reason: .capacity
                )))
            }
        case .silence:
            break
        }
    }

    func attach(_ request: PTYHostAttach) throws { record(.attach(request)) }
    func resize(_ request: PTYHostResize) throws { record(.resize(request)) }
    func detach(_ request: PTYHostDetach) throws { record(.detach(request)) }
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

    // MARK: - What the conversation sent

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

    var detaches: [PTYHostDetach] {
        sent.compactMap { frame -> PTYHostDetach? in
            guard case .detach(let request) = frame else { return nil }
            return request
        }
    }

    var kills: [PTYHostKill] {
        sent.compactMap { frame -> PTYHostKill? in
            guard case .kill(let request) = frame else { return nil }
            return request
        }
    }

    var closeInputs: [PTYHostCloseInput] {
        sent.compactMap { frame -> PTYHostCloseInput? in
            guard case .closeInput(let request) = frame else { return nil }
            return request
        }
    }

    // MARK: - What the daemon would say

    func send(_ frame: PTYHostFrame) {
        queue.sync { events.frame(frame) }
    }

    func send(output bytes: Data) {
        queue.sync { events.output(bytes) }
    }

    func send(standardError bytes: Data) {
        queue.sync { events.standardError(bytes) }
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
    private var storage: FakePipeTransport?

    var transport: FakePipeTransport? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func adopt(_ transport: FakePipeTransport) {
        lock.lock()
        storage = transport
        lock.unlock()
    }
}

/// What a transport read, from whichever thread the handler ran on.
private final class ByteSink: @unchecked Sendable {
    private let lock = NSLock()
    private var outputStorage = Data()
    private var errorStorage = Data()

    @discardableResult
    func appendOutput(_ bytes: Data) -> String {
        lock.lock()
        defer { lock.unlock() }
        outputStorage.append(bytes)
        return String(decoding: outputStorage, as: UTF8.self)
    }

    @discardableResult
    func appendError(_ bytes: Data) -> String {
        lock.lock()
        defer { lock.unlock() }
        errorStorage.append(bytes)
        return String(decoding: errorStorage, as: UTF8.self)
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: outputStorage, as: UTF8.self)
    }
}

/// Every ending the link reported, in order.
private final class StatusSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int32] = []

    func append(_ status: Int32) {
        lock.lock()
        storage.append(status)
        lock.unlock()
    }

    var statuses: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
