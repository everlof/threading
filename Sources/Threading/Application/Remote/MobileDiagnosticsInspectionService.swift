import Foundation
import ThreadingRemoteKit

@MainActor
protocol MobileDiagnosticsToolProviding: AnyObject {
    var mobileDiagnosticsInspection: MobileDiagnosticsInspectionService { get }
}

@MainActor
extension MobileDiagnosticsToolProviding {
    func listIOSDiagnosticDevices() -> MCPToolResult {
        mobileDiagnosticsInspection.listDevices()
    }

    func inspectIOSDiagnostics(
        _ arguments: IOSDiagnosticsInspectionArguments,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        mobileDiagnosticsInspection.inspect(arguments, completion: completion)
    }
}

/// Application-owned formatter/request coordinator for the shipping opt-in iPhone evidence cache.
/// The MCP adapter supplies this injected capability and owns none of its storage or policy.
@MainActor
final class MobileDiagnosticsInspectionService {
    private let captures: MobileDiagnosticsCaptureStore
    private let waitTimeout: Duration
    private var requestTasks: [String: Task<Void, Never>] = [:]

    init(
        captures: MobileDiagnosticsCaptureStore,
        waitTimeout: Duration = .seconds(8)
    ) {
        self.captures = captures
        self.waitTimeout = waitTimeout
    }

    deinit {
        for task in requestTasks.values { task.cancel() }
    }

    func listDevices() -> MCPToolResult {
        guard captures.isEnabled else { return Self.disabledResult() }
        let devices = captures.deviceSummaries()
        guard !devices.isEmpty else {
            return .success(
                "No iOS diagnostic evidence is cached. Enable Local diagnostics on the paired "
                    + "iPhone, open it on the same local network, then try again."
            )
        }
        let rows = devices.map { device -> String in
            let connection = device.isConnected ? "connected" : "offline; cached evidence only"
            let captured = device.latestCapture?.capturedAt ?? "never"
            return "- \(device.deviceName) — id \(device.deviceID); \(connection); "
                + "newest capture \(captured)"
        }
        return .success((["iOS diagnostic devices:"] + rows).joined(separator: "\n"))
    }

    func inspect(
        _ arguments: IOSDiagnosticsInspectionArguments,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard captures.isEnabled else {
            completion(Self.disabledResult())
            return
        }
        let devices = captures.deviceSummaries()
        let selected: MobileDiagnosticsDeviceSummary?
        if let deviceID = arguments.deviceID {
            selected = devices.first { $0.deviceID == deviceID }
            guard selected != nil else {
                completion(.failure(
                    "device_id is unknown. Call list_ios_diagnostic_devices and use an exact id."
                ))
                return
            }
        } else {
            guard devices.count <= 1 else {
                let candidates = devices.map { device in
                    "- \(device.deviceName) — id \(device.deviceID); "
                        + (device.isConnected ? "connected" : "cached only")
                }.joined(separator: "\n")
                completion(.failure(
                    "More than one iPhone has diagnostic evidence. Call "
                        + "list_ios_diagnostic_devices, choose one device_id, then retry:\n"
                        + candidates
                ))
                return
            }
            selected = devices.first
        }
        guard let selected else {
            completion(.failure(
                "No iOS diagnostic evidence is available yet. Enable Local diagnostics on the "
                    + "paired iPhone, open it on the same local network, then try again."
            ))
            return
        }

        let screenshotPolicy: RemoteMobileDiagnosticsCaptureRequestDTO.ScreenshotPolicy
        switch arguments.screenshot ?? "incident" {
        case "none": screenshotPolicy = .none
        case "incident": screenshotPolicy = .latestIncident
        case "current": screenshotPolicy = .current
        default:
            completion(.failure("screenshot must be incident, current, or none."))
            return
        }

        guard arguments.fresh ?? true else {
            guard let cached = captures.latestCapture(deviceID: selected.deviceID) else {
                completion(.failure("This iPhone has no cached diagnostic evidence yet."))
                return
            }
            completion(Self.result(cached, freshness: "cached"))
            return
        }

        guard let requestID = captures.requestCapture(
            deviceID: selected.deviceID,
            screenshotPolicy: screenshotPolicy,
            automatic: false
        ) else {
            guard let cached = captures.latestCapture(deviceID: selected.deviceID) else {
                completion(.failure(
                    "The iPhone is offline and no cached diagnostic evidence exists yet."
                ))
                return
            }
            completion(Self.result(cached, freshness: "cached; phone offline"))
            return
        }

        let captures = captures
        let waitTimeout = waitTimeout
        let selectedDeviceID = selected.deviceID
        let task = Task { @MainActor [weak self] in
            defer { self?.requestTasks.removeValue(forKey: requestID) }
            let outcome = await captures.waitForCapture(
                requestID: requestID,
                timeout: waitTimeout
            )
            let output: MCPToolResult
            switch outcome {
            case .captured(let fresh):
                output = Self.result(fresh, freshness: "fresh")
            case .disabled:
                output = Self.disabledResult()
            case .disconnected:
                output = Self.cachedFallback(
                    captures: captures,
                    deviceID: selectedDeviceID,
                    freshness: "cached; phone disconnected before answering",
                    failure: "The iPhone disconnected before returning diagnostic evidence."
                )
            case .timedOut:
                output = Self.cachedFallback(
                    captures: captures,
                    deviceID: selectedDeviceID,
                    freshness: "cached; connected phone did not answer within 8 seconds",
                    failure: "The connected iPhone did not return diagnostic evidence within "
                        + "8 seconds."
                )
            case .cancelled:
                output = .failure("The iOS diagnostic inspection was cancelled.")
            case .failed(let error):
                output = Self.cachedFallback(
                    captures: captures,
                    deviceID: selectedDeviceID,
                    freshness: "cached; fresh evidence could not be stored",
                    failure: "The iPhone returned diagnostic evidence, but the Mac could not "
                        + "safely store it (\(error))."
                )
            }
            completion(output)
        }
        requestTasks[requestID] = task
    }

