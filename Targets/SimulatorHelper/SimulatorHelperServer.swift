import Darwin
import Foundation
import IOSurface
import ThreadingSimulatorKit

/// Set from a signal handler when the app terminates the helper (the client stops a stream with
/// `process.terminate()`), so the read loop can break and run cleanup — otherwise the shared-memory
/// transport's mapped temp buffers would leak.
private nonisolated(unsafe) var helperTerminationRequested: sig_atomic_t = 0

// The bridge is already shared across the helper's queues (the capture loop on the state queue, and
// input through `SimulatorInputSender`), and it serializes its own private-framework work — the
// accessibility read on a dedicated serial queue, HID input through its own client. Marking it
// `@unchecked Sendable` lets the snapshot read run off the state queue the same way input does.
extension SimulatorPrivateBridge: @unchecked Sendable {}

private func installHelperTerminationHandlers() {
    var action = sigaction()
    action.__sigaction_u.__sa_handler = { _ in helperTerminationRequested = 1 }
    // No SA_RESTART: a blocking read must return EINTR on the signal so the loop can notice and
    // tear down, rather than transparently resuming.
    action.sa_flags = 0
    sigemptyset(&action.sa_mask)
    _ = sigaction(SIGTERM, &action, nil)
    _ = sigaction(SIGINT, &action, nil)
}

final class SimulatorHelperServer: @unchecked Sendable {
    private enum Limits {
        static let readBytes = 64 * 1024
        static let minimumFramesPerSecond = 1
        static let maximumFramesPerSecond = 60
    }

    /// Stable codes emitted by the adjacent Objective-C compatibility shim. Keeping the mapping
    /// here preserves the protocol's semantic refusals without exposing private framework types.
    private enum BridgeFailureCode {
        static let untrustedFramework = 10
        static let invalidDeveloperDirectory = 20
        static let frameworkMissing = 21
        static let frameworkLoadFailed = 22
        static let apiUnavailable = 23
        static let deviceUnavailable = 24
        static let screenInitializationFailed = 25
        static let framebufferUnavailable = 26
    }

    private let inputDescriptor = STDIN_FILENO
    private let outputDescriptor = STDOUT_FILENO
    private let stateQueue = DispatchQueue(label: "codes.threading.simulator-helper.state")
    private let outputQueue = DispatchQueue(label: "codes.threading.simulator-helper.output")
    private let inputQueue = DispatchQueue(label: "codes.threading.simulator-helper.input")
    private var decoder = SimulatorBridgeFrameDecoder()
    private var bridge: SimulatorPrivateBridge?
    private var inputSender: SimulatorInputSender?
    private var encoder: (any SimulatorFrameEncoding)?
    private var orientedFrameSurface: SimulatorOrientedFrameSurface?
    /// Non-nil when the app negotiated the shared-memory transport; the capture loop then copies
    /// each surface into a shared buffer instead of encoding it.
    private var sharedProvider: SimulatorSharedMemoryProvider?
    /// A rotation often changes only screen properties, leaving the native surface unchanged.
    /// Both size and orientation belong to one negotiation, including its input coordinate map.
    private var captureGeometry: CaptureGeometry?
    private struct CaptureGeometry: Equatable {
        let width: Int
        let height: Int
        let orientation: Int
        init(_ surface: IOSurface, orientation: Int) {
            width = IOSurfaceGetWidth(surface)
            height = IOSurfaceGetHeight(surface)
            self.orientation = orientation
        }
    }
    private static let geometryChangedDetail =
        "The Simulator screen rotated or resized; the stream is reconnecting. Retry the request."
    private var framesPerSecond = 30
    private var timer: DispatchSourceTimer?
    private var nextSequence: UInt64 = 1
    /// One frame in the encoder at a time: the next capture waits for this one to come back.
    /// That only works with an encoder that emits every frame immediately, which is why
    /// `SimulatorH264FrameEncoder` verifies its zero frame delay instead of assuming it.
    private var isEncoding = false
    private var frameWindow = SimulatorLatestFrameWindow<SimulatorBridgeMediaFrame>()
    private var statistics = SimulatorBridgeStatistics(
        capturedFrames: 0,
        sentFrames: 0,
        replacedFrames: 0,
        encodedBytes: 0
    )
    private var peerProtocolVersion = 1
    private var hasHello = false
    private var isVisible = false
    private var isStopped = false
    private var isGeometryChanging = false

