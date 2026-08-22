/// Supplies Threading's host-owned iPhone diagnostics capability to the typed MCP adapter.
@MainActor
extension AgentToolCoordinator: MobileDiagnosticsToolProviding {
    var mobileDiagnosticsInspection: MobileDiagnosticsInspectionService {
        dependencies.mobileDiagnosticsInspection
    }
}
