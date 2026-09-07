import Darwin
import Foundation
import ThreadingSimulatorKit

final class SimulatorHelperClient: SimulatorLiveStreamSession, @unchecked Sendable {
    let events: AsyncStream<SimulatorLiveStreamEvent>

    private let eventContinuation: AsyncStream<SimulatorLiveStreamEvent>.Continuation
    private let stateQueue = DispatchQueue(label: "codes.threading.simulator-client.state")
    private let readQueue = DispatchQueue(
        label: "codes.threading.simulator-client.read",
        qos: .userInitiated
    )
    private let writeQueue = DispatchQueue(
        label: "codes.threading.simulator-client.write",
        qos: .userInitiated
    )
    private let frameDecoder = SimulatorFrameDecoder()
    /// Non-nil when the helper selected the shared-memory transport; frames then arrive as
    /// `sharedFrameReady` control messages read through this instead of the decoder.
    private var sharedConsumer: SimulatorSharedMemoryConsumer?
    private let helperURL: URL
    private let deviceID: SimulatorDeviceID
    private let developerDirectory: String
    private let onStop: @Sendable () -> Void
    private let diagnosticID = UUID()
    private let startedAt = DispatchTime.now().uptimeNanoseconds

    private var process: Process?
    private var readDescriptor: Int32 = -1
    private var writeDescriptor: Int32 = -1
    private var handshake: CheckedContinuation<Void, Error>?
    private var handshakeSpan: PerformanceSpan?
    private var pendingInput: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var didStop = false
    private var didCompleteHandshake = false
    private var didStartDiagnostics = false
    private var isVisibleRequested = false
    /// Frames this process decoded, counted here because the helper only reports its own
    /// statistics every few seconds of sent frames; a stream that froze early never sends any.
    private var receivedFrames: UInt64 = 0
    private var latestStatistics = SimulatorBridgeStatistics(
        capturedFrames: 0,
        sentFrames: 0,
        replacedFrames: 0,
        encodedBytes: 0
    )
    private lazy var livenessMonitor = SimulatorFrameLivenessMonitor(queue: stateQueue) {
        [weak self] in self?.handleStall()
    }

    init(
        helperURL: URL,
        deviceID: SimulatorDeviceID,
        developerDirectory: String,
        onStop: @escaping @Sendable () -> Void
    ) {
        let pair = AsyncStream<SimulatorLiveStreamEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        events = pair.stream
        eventContinuation = pair.continuation
        self.helperURL = helperURL
        self.deviceID = deviceID
        self.developerDirectory = developerDirectory
        self.onStop = onStop
    }

