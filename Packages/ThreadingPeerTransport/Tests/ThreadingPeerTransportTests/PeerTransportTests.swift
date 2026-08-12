import XCTest
@testable import ThreadingPeerTransport

final class PeerTransportTests: XCTestCase {
    func testConfigurationRejectsUnboundedOrUnsupportedServiceInput() throws {
        XCTAssertThrowsError(try PeerIceServer(urls: []))
        XCTAssertThrowsError(try PeerIceServer(urls: ["https://example.com/not-ice"]))

        let server = try PeerIceServer(urls: ["stun:stun.example.com:3478"])
        XCTAssertThrowsError(
            try PeerTransportConfiguration(
                iceServers: Array(
                    repeating: server,
                    count: PeerTransportBounds.maximumIceServers + 1
                )
            )
        )
    }

    func testConfiguredSTUNServerGathersServerReflexiveCandidate() async throws {
        guard let stunURL = ProcessInfo.processInfo.environment["THREADING_STUN_URL"],
              !stunURL.isEmpty
        else {
            throw XCTSkip("Set THREADING_STUN_URL to run the live STUN probe.")
        }
        let server = try PeerIceServer(urls: [stunURL])
        let configuration = try PeerTransportConfiguration(iceServers: [server])
        let peer = try WebRTCPeerTransport(role: .offerer, configuration: configuration)
        _ = try await peer.makeTrickleOffer()
        let foundServerReflexiveCandidate = try await Self.hasCandidate(
            containing: " typ srflx ",
            from: peer,
            timeout: .seconds(15)
        )
        await peer.close()

        XCTAssertTrue(foundServerReflexiveCandidate)
    }

    func testSessionDescriptionAndMessageLimitsAreEnforcedBeforeWebRTC() async throws {
        XCTAssertThrowsError(try PeerSessionDescription(kind: .offer, sdp: ""))
        XCTAssertThrowsError(
            try PeerIceCandidate(sdp: "", sdpMLineIndex: 0, sdpMid: nil)
        )
        XCTAssertThrowsError(
            try PeerSessionDescription(
                kind: .offer,
                sdp: String(
                    repeating: "x",
                    count: PeerTransportBounds.maximumSessionDescriptionBytes + 1
                )
            )
        )

        let configuration = try PeerTransportConfiguration()
        let peer = try WebRTCPeerTransport(role: .offerer, configuration: configuration)
        let oversized = Data(count: PeerTransportBounds.maximumMessageBytes + 1)
        do {
            try await peer.send(oversized)
            XCTFail("Expected the message limit to reject the payload")
        } catch let error as PeerTransportError {
            XCTAssertEqual(
                error,
                .messageTooLarge(
                    actual: oversized.count,
                    limit: PeerTransportBounds.maximumMessageBytes
                )
            )
        }
        await peer.close()
    }

    func testTrickledHostCandidatesOpenReliableChannel() async throws {
        let configuration = try PeerTransportConfiguration()
        let offerer = try WebRTCPeerTransport(role: .offerer, configuration: configuration)
        let answerer = try WebRTCPeerTransport(role: .answerer, configuration: configuration)

        let offer = try await offerer.makeTrickleOffer()
        let answer = try await answerer.makeTrickleAnswer(to: offer)
        try await offerer.accept(answer: answer)

        async let offerCandidateTransfer = Self.forwardCandidates(
            from: offerer,
            to: answerer
        )
        async let answerCandidateTransfer = Self.forwardCandidates(
            from: answerer,
            to: offerer
        )
        async let offererOpen: Void = offerer.waitUntilOpen()
        async let answererOpen: Void = answerer.waitUntilOpen()
        _ = try await (
            offerCandidateTransfer,
            answerCandidateTransfer,
            offererOpen,
            answererOpen
        )

        let message = Data("trickle-connected".utf8)
        try await offerer.send(message)
        let received = try await answerer.receive()
        XCTAssertEqual(received, message)
        await offerer.close()
        await answerer.close()
    }

