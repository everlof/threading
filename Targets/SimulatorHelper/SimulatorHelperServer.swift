import Foundation
import IOSurface
import ThreadingSimulatorKit

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

    private let input = FileHandle.standardInput
    private let output = FileHandle.standardOutput
    private let stateQueue = DispatchQueue(label: "codes.threading.simulator-helper.state")
    private let outputQueue = DispatchQueue(label: "codes.threading.simulator-helper.output")
    private let inputQueue = DispatchQueue(label: "codes.threading.simulator-helper.input")
    private var decoder = SimulatorBridgeFrameDecoder()
    private var bridge: SimulatorPrivateBridge?
    private var inputSender: SimulatorInputSender?
    private var encoder: (any SimulatorFrameEncoding)?
    private var framesPerSecond = 30
    private var timer: DispatchSourceTimer?
    private var nextSequence: UInt64 = 1
    private var isEncoding = false
    private var frameWindow = SimulatorLatestFrameWindow<SimulatorBridgeMediaFrame>()
    private var statistics = SimulatorBridgeStatistics(
        capturedFrames: 0,
        sentFrames: 0,
        replacedFrames: 0,
        encodedBytes: 0
    )
    private var hasHello = false
    private var isVisible = false
    private var isStopped = false

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

        do {
            while !isStopped, let bytes = try input.read(upToCount: Limits.readBytes), !bytes.isEmpty {
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
        stateQueue.sync { stop() }
        return 0
    }

    private func handle(_ message: SimulatorBridgeClientMessage) {
        switch message {
        case .hello(let hello):
            guard !hasHello else {
                writeControl(.failure(.malformedMessage, detail: "A helper connection has one hello."))
                return
            }
            hasHello = true
            establish(hello)

        case .setVisible(let visible):
            guard bridge != nil else { return }
            isVisible = visible
            if visible { startTimer() } else { stopTimer(clearPending: true) }

        case .acknowledgeFrame(let sequence):
            acknowledge(sequence)

        case .input(let requestID, let command):
            guard let inputSender else {
                writeControl(.inputResult(requestID: requestID, error: "Direct Simulator input is unavailable."))
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

        case .stop:
            stop()
        }
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

        let selectedEncoder: (any SimulatorFrameEncoding)? = hello.preferredCodecs.compactMap {
            switch $0 {
            case .h264:
                return try? SimulatorH264FrameEncoder(
                    width: IOSurfaceGetWidth(firstSurface),
                    height: IOSurfaceGetHeight(firstSurface),
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
        self.inputSender = bridge.supportsInput ? SimulatorInputSender(bridge: bridge) : nil
        framesPerSecond = hello.requestedFramesPerSecond
        writeControl(.hello(SimulatorBridgeHelloReply(
            selectedCodec: selectedEncoder.codec,
            capabilities: SimulatorBridgeCapabilities(
                codecs: [.h264, .jpeg],
                supportsTouch: bridge.supportsInput,
                supportsKeyboard: bridge.supportsInput,
                supportsButtons: bridge.supportsInput,
                maximumFramesPerSecond: Limits.maximumFramesPerSecond
            ),
            refusal: nil,
            coreSimulatorVersion: bridge.coreSimulatorVersion,
            simulatorKitVersion: bridge.simulatorKitVersion
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
        guard isVisible, timer == nil, bridge != nil, encoder != nil else { return }
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

    private func capture() {
        guard isVisible, !isEncoding, let bridge, let encoder,
              let surface = bridge.copyCurrentSurface() else { return }
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
            surface: surface,
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
        outputQueue.async { [output] in
            do { try output.write(contentsOf: framed) }
            catch { fputs("threading-simulator-helper: socket write failed\n", stderr) }
        }
        if statistics.sentFrames.isMultiple(of: UInt64(max(1, framesPerSecond * 5))) {
            writeControl(.statistics(statistics))
        }
    }

    private func writeControl(_ message: SimulatorBridgeHelperMessage) {
        guard let payload = try? JSONEncoder().encode(message),
              let frame = try? SimulatorBridgeFraming.encode(kind: .control, payload: payload) else {
            return
        }
        outputQueue.async { [output] in try? output.write(contentsOf: frame) }
    }

    private func stop() {
        guard !isStopped else { return }
        isStopped = true
        isVisible = false
        stopTimer(clearPending: true)
        encoder?.finish()
        encoder = nil
        writeControl(.statistics(statistics))
    }
}
