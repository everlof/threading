import XCTest
@testable import Threading

/// "My iPhone never got a pairing code", and everything the app could not say about it.
///
/// Every case here stands for a way the settings page sat on "Preparing your pairing code /
/// Connecting…" with no reason and no way out, while the way in itself was fine. The reading half
/// is here too: a child that prints a short burst and keeps running is what the pairing card was
/// waiting on, and it is now `tailscale serve` rather than the relay that produced it.
final class RemoteDoorReadinessTests: XCTestCase {

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
        // CLI announcing its address and then going quiet.
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

    // MARK: - What the pairing card says

    /// A way in that is answering, with no payload built from it, is the state that shipped as a
    /// spinner: nothing further is coming, and "Preparing your pairing code" was a promise the
    /// card could not keep.
    func testAWayInThatIsAnsweringWithNoPayloadIsNotProgress() {
        XCTAssertEqual(
            RemotePairingCardState.resolve(
                ownerDevicePersistenceError: nil,
                pairingCodePayload: nil,
                wayIn: .thisNetwork(
                    isEnabled: true,
                    state: .bound([Self.lanBinding]),
                    firewall: .unknown
                )
            ),
            .codeUnavailable
        )
    }

    /// Only a way in that is still coming up reads as work in progress, and it says what it is
    /// waiting for rather than promising a code "as soon as the selected connection is ready".
    func testOnlyAnUnfinishedWayInShowsPreparingAndSaysWhatItIsWaitingFor() {
        let binding = RemotePairingCardState.resolve(
            ownerDevicePersistenceError: nil,
            pairingCodePayload: nil,
            wayIn: .tailscale(isEnabled: true, state: .binding, facts: .unknown)
        )
        XCTAssertEqual(binding, .preparing(detail: "Binding to this Mac’s tailnet address…"))

        XCTAssertEqual(
            RemotePairingCardState.resolve(
                ownerDevicePersistenceError: nil,
                pairingCodePayload: nil,
                wayIn: nil
            ),
            .preparing(detail: nil),
            "a page told about no way in at all is a wait, not an answer"
        )
    }

    /// The transport observes the command it is running and nothing else, so the states that
    /// are not a step on the way to Serve publishing say nothing rather than guessing.
    func testOnlyAnInFlightCommandProducesAStartupStatement() throws {
        XCTAssertNil(TailscaleReadiness.notChecked.startupStatement)
        XCTAssertNil(TailscaleReadiness.ready(URL(string: "https://mac.ts.net:8443/")!).startupStatement)
        XCTAssertNil(
            TailscaleReadiness.actionRequired(.serveNotEnabled, actionURL: nil).startupStatement
        )
        XCTAssertEqual(
            TailscaleReadiness.checking.startupStatement?.title,
            "Checking Tailscale"
        )
        XCTAssertEqual(
            TailscaleReadiness.publishing.startupStatement?.title,
            "Publishing on your tailnet"
        )
    }

    func testAPayloadWinsOverTheWayInState() {
        XCTAssertEqual(
            RemotePairingCardState.resolve(
                ownerDevicePersistenceError: nil,
                pairingCodePayload: "HTTPS://192.168.1.42:8760/#TOKEN",
                wayIn: .tailscale(isEnabled: true, state: .binding, facts: .unknown)
            ),
            .ready(payload: "HTTPS://192.168.1.42:8760/#TOKEN")
        )
    }

    func testAnUnreadableKeychainWinsOverEverything() {
        XCTAssertEqual(
            RemotePairingCardState.resolve(
                ownerDevicePersistenceError: "keychain",
                pairingCodePayload: "HTTPS://192.168.1.42:8760/#TOKEN",
                wayIn: .thisNetwork(
                    isEnabled: true,
                    state: .bound([Self.lanBinding]),
                    firewall: .unknown
                )
            ),
            .keychainUnavailable
        )
    }

