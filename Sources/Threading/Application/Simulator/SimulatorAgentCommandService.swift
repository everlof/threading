import Foundation

/// Owns validation and stable response payloads for Simulator MCP commands.
///
/// The coordinator remains a thin adapter over the session's visible pane. This service has no
/// window authority and cannot create a second device lease or launch Simulator.app.
enum SimulatorAgentCommandService {
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
