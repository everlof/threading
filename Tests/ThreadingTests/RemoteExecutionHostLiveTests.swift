import CryptoKit
import Foundation
import ThreadingDomain
import ThreadingPTYHostKit
import XCTest
@testable import Threading

/// Remote execution hosts against a real Linux machine, end to end: facts, upload, unit, linger,
/// tunnel, `hello`, and a child spawned through the forwarded socket that reports it runs on the
/// host. Then a second preparation, which must find everything already in place.
///
/// Opt-in, because it needs a host and changes it: it installs `threading-ptyd` under
/// `~/.local/lib/threading`, writes a systemd user unit and enables lingering. Set, for example
/// against the Lima VM from the remote-session spike:
///
///     TEST_RUNNER_THREADING_REMOTE_HOST_DESTINATION=lima-ptyd-spike
///     TEST_RUNNER_THREADING_REMOTE_HOST_SSH_CONFIG=$HOME/.lima/ptyd-spike/ssh.config
///     TEST_RUNNER_THREADING_REMOTE_HOST_BINARIES=<repo>/build/linux
///
/// (`TEST_RUNNER_` is how `xcodebuild test` passes a variable into the test process.)
final class RemoteExecutionHostLiveTests: XCTestCase {

    private enum Key {
        static let destination = "THREADING_REMOTE_HOST_DESTINATION"
        static let sshConfig = "THREADING_REMOTE_HOST_SSH_CONFIG"
        static let binaries = "THREADING_REMOTE_HOST_BINARIES"
    }

    private enum Fixture {
        /// A first preparation uploads a ~57 MB binary.
        static let preparationTimeout: TimeInterval = 600
        static let childTimeout: TimeInterval = 20
        /// A real `claude` starting on the host, loading its hooks and spawning its MCP servers.
        static let agentTimeout: TimeInterval = 60
        /// A real turn: the model answering, and a tool call crossing back to this Mac.
        static let turnTimeout: TimeInterval = 180
    }

