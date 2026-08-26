import Foundation

/// Owns validation and stable response payloads for Simulator MCP commands.
///
/// The coordinator remains a thin adapter over the session's visible pane. This service has no
/// window authority and cannot create a second device lease or launch Simulator.app.
enum SimulatorAgentCommandService {
    private static let validTextPunctuation = Set("-_=+[]{}\\|;:'\"`~,<>./?!@#$%^&*()")

    enum Input: Sendable {
        case tap(x: Double, y: Double)
        case swipe(
            fromX: Double,
            fromY: Double,
            toX: Double,
            toY: Double,
            durationMilliseconds: Int
        )
        case text(String)
        case button(Button)
    }

    enum Button: String, Sendable {
        case home
        case lock
        case side
    }

    struct LaunchRequest {
        let applicationURL: URL
        let bundleIdentifier: String
        let arguments: [String]
    }

    enum Request<Value> {
        case accepted(Value)
        case rejected(MCPToolResult)
    }

    static func requestedDeviceID(
        from arguments: SimulatorPrepareArguments
    ) -> Request<SimulatorDeviceID?> {
        guard let rawValue = arguments.deviceID else { return .accepted(nil) }
        guard let parsed = SimulatorDeviceID(rawValue) else {
            return .rejected(.failure(
                "device_id must be an exact CoreSimulator device UUID."
            ))
        }
        return .accepted(parsed)
    }

    static func launchRequest(
        from arguments: SimulatorInstallLaunchArguments,
        resolve: (String) -> URL?
    ) -> Request<LaunchRequest> {
        guard let path = arguments.applicationPath, !path.isEmpty else {
            return .rejected(.failure("Missing required argument: application_path"))
        }
        guard let bundleIdentifier = arguments.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return .rejected(.failure("Missing required argument: bundle_identifier"))
        }
        guard let applicationURL = resolve(path) else {
            return .rejected(.failure("No such application: \(path)"))
        }
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return .rejected(.failure("application_path must name a built .app bundle."))
        }
        return .accepted(LaunchRequest(
            applicationURL: applicationURL,
            bundleIdentifier: bundleIdentifier,
            arguments: arguments.arguments ?? []
        ))
    }

    static func preparationResult(for lease: SimulatorDeviceLease) -> MCPToolResult {
        let device = lease.device
        return encoded(PreparationPayload(
            deviceID: device.id.rawValue,
            name: device.name,
            runtime: device.runtimeName,
            family: device.family.rawValue,
            bootOwnership: lease.bootOwnership.rawValue,
            surface: "Threading right panel",
            xcodebuildDestination: "platform=iOS Simulator,id=\(device.id.rawValue)"
        ))
    }

    static func launchResult(for receipt: SimulatorLaunchReceipt) -> MCPToolResult {
        encoded(LaunchPayload(
            deviceID: receipt.deviceID.rawValue,
            bundleIdentifier: receipt.bundleIdentifier,
            processIdentifier: receipt.processIdentifier,
            surface: "Threading right panel"
        ))
    }

    static func screenshotResult(
        data: Data,
        device: SimulatorDevice,
        includeImage: Bool
    ) -> MCPToolResult {
        .screenshot(
            "Captured \(device.name) (\(device.id.rawValue)) "
                + "from Threading's right-panel Simulator.",
            pngData: data,
            includeImage: includeImage
        )
    }

    static func tapInput(from arguments: SimulatorTapArguments) -> Request<Input> {
        guard let x = arguments.x, let y = arguments.y else {
            return .rejected(.failure("Missing required arguments: x and y"))
        }
        guard validCoordinate(x), validCoordinate(y) else {
            return .rejected(.failure("Simulator coordinates must be finite values from 0 to 1."))
        }
        return .accepted(.tap(x: x, y: y))
    }

    static func swipeInput(
        from arguments: SimulatorSwipeArguments
    ) -> Request<Input> {
        guard let fromX = arguments.fromX,
              let fromY = arguments.fromY,
              let toX = arguments.toX,
              let toY = arguments.toY else {
            return .rejected(.failure(
                "Missing required arguments: from_x, from_y, to_x, and to_y"
            ))
        }
        guard [fromX, fromY, toX, toY].allSatisfy(validCoordinate) else {
            return .rejected(.failure("Simulator coordinates must be finite values from 0 to 1."))
        }
        let duration = arguments.durationMilliseconds ?? 300
        guard (100...2_000).contains(duration) else {
            return .rejected(.failure("duration_ms must be between 100 and 2000."))
        }
        return .accepted(.swipe(
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            durationMilliseconds: duration
        ))
    }

    static func textInput(
        from arguments: SimulatorTypeTextArguments
    ) -> Request<Input> {
        guard let text = arguments.text, !text.isEmpty else {
            return .rejected(.failure("Missing required argument: text"))
        }
        guard text.count <= 1_024 else {
            return .rejected(.failure("Simulator text is limited to 1,024 characters per call."))
        }
        guard text.allSatisfy(validTextCharacter) else {
            return .rejected(.failure(
                "Direct Simulator typing supports printable US-keyboard text, tab, newline, and backspace."
            ))
        }
        return .accepted(.text(text))
    }

    static func buttonInput(
        from arguments: SimulatorPressButtonArguments
    ) -> Request<Input> {
        guard let rawValue = arguments.button, !rawValue.isEmpty else {
            return .rejected(.failure("Missing required argument: button"))
        }
        guard let button = Button(rawValue: rawValue) else {
            return .rejected(.failure("button must be home, lock, or side."))
        }
        return .accepted(.button(button))
    }

    static func inputResult(action: String, device: SimulatorDevice) -> MCPToolResult {
        encoded(InputPayload(
            deviceID: device.id.rawValue,
            action: action,
            surface: "Threading right panel"
        ))
    }

    private static func validCoordinate(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    /// Mirrors the helper protocol's bounded US-keyboard vocabulary without importing the
    /// transport package across the Application compiler-layer boundary.
    private static func validTextCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else { return false }
        switch scalar.value {
        case 8, 9, 10, 32, 48...57, 65...90, 97...122:
            return true
        default:
            return validTextPunctuation.contains(character)
        }
    }

    private static func encoded<Value: Encodable>(_ value: Value) -> MCPToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return .failure("Could not encode the Simulator result.")
        }
        return .success(text)
    }
}

private struct PreparationPayload: Encodable {
    let deviceID: String
    let name: String
    let runtime: String
    let family: String
    let bootOwnership: String
    let surface: String
    let xcodebuildDestination: String

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name, runtime, family
        case bootOwnership = "boot_ownership"
        case surface
        case xcodebuildDestination = "xcodebuild_destination"
    }
}

private struct LaunchPayload: Encodable {
    let deviceID: String
    let bundleIdentifier: String
    let processIdentifier: Int32?
    let surface: String

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case bundleIdentifier = "bundle_identifier"
        case processIdentifier = "process_identifier"
        case surface
    }
}

private struct InputPayload: Encodable {
    let deviceID: String
    let action: String
    let surface: String

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case action, surface
    }
}
