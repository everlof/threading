import XCTest
@testable import Threading

/// The relay's half of "my iPhone never got a pairing code".
///
/// Every case here stands for a way the settings page sat on "Preparing your pairing code /
/// Connecting…" with no reason and no way out, while the relay itself was fine.
final class RemoteRelayReadinessTests: XCTestCase {

    // MARK: - Reading a running child's output

    /// The regression boundary for the bug itself. `FileHandle.read(upToCount:)` fills its count
    /// rather than returning what is there, so a child that prints a short burst and keeps
    /// running delivered nothing at all. With that primitive this test times out.
    func testDeliversAShortBurstWhileTheWriterIsStillOpen() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[1]) }

        let delivered = expectation(description: "the burst reaches the receiver")
        delivered.assertForOverFulfill = false
        let collected = CollectedOutput()
        let stream = ChildOutputStream(readEnd: descriptors[0]) { data in
            collected.append(data)
            delivered.fulfill()
        }
        defer { stream.cancel() }

        // Far less than any plausible read chunk, and nothing follows it: exactly the shape of a
        // quick Tunnel announcing its address and then going quiet.
        let burst = Data("a short banner line\n".utf8)
        burst.withUnsafeBytes { raw in
            XCTAssertEqual(write(descriptors[1], raw.baseAddress, raw.count), raw.count)
        }

        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(collected.text, "a short banner line\n")
    }

    /// The read itself, without a source or a child: what one wake-up made available, and never
    /// a wait for the buffer to fill.
    func testAReadReturnsOnlyWhatIsThere() {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }

        let burst = Data(repeating: 0x41, count: 100)
        burst.withUnsafeBytes { raw in
            XCTAssertEqual(write(descriptors[1], raw.baseAddress, raw.count), 100)
        }
        XCTAssertEqual(
            ChildOutputReader.read(descriptor: descriptors[0], maximumBytes: 16 * 1024),
            .read(burst)
        )
    }

    func testAClosedWriterReadsAsEndOfFile() {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]) }
        close(descriptors[1])

        XCTAssertEqual(ChildOutputReader.read(descriptor: descriptors[0]), .endOfFile)
    }

    /// A read error must not become an uncatchable Objective-C exception, which is what
    /// `FileHandle.availableData` does on a descriptor closed underneath it.
    func testABrokenDescriptorIsAReportedFailureRatherThanACrash() {
        XCTAssertEqual(ChildOutputReader.read(descriptor: -1), .failed(errno: EBADF))

        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        let reader = descriptors[0]
        close(descriptors[0])
        close(descriptors[1])
        XCTAssertEqual(ChildOutputReader.read(descriptor: reader), .failed(errno: EBADF))
    }

    /// A non-blocking descriptor with nothing on it is not end of file, and retiring the handler
    /// there would drop everything the child said afterwards.
    func testASpuriousWakeUpOnANonBlockingDescriptorIsNotEndOfFile() {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        XCTAssertNotEqual(fcntl(descriptors[0], F_SETFL, O_NONBLOCK), -1)

        XCTAssertEqual(ChildOutputReader.read(descriptor: descriptors[0]), .wouldBlock)
    }

    /// End of file is terminal. The stream ends there rather than waking forever on a descriptor
    /// that will never produce another byte, and closing is the cancel handler's job alone.
    func testClosesItsDescriptorOnceAtEndOfFile() {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        let reader = descriptors[0]
        let stream = ChildOutputStream(readEnd: reader) { _ in }

        close(descriptors[1])

        // The stream owns the descriptor: at end of file it cancels, and the cancel handler is
        // the one place that closes. Waiting for the descriptor to become invalid proves both.
        let closed = expectation(description: "the descriptor is released")
        closed.assertForOverFulfill = false
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            guard fcntl(reader, F_GETFD) == -1, errno == EBADF else { return }
            timer.invalidate()
            closed.fulfill()
        }
        RunLoop.current.add(poll, forMode: .common)
        wait(for: [closed], timeout: 3)
        poll.invalidate()

        // Idempotent, and never a second close of a number the kernel has since handed out.
        stream.cancel()
        stream.cancel()
    }

    // MARK: - Parsing the published address

    func testFindsTheAddressInAQuickTunnelBanner() {
        // The real shape of the output: box drawing around it, and log level prefixes.
        let banner = """
        2026-08-16T15:04:51Z INF Requesting new quick Tunnel on trycloudflare.com...
        2026-08-16T15:04:58Z INF +------------------------------------------------------+
        2026-08-16T15:04:58Z INF |  Your quick Tunnel has been created! Visit it at:     |
        2026-08-16T15:04:58Z INF |  https://followed-joke-prizes-newton.trycloudflare.com |
        2026-08-16T15:04:58Z INF +------------------------------------------------------+
        """
        XCTAssertEqual(
            RemoteTunnel.publicURL(in: banner),
            URL(string: "https://followed-joke-prizes-newton.trycloudflare.com")
        )
    }

    func testFindsNoAddressBeforeOneIsPublished() {
        let preamble = """
        2026-08-16T15:04:51Z ERR Configuration file /dev/null was empty
        2026-08-16T15:04:51Z INF Requesting new quick Tunnel on trycloudflare.com...
        """
        XCTAssertNil(RemoteTunnel.publicURL(in: preamble))
    }

    // MARK: - A relay that starts and never answers

    /// The state the app actually shipped in: a child alive and quiet, and a transport with no
    /// way out of `.starting`. It now ends as a reported failure with a code.
    @MainActor
    func testARelayThatNeverPublishesAnAddressTimesOut() async throws {
        let quiet = try QuietExecutable()
        defer { try? FileManager.default.removeItem(at: quiet.directory) }
        let tunnel = RemoteTunnel(
            childLedger: AgentChildLedger(url: quiet.directory.appendingPathComponent("ledger")),
            locateExecutable: { quiet.url },
            startupTimeout: .milliseconds(400)
        )
        defer { tunnel.stop() }

        let states = ObservedStates()
        tunnel.start(port: 65000) { states.append($0) }
        XCTAssertEqual(tunnel.state, .starting)

        // The child has to be up before its death can mean anything.
        try await waitUntil(within: .seconds(10)) { quiet.launchedProcessID != nil }
        let child = try XCTUnwrap(quiet.launchedProcessID)
        XCTAssertTrue(quiet.isRunning(child), "the stand-in relay should be alive to be killed")

        try await waitUntil(within: .seconds(10)) {
            if case .unavailable = tunnel.state { return true }
            return false
        }
        XCTAssertEqual(tunnel.lastFailure, .startupTimedOut)
        XCTAssertTrue(
            states.all.contains { if case .unavailable = $0 { return true } else { return false } },
            "the failure has to reach the coordinator, not only the transport"
        )

        // Fail closed: a relay we have stopped tracking must not be left publishing this Mac.
        try await waitUntil(within: .seconds(10)) { !quiet.isRunning(child) }
    }

    /// No child, no spawn, and still a code — the branch a machine without `cloudflared` takes.
    @MainActor
    func testAMissingRelayBinaryReportsItsOwnCode() {
        let tunnel = RemoteTunnel(locateExecutable: { nil })
        defer { tunnel.stop() }

        var reported: RemoteTransportState?
        tunnel.start(port: 65000) { reported = $0 }

        XCTAssertEqual(tunnel.lastFailure, .notInstalled)
        guard case .unavailable = reported else {
            return XCTFail("the missing binary has to be reported, not merely stored")
        }
    }

    // MARK: - Saying which way it failed

    /// The journal recorded `reason=unavailable` for every relay failure alike, because the
    /// reason was inferred from a localised sentence. These codes are what a report groups by.
    func testRelayFailuresCarryTheirOwnDiagnosticReason() {
        XCTAssertEqual(RemoteRelayFailure.notInstalled.diagnosticReason, "unavailable")
        XCTAssertEqual(RemoteRelayFailure.launchFailed.diagnosticReason, "unavailable")
        XCTAssertEqual(RemoteRelayFailure.startupTimedOut.diagnosticReason, "timeout")
        XCTAssertEqual(RemoteRelayFailure.exitedDuringStartup.diagnosticReason, "process-exited")
        XCTAssertEqual(RemoteRelayFailure.exitedAfterConnecting.diagnosticReason, "process-exited")
    }

    func testRelayFailureCodesAreStableTokens() {
        XCTAssertEqual(RemoteRelayFailure.startupTimedOut.rawValue, "startupTimedOut")
        XCTAssertEqual(RemoteRelayFailure.notInstalled.rawValue, "notInstalled")
    }

    // MARK: - What the pairing card says

    func testAConnectedTransportWithNoPayloadIsNotProgress() {
        // This is the state that shipped as a spinner: the connection is up, so nothing further
        // is coming, and "Preparing your pairing code" was a promise the card could not keep.
        XCTAssertEqual(
            RemotePairingCardState.resolve(
                ownerDevicePersistenceError: nil,
                pairingCodePayload: nil,
                transport: .connected(URL(string: "https://example.trycloudflare.com")!)
            ),
            .codeUnavailable
        )
    }

    func testOnlyAnUnfinishedConnectionShowsPreparing() {
        for transport in [RemoteTransportState.stopped, .starting] {
            XCTAssertEqual(
                RemotePairingCardState.resolve(
                    ownerDevicePersistenceError: nil,
                    pairingCodePayload: nil,
                    transport: transport
                ),
                .preparing,
                "\(transport) should still read as work in progress"
            )
        }
    }

    func testAPayloadWinsOverTheTransportState() {
        XCTAssertEqual(
            RemotePairingCardState.resolve(
                ownerDevicePersistenceError: nil,
                pairingCodePayload: "HTTPS://EXAMPLE.TRYCLOUDFLARE.COM/#TOKEN",
                transport: .starting
            ),
            .ready(payload: "HTTPS://EXAMPLE.TRYCLOUDFLARE.COM/#TOKEN")
        )
    }

    func testAnUnreadableKeychainWinsOverEverything() {
        XCTAssertEqual(
            RemotePairingCardState.resolve(
                ownerDevicePersistenceError: "keychain",
                pairingCodePayload: "HTTPS://EXAMPLE.TRYCLOUDFLARE.COM/#TOKEN",
                transport: .connected(URL(string: "https://example.trycloudflare.com")!)
            ),
            .keychainUnavailable
        )
    }

    func testAnUnavailableTransportOffersItsOwnRecovery() {
        XCTAssertEqual(
            RemotePairingCardState.resolve(
                ownerDevicePersistenceError: nil,
                pairingCodePayload: nil,
                transport: .unavailable("The secure relay did not answer in time.")
            ),
            .connectionUnavailable
        )
    }
}