    func testHostCandidatesOpenReliableOrderedChannelAndExposeDirectRoute() async throws {
        let started = ContinuousClock.now
        let configuration = try PeerTransportConfiguration()
        let offerer = try WebRTCPeerTransport(role: .offerer, configuration: configuration)
        let answerer = try WebRTCPeerTransport(role: .answerer, configuration: configuration)
        defer {
            Task {
                await offerer.close()
                await answerer.close()
            }
        }

        let offer = try await offerer.makeOffer()
        let answer = try await answerer.makeAnswer(to: offer)
        try await offerer.accept(answer: answer)

        async let offererOpen: Void = offerer.waitUntilOpen()
        async let answererOpen: Void = answerer.waitUntilOpen()
        _ = try await (offererOpen, answererOpen)

        let messageCount = 1_024
        let payloadBytes = 2_048
        async let receivedMessages = Self.receive(
            count: messageCount,
            from: answerer
        )

        for sequence in 0..<messageCount {
            var payload = Data(count: payloadBytes)
            payload.replaceSubrange(0..<8, with: Self.sequencePrefix(sequence))
            try await sendRetryingBackpressure(payload, through: offerer)
        }
        let messages = try await receivedMessages
        XCTAssertEqual(messages.count, messageCount)
        for (expectedSequence, data) in messages.enumerated() {
            XCTAssertEqual(data.count, payloadBytes)
            XCTAssertEqual(data.prefix(8), Self.sequencePrefix(expectedSequence))
        }

        let response = Data("connected".utf8)
        try await answerer.send(response)
        let receivedResponse = try await offerer.receive()
        XCTAssertEqual(receivedResponse, response)

        let route = await offerer.selectedRoute()
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.usesRelay, false)

        let offererSnapshot = await offerer.snapshot()
        let answererSnapshot = await answerer.snapshot()
        XCTAssertEqual(offererSnapshot.state, .open)
        XCTAssertEqual(answererSnapshot.state, .open)
        XCTAssertLessThanOrEqual(
            offererSnapshot.generatedCandidateCount,
            PeerTransportBounds.maximumIceCandidates
        )
        XCTAssertLessThanOrEqual(
            answererSnapshot.inboundBufferedBytes,
            PeerTransportBounds.maximumBufferedBytes
        )

        if ProcessInfo.processInfo.environment["THREADING_PERF"] == "1" {
            let elapsed = started.duration(to: .now)
            print(
                "THREADING_PERF peer-transport messages=\(messageCount) "
                    + "payload_bytes=\(payloadBytes) elapsed=\(elapsed) "
                    + "route=\(String(describing: route))"
            )
        }
    }

    func testUnreadMessageCountIsBoundedIndependentlyOfBytes() async throws {
        let configuration = try PeerTransportConfiguration()
        let offerer = try WebRTCPeerTransport(role: .offerer, configuration: configuration)
        let answerer = try WebRTCPeerTransport(role: .answerer, configuration: configuration)
        let offer = try await offerer.makeOffer()
        let answer = try await answerer.makeAnswer(to: offer)
        try await offerer.accept(answer: answer)
        async let offererOpen: Void = offerer.waitUntilOpen()
        async let answererOpen: Void = answerer.waitUntilOpen()
        _ = try await (offererOpen, answererOpen)

        for _ in 0...PeerTransportBounds.maximumBufferedMessages {
            do {
                try await sendRetryingBackpressure(Data([0]), through: offerer)
            } catch PeerTransportError.dataChannelNotOpen {
                break
            }
        }

        var answererSnapshot = await answerer.snapshot()
        for _ in 0..<100 {
            if case .failed = answererSnapshot.state { break }
            try await Task.sleep(nanoseconds: 1_000_000)
            answererSnapshot = await answerer.snapshot()
        }
        guard case .failed = answererSnapshot.state else {
            XCTFail("Expected the unread-message cap to close the transport")
            await offerer.close()
            await answerer.close()
            return
        }
        XCTAssertEqual(answererSnapshot.inboundBufferedBytes, 0)
        XCTAssertEqual(answererSnapshot.inboundBufferedMessages, 0)
        await offerer.close()
        await answerer.close()
    }

    private func sendRetryingBackpressure(
        _ data: Data,
        through peer: WebRTCPeerTransport
    ) async throws {
        while true {
            do {
                try await peer.send(data)
                return
            } catch PeerTransportError.outboundBackpressure {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    private static func sequencePrefix(_ sequence: Int) -> Data {
        var value = UInt64(sequence).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func receive(
        count: Int,
        from peer: WebRTCPeerTransport
    ) async throws -> [Data] {
        var messages: [Data] = []
        messages.reserveCapacity(count)
        for _ in 0..<count {
            messages.append(try await peer.receive())
        }
        return messages
    }

    private static func forwardCandidates(
        from source: WebRTCPeerTransport,
        to destination: WebRTCPeerTransport
    ) async throws {
        for try await candidate in source.localCandidates {
            try await destination.addRemoteCandidate(candidate)
        }
    }

    private static func hasCandidate(
        containing fragment: String,
        from peer: WebRTCPeerTransport,
        timeout: Duration
    ) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for try await candidate in peer.localCandidates {
                    if candidate.sdp.contains(fragment) { return true }
                }
                return false
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
