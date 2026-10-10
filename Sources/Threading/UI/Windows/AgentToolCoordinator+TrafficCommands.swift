import Foundation

@MainActor
extension AgentToolCoordinator {
    func traffic(_ request: TrafficRequest, for sessionID: SessionID,
                 completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void) {
        Task { completion(await ProxyCaptureService.shared.call(request, for: sessionID)) }
    }
}