    /// A code cannot exist and nothing else can be said: the card carries the way in's own
    /// sentence, which already holds the fact and its remedy.
    func testAFailingWayInCarriesItsOwnReasonAndRemedy() {
        XCTAssertEqual(
            RemotePairingCardState.resolve(
                ownerDevicePersistenceError: nil,
                pairingCodePayload: nil,
                wayIn: .tailscale(
                    isEnabled: true,
                    state: .notReachable(.tailscaleNotConnected),
                    facts: TailscaleHostFacts(state: .notInstalled, magicDNSName: nil)
                )
            ),
            .connectionUnavailable(
                reason: "Not currently reachable: Tailscale is not installed on this Mac. "
                    + "Install Tailscale and sign in on this Mac. The door comes back on its own."
            ),
            "the panel does not say which way in failed or what fixes it"
        )
    }

    /// The card speaks for the way in closest to carrying a code, not for the first one drawn.
    /// A network door still binding says more than a tailnet door that is off.
    func testTheCardSpeaksForTheWayInClosestToACode() throws {
        let off = RemoteDoorStatus.tailscale(isEnabled: false, state: .off, facts: .unknown)
        let failing = RemoteDoorStatus.thisNetwork(
            isEnabled: true,
            state: .notReachable(.noInterface),
            firewall: .unknown
        )
        let working = RemoteDoorStatus.tailscale(isEnabled: true, state: .binding, facts: .unknown)
        let ready = RemoteDoorStatus.thisNetwork(
            isEnabled: true,
            state: .bound([Self.lanBinding]),
            firewall: .unknown
        )

        XCTAssertEqual(RemotePairingCardState.mostAdvanced(of: [off, failing]), failing)
        XCTAssertEqual(RemotePairingCardState.mostAdvanced(of: [off, failing, working]), working)
        XCTAssertEqual(
            RemotePairingCardState.mostAdvanced(of: [off, failing, working, ready]),
            ready
        )
        XCTAssertNil(RemotePairingCardState.mostAdvanced(of: []))
    }

    /// Nothing switched on is a dead end with a fact in it rather than a wait.
    func testNoWayInIsNotAWait() {
        XCTAssertEqual(
            RemotePairingCardState.resolve(
                ownerDevicePersistenceError: nil,
                pairingCodePayload: nil,
                wayIn: .remoteAccessOff(),
                hasWayIn: false
            ),
            .noWayIn
        )
    }

    // MARK: - Serve carries its own reason and its own fix

    /// The bug this exists for: the page showed "Private connection unavailable" while the only
    /// explanation it had sat in a readiness row three rows above it. Serve is a sub-option now,
    /// so the sentence and the button belong to its row — but they still have to be there.
    func testEveryServeIssueReachesItsRowWithAReasonAndAFix() throws {
        let approval = try XCTUnwrap(URL(string: "https://login.tailscale.com/f/serve?node=abc"))
        for issue in [
            TailscaleReadinessIssue.notInstalled,
            .signedOut,
            .stopped,
            .statusUnavailable,
            .serveNotEnabled,
            .httpsRequired,
            .permissionDenied,
            .portInUse,
            .serveFailed
        ] {
            let readiness = TailscaleReadiness.actionRequired(issue, actionURL: approval)
            let status = RemoteDoorStatus.tailscaleServe(
                isEnabled: true,
                transport: .unavailable(issue.message),
                readiness: readiness
            )
            XCTAssertEqual(status.text, issue.failureStatement, "\(issue) does not state what failed")
            XCTAssertEqual(status.hint, issue.remedyStatement, "\(issue) does not state the fix")
            XCTAssertEqual(status.tone, .attention, "\(issue)")
            XCTAssertEqual(
                RemoteDoorStatus.serveRemedy(readiness)?.title,
                issue.remedyActionTitle,
                "\(issue) offered a button the model does not name"
            )
        }
    }

