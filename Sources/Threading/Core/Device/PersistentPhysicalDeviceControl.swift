import Darwin
import Foundation
import os

/// One demand-driven preview pipe and one consent-driven input pipe. Frames never queue:
/// the caller requests its next frame only after publishing the last one. Input has its own
/// worker, so a capture cannot delay a release. No network listener exists; keyboard reports
/// cross the private pipe as bounded HID usages rather than typed text.
final class PersistentPhysicalDeviceControl: PhysicalDeviceControlling, @unchecked Sendable {
    private let fallback: any PhysicalDeviceControlling
    private let preview: PhysicalDeviceSessionPipe
    private let input: PhysicalDeviceSessionPipe
    private let legacyPreview = OSAllocatedUnfairLock(initialState: false)

    init(fallback: any PhysicalDeviceControlling = DevicectlPhysicalDeviceControl()) {
        self.fallback = fallback
        preview = PhysicalDeviceSessionPipe(lane: "preview")
        input = PhysicalDeviceSessionPipe(lane: "control")
    }

    var supportsLiveTouch: Bool { true }
    var supportsKeyboardInput: Bool { true }
    var frameInterval: Duration { legacyPreview.withLock { $0 ? .seconds(1) : .milliseconds(100) } }

    func availableDevices() async throws -> [PhysicalDevice] { try await fallback.availableDevices() }
    func controlSupport(of device: PhysicalDevice) async throws -> PhysicalDeviceControlSupport {
        try await fallback.controlSupport(of: device)
    }
    func prepareControl(of device: PhysicalDevice) async throws { try await fallback.prepareControl(of: device) }
    func preparePreview(of device: PhysicalDevice) async throws { try await fallback.preparePreview(of: device) }
    func beginInput(of device: PhysicalDevice) async throws { _ = try await input.request("ready", device: device.id) }

    func screenshot(of device: PhysicalDevice) async throws -> Data {
        if (Int(device.osVersion.split(separator: ".").first ?? "0") ?? 0) < 17 {
            legacyPreview.withLock { $0 = true }
            return try await fallback.screenshot(of: device)
        }
        let data: Data
        do {
            data = try await preview.request("frame", device: device.id)
        } catch PhysicalDeviceControlError.screenshotToolUnavailable {
            // Keep the pre-existing libimobiledevice route usable on older phones when the
            // optional modern tooling is absent. Transport failures must not silently retry.
            legacyPreview.withLock { $0 = true }
            return try await fallback.screenshot(of: device)
        }
        guard data.starts(with: PhysicalDeviceDefaults.pngSignature) else {
            throw PhysicalDeviceControlError.invalidScreenshot
        }
        legacyPreview.withLock { $0 = false }
        return data
    }

    func sendInput(_ event: PhysicalDeviceInput, to device: PhysicalDevice) async throws {
        func send(_ phase: String, _ x: Double, _ y: Double) async throws {
            let command = try PhysicalDeviceSessionPipe.touchCommand(phase, x: x, y: y)
            _ = try await input.request(command, device: device.id)
        }
        switch event {
        case .tap(let x, let y):
            try await send("down", x, y)
            try await Task.sleep(for: .milliseconds(40))
            try await send("up", x, y)
        case .touchDown(let x, let y): try await send("down", x, y)
        case .touchMove(let x, let y): try await send("move", x, y)
        case .touchUp(let x, let y): try await send("up", x, y)
        case .key(let usage, let shift):
            guard usage < 240 else { throw PhysicalDeviceControlError.invalidInput }
            _ = try await input.request(
                "key \(usage) \(shift ? 1 : 0)",
                device: device.id
            )
        case .drag:
            // The persistent path consumes live phases, never replays a completed mouse drag.
            throw PhysicalDeviceControlError.invalidInput
        }
    }

    func stopPreview() {
        preview.stop()
        fallback.stopPreview()
    }
    func stopInput() { input.stop() }
}

/// All pipe/file/process operations belong to `worker`. The lock protects only the active
/// child and epoch, letting revocation interrupt a blocked read without waiting for that queue.
final class PhysicalDeviceSessionPipe: @unchecked Sendable {
    private struct State {
        var epoch = 0
        var child: SpawnedChildProcess?
        var escalation: ChildProcessEscalation?
    }
    private struct Connection {
        let device: PhysicalDeviceID
        let epoch: Int
        let child: SpawnedChildProcess
        let writer: FileHandle
        let reader: FileHandle
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let worker: SimulatorCommandQueue
    private let queue: DispatchQueue
    private let lane: String
    private let launch: @Sendable (PhysicalDeviceID, String) throws -> (URL, [String], [String: String])
    private var connection: Connection?

    init(
        lane: String,
        launch: @escaping @Sendable (PhysicalDeviceID, String) throws -> (URL, [String], [String: String]) = {
            try PhysicalDeviceSessionPipe.launch(device: $0, lane: $1)
        }
    ) {
        self.lane = lane
        self.launch = launch
        let queue = DispatchQueue(
            label: "codes.threading.physical-device.\(lane)", qos: .userInitiated
        )
        self.queue = queue
        worker = SimulatorCommandQueue(queue: queue)
    }

    deinit {
        // FileHandle closes its owned descriptors. Escalation owns teardown beyond this lifetime.
        if let child = connection?.child, child.isRunning { _ = ChildProcessEscalation(child: child) }
    }

    func stop() { invalidate(epoch: nil) }

