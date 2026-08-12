import Foundation
@preconcurrency import WebRTC

/// An ordered, reliable, encrypted peer data channel suitable for carrying bounded tunnel frames.
///
/// WebRTC invokes delegates on its own threads. `stateQueue` is the single owner of all mutable
/// Swift and WebRTC state after initialization; the unchecked conformance documents that explicit
/// synchronization boundary for the Objective-C framework's non-Sendable types.
public final class WebRTCPeerTransport: NSObject, @unchecked Sendable {
    private static let channelLabel = "threading.remote.v1"
    private static let factory: RTCPeerConnectionFactory = {
        _ = RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
    }()

    private let role: PeerTransportRole
    private let stateQueue = DispatchQueue(label: "codes.threading.peer-transport.state")
    private let peerConnection: RTCPeerConnection
    private let mediaConstraints = RTCMediaConstraints(
        mandatoryConstraints: nil,
        optionalConstraints: nil
    )
    public let localCandidates: AsyncThrowingStream<PeerIceCandidate, Error>
    private let localCandidateContinuation:
        AsyncThrowingStream<PeerIceCandidate, Error>.Continuation
    public let stateChanges: AsyncStream<PeerTransportState>
    private let stateContinuation: AsyncStream<PeerTransportState>.Continuation

    private var dataChannel: RTCDataChannel?
    private var transportState: PeerTransportState = .idle
    private var generatedCandidateCount = 0
    private var acceptedRemoteCandidateCount = 0

    private var pendingDescription: PendingDescription?
    private var pendingRemoteDescription: PendingVoid?
    private var pendingOpen: PendingVoid?
    private var pendingReceive: CheckedContinuation<Data, Error>?
    private var pendingSend: PendingSend?

    private var inboundMessages: [Data] = []
    private var inboundHead = 0
    private var inboundBufferedBytes = 0

    public init(
        role: PeerTransportRole,
        configuration: PeerTransportConfiguration
    ) throws {
        self.role = role
        let candidateStream = AsyncThrowingStream<PeerIceCandidate, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(PeerTransportBounds.maximumIceCandidates)
        )
        localCandidates = candidateStream.stream
        localCandidateContinuation = candidateStream.continuation
        let stateStream = AsyncStream<PeerTransportState>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        stateChanges = stateStream.stream
        stateContinuation = stateStream.continuation

        let rtcConfiguration = RTCConfiguration()
        rtcConfiguration.sdpSemantics = .unifiedPlan
        rtcConfiguration.bundlePolicy = .maxBundle
        rtcConfiguration.rtcpMuxPolicy = .require
        rtcConfiguration.continualGatheringPolicy = .gatherOnce
        rtcConfiguration.iceTransportPolicy = configuration.policy == .relayOnly ? .relay : .all
        rtcConfiguration.iceServers = configuration.iceServers.map { server in
            RTCIceServer(
                urlStrings: server.urls,
                username: server.username,
                credential: server.credential
            )
        }

        guard let connection = Self.factory.peerConnection(
            with: rtcConfiguration,
            constraints: mediaConstraints,
            delegate: nil
        ) else {
            throw PeerTransportError.webRTC("WebRTC could not create a peer connection.")
        }
        self.peerConnection = connection
        super.init()
        connection.delegate = self

