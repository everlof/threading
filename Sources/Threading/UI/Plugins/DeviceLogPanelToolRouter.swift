import Foundation
import ThreadingPluginKit

/// A stable built-in route to the session's existing plugin, never a second log reader.
@MainActor
enum DeviceLogPanelToolRouter {
    static var admissionFailure: MCPToolResult? {
        guard AppSettings.shared.isToolGroupEnabled("device-log"),
              AppSettings.shared.isToolGroupEnabled(NativePluginManagedOffer.deviceLogs.identifier) else {
            return .failure("Device Logs tools are disabled in Settings > Tools.")
        }
        return nil
    }

    static func invoke(
        _ arguments: DeviceLogsArguments, for sessionID: SessionID,
        in pane: NativePluginPaneViewController,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        if let failure = admissionFailure { completion(failure); return }
        guard pane.owningSessionID == sessionID else {
            completion(.failure("Device Logs belongs to a different session."))
            return
        }
        Task { @MainActor in
            await pane.waitForInitialLoad()
            // Settings can change while verification runs. Do not dispatch through a revoked group.
            if let failure = admissionFailure { completion(failure); return }
            guard let plugin = pane.loaded else {
                let reason = pane.refusal?.description ?? "The plugin is still loading."
                completion(.failure("Device Logs is not ready: \(reason) Complete any setup shown in the panel, then retry device_logs with action:state. No panel parameters were applied."))
                return
            }
            guard plugin.pluginIdentifier == NativePluginManagedOffer.deviceLogs.identifier else {
                completion(.failure("The opened pane is not the Device Logs plugin."))
                return
            }
            NativePluginMCPToolProvider().invokeTool(
                named: arguments.pluginToolName, arguments: arguments.parameters, for: sessionID, in: pane
            ) { response in
                completion(response.isError ? .failure(response.text) : .success(response.text))
            }
        }
    }
}
