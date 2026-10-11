import CoreGraphics
import Foundation
import os
import ThreadingAndroidKit
import ThreadingSimulatorKit

/// A live Android device through `adb` alone — the only route to a USB phone, and the fallback for
/// an emulator whose gRPC service is off or refused. `screenrecord` streams the device's own H.264
/// into the same VideoToolbox decoder the iOS helper's frames use; input is `adb shell input`.
///
/// `screenrecord` emits a picture only when the screen changes, so silence is not a stall: health
/// is the recorder process staying alive and the device answering the orientation poll.
final class AndroidScreenRecordStreamSession: SimulatorLiveStreamSession, @unchecked Sendable {
    let events: AsyncStream<SimulatorLiveStreamEvent>
    var screenOrientation: SimulatorScreenOrientation? { nil }

    private let continuation: AsyncStream<SimulatorLiveStreamEvent>.Continuation
    private let target: AndroidTarget
    private let sdk: AndroidSDK
    private let apiLevel: Int
    private let naturalWidth: Int
    private let naturalHeight: Int
    private let onStop: @Sendable () -> Void
    private let decoder = SimulatorFrameDecoder()
    private let readQueue = DispatchQueue(label: "codes.threading.android-screenrecord", qos: .userInteractive)
    private let input = AndroidInputSequencer()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var monitorTask: Task<Void, Never>?

    private struct State {
        var stopped = false
        var visible = false
        var recorder: SpawnedChildProcess?
        var recorderGeneration = 0
        var restarts: [Date] = []
        var orientation = 0
        var sequence: UInt64 = 0
        var holding = false
        var lastPoint: (x: Int, y: Int)?
    }

    static func open(target: AndroidTarget, sdk: AndroidSDK, onStop: @escaping @Sendable () -> Void) async throws -> AndroidScreenRecordStreamSession {
        let properties = try await AndroidADBCommand.run(
            adb: sdk.adb, arguments: ["-s", target.serial, "shell", "getprop ro.build.version.sdk; wm size; " + orientationProbe],
            timeout: AndroidControlDefaults.propertyTimeout
        )
        let lines = String(decoding: properties, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        guard let api = lines.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              let size = AndroidGeometry.parseWindowSize(lines.joined(separator: "\n")) else {
            throw SimulatorLiveStreamError.helperUnavailable("The Android device did not report its display.")
        }
        guard api >= AndroidStreamDefaults.screenRecordMinimumAPI else {
            throw SimulatorLiveStreamError.helperUnavailable(
                "Live Android streaming needs Android 10 or later; this device shows still screenshots."
            )
        }
        let session = AndroidScreenRecordStreamSession(
            target: target, sdk: sdk, apiLevel: api, naturalWidth: size.width, naturalHeight: size.height, onStop: onStop
        )
        session.state.withLock { $0.orientation = parseOrientation(lines) ?? 0 }
        session.start()
        return session
    }

    private static let orientationProbe = "dumpsys display | grep -m1 -o 'mCurrentOrientation=[0-9]'"

    static func parseOrientation(_ lines: [String]) -> Int? {
        lines.lazy.compactMap { line -> Int? in
            guard let range = line.range(of: "mCurrentOrientation=") else { return nil }
            return Int(line[range.upperBound...].prefix(1))
        }.first
    }

    private init(target: AndroidTarget, sdk: AndroidSDK, apiLevel: Int, naturalWidth: Int, naturalHeight: Int,
                 onStop: @escaping @Sendable () -> Void) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.target = target
        self.sdk = sdk
        self.apiLevel = apiLevel
        self.naturalWidth = naturalWidth
        self.naturalHeight = naturalHeight
        self.onStop = onStop
    }

