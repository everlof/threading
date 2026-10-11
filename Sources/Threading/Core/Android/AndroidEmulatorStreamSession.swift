import CoreGraphics
import Darwin
import Foundation
import os
import ThreadingAndroidKit
import ThreadingSimulatorKit

/// A live Android emulator through its own gRPC control service: raw RGBA frames written by the
/// emulator into a region Threading maps, touches and keys as emulator events, rotation through the
/// emulator's sensor model. No codec and no `adb` in the frame or input path.
///
/// Authorization is a public key dropped into the emulator's advertised `jwks` directory and a
/// short-lived ES256 token whose audience names exactly the methods this session calls — see
/// `docs/architecture/android-devices.md`.
final class AndroidEmulatorStreamSession: SimulatorLiveStreamSession, @unchecked Sendable {
    let events: AsyncStream<SimulatorLiveStreamEvent>
    var screenOrientation: SimulatorScreenOrientation? { nil }

    private let continuation: AsyncStream<SimulatorLiveStreamEvent>.Continuation
    private let client: EmulatorControlClient
    private let target: AndroidTarget
    private let sdk: AndroidSDK
    private let nativeWidth: Int
    private let nativeHeight: Int
    private let region: AndroidMappedRegion?
    private let keyInstallation: AndroidJWKInstallation
    private let onStop: @Sendable () -> Void
    private let input = AndroidInputSequencer()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var pingTask: Task<Void, Never>?

    private struct State {
        var stopped = false
        var visible = false
        var call: GRPCChannel.CallHandle?
        var sequence: UInt64 = 0
        var lastShape: (width: Int, height: Int, turns: Int)?
        var quarterTurns = 0
        var contact: (x: Int32, y: Int32)?
    }

    private static let touchIdentifier: Int32 = 1

    static func open(
        target: AndroidTarget, sdk: AndroidSDK, directory: AndroidDeviceDirectory,
        onStop: @escaping @Sendable () -> Void
    ) async throws -> AndroidEmulatorStreamSession {
        guard let record = target.emulator, let port = record.grpcPort else {
            throw SimulatorLiveStreamError.helperUnavailable("The emulator does not advertise a gRPC port.")
        }
        let installation = try await AndroidJWKInstallation.install(signer: directory.signer, record: record)
        do {
            let issuer = target.usesThreadingAllowlist ? EmulatorTokenSigner.threadingIssuer : EmulatorTokenSigner.audienceScopedIssuer
            let token = try directory.signer.token(issuer: issuer, methods: EmulatorControlMethod.allCases)
            let channel = GRPCChannel(port: port)
            try await channel.connect()
            let client = EmulatorControlClient(channel: channel) { _ in token }
            do {
                _ = try await client.status()
            } catch {
                channel.close()
                throw error
            }
            let size = try await Self.nativeSize(adb: sdk.adb, serial: target.serial)
            let region = try? AndroidMappedRegion(byteCount: AndroidStreamDefaults.maximumLongSide * AndroidStreamDefaults.maximumLongSide * 4)
            let session = AndroidEmulatorStreamSession(
                client: client, target: target, sdk: sdk, nativeWidth: size.width, nativeHeight: size.height,
                region: region, keyInstallation: installation, onStop: onStop
            )
            session.start()
            return session
        } catch {
            installation.remove()
            throw error
        }
    }

