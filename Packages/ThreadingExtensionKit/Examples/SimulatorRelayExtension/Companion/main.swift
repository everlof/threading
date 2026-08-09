import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ThreadingExtensionKit

private let simulatorBundleIdentifier = "com.apple.iphonesimulator"
private let surfaceIdentifier = "simulator-window"
private let maximumWidth = 1_920
private let maximumHeight = 1_200

private func diagnostic(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func fail(_ message: String, status: Int32 = 70) -> Never {
    diagnostic(message)
    exit(status)
}

private struct SimulatorWindow {
    let id: CGWindowID
    let ownerPID: pid_t
    let bounds: CGRect
}

private struct PresentationState {
    var viewport: ExtensionRemoteSurfaceViewport
    var sequence: UInt64 = 0
    var pendingSequence: UInt64?
}

private final class RemoteWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func send(_ packet: ExtensionRemoteSurfacePacket) throws {
        lock.lock()
        defer { lock.unlock() }
        try ExtensionRemoteSurfaceWire.write(packet, to: handle)
    }
}

private final class SimulatorRelay: @unchecked Sendable {
    private let writer: RemoteWriter
    private let stateLock = NSLock()
    private var presentations: [String: PresentationState] = [:]
    private var simulatorLaunchAttempted = false
    private var screenCaptureAuthorizationChecked = false
    private var inputAuthorizationChecked = false
    private var consecutiveCaptureFailures = 0
    private let captureQueue = DispatchQueue(
        label: "codes.threading.simulator-relay.capture",
        qos: .userInteractive
    )

    init(writer: RemoteWriter) {
        self.writer = writer
    }

    func startCaptureLoop() {
        captureQueue.async { [weak self] in
            while let self {
                autoreleasepool {
                    self.captureVisiblePresentations()
                }
                Thread.sleep(forTimeInterval: 1.0 / 8.0)
            }
        }
    }

    func receive(_ message: ExtensionRemoteSurfaceMessage) {
        switch message {
        case .open(let request):
            guard request.surfaceID == surfaceIdentifier else {
                fail("The host opened undeclared surface \(request.surfaceID).")
            }
            requireScreenCaptureAuthorization()
            stateLock.lock()
            presentations[request.presentationID] = PresentationState(
                viewport: request.viewport
            )
            stateLock.unlock()
            ensureSimulatorIsRunning()

        case .viewport(let viewport):
            stateLock.lock()
            if presentations[viewport.presentationID] != nil {
                presentations[viewport.presentationID]?.viewport = viewport
            }
            stateLock.unlock()

        case .input(let input):
            relay(input)

        case .acknowledgement(let acknowledgement):
            stateLock.lock()
            if presentations[acknowledgement.presentationID]?.pendingSequence
                == acknowledgement.sequence {
                presentations[acknowledgement.presentationID]?.pendingSequence = nil
            }
            stateLock.unlock()

        case .close(let presentation):
            stateLock.lock()
            presentations.removeValue(forKey: presentation.presentationID)
            stateLock.unlock()

        case .frame:
            fail("The host sent a companion-owned remote-surface frame.")
        }
    }

    private func captureVisiblePresentations() {
        let targets: [(String, ExtensionRemoteSurfaceViewport)] = stateLock.withLock {
            presentations.compactMap { id, state in
                guard state.viewport.isVisible,
                      state.pendingSequence == nil,
                      state.viewport.width > 0,
                      state.viewport.height > 0 else {
                    return nil
                }
                return (id, state.viewport)
            }
        }
        guard !targets.isEmpty else { return }
        guard let window = simulatorWindow() else {
            ensureSimulatorIsRunning()
            return
        }
        guard let image = capture(window: window) else {
            consecutiveCaptureFailures += 1
            if consecutiveCaptureFailures == 80 {
                fail(
                    "Simulator Relay could not capture the Simulator window. "
                        + "Allow Screen Recording for Threading and reload "
                        + "the extension."
                )
            }
            return
        }
        consecutiveCaptureFailures = 0

        for (presentationID, viewport) in targets {
            let size = frameSize(for: image, viewport: viewport)
            guard let pixels = bgraPixels(image: image, width: size.width, height: size.height)
            else {
                continue
            }

            let sequence: UInt64? = stateLock.withLock {
                guard var state = presentations[presentationID],
                      state.pendingSequence == nil,
                      state.viewport.isVisible else {
                    return nil
                }
                state.sequence += 1
                state.pendingSequence = state.sequence
                presentations[presentationID] = state
                return state.sequence
            }
            guard let sequence else { continue }

            do {
                try writer.send(.init(
                    message: .frame(.init(
                        presentationID: presentationID,
                        sequence: sequence,
                        width: size.width,
                        height: size.height,
                        bytesPerRow: size.width * 4,
                        payloadLength: pixels.count
                    )),
                    payload: pixels
                ))
            } catch {
                fail("The Simulator remote-surface channel closed: \(error.localizedDescription)")
            }
        }
    }