    func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async { [self] in
                guard !didStop else {
                    continuation.resume(throwing: SimulatorLiveStreamError.disconnected)
                    return
                }
                handshake = continuation
                handshakeSpan = PerformanceRecorder.shared.begin(
                    "Simulator Helper Handshake",
                    category: "simulator",
                    crossesQueues: true,
                    metadata: ["protocol": String(SimulatorBridgeProtocol.current)]
                )
                do {
                    try launch()
                    guard let uuid = UUID(uuidString: deviceID.rawValue) else {
                        throw SimulatorLiveStreamError.helperUnavailable(
                            "The adopted Simulator device identifier is invalid."
                        )
                    }
                    send(.hello(SimulatorBridgeHello(
                        deviceID: uuid,
                        developerDirectory: developerDirectory,
                        preferredCodecs: [.h264, .jpeg],
                        requestedFramesPerSecond: 30,
                        supportsSharedMemory: true
                    )))
                    stateQueue.asyncAfter(deadline: .now() + 6) { [weak self] in
                        guard let self, !self.didCompleteHandshake else { return }
                        self.failHandshake(SimulatorLiveStreamError.handshakeTimedOut)
                        self.stopLocked()
                    }
                } catch {
                    failHandshake(error)
                    stopLocked()
                }
            }
        }
    }

    func setVisible(_ visible: Bool) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            isVisibleRequested = visible
            send(.setVisible(visible))
            if didCompleteHandshake { livenessMonitor.setVisible(visible) }
        }
    }

    func sendInput(_ input: SimulatorBridgeInput) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async { [weak self] in
                guard let self, !didStop, didCompleteHandshake else {
                    continuation.resume(throwing: SimulatorLiveStreamError.disconnected)
                    return
                }
                let id = UUID()
                pendingInput[id] = continuation
                send(.input(requestID: id, command: input))
                stateQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let continuation = self?.pendingInput.removeValue(forKey: id) else {
                        return
                    }
                    continuation.resume(throwing: SimulatorLiveStreamError.inputTimedOut)
                }
            }
        }
    }

    func stop() {
        stateQueue.async { [weak self] in self?.stopLocked() }
    }

    private func launch() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw SimulatorLiveStreamError.helperUnavailable(
                "Threading could not create the private Simulator helper socket."
            )
        }
        var noSignal: Int32 = 1
        setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        setsockopt(sockets[1], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let parentReadDescriptor = sockets[0]
        let parentWriteDescriptor = dup(parentReadDescriptor)
        guard parentWriteDescriptor >= 0 else {
            close(parentReadDescriptor)
            close(sockets[1])
            throw SimulatorLiveStreamError.helperUnavailable(
                "Threading could not prepare the private Simulator helper socket."
            )
        }
        let child = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)

        let process = Process()
        process.executableURL = helperURL
        process.standardInput = child
        process.standardOutput = child
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            guard let client = self else { return }
            client.stateQueue.async { [client] in
                guard !client.didStop else { return }
                let error = SimulatorLiveStreamError.helperUnavailable(
                    "The direct Simulator helper exited with status \(process.terminationStatus)."
                )
                client.failHandshake(error)
                client.eventContinuation.yield(.failed(error.localizedDescription))
                client.stopLocked(terminateProcess: false)
            }
        }
        do { try process.run() }
        catch {
            close(sockets[0])
            close(parentWriteDescriptor)
            child.closeFile()
            throw SimulatorLiveStreamError.helperUnavailable(
                "Threading could not launch its embedded Simulator helper."
            )
        }
        child.closeFile()
        self.process = process
        readDescriptor = parentReadDescriptor
        writeDescriptor = parentWriteDescriptor
        readQueue.async { [weak self] in self?.readFrames(from: parentReadDescriptor) }
    }

    private func readFrames(from descriptor: Int32) {
        var wireDecoder = SimulatorBridgeFrameDecoder()
        do {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                guard let bytes = try SimulatorSocketIO.read(
                    upToCount: buffer.count,
                    from: descriptor,
                    reusing: &buffer
                ) else { break }
                switch wireDecoder.accept(bytes) {
                case .refused:
                    throw SimulatorLiveStreamError.invalidFrame
                case .frames(let frames):
                    for frame in frames {
                        switch frame.kind {
                        case .control:
                            guard let message = try? JSONDecoder().decode(
                                SimulatorBridgeHelperMessage.self,
                                from: frame.payload
                            ) else { throw SimulatorLiveStreamError.invalidFrame }
                            stateQueue.async { [weak self] in self?.handle(message) }
                        case .media:
                            let media = try SimulatorBridgeMediaFrame.decode(frame.payload)
                            frameDecoder.decode(media) { [weak self] result in
                                guard let self else { return }
                                switch result {
                                case .success(let frame):
                                    eventContinuation.yield(.frame(frame))
                                    stateQueue.async { [weak self] in
                                        guard let self, !didStop else { return }
                                        receivedFrames += 1
                                        livenessMonitor.frameArrived()
                                        send(.acknowledgeFrame(frame.sequence))
                                    }
                                case .failure:
                                    stateQueue.async { [weak self] in
                                        guard let self else { return }
                                        eventContinuation.yield(.failed(
                                            SimulatorLiveStreamError.invalidFrame.localizedDescription
                                        ))
                                        stopLocked()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            stateQueue.async { [weak self] in
                guard let self, !didStop else { return }
                failHandshake(SimulatorLiveStreamError.disconnected)
                eventContinuation.yield(.ended)
                stopLocked(terminateProcess: false)
            }
        } catch {
            stateQueue.async { [weak self] in
                guard let self, !didStop else { return }
                failHandshake(error)
                eventContinuation.yield(.failed(error.localizedDescription))
                stopLocked()
            }
        }
    }

    private func handle(_ message: SimulatorBridgeHelperMessage) {
        switch message {
        case .hello(let reply):
            guard !didCompleteHandshake else { return }
            guard SimulatorBridgeCompatibility.evaluate(
                peerVersion: reply.protocolVersion,
                peerMinimum: reply.minimumSupported
            ) == .compatible else {
                failHandshake(SimulatorLiveStreamError.refused(
                    .incompatibleProtocol,
                    "The app and Simulator helper protocol versions do not overlap."
                ))
                stopLocked()
                return
            }
            if let refusal = reply.refusal {
                failHandshake(SimulatorLiveStreamError.refused(
                    refusal,
                    refusalDescription(refusal)
                ))
                stopLocked()
                return
            }
            guard let capabilities = reply.capabilities else {
                failHandshake(SimulatorLiveStreamError.invalidFrame)
                stopLocked()
                return
            }
            let backend: SimulatorLiveBackend
            if let shared = reply.sharedSurface {
                guard let consumer = SimulatorSharedMemoryConsumer(descriptor: shared) else {
                    failHandshake(SimulatorLiveStreamError.refused(
                        .internalFailure,
                        "Threading could not map the shared Simulator frame buffers."
                    ))
                    stopLocked()
                    return
                }
                sharedConsumer = consumer
                backend = .sharedMemory
                handshakeSpan?.end(metadata: ["result": "ready", "transport": "shared-memory"])
            } else if let codec = reply.selectedCodec {
                backend = .direct(codec: codec)
                handshakeSpan?.end(metadata: ["result": "ready", "codec": String(codec.rawValue)])
                SimulatorStreamDiagnostics.shared.started(id: diagnosticID, codec: codec)
            } else {
                failHandshake(SimulatorLiveStreamError.invalidFrame)
                stopLocked()
                return
            }
            didCompleteHandshake = true
            didStartDiagnostics = true
            handshakeSpan = nil
            ThreadingLogger.simulator.info(
                "Direct stream started device=\(self.deviceID.rawValue, privacy: .public) backend=\(String(describing: backend), privacy: .public)"
            )
            handshake?.resume()
            handshake = nil
            eventContinuation.yield(.ready(
                backend: backend,
                capabilities: capabilities,
                coreSimulatorVersion: reply.coreSimulatorVersion,
                simulatorKitVersion: reply.simulatorKitVersion
            ))
            livenessMonitor.setVisible(isVisibleRequested)

        case .inputResult(let requestID, let error):
            guard let continuation = pendingInput.removeValue(forKey: requestID) else { return }
            if let error {
                continuation.resume(throwing: SimulatorLiveStreamError.helperUnavailable(error))
            } else {
                continuation.resume()
            }

        case .statistics(let statistics):
            latestStatistics = statistics
            SimulatorStreamDiagnostics.shared.update(id: diagnosticID, statistics: statistics)
            eventContinuation.yield(.statistics(statistics))

        case let .sharedFrameReady(bufferIndex, sequence, presentationTimeNanoseconds):
            guard let consumer = sharedConsumer else { return }
            guard let image = consumer.image(forBuffer: bufferIndex) else {
                eventContinuation.yield(.failed(
                    SimulatorLiveStreamError.invalidFrame.localizedDescription
                ))
                stopLocked()
                return
            }
            receivedFrames += 1
            livenessMonitor.frameArrived()
            eventContinuation.yield(.frame(SimulatorLiveFrame(
                sequence: sequence,
                image: image,
                codec: nil,
                presentationTimeNanoseconds: presentationTimeNanoseconds
            )))
            // The shared-memory analogue of acknowledging a frame: the app has copied this buffer
            // out, so the helper may reuse it.
            send(.releaseSharedFrame(bufferIndex))

        case .failure(let refusal, let detail):
            let error = SimulatorLiveStreamError.refused(refusal, detail)
            failHandshake(error)
            eventContinuation.yield(.failed(detail))
            stopLocked()
        }
    }

    private func send(_ message: SimulatorBridgeClientMessage) {
        guard !didStop, writeDescriptor >= 0,
              let payload = try? JSONEncoder().encode(message),
              let frame = try? SimulatorBridgeFraming.encode(
                kind: .control,
                payload: payload
              ) else { return }
        let descriptor = writeDescriptor
        writeQueue.async { [weak self] in
            do { try SimulatorSocketIO.writeAll(frame, to: descriptor) }
            catch {
                guard let client = self else { return }
                client.stateQueue.async { [client] in client.stopLocked() }
            }
        }
    }

    private func failHandshake(_ error: Error) {
        handshakeSpan?.end(metadata: ["result": "failed"])
        handshakeSpan = nil
        guard let handshake else { return }
        self.handshake = nil
        handshake.resume(throwing: error)
    }

    /// A visible stream went quiet for the whole liveness deadline. That is a helper that is
    /// alive but not delivering, so it ends the way a lost helper does: with a reason the pane
    /// can show, a fallback and a retry, instead of a frozen picture under a live label.
    private func handleStall() {
        guard !didStop else { return }
        let error = SimulatorLiveStreamError.stalled
        ThreadingLogger.simulator.error(
            "Direct stream stalled device=\(self.deviceID.rawValue, privacy: .public) received=\(self.receivedFrames, privacy: .public)"
        )
        SimulatorStreamDiagnostics.shared.recordedFailure(error)
        eventContinuation.yield(.failed(error.localizedDescription))
        stopLocked()
    }

    private func stopLocked(terminateProcess: Bool = true) {
        guard !didStop else { return }
        if terminateProcess { send(.stop) }
        didStop = true
        livenessMonitor.invalidate()
        frameDecoder.invalidate()
        sharedConsumer?.close()
        sharedConsumer = nil
        failHandshake(SimulatorLiveStreamError.disconnected)
        for continuation in pendingInput.values {
            continuation.resume(throwing: SimulatorLiveStreamError.disconnected)
        }
        pendingInput.removeAll()
        writeQueue.sync {}
        if readDescriptor >= 0 { close(readDescriptor) }
        readDescriptor = -1
        if writeDescriptor >= 0 { close(writeDescriptor) }
        writeDescriptor = -1
        if terminateProcess, let process, process.isRunning { process.terminate() }
        process = nil
        if didStartDiagnostics {
            SimulatorStreamDiagnostics.shared.update(
                id: diagnosticID,
                statistics: latestStatistics
            )
            SimulatorStreamDiagnostics.shared.ended(id: diagnosticID)
            let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            ThreadingLogger.simulator.info(
                "Direct stream ended durationMS=\(elapsedMilliseconds, privacy: .public) received=\(self.receivedFrames, privacy: .public) sent=\(self.latestStatistics.sentFrames, privacy: .public) replaced=\(self.latestStatistics.replacedFrames, privacy: .public)"
            )
            didStartDiagnostics = false
        }
        eventContinuation.finish()
        onStop()
    }

    private func refusalDescription(_ refusal: SimulatorBridgeRefusal) -> String {
        switch refusal {
        case .incompatibleProtocol: return "The app and Simulator helper need the same build."
        case .untrustedHost: return "The Simulator helper could not verify Threading's signature."
        case .untrustedFramework: return "The active Xcode Simulator framework is not trusted."
        case .invalidDeveloperDirectory: return "The active Xcode developer directory is invalid."
        case .frameworkUnavailable: return "The active Xcode does not include SimulatorKit."
        case .apiUnavailable: return "This Xcode does not expose the compatible direct Simulator API."
        case .deviceUnavailable: return "The adopted Simulator device is no longer available."
        case .screenUnavailable: return "The adopted Simulator did not publish a screen surface."
        case .codecUnavailable: return "No supported live Simulator codec is available."
        case .malformedMessage: return "The Simulator helper connection returned malformed data."
        case .inputUnavailable: return "This Xcode does not expose compatible Simulator input."
        case .internalFailure: return "The direct Simulator helper failed."
        }
    }
}

enum SimulatorSocketIO {
    static func read(
        upToCount count: Int,
        from descriptor: Int32,
        reusing buffer: inout [UInt8]
    ) throws -> Data? {
        precondition(count > 0 && buffer.count >= count)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, count)
            }
            if bytesRead > 0 { return Data(buffer.prefix(bytesRead)) }
            if bytesRead == 0 { return nil }
            if errno != EINTR { throw SimulatorLiveStreamError.disconnected }
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { storage in
            guard let baseAddress = storage.baseAddress else { return }
            var offset = 0
            while offset < storage.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    storage.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw SimulatorLiveStreamError.disconnected
                }
            }
        }
    }
}

actor SimulatorLiveStreamCoordinator: SimulatorLiveStreamCoordinating {
    static let shared = SimulatorLiveStreamCoordinator()

    private let bundle: Bundle
    private var budget: SimulatorStreamBudget

    init(
        maximumStreams: Int = SimulatorStreamBudget.defaultMaximum,
        bundle: Bundle = .main
    ) {
        self.bundle = bundle
        self.budget = SimulatorStreamBudget(maximum: maximumStreams)
    }

    func openStream(for deviceID: SimulatorDeviceID) async throws -> any SimulatorLiveStreamSession {
        guard budget.hasCapacity else {
            throw SimulatorLiveStreamError.streamLimit(maximum: budget.maximum)
        }
        guard let helperURL = SimulatorHelperLocation.bundledExecutable(in: bundle),
              FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw SimulatorLiveStreamError.helperUnavailable(
                "This Threading build does not contain the direct Simulator helper."
            )
        }
        try SimulatorHelperTrust.verify(executableURL: helperURL, bundle: bundle)
        let developerDirectory = try SimulatorDeveloperDirectory.active()
        let token = try budget.reserve()
        let client = SimulatorHelperClient(
            helperURL: helperURL,
            deviceID: deviceID,
            developerDirectory: developerDirectory
        ) { [weak self] in
            Task { await self?.release(token) }
        }
        do {
            try await withTaskCancellationHandler {
                try await client.start()
            } onCancel: {
                client.stop()
            }
            try Task.checkCancellation()
            return client
        } catch {
            budget.release(token)
            if let streamError = error as? SimulatorLiveStreamError {
                SimulatorStreamDiagnostics.shared.recordedFailure(streamError)
            }
            throw error
        }
    }

    private func release(_ token: UUID) {
        budget.release(token)
    }
}