    private func start() {
        continuation.yield(.ready(
            backend: .android(.screenRecord), capabilities: .android, coreSimulatorVersion: nil, simulatorKitVersion: nil
        ))
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(AndroidStreamDefaults.pingInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.pollOrientation()
            }
        }
    }

    /// The display's current size in its present orientation — what `input` coordinates address.
    private var displaySize: (width: Int, height: Int) {
        let quarter = state.withLock { $0.orientation } % 2 == 1
        return quarter ? (naturalHeight, naturalWidth) : (naturalWidth, naturalHeight)
    }

    // MARK: - SimulatorLiveStreamSession

    func setVisible(_ visible: Bool) {
        let recorder: SpawnedChildProcess? = state.withLock { state in
            guard !state.stopped, state.visible != visible else { return nil }
            state.visible = visible
            guard !visible else { return nil }
            state.recorderGeneration += 1
            defer { state.recorder = nil }
            return state.recorder
        }
        recorder?.terminate()
        if visible { startRecorder() }
    }

    func sendInput(_ input: SimulatorBridgeInput) async throws {
        try await self.input.perform { try await self.deliver(input) }
    }

    func streamInput(_ input: SimulatorBridgeInput) {
        if case .touch(.moved, _, _) = input {
            self.input.coalesce { try await self.deliver(input) }
        } else {
            Task { try? await self.input.perform { try await self.deliver(input) } }
        }
    }

    func requestAccessibilitySnapshot() async throws -> SimulatorAccessibilityElement {
        try await AndroidAccessibilityReader.snapshot(adb: sdk.adb, serial: target.serial)
    }

    func stop() { finish(nil) }

    // MARK: - Recorder

    private func startRecorder() {
        let display = displaySize
        let (width, height) = AndroidGeometry.cappedSize(width: display.width, height: display.height)
        var arguments = ["-s", target.serial, "exec-out", "screenrecord", "--output-format=h264",
                         "--size", "\(width)x\(height)", "--bit-rate", AndroidStreamDefaults.screenRecordBitRate]
        arguments += ["--time-limit", apiLevel >= AndroidStreamDefaults.screenRecordUnlimitedAPI
                      ? "0" : String(AndroidStreamDefaults.screenRecordSegmentSeconds)]
        arguments.append("-")

        let pipe: ChildPipe
        let process: SpawnedChildProcess
        do {
            pipe = try ChildPipe()
            process = try ChildProcessSpawn.spawn(
                executableURL: sdk.adb, arguments: arguments, environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil,
                descriptors: [
                    AgentChildProcessDefaults.standardInputDescriptor: .nullDevice,
                    AgentChildProcessDefaults.standardOutputDescriptor: .inherited(pipe.writeEnd),
                    AgentChildProcessDefaults.standardErrorDescriptor: .nullDevice,
                ]
            )
        } catch {
            finish(.failed(L10n.string("Couldn’t start the Android screen stream.")))
            return
        }
        pipe.closeWriteEnd()
        let generation: Int? = state.withLock { state in
            guard state.visible, !state.stopped else { return nil }
            state.recorderGeneration += 1
            state.recorder = process
            return state.recorderGeneration
        }
        guard let generation else {
            process.terminate()
            pipe.closeReadEnd()
            return
        }
        read(pipe.takeReadDescriptor(), generation: generation, width: width, height: height)
        process.observeExit { [weak self] _ in self?.recorderExited(generation: generation) }
    }

    private func read(_ descriptor: Int32, generation: Int, width: Int, height: Int) {
        var parser = AnnexBStream()
        var configuration = Data()
        var flushWork: DispatchWorkItem?
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 256 * 1024, alignment: 16)

        let submit: ([H264AccessUnit]) -> Void = { [weak self] units in
            guard let self else { return }
            for unit in units {
                if unit.parameterSetsChanged, let sps = unit.sequenceParameterSet, let pps = unit.pictureParameterSet {
                    configuration = (try? SimulatorBridgeH264Configuration.encode(
                        sequenceParameterSet: Data(sps), pictureParameterSet: Data(pps)
                    )) ?? Data()
                }
                self.decode(unit, configuration: unit.parameterSetsChanged ? configuration : Data(), width: width, height: height)
            }
        }
        source.setEventHandler { [weak self] in
            let count = Darwin.read(descriptor, buffer, 256 * 1024)
            guard count > 0 else {
                source.cancel()
                return
            }
            guard let self, self.state.withLock({ $0.recorderGeneration == generation && !$0.stopped }) else {
                source.cancel()
                return
            }
            do {
                submit(try parser.append(Array(UnsafeRawBufferPointer(start: buffer, count: count))))
            } catch {
                source.cancel()
                self.finish(.failed(L10n.string("The Android screen stream sent an unreadable picture.")))
                return
            }
            // The last picture of a burst has no following start code; declare it complete once
            // the pipe has been quiet briefly.
            flushWork?.cancel()
            let work = DispatchWorkItem { submit(parser.flush()) }
            flushWork = work
            self.readQueue.asyncAfter(deadline: .now() + AndroidStreamDefaults.annexBFlushDelay, execute: work)
        }
        source.setCancelHandler {
            flushWork?.cancel()
            buffer.deallocate()
            close(descriptor)
        }
        source.resume()
    }

    private func decode(_ unit: H264AccessUnit, configuration: Data, width: Int, height: Int) {
        let sequence = state.withLock { state -> UInt64 in
            state.sequence += 1
            return state.sequence
        }
        let frame = SimulatorBridgeMediaFrame(
            sequence: sequence, presentationTimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            width: UInt32(width), height: UInt32(height), codec: .h264, isKeyFrame: unit.isKeyFrame,
            codecConfiguration: configuration, bytes: Data(unit.avcc)
        )
        decoder.decode(frame) { [weak self] result in
            guard let self, case .success(let decoded) = result, !self.state.withLock({ $0.stopped }) else { return }
            self.continuation.yield(.frame(decoded))
        }
    }

    /// Before Android 14 `screenrecord` ends itself at its time limit; a visible stream starts the
    /// next segment. Repeated early exits are a failure, not a loop.
    private func recorderExited(generation: Int) {
        let restart: Bool? = state.withLock { state in
            guard !state.stopped, state.recorderGeneration == generation, state.visible else { return nil }
            state.recorder = nil
            let now = Date()
            state.restarts = state.restarts.filter { now.timeIntervalSince($0) < 60 } + [now]
            return state.restarts.count <= AndroidStreamDefaults.maximumScreenRecordRestartsPerMinute
        }
        switch restart {
        case true?: startRecorder()
        case false?: finish(.failed(L10n.string("The Android screen stream keeps stopping.")))
        case nil: break
        }
    }

    private func pollOrientation() async {
        do {
            let output = try await AndroidADBCommand.run(
                adb: sdk.adb, arguments: ["-s", target.serial, "shell", Self.orientationProbe],
                timeout: AndroidControlDefaults.propertyTimeout
            )
            let lines = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            guard let orientation = Self.parseOrientation(lines) else { return }
            let changed = state.withLock { state -> Bool in
                defer { state.orientation = orientation }
                return state.orientation != orientation
            }
            // The recorder's size was fixed for the old orientation; the pane opens a fresh stream.
            if changed { finish(.geometryChanged) }
        } catch is CancellationError {
            return
        } catch {
            finish(.failed(L10n.string("The Android device stopped answering.")))
        }
    }

    // MARK: - Input

    private func pixel(_ x: Double, _ y: Double) -> (Int, Int) {
        let size = displaySize
        return (Int((min(max(x, 0), 1) * Double(size.width - 1)).rounded()),
                Int((min(max(y, 0), 1) * Double(size.height - 1)).rounded()))
    }

    private func shell(_ command: String) async throws {
        _ = try await AndroidADBCommand.run(adb: sdk.adb, arguments: ["-s", target.serial, "shell", command],
                                            timeout: AndroidControlDefaults.launchTimeout)
    }

    private func deliver(_ input: SimulatorBridgeInput) async throws {
        guard !state.withLock({ $0.stopped }) else { throw SimulatorLiveStreamError.disconnected }
        switch input {
        case .tap(let x, let y):
            let point = pixel(x, y)
            try await shell("input tap \(point.0) \(point.1)")
        case .drag(let fromX, let fromY, let toX, let toY, let duration):
            let from = pixel(fromX, fromY), to = pixel(toX, toY)
            try await shell("input swipe \(from.0) \(from.1) \(to.0) \(to.1) \(max(1, duration))")
        case .touch(let phase, let x, let y):
            let point = pixel(x, y)
            switch phase {
            case .began:
                state.withLock { $0.holding = true; $0.lastPoint = point }
                try await shell("input motionevent DOWN \(point.0) \(point.1)")
            case .moved:
                guard state.withLock({ $0.holding }) else { return }
                state.withLock { $0.lastPoint = point }
                try await shell("input motionevent MOVE \(point.0) \(point.1)")
            case .ended:
                state.withLock { $0.holding = false; $0.lastPoint = nil }
                try await shell("input motionevent UP \(point.0) \(point.1)")
            case .cancelled:
                guard let held = state.withLock({ state -> (x: Int, y: Int)? in
                    defer { state.holding = false; state.lastPoint = nil }
                    return state.holding ? state.lastPoint : nil
                }) else { return }
                try await shell("input motionevent UP \(held.x) \(held.y)")
            }
        case .text(let text):
            guard text.count <= AndroidStreamDefaults.maximumTextCharacters else {
                throw SimulatorLiveStreamError.helperUnavailable("Android text is limited to 1,024 characters per call.")
            }
            // `input text` reads %s as a space; everything else goes through the device shell quoted.
            try await shell("input text " + AndroidShellQuoting.quote(text.replacingOccurrences(of: " ", with: "%s")))
        case .button(let button):
            switch button {
            case .rotateLeft, .rotateRight:
                throw SimulatorLiveStreamError.helperUnavailable("Rotate this device by turning it.")
            default:
                guard let key = AndroidButtonMapping.keyEvents[button] else {
                    throw SimulatorLiveStreamError.helperUnavailable("An Android device has no \(button.rawValue) button.")
                }
                try await shell("input keyevent \(key)")
            }
        }
    }

    // MARK: - Lifecycle

    private func finish(_ event: SimulatorLiveStreamEvent?) {
        let (first, recorder, held): (Bool, SpawnedChildProcess?, (x: Int, y: Int)?) = state.withLock { state in
            guard !state.stopped else { return (false, nil, nil) }
            state.stopped = true
            state.recorderGeneration += 1
            defer { state.recorder = nil; state.holding = false }
            return (true, state.recorder, state.holding ? state.lastPoint : nil)
        }
        guard first else { return }
        recorder?.terminate()
        monitorTask?.cancel()
        if let held {
            let adb = sdk.adb, serial = target.serial
            Task { _ = try? await AndroidADBCommand.run(adb: adb, arguments: ["-s", serial, "shell", "input motionevent UP \(held.x) \(held.y)"],
                                                        timeout: AndroidControlDefaults.propertyTimeout) }
        }
        decoder.invalidate()
        if let event { continuation.yield(event) }
        continuation.finish()
        onStop()
    }
}
