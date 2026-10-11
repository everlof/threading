import CoreGraphics
import Foundation
import os
import ThreadingAndroidKit
import ThreadingSimulatorKit

enum AndroidStreamDefaults {
    /// The longest side a live frame is delivered at. The pane is at most a few hundred points
    /// wide per device; full 1080×2400 RGBA at 60 fps would be 600 MB/s across loopback for pixels
    /// nobody sees.
    static let maximumLongSide = 1_280
    static let framesPerSecond = 60
    static let pingInterval: TimeInterval = 2
    static let keyActivationTimeout: TimeInterval = 3
    static let maximumTextCharacters = 1_024
    static let dragStepMilliseconds = 16
    static let accessibilityTimeout: TimeInterval = 20
    /// A still screen sends nothing; the Annex-B tail is declared complete after this much quiet.
    static let annexBFlushDelay: TimeInterval = 0.012
    static let screenRecordBitRate = "8M"
    /// `screenrecord` before Android 14 stops after 180 s; it is restarted just before.
    static let screenRecordSegmentSeconds = 170
    static let screenRecordUnlimitedAPI = 34
    static let screenRecordMinimumAPI = 29
    static let maximumScreenRecordRestartsPerMinute = 6
}

/// The capability every Android transport advertises to the pane.
extension SimulatorBridgeCapabilities {
    static let android = SimulatorBridgeCapabilities(
        codecs: [], supportsTouch: true, supportsKeyboard: true, supportsButtons: true,
        maximumFramesPerSecond: AndroidStreamDefaults.framesPerSecond
    )
}

/// Upright display geometry shared by the Android transports.
enum AndroidGeometry {
    /// A size inside `maximumLongSide` with the same aspect, rounded to multiples of 8 (what the
    /// device encoders accept).
    static func cappedSize(width: Int, height: Int, maximumLongSide: Int = AndroidStreamDefaults.maximumLongSide) -> (Int, Int) {
        let long = max(width, height)
        guard long > maximumLongSide, long > 0 else { return (width - width % 8, height - height % 8) }
        let scale = Double(maximumLongSide) / Double(long)
        func round8(_ value: Double) -> Int { max(8, Int(value / 8) * 8) }
        return (round8(Double(width) * scale), round8(Double(height) * scale))
    }

    /// The rotation-sensor angle about z that puts the emulator at an Android rotation.
    static func sensorDegrees(quarterTurns: Int) -> Float {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return 90
        case 2: return 180
        case 3: return -90
        default: return 0
        }
    }

    /// A 0…1 point on the upright picture to physical (natural-orientation) display pixels, given
    /// the display's Android rotation (quarter turns, ROTATION_0…ROTATION_270).
    static func nativePixel(x: Double, y: Double, quarterTurns: Int, nativeWidth: Int, nativeHeight: Int) -> (Int32, Int32) {
        let u = min(max(x, 0), 1), v = min(max(y, 0), 1)
        let (nx, ny): (Double, Double)
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: (nx, ny) = (1 - v, u)
        case 2: (nx, ny) = (1 - u, 1 - v)
        case 3: (nx, ny) = (v, 1 - u)
        default: (nx, ny) = (u, v)
        }
        return (Int32((nx * Double(nativeWidth - 1)).rounded()), Int32((ny * Double(nativeHeight - 1)).rounded()))
    }

    /// `wm size`'s "Physical size: 1080x2400" (an "Override size" line, when present, wins:
    /// it is the size apps and `input` see).
    static func parseWindowSize(_ output: String) -> (width: Int, height: Int)? {
        var physical: (Int, Int)?
        var override: (Int, Int)?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let parts = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else { continue }
            if line.hasPrefix("Override") { override = (width, height) } else { physical = (width, height) }
        }
        return override ?? physical
    }
}

/// The W3C key values the emulator's `sendKey` maps to Android's own buttons, and the `input
/// keyevent` codes adb sends for the same buttons on a phone.
enum AndroidButtonMapping {
    static let emulatorKeys: [SimulatorBridgeButton: String] = [
        .home: "GoHome", .back: "GoBack", .overview: "AppSwitch", .lock: "Power", .side: "Power",
        .volumeUp: "AudioVolumeUp", .volumeDown: "AudioVolumeDown",
    ]

    static let keyEvents: [SimulatorBridgeButton: String] = [
        .home: "KEYCODE_HOME", .back: "KEYCODE_BACK", .overview: "KEYCODE_APP_SWITCH", .lock: "KEYCODE_POWER",
        .side: "KEYCODE_POWER", .volumeUp: "KEYCODE_VOLUME_UP", .volumeDown: "KEYCODE_VOLUME_DOWN",
    ]
}

/// Builds a CGImage from tightly packed RGBA8888 rows, copying once so the source buffer (a
/// mapped region the emulator keeps writing) can change underneath without tearing the result.
enum AndroidFrameImage {
    static func image(rgba bytes: UnsafeRawBufferPointer, width: Int, height: Int) -> CGImage? {
        let length = width * height * 4
        guard width > 0, height > 0, bytes.count >= length,
              let data = CFDataCreate(nil, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), length),
              let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Reads the foreground window hierarchy through `uiautomator`, the one accessibility source a
/// phone and an emulator both have, and maps it onto the pane's element model.
enum AndroidAccessibilityReader {
    static func snapshot(adb: URL, serial: String) async throws -> SimulatorAccessibilityElement {
        let output = try await AndroidADBCommand.run(
            adb: adb, arguments: ["-s", serial, "exec-out", "uiautomator", "dump", "/dev/stdout"],
            timeout: AndroidStreamDefaults.accessibilityTimeout, maximumOutputBytes: UIAutomatorHierarchy.maximumBytes
        )
        let root: AndroidUINode
        do { root = try UIAutomatorHierarchy.parse(output) } catch AndroidRecordError.hierarchyTooLarge {
            throw SimulatorLiveStreamError.helperUnavailable("The Android window hierarchy is larger than Threading reads.")
        } catch {
            throw SimulatorLiveStreamError.helperUnavailable(
                "The Android device did not return its window hierarchy. It may still be animating; try again."
            )
        }
        return element(root)
    }

