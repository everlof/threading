import Foundation

/// Owns a capture-policy transaction independently of its Mac/phone approval presentation.
@MainActor
enum BrowserNetworkCaptureCommandService {
    static func configuration(_ settings: BrowserNetworkCaptureSettings) -> MCPToolResult {
        .structured(settings.agentDescription, value: settings.agentConfiguration)
    }

    static func request(
        _ request: BrowserNetworkCaptureRequest,
        settings: BrowserNetworkCaptureSettings,
        confirm: (BrowserNetworkCaptureOptions, @escaping @MainActor (Bool) -> Void) -> Void,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard !request.isEmpty else {
            completion(.failure("request_capture must specify at least one capture option."))
            return
        }
        let previous = settings.options
        let revision = settings.revision
        let proposed = request.applying(to: previous)
        guard proposed != previous else {
            completion(configuration(settings))
            return
        }
        confirm(proposed) { allowed in
            guard allowed else {
                completion(.failure("The user declined the network capture change. Settings are unchanged."))
                return
            }
            guard settings.revision == revision, settings.options == previous else {
                completion(.failure("Network capture settings changed while approval was open; request again."))
                return
            }
            settings.options = proposed
            completion(configuration(settings))
        }
    }
}
