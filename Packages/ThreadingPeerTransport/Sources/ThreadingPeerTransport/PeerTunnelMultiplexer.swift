import Foundation

public struct PeerTunnelStream: Sendable {
    public let id: UInt32
    private let multiplexer: PeerTunnelMultiplexer

    fileprivate init(id: UInt32, multiplexer: PeerTunnelMultiplexer) {
        self.id = id
        self.multiplexer = multiplexer
    }

    public func accept() async throws {
        try await multiplexer.accept(streamID: id)
    }

    public func send(_ data: Data) async throws {
        try await multiplexer.send(data, streamID: id)
    }

    public func receive() async throws -> Data? {
        try await multiplexer.receive(streamID: id)
    }

    /// Replenishes credit only after the caller has handed the bytes to its local socket.
    public func acknowledge(_ byteCount: Int) async throws {
        try await multiplexer.acknowledge(byteCount, streamID: id)
    }

    public func endSending() async throws {
        try await multiplexer.endSending(streamID: id)
    }

    public func reset() async {
        await multiplexer.reset(streamID: id)
    }
}

/// Multiplexes bounded logical byte streams over one reliable ordered data channel.
///
/// Expected scale is one instance per connected device, at most 32 logical sockets, and at most
/// 256 KiB unacknowledged inbound bytes per direction and stream (8 MiB worst-case aggregate).
/// All mutation is actor-owned. A separate writer actor serializes frames across actor suspension,
/// preserving the data channel's ordering when several socket pumps are active.
public actor PeerTunnelMultiplexer {
    private struct PendingWait {
        let identifier: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private enum Phase {
        case opening
        case open
    }

    private struct StreamState {
        var phase: Phase
        var sendCredit = PeerTunnelBounds.streamWindowBytes
        var inboundChunks: [Data] = []
        var inboundHead = 0
        var unacknowledgedInboundBytes = 0
        var sendInFlight = false
        var localEnded = false
        var remoteEnded = false
        var remoteEndObserved = false
        var pendingOpen: PendingWait?
        var pendingReceive: CheckedContinuation<Data?, Error>?
        var pendingCredit: PendingWait?
    }

    private let role: PeerTunnelRole
    private let transport: any PeerMessageTransport
    private let writer: PeerTunnelWriter
    private var streams: [UInt32: StreamState] = [:]
    private var acceptedStreamIDs: [UInt32] = []
    private var acceptedHead = 0
    private var pendingAccept: CheckedContinuation<PeerTunnelStream, Error>?
    private var nextClientStreamID: UInt32 = 1
    private var receiveTask: Task<Void, Never>?
    private var terminalError: Error?

    public init(role: PeerTunnelRole, transport: any PeerMessageTransport) {
        self.role = role
        self.transport = transport
        writer = PeerTunnelWriter(transport: transport)
    }

    deinit {
        receiveTask?.cancel()
    }

    public func start() throws {
        guard receiveTask == nil else { throw PeerTunnelError.alreadyStarted }
        guard terminalError == nil else { throw PeerTunnelError.closed }
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    public func openStream() async throws -> PeerTunnelStream {
        try ensureStarted()
        guard role == .client else { throw PeerTunnelError.protocolViolation }
        guard streams.count < PeerTunnelBounds.maximumStreams else {
            throw PeerTunnelError.tooManyStreams(limit: PeerTunnelBounds.maximumStreams)
        }
        let streamID = try allocateClientStreamID()
        streams[streamID] = StreamState(phase: .opening)

        do {
            try await writer.send(.control(.open, streamID: streamID))
            try await waitUntilAccepted(streamID: streamID)
            return PeerTunnelStream(id: streamID, multiplexer: self)
        } catch {
            failStream(streamID, error: error)
            throw error
        }
    }

    public func acceptStream() async throws -> PeerTunnelStream {
        try ensureStarted()
        guard role == .server else { throw PeerTunnelError.protocolViolation }
        while acceptedHead < acceptedStreamIDs.count {
            let streamID = acceptedStreamIDs[acceptedHead]
            acceptedHead += 1
            compactAcceptedStreamsIfNeeded()
            if streams[streamID] != nil {
                return PeerTunnelStream(id: streamID, multiplexer: self)
            }
        }
        guard pendingAccept == nil else { throw PeerTransportError.operationAlreadyPending }
        return try await withCheckedThrowingContinuation { continuation in
            pendingAccept = continuation
        }
    }

    fileprivate func accept(streamID: UInt32) async throws {
        try ensureStarted()
        guard role == .server, var state = streams[streamID], state.phase == .opening else {
            throw PeerTunnelError.streamNotOpen(streamID)
        }
        state.phase = .open
        streams[streamID] = state
        do {
            try await writer.send(.control(.opened, streamID: streamID))
        } catch {
            failAll(error)
            throw error
        }
    }

    fileprivate func send(_ data: Data, streamID: UInt32) async throws {
        guard !data.isEmpty else { return }
        guard data.count <= PeerTunnelBounds.maximumDataBytes else {
            throw PeerTunnelError.writeTooLarge(
                actual: data.count,
                limit: PeerTunnelBounds.maximumDataBytes
            )
        }
        try ensureStarted()
        guard var initialState = streams[streamID], initialState.phase == .open,
              !initialState.localEnded else {
            throw PeerTunnelError.streamClosed(streamID)
        }
        guard !initialState.sendInFlight else {
            throw PeerTransportError.operationAlreadyPending
        }
        initialState.sendInFlight = true
        streams[streamID] = initialState
        do {
            try await sendStarted(data, streamID: streamID)
        } catch {
            if var state = streams[streamID] {
                state.sendInFlight = false
                streams[streamID] = state
            }
            throw error
        }
    }

    private func sendStarted(_ data: Data, streamID: UInt32) async throws {
        try await waitForCredit(streamID: streamID, byteCount: data.count)
        guard var state = streams[streamID], state.phase == .open, !state.localEnded else {
            throw PeerTunnelError.streamClosed(streamID)
        }
        state.sendCredit -= data.count
        streams[streamID] = state
        do {
            try await writer.send(.data(streamID: streamID, payload: data))
            if var current = streams[streamID] {
                current.sendInFlight = false
                streams[streamID] = current
            }
        } catch {
            failAll(error)
            throw error
        }
    }

    fileprivate func receive(streamID: UInt32) async throws -> Data? {
        try ensureStarted()
        guard var state = streams[streamID] else {
            throw PeerTunnelError.unknownStream(streamID)
        }
        guard state.phase == .open else { throw PeerTunnelError.streamNotOpen(streamID) }
        if state.inboundHead < state.inboundChunks.count {
            let data = state.inboundChunks[state.inboundHead]
            state.inboundHead += 1
            streams[streamID] = state
            compactInboundChunksIfNeeded(streamID: streamID)
            return data
        }
        if state.remoteEnded {
            state.remoteEndObserved = true
            streams[streamID] = state
            removeFinishedStreamIfPossible(streamID)
            return nil
        }
        guard state.pendingReceive == nil else { throw PeerTransportError.operationAlreadyPending }
        return try await withCheckedThrowingContinuation { continuation in
            state.pendingReceive = continuation
            streams[streamID] = state
        }
    }

    fileprivate func acknowledge(_ byteCount: Int, streamID: UInt32) async throws {
        guard byteCount > 0, var state = streams[streamID],
              byteCount <= state.unacknowledgedInboundBytes else {
            throw PeerTunnelError.invalidAcknowledgement(streamID: streamID)
        }
        state.unacknowledgedInboundBytes -= byteCount
        streams[streamID] = state
        do {
            try await writer.send(.window(streamID: streamID, bytes: byteCount))
            removeFinishedStreamIfPossible(streamID)
        } catch {
            failAll(error)
            throw error
        }
    }

    fileprivate func endSending(streamID: UInt32) async throws {
        guard var state = streams[streamID] else {
            throw PeerTunnelError.unknownStream(streamID)
        }
        guard state.phase == .open else { throw PeerTunnelError.streamNotOpen(streamID) }
        guard !state.localEnded else { return }
        guard !state.sendInFlight else { throw PeerTransportError.operationAlreadyPending }
        state.localEnded = true
        streams[streamID] = state
        do {
            try await writer.send(.control(.end, streamID: streamID))
            removeFinishedStreamIfPossible(streamID)
        } catch {
            failAll(error)
            throw error
        }
    }

    fileprivate func reset(streamID: UInt32) async {
        guard streams[streamID] != nil else { return }
        failStream(streamID, error: PeerTunnelError.streamClosed(streamID))
        try? await writer.send(.control(.reset, streamID: streamID))
    }

    public func close() async {
        guard terminalError == nil else { return }
        failAll(PeerTunnelError.closed)
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
    }

    private func runReceiveLoop() async {
        do {
            while !Task.isCancelled {
                let data = try await transport.receive()
                let frame = try PeerTunnelFrame(decoding: data)
                try await handle(frame)
            }
        } catch is CancellationError {
            return
        } catch {
            failAll(error)
            await transport.close()
        }
    }

    private func handle(_ frame: PeerTunnelFrame) async throws {
        switch frame.operation {
        case .open:
            try handleOpen(frame.streamID)
        case .opened:
            try handleOpened(frame.streamID)
        case .data:
            try handleData(frame.payload, streamID: frame.streamID)
        case .window:
            try handleWindow(Int(frame.value), streamID: frame.streamID)
        case .end:
            try handleEnd(frame.streamID)
        case .reset:
            guard streams[frame.streamID] != nil else {
                throw PeerTunnelError.unknownStream(frame.streamID)
            }
            failStream(
                frame.streamID,
                error: PeerTunnelError.streamClosed(frame.streamID)
            )
        }
    }

    private func handleOpen(_ streamID: UInt32) throws {
        guard role == .server, streamID.isMultiple(of: 2) == false,
              streams[streamID] == nil else {
            throw PeerTunnelError.protocolViolation
        }
        guard streams.count < PeerTunnelBounds.maximumStreams else {
            Task { try? await writer.send(.control(.reset, streamID: streamID)) }
            return
        }
        streams[streamID] = StreamState(phase: .opening)
        let stream = PeerTunnelStream(id: streamID, multiplexer: self)
        if let continuation = pendingAccept {
            pendingAccept = nil
            continuation.resume(returning: stream)
        } else {
            acceptedStreamIDs.append(streamID)
        }
    }

    private func handleOpened(_ streamID: UInt32) throws {
        guard role == .client, var state = streams[streamID], state.phase == .opening else {
            throw PeerTunnelError.protocolViolation
        }
        state.phase = .open
        let continuation = state.pendingOpen
        state.pendingOpen = nil
        streams[streamID] = state
        continuation?.continuation.resume()
    }

    private func handleData(_ data: Data, streamID: UInt32) throws {
        guard !data.isEmpty, var state = streams[streamID], state.phase == .open,
              !state.remoteEnded else {
            throw PeerTunnelError.protocolViolation
        }
        guard state.unacknowledgedInboundBytes
                <= PeerTunnelBounds.streamWindowBytes - data.count else {
            throw PeerTunnelError.receiveWindowExceeded(
                streamID: streamID,
                limit: PeerTunnelBounds.streamWindowBytes
            )
        }
        let bufferedChunkCount = state.inboundChunks.count - state.inboundHead
        guard state.pendingReceive != nil
                || bufferedChunkCount < PeerTunnelBounds.maximumBufferedChunksPerStream else {
            throw PeerTunnelError.receiveChunkLimitExceeded(
                streamID: streamID,
                limit: PeerTunnelBounds.maximumBufferedChunksPerStream
            )
        }
        state.unacknowledgedInboundBytes += data.count
        if let continuation = state.pendingReceive {
            state.pendingReceive = nil
            streams[streamID] = state
            continuation.resume(returning: data)
        } else {
            state.inboundChunks.append(data)
            streams[streamID] = state
        }
    }

    private func handleWindow(_ byteCount: Int, streamID: UInt32) throws {
        guard byteCount > 0, var state = streams[streamID], state.phase == .open,
              state.sendCredit <= PeerTunnelBounds.streamWindowBytes - byteCount else {
            throw PeerTunnelError.protocolViolation
        }
        state.sendCredit += byteCount
        let continuation = state.pendingCredit
        state.pendingCredit = nil
        streams[streamID] = state
        continuation?.continuation.resume()
    }

    private func handleEnd(_ streamID: UInt32) throws {
        guard var state = streams[streamID], state.phase == .open, !state.remoteEnded else {
            throw PeerTunnelError.protocolViolation
        }
        state.remoteEnded = true
        if state.inboundHead == state.inboundChunks.count,
           let continuation = state.pendingReceive {
            state.pendingReceive = nil
            state.remoteEndObserved = true
            continuation.resume(returning: nil)
        }
        streams[streamID] = state
        removeFinishedStreamIfPossible(streamID)
    }

    private func waitUntilAccepted(streamID: UInt32) async throws {
        guard var state = streams[streamID], state.phase == .opening else {
            throw PeerTunnelError.streamNotOpen(streamID)
        }
        let identifier = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            state.pendingOpen = PendingWait(identifier: identifier, continuation: continuation)
            streams[streamID] = state
            scheduleTimeout(
                after: PeerTunnelBounds.streamOpenTimeout,
                streamID: streamID,
                identifier: identifier,
                kind: .open
            )
        }
    }

    private func waitForCredit(streamID: UInt32, byteCount: Int) async throws {
        while true {
            guard var state = streams[streamID], state.phase == .open, !state.localEnded else {
                throw PeerTunnelError.streamClosed(streamID)
            }
            if state.sendCredit >= byteCount { return }
            guard state.pendingCredit == nil else { throw PeerTransportError.operationAlreadyPending }
            let identifier = UUID()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                state.pendingCredit = PendingWait(
                    identifier: identifier,
                    continuation: continuation
                )
                streams[streamID] = state
                scheduleTimeout(
                    after: PeerTunnelBounds.flowControlTimeout,
                    streamID: streamID,
                    identifier: identifier,
                    kind: .credit
                )
            }
        }
    }

    private func allocateClientStreamID() throws -> UInt32 {
        for _ in 0..<PeerTunnelBounds.maximumStreams {
            let candidate = nextClientStreamID
            nextClientStreamID = candidate > UInt32.max - 2 ? 1 : candidate + 2
            if streams[candidate] == nil { return candidate }
        }
        throw PeerTunnelError.tooManyStreams(limit: PeerTunnelBounds.maximumStreams)
    }

    private func ensureStarted() throws {
        if let terminalError { throw terminalError }
        guard receiveTask != nil else { throw PeerTunnelError.notStarted }
    }

    private func failAll(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        let active = streams
        streams.removeAll(keepingCapacity: false)
        for state in active.values {
            let failure = error as? PeerTunnelError ?? PeerTunnelError.transport(
                error.localizedDescription
            )
            state.pendingOpen?.continuation.resume(throwing: failure)
            state.pendingReceive?.resume(throwing: failure)
            state.pendingCredit?.continuation.resume(throwing: failure)
        }
        pendingAccept?.resume(throwing: error)
        pendingAccept = nil
        acceptedStreamIDs.removeAll(keepingCapacity: false)
        acceptedHead = 0
    }

    private func failStream(_ streamID: UInt32, error: Error) {
        guard let state = streams.removeValue(forKey: streamID) else { return }
        state.pendingOpen?.continuation.resume(throwing: error)
        state.pendingReceive?.resume(throwing: error)
        state.pendingCredit?.continuation.resume(throwing: error)
        removeAcceptedStreamID(streamID)
    }

    private func removeFinishedStreamIfPossible(_ streamID: UInt32) {
        guard let state = streams[streamID], state.localEnded, state.remoteEnded,
              state.remoteEndObserved,
              state.unacknowledgedInboundBytes == 0,
              state.inboundHead == state.inboundChunks.count else { return }
        streams[streamID] = nil
    }

    private func compactInboundChunksIfNeeded(streamID: UInt32) {
        guard var state = streams[streamID] else { return }
        if state.inboundHead == state.inboundChunks.count {
            state.inboundChunks.removeAll(keepingCapacity: true)
            state.inboundHead = 0
        } else if state.inboundHead >= 16,
                  state.inboundHead * 2 >= state.inboundChunks.count {
            state.inboundChunks.removeFirst(state.inboundHead)
            state.inboundHead = 0
        }
        streams[streamID] = state
    }

    private func compactAcceptedStreamsIfNeeded() {
        if acceptedHead == acceptedStreamIDs.count {
            acceptedStreamIDs.removeAll(keepingCapacity: true)
            acceptedHead = 0
        } else if acceptedHead >= 16, acceptedHead * 2 >= acceptedStreamIDs.count {
            acceptedStreamIDs.removeFirst(acceptedHead)
            acceptedHead = 0
        }
    }

    private enum WaitKind {
        case open
        case credit
    }

    private func scheduleTimeout(
        after seconds: TimeInterval,
        streamID: UInt32,
        identifier: UUID,
        kind: WaitKind
    ) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await self?.timeoutWait(streamID: streamID, identifier: identifier, kind: kind)
        }
    }

    private func timeoutWait(streamID: UInt32, identifier: UUID, kind: WaitKind) {
        guard let state = streams[streamID] else { return }
        let matches: Bool
        let error: PeerTunnelError
        switch kind {
        case .open:
            matches = state.pendingOpen?.identifier == identifier
            error = .streamOpenTimedOut(streamID)
        case .credit:
            matches = state.pendingCredit?.identifier == identifier
            error = .flowControlTimedOut(streamID)
        }
        guard matches else { return }
        failStream(streamID, error: error)
        Task { try? await writer.send(.control(.reset, streamID: streamID)) }
    }

    private func removeAcceptedStreamID(_ streamID: UInt32) {
        guard role == .server,
              let index = acceptedStreamIDs[acceptedHead...].firstIndex(of: streamID) else {
            return
        }
        acceptedStreamIDs.remove(at: index)
        compactAcceptedStreamsIfNeeded()
    }
}

private actor PeerTunnelWriter {
    private let transport: any PeerMessageTransport

    init(transport: any PeerMessageTransport) {
        self.transport = transport
    }

    func send(_ frame: PeerTunnelFrame) async throws {
        try await transport.sendWhenWritable(frame.encoded())
    }
}