    private func invalidate(epoch: Int?) {
        state.withLock { state in
            guard epoch == nil || epoch == state.epoch else { return }
            state.epoch += 1
            if let child = state.child, child.isRunning {
                state.escalation = ChildProcessEscalation(child: child)
            }
            state.child = nil
        }
        queue.async { [weak self] in
            guard let self, let connection = self.connection,
                  self.state.withLock({ $0.epoch != connection.epoch }) else { return }
            try? connection.writer.close()
            try? connection.reader.close()
            self.connection = nil
        }
    }

    func request(_ command: String, device: PhysicalDeviceID) async throws -> Data {
        let epoch = state.withLock { $0.epoch }
        let cancellation = SimulatorCommandCancellation()
        return try await withTaskCancellationHandler {
            try await worker.perform { [self] in
                guard !cancellation.isCancelled, state.withLock({ $0.epoch == epoch }) else {
                    throw PhysicalDeviceControlError.cancelled
                }
                let connection = try connect(device: device, epoch: epoch)
                cancellation.attach(connection.child)
                let deadline = ChildProcessDeadline(
                    child: connection.child, timeout: PhysicalDeviceDefaults.inputTimeout,
                    terminationGrace: BoundedChildDefaults.terminationGrace
                )
                defer { _ = deadline.complete(); cancellation.complete() }
                do {
                    try connection.writer.write(contentsOf: Data((command + "\n").utf8))
                    let header = try Self.readExactly(4, from: connection.reader)
                    let size = header.reduce(0) { ($0 << 8) | Int($1) }
                    guard size > 0, size <= PhysicalDeviceDefaults.maximumScreenshotBytes + 1 else {
                        throw PhysicalDeviceControlError.outputTooLarge(operation: "session")
                    }
                    let response = try Self.readExactly(size, from: connection.reader)
                    guard !cancellation.isCancelled, state.withLock({ $0.epoch == epoch }) else {
                        throw PhysicalDeviceControlError.cancelled
                    }
                    guard response.first == 0 else {
                        throw PhysicalDeviceControlError.invalidResponse("The iPhone session ended. Unlock the phone and retry.")
                    }
                    return Data(response.dropFirst())
                } catch {
                    invalidate(epoch: epoch)
                    throw error
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func connect(device: PhysicalDeviceID, epoch: Int) throws -> Connection {
        if let connection, connection.device == device, connection.epoch == epoch, connection.child.isRunning {
            return connection
        }
        if let connection {
            if connection.child.isRunning { _ = ChildProcessEscalation(child: connection.child) }
            try? connection.writer.close()
            try? connection.reader.close()
            self.connection = nil
        }
        let (executable, arguments, environment) = try launch(device, lane)
        let incoming = try ChildPipe()
        let outgoing = try ChildPipe(closingOnFailure: [incoming])
        defer { incoming.closeBothEnds(); outgoing.closeBothEnds() }
        guard fcntl(incoming.writeEnd, F_SETNOSIGPIPE, 1) != -1 else {
            throw PhysicalDeviceControlError.invalidResponse("The iPhone session pipe could not be opened.")
        }
        let child = try ChildProcessSpawn.spawn(
            executableURL: executable, arguments: arguments, environment: environment,
            workingDirectory: nil, descriptors: [
                AgentChildProcessDefaults.standardInputDescriptor: .inherited(incoming.readEnd),
                AgentChildProcessDefaults.standardOutputDescriptor: .inherited(outgoing.writeEnd),
                AgentChildProcessDefaults.standardErrorDescriptor: .nullDevice,
            ]
        )
        incoming.closeReadEnd()
        outgoing.closeWriteEnd()
        let made = Connection(device: device, epoch: epoch, child: child,
                              writer: incoming.takeWriteHandle(), reader: outgoing.takeReadHandle())
        connection = made
        state.withLock { state in
            if state.epoch == epoch { state.child = child }
            else { state.escalation = ChildProcessEscalation(child: child) }
        }
        return made
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            let part = try autoreleasepool { try handle.read(upToCount: min(64 * 1024, count - bytes.count)) }
            guard let part, !part.isEmpty else {
                throw PhysicalDeviceControlError.invalidResponse("The iPhone session disconnected. Retry to reconnect.")
            }
            bytes.append(part)
        }
        return bytes
    }

    static func touchCommand(_ phase: String, x: Double, y: Double) throws -> String {
        guard ["down", "move", "up"].contains(phase), x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y) else { throw PhysicalDeviceControlError.invalidInput }
        let maximum = Double(PhysicalDeviceDefaults.hidCoordinateMaximum)
        return "\(phase) \(Int((x * maximum).rounded())) \(Int((y * maximum).rounded()))"
    }

    static func launch(device: PhysicalDeviceID, lane: String) throws -> (URL, [String], [String: String]) {
        guard let tool = PhysicalDeviceToolLocator.pymobiledevice3(),
              let helper = Bundle.main.url(forResource: "physical_device_session.py", withExtension: "txt") else {
            throw PhysicalDeviceControlError.screenshotToolUnavailable
        }
        let python = tool.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw PhysicalDeviceControlError.screenshotToolUnavailable
        }
        var environment = try Pymobiledevice3RuntimeEnvironment.prepare(inherited: ProcessInfo.processInfo.environment)
        environment["PYTHONUNBUFFERED"] = "1"
        return (python, [helper.path, "--device", device.rawValue, "--lane", lane], environment)
    }
}