    func run() -> Int32 {
        guard SimulatorPrivateBridge.hostProcessIsTrusted() else {
            writeControl(.hello(SimulatorBridgeHelloReply(
                selectedCodec: nil,
                capabilities: nil,
                refusal: .untrustedHost,
                coreSimulatorVersion: nil,
                simulatorKitVersion: nil
            )))
            fputs("threading-simulator-helper: untrusted host process\n", stderr)
            return 77
        }

        installHelperTerminationHandlers()
        // Reclaim shared buffers a previous helper leaked if it was killed before teardown.
        SimulatorSharedMemoryProvider.sweepOrphans()
        // Every exit path from here — clean stop, a decode error return, an interrupted read — runs
        // teardown, so the shared-memory transport never leaks its mapped temp buffers. `stop()` is
        // idempotent.
        defer { stateQueue.sync { stop() } }

        do {
            var buffer = [UInt8](repeating: 0, count: Limits.readBytes)
            while !isStopped {
                if helperTerminationRequested != 0 { break }
                let count = buffer.withUnsafeMutableBytes { storage in
                    Darwin.read(inputDescriptor, storage.baseAddress, storage.count)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR {
                        if helperTerminationRequested != 0 { break }
                        continue
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let bytes = Data(buffer.prefix(count))
                switch decoder.accept(bytes) {
                case .refused:
                    writeControl(.failure(.malformedMessage, detail: "The helper wire frame is malformed."))
                    return 65
                case .frames(let frames):
                    for frame in frames {
                        guard frame.kind == .control else { return 65 }
                        guard let message = try? JSONDecoder().decode(
                            SimulatorBridgeClientMessage.self,
                            from: frame.payload
                        ) else { return 65 }
                        stateQueue.sync { handle(message) }
                    }
                }
            }
        } catch {
            fputs("threading-simulator-helper: socket read failed\n", stderr)
            return 74
        }
        return 0
    }

    private func handle(_ message: SimulatorBridgeClientMessage) {
        switch message {
        case .hello(let hello):
            guard !hasHello else {
                writeControl(.failure(.malformedMessage, detail: "A helper connection has one hello."))
                return
            }
            peerProtocolVersion = hello.protocolVersion
            hasHello = true
            establish(hello)

        case .setVisible(let visible):
            guard bridge != nil else { return }
            isVisible = visible
            if visible { startTimer() } else { stopTimer(clearPending: true) }

        case .acknowledgeFrame(let sequence):
            acknowledge(sequence)

        case .releaseSharedFrame(let bufferIndex):
            sharedProvider?.release(bufferIndex)

        case .input(let requestID, let command):
            guard let inputSender else {
                writeControl(.inputResult(requestID: requestID, error: "Direct Simulator input is unavailable."))
                return
            }
            guard !geometryChangedSinceNegotiation() else {
                writeControl(.inputResult(requestID: requestID, error: Self.geometryChangedDetail))
                return
            }
            inputQueue.async { [weak self] in
                do {
                    try inputSender.send(command)
                    self?.writeControl(.inputResult(requestID: requestID, error: nil))
                } catch {
                    self?.writeControl(.inputResult(
                        requestID: requestID,
                        error: error.localizedDescription
                    ))
                }
            }

        case .accessibilitySnapshot(let requestID):
            guard let bridge, let geometry = captureGeometry,
                  let orientation = SimulatorScreenOrientation(rawValue: geometry.orientation) else {
                writeControl(.accessibilitySnapshotResult(
                    requestID: requestID,
                    root: nil,
                    error: "The direct Simulator helper is not connected to a device."
                ))
                return
            }
            guard !geometryChangedSinceNegotiation() else {
                writeControl(.accessibilitySnapshotResult(requestID: requestID, root: nil,
                                                          error: Self.geometryChangedDetail))
                return
            }
            // Off the state queue: a cold read is 1–2 orders slower than a warm one, and the bridge
            // serializes every translator interaction on its own queue anyway.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let tree = try bridge.accessibilitySnapshot()
                    let live = SimulatorScreenOrientation(rawValue: bridge.screenUIOrientation) ?? orientation
                    guard live == orientation else {
                        self?.writeControl(.accessibilitySnapshotResult(requestID: requestID, root: nil,
                            error: "The Simulator screen rotated during the accessibility read. Retry the snapshot."))
                        return
                    }
                    let bounds = (tree["frame"] as? [NSNumber]).flatMap { $0.count == 4 ? $0 : nil }
                    let rootWidth = bounds?[2].doubleValue ?? 0
                    let rootHeight = bounds?[3].doubleValue ?? 0
                    guard let transform = orientation.accessibilityTransform(
                        rootWidth: rootWidth, rootHeight: rootHeight,
                        nativeWidth: Double(geometry.width), nativeHeight: Double(geometry.height)) else {
                        self?.writeControl(.accessibilitySnapshotResult(requestID: requestID, root: nil,
                            error: "The foreground app's accessibility frame does not cover the rotated "
                                + "Simulator screen, so its element positions cannot be mapped. "
                                + "Use simulator_screenshot coordinates instead."))
                        return
                    }
                    let sent = self?.writeControl(.accessibilitySnapshotResult(
                        requestID: requestID,
                        root: Self.element(from: tree, orientation: transform,
                                           nativeWidth: rootWidth, nativeHeight: rootHeight),
                        error: nil
                    ))
                    if sent == false {
                        // The serialized tree exceeded the control-frame cap. Dropping it would
                        // strand the app on a timeout with no reason, so answer with an explicit,
                        // always-small failure the app can surface and retry from.
                        self?.writeControl(.accessibilitySnapshotResult(
                            requestID: requestID,
                            root: nil,
                            error: "The accessibility tree is too large to return over the helper "
                                + "wire. Snapshot a smaller screen or a more specific element."
                        ))
                    }
                } catch {
                    self?.writeControl(.accessibilitySnapshotResult(
                        requestID: requestID,
                        root: nil,
                        error: error.localizedDescription
                    ))
                }
            }

        case .stop:
            stop()
        }
    }

