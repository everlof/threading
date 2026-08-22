#if DEBUG
import Foundation
import ThreadingRemoteKit

@MainActor
protocol MobileDebugToolProviding: AnyObject {
    var mobileDebugInspection: MobileDebugInspectionService { get }
}

@MainActor
extension MobileDebugToolProviding {
    func listIOSDebugDevices() -> MCPToolResult {
        mobileDebugInspection.listDevices()
    }

    func inspectIOSDebug(
        _ arguments: IOSDebugInspectionArguments,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        mobileDebugInspection.inspect(arguments, completion: completion)
    }
}

/// Application-owned formatter/request coordinator for the Debug iPhone evidence cache.
/// The MCP adapter supplies this injected capability and owns none of its storage or policy.
@MainActor
final class MobileDebugInspectionService {
    private let captures: MobileDebugCaptureStore

    init(captures: MobileDebugCaptureStore) {
        self.captures = captures
    }

    func listDevices() -> MCPToolResult {
        let devices = captures.deviceSummaries()
        guard !devices.isEmpty else {
            return .success(
                "No iOS Debug evidence is cached. Open the Debug iOS app on the same local "
                    + "network as its paired Mac, then try again."
            )
        }
        let rows = devices.map { device -> String in
            let connection = device.isConnected ? "connected" : "offline; cached evidence only"
            let captured = device.latestCapture?.capturedAt ?? "never"
            return "- \(device.deviceName) — id \(device.deviceID); \(connection); "
                + "newest capture \(captured)"
        }
        return .success((["iOS Debug devices:"] + rows).joined(separator: "\n"))
    }

    func inspect(
        _ arguments: IOSDebugInspectionArguments,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let devices = captures.deviceSummaries()
        let selected: MobileDebugDeviceSummary?
        if let deviceID = arguments.deviceID {
            selected = devices.first { $0.deviceID == deviceID }
            guard selected != nil else {
                completion(.failure(
                    "device_id is unknown. Call list_ios_debug_devices and use an exact id."
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
                    "More than one iPhone has Debug evidence. Call list_ios_debug_devices, "
                        + "choose one device_id, then retry:\n\(candidates)"
                ))
                return
            }
            selected = devices.first
        }
        guard let selected else {
            completion(.failure(
                "No iOS Debug evidence is available yet. Open the Debug iOS app on the same "
                    + "local network as its paired Mac, then try again."
            ))
            return
        }

        let screenshotPolicy: RemoteMobileDebugCaptureRequestDTO.ScreenshotPolicy
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
                completion(.failure("This iPhone has no cached Debug evidence yet."))
                return
            }
            completion(result(cached, freshness: "cached"))
            return
        }

        guard let requestID = captures.requestCapture(
            deviceID: selected.deviceID,
            screenshotPolicy: screenshotPolicy,
            automatic: false
        ) else {
            guard let cached = captures.latestCapture(deviceID: selected.deviceID) else {
                completion(.failure(
                    "The iPhone is offline and no cached Debug evidence exists yet."
                ))
                return
            }
            completion(result(cached, freshness: "cached; phone offline"))
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(200))
                if let fresh = self.captures.capture(requestID: requestID) {
                    completion(self.result(fresh, freshness: "fresh"))
                    return
                }
            }
            if let cached = self.captures.latestCapture(deviceID: selected.deviceID) {
                completion(self.result(
                    cached,
                    freshness: "cached; connected phone did not answer within 8 seconds"
                ))
            } else {
                completion(.failure(
                    "The connected iPhone did not return Debug evidence within 8 seconds."
                ))
            }
        }
    }

    private func result(
        _ stored: MobileDebugStoredCapture,
        freshness: String
    ) -> MCPToolResult {
        let capture = stored.capture
        var lines = [
            "iOS Debug checkup (\(freshness); \(Self.age(capture.capturedAt)))",
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
        let screenshot = capture.screenshotJPEGBase64.flatMap { encoded in
            Data(base64Encoded: encoded)
        }
        lines.append(screenshot == nil
            ? "Screenshot: none in this capture."
            : "Screenshot: attached (\(capture.screenshotKind ?? "debug evidence")).")
        lines.append(
            "Privacy boundary: no prompts, terminal output, paths, credentials, or notification "
                + "text are represented in these diagnostics."
        )
        return .debugEvidence(lines.joined(separator: "\n"), jpegData: screenshot)
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
#endif
