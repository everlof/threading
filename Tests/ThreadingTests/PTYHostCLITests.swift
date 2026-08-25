import Darwin
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest

/// `threading-ptyd <verb>`, exercised as the process a person runs.
///
/// Every test here runs the shipping helper **twice**: once as a daemon on a scratch rendezvous,
/// and once as a client pointed at it with `--socket`/`--state`. Nothing is stubbed on either
/// side, because the whole point of the tool is that it speaks the real framing, the real frames
/// and the real version gate to the real daemon — a client tested against a fake would be a client
/// that agrees with a fake.
///
/// **The assertions are about what a person reads and what the shell gets back**: the text on
/// standard output, the sentence on standard error, and the exit code. A frame count would pass
/// against a tool that asked the right questions and printed nothing useful.
///
/// `launchctl` is never the real one. There is one `codes.threading.ptyd` on a machine and it
/// belongs to the developer's own Threading, so every invocation here points
/// `THREADING_PTY_HOST_LAUNCHCTL` at a script replaying a captured answer; the registration line
/// is then a test of the parser over the text it actually has to read.
///
/// Nothing here needs a window, and every wait is bounded.
final class PTYHostCLITests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        /// Generous: each bounds a process launch plus a socket round trip.
        static let replyTimeout: TimeInterval = 10
        /// A CLI invocation that may sit through a kill escalation.
        static let commandTimeout: TimeInterval = 30
        /// How long a stopped child is given to disappear from the process table.
        static let deathTimeout: TimeInterval = 10

        static let helperName = "threading-ptyd"
        static let shell = "/bin/sh"

        /// Two identities that share a prefix, so an ambiguous `stop` is reachable without
        /// drawing UUIDs until two happen to collide.
        static let firstIdentifier = "AAAAAAAA-0000-4000-8000-000000000001"
        static let secondIdentifier = "AAAAAAAA-0000-4000-8000-000000000002"
        static let sharedPrefix = "AAAA"

        /// One real `launchctl print gui/<uid>/codes.threading.ptyd`, captured from a Mac with the
        /// login item registered and the daemon running. Trimmed of the keys the parser has no
        /// interest in; the ones it reads are verbatim, including the neighbouring `spawn type`
        /// and `program identifier` lines that a substring search for "type" or "id" would have
        /// answered with first.
        static let registeredLaunchctlAnswer = """
            codes.threading.ptyd = {
            \tactive count = 1
            \tpath = /Applications/Threading.app/Contents/Library/LaunchAgents/\
            codes.threading.ptyd.plist
            \ttype = LaunchAgent
            \tstate = running

            \tprogram = /Applications/Threading.app/Contents/Helpers/threading-ptyd
            \tprogram identifier = codes.threading.ptyd (mode: 2)
            \targuments = {
            \t\t/Applications/Threading.app/Contents/Helpers/threading-ptyd
            \t\t--default-locations
            \t}

            \tspawn type = interactive (4)
            \tjetsam priority = 40
            \tpid = 4242
            \timmediate reason = speculative
            \tminimum runtime = 10
            }
            """

        /// What launchd says about a label it has never been given.
        static let missingLaunchctlAnswer =
            "Could not find service \"codes.threading.ptyd\" in domain for user"
    }

    // MARK: - Fixture state

    private var directory: URL!
    private var daemons: [CLIDaemon] = []
    private var wireClients: [CLIWireClient] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `sockaddr_un.sun_path` holds 104 bytes and the system temporary directory is already
        // about half of that, so the fixture's own names stay to a handful of characters.
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ptyc-\(UInt32.random(in: 0..<0xFFFF_FFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for client in wireClients { client.hangUp() }
        wireClients.removeAll()
        for daemon in daemons { daemon.terminate() }
        daemons.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - status

    /// Nothing listening is a finding, not a crash: the tool says which half is missing and the
    /// shell gets a 1 to branch on.
    func testStatusSaysNothingIsListeningWhenThereIsNoDaemon() throws {
        let helper = try helperURL()
        let answer = try run(
            helper,
            ["status", "--socket", directory.appendingPathComponent("absent.sock").path,
             "--state", directory.appendingPathComponent("state").path]
        )

        XCTAssertEqual(answer.status, 1, "no daemon answered, so the shell is told so")
        XCTAssertTrue(
            answer.output.contains("(absent)"),
            "the socket line says the file is not there: \(answer.output)"
        )
        XCTAssertTrue(
            answer.output.contains("nothing is listening"),
            "the daemon line says nobody answered: \(answer.output)"
        )
        XCTAssertTrue(
            answer.output.contains("journal"),
            "the journal's path is printed whether or not a daemon answered"
        )
    }

    /// A daemon that answered is reported by what it said about itself and what it holds.
    func testStatusReportsTheDaemonsBuildAndWhatItHolds() throws {
        let helper = try helperURL()
        let daemon = try startDaemon(helper)
        let answer = try run(helper, ["status"] + daemon.locationArguments)

        XCTAssertEqual(answer.status, 0, "a daemon answered: \(answer.error)")
        XCTAssertTrue(answer.output.contains("(present)"), answer.output)
        XCTAssertTrue(
            answer.output.contains("build ") && answer.output.contains("pid "),
            "the greeting's build and pid are reported: \(answer.output)"
        )
        XCTAssertTrue(
            answer.output.contains("protocol \(PTYHostProtocol.current)"),
            "the protocol pair is what the gate compares, so it is what is shown: \(answer.output)"
        )
        XCTAssertTrue(
            answer.output.contains("0 sessions: 0 attached, 0 detached, 0 exited"),
            "an idle daemon holds nothing, and says so in all three counts: \(answer.output)"
        )
    }

    /// The registration line, over a captured `launchctl print` answer.
    ///
    /// The real label is never asked: it is the developer's own login item, so an assertion about
    /// it would be an assertion about their machine's state rather than about this parser.
    func testStatusReadsARegisteredLaunchctlAnswer() throws {
        let helper = try helperURL()
        let daemon = try startDaemon(helper)
        let answer = try run(
            helper,
            ["status"] + daemon.locationArguments,
            launchctl: try fakeLaunchctl(
                named: "registered",
                printing: Fixture.registeredLaunchctlAnswer,
                exiting: 0
            )
        )

        XCTAssertTrue(
            answer.output.contains("codes.threading.ptyd is registered: state running, pid 4242"),
            "the state and the pid are read from the lines that carry them: \(answer.output)"
        )
    }

    /// "Could not find service" is not registered, whatever the exit status was.
    func testStatusReadsAMissingServiceAsNotRegistered() throws {
        let helper = try helperURL()
        let daemon = try startDaemon(helper)
        let answer = try run(
            helper,
            ["status"] + daemon.locationArguments,
            launchctl: try fakeLaunchctl(
                named: "missing",
                printing: Fixture.missingLaunchctlAnswer,
                exiting: 113
            )
        )

        XCTAssertTrue(
            answer.output.contains("codes.threading.ptyd is not registered"),
            answer.output
        )
    }

    /// An answer this build cannot read is its own finding: "I could not tell" and "it is not
    /// there" would send somebody looking in two different places.
    func testStatusReportsAnUnreadableLaunchctlAnswerAsItsOwnFinding() throws {
        let helper = try helperURL()
        let daemon = try startDaemon(helper)
        let answer = try run(
            helper,
            ["status"] + daemon.locationArguments,
            launchctl: try fakeLaunchctl(named: "bad", printing: "Bad request.", exiting: 125)
        )

        XCTAssertTrue(
            answer.output.contains("could not be read from launchctl: Bad request."),
            answer.output
        )
    }

    // MARK: - sessions

    func testSessionsShowsASpawnedChildAsAttached() throws {
        let helper = try helperURL()
        let daemon = try startDaemon(helper)
        let identity = Self.identity(Fixture.firstIdentifier)
        let spawned = try spawn(on: daemon, id: identity, script: "sleep 30")

        let answer = try run(helper, ["sessions"] + daemon.locationArguments)
        XCTAssertEqual(answer.status, 0, answer.error)
        XCTAssertTrue(answer.output.contains("ID"), "the table has a header: \(answer.output)")

        let row = try XCTUnwrap(
            answer.output.split(separator: "\n").first { $0.contains(String(spawned.pid)) },
            "no row carried the child's pid: \(answer.output)"
        )
        XCTAssertTrue(
            row.contains(String(identity.description.prefix(8))),
            "the row leads with the short id: \(row)"
        )
        XCTAssertTrue(row.contains("pty"), "a terminal session names its channel: \(row)")
        XCTAssertTrue(row.contains("80x24"), "the grid is the one it was spawned with: \(row)")
        XCTAssertTrue(
            row.contains("attached"),
            "the spawning connection is still watching it: \(row)"
        )
        XCTAssertTrue(row.contains("sh"), "the executable's basename names what it is: \(row)")
    }

    /// The same answer, as something a script can read.
    func testSessionsPrintsJSONWithStableKeys() throws {
        let helper = try helperURL()
        let daemon = try startDaemon(helper)
        let identity = Self.identity(Fixture.firstIdentifier)
        let spawned = try spawn(on: daemon, id: identity, script: "sleep 30")

        let answer = try run(helper, ["sessions", "--json"] + daemon.locationArguments)
        XCTAssertEqual(answer.status, 0, answer.error)

        let parsed = try JSONSerialization.jsonObject(
            with: Data(answer.output.utf8)
        ) as? [[String: Any]]
        let objects = try XCTUnwrap(parsed, "the answer is an array of objects: \(answer.output)")
        XCTAssertEqual(objects.count, 1)
        let object = try XCTUnwrap(objects.first)
        XCTAssertEqual(object["id"] as? String, identity.description)
        XCTAssertEqual(object["pid"] as? Int, Int(spawned.pid))
        XCTAssertEqual(object["channel"] as? String, "pty")
        XCTAssertEqual(object["state"] as? String, "attached")
        XCTAssertEqual(object["attached"] as? Bool, true)
        XCTAssertEqual(object["cols"] as? Int, 80)
        XCTAssertTrue(object["exit"] is NSNull, "a running child has no exit status")
        XCTAssertNotNil(object["startedAt"] as? String, "the date is readable, not a reference")
    }

    func testSessionsSaysSoWhenTheDaemonHoldsNothing() throws {
        let helper = try helperURL()
        let daemon = try startDaemon(helper)
        let answer = try run(helper, ["sessions"] + daemon.locationArguments)

        XCTAssertEqual(answer.status, 0, answer.error)
        XCTAssertEqual(answer.output.trimmingCharacters(in: .whitespacesAndNewlines), "no sessions")
    }

    // MARK: - journal

    func testJournalAnswersNoMoreLinesThanWereAsked() throws {
        let helper = try helperURL()
        let daemon = try startDaemon(helper)
        _ = try spawn(on: daemon, id: Self.identity(Fixture.firstIdentifier), script: "sleep 30")

        let answer = try run(helper, ["journal", "5"] + daemon.locationArguments)
        XCTAssertEqual(answer.status, 0, answer.error)

        let lines = answer.output
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertFalse(lines.isEmpty, "the daemon has journalled its own start by now")
        XCTAssertLessThanOrEqual(lines.count, 5, "the ask is a bound: \(answer.output)")
        for line in lines {
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(line.utf8)),
                "the journal is one JSON object per line: \(line)"
            )
        }
    }

    // MARK: - stop

    func testStopEndsARunningChild() throws {
        let helper = try helperURL()
        let daemon = try startDaemon(helper)
        let identity = Self.identity(Fixture.firstIdentifier)
        let spawned = try spawn(on: daemon, id: identity, script: "sleep 300")
        XCTAssertEqual(Darwin.kill(spawned.pid, 0), 0, "the child is running before the stop")

        let answer = try run(
            helper,
            ["stop", String(identity.description.prefix(8))] + daemon.locationArguments
        )
        XCTAssertEqual(answer.status, 0, "the ending arrived: \(answer.error)")
        XCTAssertTrue(
            answer.output.contains("stopped") && answer.output.contains(String(spawned.pid)),
            "the tool says what it ended: \(answer.output)"
        )

        // The pid is the assertion rather than the frame: a tool that sent the right frames and
        // left the child running would pass every text check above.
        try waitUntil(timeout: Fixture.deathTimeout, "the child is gone") {
            Darwin.kill(spawned.pid, 0) != 0 && errno == ESRCH
        }
    }

    /// An ambiguous prefix is refused rather than resolved: the two sessions it reaches are two
    /// different people's turns.
    func testStopRefusesAnAmbiguousPrefix() throws {
        let helper = try helperURL()
        let daemon = try startDaemon(helper)
        let first = try spawn(
            on: daemon,
            id: Self.identity(Fixture.firstIdentifier),
            script: "sleep 300"
        )
        let second = try spawn(
            on: daemon,
            id: Self.identity(Fixture.secondIdentifier),
            script: "sleep 300"
        )

        let answer = try run(
            helper,
            ["stop", Fixture.sharedPrefix] + daemon.locationArguments
        )
        XCTAssertEqual(answer.status, 1)
        XCTAssertTrue(
            answer.error.contains("2 sessions start with \(Fixture.sharedPrefix)"),
            "the refusal counts them: \(answer.error)"
        )
        XCTAssertTrue(answer.output.isEmpty, "a refusal says nothing on standard output")
        XCTAssertEqual(Darwin.kill(first.pid, 0), 0, "neither child was picked")
        XCTAssertEqual(Darwin.kill(second.pid, 0), 0, "neither child was picked")
    }

    func testStopRefusesAnUnknownPrefix() throws {
        let helper = try helperURL()
        let daemon = try startDaemon(helper)
        _ = try spawn(on: daemon, id: Self.identity(Fixture.firstIdentifier), script: "sleep 300")

        let answer = try run(helper, ["stop", "ZZZZZZZZ"] + daemon.locationArguments)
        XCTAssertEqual(answer.status, 1)
        XCTAssertTrue(
            answer.error.contains("No session the background host holds starts with ZZZZZZZZ"),
            answer.error
        )
    }

    // MARK: - Usage

    func testAWordThatIsNotAVerbIsUsageAndExitsSixtyFour() throws {
        let helper = try helperURL()
        let answer = try run(helper, ["wibble"])

        XCTAssertEqual(answer.status, 64, "EX_USAGE")
        XCTAssertTrue(answer.error.contains("wibble is not a verb"), answer.error)
        XCTAssertTrue(answer.error.contains("usage: threading-ptyd"), answer.error)
        XCTAssertTrue(answer.output.isEmpty, "a refusal goes to standard error")
    }

    func testAnOptionOnTheWrongVerbIsUsage() throws {
        let helper = try helperURL()
        let answer = try run(helper, ["status", "--json"])

        XCTAssertEqual(answer.status, 64)
        XCTAssertTrue(answer.error.contains("only `sessions` prints JSON"), answer.error)
    }

    /// There is no follow mode, and the refusal says where to look instead.
    func testFollowIsRefusedAndNamesTheFile() throws {
        let helper = try helperURL()
        let answer = try run(helper, ["journal", "--follow"])

        XCTAssertEqual(answer.status, 64)
        XCTAssertTrue(answer.error.contains("there is no follow mode"), answer.error)
        XCTAssertTrue(
            answer.error.contains("status"),
            "the refusal points at the verb that prints the path: \(answer.error)"
        )
    }

    func testStopWithoutASessionIsUsage() throws {
        let helper = try helperURL()
        let answer = try run(helper, ["stop"])

        XCTAssertEqual(answer.status, 64)
        XCTAssertTrue(answer.error.contains("stop takes one session id prefix"), answer.error)
    }

    func testHelpIsNotAFailure() throws {
        let helper = try helperURL()
        let answer = try run(helper, ["--help"])

        XCTAssertEqual(answer.status, 0, "asking for help is not a mistake: \(answer.error)")
        XCTAssertTrue(
            answer.output.contains("usage: threading-ptyd"),
            "the usage leads: \(answer.output.debugDescription)"
        )
        XCTAssertTrue(
            answer.output.contains(PTYHostDefaultLocations.defaultLocationsArgument),
            "the daemon's own forms are in the same text: \(answer.output.debugDescription)"
        )
        // Not `isEmpty`: a coverage build's instrumentation writes its own line to standard error
        // when it cannot place `default.profraw`, and that is the harness talking rather than the
        // tool. What is asserted is that the tool itself said nothing there.
        XCTAssertFalse(
            answer.error.contains("threading-ptyd"),
            "help is printed for reading, not as a diagnostic: \(answer.error.debugDescription)"
        )
    }

    /// The verbs did not shadow the daemon's command line: a half-named pair is still `EX_USAGE`,
    /// and it is still the daemon's parser refusing it.
    func testTheDaemonCommandLineIsUnchanged() throws {
        let helper = try helperURL()
        let answer = try run(helper, ["--socket", directory.appendingPathComponent("x").path])

        XCTAssertEqual(answer.status, 64)
        XCTAssertTrue(answer.error.contains("usage: threading-ptyd"), answer.error)
    }

    // MARK: - Helpers

    private static func identity(_ uuid: String) -> PTYHostSessionIdentity {
        PTYHostSessionIdentity.agentSession(SessionID(UUID(uuidString: uuid)!))
    }

    private func helperURL() throws -> URL {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(Fixture.helperName, isDirectory: false)
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: url.path),
            "no \(Fixture.helperName) in this bundle — build the Threading target, which embeds "
                + "it through the Embed Extension Helpers phase, and run the hosted test target"
        )
        return url
    }

    @discardableResult
    private func startDaemon(_ helper: URL) throws -> CLIDaemon {
        let index = daemons.count
        let daemon = try CLIDaemon(
            helper: helper,
            socketPath: directory.appendingPathComponent("d\(index).sock").path,
            stateDirectory: directory.appendingPathComponent("s\(index)", isDirectory: true)
        )
        daemons.append(daemon)
        try daemon.waitUntilListening(timeout: Fixture.replyTimeout)
        return daemon
    }

    /// Puts a child in the daemon and leaves a watcher on it, so a row reads `attached`.
    ///
    /// Spawned over the wire rather than through the tool on purpose: the tool has no `spawn`
    /// verb and must not grow one. A session belongs to a conversation the app owns, and a child
    /// started from a shell would be one no surface could ever show.
    @discardableResult
    private func spawn(
        on daemon: CLIDaemon,
        id: PTYHostSessionIdentity,
        script: String
    ) throws -> PTYHostSpawned {
        let client = try CLIWireClient(socketPath: daemon.socketPath)
        wireClients.append(client)
        try client.greet(timeout: Fixture.replyTimeout)
        return try client.spawn(id: id, script: script, timeout: Fixture.replyTimeout)
    }

    /// Writes a stand-in for `launchctl` that replays one captured answer.
    private func fakeLaunchctl(
        named name: String,
        printing answer: String,
        exiting status: Int32
    ) throws -> String {
        let payload = directory.appendingPathComponent("launchctl-\(name).txt")
        try answer.write(to: payload, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("launchctl-\(name)")
        // Written to standard error, which is where launchd puts its refusal on some releases;
        // the tool reads both descriptors as one text for exactly that reason.
        try """
            #!/bin/sh
            cat "\(payload.path)" >&2
            exit \(status)
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        return script.path
    }

    /// Runs the helper as a client and collects everything the shell would see.
    ///
    /// Standard output and standard error go to files rather than pipes: two pipes read from one
    /// thread is a deadlock waiting for an answer larger than a pipe buffer, and a file has no
    /// such bound.
    private func run(
        _ helper: URL,
        _ arguments: [String],
        launchctl: String? = nil,
        timeout: TimeInterval = Fixture.commandTimeout
    ) throws -> CLIAnswer {
        let stamp = UInt32.random(in: 0..<0xFFFF_FFFF)
        let outURL = directory.appendingPathComponent("out-\(stamp)")
        let errURL = directory.appendingPathComponent("err-\(stamp)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.standardOutput = try FileHandle(forWritingTo: outURL)
        process.standardError = try FileHandle(forWritingTo: errURL)
        process.standardInput = FileHandle.nullDevice
        // Somewhere writable: the test host's own working directory is `/`, and a coverage build
        // that cannot place `default.profraw` says so on the child's standard error, which is
        // one of the things being asserted about.
        process.currentDirectoryURL = directory
        // Never the machine's own `launchctl`: the one registered label is the developer's.
        let launchctlProgram: String
        if let launchctl {
            launchctlProgram = launchctl
        } else {
            launchctlProgram = try fakeLaunchctl(
                named: "default-\(stamp)",
                printing: Fixture.missingLaunchctlAnswer,
                exiting: 113
            )
        }
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "THREADING_PTY_HOST_LAUNCHCTL": launchctlProgram
        ]
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("threading-ptyd \(arguments.joined(separator: " ")) never returned")
        }
        process.waitUntilExit()

        return CLIAnswer(
            status: process.terminationStatus,
            output: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
            error: (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        )
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

// MARK: - What the shell saw

private struct CLIAnswer {
    let status: Int32
    let output: String
    let error: String
}

// MARK: - Failure

private struct PTYHostCLITestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - The daemon under test

/// One `threading-ptyd` daemon on a scratch rendezvous, for the client to be pointed at.
///
/// A private fixture rather than a shared one, which is this directory's own convention:
/// `PTYHostDaemonTests` and `PTYHostSessionDaemonTests` each keep their own, because a fixture
/// shared across test files is a fixture every file has to agree about.
private final class CLIDaemon: @unchecked Sendable {

    // MARK: - Properties

    let socketPath: String
    let stateDirectory: URL

    private let process = Process()
    private let diagnostics = Pipe()
    private let lock = NSLock()
    private var collected = Data()

    /// What every client invocation has to be told to reach this daemon rather than the one the
    /// developer's own Threading may have running.
    var locationArguments: [String] {
        ["--socket", socketPath, "--state", stateDirectory.path]
    }

    // MARK: - Initialization

    init(helper: URL, socketPath: String, stateDirectory: URL) throws {
        self.socketPath = socketPath
        self.stateDirectory = stateDirectory

        process.executableURL = helper
        process.arguments = ["--socket", socketPath, "--state", stateDirectory.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = stateDirectory.deletingLastPathComponent()
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

    // MARK: - Public Methods

    /// Ready means *connectable*, not "the file is there".
    func waitUntilListening(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let probe = try? CLIWireClient(socketPath: socketPath) {
                probe.hangUp()
                return
            }
            if !process.isRunning {
                throw PTYHostCLITestFailure("the daemon exited before listening: \(diagnosticText)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw PTYHostCLITestFailure("the daemon never bound \(socketPath): \(diagnosticText)")
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

// MARK: - The wire client that puts children there

/// The smallest client that can greet a daemon and spawn a child, and then stay attached.
///
/// Deliberately not a second copy of `PTYHostDaemonTests`' full client: these tests need one
/// thing the tool cannot do for itself — put a session in the daemon — and a fixture that could
/// also resize, detach and read a byte stream would be a fixture with its own failure modes.
private final class CLIWireClient: @unchecked Sendable {

    // MARK: - Properties

    private let descriptor: Int32
    private let condition = NSCondition()
    private var decoder = PTYHostFrameDecoder()
    private var controls: [PTYHostFrame] = []
    private var closed = false

    private static let encoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()

    /// The environment a child is handed. Composed here rather than inherited, because that is
    /// the contract: the daemon adds nothing and removes nothing.
    private static let childEnvironment = [
        "TERM=xterm-256color",
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
        "LC_ALL=C"
    ]

    // MARK: - Initialization

    init(socketPath: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PTYHostCLITestFailure("socket() failed") }

        // Without this a write to a socket the daemon has already closed would raise `SIGPIPE`
        // in the *test host*, which is a crash rather than a failure.
        var suppress: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &suppress,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            Darwin.close(descriptor)
            throw PTYHostCLITestFailure("socket path is \(bytes.count) bytes, too long")
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
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw PTYHostCLITestFailure("connect() failed: \(String(cString: strerror(errno)))")
        }

        Thread.detachNewThread { [self] in read() }
    }

    // MARK: - Public Methods

    func greet(timeout: TimeInterval) throws {
        send(.hello(PTYHostHello(build: "test", pid: getpid())))
        _ = try nextControl(timeout: timeout) {
            if case .hello = $0 { return true }
            return false
        }
    }

    func spawn(
        id: PTYHostSessionIdentity,
        script: String,
        timeout: TimeInterval
    ) throws -> PTYHostSpawned {
        send(.spawn(PTYHostSpawnRequest(
            id: id,
            channel: .pty(grid: PTYHostGrid(cols: 80, rows: 24)),
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: Self.childEnvironment,
            cwd: NSTemporaryDirectory()
        )))
        let frame = try nextControl(timeout: timeout) {
            if case .spawned = $0 { return true }
            if case .spawnRefused = $0 { return true }
            return false
        }
        guard case .spawned(let body) = frame else {
            throw PTYHostCLITestFailure("the daemon refused the spawn: \(frame)")
        }
        return body
    }

    func hangUp() {
        condition.lock()
        let alreadyClosed = closed
        closed = true
        condition.broadcast()
        condition.unlock()
        guard !alreadyClosed else { return }
        _ = shutdown(descriptor, SHUT_RDWR)
    }

    // MARK: - Private Methods

    private func send(_ frame: PTYHostFrame) {
        guard let payload = try? Self.encoder.encode(frame),
              let framed = try? PTYHostFraming.encode(kind: .control, payload: payload) else {
            return
        }
        write(framed)
    }

    private func nextControl(
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
                throw PTYHostCLITestFailure("no matching control frame arrived; had \(controls)")
            }
        }
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            guard count > 0 else {
                condition.lock()
                closed = true
                condition.broadcast()
                condition.unlock()
                Darwin.close(descriptor)
                return
            }
            let incoming = Data(buffer[0..<count])
            condition.lock()
            switch decoder.accept(incoming) {
            case .frames(let frames):
                for frame in frames where frame.kind == .control {
                    if let control = try? Self.jsonDecoder.decode(
                        PTYHostFrame.self,
                        from: frame.payload
                    ) {
                        controls.append(control)
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
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
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