    /// Convert the helper bridge's plain-dictionary tree into the wire value tree. Unknown or missing
    /// keys degrade to sensible defaults rather than failing the whole snapshot.
    private static func element(from node: [AnyHashable: Any], orientation: SimulatorScreenOrientation,
                                nativeWidth: Double, nativeHeight: Double) -> SimulatorAccessibilityElement {
        let frameArray = node["frame"] as? [Any] ?? []
        func number(_ index: Int) -> Double {
            guard index < frameArray.count, let value = frameArray[index] as? NSNumber else { return 0 }
            return value.doubleValue
        }
        let frame = orientation.uprightRect(x: number(0), y: number(1), width: number(2), height: number(3),
                                           nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        let children = (node["children"] as? [[AnyHashable: Any]] ?? []).map {
            element(from: $0, orientation: orientation, nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        }
        return SimulatorAccessibilityElement(
            role: node["role"] as? String ?? "AXUnknown",
            subrole: node["subrole"] as? String,
            label: node["label"] as? String,
            value: node["value"] as? String,
            identifier: node["identifier"] as? String,
            enabled: (node["enabled"] as? NSNumber)?.boolValue ?? true,
            frame: SimulatorAccessibilityElement.Frame(
                x: frame.x, y: frame.y, width: frame.width, height: frame.height
            ),
            children: children
        )
    }

    private func establish(_ hello: SimulatorBridgeHello) {
        guard SimulatorBridgeCompatibility.evaluate(
            peerVersion: hello.protocolVersion,
            peerMinimum: hello.minimumSupported
        ) == .compatible else {
            refuse(.incompatibleProtocol, detail: "The app and helper protocol versions do not overlap.")
            return
        }
        guard (Limits.minimumFramesPerSecond...Limits.maximumFramesPerSecond)
            .contains(hello.requestedFramesPerSecond) else {
            refuse(.malformedMessage, detail: "The requested frame rate is outside 1–60 fps.")
            return
        }
        let bridge: SimulatorPrivateBridge
        do {
            bridge = try SimulatorPrivateBridge(
                developerDirectory: hello.developerDirectory,
                deviceID: hello.deviceID
            )
        } catch {
            let refusal: SimulatorBridgeRefusal
            switch (error as NSError).code {
            case BridgeFailureCode.untrustedFramework:
                refusal = .untrustedFramework
            case BridgeFailureCode.invalidDeveloperDirectory:
                refusal = .invalidDeveloperDirectory
            case BridgeFailureCode.frameworkMissing, BridgeFailureCode.frameworkLoadFailed:
                refusal = .frameworkUnavailable
            case BridgeFailureCode.deviceUnavailable:
                refusal = .deviceUnavailable
            case BridgeFailureCode.apiUnavailable,
                 BridgeFailureCode.screenInitializationFailed,
                 BridgeFailureCode.framebufferUnavailable:
                refusal = .apiUnavailable
            default:
                refusal = .internalFailure
            }
            refuse(refusal, detail: error.localizedDescription)
            return
        }
        var firstSurface: IOSurface?
        let deadline = Date().addingTimeInterval(3)
        while firstSurface == nil, Date() < deadline {
            firstSurface = bridge.copyCurrentSurface()
            if firstSurface == nil { Thread.sleep(forTimeInterval: 0.025) }
        }
        guard let firstSurface else {
            refuse(.screenUnavailable, detail: "The adopted device did not publish a framebuffer surface.")
            return
        }
        // An Xcode that publishes no screen orientation streams in native axes, exactly as every
        // helper did before orientation was read at all.
        let orientation = SimulatorScreenOrientation(rawValue: bridge.screenUIOrientation) ?? .portrait

        // Prefer the shared-memory transport when the app can consume it: it copies each surface
        // into shared buffers with no codec, which is dramatically lower latency for the local
        // in-panel pane. It only works same-machine (BGRA surfaces mapped in another process); if
        // the surface format is not compatible the provider declines and we fall back to a codec.
        let capabilities = SimulatorBridgeCapabilities(
            codecs: [.h264, .jpeg],
            supportsTouch: bridge.supportsInput,
            supportsKeyboard: bridge.supportsInput,
            supportsButtons: bridge.supportsInput,
            maximumFramesPerSecond: Limits.maximumFramesPerSecond
        )
        if hello.supportsSharedMemory,
           let provider = SimulatorSharedMemoryProvider(surface: firstSurface, bufferCount: 3, orientation: orientation) {
            self.bridge = bridge
            self.sharedProvider = provider
            self.captureGeometry = CaptureGeometry(firstSurface, orientation: orientation.rawValue)
            self.inputSender = bridge.supportsInput ? SimulatorInputSender(bridge: bridge, orientation: orientation) : nil
            framesPerSecond = hello.requestedFramesPerSecond
            writeControl(.hello(SimulatorBridgeHelloReply(
                selectedCodec: nil,
                sharedSurface: provider.descriptor,
                capabilities: capabilities,
                refusal: nil,
                coreSimulatorVersion: bridge.coreSimulatorVersion,
                simulatorKitVersion: bridge.simulatorKitVersion,
                screenOrientation: orientation
            )))
            return
        }

        guard let oriented = SimulatorOrientedFrameSurface(surface: firstSurface, orientation: orientation) else {
            refuse(.screenUnavailable, detail: "The Simulator frame format cannot be displayed upright.")
            return
        }
        let size = SimulatorSurfaceRotation.dimensions(firstSurface, orientation: orientation)
        let selectedEncoder: (any SimulatorFrameEncoding)? = hello.preferredCodecs.compactMap {
            switch $0 {
            case .h264:
                return try? SimulatorH264FrameEncoder(
                    width: size.width,
                    height: size.height,
                    framesPerSecond: hello.requestedFramesPerSecond
                )
            case .jpeg:
                return SimulatorJPEGFrameEncoder()
            }
        }.first
        guard let selectedEncoder else {
            refuse(.codecUnavailable, detail: "No mutually supported Simulator frame codec is available.")
            return
        }

        self.bridge = bridge
        self.encoder = selectedEncoder
        self.orientedFrameSurface = oriented
        self.captureGeometry = CaptureGeometry(firstSurface, orientation: orientation.rawValue)
        self.inputSender = bridge.supportsInput ? SimulatorInputSender(bridge: bridge, orientation: orientation) : nil
        framesPerSecond = hello.requestedFramesPerSecond
        writeControl(.hello(SimulatorBridgeHelloReply(
            selectedCodec: selectedEncoder.codec,
            capabilities: capabilities,
            refusal: nil,
            coreSimulatorVersion: bridge.coreSimulatorVersion,
            simulatorKitVersion: bridge.simulatorKitVersion,
            screenOrientation: orientation
        )))
    }

    private func refuse(_ refusal: SimulatorBridgeRefusal, detail: String) {
        writeControl(.hello(SimulatorBridgeHelloReply(
            selectedCodec: nil,
            capabilities: nil,
            refusal: refusal,
            coreSimulatorVersion: bridge?.coreSimulatorVersion,
            simulatorKitVersion: bridge?.simulatorKitVersion
        )))
    }

    private func startTimer() {
        guard isVisible, !isGeometryChanging, timer == nil, bridge != nil,
              encoder != nil || sharedProvider != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(1_000_000_000 / framesPerSecond),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in self?.capture() }
        self.timer = timer
        timer.resume()
    }

    private func stopTimer(clearPending: Bool) {
        timer?.cancel()
        timer = nil
        if clearPending {
            frameWindow.clear()
        }
    }

    /// Ends capture once for a confirmed geometry change. The app renegotiates this same lease;
    /// ordinary failures continue through the fallback path.
    private func endStreamIfGeometryChanged(_ surface: IOSurface) -> Bool {
        guard let captureGeometry, let bridge,
              captureGeometry != CaptureGeometry(surface, orientation: liveOrientation(of: bridge, negotiated: captureGeometry))
        else { return false }
        guard !isGeometryChanging else { return true }
        isGeometryChanging = true
        stopTimer(clearPending: true)
        let sender = inputSender
        inputQueue.async { [weak self] in
            sender?.stop()
            self?.stateQueue.async { [weak self] in
                guard let self else { return }
                if self.peerProtocolVersion >= 4 {
                    self.writeControl(.geometryChanged)
                } else {
                    self.writeControl(.failure(.internalFailure, detail: "The Simulator surface size changed; retry at the new size."))
                }
                self.stop()
            }
        }
        return true
    }

    /// A transient unreadable orientation (0) is not a rotation; keep the negotiated axes.
    private func liveOrientation(of bridge: SimulatorPrivateBridge, negotiated: CaptureGeometry) -> Int {
        SimulatorScreenOrientation(rawValue: bridge.screenUIOrientation)?.rawValue ?? negotiated.orientation
    }

    /// The capture loop only runs while frames are wanted. A stream opened for an agent while its
    /// pane is hidden still carries input and element reads, so those check the geometry too:
    /// otherwise a rotation goes unnoticed, input is mapped through stale axes and every
    /// accessibility read is refused without anything ever renegotiating.
    private func geometryChangedSinceNegotiation() -> Bool {
        if isGeometryChanging { return true }
        guard let surface = bridge?.copyCurrentSurface() else { return false }
        return endStreamIfGeometryChanged(surface)
    }

    private func capture() {
        guard isVisible, let bridge else { return }
        if let sharedProvider {
            guard let surface = bridge.copyCurrentSurface() else { return }
            if endStreamIfGeometryChanged(surface) { return }
            guard let bufferIndex = sharedProvider.write(surface: surface) else {
                // Every buffer is still held by the app; drop this capture (latest-frame-wins).
                statistics = SimulatorBridgeStatistics(
                    capturedFrames: statistics.capturedFrames + 1,
                    sentFrames: statistics.sentFrames,
                    replacedFrames: statistics.replacedFrames + 1,
                    encodedBytes: statistics.encodedBytes
                )
                return
            }
            let sequence = nextSequence
            nextSequence &+= 1
            statistics = SimulatorBridgeStatistics(
                capturedFrames: statistics.capturedFrames + 1,
                sentFrames: statistics.sentFrames + 1,
                replacedFrames: statistics.replacedFrames,
                encodedBytes: statistics.encodedBytes
            )
            writeControl(.sharedFrameReady(
                bufferIndex: bufferIndex,
                sequence: sequence,
                presentationTimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ))
            return
        }
        guard !isEncoding, let encoder,
              let surface = bridge.copyCurrentSurface() else { return }
        if endStreamIfGeometryChanged(surface) { return }
        guard let normalized = orientedFrameSurface?.normalized(surface) else {
            writeControl(.failure(.internalFailure, detail: "The Simulator frame could not be displayed upright."))
            stop()
            return
        }
        isEncoding = true
        let sequence = nextSequence
        nextSequence &+= 1
        let timestamp = DispatchTime.now().uptimeNanoseconds
        statistics = SimulatorBridgeStatistics(
            capturedFrames: statistics.capturedFrames + 1,
            sentFrames: statistics.sentFrames,
            replacedFrames: statistics.replacedFrames,
            encodedBytes: statistics.encodedBytes
        )
        encoder.encode(
            surface: normalized,
            sequence: sequence,
            presentationTimeNanoseconds: timestamp
        ) { [weak self] result in
            guard let self else { return }
            self.stateQueue.async { [weak self] in
                guard let self else { return }
                self.isEncoding = false
                guard self.isVisible else { return }
                switch result {
                case .success(let frame): self.offer(frame)
                case .failure(let error):
                    self.writeControl(.failure(.internalFailure, detail: error.localizedDescription))
                    self.stopTimer(clearPending: true)
                }
            }
        }
    }

    private func offer(_ frame: SimulatorBridgeMediaFrame) {
        switch frameWindow.offer(frame, sequence: frame.sequence) {
        case .send:
            send(frame)
        case .held(let replaced):
            statistics = SimulatorBridgeStatistics(
                capturedFrames: statistics.capturedFrames,
                sentFrames: statistics.sentFrames,
                replacedFrames: statistics.replacedFrames + (replaced ? 1 : 0),
                encodedBytes: statistics.encodedBytes
            )
        }
    }

    private func acknowledge(_ sequence: UInt64) {
        if let pending = frameWindow.acknowledge(sequence: sequence) { send(pending) }
    }

    private func send(_ frame: SimulatorBridgeMediaFrame) {
        guard let payload = try? frame.encode(),
              let framed = try? SimulatorBridgeFraming.encode(kind: .media, payload: payload) else {
            writeControl(.failure(.internalFailure, detail: "An encoded Simulator frame exceeded its wire budget."))
            stopTimer(clearPending: true)
            return
        }
        statistics = SimulatorBridgeStatistics(
            capturedFrames: statistics.capturedFrames,
            sentFrames: statistics.sentFrames + 1,
            replacedFrames: statistics.replacedFrames,
            encodedBytes: statistics.encodedBytes + UInt64(frame.bytes.count)
        )
        outputQueue.async { [outputDescriptor] in
            do { try Self.writeAll(framed, to: outputDescriptor) }
            catch { fputs("threading-simulator-helper: socket write failed\n", stderr) }
        }
        if statistics.sentFrames.isMultiple(of: UInt64(max(1, framesPerSecond * 5))) {
            writeControl(.statistics(statistics))
        }
    }

    /// Returns false when the message could not even be framed — chiefly because its payload
    /// exceeds the control-frame cap. Callers that would otherwise leave the app waiting on a
    /// dropped reply use this to send a smaller, explicit failure in its place.
    @discardableResult
    private func writeControl(_ message: SimulatorBridgeHelperMessage) -> Bool {
        guard let payload = try? JSONEncoder().encode(message),
              let frame = try? SimulatorBridgeFraming.encode(kind: .control, payload: payload) else {
            return false
        }
        outputQueue.async { [outputDescriptor] in
            try? Self.writeAll(frame, to: outputDescriptor)
        }
        return true
    }

    private func stop() {
        guard !isStopped else { return }
        isStopped = true
        inputSender?.stop()
        isVisible = false
        stopTimer(clearPending: true)
        encoder?.finish()
        encoder = nil
        sharedProvider?.teardown()
        sharedProvider = nil
        writeControl(.statistics(statistics))
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
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
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }
}