    private init(
        client: EmulatorControlClient, target: AndroidTarget, sdk: AndroidSDK, nativeWidth: Int, nativeHeight: Int,
        region: AndroidMappedRegion?, keyInstallation: AndroidJWKInstallation, onStop: @escaping @Sendable () -> Void
    ) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.client = client
        self.target = target
        self.sdk = sdk
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.region = region
        self.keyInstallation = keyInstallation
        self.onStop = onStop
    }

    private func start() {
        continuation.yield(.ready(
            backend: .android(.emulatorControl), capabilities: .android,
            coreSimulatorVersion: nil, simulatorKitVersion: nil
        ))
        client.channel.whenClosed { [weak self] failure in
            self?.finish(.failed(failure.localizedDescription))
        }
        // The frame stream may be silent for as long as the screen is still, so liveness is the
        // service answering, not the arrival of frames. A unary status call rather than an
        // HTTP/2 PING: gRPC servers answer frequent pings with GOAWAY "too_many_pings".
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(AndroidStreamDefaults.pingInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                do { _ = try await self.client.status() } catch {
                    self.finish(.failed(L10n.string("The Android emulator stopped answering.")))
                    return
                }
            }
        }
    }

    // MARK: - SimulatorLiveStreamSession

    func setVisible(_ visible: Bool) {
        let previous: GRPCChannel.CallHandle? = state.withLock { state in
            guard !state.stopped, state.visible != visible else { return nil }
            state.visible = visible
            defer { if !visible { state.call = nil } }
            return visible ? nil : state.call
        }
        previous?.cancel()
        if visible, state.withLock({ $0.call == nil && !$0.stopped }) { startFrames() }
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

    func stop() {
        finish(nil)
    }

    // MARK: - Frames

    private func startFrames() {
        let long = UInt32(AndroidStreamDefaults.maximumLongSide)
        let request = EmulatorScreenshotRequest(
            format: .rgba8888, width: long, height: long, mmapHandle: region.map { "file://\($0.url.path)" }
        )
        let handle = client.streamScreenshots(request, onImage: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let image): self.deliver(image)
            case .failure: self.finish(.failed(L10n.string("The Android emulator sent an unreadable frame.")))
            }
        }, onEnd: { [weak self] status in
            guard let self, status.code != .cancelled else { return }
            if self.state.withLock({ $0.visible && !$0.stopped }) {
                self.finish(.failed(status.message.isEmpty ? "\(status)" : status.message))
            }
        })
        let keep = state.withLock { state -> Bool in
            guard state.visible, !state.stopped else { return false }
            state.call = handle
            return true
        }
        if !keep { handle.cancel() }
    }

    private func deliver(_ image: EmulatorImage) {
        guard !image.isEmpty else { return } // The display is off or has not posted yet.
        let turns = image.rotation.quarterTurns
        let built: CGImage?
        if image.pixels.isEmpty, let region {
            built = region.withBytes { AndroidFrameImage.image(rgba: $0, width: image.width, height: image.height) }
        } else {
            built = image.pixels.withUnsafeBytes { AndroidFrameImage.image(rgba: $0, width: image.width, height: image.height) }
        }
        guard let built else { return }
        let (sequence, changed) = state.withLock { state -> (UInt64, Bool) in
            let shape = (image.width, image.height, turns)
            let changed = state.lastShape.map { $0 != shape } ?? false
            state.lastShape = shape
            state.quarterTurns = turns
            state.sequence += 1
            return (state.sequence, changed)
        }
        if changed {
            // The pane renegotiates once per confirmed rotation, as it does for an iOS device.
            finish(.geometryChanged)
            return
        }
        continuation.yield(.frame(SimulatorLiveFrame(
            sequence: sequence, image: built, codec: nil, presentationTimeNanoseconds: image.timestampMicroseconds * 1_000
        )))
    }

    // MARK: - Input

    private func pixel(_ x: Double, _ y: Double) -> (Int32, Int32) {
        let turns = state.withLock { $0.quarterTurns }
        return AndroidGeometry.nativePixel(x: x, y: y, quarterTurns: turns, nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    private func touch(_ point: (Int32, Int32), down: Bool) async throws {
        state.withLock { $0.contact = down ? point : nil }
        try await client.sendTouch([EmulatorTouch(
            x: point.0, y: point.1, identifier: Self.touchIdentifier, pressure: down ? EmulatorTouch.contactPressure : 0
        )])
    }

    private func deliver(_ input: SimulatorBridgeInput) async throws {
        guard !state.withLock({ $0.stopped }) else { throw SimulatorLiveStreamError.disconnected }
        switch input {
        case .tap(let x, let y):
            let point = pixel(x, y)
            try await touch(point, down: true)
            try await touch(point, down: false)
        case .drag(let fromX, let fromY, let toX, let toY, let duration):
            let steps = max(2, duration / AndroidStreamDefaults.dragStepMilliseconds)
            try await touch(pixel(fromX, fromY), down: true)
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                try await Task.sleep(nanoseconds: UInt64(AndroidStreamDefaults.dragStepMilliseconds) * 1_000_000)
                try await touch(pixel(fromX + (toX - fromX) * t, fromY + (toY - fromY) * t), down: true)
            }
            try await touch(pixel(toX, toY), down: false)
        case .touch(let phase, let x, let y):
            switch phase {
            case .began, .moved: try await touch(pixel(x, y), down: true)
            case .ended: try await touch(pixel(x, y), down: false)
            case .cancelled:
                // Lift where the contact is held, never at the point the cancel carries.
                guard let held = state.withLock({ $0.contact }) else { return }
                try await touch(held, down: false)
            }
        case .text(let text):
            guard text.count <= AndroidStreamDefaults.maximumTextCharacters else {
                throw SimulatorLiveStreamError.helperUnavailable("Android text is limited to 1,024 characters per call.")
            }
            try await client.type(text)
        case .button(let button):
            switch button {
            case .rotateLeft: try await rotate(by: 1)
            case .rotateRight: try await rotate(by: -1)
            default:
                guard let key = AndroidButtonMapping.emulatorKeys[button] else {
                    throw SimulatorLiveStreamError.helperUnavailable("An Android device has no \(button.rawValue) button.")
                }
                try await client.pressKey(key)
            }
        }
    }

    /// Turns the device a quarter turn by setting the emulator's rotation sensor, as Android
    /// Studio's rotate controls do. Android counts rotation anticlockwise (ROTATION_90 is the
    /// device turned a quarter to the left), so Rotate Left is +1. Measured on emulator 37.1: a
    /// sensor angle of +90° about z reports `LANDSCAPE` (1) and −90° `REVERSE_LANDSCAPE` (3).
    private func rotate(by delta: Int) async throws {
        let turns = state.withLock { (($0.quarterTurns + delta) % 4 + 4) % 4 }
        try await setRotation(quarterTurns: turns)
    }

    func setRotation(quarterTurns: Int) async throws {
        try await client.setRotation(x: 0, y: 0, z: AndroidGeometry.sensorDegrees(quarterTurns: quarterTurns))
    }

    // MARK: - Lifecycle

    private func finish(_ event: SimulatorLiveStreamEvent?) {
        let (first, call): (Bool, GRPCChannel.CallHandle?) = state.withLock { state in
            guard !state.stopped else { return (false, nil) }
            state.stopped = true
            defer { state.call = nil }
            return (true, state.call)
        }
        guard first else { return }
        call?.cancel()
        pingTask?.cancel()
        if let contact = state.withLock({ $0.contact }) {
            // Never leave a finger down in the guest.
            let client = client
            Task { try? await client.sendTouch([EmulatorTouch(x: contact.x, y: contact.y, identifier: Self.touchIdentifier, pressure: 0)]) }
        }
        if let event { continuation.yield(event) }
        continuation.finish()
        client.channel.close()
        keyInstallation.remove()
        onStop()
    }

    private static func nativeSize(adb: URL, serial: String) async throws -> (width: Int, height: Int) {
        let output = try await AndroidADBCommand.run(adb: adb, arguments: ["-s", serial, "shell", "wm", "size"],
                                                     timeout: AndroidControlDefaults.propertyTimeout)
        guard let size = AndroidGeometry.parseWindowSize(String(decoding: output, as: UTF8.self)) else {
            throw SimulatorLiveStreamError.helperUnavailable("The Android device did not report its display size.")
        }
        return size
    }
}