        if role == .offerer {
            let dataConfiguration = RTCDataChannelConfiguration()
            dataConfiguration.isOrdered = true
            dataConfiguration.maxPacketLifeTime = -1
            dataConfiguration.maxRetransmits = -1
            dataConfiguration.isNegotiated = false
            guard let channel = connection.dataChannel(
                forLabel: Self.channelLabel,
                configuration: dataConfiguration
            ) else {
                connection.close()
                throw PeerTransportError.webRTC("WebRTC could not create the data channel.")
            }
            dataChannel = channel
            channel.delegate = self
        }
    }

    deinit {
        localCandidateContinuation.finish()
        stateContinuation.finish()
        dataChannel?.delegate = nil
        peerConnection.delegate = nil
        dataChannel?.close()
        peerConnection.close()
    }

    public func makeOffer() async throws -> PeerSessionDescription {
        guard role == .offerer else {
            throw PeerTransportError.unexpectedSessionDescription(expected: .offer)
        }
        return try await createLocalDescription(kind: .offer, waitForGathering: true)
    }

    /// Returns after the initial local SDP is set. Consume `localCandidates` and signal each
    /// candidate while gathering continues.
    public func makeTrickleOffer() async throws -> PeerSessionDescription {
        guard role == .offerer else {
            throw PeerTransportError.unexpectedSessionDescription(expected: .offer)
        }
        return try await createLocalDescription(kind: .offer, waitForGathering: false)
    }

    public func makeAnswer(to offer: PeerSessionDescription) async throws -> PeerSessionDescription {
        guard role == .answerer, offer.kind == .offer else {
            throw PeerTransportError.unexpectedSessionDescription(expected: .offer)
        }
        try await setRemoteDescription(offer)
        return try await createLocalDescription(kind: .answer, waitForGathering: true)
    }

    /// Accepts the offer and returns the initial answer before ICE gathering finishes.
    public func makeTrickleAnswer(
        to offer: PeerSessionDescription
    ) async throws -> PeerSessionDescription {
        guard role == .answerer, offer.kind == .offer else {
            throw PeerTransportError.unexpectedSessionDescription(expected: .offer)
        }
        try await setRemoteDescription(offer)
        return try await createLocalDescription(kind: .answer, waitForGathering: false)
    }

    public func accept(answer: PeerSessionDescription) async throws {
        guard role == .offerer, answer.kind == .answer else {
            throw PeerTransportError.unexpectedSessionDescription(expected: .answer)
        }
        try await setRemoteDescription(answer)
    }

    public func addRemoteCandidate(_ candidate: PeerIceCandidate) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async { [self] in
                guard transportState != .closed else {
                    continuation.resume(throwing: PeerTransportError.transportClosed)
                    return
                }
                guard acceptedRemoteCandidateCount < PeerTransportBounds.maximumIceCandidates else {
                    continuation.resume(
                        throwing: PeerTransportError.tooManyIceCandidates(
                            limit: PeerTransportBounds.maximumIceCandidates
                        )
                    )
                    return
                }
                acceptedRemoteCandidateCount += 1
                let rtcCandidate = RTCIceCandidate(
                    sdp: candidate.sdp,
                    sdpMLineIndex: candidate.sdpMLineIndex,
                    sdpMid: candidate.sdpMid
                )
                peerConnection.add(rtcCandidate) { error in
                    if let error {
                        continuation.resume(
                            throwing: PeerTransportError.webRTC(error.localizedDescription)
                        )
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    public func waitUntilOpen() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async { [self] in
                switch transportState {
                case .open:
                    continuation.resume()
                case .closed:
                    continuation.resume(throwing: PeerTransportError.transportClosed)
                case .failed(let message):
                    continuation.resume(throwing: PeerTransportError.webRTC(message))
                default:
                    guard pendingOpen == nil else {
                        continuation.resume(throwing: PeerTransportError.operationAlreadyPending)
                        return
                    }
                    let identifier = UUID()
                    pendingOpen = PendingVoid(identifier: identifier, continuation: continuation)
                    scheduleTimeout(identifier: identifier, operation: .open)
                }
            }
        }
    }

    /// Sends one already-framed tunnel message. The caller should pause its socket read and retry
    /// after backpressure rather than adding another queue in front of WebRTC.
    public func send(_ data: Data) async throws {
        guard data.count <= PeerTransportBounds.maximumMessageBytes else {
            throw PeerTransportError.messageTooLarge(
                actual: data.count,
                limit: PeerTransportBounds.maximumMessageBytes
            )
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async { [self] in
                switch sendLocked(data) {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(
                        throwing: error
                    )
                }
            }
        }
    }

    /// Sends one message after the native channel has drained enough capacity. Only one caller
    /// may wait; tunnel multiplexers serialize writes before reaching this boundary.
    public func sendWhenWritable(_ data: Data) async throws {
        guard data.count <= PeerTransportBounds.maximumMessageBytes else {
            throw PeerTransportError.messageTooLarge(
                actual: data.count,
                limit: PeerTransportBounds.maximumMessageBytes
            )
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async { [self] in
                switch sendLocked(data) {
                case .success:
                    continuation.resume()
                case .failure(PeerTransportError.outboundBackpressure):
                    guard pendingSend == nil else {
                        continuation.resume(throwing: PeerTransportError.operationAlreadyPending)
                        return
                    }
                    let identifier = UUID()
                    pendingSend = PendingSend(
                        identifier: identifier,
                        data: data,
                        continuation: continuation
                    )
                    stateQueue.asyncAfter(
                        deadline: .now() + PeerTransportBounds.outboundBackpressureTimeout
                    ) { [weak self] in
                        guard let self, pendingSend?.identifier == identifier else { return }
                        closeLocked(
                            error: PeerTransportError.outboundBackpressureTimedOut(
                                limit: PeerTransportBounds.maximumBufferedBytes
                            ),
                            failed: true
                        )
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Receives one message. At most one waiter and 2 MiB of unread messages are retained.
    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                if inboundHead < inboundMessages.count {
                    let data = inboundMessages[inboundHead]
                    inboundHead += 1
                    inboundBufferedBytes -= data.count
                    compactInboundStorageIfNeeded()
                    continuation.resume(returning: data)
                    return
                }
                switch transportState {
                case .closed:
                    continuation.resume(throwing: PeerTransportError.transportClosed)
                case .failed(let message):
                    continuation.resume(throwing: PeerTransportError.webRTC(message))
                default:
                    guard pendingReceive == nil else {
                        continuation.resume(throwing: PeerTransportError.operationAlreadyPending)
                        return
                    }
                    pendingReceive = continuation
                }
            }
        }
    }

    public func snapshot() async -> PeerTransportSnapshot {
        await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                continuation.resume(
                    returning: PeerTransportSnapshot(
                        state: transportState,
                        generatedCandidateCount: generatedCandidateCount,
                        outboundBufferedBytes: dataChannel?.bufferedAmount ?? 0,
                        inboundBufferedBytes: inboundBufferedBytes,
                        inboundBufferedMessages: inboundMessages.count - inboundHead
                    )
                )
            }
        }
    }

    /// Reads only candidate kinds and the network protocol; addresses are deliberately omitted.
    public func selectedRoute() async -> PeerTransportRoute? {
        await withCheckedContinuation { continuation in
            stateQueue.async { [peerConnection] in
                peerConnection.statistics { report in
                    continuation.resume(returning: Self.route(from: report))
                }
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                closeLocked(error: PeerTransportError.transportClosed, failed: false)
                continuation.resume()
            }
        }
    }

    private func createLocalDescription(
        kind: PeerSessionDescription.Kind,
        waitForGathering: Bool
    ) async throws -> PeerSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                guard pendingDescription == nil, pendingRemoteDescription == nil else {
                    continuation.resume(throwing: PeerTransportError.operationAlreadyPending)
                    return
                }
                guard transportState != .closed else {
                    continuation.resume(throwing: PeerTransportError.transportClosed)
                    return
                }

                setTransportState(.gathering)
                generatedCandidateCount = 0
                let identifier = UUID()
                pendingDescription = PendingDescription(
                    identifier: identifier,
                    kind: kind,
                    waitForGathering: waitForGathering,
                    continuation: continuation
                )
                scheduleTimeout(identifier: identifier, operation: .description)

                let completion: @Sendable (RTCSessionDescription?, Error?) -> Void = {
                    [weak self] description, error in
                    self?.stateQueue.async { [weak self] in
                        self?.didCreateLocalDescription(
                            description,
                            error: error,
                            identifier: identifier
                        )
                    }
                }
                switch kind {
                case .offer:
                    peerConnection.offer(for: mediaConstraints, completionHandler: completion)
                case .answer:
                    peerConnection.answer(for: mediaConstraints, completionHandler: completion)
                }
            }
        }
    }

    private func didCreateLocalDescription(
        _ description: RTCSessionDescription?,
        error: Error?,
        identifier: UUID
    ) {
        guard pendingDescription?.identifier == identifier else { return }
        if let error {
            failPendingDescription(PeerTransportError.webRTC(error.localizedDescription))
            return
        }
        guard let description else {
            failPendingDescription(
                PeerTransportError.webRTC("WebRTC returned no session description.")
            )
            return
        }
        peerConnection.setLocalDescription(description) { [weak self] error in
            self?.stateQueue.async { [weak self] in
                guard let self, pendingDescription?.identifier == identifier else { return }
                if let error {
                    failPendingDescription(PeerTransportError.webRTC(error.localizedDescription))
                    return
                }
                completeLocalDescriptionIfReady(identifier: identifier)
            }
        }
    }

    private func completeLocalDescriptionIfReady(identifier: UUID) {
        guard pendingDescription?.identifier == identifier,
              let localDescription = peerConnection.localDescription,
              let pending = pendingDescription
        else { return }
        guard !pending.waitForGathering
                || peerConnection.iceGatheringState == .complete
        else { return }
        do {
            let description = try PeerSessionDescription(
                kind: pending.kind,
                sdp: localDescription.sdp
            )
            pendingDescription = nil
            if transportState != .open {
                setTransportState(pending.kind == .answer ? .connecting : .idle)
            }
            pending.continuation.resume(returning: description)
        } catch {
            failPendingDescription(error)
        }
    }

    private func setRemoteDescription(_ description: PeerSessionDescription) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async { [self] in
                guard pendingDescription == nil, pendingRemoteDescription == nil else {
                    continuation.resume(throwing: PeerTransportError.operationAlreadyPending)
                    return
                }
                guard transportState != .closed else {
                    continuation.resume(throwing: PeerTransportError.transportClosed)
                    return
                }

                let identifier = UUID()
                pendingRemoteDescription = PendingVoid(
                    identifier: identifier,
                    continuation: continuation
                )
                scheduleTimeout(identifier: identifier, operation: .remoteDescription)
                let rtcDescription = RTCSessionDescription(
                    type: description.kind == .offer ? .offer : .answer,
                    sdp: description.sdp
                )
                peerConnection.setRemoteDescription(rtcDescription) { [weak self] error in
                    self?.stateQueue.async { [weak self] in
                        guard let self,
                              let pending = pendingRemoteDescription,
                              pending.identifier == identifier
                        else { return }
                        pendingRemoteDescription = nil
                        if let error {
                            pending.continuation.resume(
                                throwing: PeerTransportError.webRTC(error.localizedDescription)
                            )
                        } else {
                            if transportState != .open {
                                setTransportState(.connecting)
                            }
                            pending.continuation.resume()
                        }
                    }
                }
            }
        }
    }

    private func didGenerateCandidate(_ candidate: PeerIceCandidate) {
        generatedCandidateCount += 1
        guard generatedCandidateCount <= PeerTransportBounds.maximumIceCandidates else {
            closeLocked(
                error: PeerTransportError.tooManyIceCandidates(
                    limit: PeerTransportBounds.maximumIceCandidates
                ),
                failed: true
            )
            return
        }
        switch localCandidateContinuation.yield(candidate) {
        case .enqueued:
            break
        case .dropped:
            closeLocked(
                error: PeerTransportError.tooManyIceCandidates(
                    limit: PeerTransportBounds.maximumIceCandidates
                ),
                failed: true
            )
        case .terminated:
            break
        @unknown default:
            break
        }
    }

    private func adoptRemoteDataChannel(_ channel: RTCDataChannel) {
        guard role == .answerer,
              channel.label == Self.channelLabel,
              dataChannel == nil
        else {
            channel.close()
            return
        }
        dataChannel = channel
        channel.delegate = self
        dataChannelStateChanged(channel)
    }

    private func dataChannelStateChanged(_ channel: RTCDataChannel) {
        guard channel === dataChannel else { return }
        switch channel.readyState {
        case .open:
            setTransportState(.open)
            if let pending = pendingOpen {
                pendingOpen = nil
                pending.continuation.resume()
            }
        case .closed:
            if transportState != .closed {
                closeLocked(error: PeerTransportError.transportClosed, failed: false)
            }
        case .connecting, .closing:
            break
        @unknown default:
            break
        }
    }

    private func sendLocked(_ data: Data) -> Result<Void, PeerTransportError> {
        guard transportState == .open, let channel = dataChannel,
              channel.readyState == .open
        else {
            return .failure(.dataChannelNotOpen)
        }
        let buffered = channel.bufferedAmount
        let limit = UInt64(PeerTransportBounds.maximumBufferedBytes)
        guard UInt64(data.count) <= limit,
              buffered <= limit - UInt64(data.count)
        else {
            return .failure(
                .outboundBackpressure(
                    buffered: buffered,
                    attempted: data.count,
                    limit: PeerTransportBounds.maximumBufferedBytes
                )
            )
        }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        guard channel.sendData(buffer) else {
            return .failure(.webRTC("WebRTC rejected the outbound message."))
        }
        return .success(())
    }

    private func flushPendingSend() {
        guard let pending = pendingSend else { return }
        switch sendLocked(pending.data) {
        case .success:
            pendingSend = nil
            pending.continuation.resume()
        case .failure(PeerTransportError.outboundBackpressure):
            break
        case .failure(let error):
            pendingSend = nil
            pending.continuation.resume(throwing: error)
        }
    }

    private func receiveLocked(_ data: Data) {
        guard data.count <= PeerTransportBounds.maximumMessageBytes else {
            closeLocked(
                error: PeerTransportError.messageTooLarge(
                    actual: data.count,
                    limit: PeerTransportBounds.maximumMessageBytes
                ),
                failed: true
            )
            return
        }
        if let continuation = pendingReceive {
            pendingReceive = nil
            continuation.resume(returning: data)
            return
        }
        guard inboundMessages.count - inboundHead
                < PeerTransportBounds.maximumBufferedMessages
        else {
            closeLocked(
                error: PeerTransportError.inboundMessageLimitExceeded(
                    limit: PeerTransportBounds.maximumBufferedMessages
                ),
                failed: true
            )
            return
        }
        guard inboundBufferedBytes <= PeerTransportBounds.maximumBufferedBytes - data.count else {
            closeLocked(
                error: PeerTransportError.inboundBufferExceeded(
                    limit: PeerTransportBounds.maximumBufferedBytes
                ),
                failed: true
            )
            return
        }
        inboundMessages.append(data)
        inboundBufferedBytes += data.count
    }

    private func compactInboundStorageIfNeeded() {
        if inboundHead == inboundMessages.count {
            inboundMessages.removeAll(keepingCapacity: true)
            inboundHead = 0
        } else if inboundHead >= 64, inboundHead * 2 >= inboundMessages.count {
            inboundMessages.removeFirst(inboundHead)
            inboundHead = 0
        }
    }

    private func failPendingDescription(_ error: Error) {
        guard pendingDescription != nil else { return }
        closeLocked(error: error, failed: true)
    }

    private func closeLocked(error: Error, failed: Bool) {
        guard transportState != .closed else { return }
        setTransportState(failed ? .failed(error.localizedDescription) : .closed)
        dataChannel?.delegate = nil
        dataChannel?.close()
        peerConnection.delegate = nil
        peerConnection.close()
        if failed {
            localCandidateContinuation.finish(throwing: error)
        } else {
            localCandidateContinuation.finish()
        }
        stateContinuation.finish()

        if let pending = pendingDescription {
            pendingDescription = nil
            pending.continuation.resume(throwing: error)
        }
        if let pending = pendingRemoteDescription {
            pendingRemoteDescription = nil
            pending.continuation.resume(throwing: error)
        }
        if let pending = pendingOpen {
            pendingOpen = nil
            pending.continuation.resume(throwing: error)
        }
        if let pending = pendingReceive {
            pendingReceive = nil
            pending.resume(throwing: error)
        }
        if let pending = pendingSend {
            pendingSend = nil
            pending.continuation.resume(throwing: error)
        }
        inboundMessages.removeAll(keepingCapacity: false)
        inboundHead = 0
        inboundBufferedBytes = 0
    }

    private enum TimeoutOperation {
        case description
        case remoteDescription
        case open
    }

    private func setTransportState(_ state: PeerTransportState) {
        guard transportState != state else { return }
        transportState = state
        stateContinuation.yield(state)
    }

    private func scheduleTimeout(identifier: UUID, operation: TimeoutOperation) {
        stateQueue.asyncAfter(deadline: .now() + PeerTransportBounds.negotiationTimeout) { [weak self] in
            guard let self else { return }
            let matches: Bool
            switch operation {
            case .description:
                matches = pendingDescription?.identifier == identifier
            case .remoteDescription:
                matches = pendingRemoteDescription?.identifier == identifier
            case .open:
                matches = pendingOpen?.identifier == identifier
            }
            guard matches else { return }
            closeLocked(error: PeerTransportError.negotiationTimedOut, failed: true)
        }
    }

    private static func route(from report: RTCStatisticsReport) -> PeerTransportRoute? {
        let statistics = report.statistics
        let selectedPairIdentifier = statistics.values
            .first(where: { $0.type == "transport" })?
            .values["selectedCandidatePairId"] as? String
        let pair = selectedPairIdentifier.flatMap { statistics[$0] }
            ?? statistics.values.first(where: { statistic in
                statistic.type == "candidate-pair"
                    && (statistic.values["nominated"] as? NSNumber)?.boolValue == true
                    && (statistic.values["state"] as? String) == "succeeded"
            })
        guard let pair,
              let localIdentifier = pair.values["localCandidateId"] as? String,
              let remoteIdentifier = pair.values["remoteCandidateId"] as? String,
              let local = statistics[localIdentifier],
              let remote = statistics[remoteIdentifier]
        else { return nil }

        return PeerTransportRoute(
            localCandidate: candidateKind(local.values["candidateType"] as? String),
            remoteCandidate: candidateKind(remote.values["candidateType"] as? String),
            networkProtocol: local.values["protocol"] as? String
        )
    }

    private static func candidateKind(_ rawValue: String?) -> PeerCandidateKind {
        guard let rawValue else { return .unknown }
        return PeerCandidateKind(rawValue: rawValue) ?? .unknown
    }

    private struct PendingDescription {
        let identifier: UUID
        let kind: PeerSessionDescription.Kind
        let waitForGathering: Bool
        let continuation: CheckedContinuation<PeerSessionDescription, Error>
    }

    private struct PendingVoid {
        let identifier: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct PendingSend {
        let identifier: UUID
        let data: Data
        let continuation: CheckedContinuation<Void, Error>
    }
}