    private func ensureSimulatorIsRunning() {
        stateLock.lock()
        guard !simulatorLaunchAttempted else {
            stateLock.unlock()
            return
        }
        simulatorLaunchAttempted = true
        stateLock.unlock()

        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: simulatorBundleIdentifier
        ).isEmpty else {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Simulator"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            fail("Simulator Relay could not launch Simulator: \(error.localizedDescription)")
        }
    }

    private func relay(_ input: ExtensionRemoteSurfaceInput) {
        requireInputAuthorization()
        guard let window = simulatorWindow() else { return }
        let flags = eventFlags(input.modifiers)

        switch input.kind {
        case .pointerMoved, .pointerDown, .pointerUp:
            guard let x = input.x, let y = input.y else { return }
            let point = CGPoint(
                x: window.bounds.minX + CGFloat(x) * window.bounds.width,
                y: window.bounds.minY + CGFloat(y) * window.bounds.height
            )
            let button = mouseButton(input.button ?? 0)
            let type: CGEventType
            switch input.kind {
            case .pointerMoved:
                type = .mouseMoved
            case .pointerDown:
                type = mouseType(button: button, down: true)
            case .pointerUp:
                type = mouseType(button: button, down: false)
            default:
                return
            }
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: button
            ) else {
                return
            }
            event.flags = flags
            event.postToPid(window.ownerPID)

        case .scroll:
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(clamping: Int(-(input.deltaY ?? 0))),
                wheel2: Int32(clamping: Int(input.deltaX ?? 0)),
                wheel3: 0
            ) else {
                return
            }
            event.flags = flags
            event.postToPid(window.ownerPID)

        case .keyDown, .keyUp:
            guard let keyCode = input.keyCode,
                  let event = CGEvent(
                      keyboardEventSource: nil,
                      virtualKey: CGKeyCode(keyCode),
                      keyDown: input.kind == .keyDown
                  ) else {
                return
            }
            event.flags = flags
            event.postToPid(window.ownerPID)
        }
    }

    private func requireScreenCaptureAuthorization() {
        stateLock.lock()
        let alreadyChecked = screenCaptureAuthorizationChecked
        screenCaptureAuthorizationChecked = true
        stateLock.unlock()
        guard !alreadyChecked else { return }

        guard CGPreflightScreenCaptureAccess() else {
            fail(
                "Simulator Relay needs Screen Recording. macOS attributes this direct child "
                    + "process to Threading, so allow Threading in System Settings → Privacy & "
                    + "Security → Screen & System Audio Recording, then relaunch Threading."
            )
        }
    }

    private func requireInputAuthorization() {
        stateLock.lock()
        let alreadyChecked = inputAuthorizationChecked
        inputAuthorizationChecked = true
        stateLock.unlock()
        guard !alreadyChecked else { return }

        let checkOnly = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary
        guard AXIsProcessTrustedWithOptions(checkOnly) else {
            fail(
                "Simulator Relay needs Accessibility for input relay. macOS attributes this "
                    + "direct child process to Threading, so allow Threading in System Settings → "
                    + "Privacy & Security → Accessibility, then relaunch Threading."
            )
        }
    }
}