    static func element(_ node: AndroidUINode) -> SimulatorAccessibilityElement {
        let label = [node.contentDescription, node.text].first { !$0.isEmpty }
        let isTextField = node.className.hasSuffix("EditText")
        return SimulatorAccessibilityElement(
            role: role(for: node), subrole: node.className.isEmpty ? nil : node.className,
            label: label, value: isTextField && !node.isPassword && !node.text.isEmpty ? node.text : nil,
            identifier: node.resourceID.isEmpty ? nil : node.resourceID,
            enabled: node.isEnabled,
            frame: .init(x: node.bounds.x, y: node.bounds.y, width: node.bounds.width, height: node.bounds.height),
            children: node.children.map(element)
        )
    }

    /// The AX role the pane's inspector and agent locators already understand.
    static func role(for node: AndroidUINode) -> String {
        let name = node.className.split(separator: ".").last.map(String.init) ?? node.className
        switch name {
        case "Button", "ImageButton", "MaterialButton", "FloatingActionButton": return "AXButton"
        case "EditText", "AutoCompleteTextView", "TextInputEditText": return "AXTextField"
        case "TextView": return node.isClickable ? "AXButton" : "AXStaticText"
        case "ImageView": return node.isClickable ? "AXButton" : "AXImage"
        case "CheckBox", "Switch", "SwitchCompat", "SwitchMaterial", "ToggleButton": return "AXCheckBox"
        case "RadioButton": return "AXRadioButton"
        case "SeekBar": return "AXSlider"
        case "ProgressBar": return "AXProgressIndicator"
        case "RecyclerView", "ListView", "ScrollView", "HorizontalScrollView", "NestedScrollView": return "AXScrollArea"
        case "hierarchy": return "AXApplication"
        default: return node.isClickable ? "AXButton" : "AXGroup"
        }
    }
}

/// A bounded one-shot `adb` command off the caller's actor, for the transports (the lifecycle
/// control has its own serial queue).
enum AndroidADBCommand {
    static func run(
        adb: URL, arguments: [String], timeout: TimeInterval,
        maximumOutputBytes: Int = AndroidControlDefaults.maximumCommandOutputBytes
    ) async throws -> Data {
        let runner = XcrunSimulatorCommandRunner(executable: adb.path, prefixArguments: [])
        let cancellation = SimulatorCommandCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        let result = try runner.run(arguments, timeout: timeout, maximumOutputBytes: maximumOutputBytes,
                                                    capture: .standardOutput, cancellation: cancellation)
                        if result.outputWasTruncated { throw SimulatorControlError.outputTooLarge(operation: "adb") }
                        switch result.termination {
                        case .timedOut: throw SimulatorControlError.timedOut(operation: "adb")
                        case .exited(let status) where status != 0:
                            throw SimulatorControlError.commandFailed(
                                operation: "adb", detail: String(decoding: result.output, as: UTF8.self)
                            )
                        case .exited: return result.output
                        }
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// The Android transports' app-wide admission, independent of the iOS helper budget.
actor AndroidStreamCoordinator: SimulatorLiveStreamCoordinating {
    static let shared = AndroidStreamCoordinator()

    private let control: AndroidDeviceControl?
    private let directory: AndroidDeviceDirectory
    private let budget: OSAllocatedUnfairLock<SimulatorStreamBudget>

    init(
        control: AndroidDeviceControl? = AndroidDeviceControl.shared,
        directory: AndroidDeviceDirectory = .shared,
        maximumStreams: Int = SimulatorStreamBudget.defaultMaximum
    ) {
        self.control = control
        self.directory = directory
        self.budget = OSAllocatedUnfairLock(initialState: SimulatorStreamBudget(maximum: maximumStreams))
    }

    func openStream(for deviceID: SimulatorDeviceID) async throws -> any SimulatorLiveStreamSession {
        guard let control, let sdk = directory.sdk else {
            throw SimulatorLiveStreamError.helperUnavailable("The Android SDK is not installed on this Mac.")
        }
        let token = try budget.withLock { try $0.reserve() }
        let budget = budget
        let release: @Sendable () -> Void = { budget.withLock { $0.release(token) } }
        do {
            let target = try await control.target(for: deviceID)
            if target.emulator?.grpcPort != nil {
                do {
                    return try await AndroidEmulatorStreamSession.open(
                        target: target, sdk: sdk, directory: directory, onStop: release
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A refused or unreachable control service still leaves adb, which every
                    // emulator has; the reason stays in the log rather than the pane.
                    ThreadingLogger.simulator.error(
                        "Android emulator gRPC unavailable, using adb: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
            return try await AndroidScreenRecordStreamSession.open(target: target, sdk: sdk, onStop: release)
        } catch {
            release()
            throw error
        }
    }
}