// MARK: - Supporting types

/// One public key in one emulator's `jwks` directory, removed when the last session using it ends.
final class AndroidJWKInstallation: @unchecked Sendable {
    private static let registry = OSAllocatedUnfairLock(initialState: [URL: Int]())

    private let file: URL
    private let removed = OSAllocatedUnfairLock(initialState: false)

    private init(file: URL) { self.file = file }

    static func install(signer: EmulatorTokenSigner, record: RunningEmulatorRecord) async throws -> AndroidJWKInstallation {
        guard let directory = record.jwksDirectory else {
            // An emulator started without JWT security needs no key.
            return AndroidJWKInstallation(file: URL(fileURLWithPath: "/dev/null"))
        }
        let file = directory.appendingPathComponent("\(signer.keyID).jwk")
        let first = registry.withLock { counts -> Bool in
            counts[file, default: 0] += 1
            return counts[file] == 1
        }
        let installation = AndroidJWKInstallation(file: file)
        do {
            if first || !FileManager.default.fileExists(atPath: file.path) {
                try signer.publicJWK().write(to: file, options: .atomic)
            }
            guard let active = record.activeJWKFile else { return installation }
            let deadline = Date().addingTimeInterval(AndroidStreamDefaults.keyActivationTimeout)
            while Date() < deadline {
                if let data = try? Data(contentsOf: active), EmulatorJWKSet.contains(keyID: signer.keyID, in: data) {
                    return installation
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw SimulatorLiveStreamError.helperUnavailable("The emulator did not accept Threading's key.")
        } catch {
            installation.remove()
            throw error
        }
    }

    func remove() {
        guard removed.withLock({ value -> Bool in defer { value = true }; return !value }) else { return }
        guard file.path != "/dev/null" else { return }
        let last = Self.registry.withLock { counts -> Bool in
            counts[file, default: 1] -= 1
            if counts[file] == 0 { counts[file] = nil; return true }
            return false
        }
        if last { try? FileManager.default.removeItem(at: file) }
    }
}

/// A private file the emulator writes frames into and Threading maps read-only.
final class AndroidMappedRegion: @unchecked Sendable {
    let url: URL
    private let pointer: UnsafeMutableRawPointer
    private let byteCount: Int

    init(byteCount: Int, directory: URL = FileManager.default.temporaryDirectory) throws {
        url = directory.appendingPathComponent("codes.threading.android-frames-\(UUID().uuidString)")
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw SimulatorLiveStreamError.helperUnavailable("Couldn’t create the frame region.") }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(byteCount)) == 0,
              let mapped = mmap(nil, byteCount, PROT_READ, MAP_SHARED, descriptor, 0), mapped != MAP_FAILED else {
            unlink(url.path)
            throw SimulatorLiveStreamError.helperUnavailable("Couldn’t map the frame region.")
        }
        pointer = mapped
        self.byteCount = byteCount
    }