    /// A remedy is a title *and* a page. An issue with no page to open offers no button rather
    /// than one that goes nowhere.
    func testAServeIssueWithNoPageToOpenOffersNoButton() {
        XCTAssertNil(
            RemoteDoorStatus.serveRemedy(.actionRequired(.serveNotEnabled, actionURL: nil))
        )
        XCTAssertNil(RemoteDoorStatus.serveRemedy(.publishing))
    }

    /// Serve publishing says where, and Serve switched off says what a browser gets instead.
    func testServeStatesWhereItIsServingAndWhatItsAbsenceCosts() throws {
        let origin = try XCTUnwrap(URL(string: "https://mac-studio.tail1234.ts.net:8443/"))
        let serving = RemoteDoorStatus.tailscaleServe(
            isEnabled: true,
            transport: .connected(origin),
            readiness: .ready(origin)
        )
        XCTAssertEqual(serving.text, "Serving at https://mac-studio.tail1234.ts.net:8443")
        XCTAssertEqual(serving.tone, .ready)

        let off = RemoteDoorStatus.tailscaleServe(
            isEnabled: false,
            transport: .stopped,
            readiness: .notChecked
        )
        XCTAssertEqual(off.text, "Off. A browser on your tailnet gets a certificate warning.")
        XCTAssertEqual(off.tone, .off)
    }

    /// The readiness rows and the panel read the same value, which is what stops a reason from
    /// existing in one and not the other.
    func testEveryIssueNamesTheReadinessRowItBelongsTo() {
        XCTAssertEqual(TailscaleReadinessIssue.notInstalled.step, .installed)
        XCTAssertEqual(TailscaleReadinessIssue.signedOut.step, .signedIn)
        XCTAssertEqual(TailscaleReadinessIssue.stopped.step, .signedIn)
        XCTAssertEqual(TailscaleReadinessIssue.statusUnavailable.step, .signedIn)
        // Serve's failures are not rows on a card about the door: the door does not go through
        // Serve any more, and a row saying "Enable HTTPS certificates" beside a bound tailnet
        // address would be describing a browser convenience as a way in.
        for issue in [
            TailscaleReadinessIssue.serveNotEnabled,
            .httpsRequired,
            .permissionDenied,
            .portInUse,
            .serveFailed
        ] {
            XCTAssertNil(issue.step, "\(issue) claims a row on the door's readiness card")
        }
    }

    // MARK: - The tailnet way in's readiness card

    /// A bound door is proof of both CLI facts, whatever the probe managed to say. An address in
    /// `100.64.0.0/10` on a `utun` exists only because `tailscaled` is installed, signed in and
    /// running, so the listener outranks the probe rather than the other way round.
    func testABoundTailnetProvesTheFactsTheProbeCouldNotRead() {
        let state = RemoteAccessDoorState.bound([Self.tailnetBinding])
        let card = RemoteTailnetReadinessPresentation.resolve(
            isEnabled: true,
            facts: .unknown,
            doorState: state,
            doorStatus: .tailscale(isEnabled: true, state: state, facts: .unknown)
        )

        XCTAssertEqual(card.row(.installed)?.mark, .met)
        XCTAssertEqual(card.row(.signedIn)?.mark, .met)
        XCTAssertEqual(card.row(.tailnetAddress)?.mark, .met)
        XCTAssertEqual(
            card.row(.tailnetAddress)?.detail,
            "Reachable at 100.65.47.126:8760.",
            "the row does not name the address the listener took"
        )
    }