    private static func disabledResult() -> MCPToolResult {
        .failure(
            "Local diagnostics is off on this Mac. Enable Settings > Advanced > Local "
                + "Diagnostics, then enable it independently on the paired iPhone."
        )
    }

    private static func result(
        _ stored: MobileDiagnosticsStoredCapture,
        freshness: String
    ) -> MCPToolResult {
        let capture = stored.capture
        var lines = [
            "iOS checkup (\(freshness); \(Self.age(capture.capturedAt)))",
            "Device: \(stored.deviceName) — \(capture.deviceModel)",
            "App: \(capture.appVersion) (\(capture.appBuild)); OS: \(capture.operatingSystem)",
            "State: app \(capture.applicationState); connection \(capture.connectionState); "
                + "route \(capture.activeEndpointKind)",
            "Inventory: \(capture.pairedHostCount) paired Mac(s); "
                + "\(capture.visibleSessionCount) visible session(s)",
            "Capture: \(capture.capturedAt); cached on Mac: \(stored.storedAt)",
            "Recent structural diagnostics (newest \(min(capture.diagnostics.count, 60)) "
                + "of \(capture.diagnostics.count)):",
        ]
        lines.append(contentsOf: capture.diagnostics.suffix(60).map { record in
            let fields = record.fields.keys.sorted().map {
                "\($0)=\(record.fields[$0] ?? "")"
            }.joined(separator: " ")
            return "- \(record.timestamp) [\(record.level.rawValue)] "
                + "\(record.event.rawValue)\(fields.isEmpty ? "" : " \(fields)")"
        })
        let screenshot = capture.screenshotJPEGBase64.flatMap { Data(base64Encoded: $0) }
        lines.append(screenshot == nil
            ? "Screenshot: none in this capture."
            : "Screenshot: attached (\(capture.screenshotKind ?? "diagnostic evidence")).")
        lines.append(
            "Privacy boundary: no prompts, terminal output, paths, credentials, or notification "
                + "text are represented in these diagnostics."
        )
        return .diagnosticEvidence(lines.joined(separator: "\n"), jpegData: screenshot)
    }

    private static func cachedFallback(
        captures: MobileDiagnosticsCaptureStore,
        deviceID: String,
        freshness: String,
        failure: String
    ) -> MCPToolResult {
        guard let cached = captures.latestCapture(deviceID: deviceID) else {
            return .failure(failure)
        }
        return result(cached, freshness: freshness)
    }

    private static func age(_ timestamp: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: timestamp) ?? ordinary.date(from: timestamp) else {
            return "capture age unknown"
        }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s old" }
        if seconds < 3_600 { return "\(seconds / 60)m old" }
        if seconds < 86_400 { return "\(seconds / 3_600)h old" }
        return "\(seconds / 86_400)d old"
    }
}