    func withBytes<Result>(_ body: (UnsafeRawBufferPointer) -> Result) -> Result {
        body(UnsafeRawBufferPointer(start: pointer, count: byteCount))
    }

    deinit {
        munmap(pointer, byteCount)
        unlink(url.path)
    }
}

/// Orders input: one operation at a time, in submission order, with streamed touch moves
/// coalesced to the newest while one is in flight — a pan that outruns the device drops
/// intermediate positions rather than queueing them, which is what kept it from lagging.
final class AndroidInputSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var pendingMove: (@Sendable () async throws -> Void)?
    private var moveScheduled = false

    func perform(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let result = OSAllocatedUnfairLock<Result<Void, Error>?>(initialState: nil)
        let task: Task<Void, Never> = lock.withLock {
            let previous = tail
            let task = Task {
                await previous?.value
                do { try await operation(); result.withLock { $0 = .success(()) } } catch { result.withLock { $0 = .failure(error) } }
            }
            tail = task
            return task
        }
        await task.value
        try result.withLock { $0 }?.get()
    }

    func coalesce(_ move: @escaping @Sendable () async throws -> Void) {
        let schedule: Bool = lock.withLock {
            pendingMove = move
            defer { moveScheduled = true }
            return !moveScheduled
        }
        guard schedule else { return }
        Task {
            try? await perform { [weak self] in
                guard let self else { return }
                let next: (@Sendable () async throws -> Void)? = self.lock.withLock {
                    defer { self.pendingMove = nil; self.moveScheduled = false }
                    return self.pendingMove
                }
                try await next?()
            }
        }
    }
}
