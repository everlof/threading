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

    private func prepare(
        _ hosts: RemoteExecutionHosts,
        _ destination: RemoteHostDestination,
        binaries: URL
    ) throws -> RemoteHostLaunchContext {
        _ = hosts.readiness(for: destination, binaryDirectory: binaries)
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
