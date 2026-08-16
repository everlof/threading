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
    func testDeliversAShortBurstWhileTheWriterIsStillOpen() {
        let pipe = Pipe()
        defer { pipe.fileHandleForReading.readabilityHandler = nil }

        let delivered = expectation(description: "the burst reaches the receiver")
        delivered.assertForOverFulfill = false
        let collected = CollectedOutput()
        ChildOutputReader.deliver(from: pipe.fileHandleForReading) { data in
            collected.append(data)
            delivered.fulfill()
        }

        // Far less than any plausible read chunk, and nothing follows it: exactly the shape of a
        // quick Tunnel announcing its address and then going quiet.
        pipe.fileHandleForWriting.write(Data("a short banner line\n".utf8))

        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(collected.text, "a short banner line\n")
        try? pipe.fileHandleForWriting.close()
    }

    /// End of file is terminal, and the readability source keeps waking for a closed descriptor.
    /// Retiring the handler there is what keeps that from becoming a spin.
    func testRetiresTheHandlerAtEndOfFile() {
        let pipe = Pipe()
        let ended = expectation(description: "the handler retires itself")
        ChildOutputReader.deliver(from: pipe.fileHandleForReading) { _ in }

        try? pipe.fileHandleForWriting.close()

        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            guard pipe.fileHandleForReading.readabilityHandler == nil else { return }
            timer.invalidate()
            ended.fulfill()
        }
        RunLoop.current.add(poll, forMode: .common)
        wait(for: [ended], timeout: 3)
        poll.invalidate()
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