    func testPreparesAHostAndRunsAChildThereThroughTheTunnel() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment[Key.destination], let binaries = environment[Key.binaries] else {
            throw XCTSkip("set \(Key.destination) and \(Key.binaries) to run against a real host")
        }
        let destination = RemoteHostDestination(alias: alias, configFile: environment[Key.sshConfig])
        // A short socket directory: the hosted test's scratch root is too long for `sun_path`.
        let sockets = URL(fileURLWithPath: "/tmp/threading-rh-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sockets) }
        let hosts = RemoteExecutionHosts(localDirectory: sockets)
        defer { hosts.closeAllTunnels() }

        let context = try prepare(hosts, destination, binaries: URL(fileURLWithPath: binaries))
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.localSocketPath))
        XCTAssertNotNil(context.facts.architecture)
        // The facts the Remote Hosts page reads to say a machine is reachable but cannot yet run an
        // agent. Heuristics, so they are checked against a real host rather than trusted.
        XCTAssertNotNil(context.facts.curlPath, "no curl: this host's hooks could not report")
        XCTAssertNotNil(context.facts.claudePath, "the spike's VM has claude on its login PATH")
        XCTAssertEqual(context.facts.claudeSignedIn, true, "the spike's VM is signed in")

        let output = OutputCollector()
        let exited = PTYHostLatch<PTYHostExited>()
        let client = PTYHostClient(
            socketPath: context.localSocketPath,
            build: "remote-live-test",
            events: PTYHostClient.Events(
                frame: { frame in
                    if case .exited(let ending) = frame { exited.complete(ending) }
                },
                output: { output.append($0) }
            )
        )
        defer { client.close() }
        try client.connect()
        let identity = PTYHostSessionIdentity.agentSession(SessionID())
        try client.spawn(PTYHostSpawnRequest(
            id: identity,
            channel: .pty(grid: PTYHostGrid(cols: 80, rows: 24, xpixel: 0, ypixel: 0)),
            executable: context.facts.loginShell,
            arguments: ["-l", "-c", "printf 'HOST=%s HOME=%s\\n' \"$(uname -s)\" \"$HOME\"; exit 7"],
            environment: RemoteAgentLaunch.environment(for: context.facts)
        ))

        let ending = try XCTUnwrap(exited.wait(Fixture.childTimeout), "the remote child never exited")
        XCTAssertEqual(ending.status, 7)
        XCTAssertTrue(output.text.contains("HOST=Linux HOME=\(context.facts.home)"), output.text)

        // Everything is in place now, so a second preparation uploads nothing and starts nothing.
        let again = RemoteExecutionHosts(localDirectory: sockets)
        defer { again.closeAllTunnels() }
        hosts.closeAllTunnels()
        let second = try prepare(again, destination, binaries: URL(fileURLWithPath: binaries))
        XCTAssertTrue(second.facts.activeInstances.contains { !$0.isEmpty }, "this build's instance is active")
        XCTAssertEqual(
            Set(second.facts.activeInstances).count, second.facts.activeInstances.count,
            "no instance is listed twice"
        )
    }

    /// The durable half: a session keeps running on the host while no Mac is connected, the next
    /// preparation's survey finds it, and attaching hands back what it wrote meanwhile. Then a
    /// tunnel a crashed app would have left is ended by the next coordinator that opens one.
    func testASessionOutlivesEveryTunnelAndIsTakenBackAfterwards() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment[Key.destination], let binaries = environment[Key.binaries] else {
            throw XCTSkip("set \(Key.destination) and \(Key.binaries) to run against a real host")
        }
        let destination = RemoteHostDestination(alias: alias, configFile: environment[Key.sshConfig])
        let sockets = URL(fileURLWithPath: "/tmp/threading-rh-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sockets) }
        let binaryDirectory = URL(fileURLWithPath: binaries)

        // Launch, then quit: every tunnel closes and nothing detaches.
        let first = RemoteExecutionHosts(localDirectory: sockets)
        defer { first.closeAllTunnels() }
        let context = try prepare(first, destination, binaries: binaryDirectory)
        let identity = PTYHostSessionIdentity.agentSession(SessionID())
        let spawned = PTYHostLatch<PTYHostSpawned>()
        let starter = PTYHostClient(
            socketPath: context.localSocketPath,
            build: "remote-live-test",
            events: PTYHostClient.Events(frame: { frame in
                if case .spawned(let answer) = frame { spawned.complete(answer) }
            })
        )
        try starter.connect()
        try starter.spawn(PTYHostSpawnRequest(
            id: identity,
            channel: .pty(grid: PTYHostGrid(cols: 80, rows: 24, xpixel: 0, ypixel: 0)),
            executable: context.facts.loginShell,
            arguments: ["-l", "-c", "sleep 3; printf 'WROTE-WHILE-AWAY\\n'; sleep 60"],
            environment: RemoteAgentLaunch.environment(for: context.facts)
        ))
        // The host's answer, not a local flush: a flush reaches only this Mac's end of the tunnel.
        XCTAssertNotNil(spawned.wait(Fixture.childTimeout), "the host never answered the spawn")
        starter.close()
        first.closeAllTunnels()
        Thread.sleep(forTimeInterval: 5)

        // The next launch: prepared again, surveyed, and the session is still running there.
        let second = RemoteExecutionHosts(localDirectory: sockets)
        // Closed on every path out; the crash below is simulated by not closing it *before* `third`.
        defer { second.closeAllTunnels() }
        let later = try prepare(second, destination, binaries: binaryDirectory)
        let held = try XCTUnwrap(RemoteHostDaemonAdmin.sessions(socketPath: later.localSocketPath, build: "remote-live-test"))
        let running = try XCTUnwrap(held.first { $0.id == identity }, "the host no longer holds the session")
        XCTAssertNil(running.exit)

        let output = OutputCollector()
        let watcher = PTYHostClient(
            socketPath: later.localSocketPath,
            build: "remote-live-test",
            events: PTYHostClient.Events(output: { output.append($0) })
        )
        try watcher.connect()
        try watcher.attach(PTYHostAttach(id: identity, replayBudget: PTYHostReplayDefaults.minimumBudgetBytes))
        let deadline = Date().addingTimeInterval(Fixture.childTimeout)
        while Date() < deadline, !output.text.contains("WROTE-WHILE-AWAY") {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(output.text.contains("WROTE-WHILE-AWAY"), "the replay lost what the session wrote: \(output.text)")
        try watcher.kill(PTYHostKill(id: identity, escalate: true))
        _ = watcher.drainWrites(until: Date().addingTimeInterval(Fixture.childTimeout))
        watcher.close()

        // A crash: `second` never closes its tunnel. The next coordinator must end it.
        XCTAssertTrue(second.tunnelIsRunning(for: destination))
        let third = RemoteExecutionHosts(localDirectory: sockets)
        defer { third.closeAllTunnels() }
        _ = try prepare(third, destination, binaries: binaryDirectory)
        let ended = Date().addingTimeInterval(Fixture.childTimeout)
        while Date() < ended, second.tunnelIsRunning(for: destination) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(second.tunnelIsRunning(for: destination), "the stranded tunnel was left running")
        XCTAssertTrue(third.tunnelIsRunning(for: destination))
    }

    /// Slice 4's path back: the same tunnel forwards the host's rendezvous to a socket on this Mac,
    /// so a hook's `curl` on the host and the Linux bridge an agent spawns there both reach it. The
    /// listener here stands in for Threading's MCP server and answers every request with a
    /// handshake naming itself, which is what proves a reply made the whole round trip.
    func testHooksAndTheBridgeOnTheHostReachThisMacThroughTheTunnel() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment[Key.destination], let binaries = environment[Key.binaries] else {
            throw XCTSkip("set \(Key.destination) and \(Key.binaries) to run against a real host")
        }
        let destination = RemoteHostDestination(alias: alias, configFile: environment[Key.sshConfig])
        let sockets = URL(fileURLWithPath: "/tmp/threading-rh-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sockets) }
        try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true)
        let app = try FakeAppListener(path: sockets.appendingPathComponent("app.sock").path)
        defer { app.close() }

        let hosts = RemoteExecutionHosts(localDirectory: sockets)
        defer { hosts.closeAllTunnels() }
        let context = try prepare(hosts, destination, binaries: URL(fileURLWithPath: binaries), appSocketPath: app.path)
        let route = try XCTUnwrap(context.toolRoute, "no route back was prepared")
        let bridge = try XCTUnwrap(route.bridgePath, "no bridge was installed; build it with scripts/test-ptyd-linux.sh")
        XCTAssertNotNil(context.facts.curlPath, "the host has no curl, so its hooks cannot report")

        let runner = SystemSSHCommandRunner()
        let hook = try runner.run(
            on: destination,
            command: "curl -s --max-time 10 --unix-socket \(route.socketPath) -H 'Content-Type: application/json' "
                + "--data-binary '{}' 'http://localhost/hooks/lifecycle/live-test?event=stop'",
            input: .none,
            extraOptions: [],
            timeout: Fixture.childTimeout
        )
        XCTAssertTrue(hook.succeeded, hook.output)
        XCTAssertTrue(hook.output.contains(FakeAppListener.serverName), "the hook's reply did not come back: \(hook.output)")
        XCTAssertTrue(app.requestLines.contains { $0.hasPrefix("POST /hooks/lifecycle/live-test") }, "\(app.requestLines)")

        let handshake = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
        let spoke = try runner.run(
            on: destination,
            command: "timeout 20 \(bridge) --socket \(route.socketPath) --token live-test --cache \(route.cacheDirectory)/live-test.json",
            input: .data(Data((handshake + "\n").utf8)),
            extraOptions: [],
            timeout: Fixture.childTimeout + 10
        )
        XCTAssertTrue(spoke.output.contains(FakeAppListener.serverName), "the bridge did not relay this Mac's answer: \(spoke.output)")
        XCTAssertTrue(app.requestLines.contains { $0.hasPrefix("POST /mcp/live-test") }, "\(app.requestLines)")
    }

    /// The whole of slice 4 with the real agent: the launch `RemoteAgentLaunch` composes, spawned
    /// through the daemon, starts the host's `claude`, whose `SessionStart` hook and whose MCP
    /// bridge both reach this Mac through the reverse forward, addressed by the session's token.
    ///
    /// Uses the host's signed-in Claude in `~/remote-test`, a folder it already trusts, and sends
    /// no prompt, so it spends nothing.
    @MainActor
    func testARealRemoteClaudeReportsItsStartAndReachesThreadingsTools() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment[Key.destination], let binaries = environment[Key.binaries] else {
            throw XCTSkip("set \(Key.destination) and \(Key.binaries) to run against a real host")
        }
        let destination = RemoteHostDestination(alias: alias, configFile: environment[Key.sshConfig])
        let sockets = URL(fileURLWithPath: "/tmp/threading-rh-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sockets) }
        try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true)
        let app = try FakeAppListener(path: sockets.appendingPathComponent("app.sock").path)
        defer { app.close() }

        let hosts = RemoteExecutionHosts(localDirectory: sockets)
        defer { hosts.closeAllTunnels() }
        let context = try prepare(hosts, destination, binaries: URL(fileURLWithPath: binaries), appSocketPath: app.path)

        let session = AgentSession(kind: .claude, title: "live hooks")
        let host = ProjectExecutionHost(destination: alias, remoteDirectory: "\(context.facts.home)/remote-test")
        let launch = try RemoteAgentLaunch.make(
            for: session,
            in: Project(name: "live", folderURL: URL(fileURLWithPath: "/tmp/live")),
            host: host,
            context: context,
            initialPrompt: nil,
            reportsLifecycle: true,
            allowedTools: ["set_session_name"]
        ).encode()
        let token = MCPSessionRegistry.token(for: session.id)

        let client = PTYHostClient(socketPath: context.localSocketPath, build: "remote-live-test",
                                   events: PTYHostClient.Events())
        defer { client.close() }
        try client.connect()
        let identity = PTYHostSessionIdentity.agentSession(session.id)
        try client.spawn(PTYHostSpawnRequest(
            id: identity,
            channel: .pty(grid: PTYHostGrid(cols: 120, rows: 40, xpixel: 0, ypixel: 0)),
            executable: launch.plan.executable,
            arguments: launch.plan.arguments,
            environment: launch.environment
        ))
        defer {
            try? client.kill(PTYHostKill(id: identity, escalate: true))
            _ = client.drainWrites(until: Date().addingTimeInterval(Fixture.childTimeout))
        }

        let started = "POST /lifecycle/\(token)?event=\(HookLifecycleEvent.sessionStarted.rawValue)"
        let tools = "POST /mcp/\(token)"
        let deadline = Date().addingTimeInterval(Fixture.agentTimeout)
        while Date() < deadline {
            let lines = app.requestLines
            if lines.contains(where: { $0.hasPrefix(started) }), lines.contains(where: { $0.hasPrefix(tools) }) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(app.requestLines.contains { $0.hasPrefix(started) }, "no SessionStart hook arrived: \(app.requestLines)")
        XCTAssertTrue(app.requestLines.contains { $0.hasPrefix(tools) }, "the bridge never reached Threading: \(app.requestLines)")
    }

    /// The point of the slice, with a real agent: Claude on the host is asked to use a Threading
    /// tool, and the call arrives on this Mac — through the bridge it spawned there, the socket
    /// forwarded back over the tunnel, addressed by this session's token.
    ///
    /// Spends one small turn on the host's own login.
    @MainActor
    func testARealRemoteClaudeCallsAThreadingToolOnThisMac() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment[Key.destination], let binaries = environment[Key.binaries] else {
            throw XCTSkip("set \(Key.destination) and \(Key.binaries) to run against a real host")
        }
        let destination = RemoteHostDestination(alias: alias, configFile: environment[Key.sshConfig])
        let sockets = URL(fileURLWithPath: "/tmp/threading-rh-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sockets) }
        try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true)
        let app = try FakeAppListener(path: sockets.appendingPathComponent("app.sock").path)
        defer { app.close() }

        let hosts = RemoteExecutionHosts(localDirectory: sockets)
        defer { hosts.closeAllTunnels() }
        let context = try prepare(hosts, destination, binaries: URL(fileURLWithPath: binaries), appSocketPath: app.path)

        let session = AgentSession(kind: .claude, title: "live tool call")
        let launch = try RemoteAgentLaunch.make(
            for: session,
            in: Project(name: "live", folderURL: URL(fileURLWithPath: "/tmp/live")),
            host: ProjectExecutionHost(destination: alias, remoteDirectory: "\(context.facts.home)/remote-test"),
            context: context,
            initialPrompt: "Call the \(MCPDefaults.allowedToolName(FakeAppListener.toolName)) tool "
                + "with name TRYIT, then reply with just DONE. Do nothing else.",
            reportsLifecycle: true,
            allowedTools: [FakeAppListener.toolName]
        ).encode()

        let output = OutputCollector()
        let client = PTYHostClient(
            socketPath: context.localSocketPath,
            build: "remote-live-test",
            events: PTYHostClient.Events(output: { output.append($0) })
        )
        defer { client.close() }
        try client.connect()
        let identity = PTYHostSessionIdentity.agentSession(session.id)
        try client.spawn(PTYHostSpawnRequest(
            id: identity,
            channel: .pty(grid: PTYHostGrid(cols: 120, rows: 40, xpixel: 0, ypixel: 0)),
            executable: launch.plan.executable,
            arguments: launch.plan.arguments,
            environment: launch.environment
        ))
        defer {
            try? client.kill(PTYHostKill(id: identity, escalate: true))
            _ = client.drainWrites(until: Date().addingTimeInterval(Fixture.childTimeout))
        }

        let deadline = Date().addingTimeInterval(Fixture.turnTimeout)
        while Date() < deadline, app.toolCalls.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let call = try XCTUnwrap(app.toolCalls.first, "no tool call arrived; the agent's screen was:\n\(output.text)")
        XCTAssertEqual(call.name, FakeAppListener.toolName)
        XCTAssertTrue(call.arguments.contains("TRYIT"), call.arguments)
    }

    /// What someone who is not the developer gets: no local build directory at all. The host is
    /// prepared from the components this build publishes — downloaded from the release, verified
    /// against the manifest compiled in, cached — and answers `hello` with them.
    func testPreparesAHostFromThePublishedComponentsAlone() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment[Key.destination] else {
            throw XCTSkip("set \(Key.destination) to run against a real host")
        }
        guard RemoteHostComponentSource.hasPublishedComponents else {
            throw XCTSkip("this build publishes no Linux components")
        }
        let destination = RemoteHostDestination(alias: alias, configFile: environment[Key.sshConfig])
        let sockets = URL(fileURLWithPath: "/tmp/threading-rh-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sockets) }
        let cache = sockets.appendingPathComponent("components", isDirectory: true)
        let components = RemoteHostPublishedComponents(root: cache)

        let hosts = RemoteExecutionHosts(localDirectory: sockets)
        defer { hosts.closeAllTunnels() }
        _ = hosts.readiness(for: destination, components: components)
        let deadline = Date().addingTimeInterval(Fixture.preparationTimeout)
        var context: RemoteHostLaunchContext?
        while Date() < deadline, context == nil {
            switch hosts.phase(for: destination) {
            case .ready(let ready): context = ready
            case .failed(let failure):
                XCTFail("preparation failed: \(failure.token): \(failure.detail)")
                throw failure
            case .idle, .preparing: Thread.sleep(forTimeInterval: 0.5)
            }
        }
        let ready = try XCTUnwrap(context, "preparation did not settle")
        let architecture = try XCTUnwrap(ready.facts.architecture)
        let daemon = try XCTUnwrap(RemoteHostComponentManifest.component(.daemon, for: architecture))
        XCTAssertNotNil(components.cachedURL(for: daemon), "the published daemon was not downloaded and kept")
        XCTAssertEqual(PTYHostClient.probe(socketPath: ready.localSocketPath, build: "remote-live-test"), .ready)
    }

    /// A real transcript on the host, mirrored here over `ssh` in deliberately small rounds, comes
    /// out byte for byte what the host holds — the property every reader on this Mac relies on.
    func testARealTranscriptIsMirroredByteForByte() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment[Key.destination] else {
            throw XCTSkip("set \(Key.destination) to run against a real host")
        }
        let destination = RemoteHostDestination(alias: alias, configFile: environment[Key.sshConfig])
        let runner = SystemSSHCommandRunner()
        let newest = try runner.run(
            on: destination,
            command: "ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -n 1",
            input: .none, extraOptions: [], timeout: Fixture.childTimeout
        )
        let remotePath = newest.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remotePath.hasSuffix(".jsonl") else { throw XCTSkip("the host holds no Claude transcript") }

        let root = URL(fileURLWithPath: "/tmp/threading-mirror-live-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Small rounds, so a transcript of a few hundred kilobytes takes several and the offsets
        // between them are exercised against real bytes.
        let mirror = RemoteTranscriptMirror(root: root, chunkBytes: 32 * 1024, maximumRounds: 64)
        let location = RemoteTranscriptLocation(
            destination: destination,
            remotePath: remotePath,
            localURL: mirror.localURL(destination: destination, transcriptID: TranscriptID("live"))
        )
        guard case .advanced = mirror.synchronize(location) else { return XCTFail("nothing was mirrored") }
        XCTAssertEqual(mirror.synchronize(location), .unchanged)

        let digest = try runner.run(
            on: destination,
            command: "sha256sum \(ShellCommand(word: remotePath).source) | cut -d' ' -f1",
            input: .none, extraOptions: [], timeout: Fixture.childTimeout
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = try Data(contentsOf: location.localURL)
        let remoteSize = try runner.run(
            on: destination,
            command: "wc -c < \(ShellCommand(word: remotePath).source)",
            input: .none, extraOptions: [], timeout: Fixture.childTimeout
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sizes first: a mirror that stops short (it once did, at a line longer than a read) says
        // so plainly rather than as two unequal digests.
        XCTAssertEqual(String(local.count), remoteSize, "the mirror stopped short of the host's file")
        let localDigest = SHA256.hash(data: local).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(localDigest, digest, "the mirror is not the host's file")
    }

    /// A remote checkout's uncommitted changes, read over the real `ssh` path in one round trip.
    /// Uses `~/threading-git-test` on the host — 200 committed files, 20 of them changed and one
    /// untracked — and skips when the host has no such repository.
    @MainActor
    func testARemoteCheckoutsUncommittedChangesAreReadInOneRoundTrip() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment[Key.destination] else {
            throw XCTSkip("set \(Key.destination) to run against a real host")
        }
        let destination = RemoteHostDestination(alias: alias, configFile: environment[Key.sshConfig])
        let home = try SystemSSHCommandRunner().run(
            on: destination, command: "printf %s \"$HOME\"", input: .none, extraOptions: [],
            timeout: Fixture.childTimeout
        ).output
        let answered = expectation(description: "the host answered")
        var outcome: RemoteGitReviewOutcome?
        let started = Date()
        RemoteGitReviewReader.shared.uncommitted(
            destination: destination,
            remoteDirectory: "\(home)/threading-git-test"
        ) { result in
            outcome = result
            answered.fulfill()
        }
        wait(for: [answered], timeout: Fixture.childTimeout)
        let elapsed = Date().timeIntervalSince(started)
        switch outcome {
        case .notRepository?, .missingDirectory?:
            throw XCTSkip("the host has no ~/threading-git-test repository")
        case .diffs(let branch, let files, let truncated)?:
            XCTAssertNotNil(branch)
            XCTAssertFalse(truncated)
            XCTAssertEqual(files.count, 21, "\(files.map(\.path))")
            XCTAssertTrue(files.contains { $0.path == "untracked.txt" })
            XCTAssertLessThan(elapsed, 5, "one round trip took \(elapsed) s")
        default:
            XCTFail("unexpected answer: \(String(describing: outcome))")
        }
    }

    private func prepare(
        _ hosts: RemoteExecutionHosts,
        _ destination: RemoteHostDestination,
        binaries: URL,
        appSocketPath: String? = nil
    ) throws -> RemoteHostLaunchContext {
        _ = hosts.readiness(
            for: destination,
            components: RemoteHostDirectoryComponents(directory: binaries),
            appSocketPath: appSocketPath
        )
        let deadline = Date().addingTimeInterval(Fixture.preparationTimeout)
        while Date() < deadline {
            switch hosts.phase(for: destination) {
            case .ready(let context):
                return context
            case .failed(let failure):
                XCTFail("preparation failed: \(failure.token): \(failure.detail)")
                throw failure
            case .idle, .preparing:
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        throw RemoteHostFailure(token: "testTimeout", detail: "preparation did not settle")
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A unix-socket HTTP listener standing in for Threading's MCP server: it records each request line,
/// answers the handshake and `tools/list` as the app would, and records every tool call an agent
/// makes. Enough of the server for a real agent on a host to find a tool and use it.
private final class FakeAppListener: @unchecked Sendable {
    static let serverName = "threading-live-test-listener"
    /// The one tool it offers, spelled as the app spells it.
    static let toolName = MCPBuiltInTool.setSessionName.rawValue

    let path: String
    private let descriptor: Int32
    private let lock = NSLock()
    private var lines: [String] = []
    private var calls: [(name: String, arguments: String)] = []

    var requestLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    var toolCalls: [(name: String, arguments: String)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    init(path: String) throws {
        self.path = path
        unlink(path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func close() {
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else { return }
            Thread.detachNewThread { [weak self] in self?.serve(connection) }
        }
    }

    private func serve(_ connection: Int32) {
        defer { Darwin.close(connection) }
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var body = Data()
        while true {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(contentsOf: buffer[0..<count])
            guard let end = request.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: request[..<end.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            if request.count - end.upperBound < length { continue }
            body = request[end.upperBound...].prefix(length)
            lock.lock()
            lines.append(String(head.split(separator: "\r\n").first ?? ""))
            lock.unlock()
            break
        }
        send(answer(to: body), to: connection)
    }

    /// The app's half of the conversation, in miniature: a handshake, one tool, and a result for
    /// every call of it. Anything else — a hook's report, a notification — is simply accepted.
    private func answer(to body: Data) -> String {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = message["method"] as? String else {
            return response(status: "200 OK", body: "{}")
        }
        guard let id = message["id"] else { return response(status: "202 Accepted", body: "") }

        let result: String
        switch method {
        case "initialize":
            result = #"{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true}},"#
                + #""serverInfo":{"name":"\#(Self.serverName)","version":"0"},"#
                + #""instructions":"This is a live test stand-in for Threading."}"#
        case "tools/list":
            result = #"{"tools":[{"name":"\#(Self.toolName)","description":"Rename this chat.",""#
                + #"inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}]}"#
        case "tools/call":
            let parameters = message["params"] as? [String: Any]
            let name = parameters?["name"] as? String ?? ""
            let arguments = (parameters?["arguments"]).flatMap {
                (try? JSONSerialization.data(withJSONObject: $0)).map { String(decoding: $0, as: UTF8.self) }
            } ?? ""
            lock.lock()
            calls.append((name: name, arguments: arguments))
            lock.unlock()
            result = #"{"content":[{"type":"text","text":"Renamed."}],"isError":false}"#
        default:
            result = "{}"
        }
        let identifier = (id as? Int).map(String.init) ?? #""\#(id)""#
        return response(status: "200 OK", body: #"{"jsonrpc":"2.0","id":\#(identifier),"result":\#(result)}"#)
    }

    private func response(status: String, body: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private func send(_ text: String, to connection: Int32) {
        _ = text.withCString { Darwin.write(connection, $0, strlen($0)) }
    }
}