extension WebRTCPeerTransport: RTCPeerConnectionDelegate {
    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove stream: RTCMediaStream
    ) {}

    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            switch newState {
            case .failed:
                closeLocked(
                    error: PeerTransportError.webRTC("ICE connectivity checks failed."),
                    failed: true
                )
            case .closed:
                closeLocked(error: PeerTransportError.transportClosed, failed: false)
            default:
                break
            }
        }
    }

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {
        stateQueue.async { [weak self] in
            guard let self, newState == .complete else { return }
            localCandidateContinuation.finish()
            if let identifier = pendingDescription?.identifier {
                completeLocalDescriptionIfReady(identifier: identifier)
            }
        }
    }

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        let boundedCandidate: PeerIceCandidate
        do {
            boundedCandidate = try PeerIceCandidate(
                sdp: candidate.sdp,
                sdpMLineIndex: candidate.sdpMLineIndex,
                sdpMid: candidate.sdpMid
            )
        } catch {
            stateQueue.async { [weak self] in
                self?.closeLocked(error: error, failed: true)
            }
            return
        }
        stateQueue.async { [weak self] in
            self?.didGenerateCandidate(boundedCandidate)
        }
    }

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {
        stateQueue.async { [weak self] in
            self?.adoptRemoteDataChannel(dataChannel)
        }
    }
}

extension WebRTCPeerTransport: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        stateQueue.async { [weak self] in
            self?.dataChannelStateChanged(dataChannel)
        }
    }

    public func dataChannel(
        _ dataChannel: RTCDataChannel,
        didReceiveMessageWith buffer: RTCDataBuffer
    ) {
        let data = Data(buffer.data)
        stateQueue.async { [weak self] in
            self?.receiveLocked(data)
        }
    }

    public func dataChannel(
        _ dataChannel: RTCDataChannel,
        didChangeBufferedAmount amount: UInt64
    ) {
        stateQueue.async { [weak self] in
            guard let self, dataChannel === self.dataChannel else { return }
            flushPendingSend()
        }
    }
}
