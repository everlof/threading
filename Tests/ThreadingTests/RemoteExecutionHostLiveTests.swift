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