private func simulatorWindow() -> SimulatorWindow? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let values = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
        as? [[CFString: Any]] else {
        return nil
    }
    return values.compactMap { info -> SimulatorWindow? in
        guard let owner = info[kCGWindowOwnerPID] as? NSNumber,
              let windowNumber = info[kCGWindowNumber] as? NSNumber,
              let layer = info[kCGWindowLayer] as? NSNumber,
              layer.intValue == 0,
              let boundsDictionary = info[kCGWindowBounds] as? [String: Any],
              let application = NSRunningApplication(
                  processIdentifier: owner.int32Value
              ),
              application.bundleIdentifier == simulatorBundleIdentifier else {
            return nil
        }
        var bounds = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(
                  boundsDictionary as CFDictionary,
                  &bounds
              ),
              bounds.width >= 200,
              bounds.height >= 200 else {
            return nil
        }
        return SimulatorWindow(
            id: CGWindowID(windowNumber.uint32Value),
            ownerPID: owner.int32Value,
            bounds: bounds
        )
    }
    .max { left, right in
        left.bounds.width * left.bounds.height < right.bounds.width * right.bounds.height
    }
}

private func capture(window: SimulatorWindow) -> CGImage? {
    CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        window.id,
        [.boundsIgnoreFraming, .bestResolution]
    )
}

private func frameSize(
    for image: CGImage,
    viewport: ExtensionRemoteSurfaceViewport
) -> (width: Int, height: Int) {
    let desiredWidth = max(1, Int((viewport.width * viewport.scale).rounded()))
    let desiredHeight = max(1, Int((viewport.height * viewport.scale).rounded()))
    let scale = min(
        1,
        min(
            Double(min(maximumWidth, desiredWidth)) / Double(image.width),
            Double(min(maximumHeight, desiredHeight)) / Double(image.height)
        )
    )
    return (
        max(1, Int((Double(image.width) * scale).rounded())),
        max(1, Int((Double(image.height) * scale).rounded()))
    )
}

private func bgraPixels(image: CGImage, width: Int, height: Int) -> Data? {
    var pixels = Data(count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(
            data: bytes.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            ).union(.byteOrder32Little).rawValue
        ) else {
            return false
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return rendered ? pixels : nil
}

private func mouseButton(_ value: Int) -> CGMouseButton {
    switch value {
    case 1: return .right
    case 2: return .center
    default: return .left
    }
}

private func mouseType(button: CGMouseButton, down: Bool) -> CGEventType {
    switch (button, down) {
    case (.right, true): return .rightMouseDown
    case (.right, false): return .rightMouseUp
    case (.center, true): return .otherMouseDown
    case (.center, false): return .otherMouseUp
    case (_, true): return .leftMouseDown
    case (_, false): return .leftMouseUp
    }
}

private func eventFlags(
    _ modifiers: [ExtensionRemoteSurfaceModifier]
) -> CGEventFlags {
    var flags: CGEventFlags = []
    for modifier in modifiers {
        switch modifier {
        case .shift: flags.insert(.maskShift)
        case .control: flags.insert(.maskControl)
        case .option: flags.insert(.maskAlternate)
        case .command: flags.insert(.maskCommand)
        }
    }
    return flags
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

let environment = ProcessInfo.processInfo.environment
guard CommandLine.arguments.dropFirst().first == "--threading-companion-serve",
      let companionID = environment[ExtensionCompanionEnvironment.companionIdentifier],
      let generation = environment[ExtensionCompanionEnvironment.generation],
      let descriptorText = environment[
          ExtensionCompanionEnvironment.remoteSurfaceDescriptor
      ],
      let descriptor = Int32(descriptorText) else {
    fail("Simulator Relay was not launched as a Threading companion.", status: 64)
}

var hello = try JSONEncoder().encode(ExtensionCompanionHello(
    companionID: companionID,
    generation: generation
))
hello.append(0x0A)
try FileHandle.standardOutput.write(contentsOf: hello)

DispatchQueue.global(qos: .utility).async {
    while let line = readLine(strippingNewline: true),
          let data = line.data(using: .utf8) {
        guard let message = try? JSONDecoder().decode(
            ExtensionCompanionHostMessage.self,
            from: data
        ) else {
            continue
        }
        if message.type == .shutdown, message.generation == generation {
            exit(0)
        }
    }
    exit(0)
}

private let surfaceHandle = FileHandle(
    fileDescriptor: descriptor,
    closeOnDealloc: false
)
private let relay = SimulatorRelay(writer: RemoteWriter(handle: surfaceHandle))
relay.startCaptureLoop()

do {
    while let packet = try ExtensionRemoteSurfaceWire.read(from: surfaceHandle) {
        relay.receive(packet.message)
    }
} catch {
    fail("Simulator Relay received an invalid surface message: \(error.localizedDescription)")
}