private extension XCTestCase {
    /// Polls rather than sleeping a fixed amount, so a slow machine does not turn a passing
    /// deadline into a flake.
    func waitUntil(
        within limit: Duration,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let met = await condition()
        XCTAssertTrue(met, "condition was still false after \(limit)")
    }
}

/// A stand-in for a relay binary that launches, ignores its arguments, says nothing, and stays
/// alive — the exact shape that produced no output and no failure.
///
/// It reports its own pid before `exec`ing, because matching a command line does not survive the
/// `exec`: an earlier version of this fixture looked for the script's path in `ps` and so passed
/// whether or not the child was still running.
private struct QuietExecutable {
    let directory: URL
    let url: URL
    private let pidURL: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quiet-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("quiet-relay")
        pidURL = directory.appendingPathComponent("pid")
        try """
        #!/bin/sh
        printf '%s' "$$" > "\(pidURL.path)"
        exec sleep 120
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    /// The pid the child reported, once it has. `exec` keeps it, so this identifies the process
    /// that is actually holding the relay open.
    var launchedProcessID: pid_t? {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return value
    }

    /// Asked of the kernel rather than of the transport, so the assertion is about the machine
    /// and not about what the app believes. A reaped child answers ESRCH; an unreaped zombie
    /// still answers a signal check, so the process state decides.
    func isRunning(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        listing.arguments = ["-p", String(pid), "-o", "state="]
        let pipe = Pipe()
        listing.standardOutput = pipe
        listing.standardError = FileHandle.nullDevice
        guard (try? listing.run()) != nil else { return true }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        listing.waitUntilExit()
        let state = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !state.isEmpty && !state.hasPrefix("Z")
    }
}

/// The transport reports on the main actor; the assertions read the sequence afterwards.
@MainActor
private final class ObservedStates {
    private(set) var all: [RemoteTransportState] = []
    func append(_ state: RemoteTransportState) { all.append(state) }
}

/// Output arrives on Foundation's monitoring queue, not on the test's thread.
private final class CollectedOutput: @unchecked Sendable {
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