    /// The failing row is the one to act on, and the rows below it wait rather than repeating
    /// the same failure in three different spellings.
    func testACLIFactMarksItsOwnRowAndLeavesTheRestWaiting() {
        let state = RemoteAccessDoorState.notReachable(.tailscaleNotConnected)
        func card(_ facts: TailscaleHostFacts) -> RemoteTailnetReadinessPresentation {
            .resolve(
                isEnabled: true,
                facts: facts,
                doorState: state,
                doorStatus: .tailscale(isEnabled: true, state: state, facts: facts)
            )
        }

        let notInstalled = card(TailscaleHostFacts(state: .notInstalled, magicDNSName: nil))
        XCTAssertEqual(notInstalled.row(.installed)?.mark, .attention)
        XCTAssertEqual(notInstalled.row(.signedIn)?.mark, .pending)
        XCTAssertEqual(notInstalled.row(.tailnetAddress)?.mark, .pending)

        let signedOut = card(TailscaleHostFacts(state: .signedOut, magicDNSName: nil))
        XCTAssertEqual(signedOut.row(.installed)?.mark, .met)
        XCTAssertEqual(signedOut.row(.signedIn)?.mark, .attention)
        XCTAssertEqual(
            signedOut.row(.signedIn)?.detail,
            "Sign in to Tailscale on this Mac. The door comes back on its own.",
            "the row and the status line disagree about what to do"
        )
        XCTAssertEqual(signedOut.row(.tailnetAddress)?.mark, .pending)
    }

    /// A door that is down for a reason the CLI does not explain says so on the address row,
    /// in the door's own words.
    func testADoorFailureTheCLIDoesNotExplainLandsOnTheAddressRow() {
        let state = RemoteAccessDoorState.notReachable(.identityUnavailable)
        let card = RemoteTailnetReadinessPresentation.resolve(
            isEnabled: true,
            facts: TailscaleHostFacts(state: .running, magicDNSName: "mac.tail1234.ts.net"),
            doorState: state,
            doorStatus: .tailscale(
                isEnabled: true,
                state: state,
                facts: TailscaleHostFacts(state: .running, magicDNSName: "mac.tail1234.ts.net")
            )
        )

        XCTAssertEqual(card.row(.installed)?.mark, .met)
        XCTAssertEqual(card.row(.signedIn)?.mark, .met)
        XCTAssertEqual(card.row(.tailnetAddress)?.mark, .attention)
        XCTAssertEqual(
            card.row(.tailnetAddress)?.detail,
            "Not currently reachable: this Mac has no certificate to present."
        )
    }

    /// The card asks nothing of a Mac whose tailnet way in is switched off.
    func testTheCardWaitsWhileTheWayInIsOff() {
        let card = RemoteTailnetReadinessPresentation.resolve(
            isEnabled: false,
            facts: .unknown,
            doorState: .off,
            doorStatus: .tailscale(isEnabled: false, state: .off, facts: .unknown)
        )
        XCTAssertEqual(card.rows.map(\.mark), [.pending, .pending, .pending])
        XCTAssertEqual(card.row(.installed)?.detail, "Checked when the tailnet way in is on.")
    }

    /// A bound door names its MagicDNS name beside its address, because that is a route the
    /// phone can take. Serve's port is not one of them.
    func testABoundDoorNamesItsMagicDNSNameAndNotServesPort() {
        let state = RemoteAccessDoorState.bound([Self.tailnetBinding])
        let status = RemoteDoorStatus.tailscale(
            isEnabled: true,
            state: state,
            facts: TailscaleHostFacts(state: .running, magicDNSName: "mac.tail1234.ts.net")
        )

        XCTAssertEqual(status.text, "Reachable at 100.65.47.126:8760")
        XCTAssertEqual(status.hint, "Also reachable at mac.tail1234.ts.net:8760.")
        XCTAssertEqual(status.tone, .ready)
        XCTAssertEqual(status.boundAddress, "100.65.47.126:8760")
    }

    private static let tailnetBinding = RemoteListenerBinding(
        door: .tailscale,
        address: RemoteNetworkAddress(interfaceName: "utun4", address: "100.65.47.126"),
        port: 8760
    )

    /// One LAN binding, so the pairing-card cases can be built without a listener.
    private static let lanBinding = RemoteListenerBinding(
        door: .lan,
        address: RemoteNetworkAddress(interfaceName: "en0", address: "192.168.1.42"),
        port: 8760
    )
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
